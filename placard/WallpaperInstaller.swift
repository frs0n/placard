import Foundation
import Observation
import ZIPFoundation

@MainActor
@Observable
final class InstallCoordinator {
    private(set) var state: InstallState = .idle
    private let installer = WallpaperInstaller()
    private var task: Task<Void, Never>?

    func install(_ wallpaper: Wallpaper) {
        guard !state.isWorking else { return }
        task?.cancel()
        state = .downloading
        task = Task {
            do {
                try await installer.install(wallpaper) { [weak self] phase in
                    self?.state = phase
                }
                state = .preparingRespring
                try await Task.sleep(for: .milliseconds(250))
                state = .respringing
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failure(error.localizedDescription)
            }
        }
    }

    func reset() {
        guard !state.isWorking else { return }
        state = .idle
    }
}

enum InstallState: Equatable, Sendable {
    case idle
    case downloading
    case unpacking
    case locatingPosterBoard
    case writing
    case preparingRespring
    case respringing
    case failure(String)

    var isWorking: Bool {
        switch self {
        case .downloading, .unpacking, .locatingPosterBoard, .writing,
             .preparingRespring, .respringing: true
        default: false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .failure: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .idle: ""
        case .downloading: String(localized: "Downloading…")
        case .unpacking: String(localized: "Unpacking…")
        case .locatingPosterBoard: String(localized: "Preparing…")
        case .writing: String(localized: "Installing…")
        case .preparingRespring: String(localized: "Preparing to refresh screen…")
        case .respringing: String(localized: "Refreshing screen…")
        case .failure(let message): message
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle, .failure: String(localized: "Install Wallpaper")
        default: String(localized: "Installing…")
        }
    }

}

