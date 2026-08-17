import UniformTypeIdentifiers

extension UTType {
    /// The canonical type identifier exported by Pocket Poster for `.tendies` archives.
    static let tendiesWallpaper = UTType(
        importedAs: "com.leemin.tendies",
        conformingTo: .archive
    )
}
