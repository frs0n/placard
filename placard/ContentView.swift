import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

@main
struct PlacardApp: App {
    var body: some Scene {
        WindowGroup {
            PlacardRootView()
        }
    }
}

struct PlacardRootView: View {
    @State private var selection: AppTab = .browse

    var body: some View {
        TabView(selection: $selection) {
            Tab("Browse", systemImage: "square.grid.2x2", value: .browse) {
                WallpaperBrowserView()
            }

            Tab("Create", systemImage: "plus", value: .create) {
                CustomWallpaperView()
            }

            Tab("Library", systemImage: "rectangle.stack", value: .library) {
                InstalledWallpapersView()
            }
        }
        .tint(.accentColor)
    }
}

private enum AppTab: Hashable {
    case browse
    case create
    case library
}

struct WallpaperBrowserView: View {
    private static let importablePackageTypes: [UTType] = [.tendiesWallpaper]

    private let catalog: WallpaperCatalog

    @State private var category: WallpaperCategory = .custom
    @State private var loadState: CatalogLoadState = .idle
    @State private var query = ""
    @State private var sortOrder: WallpaperSortOrder = .random
    @State private var ordered: [Wallpaper] = []
    @State private var loadedCategory: WallpaperCategory?
    @State private var isImportingPackage = false
    @State private var importCoordinator = InstallCoordinator()

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
                Label("Unable to Load", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await load(category) } }
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
                switch loadState {
                case .idle, .loading:
                    WallpaperLoadingGrid(showsAuthor: category != .apple)
                case .loaded where !displayedWallpapers.isEmpty:
                    WallpaperGrid(
                        wallpapers: displayedWallpapers,
                        showsAuthor: category != .apple
                    )
                default:
                    EmptyView()
                }
            }
            .overlay { unavailableOverlay }
            .navigationTitle(category.title)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Category", selection: $category) {
                        ForEach(WallpaperCategory.allCases) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 190)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import Wallpaper", systemImage: "square.and.arrow.down") {
                        isImportingPackage = true
                    }
                    .labelStyle(.iconOnly)
                    .disabled(importCoordinator.state.isWorking)
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $sortOrder) {
                            ForEach(WallpaperSortOrder.allCases) { order in
                                Label(order.title, systemImage: order.symbol).tag(order)
                            }
                        }
                    } label: {
                        Label("Sort", systemImage: "arrow.up.arrow.down")
                    }
                }
            }
            .onChange(of: sortOrder) { _, _ in applyOrder() }
            .searchable(text: $query, prompt: "Search")
            .refreshable { await refresh() }
            .task(id: category) { await loadIfNeeded(category) }
            .fileImporter(
                isPresented: $isImportingPackage,
                allowedContentTypes: Self.importablePackageTypes
            ) { result in
                importCoordinator.importPackage(from: result)
            }
            .alert(
                "Unable to Import Wallpaper",
                isPresented: .init(
                    get: { importCoordinator.state.isTerminal },
                    set: { if !$0 { importCoordinator.reset() } }
                )
            ) {
                Button("OK", role: .cancel) { importCoordinator.reset() }
            } message: {
                Text(importCoordinator.state.message)
            }
            .alert(
                "Wallpaper Installed",
                isPresented: importLocationNoticePresented
            ) {
                Button("Don't Show Again") {
                    WallpaperLocationNotice.disable()
                    importCoordinator.continueAfterLocationNotice()
                }
                Button("Continue") {
                    importCoordinator.continueAfterLocationNotice()
                }
            } message: {
                Text("After the screen refreshes, open the system Add New Wallpaper page and find your wallpaper by name.")
            }
            .overlay {
                if importCoordinator.state == .respringing {
                    NeoSpringView()
                        .ignoresSafeArea()
                        .transition(.opacity)
                } else if importCoordinator.state.isWorking {
                    ProgressView(importCoordinator.state.message)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
            }
        }
    }

    private func applyOrder() {
        guard case .loaded(let wallpapers) = loadState else { return }
        ordered = sortOrder.apply(to: wallpapers)
    }

    private var importLocationNoticePresented: Binding<Bool> {
        Binding(
            get: { importCoordinator.state == .installed },
            set: { isPresented in
                if !isPresented {
                    importCoordinator.continueAfterLocationNotice()
                }
            }
        )
    }

    /// Initial load / category change: show the loading grid, then fetch.
    private func loadIfNeeded(_ targetCategory: WallpaperCategory) async {
        guard loadedCategory != targetCategory else { return }
        await load(targetCategory)
    }

    private func load(_ targetCategory: WallpaperCategory) async {
        loadState = .loading
        ordered = []
        await fetch(targetCategory)
    }

    /// Pull to refresh: keep the current content on screen while fetching so
    /// swapping to a loading state doesn't cancel the refresh task mid-request.
    private func refresh() async {
        await fetch(category)
    }

    private func fetch(_ targetCategory: WallpaperCategory) async {
        do {
            let wallpapers = try await catalog.fetch(targetCategory)
            guard targetCategory == category else { return }
            loadState = .loaded(wallpapers)
            loadedCategory = targetCategory
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

struct CustomWallpaperView: View {
    @State private var selectedVideo: PhotosPickerItem?
    @State private var draft: VideoWallpaperDraft?
    @State private var importedVideoURL: URL?
    @State private var isImportingVideo = false
    @State private var videoImportError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    ContentUnavailableView {
                        Label("Create Video Wallpaper", systemImage: "video.badge.plus")
                    } description: {
                        Text("Choose a vertical video to turn into a Lock Screen wallpaper.")
                    } actions: {
                        VStack(spacing: 10) {
                            PhotosPicker(selection: $selectedVideo, matching: .videos) {
                                Label("Choose Video", systemImage: "photo.on.rectangle")
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                            .disabled(isImportingVideo)

                            Text("Up to 12 seconds")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    VStack(spacing: 16) {
                        Link(destination: URL(string: "https://v.douyin.com/jIfvCCHjwFE")!) {
                            HStack(spacing: 14) {
                                Image("DeveloperAvatar")
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 52, height: 52)
                                    .clipShape(.circle)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Developer")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("SUSS")
                                        .font(.headline)
                                }

                                Spacer()
                                Image(systemName: "arrow.up.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                        .accessibilityLabel("Developer SUSS")

                        DisclosureGroup {
                            Image("DonationCode")
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(maxWidth: 260)
                                .clipShape(.rect(cornerRadius: 12))
                                .frame(maxWidth: .infinity)
                                .padding(.top, 8)
                        } label: {
                            Label("Thanks SUSS - WeChat Donation Code", systemImage: "cup.and.saucer.fill")
                                .font(.headline)
                        }
                        .padding(16)
                        .glassEffect(.regular, in: .rect(cornerRadius: 20))
                    }
                    .frame(maxWidth: 420)
                    .padding(.horizontal, 20)
                }
            }
            .navigationTitle("Create")
            .onChange(of: selectedVideo) { _, item in
                guard let item else { return }
                importVideo(item)
            }
            .sheet(item: $draft, onDismiss: cleanUpImportedVideo) { draft in
                VideoWallpaperDetailView(draft: draft)
            }
            .alert(
                "Unable to Import Video",
                isPresented: .init(
                    get: { videoImportError != nil },
                    set: { if !$0 { videoImportError = nil } }
                ),
                presenting: videoImportError
            ) { _ in
                Button("OK", role: .cancel) { videoImportError = nil }
            } message: {
                Text($0)
            }
            .overlay {
                if isImportingVideo {
                    ProgressView("Importing…")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .glassEffect(.regular, in: .rect(cornerRadius: 18))
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
