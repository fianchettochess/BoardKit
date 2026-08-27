# Open Chess BLE Integration Guide

This guide explains how to integrate Open Chess boards with the BoardKit package via Bluetooth Low Energy (BLE).

## Overview

The Open Chess board uses an Arduino Nano RP2040 Connect with a u-blox NINA-W102 module that supports both WiFi and BLE. This guide covers:

1. Firmware modifications to add BLE support
2. BoardKit adapter integration
3. Mobile/desktop app development

## Hardware Requirements

- Arduino Nano RP2040 Connect (or compatible board with NINA-W102)
- Open Chess board hardware (sensors, LEDs, etc.)
- BLE-capable host device (iOS 13+, Android 6+, macOS, Windows 10+)

## Firmware BLE Support

### BLE Service Architecture

The Open Chess BLE service uses a custom GATT profile:

```
Open Chess Service (UUID: 19B10000-E8F2-537E-4F6C-D104768A1214)
├── Sensor Characteristic (UUID: 19B10001-...)
│   ├── Properties: Read, Notify
│   ├── Board → Host: Sensor events (piece lift/place)
│   └── Format: "SE:<square><state>" (e.g., "SE:e2L", "SE:e4P")
│
├── Command Characteristic (UUID: 19B10002-...)
│   ├── Properties: Write
│   ├── Host → Board: Commands
│   └── Format: "CMD:GETSTATE", "CMD:NEWGAME", "LED:e2,e4", etc.
│
├── State Characteristic (UUID: 19B10003-...)
│   ├── Properties: Read, Notify
│   ├── Board → Host: Occupancy snapshot
│   └── Format: "OC:<64 bits>" (64 chars of '0'/'1')
│
└── LED Characteristic (UUID: 19B10004-...)
    ├── Properties: Write
    ├── Host → Board: LED control
    └── Format: "SET:e2,e4", "COLOR:e4R255G0B0", "CLEAR"
```

### Firmware Implementation

The BLE support is implemented in `ble_manager.h` and `ble_manager.cpp`:

```cpp
// Enable BLE in OpenChess.ino
#define ENABLE_BLE

// Include BLE manager
#include "ble_manager.h"

// Initialize in setup()
BLEManager bleManager(&boardDriver);
bleManager.begin();

// Handle in loop()
bleManager.handleConnection();
```

### Building the Firmware

1. Install Arduino IDE 2.0+
2. Install board support: `Arduino Nano RP2040 Connect`
3. Install libraries:
   - `ArduinoBLE` (for BLE support)
   - `Adafruit NeoPixel` v1.14 (for LEDs)
   - `WiFiNINA` (for WiFi, optional)
4. Open `OpenChess.ino`
5. Uncomment `#define ENABLE_BLE`
6. Select board: `Arduino Nano RP2040 Connect`
7. Upload

## BoardKit Integration

### BLE Transport Layer

The `OpenChessAdapter` in BoardKit provides BLE-specific constants and helpers:

```swift
import OpenChessAdapter

// BLE service and characteristic UUIDs
let serviceUUID = OpenChessBLE.serviceUUID
let sensorCharUUID = OpenChessBLE.sensorCharUUID
let commandCharUUID = OpenChessBLE.commandCharUUID
let stateCharUUID = OpenChessBLE.stateCharUUID
let ledCharUUID = OpenChessBLE.ledCharUUID

// Create commands
let setStateCommand = OpenChessAdapter.bleRequestState()
let setLEDsCommand = OpenChessAdapter.bleSetLEDs(squares: ["e2", "e4"])
let setColorCommand = OpenChessAdapter.bleSetLEDColor(square: "e4", r: 255, g: 0, b: 0)
let clearCommand = OpenChessAdapter.bleClearLEDs()
```

### Platform-Specific BLE Implementation

#### iOS/macOS (CoreBluetooth)

```swift
import CoreBluetooth

class OpenChessBLEManager: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var centralManager: CBCentralManager!
    var openChessPeripheral: CBPeripheral?
    
    // Service and characteristic UUIDs
    let serviceUUID = CBUUID(string: OpenChessBLE.serviceUUID)
    let sensorCharUUID = CBUUID(string: OpenChessBLE.sensorCharUUID)
    let commandCharUUID = CBUUID(string: OpenChessBLE.commandCharUUID)
    
    func startScan() {
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: nil)
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        if OpenChessConnection.isOpenChessBLE(name: peripheral.name ?? "") {
            openChessPeripheral = peripheral
            centralManager.stopScan()
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([sensorCharUUID, commandCharUUID], for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard let data = characteristic.value,
              let event = String(data: data, encoding: .utf8) else { return }
        
        // Parse sensor event
        if event.hasPrefix("SE:") {
            let square = String(event.dropFirst(3).prefix(2))
            let state = event.last
            let isLift = state == "L"
            
            // Emit BoardEvent
            let boardEvent = BoardEvent.squareSensed(square: square, isLift: isLift, piece: nil)
            // Process event...
        }
    }
    
    func sendCommand(_ command: Data) {
        guard let peripheral = openChessPeripheral,
              let characteristic = peripheral.services?
                .first(where: { $0.uuid == serviceUUID })?
                .characteristics?
                .first(where: { $0.uuid == commandCharUUID }) else { return }
        
        peripheral.writeValue(command, for: characteristic, type: .withResponse)
    }
}
```

