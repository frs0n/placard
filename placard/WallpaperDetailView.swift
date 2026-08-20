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
                    if isCancellable {
                        installer.cancel()
                    }
                    dismiss()
                }
                .labelStyle(.iconOnly)
                .disabled(installer.state.isWorking && !isCancellable)
            }
        }
        .interactiveDismissDisabled(installer.state.isWorking && !isCancellable)
        .onDisappear {
            if isCancellable {
                installer.cancel()
            }
        }
        .alert(
            "Wallpaper Installed",
            isPresented: locationNoticePresented
        ) {
            Button("Don't Show Again") {
                WallpaperLocationNotice.disable()
                installer.continueAfterLocationNotice()
            }
            Button("Continue") {
                installer.continueAfterLocationNotice()
            }
        } message: {
            Text("After the screen refreshes, open the system Add New Wallpaper page and find your wallpaper by name.")
        }
        .overlay {
            if installer.state == .respringing {
                NeoSpringView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.3), value: installPhaseKey)
    }

    private func install() {
        installer.install(wallpaper)
    }

    private var isCancellable: Bool {
        if case .downloading = installer.state { return true }
        return false
    }

    /// Ignores the download fraction so per-byte progress updates don't animate the whole view.
    private var installPhaseKey: String {
        switch installer.state {
        case .idle: "idle"
        case .downloading: "downloading"
        case .importing: "importing"
        case .unpacking: "unpacking"
        case .locatingPosterBoard: "locating"
        case .writing: "writing"
        case .installed: "installed"
        case .preparingRespring: "preparingRespring"
        case .respringing: "respringing"
        case .failure: "failure"
        }
    }

    private var locationNoticePresented: Binding<Bool> {
        Binding(
            get: { installer.state == .installed },
            set: { isPresented in
                if !isPresented {
                    installer.continueAfterLocationNotice()
                }
            }
        )
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

/// A single button that carries every state: the download fills it from the leading edge,
/// later phases swap only the label, so the bar never changes size.
private struct InstallBar: View {
    let state: InstallState
    let onInstall: () -> Void

    private var downloadFraction: Double? {
        if case .downloading(let progress) = state { return progress }
        return nil
    }

    var body: some View {
        VStack(spacing: 8) {
            Button(action: onInstall) {
                InstallButtonLabel(state: state)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
            .disabled(state.isWorking)
            .overlay {
                if let downloadFraction {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(.white.opacity(0.24))
                            .frame(width: proxy.size.width * downloadFraction)
                            .animation(.linear(duration: 0.2), value: downloadFraction)
                    }
                    .clipShape(.capsule)
                    .allowsHitTesting(false)
                }
            }

            if case .failure(let message) = state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }
}

private struct InstallButtonLabel: View {
    let state: InstallState

    var body: some View {
        HStack(spacing: 8) {
            leadingIcon
            Text(title)
                .lineLimit(1)
                .monospacedDigit()
        }
        .fontWeight(.semibold)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        switch state {
        case .downloading:
            Image(systemName: "arrow.down.circle.fill")
        case .importing, .unpacking, .locatingPosterBoard, .writing,
             .preparingRespring, .respringing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .installed:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "arrow.clockwise")
        case .idle:
            Image(systemName: "arrow.down.circle.fill")
        }
    }

    private var title: String {
        switch state {
        case .idle, .failure:
            state.buttonTitle
        case .downloading(let progress):
            progress.formatted(.percent.precision(.fractionLength(0)))
        case .installed:
            String(localized: "Installed")
        default:
            state.message
        }
    }
}
