import SwiftUI
import PhotosUI

@main
struct PlacardApp: App {
    var body: some Scene {
        WindowGroup {
            PlacardRootView()
        }
    }
}

struct PlacardRootView: View {
    var body: some View {
        TabView {
            Tab("浏览", systemImage: "square.grid.2x2") {
                WallpaperBrowserView()
            }

            Tab("自定义", systemImage: "wand.and.stars") {
                CustomWallpaperView()
            }

            Tab("管理", systemImage: "rectangle.stack") {
                InstalledWallpapersView()
            }
        }
    }
}

struct WallpaperBrowserView: View {
    private let catalog: WallpaperCatalog

    @State private var category: WallpaperCategory = .custom
    @State private var loadState: CatalogLoadState = .idle
    @State private var query = ""
    @State private var selectedWallpaper: SelectedWallpaper?
    @State private var installer = InstallCoordinator()

    init(catalog: WallpaperCatalog = .live) {
        self.catalog = catalog
    }

    private var filteredWallpapers: [Wallpaper] {
        guard case .loaded(let wallpapers) = loadState else { return [] }
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return wallpapers }
        return wallpapers.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                || (category != .apple
                    && $0.authors?.localizedCaseInsensitiveContains(trimmedQuery) == true)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch loadState {
                case .idle, .loading:
                    WallpaperLoadingGrid(showsAuthor: category != .apple)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("无法载入壁纸", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("重试") { Task { await load() } }
                    }
                case .loaded:
                    if filteredWallpapers.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        WallpaperGrid(
                            wallpapers: filteredWallpapers,
                            showsAuthor: category != .apple,
                            onSelect: select
                        )
                    }
                }
            }
            .navigationTitle("壁纸")
            .safeAreaInset(edge: .top, spacing: 0) {
                Picker("分类", selection: $category) {
                    ForEach(WallpaperCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .background(.bar)
            }
            .searchable(text: $query, prompt: "名称或作者")
            .refreshable { await load() }
            .task(id: category) { await load() }
            .sheet(item: $selectedWallpaper) { selection in
                WallpaperDetailView(
                    wallpaper: selection.wallpaper,
                    showsAuthor: selection.showsAuthor,
                    installer: installer
                )
            }
        }
    }

    private func select(_ wallpaper: Wallpaper) {
        installer.reset()
        selectedWallpaper = SelectedWallpaper(
            wallpaper: wallpaper,
            showsAuthor: category != .apple
        )
    }

    private func load() async {
        loadState = .loading
        do {
            let wallpapers = try await catalog.fetch(category)
            loadState = .loaded(Array(wallpapers.reversed()))
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed(error.localizedDescription)
        }
    }

}

private enum CatalogLoadState: Equatable {
    case idle
    case loading
    case loaded([Wallpaper])
    case failed(String)

}

private struct SelectedWallpaper: Identifiable {
    let wallpaper: Wallpaper
    let showsAuthor: Bool

    var id: String { wallpaper.id }
}

struct CustomWallpaperView: View {
    @State private var selectedVideo: PhotosPickerItem?
    @State private var draft: VideoWallpaperDraft?
    @State private var importedVideoURL: URL?
    @State private var isImportingVideo = false
    @State private var videoImportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(spacing: 18) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 54, weight: .medium))
                            .foregroundStyle(.tint)
                            .symbolRenderingMode(.hierarchical)

                        VStack(spacing: 6) {
                            Text("用你的视频制作动态壁纸")
                                .font(.title2.weight(.semibold))
                            Text("选择视频后可以预览、命名并设置往返播放。")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }

                        PhotosPicker(selection: $selectedVideo, matching: .videos) {
                            Label("选择视频", systemImage: "photo.on.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(isImportingVideo)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 22))

                    VStack(alignment: .leading, spacing: 14) {
                        Text("视频壁纸")
                            .font(.headline)
                        CustomFeatureRow(
                            icon: "clock",
                            title: "最长 12 秒",
                            detail: "较短的视频生成更快，占用空间也更少。"
                        )
                        CustomFeatureRow(
                            icon: "arrow.left.arrow.right",
                            title: "支持往返播放",
                            detail: "在结尾反向播放，减少循环时的跳变。"
                        )
                        CustomFeatureRow(
                            icon: "rectangle.portrait",
                            title: "建议使用竖屏视频",
                            detail: "竖屏画面更适合锁定屏幕的显示比例。"
                        )
                    }
                }
                .padding(16)
            }
            .navigationTitle("自定义")
            .onChange(of: selectedVideo) { _, item in
                guard let item else { return }
                importVideo(item)
            }
            .sheet(item: $draft, onDismiss: cleanUpImportedVideo) { draft in
                VideoWallpaperDetailView(draft: draft)
            }
            .alert(
                "无法导入视频",
                isPresented: .init(
                    get: { videoImportError != nil },
                    set: { if !$0 { videoImportError = nil } }
                ),
                presenting: videoImportError
            ) { _ in
                Button("好", role: .cancel) { videoImportError = nil }
            } message: {
                Text($0)
            }
            .overlay {
                if isImportingVideo {
                    ProgressView("正在导入视频…")
                        .padding(20)
                        .background(.regularMaterial, in: .rect(cornerRadius: 16))
                }
            }
        }
    }

    private func importVideo(_ item: PhotosPickerItem) {
        isImportingVideo = true
        Task {
            defer {
                selectedVideo = nil
                isImportingVideo = false
            }
            do {
                guard let video = try await item.loadTransferable(type: ImportedVideo.self) else {
                    throw VideoWallpaperError.invalidVideo
                }
                importedVideoURL = video.url
                draft = VideoWallpaperDraft(url: video.url)
            } catch {
                videoImportError = error.localizedDescription
            }
        }
    }

    private func cleanUpImportedVideo() {
        guard let importedVideoURL else { return }
        try? FileManager.default.removeItem(at: importedVideoURL)
        self.importedVideoURL = nil
    }
}

private struct CustomFeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview("Browser") {
    PlacardRootView()
}

#Preview("Unavailable") {
    WallpaperBrowserView(catalog: .failingPreview)
}
