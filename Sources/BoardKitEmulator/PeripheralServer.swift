// BLE peripheral server — the ONLY CoreBluetooth code in the BoardKit tree.
//
// The BoardKit library targets stay platform-free; everything radio-shaped
// lives here, inside the executable target, behind this guard.
#if os(macOS) && canImport(CoreBluetooth)

import Foundation
import CoreBluetooth

/// `CBPeripheralManager` wrapper that advertises a `BoardPersonality`'s
/// identity and serves its GATT layout over real BLE.
///
/// ## What this can and cannot advertise
///
/// macOS peripheral-mode advertising supports exactly TWO keys —
/// `CBAdvertisementDataLocalNameKey` and `CBAdvertisementDataServiceUUIDsKey`.
/// No manufacturer data, no TX-power, no raw advertisement control. Host
/// transports discover boards by (name filter + service UUID), so these two
/// keys are sufficient to be discovered as hardware.
///
/// ## Live-run honesty
///
/// Creating a `CBPeripheralManager` triggers the macOS Bluetooth TCC
/// permission prompt on first run, and a real central must connect and
/// subscribe before any notification leaves the machine. The first live run
/// is therefore a human-driven session; CI covers everything below the
/// radio (personalities, chaos, driver, capture) through the pure test
/// targets.
///
/// ## Notification pump
///
/// Frames are queued whole, chunked to the subscribed central's
/// `maximumUpdateValueLength` at send time (both host adapters reassemble:
/// Square Off on the `*` terminator, Chessnut on the length header), paced
/// by `notifyGapMs`, and retried on `updateValue == false` when CoreBluetooth
/// signals readiness via `peripheralManagerIsReady(toUpdateSubscribers:)`.
///
/// ## Capture
///
/// Every session doubles as a ReplayScript capture: notifications are
/// logged as `rx` lines, host writes as `# tx` comments, subscription
/// changes as lifecycle events. Lines are appended to `captureURL`
/// incrementally so a Ctrl-C still leaves a usable file.
final class PeripheralServer: NSObject, @unchecked Sendable {

    // MARK: - Configuration

    private let advertisedName: String
    private let layout: GATTLayout
    private let notifyGapMs: Int
    private let captureURL: URL?

    // MARK: - State (all mutated on `queue`)

    private let queue = DispatchQueue(label: "boardkit.emulator.ble")
    private var manager: CBPeripheralManager?
    private var characteristicsByUUID: [String: CBMutableCharacteristic] = [:]
    private var servicesPendingAdd = 0
    private var advertisingStarted = false

    /// Whole personality frames waiting to be sent (chunked at send time).
    private var pendingChunks: [(characteristicUUID: String, data: Data)] = []
    private var waitingForReadiness = false
    private var maxUpdateLength = 20
    private var subscriberCount = 0

    private var recorder: CaptureRecorder
    private var captureHandle: FileHandle?
    private var flushedLineCount = 0
    private var lastTrafficAt = DispatchTime.now()

    // MARK: - Callbacks (set before `start()`)

    var onHostWrite: (@Sendable (Data) -> Void)?
    /// Fired on the first subscriber and on the last unsubscriber.
    var onCentralPresence: (@Sendable (Bool) -> Void)?
    var onLog: (@Sendable (String) -> Void)?

    // MARK: - Init

