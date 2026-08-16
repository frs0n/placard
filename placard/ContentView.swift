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
    @State private var sortOrder: WallpaperSortOrder = .random
    @State private var ordered: [Wallpaper] = []
    @State private var selectedWallpaper: SelectedWallpaper?
    @State private var installer = InstallCoordinator()

    init(catalog: WallpaperCatalog = .live) {
        self.catalog = catalog
    }

    private var displayedWallpapers: [Wallpaper] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return ordered }
        return ordered.filter {
            $0.name.localizedCaseInsensitiveContains(trimmedQuery)
                || (category != .apple
                    && $0.authors?.localizedCaseInsensitiveContains(trimmedQuery) == true)
        }
    }

    @ViewBuilder
    private var unavailableOverlay: some View {
        switch loadState {
        case .failed(let message):
            ContentUnavailableView {
                Label("无法加载", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await load() } }
            }
        case .loaded where displayedWallpapers.isEmpty:
            ContentUnavailableView.search(text: query)
        default:
            EmptyView()
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Picker("分类", selection: $category) {
                    ForEach(WallpaperCategory.allCases) { category in
                        Text(category.title).tag(category)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

                switch loadState {
                case .idle, .loading:
                    WallpaperLoadingGrid(showsAuthor: category != .apple)
                case .loaded where !displayedWallpapers.isEmpty:
                    WallpaperGrid(
                        wallpapers: displayedWallpapers,
                        showsAuthor: category != .apple,
                        onSelect: select
                    )
                default:
                    EmptyView()
                }
            }
            .overlay { unavailableOverlay }
            .navigationTitle("壁纸")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("排序方式", selection: $sortOrder) {
                            ForEach(WallpaperSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.symbol).tag(order)
                            }
                        }
                    } label: {
                        Label("排序方式", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .onChange(of: sortOrder) { _, _ in applyOrder() }
            .searchable(text: $query, prompt: "搜索")
            .refreshable { await refresh() }
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

    private func applyOrder() {
        guard case .loaded(let wallpapers) = loadState else { return }
        ordered = sortOrder.apply(to: wallpapers)
    }

    /// Initial load / category change: show the loading grid, then fetch.
    private func load() async {
        loadState = .loading
        ordered = []
        await fetch()
    }

    /// Pull to refresh: keep the current content on screen while fetching so
    /// swapping to a loading state doesn't cancel the refresh task mid-request.
    private func refresh() async {
        await fetch()
    }

    private func fetch() async {
        do {
            let wallpapers = try await catalog.fetch(category)
            loadState = .loaded(wallpapers)
            applyOrder()
        } catch is CancellationError {
            return
        } catch let error as URLError where error.code == .cancelled {
            return
        } catch {
            // Only surface a hard failure when there's nothing already shown;
            // a failed refresh should quietly keep the existing wallpapers.
            if case .loaded = loadState { return }
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
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "video.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)

                VStack(spacing: 8) {
                    Text("视频动态壁纸")
                        .font(.title2.weight(.semibold))
                    Text("把你的视频变成锁定屏幕的动态壁纸。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Spacer()

                VStack(spacing: 12) {
                    PhotosPicker(selection: $selectedVideo, matching: .videos) {
                        Text("选择视频").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isImportingVideo)

                    Text("最长 12 秒，建议使用竖屏视频")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
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
                    ProgressView("正在导入…")
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

#Preview("Browser") {
    PlacardRootView()
}

#Preview("Unavailable") {
    WallpaperBrowserView(catalog: .failingPreview)
}
