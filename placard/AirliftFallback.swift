import Foundation
import SwiftUI
import UniformTypeIdentifiers
import AirliftFFI

enum AirliftFallbackError: LocalizedError {
    case pairingRequired
    case invalidContainer
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .pairingRequired: "Import a device pairing file in the Airlift tab and connect LocalDevVPN."
        case .invalidContainer: "The resolved PosterBoard container path is invalid."
        case .operationFailed(let message): message
        }
    }
}

enum AirliftFallback {
    static var pairingURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("placard_pairing.plist")
    }

    static var isConfigured: Bool {
        ((try? pairingURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
    }

    static func importPairingFile(_ source: URL) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: source)
        guard !data.isEmpty, data.count < 1_024 * 1_024,
              (try? PropertyListSerialization.propertyList(from: data, format: nil)) != nil else {
            throw AirliftFallbackError.operationFailed("Choose a valid pairing plist (under 1 MB).")
        }
        try data.write(to: pairingURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    static func writeDescriptors(_ groups: [String: [URL]]) async throws -> [String] {
        guard isConfigured else { throw AirliftFallbackError.pairingRequired }
        let pairingPath = pairingURL.path
        return try await Task.detached(priority: .userInitiated) {
            let reportedContainer = try Self.resolveContainer(pairingPath: pairingPath)
            let container = reportedContainer.hasPrefix("/private/var/mobile/")
                ? String(reportedContainer.dropFirst("/private".count)) : reportedContainer
            let components = container.split(separator: "/").map { String($0) }
            guard components.count == 6,
                  Array(components.prefix(5)) == ["var", "mobile", "Containers", "Data", "Application"],
                  UUID(uuidString: components[5]) != nil else {
                throw AirliftFallbackError.invalidContainer
            }

            var installed: [String] = []
            for (extensionID, descriptors) in groups.sorted(by: { $0.key < $1.key }) {
                guard !extensionID.isEmpty,
                      extensionID.range(of: "^[A-Za-z0-9.-]+$", options: .regularExpression) != nil else {
                    throw AirliftFallbackError.invalidContainer
                }
                let parent = container + "/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/" + extensionID + "/descriptors"
                for descriptor in descriptors {
                    try Task.checkCancellation()
                    let name = UUID().uuidString.uppercased()
                    try Self.inject(descriptor: descriptor, parent: parent, name: name, pairingPath: pairingPath)
                    installed.append(parent + "/" + name)

                    // Collections descriptors may also live under the newer provider identifier.
                    if extensionID == "com.apple.WallpaperKit.CollectionsPoster" {
                        let modern = container + "/Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/com.apple.Posters.CollectionsPosterApp/descriptors"
                        try? Self.inject(descriptor: descriptor, parent: modern, name: name, pairingPath: pairingPath)
                    }
                }
            }
            return installed
        }.value
    }

    nonisolated private static func resolveContainer(pairingPath: String) throws -> String {
        var path: UnsafeMutablePointer<CChar>?
        var error: UnsafeMutablePointer<CChar>?
        let status = pairingPath.withCString { pairing in
            "com.apple.PosterBoard".withCString { bundle in
                al_find_app_container(pairing, bundle, nil, nil, &path, &error)
            }
        }
        defer {
            if let path { al_string_free(path) }
            if let error { al_string_free(error) }
        }
        guard status == 0, let path else {
            throw AirliftFallbackError.operationFailed(error.map { String(cString: $0) } ?? "Could not locate PosterBoard through LocalDevVPN.")
        }
        return String(cString: path)
    }

    nonisolated private static func inject(descriptor: URL, parent: String, name: String, pairingPath: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        let status = pairingPath.withCString { pairing in
            descriptor.path.withCString { folder in
                parent.withCString { destination in
                    name.withCString { leaf in
                        al_exploit_inject_folder(pairing, folder, destination, leaf, nil, nil, &error)
                    }
                }
            }
        }
        defer { if let error { al_string_free(error) } }
        guard status == 0 else {
            throw AirliftFallbackError.operationFailed(error.map { String(cString: $0) } ?? "Airlift could not install the descriptor.")
        }
    }
}

struct AirliftSetupView: View {
    @State private var importing = false
    @State private var configured = AirliftFallback.isConfigured
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Before installing") {
                    Text("Connect LocalDevVPN in loopback mode. Pair this iPhone in Developer Mode using AirCard-iOS, then import its pairing plist here.")
                    Link("Open LocalDevVPN", destination: URL(string: "localdevvpn://")!)
                    Link("AirCard-iOS setup", destination: URL(string: "https://github.com/Mak5er/AirCard-iOS")!)
                }
                Section("Device pairing") {
                    Label(configured ? "Pairing file imported" : "Pairing file required", systemImage: configured ? "checkmark.circle.fill" : "exclamationmark.circle")
                    Button("Import pairing plist") { importing = true }
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Airlift")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                do {
                    try AirliftFallback.importPairingFile(result.get())
                    configured = AirliftFallback.isConfigured
                    errorMessage = nil
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}
