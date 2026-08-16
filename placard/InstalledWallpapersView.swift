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
                    ? "将从“我的壁纸”中移除并刷新屏幕。"
                    : "将从“精选”中移除并刷新屏幕。已创建的壁纸不受影响。"),
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
            ProgressView("正在载入…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let wallpapers):
            if wallpapers.isEmpty {
                ContentUnavailableView(
                    "暂无壁纸",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("这里会显示已保存的锁屏壁纸。")
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
                Label("无法载入", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("重试") { Task { await manager.load() } }
            }
        case .deleting:
            ProgressView("正在删除…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preparingRespring:
            ProgressView("即将刷新屏幕…")
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
                .accessibilityHint(wallpaper.snapshotError ?? "没有可用的预览")
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
