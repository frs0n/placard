import Foundation
import Observation
import OSLog
import ZIPFoundation

nonisolated private let installerLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Placard",
    category: "WallpaperInstaller"
)

enum WallpaperLocationNotice {
    static let preferenceKey = "ShowWallpaperLocationNotice"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: preferenceKey) as? Bool ?? true
    }

    static func disable() {
        UserDefaults.standard.set(false, forKey: preferenceKey)
    }
}

@MainActor
@Observable
final class InstallCoordinator {
    private(set) var state: InstallState = .idle
    private let installer = WallpaperInstaller()
    private var task: Task<Void, Never>?

    func install(_ wallpaper: Wallpaper) {
        guard !state.isWorking else { return }
        task?.cancel()
        state = .downloading(0)
        task = Task { [self] in
            do {
                try await installer.install(wallpaper) { [weak self] phase in
                    self?.state = phase
                }
                finishInstallation()
            } catch is CancellationError {
                state = .idle
            } catch {
                reportInstallFailure(error)
                state = .failure(error.localizedDescription)
            }
        }
    }

    func install(packagesAt packageURLs: [URL]) {
        guard !state.isWorking else { return }
        task?.cancel()
        state = .importing
        task = Task {
            do {
                for packageURL in packageURLs {
                    try Task.checkCancellation()
                    let hasSecurityScopedAccess = packageURL.startAccessingSecurityScopedResource()
                    defer {
                        if hasSecurityScopedAccess {
                            packageURL.stopAccessingSecurityScopedResource()
                        }
                    }

                    try await installer.install(packageAt: packageURL) { [weak self] phase in
                        self?.state = phase
                    }
                }

                finishInstallation()
            } catch is CancellationError {
                state = .idle
            } catch {
                reportInstallFailure(error)
                state = .failure(error.localizedDescription)
            }
        }
    }

    func reset() {
        guard !state.isWorking else { return }
        state = .idle
    }

    func cancel() {
        guard case .downloading = state else { return }
        task?.cancel()
        task = nil
        state = .idle
    }

    func continueAfterLocationNotice() {
        guard state == .installed else { return }
        task = Task {
            state = .preparingRespring
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            state = .respringing
        }
    }

    private func finishInstallation() {
        state = .installed
        if !WallpaperLocationNotice.isEnabled {
            continueAfterLocationNotice()
        }
    }

    private func reportInstallFailure(_ error: Error) {
        let nsError = error as NSError
        let diagnostic = "Installation failed: \(String(reflecting: error)); domain=\(nsError.domain); code=\(nsError.code); userInfo=\(nsError.userInfo)"
        installerLogger.error(
            "\(diagnostic, privacy: .public)"
        )
    }
}

enum InstallState: Equatable, Sendable {
    case idle
    case downloading(Double)
    case importing
    case unpacking
    case locatingPosterBoard
    case writing
    case installed
    case preparingRespring
    case respringing
    case failure(String)

    var isWorking: Bool {
        switch self {
        case .downloading, .importing, .unpacking, .locatingPosterBoard, .writing,
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
        case .downloading(let progress):
            String(localized: "Downloading…") + " \(progress.formatted(.percent.precision(.fractionLength(0))))"
        case .importing: String(localized: "Importing wallpaper…")
        case .unpacking: String(localized: "Unpacking…")
        case .locatingPosterBoard: String(localized: "Preparing…")
        case .writing: String(localized: "Installing…")
        case .installed: String(localized: "Wallpaper Installed")
        case .preparingRespring: String(localized: "Preparing to refresh screen…")
        case .respringing: String(localized: "Refreshing screen…")
        case .failure(let message): message
        }
    }

