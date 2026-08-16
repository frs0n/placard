import SwiftUI

@main
struct PlacardApp: App {
    var body: some Scene {
        WindowGroup {
            WallpaperBrowserView()
        }
    }
}

struct WallpaperBrowserView: View {
    private let catalog: WallpaperCatalog

    @State private var category: WallpaperCategory = .custom
    @State private var loadState: CatalogLoadState = .idle
    @State private var query = ""
    @State private var presentedSheet: BrowserSheet?
    @State private var installer = InstallCoordinator()

    init(catalog: WallpaperCatalog = .live) {
        self.catalog = catalog
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-PlacardOpenInstalledWallpapers") {
            _presentedSheet = State(initialValue: .installed)
        }
        #endif
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
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        presentedSheet = .installed
                    } label: {
                        Image(systemName: "rectangle.stack")
                    }
                    .accessibilityLabel("已安装壁纸")
                }
            }
            .sheet(item: $presentedSheet) { sheet in
                switch sheet {
                case .wallpaper(let wallpaper, let showsAuthor):
                    WallpaperDetailView(
                        wallpaper: wallpaper,
                        showsAuthor: showsAuthor,
                        installer: installer
                    )
                case .installed:
                    InstalledWallpapersView()
                }
            }
        }
    }

    private func select(_ wallpaper: Wallpaper) {
        installer.reset()
        presentedSheet = .wallpaper(wallpaper, showsAuthor: category != .apple)
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

private enum BrowserSheet: Identifiable {
    case wallpaper(Wallpaper, showsAuthor: Bool)
    case installed

    var id: String {
        switch self {
        case .wallpaper(let wallpaper, _): "wallpaper-\(wallpaper.id)"
        case .installed: "installed"
        }
    }
}

#Preview("Browser") {
    WallpaperBrowserView(catalog: .preview)
}

#Preview("Unavailable") {
    WallpaperBrowserView(catalog: .failingPreview)
}
