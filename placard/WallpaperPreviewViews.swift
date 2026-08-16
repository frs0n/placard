import ImageIO
import SwiftUI
import UIKit

struct WallpaperGrid: View {
    let wallpapers: [Wallpaper]
    let showsAuthor: Bool
    @Namespace private var transitionNamespace
    @State private var selectedWallpaper: Wallpaper?

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 260), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(wallpapers) { wallpaper in
                Button {
                    selectedWallpaper = wallpaper
                } label: {
                    WallpaperCard(
                        wallpaper: wallpaper,
                        showsAuthor: showsAuthor,
                        transitionNamespace: transitionNamespace
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Open preview")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .fullScreenCover(item: $selectedWallpaper) { wallpaper in
            NavigationStack {
                WallpaperDetailView(
                    wallpaper: wallpaper,
                    showsAuthor: showsAuthor,
                    transitionNamespace: transitionNamespace
                )
            }
            .navigationTransition(
                .zoom(sourceID: wallpaper.id, in: transitionNamespace)
            )
        }
    }
}

struct WallpaperLoadingGrid: View {
    let showsAuthor: Bool

    private let columns = [GridItem(.adaptive(minimum: 164, maximum: 260), spacing: 16)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                WallpaperCard(wallpaper: .placeholder, showsAuthor: showsAuthor)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let showsAuthor: Bool
    var transitionNamespace: Namespace.ID?

    init(
        wallpaper: Wallpaper,
        showsAuthor: Bool,
        transitionNamespace: Namespace.ID? = nil
    ) {
        self.wallpaper = wallpaper
        self.showsAuthor = showsAuthor
        self.transitionNamespace = transitionNamespace
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            RemoteWallpaperPreview(urls: wallpaper.previewURLs, aspectRatio: 0.72)
                .clipShape(.rect(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .stroke(.separator.opacity(0.35), lineWidth: 0.5)
                }
                .modifier(
                    WallpaperTransitionSource(
                        id: wallpaper.id,
                        namespace: transitionNamespace
                    )
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if showsAuthor {
                    Text(wallpaper.authors ?? "Unknown Author")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(.rect)
    }
}

private struct WallpaperTransitionSource: ViewModifier {
    let id: String
    let namespace: Namespace.ID?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

struct RemoteWallpaperPreview: View {
    let urls: [URL]
    let aspectRatio: CGFloat
    let playback: PreviewPlayback

    init(
        urls: [URL],
        aspectRatio: CGFloat,
        playback: PreviewPlayback = .thumbnail
    ) {
        self.urls = urls
        self.aspectRatio = aspectRatio
        self.playback = playback
    }

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    AnimatedImageView(image: image, animates: playback == .animated)
                } else if didFail {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: urls) { await load() }
    }

    private func load() async {
        for url in urls {
            if let cached = AnimatedImageLoader.cached(url, playback: playback) {
                image = cached
                return
            }
        }
        image = nil
        didFail = false
        var loaded: UIImage?
        for url in urls {
            loaded = await AnimatedImageLoader.load(url, playback: playback)
            if loaded != nil { break }
        }
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            if let loaded {
                image = loaded
            } else {
                didFail = true
            }
        }
    }
}

enum PreviewPlayback: Sendable {
    /// Cheap, downsampled stills for scrolling collections.
    case thumbnail
    /// Full animation is reserved for the single image shown in the detail view.
    case animated
}

/// Displays a (possibly animated) `UIImage`. `UIImageView` loops animated
/// images automatically, which SwiftUI's `Image`/`AsyncImage` do not.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage
    let animates: Bool

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFill
        view.clipsToBounds = true
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentHuggingPriority(.defaultLow, for: .vertical)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        uiView.image = image
        if animates {
            uiView.startAnimating()
        } else {
            uiView.stopAnimating()
        }
    }
}

enum AnimatedImageLoader {
    nonisolated private static let cache = ImageCache()

    nonisolated static func cached(_ url: URL, playback: PreviewPlayback) -> UIImage? {
        cache.image(for: cacheKey(for: url, playback: playback))
    }

    nonisolated static func load(_ url: URL, playback: PreviewPlayback) async -> UIImage? {
        if let cached = cached(url, playback: playback) { return cached }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return nil }
            let image = await Task.detached(priority: .utility) {
                decode(data, playback: playback)
            }.value
            guard let image, !Task.isCancelled else { return nil }
            cache.insert(image, for: cacheKey(for: url, playback: playback))
            return image
        } catch {
            return nil
        }
    }

    nonisolated private static func cacheKey(for url: URL, playback: PreviewPlayback) -> NSString {
        "\(url.absoluteString)#\(cacheSuffix(for: playback))" as NSString
    }

    nonisolated private static func cacheSuffix(for playback: PreviewPlayback) -> String {
        switch playback {
        case .thumbnail: "thumbnail"
        case .animated: "animated"
        }
    }

    nonisolated private static func isAnimated(_ playback: PreviewPlayback) -> Bool {
        switch playback {
        case .thumbnail: false
        case .animated: true
        }
    }

    nonisolated private static func decode(_ data: Data, playback: PreviewPlayback) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard isAnimated(playback), count > 1 else {
            return thumbnail(source: source)
        }

        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, index, thumbnailOptions) else { continue }
            duration += frameDelay(source: source, index: index)
            frames.append(UIImage(cgImage: cgImage))
        }
        guard frames.count > 1 else { return thumbnail(source: source) }
        if duration <= 0 { duration = Double(frames.count) / 30.0 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    nonisolated private static var thumbnailOptions: CFDictionary {
        [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 1_200
        ] as CFDictionary
    }

    nonisolated private static func thumbnail(source: CGImageSource) -> UIImage? {
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    nonisolated private static func frameDelay(source: CGImageSource, index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return 0.1
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        if let delay = gif[kCGImagePropertyGIFDelayTime] as? Double, delay > 0 {
            return delay
        }
        return 0.1
    }
}

nonisolated private final class ImageCache: @unchecked Sendable {
    private let values = NSCache<NSString, UIImage>()

    init() {
        values.countLimit = 60
    }

    func image(for key: NSString) -> UIImage? {
        values.object(forKey: key)
    }

    func insert(_ image: UIImage, for key: NSString) {
        values.setObject(image, forKey: key)
    }
}