    var buttonTitle: String {
        switch self {
        case .idle: String(localized: "Install Wallpaper")
        case .failure: String(localized: "Try Again")
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
        progress: @escaping @MainActor @Sendable (InstallState) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw InstallError.deviceRequired
        #else
        guard WorseQuery.isAvailable else { throw InstallError.unsupportedSystem }
        guard wallpaper.downloadURL.scheme == "https",
              wallpaper.downloadURL.pathExtension.lowercased() == "tendies" else {
            throw InstallError.invalidDownloadURL
        }

        let workspace = fileManager.temporaryDirectory
            .appending(path: "Placard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        await progress(.downloading(0))
        let packageURL = try await downloadPackage(from: wallpaper.downloadCandidates, into: workspace) { fraction in
            Task { @MainActor in
                progress(.downloading(fraction))
            }
        }
        try Task.checkCancellation()

        await progress(.unpacking)
        let extractedURL = try extract(packageURL, into: workspace)
        let descriptorGroups = try findDescriptorGroups(in: extractedURL)
        guard !descriptorGroups.isEmpty else { throw InstallError.noDescriptors }
        for descriptors in descriptorGroups.values.flatMap({ $0 })
            where shouldRandomizeIdentifier(in: descriptors) {
            try randomizeIdentifier(in: descriptors)
        }
        try Task.checkCancellation()

        await progress(.locatingPosterBoard)
        let appHash = try WorseQuery.findPosterBoardHash()
        try Task.checkCancellation()

        await progress(.writing)
        var writtenPaths: [String] = []
        for (extensionID, descriptors) in descriptorGroups {
            writtenPaths += try WorseQuery.writeDescriptors(
                appHash: appHash,
                extensionID: extensionID,
                descriptorFolders: descriptors
            )
        }
        InstalledWallpaperNameStore.record(name: wallpaper.name, paths: writtenPaths)
        #endif
    }

    func install(
        packageAt sourceURL: URL,
        progress: @MainActor @Sendable (InstallState) -> Void
    ) async throws {
        #if targetEnvironment(simulator)
        throw InstallError.deviceRequired
        #else
        guard WorseQuery.isAvailable else { throw InstallError.unsupportedSystem }
        guard sourceURL.pathExtension.lowercased() == "tendies" else {
            throw InstallError.unsupportedPackageType
        }

        let workspace = fileManager.temporaryDirectory
            .appending(path: "Placard-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }

        let packageURL = try copyImportedPackage(sourceURL, into: workspace)
        try Task.checkCancellation()

        await progress(.unpacking)
        let extractedURL = try extract(packageURL, into: workspace)
        let descriptorGroups = try findDescriptorGroups(in: extractedURL)
        guard !descriptorGroups.isEmpty else { throw InstallError.noDescriptors }
        for descriptors in descriptorGroups.values.flatMap({ $0 })
            where shouldRandomizeIdentifier(in: descriptors) {
            try randomizeIdentifier(in: descriptors)
        }
        try Task.checkCancellation()

        await progress(.locatingPosterBoard)
        let appHash = try WorseQuery.findPosterBoardHash()
        try Task.checkCancellation()

        await progress(.writing)
        var writtenPaths: [String] = []
        for (extensionID, descriptors) in descriptorGroups {
            writtenPaths += try WorseQuery.writeDescriptors(
                appHash: appHash,
                extensionID: extensionID,
                descriptorFolders: descriptors
            )
        }
        InstalledWallpaperNameStore.record(
            name: sourceURL.deletingPathExtension().lastPathComponent,
            paths: writtenPaths
        )
        #endif
    }

    private func copyImportedPackage(_ sourceURL: URL, into workspace: URL) throws -> URL {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize > 0,
              Int64(fileSize) <= maximumPackageBytes else {
            throw InstallError.packageTooLarge
        }

        let destination = workspace.appending(path: "wallpaper.\(sourceURL.pathExtension.lowercased())")
        try fileManager.copyItem(at: sourceURL, to: destination)
        return destination
    }

    /// Race lightweight HEAD requests, then retry the other route if the actual download fails.
    private func downloadPackage(
        from candidates: [URL],
        into workspace: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let preferred = await preferredDownloadURL(in: candidates)
        try Task.checkCancellation()
        let ordered = preferred.map { first in [first] + candidates.filter { $0 != first } } ?? candidates
        var lastError: Error = InstallError.invalidDownloadURL
        for url in ordered {
            try Task.checkCancellation()
            // A failed HTTP response can still leave a downloaded file behind.
            let destination = workspace.appending(path: "wallpaper.tendies")
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            progress(0)
            do {
                return try await download(url, into: workspace, progress: progress)
            } catch {
                try Task.checkCancellation()
                lastError = error
                installerLogger.notice("Download route failed: \(url.absoluteString, privacy: .public); trying next route")
            }
        }
        throw lastError
    }

    private func preferredDownloadURL(in candidates: [URL]) async -> URL? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        return await withTaskGroup(of: URL?.self) { group in
            for url in candidates {
                group.addTask {
                    var request = URLRequest(url: url)
                    request.httpMethod = "HEAD"
                    do {
                        let (_, response) = try await session.data(for: request)
                        guard let response = response as? HTTPURLResponse,
                              response.statusCode == 200 else { return nil }
                        return url
                    } catch {
                        return nil
                    }
                }
            }
            for await result in group {
                if let url = result {
                    group.cancelAll()
                    return url
                }
            }
            // Some hosts reject HEAD; still try both routes with a real GET.
            return nil
        }
    }

    private func download(
        _ remoteURL: URL,
        into workspace: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        var request = URLRequest(url: remoteURL)
        request.timeoutInterval = 90
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let destination = workspace.appending(path: "wallpaper.tendies")
        let response: URLResponse
        do {
            response = try await PackageDownloader(
                destination: destination,
                progress: progress
            ).download(request)
        } catch {
            throw DownloadError.transport(url: remoteURL, underlying: error)
        }
        guard let response = response as? HTTPURLResponse else {
            throw DownloadError.invalidResponse(url: remoteURL)
        }
        guard response.statusCode == 200 else {
            throw DownloadError.httpStatus(url: remoteURL, statusCode: response.statusCode)
        }

        let fileSize = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard fileSize > 0, Int64(fileSize) <= maximumPackageBytes else {
            throw InstallError.packageTooLarge
        }
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

    private func shouldRandomizeIdentifier(in descriptor: URL) -> Bool {
        !descriptor.pathComponents.contains {
            $0.caseInsensitiveCompare("Container") == .orderedSame
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

private final class PackageDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let progress: @Sendable (Double) -> Void
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URLResponse, Error>?
    private var fileError: Error?

    init(destination: URL, progress: @escaping @Sendable (Double) -> Void) {
        self.destination = destination
        self.progress = progress
    }

    func download(_ request: URLRequest) async throws -> URLResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: request)
                self.task = task
                task.resume()
            }
        } onCancel: {
            self.task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        progress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            fileError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
            self.task = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let fileError {
            continuation?.resume(throwing: fileError)
        } else if let response = task.response {
            continuation?.resume(returning: response)
        } else {
            continuation?.resume(throwing: URLError(.badServerResponse))
        }
    }
}

enum InstallError: LocalizedError {
    case deviceRequired
    case unsupportedSystem
    case invalidDownloadURL
    case unsupportedPackageType
    case packageTooLarge
    case invalidPackage
    case noDescriptors

    var errorDescription: String? {
        switch self {
        case .deviceRequired: String(localized: "Please install wallpapers on a physical device.")
        case .unsupportedSystem: String(localized: "This system version is not supported.")
        case .invalidDownloadURL: String(localized: "The download URL is invalid.")
        case .unsupportedPackageType: String(localized: "Choose a .tendies wallpaper package.")
        case .packageTooLarge: String(localized: "The wallpaper package is empty or too large.")
        case .invalidPackage: String(localized: "The wallpaper package is invalid or damaged.")
        case .noDescriptors: String(localized: "The wallpaper package contains no installable content.")
        }
    }
}

private enum DownloadError: LocalizedError, CustomStringConvertible {
    case transport(url: URL, underlying: Error)
    case invalidResponse(url: URL)
    case httpStatus(url: URL, statusCode: Int)

    var errorDescription: String? {
        String(localized: "Download failed. Please try again later.")
    }

    var description: String {
        switch self {
        case .transport(let url, let underlying):
            let error = underlying as NSError
            return "transport url=\(url.absoluteString) domain=\(error.domain) code=\(error.code) description=\(error.localizedDescription) userInfo=\(error.userInfo)"
        case .invalidResponse(let url):
            return "invalidResponse url=\(url.absoluteString)"
        case .httpStatus(let url, let statusCode):
            return "httpStatus url=\(url.absoluteString) statusCode=\(statusCode)"
        }
    }
}
