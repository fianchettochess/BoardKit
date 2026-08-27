# Open Chess BLE App

A sample iOS app demonstrating BLE integration with Open Chess boards.

## Features

- **BLE Scanning**: Discovers Open Chess boards via Bluetooth Low Energy
- **Connection Management**: Connects to and disconnects from the board
- **Sensor Events**: Receives real-time piece lift/place events
- **Board State**: Displays current occupancy snapshot
- **LED Control**: Highlights squares on the physical board
- **Interactive Board**: Tap squares to select them for LED control

## Requirements

- iOS 13.0+
- Xcode 12.0+
- Physical Open Chess board with BLE support (Arduino Nano RP2040 Connect)

## Setup

1. Open `OpenChessBLEApp.xcodeproj` in Xcode
2. Select your development team
3. Build and run on a physical iOS device (BLE doesn't work in simulator)

## Usage

1. **Power on** your Open Chess board
2. **Tap "Scan"** to discover nearby boards
3. **Select** your Open Chess board from the list
4. **View** the board state and sensor events
5. **Tap squares** on the interactive board to select them
6. **Tap "Highlight Selected"** to light up those squares on the physical board

## Architecture

### OpenChessBLEManager

The core BLE manager handles:

- **CBCentralManager**: Manages BLE scanning and connections
- **CBPeripheral**: Communicates with the Open Chess board
- **Characteristics**: Reads sensor events, sends commands

### Key UUIDs

| Characteristic | UUID | Purpose |
|----------------|------|---------|
| Service | `19B10000-E8F2-537E-4F6C-D104768A1214` | Open Chess service |
| Sensor | `19B10001-...` | Board → Host (notify) |
| Command | `19B10002-...` | Host → Board (write) |
| State | `19B10003-...` | Occupancy snapshot (notify) |
| LED | `19B10004-...` | LED control (write) |

### Protocol Messages

**Board → Host:**
- `SE:<square><state>` - Sensor event (L=lift, P=place)
- `OC:<64 bits>` - Occupancy snapshot
- `CONNECTED` - Connection established
- `READY` - Board ready

**Host → Board:**
- `GETSTATE` - Request occupancy snapshot
- `NEWGAME` - Start new game
- `SET:<sq1>,<sq2>,...` - Set LEDs
- `COLOR:<sq>R<r>G<g>B<b>` - Set LED color
- `CLEAR` - Clear all LEDs

## Integration with BoardKit

This app demonstrates the same BLE protocol that the `OpenChessAdapter` in BoardKit supports. You can use the adapter in your own apps by:

```swift
import OpenChessAdapter

// Create adapter
let adapter = OpenChessAdapter()

// Parse sensor events
let events = adapter.feed(bytes: sensorData)

// Encode commands
let command = adapter.encode(.indicateSquares(["e2", "e4"], style: .highlight))
```

## Next Steps

- [ ] Add game recording and PGN export
- [ ] Integrate with Chess.com/Lichess API
- [ ] Add clock synchronization
- [ ] Implement move validation display
- [ ] Add opening book suggestions
