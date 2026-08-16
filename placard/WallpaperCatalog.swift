import Foundation

enum WallpaperCategory: String, CaseIterable, Identifiable, Sendable {
    case custom
    case apple

    var id: Self { self }

    var title: String {
        switch self {
        case .custom: "互动"
        case .apple: "Apple"
        }
    }
}

enum WallpaperSortOrder: String, CaseIterable, Identifiable, Sendable {
    case random
    case newest
    case oldest

    var id: Self { self }

    var title: String {
        switch self {
        case .random: "随机"
        case .newest: "最新"
        case .oldest: "最早"
        }
    }

    var symbol: String {
        switch self {
        case .random: "shuffle"
        case .newest: "arrow.up"
        case .oldest: "arrow.down"
        }
    }

    /// Reorders the catalog (as-fetched: oldest first) to match this option.
    func apply(to wallpapers: [Wallpaper]) -> [Wallpaper] {
        switch self {
        case .random: wallpapers.shuffled()
        case .newest: wallpapers.reversed()
        case .oldest: wallpapers
        }
    }
}

struct Wallpaper: Codable, Identifiable, Equatable, Sendable {
    let remoteID: Int?
    let name: String
    let description: String?
    let url: String
    let preview: String
    let authors: String?
    let contest: String?

    var id: String { url }
    nonisolated var downloadURL: URL { WallpaperCatalog.assetBaseURL.appending(path: url) }
    nonisolated var previewURL: URL { WallpaperCatalog.assetBaseURL.appending(path: preview) }

    enum CodingKeys: String, CodingKey {
        case remoteID = "id"
        case name, description, url, preview, authors, contest
    }

    nonisolated static let placeholder = Wallpaper(
        remoteID: nil,
        name: "Wallpaper",
        description: nil,
        url: "placeholder.tendies",
        preview: "placeholder.png",
        authors: "Author",
        contest: nil
    )

    nonisolated static let previewFixture = Wallpaper(
        remoteID: 1,
        name: "Cipher",
        description: "Decoding…",
        url: "wallpapers/custom/Cipher.tendies",
        preview: "previews/custom/gifs/Cipher.gif",
        authors: "@mightycooldude12",
        contest: "🏆 1st Place"
    )
}

struct WallpaperCatalog: Sendable {
    nonisolated static let assetBaseURL = URL(string: "https://raw.githubusercontent.com/SerStars/nugget-wallpapers/main/")!

    var fetch: @Sendable (WallpaperCategory) async throws -> [Wallpaper]

    static let live = WallpaperCatalog { category in
        let url = assetBaseURL.appending(path: "wallpapers-\(category.rawValue).json")
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadRevalidatingCacheData

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw CatalogError.invalidResponse
        }
        return try JSONDecoder().decode([Wallpaper].self, from: data)
    }

    static let preview = WallpaperCatalog { _ in
        let second = Wallpaper(
            remoteID: 2,
            name: "Rolling Hills",
            description: "boink boink boink",
            url: "wallpapers/custom/RollingHills.tendies",
            preview: "previews/custom/gifs/RollingHills.gif",
            authors: "@i.mes",
            contest: nil
        )
        return [.previewFixture, second]
    }

    static let failingPreview = WallpaperCatalog { _ in
        throw CatalogError.invalidResponse
    }
}

enum CatalogError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "暂时无法获取壁纸，请稍后再试。" }
}