private actor WallpaperInstaller {
    private let fileManager = FileManager.default
    private let maximumPackageBytes: Int64 = 250 * 1_024 * 1_024
    private let maximumExpandedBytes: UInt64 = 1_024 * 1_024 * 1_024

    func install(
        _ wallpaper: Wallpaper,
        progress: @MainActor @Sendable (InstallState) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw InstallError.deviceRequired
        #else
        guard BadQuery.isAvailable else { throw InstallError.unsupportedSystem }
        guard wallpaper.downloadURL.scheme == "https",
              wallpaper.downloadURL.pathExtension.lowercased() == "tendies" else {
            throw InstallError.invalidDownloadURL
        }

        let workspace = fileManager.temporaryDirectory
            .appending(path: "Placard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        await progress(.downloading)
        let packageURL = try await download(wallpaper.downloadURL, into: workspace)
        try Task.checkCancellation()

        await progress(.unpacking)
        let extractedURL = try extract(packageURL, into: workspace)
        let descriptorGroups = try findDescriptorGroups(in: extractedURL)
        guard !descriptorGroups.isEmpty else { throw InstallError.noDescriptors }
        for descriptors in descriptorGroups.values.flatMap({ $0 }) {
            try randomizeIdentifier(in: descriptors)
        }
        try Task.checkCancellation()

        await progress(.locatingPosterBoard)
        let appHash = try BadQuery.findPosterBoardHash()
        try Task.checkCancellation()

        await progress(.writing)
        var writtenPaths: [String] = []
        for (extensionID, descriptors) in descriptorGroups {
            writtenPaths += try BadQuery.writeDescriptors(
                appHash: appHash,
                extensionID: extensionID,
                descriptorFolders: descriptors
            )
        }
        InstalledWallpaperNameStore.record(name: wallpaper.name, paths: writtenPaths)
        #endif
    }

    private func download(_ remoteURL: URL, into workspace: URL) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200 else {
            throw InstallError.downloadFailed
        }

        let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0, Int64(fileSize) <= maximumPackageBytes else {
            throw InstallError.packageTooLarge
        }

        let destination = workspace.appending(path: "wallpaper.tendies")
        try fileManager.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private func extract(_ packageURL: URL, into workspace: URL) throws -> URL {
        let archive: Archive
        do {
            archive = try Archive(url: packageURL, accessMode: .read)
        } catch {
            throw InstallError.invalidPackage
        }
        var expandedBytes: UInt64 = 0
        var entryCount = 0
        for entry in archive {
            entryCount += 1
            expandedBytes += UInt64(entry.uncompressedSize)
            let components = NSString(string: entry.path).pathComponents
            guard !entry.path.hasPrefix("/"),
                  !components.contains(".."),
                  entry.type != .symlink,
                  entryCount <= 20_000,
                  expandedBytes <= maximumExpandedBytes else {
                throw InstallError.invalidPackage
            }
        }

        let destination = workspace.appending(path: "Extracted", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: packageURL, to: destination)
        return destination
    }

    private func findDescriptorGroups(in root: URL) throws -> [String: [URL]] {
        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else { throw InstallError.invalidPackage }

        var groups: [String: [URL]] = [:]
        for case let directory as URL in enumerator {
            let values = try directory.resourceValues(forKeys: Set(resourceKeys))
            guard values.isDirectory == true else { continue }
            if directory.lastPathComponent == "__MACOSX" {
                enumerator.skipDescendants()
                continue
            }
            let name = directory.lastPathComponent.lowercased()
            let extensionID: String?

            if name == "descriptors",
               let extensionsIndex = directory.pathComponents.lastIndex(of: "Extensions"),
               directory.pathComponents.indices.contains(extensionsIndex + 1) {
                extensionID = directory.pathComponents[extensionsIndex + 1]
            } else if ["descriptor", "descriptors", "ordered-descriptor", "ordered-descriptors"].contains(name) {
                extensionID = "com.apple.WallpaperKit.CollectionsPoster"
            } else if ["video-descriptor", "video-descriptors"].contains(name) {
                extensionID = "com.apple.PhotosUIPrivate.PhotosPosterProvider"
            } else {
                extensionID = nil
            }

            guard let extensionID else { continue }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isHiddenKey],
                options: [.skipsHiddenFiles]
            ).filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                    && $0.lastPathComponent != "__MACOSX"
            }
            if !children.isEmpty { groups[extensionID, default: []].append(contentsOf: children) }
            enumerator.skipDescendants()
        }
        return groups
    }

    private func randomizeIdentifier(in descriptor: URL) throws {
        let identifier = Int.random(in: 10_000...99_999)
        guard let enumerator = fileManager.enumerator(
            at: descriptor,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { throw InstallError.invalidPackage }

        for case let fileURL as URL in enumerator {
            guard (try fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                continue
            }
            switch fileURL.lastPathComponent {
            case "com.apple.posterkit.provider.descriptor.identifier":
                try Data(String(identifier).utf8).write(to: fileURL, options: .atomic)
            case "com.apple.posterkit.provider.contents.userInfo":
                try setPlistValue(identifier, key: "wallpaperRepresentingIdentifier", at: fileURL)
            case "Wallpaper.plist":
                try setPlistValue(identifier, key: "identifier", at: fileURL)
            default:
                continue
            }
        }
    }

    private func setPlistValue(_ value: Int, key: String, at url: URL) throws {
        let data = try Data(contentsOf: url)
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard var plist = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: &format
        ) as? [String: Any] else {
            throw InstallError.invalidPackage
        }
        plist[key] = value
        let updated = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: format,
            options: 0
        )
        try updated.write(to: url, options: .atomic)
    }
}

enum InstallError: LocalizedError {
    case deviceRequired
    case unsupportedSystem
    case invalidDownloadURL
    case downloadFailed
    case packageTooLarge
    case invalidPackage
    case noDescriptors

    var errorDescription: String? {
        switch self {
        case .deviceRequired: String(localized: "Please install wallpapers on a physical device.")
        case .unsupportedSystem: String(localized: "This system version is not supported.")
        case .invalidDownloadURL: String(localized: "The download URL is invalid.")
        case .downloadFailed: String(localized: "Download failed. Please try again later.")
        case .packageTooLarge: String(localized: "The wallpaper package is empty or too large.")
        case .invalidPackage: String(localized: "The wallpaper package is invalid or damaged.")
        case .noDescriptors: String(localized: "The wallpaper package contains no installable content.")
        }
    }
}
