import SwiftUI

/// Main content view for the Open Chess BLE app.
///
/// Displays:
/// - Connection status
/// - Scan/connect button
/// - Board name when connected
/// - Last sensor event
/// - Interactive chessboard
/// - LED control buttons
struct ContentView: View {
    @StateObject private var bleManager = OpenChessBLEManager()
    @State private var selectedSquares: Set<String> = []
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Connection Status
                connectionStatusView
                
                // Control Buttons
                controlButtonsView
                
                // Last Event
                if let event = bleManager.lastEvent {
                    Text("Last Event: \(event)")
                        .font(.headline)
                        .foregroundColor(.blue)
                }
                
                // Chessboard
                chessboardView
                
                // LED Control
                ledControlView
                
                Spacer()
            }
            .navigationTitle("Open Chess BLE")
            .padding()
        }
    }
    
    // MARK: - Connection Status View
    
    private var connectionStatusView: some View {
        VStack(spacing: 10) {
            HStack {
                Circle()
                    .fill(bleManager.isConnected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)
                
                Text(bleManager.isConnected ? "Connected" : "Disconnected")
                    .font(.headline)
            }
            
            if let name = bleManager.boardName {
                Text("Board: \(name)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            
            if bleManager.isScanning {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(10)
    }
    
    // MARK: - Control Buttons View
    
    private var controlButtonsView: some View {
        HStack(spacing: 20) {
            if bleManager.isConnected {
                Button(action: { bleManager.disconnect() }) {
                    Label("Disconnect", systemImage: "xmark.circle")
                        .foregroundColor(.red)
                }
                
                Button(action: { bleManager.requestBoardState() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .foregroundColor(.blue)
                }
                
                Button(action: { bleManager.startNewGame() }) {
                    Label("New Game", systemImage: "plus.circle")
                        .foregroundColor(.green)
                }
            } else {
                Button(action: {
                    if bleManager.isScanning {
                        bleManager.stopScanning()
                    } else {
                        bleManager.startScanning()
                    }
                }) {
                    Label(bleManager.isScanning ? "Stop Scan" : "Scan",
                          systemImage: bleManager.isScanning ? "stop.circle" : "magnifyingglass")
                        .foregroundColor(.blue)
                }
            }
        }
        .buttonStyle(.bordered)
    }
    
    // MARK: - Chessboard View
    
    private var chessboardView: some View {
        VStack(spacing: 0) {
            // File labels (a-h)
            HStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { col in
                    Text(String(UnicodeScalar(UInt8(97 + col))))
                        .frame(width: 40, height: 20)
                        .font(.caption)
                }
            }
            
            // Board squares
            ForEach((0..<8).reversed(), id: \.self) { row in
                HStack(spacing: 0) {
                    // Rank label
                    Text("\(row + 1)")
                        .frame(width: 20, height: 40)
                        .font(.caption)
                    
                    ForEach(0..<8, id: \.self) { col in
                        let square = "\(String(UnicodeScalar(UInt8(97 + col))))\(row + 1)"
                        let isOccupied = bleManager.occupancySnapshot[row * 8 + col]
                        let isSelected = selectedSquares.contains(square)
                        
                        Rectangle()
                            .fill(squareColor(row: row, col: col, isOccupied: isOccupied, isSelected: isSelected))
                            .frame(width: 40, height: 40)
                            .border(Color.gray, width: 0.5)
                            .onTapGesture {
                                toggleSquareSelection(square)
                            }
                    }
                }
            }
        }
    }
    
    // MARK: - LED Control View
    
    private var ledControlView: some View {
        VStack(spacing: 10) {
            Text("LED Control")
                .font(.headline)
            
            HStack(spacing: 10) {
                Button(action: {
                    bleManager.setLEDs(squares: Array(selectedSquares))
                }) {
                    Label("Highlight Selected", systemImage: "lightbulb")
                }
                .buttonStyle(.bordered)
                .disabled(selectedSquares.isEmpty)
                
                Button(action: {
                    bleManager.clearLEDs()
                    selectedSquares.removeAll()
                }) {
                    Label("Clear All", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
            }
            
            Text("Selected: \(selectedSquares.sorted().joined(separator: ", "))")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Helper Methods
    
    private func squareColor(row: Int, col: Int, isOccupied: Bool, isSelected: Bool) -> Color {
        let isLightSquare = (row + col) % 2 == 0
        
        if isSelected {
            return .blue.opacity(0.5)
        } else if isOccupied {
            return isLightSquare ? Color(red: 0.8, green: 0.9, blue: 1.0) : Color(red: 0.4, green: 0.6, blue: 0.8)
        } else {
            return isLightSquare ? .white : .gray.opacity(0.3)
        }
    }
    
    private func toggleSquareSelection(_ square: String) {
        if selectedSquares.contains(square) {
            selectedSquares.remove(square)
        } else {
            selectedSquares.insert(square)
        }
    }
}

// MARK: - Preview

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
