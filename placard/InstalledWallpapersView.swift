import SwiftUI

struct InstalledWallpapersView: View {
    @State private var manager: InstalledWallpapersManager
    @State private var pendingDeletion: InstalledWallpaper?
    @State private var selectedSource: InstalledWallpaper.Source = .galleryDescriptor

    init(library: InstalledWallpaperLibrary = .live) {
        _manager = State(initialValue: InstalledWallpapersManager(library: library))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("已安装")
        }
        .task { await manager.load() }
        .alert(item: $pendingDeletion) { wallpaper in
            Alert(
                title: Text("删除“\(wallpaper.name)”？"),
                message: Text(wallpaper.source == .configuration
                    ? "将从“我的壁纸”中移除这一个可切换壁纸，并刷新桌面。"
                    : "将从“精选”中移除这一个壁纸项目，并刷新桌面。已经创建的可切换壁纸不会一起删除。"),
                primaryButton: .destructive(Text("删除")) {
                    manager.delete(wallpaper)
                },
                secondaryButton: .cancel()
            )
        }
        .overlay {
            if manager.state == .respringing {
                NeoSpringView()
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch manager.state {
        case .idle, .loading:
            ProgressView("正在读取 PosterBoard…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let wallpapers):
            if wallpapers.isEmpty {
                ContentUnavailableView(
                    "没有壁纸配置",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("PosterBoard 没有返回已保存的锁屏壁纸。")
                )
            } else {
                InstalledWallpaperList(
                    collection: wallpapers,
                    selectedSource: $selectedSource,
                    onDelete: requestDeletion
                ) {
                    await manager.load()
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("无法读取已安装壁纸", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await manager.load() } }
            }
        case .deleting:
            ProgressView("正在删除壁纸…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preparingRespring:
            ProgressView("删除完成，正在准备刷新桌面…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .respringing:
            Color.black.ignoresSafeArea()
        }
    }

    private func requestDeletion(_ wallpaper: InstalledWallpaper) {
        pendingDeletion = wallpaper
    }
}

private struct InstalledWallpaperList: View {
    let collection: InstalledWallpaperCollection
    @Binding var selectedSource: InstalledWallpaper.Source
    let onDelete: (InstalledWallpaper) -> Void
    let onRefresh: () async -> Void

    private var wallpapers: [InstalledWallpaper] {
        collection.items(for: selectedSource)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("壁纸来源", selection: $selectedSource) {
                Text("精选").tag(InstalledWallpaper.Source.galleryDescriptor)
                Text("我的壁纸").tag(InstalledWallpaper.Source.configuration)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            List {
                Section {
                    ForEach(wallpapers) { wallpaper in
                        InstalledWallpaperRow(wallpaper: wallpaper, onDelete: onDelete)
                    }
                } header: {
                    Text("\(wallpapers.count) 个项目")
                }
            }
            .listStyle(.insetGrouped)
            .refreshable { await onRefresh() }
        }
    }
}

private struct InstalledWallpaperRow: View {
    let wallpaper: InstalledWallpaper
    let onDelete: (InstalledWallpaper) -> Void

    var body: some View {
        HStack(spacing: 12) {
            SystemWallpaperSnapshot(wallpaper: wallpaper)

            VStack(alignment: .leading, spacing: 3) {
                Text(wallpaper.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 5) {
                    Text(wallpaper.kindTitle)
                    if let identifier = wallpaper.descriptorIdentifier {
                        Text("·")
                        Text(identifier)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                onDelete(wallpaper)
            } label: {
                Image(systemName: "trash")
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("删除 \(wallpaper.name)")
        }
        .padding(.vertical, 6)
    }
}

private struct SystemWallpaperSnapshot: View {
    let wallpaper: InstalledWallpaper

    var body: some View {
        Group {
            if let data = wallpaper.snapshotData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                VStack(spacing: 5) {
                    Image(systemName: "rectangle.portrait.slash")
                    Text("无快照")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .accessibilityHint(wallpaper.snapshotError ?? "PosterBoard 没有返回这个配置的快照")
            }
        }
        .frame(width: 62, height: 88)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        }
        .accessibilityLabel("\(wallpaper.name) 的系统壁纸快照")
    }
}

#Preview("Installed wallpapers") {
    InstalledWallpapersView(library: .preview)
}
