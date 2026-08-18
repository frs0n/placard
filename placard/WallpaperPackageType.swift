import UniformTypeIdentifiers

extension UTType {
    /// The `.tendies` wallpaper archive type. The app owns (exports) this identifier so the
    /// system resolves downloaded `.tendies` files to it, and shares it with Pocket Poster,
    /// which declares the same `com.leemin.tendies` identifier.
    static let tendiesWallpaper = UTType(exportedAs: "com.leemin.tendies", conformingTo: .archive)

    /// Content types the wallpaper importer accepts.
    ///
    /// A `.tendies` file may resolve to the declared type, to a concrete zip/archive type, or —
    /// when no installed app has claimed the extension at download time — to a *dynamic*
    /// identifier that conforms only to `public.data`. The document picker enables a file by
    /// matching its filename extension but only selects it when its resolved type conforms to an
    /// allowed type, so a file tagged with a dynamic UTI looks selectable yet does nothing when
    /// tapped. Listing every representation keeps such files both selectable *and* tappable,
    /// which is the root cause of imports that appeared to do nothing.
    static var importableWallpaperTypes: [UTType] {
        var types: [UTType] = [.tendiesWallpaper]
        if let byExtension = UTType(filenameExtension: "tendies"), !types.contains(byExtension) {
            types.append(byExtension)
        }
        for fallback in [UTType.zip, .archive, .data] where !types.contains(fallback) {
            types.append(fallback)
        }
        return types
    }
}
