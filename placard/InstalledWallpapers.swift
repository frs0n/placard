import Foundation
import Observation

struct InstalledWallpaper: Identifiable, Equatable, Sendable {
    enum Source: String, Equatable, Sendable {
        case configuration
        case galleryDescriptor
    }

    let posterUUID: String
    let name: String
    let providerIdentifier: String
    let descriptorIdentifier: String?
    let storagePath: String
    let source: Source
    let snapshotData: Data?
    let snapshotError: String?

    var id: String { "\(source.rawValue):\(posterUUID)" }

    var kindTitle: String { Self.kindTitle(for: providerIdentifier) }

    nonisolated static func defaultName(for provider: String) -> String {
        String(format: String(localized: "%@ Wallpaper"), kindTitle(for: provider))
    }

    nonisolated private static func kindTitle(for provider: String) -> String {
        switch provider {
        case "com.apple.PhotosUIPrivate.PhotosPosterProvider": String(localized: "Photos")
        case "com.apple.WallpaperKit.CollectionsPoster": String(localized: "Featured")
        case "com.apple.GradientPoster.GradientPosterExtension": String(localized: "Color")
        case "com.apple.EmojiPoster.EmojiPosterExtension": String(localized: "Emoji")
        case "com.apple.MercuryPoster": String(localized: "Astronomy")
        case let value where value.localizedCaseInsensitiveContains("weather"): String(localized: "Weather")
        case let value where value.localizedCaseInsensitiveContains("pride"): String(localized: "Pride")
        case let value where value.localizedCaseInsensitiveContains("unity"): String(localized: "Unity")
        default: "iOS"
        }
    }

    nonisolated static let preview = InstalledWallpaper(
        posterUUID: "00000000-0000-0000-0000-000000000001",
        name: "Cipher",
        providerIdentifier: "com.apple.WallpaperKit.CollectionsPoster",
        descriptorIdentifier: "48291",
        storagePath: "/preview/configurations/00000000-0000-0000-0000-000000000001",
        source: .configuration,
        snapshotData: nil,
        snapshotError: nil
    )
}

struct InstalledWallpaperCollection: Equatable, Sendable {
    let configurations: [InstalledWallpaper]
    let galleryDescriptors: [InstalledWallpaper]

    init(_ wallpapers: [InstalledWallpaper]) {
        configurations = wallpapers.filter { $0.source == .configuration }
        galleryDescriptors = wallpapers.filter { $0.source == .galleryDescriptor }
    }

    var isEmpty: Bool { configurations.isEmpty && galleryDescriptors.isEmpty }

    func items(for source: InstalledWallpaper.Source) -> [InstalledWallpaper] {
        switch source {
        case .configuration: configurations
        case .galleryDescriptor: galleryDescriptors
        }
    }
}

enum InstalledWallpaperNameStore {
    nonisolated private static let key = "InstalledWallpaperNames"

    nonisolated static func record(name: String, paths: [String]) {
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        for path in paths { names[canonical(path)] = name }
        UserDefaults.standard.set(names, forKey: key)
    }

    nonisolated static func namesByCanonicalPath() -> [String: String] {
        let names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        return names.reduce(into: [:]) { result, entry in
            result[canonical(entry.key)] = entry.value
        }
    }

    nonisolated static func remove(path: String) {
        var names = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        let target = canonical(path)
        names = names.filter { canonical($0.key) != target }
        UserDefaults.standard.set(names, forKey: key)
    }

    nonisolated private static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}

struct InstalledWallpaperLibrary: Sendable {
    var load: @Sendable () async throws -> [InstalledWallpaper]
    var delete: @Sendable (InstalledWallpaper) async throws -> Void

    nonisolated static let live = InstalledWallpaperLibrary(
        load: {
            try await PosterBoardAccess.shared.installedWallpapers()
        },
        delete: { wallpaper in
            try await PosterBoardAccess.shared.delete(wallpaper)
        }
    )

    nonisolated static let preview = InstalledWallpaperLibrary(
        load: { [.preview] },
        delete: { _ in }
    )
}

@MainActor
@Observable
final class InstalledWallpapersManager {
    enum State: Equatable {
        case idle
        case loading
        case loaded(InstalledWallpaperCollection)
        case failed(String)
        case deleting(Int)
        case preparingRespring
        case respringing
    }

    private(set) var state: State = .idle
    private let library: InstalledWallpaperLibrary

    init(library: InstalledWallpaperLibrary = .live) {
        self.library = library
    }

    func load() async {
        state = .loading
        do {
            state = .loaded(InstalledWallpaperCollection(try await library.load()))
        } catch is CancellationError {
            return
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func delete(_ wallpapers: [InstalledWallpaper]) {
        guard !wallpapers.isEmpty, !state.isWorking else { return }
        state = .deleting(wallpapers.count)
        Task {
            do {
                for wallpaper in wallpapers {
                    try await library.delete(wallpaper)
                }
                state = .preparingRespring
                try await Task.sleep(for: .milliseconds(250))
                state = .respringing
            } catch is CancellationError {
                await load()
            } catch {
                let nsError = error as NSError
                NSLog("[Placard] wallpaper deletion failed %@ (%ld): %@",
                      nsError.domain, nsError.code, nsError.localizedDescription)
                state = .failed(error.localizedDescription)
            }
        }
    }
}

extension InstalledWallpapersManager.State {
    var isWorking: Bool {
        switch self {
        case .deleting, .preparingRespring, .respringing: true
        default: false
        }
    }
}
