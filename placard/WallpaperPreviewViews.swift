import SwiftUI

struct WallpaperGrid: View {
    let wallpapers: [Wallpaper]
    let showsAuthor: Bool
    let onSelect: (Wallpaper) -> Void

    private let columns = [GridItem(.adaptive(minimum: 164), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(wallpapers) { wallpaper in
                    Button {
                        onSelect(wallpaper)
                    } label: {
                        WallpaperCard(wallpaper: wallpaper, showsAuthor: showsAuthor)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("查看并安装这张壁纸")
                }
            }
            .padding(16)
        }
    }
}

struct WallpaperLoadingGrid: View {
    let showsAuthor: Bool

    private let columns = [GridItem(.adaptive(minimum: 164), spacing: 12)]

    var body: some View {
        ScrollView {
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

    var body: some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.1))
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                AsyncImage(url: url, transaction: .init(animation: .easeOut(duration: 0.2))) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .failure:
                        Image(systemName: "photo")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    case .empty:
                        ProgressView()
                    @unknown default:
                        EmptyView()
                    }
                }
            }
            .clipped()
    }
}