#### Android (SkipFuse or Android BLE)

```kotlin
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothManager

class OpenChessBLEManager(context: Context) {
    private val bluetoothManager = context.getSystemService(BluetoothManager::class.java)
    private val bluetoothAdapter = bluetoothManager?.adapter
    private var bluetoothGatt: BluetoothGatt? = null
    
    companion object {
        val SERVICE_UUID = UUID.fromString(OpenChessBLE.serviceUUID)
        val SENSOR_CHAR_UUID = UUID.fromString(OpenChessBLE.sensorCharUUID)
        val COMMAND_CHAR_UUID = UUID.fromString(OpenChessBLE.commandCharUUID)
    }
    
    fun connect(device: BluetoothDevice) {
        bluetoothGatt = device.connectGatt(context, false, object : BluetoothGattCallback() {
            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
                val service = gatt.getService(SERVICE_UUID)
                val sensorChar = service?.getCharacteristic(SENSOR_CHAR_UUID)
                gatt.setCharacteristicNotification(sensorChar, true)
            }
            
            override fun onCharacteristicChanged(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic) {
                val event = String(characteristic.value)
                // Parse and process sensor event
            }
        })
    }
    
    fun sendCommand(command: String) {
        val service = bluetoothGatt?.getService(SERVICE_UUID)
        val commandChar = service?.getCharacteristic(COMMAND_CHAR_UUID)
        commandChar?.value = command.toByteArray()
        bluetoothGatt?.writeCharacteristic(commandChar)
    }
}
```

## Protocol Reference

### Board → Host Events

| Code | Format | Description |
|------|--------|-------------|
| SE | `SE:<square><state>` | Sensor event (L=lift, P=place) |
| OC | `OC:<64 bits>` | Occupancy snapshot |
| MV | `MV:<from><to>` | Move executed |
| IV | `IV:<reason>` | Invalid move |
| CONNECTED | `CONNECTED` | BLE connection established |
| READY | `READY` | Board ready |
| NEWGAME | `NEWGAME` | New game started |

### Host → Board Commands

| Code | Format | Description |
|------|--------|-------------|
| GETSTATE | `GETSTATE` | Request occupancy snapshot |
| NEWGAME | `NEWGAME` | Start new game |
| LED | `LED:<sq1>,<sq2>,...` | Set LEDs (white) |
| LEDC | `LEDC:<sq><r><g><b>` | Set LED color |
| CLEAR | `CLEAR` | Clear all LEDs |

## Testing

### Using nRF Connect (iOS/Android)

1. Install nRF Connect app
2. Power on Open Chess board
3. Scan for BLE devices
4. Look for "OpenChess" device
5. Connect and explore services
6. Write commands to command characteristic
7. Subscribe to sensor characteristic notifications

### Using LightBlue (iOS)

1. Install LightBlue app
2. Scan for Open Chess board
3. Connect and test characteristics
4. Write commands and observe responses

## Troubleshooting

### Board Not Advertising

1. Check that `#define ENABLE_BLE` is uncommented
2. Verify ArduinoBLE library is installed
3. Check Serial Monitor for BLE initialization errors
4. Ensure board is not already connected to another central

### Connection Fails

1. Check BLE permissions on host device
2. Verify service UUID matches between firmware and app
3. Try restarting the board
4. Check for interference from other BLE devices

### No Sensor Events

1. Verify sensors are working (run Sensor Test mode first)
2. Check that BLE notifications are enabled
3. Monitor Serial output for debug messages
4. Verify characteristic UUIDs match

## Next Steps

1. **Test with physical hardware** once boards are available
2. **Implement mobile app** for game recording and analysis
3. **Add Chess.com/Lichess integration** via BLE
4. **Implement clock synchronization** for tournament play
5. **Add game replay functionality** via BLE

## Contributing

Contributions welcome! Areas for enhancement:

- Mobile app development (iOS/Android)
- Desktop app integration (macOS/Windows)
- Chess.com/Lichess API integration
- Tournament management features
- Game recording and analysis
- Opening book integration
