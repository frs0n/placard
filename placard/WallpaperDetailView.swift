import SwiftUI

struct WallpaperDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let wallpaper: Wallpaper
    let showsAuthor: Bool
    let installer: InstallCoordinator

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    RemoteWallpaperPreview(url: wallpaper.previewURL, aspectRatio: 0.72)
                        .frame(maxWidth: 520)
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 20))

                    WallpaperMetadata(wallpaper: wallpaper, showsAuthor: showsAuthor)
                }
                .padding(16)
            }
            .safeAreaInset(edge: .bottom) {
                InstallBar(state: installer.state, onInstall: install)
            }
            .navigationTitle("预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成", action: dismiss.callAsFunction)
                }
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

private struct WallpaperMetadata: View {
    let wallpaper: Wallpaper
    let showsAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(wallpaper.name)
                .font(.title2.weight(.semibold))
            if showsAuthor, let authors = wallpaper.authors {
                Text(authors).foregroundStyle(.secondary)
            }
            if let description = wallpaper.description, !description.isEmpty {
                Text(description)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            if let contest = wallpaper.contest {
                Text(contest)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                Text(state.buttonTitle)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(state.isWorking)

            if state == .idle || state.isTerminal {
                Text("写入完成后会使用 NeoSpring 刷新 SpringBoard，屏幕将短暂变黑。")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(.bar)
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
