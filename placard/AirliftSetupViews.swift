import SwiftUI
import UIKit

struct AirliftPairingView: View {
    let running: Bool
    let pin: String?
    let error: String?
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Pair this iPhone")
                .font(.largeTitle.bold())
            Text("Start pairing, then open Settings › Privacy & Security › Developer Mode › Pair with Placard.")
                .foregroundStyle(.secondary)
            if let pin {
                Text(pin).font(.largeTitle.monospacedDigit())
            }
            if let error {
                Text(error).foregroundStyle(.red)
            }
            Spacer()
            Button(action: onStart) {
                if running {
                    ProgressView("Waiting for pairing…")
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Start pairing")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(running)
        }
        .padding(24)
    }
}

struct AirliftVPNView: View {
    let connectionError: String?
    let checking: Bool
    let onCheck: () -> Void
    let onPairAgain: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Spacer()
            Image(systemName: "network")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("Connect LocalDevVPN")
                .font(.largeTitle.bold())
            Text("Open LocalDevVPN, tap Connect, then return to Placard.")
                .foregroundStyle(.secondary)
            Button("Open LocalDevVPN", action: openLocalDevVPN)
                .buttonStyle(.bordered)
                .controlSize(.large)
            if let connectionError {
                Text(connectionError).foregroundStyle(.red)
                Button("Pair again", action: onPairAgain)
                    .font(.footnote)
            }
            Spacer()
            Button(action: onCheck) {
                if checking {
                    ProgressView("Checking connection…")
                        .frame(maxWidth: .infinity)
                } else {
                    Text("Check and enter")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(checking)
        }
        .padding(24)
    }

    private func openLocalDevVPN() {
        let appURL = URL(string: "localdevvpn://")!
        let storeURL = URL(string: "https://apps.apple.com/app/id6755608044")!
        UIApplication.shared.open(appURL) { opened in
            guard !opened else { return }
            DispatchQueue.main.async {
                UIApplication.shared.open(storeURL)
            }
        }
    }
}

#Preview("Pairing") {
    AirliftPairingView(running: false, pin: nil, error: nil, onStart: {})
}

#Preview("LocalDevVPN") {
    AirliftVPNView(connectionError: nil, checking: false, onCheck: {}, onPairAgain: {})
}
