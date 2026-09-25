import Foundation
import OSLog

/// Adapter for AirCard-iOS 097a058c984ffc33ccb697b9dfe8058be3e86244.
/// TendiesEngine owns extraction, identifier rewriting, injection, and preferences.
@MainActor
final class AirliftWallpaperService {
    static let shared = AirliftWallpaperService()
    private var installing = false

    static func log(_ message: String) {
        Logger(subsystem: Bundle.main.bundleIdentifier ?? "Placard", category: "Airlift")
            .info("\(message, privacy: .public)")
    }

    func install(
        packageAt url: URL,
        progress: @escaping @MainActor @Sendable (InstallState) -> Void
    ) async throws {
        guard !installing else {
            throw NSError(domain: "Airlift", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Installing…")
            ])
        }
        installing = true
        defer { installing = false }
        let pairingPath = PairingController.pairingFilePath()
        guard FileManager.default.fileExists(atPath: pairingPath) else {
            throw NSError(domain: "Airlift", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Pair this iPhone")
            ])
        }
        let engine = TendiesEngine.shared
        progress(.unpacking)
        let item = try await engine.importTendie(from: url)
        defer { try? FileManager.default.removeItem(at: item.fileURL) }
        try Task.checkCancellation()
        progress(.locatingPosterBoard)
        let container = try await engine.detectPosterBoardContainer(pairingPath: pairingPath)
        try Task.checkCancellation()
        progress(.writing)
        try await engine.flashTendies(
            items: [item], containerPath: container, resetProtections: true,
            pairingPath: pairingPath, log: Self.log, progress: { _ in }
        )
    }
}
