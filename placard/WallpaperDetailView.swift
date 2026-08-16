import SwiftUI

struct WallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let wallpaper: Wallpaper
    let showsAuthor: Bool
    let transitionNamespace: Namespace.ID
    @State private var installer = InstallCoordinator()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                WallpaperHero(wallpaper: wallpaper, showsAuthor: showsAuthor)

                if let description = wallpaper.description, !description.isEmpty {
                    Text(description)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
            .frame(maxWidth: 500)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .safeAreaInset(edge: .bottom) {
            InstallBar(state: installer.state, onInstall: install)
        }
        .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") {
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .disabled(installer.state.isWorking)
            }
        }
        .interactiveDismissDisabled(installer.state.isWorking)
        .overlay {
            if installer.state == .respringing {
                NeoSpringView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    private func install() {
        installer.install(wallpaper)
    }
}

private struct WallpaperHero: View {
    let wallpaper: Wallpaper
    let showsAuthor: Bool

    var body: some View {
        RemoteWallpaperPreview(
            url: wallpaper.previewURL,
            aspectRatio: 0.72,
            playback: .animated
        )
            .overlay {
                LinearGradient(
                    colors: [.clear, .clear, .black.opacity(0.82)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(wallpaper.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    if showsAuthor, let authors = wallpaper.authors {
                        Text(authors)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.72))
                            .lineLimit(1)
                    }
                }
                .padding(20)
            }
            .overlay(alignment: .topLeading) {
                if let contest = wallpaper.contest {
                    Label(contest, systemImage: "trophy.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .glassEffect(.regular, in: .capsule)
                        .padding(14)
                }
            }
            .clipShape(.rect(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.16), lineWidth: 0.5)
            }
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
            .accessibilityElement(children: .combine)
    }
}

private struct InstallBar: View {
    let state: InstallState
    let onInstall: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            if state.isWorking || state.isTerminal {
                InstallStatus(state: state)
            }

            Button(action: onInstall) {
                Label(
                    state.buttonTitle,
                    systemImage: state.isWorking ? "hourglass" : "arrow.down.circle.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(state.isWorking)

            if state == .idle || state.isTerminal {
                Text("The screen will briefly refresh after installation.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct InstallStatus: View {
    let state: InstallState

    var body: some View {
        HStack(spacing: 8) {
            if state.isWorking {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Text(state.message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}
