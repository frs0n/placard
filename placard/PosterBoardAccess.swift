import Foundation

/// Serializes every access to PosterBoard's private container. The underlying
/// containermanager query and filesystem mutations are synchronous and are not
/// safe to run concurrently from independent installation coordinators.
actor PosterBoardAccess {
    static let shared = PosterBoardAccess()

    func findContainerHash() throws -> String {
        try Task.checkCancellation()
        return try BadQuery.findPosterBoardHash()
    }

    func writeDescriptorGroups(
        _ groups: [String: [URL]],
        appHash: String
    ) throws -> [String] {
        try Task.checkCancellation()
        var writtenPaths: [String] = []
        for (extensionID, descriptors) in groups {
            try Task.checkCancellation()
            writtenPaths += try BadQuery.writeDescriptors(
                appHash: appHash,
                extensionID: extensionID,
                descriptorFolders: descriptors
            )
        }
        return writtenPaths
    }

    func installedWallpapers() throws -> [InstalledWallpaper] {
        try Task.checkCancellation()
        return try BadQuery.installedWallpapers()
    }

    func delete(_ wallpaper: InstalledWallpaper) throws {
        try Task.checkCancellation()
        try BadQuery.deleteInstalledWallpaper(wallpaper)
    }
}