    init(advertisedName: String,
         layout: GATTLayout,
         notifyGapMs: Int = 15,
         captureURL: URL? = nil,
         captureHeader: String = "") {
        self.advertisedName = advertisedName
        self.layout = layout
        self.notifyGapMs = notifyGapMs
        self.captureURL = captureURL
        self.recorder = CaptureRecorder(header: captureHeader)
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        queue.async { [self] in
            openCaptureFileIfNeeded()
            // Creating the manager triggers the TCC Bluetooth prompt.
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }

    func stop() {
        queue.async { [self] in
            manager?.stopAdvertising()
            manager?.removeAllServices()
            flushCapture()
            try? captureHandle?.close()
            captureHandle = nil
        }
    }

    // MARK: - Outbound frames

    func enqueue(_ frames: [PersonalityFrame]) {
        queue.async { [self] in
            for frame in frames {
                recordTraffic { recorder, elapsed in
                    recorder.recordNotification(frame.data, elapsedMs: elapsed)
                }
                pendingChunks.append((frame.characteristicUUID, frame.data))
            }
            pump()
        }
    }

    /// Drain the queue, chunking each frame to the current ATT budget.
    /// Runs on `queue`.
    private func pump() {
        guard let manager, !waitingForReadiness else { return }
        while !pendingChunks.isEmpty {
            let head = pendingChunks[0]
            guard let characteristic = characteristicsByUUID[head.characteristicUUID.lowercased()] else {
                onLog?("ble: no characteristic \(head.characteristicUUID) — dropping frame")
                pendingChunks.removeFirst()
                continue
            }
            let chunk = head.data.prefix(maxUpdateLength)
            let sent = manager.updateValue(Data(chunk), for: characteristic, onSubscribedCentrals: nil)
            if !sent {
                // Transmit queue full: resume from peripheralManagerIsReady.
                waitingForReadiness = true
                return
            }
            if chunk.count == head.data.count {
                pendingChunks.removeFirst()
            } else {
                pendingChunks[0].data = head.data.dropFirst(chunk.count)
            }
            if notifyGapMs > 0, !pendingChunks.isEmpty {
                // Pace the next chunk without blocking the queue.
                waitingForReadiness = true
                queue.asyncAfter(deadline: .now() + .milliseconds(notifyGapMs)) { [self] in
                    waitingForReadiness = false
                    pump()
                }
                return
            }
        }
    }

    // MARK: - Capture plumbing (runs on `queue`)

    private func recordTraffic(_ record: (inout CaptureRecorder, Int) -> Void) {
        let now = DispatchTime.now()
        let elapsedMs = Int((now.uptimeNanoseconds - lastTrafficAt.uptimeNanoseconds) / 1_000_000)
        lastTrafficAt = now
        record(&recorder, elapsedMs)
        flushCapture()
    }

    private func openCaptureFileIfNeeded() {
        guard let captureURL, captureHandle == nil else { return }
        FileManager.default.createFile(atPath: captureURL.path, contents: nil)
        captureHandle = try? FileHandle(forWritingTo: captureURL)
        if captureHandle == nil {
            onLog?("capture: cannot open \(captureURL.path)")
        }
    }

    /// Append any recorder lines not yet on disk (incremental, Ctrl-C safe).
    private func flushCapture() {
        guard let captureHandle else { return }
        let lines = recorder.lines
        guard lines.count > flushedLineCount else { return }
        let newText = lines[flushedLineCount...].joined(separator: "\n") + "\n"
        flushedLineCount = lines.count
        try? captureHandle.write(contentsOf: Data(newText.utf8))
    }
}

// MARK: - CBPeripheralManagerDelegate

extension PeripheralServer: CBPeripheralManagerDelegate {

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            onLog?("ble: powered on — publishing \(layout.services.count) service(s)")
            publishServices(on: peripheral)
        case .unauthorized:
            onLog?("ble: UNAUTHORIZED — grant Bluetooth permission in System Settings › Privacy (TCC prompt)")
        case .poweredOff:
            onLog?("ble: Bluetooth is powered off")
        case .unsupported:
            onLog?("ble: peripheral mode unsupported on this Mac")
        default:
            onLog?("ble: state \(peripheral.state.rawValue)")
        }
    }

    private func publishServices(on peripheral: CBPeripheralManager) {
        characteristicsByUUID.removeAll()
        servicesPendingAdd = layout.services.count
        for serviceSpec in layout.services {
            let service = CBMutableService(type: CBUUID(string: serviceSpec.uuid), primary: true)
            var characteristics: [CBMutableCharacteristic] = []
            for spec in serviceSpec.characteristics {
                var properties: CBCharacteristicProperties = []
                var permissions: CBAttributePermissions = []
                for role in spec.roles {
                    switch role {
                    case .notify:
                        properties.insert(.notify)
                        permissions.insert(.readable)
                    case .write:
                        properties.insert(.write)
                        permissions.insert(.writeable)
                    case .writeWithoutResponse:
                        properties.insert(.writeWithoutResponse)
                        permissions.insert(.writeable)
                    case .read:
                        properties.insert(.read)
                        permissions.insert(.readable)
                    }
                }
                let characteristic = CBMutableCharacteristic(
                    type: CBUUID(string: spec.uuid),
                    properties: properties,
                    value: nil,
                    permissions: permissions
                )
                characteristics.append(characteristic)
                characteristicsByUUID[spec.uuid.lowercased()] = characteristic
            }
            service.characteristics = characteristics
            peripheral.add(service)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            onLog?("ble: failed to add service \(service.uuid): \(error.localizedDescription)")
            return
        }
        servicesPendingAdd -= 1
        guard servicesPendingAdd == 0, !advertisingStarted else { return }
        advertisingStarted = true
        // macOS peripheral advertising supports ONLY these two keys.
        let advertisement: [String: Any] = [
            CBAdvertisementDataLocalNameKey: advertisedName,
            CBAdvertisementDataServiceUUIDsKey: layout.advertisedServiceUUIDs.map { CBUUID(string: $0) },
        ]
        peripheral.startAdvertising(advertisement)
        onLog?("ble: advertising as \"\(advertisedName)\" [\(layout.advertisedServiceUUIDs.joined(separator: ", "))]")
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error {
            onLog?("ble: advertising failed: \(error.localizedDescription)")
        } else {
            onLog?("ble: advertising live — waiting for a central to connect + subscribe")
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didSubscribeTo characteristic: CBCharacteristic) {
        maxUpdateLength = max(20, central.maximumUpdateValueLength)
        subscriberCount += 1
        onLog?("ble: central subscribed to \(characteristic.uuid) (ATT budget \(maxUpdateLength) B)")
        recorder.recordLifecycle(connected: true)
        flushCapture()
        if subscriberCount == 1 {
            onCentralPresence?(true)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           central: CBCentral,
                           didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscriberCount = max(0, subscriberCount - 1)
        onLog?("ble: central unsubscribed from \(characteristic.uuid)")
        if subscriberCount == 0 {
            recorder.recordLifecycle(connected: false)
            flushCapture()
            onCentralPresence?(false)
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests {
            guard let value = request.value else { continue }
            recordTraffic { recorder, elapsed in
                recorder.recordHostWrite(value, elapsedMs: elapsed)
            }
            onHostWrite?(value)
        }
        if let first = requests.first {
            peripheral.respond(to: first, withResult: .success)
        }
    }

    func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        queue.async { [self] in
            waitingForReadiness = false
            pump()
        }
    }
}

#endif  // os(macOS) && canImport(CoreBluetooth)
