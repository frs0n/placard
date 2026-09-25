import SwiftUI

/// Connects the existing setup screens to AirCard's on-device pairing host.
struct AirliftEntryView: View {
    @ObservedObject private var pairing = PairingController.shared
    @State private var paired = FileManager.default.fileExists(atPath: PairingController.pairingFilePath())
    @State private var connected = false
    @State private var checking = false
    @State private var pairingError: String?
    @State private var connectionError: String?

    var body: some View {
        if connected {
            PlacardRootView()
        } else if paired {
            AirliftVPNView(
                connectionError: connectionError, checking: checking,
                onCheck: checkConnection,
                onPairAgain: {
                    paired = false
                    pairingError = nil
                    connectionError = nil
                }
            )
        } else {
            AirliftPairingView(
                running: pairing.running, pin: pairing.pairingPIN,
                error: pairingError, onStart: startPairing
            )
        }
    }

    private func startPairing() {
        guard !pairing.running else { return }
        pairingError = nil
        Task {
            do {
                _ = try await pairing.startAndWait()
                paired = true
            } catch {
                pairingError = error.localizedDescription
            }
        }
    }

    private func checkConnection() {
        guard !checking else { return }
        checking = true
        connectionError = nil
        Task {
            defer { checking = false }
            do {
                _ = try await TendiesEngine.shared.detectPosterBoardContainer(
                    pairingPath: PairingController.pairingFilePath()
                )
                connected = true
            } catch {
                connectionError = error.localizedDescription
            }
        }
    }
}
