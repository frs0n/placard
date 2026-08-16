import ImageIO
import SwiftUI
import UIKit

struct WallpaperGrid: View {
    let wallpapers: [Wallpaper]
    let showsAuthor: Bool
    let onSelect: (Wallpaper) -> Void

    private let columns = [GridItem(.adaptive(minimum: 164), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(wallpapers) { wallpaper in
                Button {
                    onSelect(wallpaper)
                } label: {
                    WallpaperCard(wallpaper: wallpaper, showsAuthor: showsAuthor)
                }
                .buttonStyle(.plain)
                .accessibilityHint("查看壁纸")
            }
        }
        .padding(16)
    }
}

struct WallpaperLoadingGrid: View {
    let showsAuthor: Bool

    private let columns = [GridItem(.adaptive(minimum: 164), spacing: 12)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(0..<6, id: \.self) { _ in
                WallpaperCard(wallpaper: .placeholder, showsAuthor: showsAuthor)
            }
        }
        .padding(16)
        .redacted(reason: .placeholder)
        .allowsHitTesting(false)
    }
}

struct WallpaperCard: View {
    let wallpaper: Wallpaper
    let showsAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteWallpaperPreview(url: wallpaper.previewURL, aspectRatio: 0.72)

            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if showsAuthor {
                    Text(wallpaper.authors ?? "未知作者")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 16))
        .clipShape(.rect(cornerRadius: 16))
    }
}

struct RemoteWallpaperPreview: View {
    let url: URL
    let aspectRatio: CGFloat

    @State private var image: UIImage?
    @State private var didFail = false

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let image {
                    AnimatedImageView(image: image)
                } else if didFail {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = AnimatedImageLoader.cached(url) {
            image = cached
            return
        }
        image = nil
        didFail = false
        let loaded = await AnimatedImageLoader.load(url)
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

/// Displays a (possibly animated) `UIImage`. `UIImageView` loops animated
/// images automatically, which SwiftUI's `Image`/`AsyncImage` do not.
private struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

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
    }
}

enum AnimatedImageLoader {
    private static let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 60
        return cache
    }()

    static func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    static func load(_ url: URL) async -> UIImage? {
        if let cached = cached(url) { return cached }
        do {
            var request = URLRequest(url: url)
            request.cachePolicy = .returnCacheDataElseLoad
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let image = decode(data) else { return nil }
            cache.setObject(image, forKey: url as NSURL)
            return image
        } catch {
            return nil
        }
    }

    private static func decode(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return UIImage(data: data) }

        var frames: [UIImage] = []
        var duration = 0.0
        for index in 0..<count {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            duration += frameDelay(source: source, index: index)
            frames.append(UIImage(cgImage: cgImage))
        }
        guard frames.count > 1 else { return UIImage(data: data) }
        if duration <= 0 { duration = Double(frames.count) / 30.0 }
        return UIImage.animatedImage(with: frames, duration: duration)
    }

    private static func frameDelay(source: CGImageSource, index: Int) -> Double {
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
