import Foundation
import CoreBluetooth
import Combine

/// BLE Manager for Open Chess boards.
///
/// Handles:
/// - Scanning for Open Chess boards
/// - Connecting to the board
/// - Receiving sensor events
/// - Sending commands (LED control, game state requests)
class OpenChessBLEManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    
    @Published var isScanning = false
    @Published var isConnected = false
    @Published var boardName: String?
    @Published var lastEvent: String?
    @Published var occupancySnapshot: [Bool] = Array(repeating: false, count: 64)
    
    // MARK: - BLE UUIDs
    
    private let serviceUUID = CBUUID(string: "19B10000-E8F2-537E-4F6C-D104768A1214")
    private let sensorCharUUID = CBUUID(string: "19B10001-E8F2-537E-4F6C-D104768A1214")
    private let commandCharUUID = CBUUID(string: "19B10002-E8F2-537E-4F6C-D104768A1214")
    private let stateCharUUID = CBUUID(string: "19B10003-E8F2-537E-4F6C-D104768A1214")
    private let ledCharUUID = CBUUID(string: "19B10004-E8F2-537E-4F6C-D104768A1214")
    
    // MARK: - Private Properties
    
    private var centralManager: CBCentralManager!
    private var openChessPeripheral: CBPeripheral?
    private var sensorCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var stateCharacteristic: CBCharacteristic?
    private var ledCharacteristic: CBCharacteristic?
    
    // MARK: - Initialization
    
    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }
    
    // MARK: - Public Methods
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth is not powered on")
            return
        }
        
        isScanning = true
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
        print("Scanning for Open Chess boards...")
    }
    
    func stopScanning() {
        centralManager.stopScan()
        isScanning = false
        print("Stopped scanning")
    }
    
    func disconnect() {
        if let peripheral = openChessPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }
    
    // MARK: - Command Methods
    
    func requestBoardState() {
        sendCommand("GETSTATE")
    }
    
    func startNewGame() {
        sendCommand("NEWGAME")
    }
    
    func setLEDs(squares: [String]) {
        let command = "SET:" + squares.joined(separator: ",")
        sendLEDCommand(command)
    }
    
    func setLEDColor(square: String, r: UInt8, g: UInt8, b: UInt8) {
        let command = "COLOR:\(square)R\(r)G\(g)B\(b)"
        sendLEDCommand(command)
    }
    
    func clearLEDs() {
        sendLEDCommand("CLEAR")
    }
    
    // MARK: - Private Methods
    
    private func sendCommand(_ command: String) {
        guard let characteristic = commandCharacteristic,
              let peripheral = openChessPeripheral,
              peripheral.state == .connected else {
            print("Not connected to board")
            return
        }
        
        if let data = command.data(using: .utf8) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            print("Sent command: \(command)")
        }
    }
    
    private func sendLEDCommand(_ command: String) {
        guard let characteristic = ledCharacteristic,
              let peripheral = openChessPeripheral,
              peripheral.state == .connected else {
            print("Not connected to board")
            return
        }
        
        if let data = command.data(using: .utf8) {
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            print("Sent LED command: \(command)")
        }
    }
    
    private func processSensorEvent(_ event: String) {
        // Format: "SE:<square><state>" (e.g., "SE:e2L", "SE:e4P")
        guard event.hasPrefix("SE:"),
              event.count == 5 else { return }
        
        let square = String(event.dropFirst(3).prefix(2))
        let state = event.last
        let isLift = state == "L"
        
        print("Sensor event: \(square) \(isLift ? "lifted" : "placed")")
        
        DispatchQueue.main.async {
            self.lastEvent = "\(square) \(isLift ? "↑" : "↓")"
        }
    }
    
    private func processOccupancySnapshot(_ snapshot: String) {
        // Format: "OC:<64 bits>"
        guard snapshot.hasPrefix("OC:"),
              snapshot.count == 67 else { return }
        
        let bits = String(snapshot.dropFirst(3))
        var occupancy = [Bool](repeating: false, count: 64)
        
        for (index, char) in bits.enumerated() where index < 64 {
            occupancy[index] = char == "1"
        }
        
        DispatchQueue.main.async {
            self.occupancySnapshot = occupancy
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension OpenChessBLEManager: CBCentralManagerDelegate {
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            print("Bluetooth is powered on")
        case .poweredOff:
            print("Bluetooth is powered off")
        case .unauthorized:
            print("Bluetooth is unauthorized")
        default:
            print("Bluetooth state: \(central.state.rawValue)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        print("Discovered: \(name) (\(peripheral.identifier.uuidString))")
        
        // Check if this is an Open Chess board
        if name.lowercased().contains("openchess") {
            openChessPeripheral = peripheral
            stopScanning()
            centralManager.connect(peripheral, options: nil)
            print("Connecting to Open Chess board: \(name)")
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to \(peripheral.name ?? "Unknown")")
        
        DispatchQueue.main.async {
            self.isConnected = true
            self.boardName = peripheral.name
        }
        
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect: \(error?.localizedDescription ?? "Unknown error")")
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.boardName = nil
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from \(peripheral.name ?? "Unknown")")
        
        DispatchQueue.main.async {
            self.isConnected = false
            self.boardName = nil
        }
    }
}

// MARK: - CBPeripheralDelegate

extension OpenChessBLEManager: CBPeripheralDelegate {
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services where service.uuid == serviceUUID {
            print("Found Open Chess service")
            peripheral.discoverCharacteristics([sensorCharUUID, commandCharUUID, stateCharUUID, ledCharUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            switch characteristic.uuid {
            case sensorCharUUID:
                sensorCharacteristic = characteristic
                peripheral.setNotify(true, for: characteristic)
                print("Subscribed to sensor notifications")
                
            case commandCharUUID:
                commandCharacteristic = characteristic
                print("Found command characteristic")
                
            case stateCharUUID:
                stateCharacteristic = characteristic
                peripheral.setNotify(true, for: characteristic)
                print("Subscribed to state notifications")
                
            case ledCharUUID:
                ledCharacteristic = characteristic
                print("Found LED characteristic")
                
            default:
                break
            }
        }
        
        // Request initial board state
        requestBoardState()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value,
              let value = String(data: data, encoding: .utf8) else { return }
        
        switch characteristic.uuid {
        case sensorCharUUID:
            processSensorEvent(value)
            
        case stateCharUUID:
            processOccupancySnapshot(value)
            
        default:
            print("Received data on \(characteristic.uuid): \(value)")
        }
    }
}
