import SwiftUI

/// Open Chess BLE App
///
/// A sample iOS app demonstrating BLE integration with Open Chess boards.
/// This app:
/// 1. Scans for Open Chess boards via BLE
/// 2. Connects to the board
/// 3. Receives sensor events (piece lift/place)
/// 4. Sends LED commands to highlight squares
/// 5. Displays the current board state
@main
struct OpenChessBLEApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
