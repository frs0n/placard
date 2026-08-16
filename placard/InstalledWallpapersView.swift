import SwiftUI

struct InstalledWallpapersView: View {
    @State private var manager: InstalledWallpapersManager
    @State private var pendingDeletions: [InstalledWallpaper] = []
    @State private var isShowingDeletionConfirmation = false
    @State private var selectedSource: InstalledWallpaper.Source = .galleryDescriptor
    @State private var selectedWallpaperIDs = Set<InstalledWallpaper.ID>()
    @State private var editMode: EditMode = .inactive

    init(library: InstalledWallpaperLibrary = .live) {
        _manager = State(initialValue: InstalledWallpapersManager(library: library))
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Library")
                .toolbar {
                    if editMode == .active {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                selectedWallpaperIDs.removeAll()
                                editMode = .inactive
                            }
                        }

                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Delete", systemImage: "trash", role: .destructive) {
                                requestDeletion(selectedWallpapers)
                            }
                            .disabled(selectedWallpapers.isEmpty)
                        }
                    } else {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Select") {
                                editMode = .active
                            }
                        }
                    }
                }
        }
        .task { await manager.load() }
        .alert(deletionTitle, isPresented: $isShowingDeletionConfirmation) {
            Button("Delete", role: .destructive) {
                manager.delete(pendingDeletions)
                pendingDeletions.removeAll()
                selectedWallpaperIDs.removeAll()
                editMode = .inactive
            }
            Button("Cancel", role: .cancel) {
                pendingDeletions.removeAll()
            }
        } message: {
            Text(deletionMessage)
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
            ProgressView("Loading…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let wallpapers):
            if wallpapers.isEmpty {
                ContentUnavailableView(
                    "No Wallpapers",
                    systemImage: "rectangle.stack.badge.minus",
                    description: Text("Saved Lock Screen wallpapers will appear here.")
                )
            } else {
                InstalledWallpaperList(
                    collection: wallpapers,
                    selectedSource: $selectedSource,
                    selectedWallpaperIDs: $selectedWallpaperIDs,
                    editMode: $editMode,
                    onDelete: requestDeletion
                ) {
                    await manager.load()
                }
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Unable to Load", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Retry") { Task { await manager.load() } }
            }
        case .deleting:
            ProgressView("Deleting…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .preparingRespring:
            ProgressView("Refreshing screen…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .respringing:
            Color.black.ignoresSafeArea()
        }
    }

    private var selectedWallpapers: [InstalledWallpaper] {
        guard case .loaded(let collection) = manager.state else { return [] }
        return collection.items(for: selectedSource).filter { selectedWallpaperIDs.contains($0.id) }
    }

    private var deletionMessage: String {
        guard let source = pendingDeletions.first?.source else { return "" }
        if pendingDeletions.count == 1, let wallpaper = pendingDeletions.first {
            return source == .configuration
                ? String(localized: "This will remove \(wallpaper.name) from My Wallpapers and refresh the screen.")
                : String(localized: "This will remove \(wallpaper.name) from Featured and refresh the screen. Wallpapers you created are unaffected.")
        }
        return source == .configuration
            ? String(localized: "This will remove \(pendingDeletions.count) wallpapers from My Wallpapers and refresh the screen.")
            : String(localized: "This will remove \(pendingDeletions.count) wallpapers from Featured and refresh the screen. Wallpapers you created are unaffected.")
    }

    private var deletionTitle: String {
        if pendingDeletions.count == 1, let wallpaper = pendingDeletions.first {
            return String(
                localized: "Delete “\(wallpaper.name)”?"
            )
        }
        return String(localized: "Delete \(pendingDeletions.count) Wallpapers?")
    }

    private func requestDeletion(_ wallpapers: [InstalledWallpaper]) {
        guard !wallpapers.isEmpty else { return }
        pendingDeletions = wallpapers
        isShowingDeletionConfirmation = true
    }
}

private struct InstalledWallpaperList: View {
    let collection: InstalledWallpaperCollection
    @Binding var selectedSource: InstalledWallpaper.Source
    @Binding var selectedWallpaperIDs: Set<InstalledWallpaper.ID>
    @Binding var editMode: EditMode
    let onDelete: ([InstalledWallpaper]) -> Void
    let onRefresh: () async -> Void

    private var wallpapers: [InstalledWallpaper] {
        collection.items(for: selectedSource)
    }

    var body: some View {
        List(selection: $selectedWallpaperIDs) {
            Section {
                Picker("Wallpaper Source", selection: $selectedSource) {
                    Text("Featured").tag(InstalledWallpaper.Source.galleryDescriptor)
                    Text("My Wallpapers").tag(InstalledWallpaper.Source.configuration)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(.init(top: 4, leading: 0, bottom: 8, trailing: 0))
            }

            if wallpapers.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Wallpapers Here Yet",
                        systemImage: "rectangle.stack.badge.minus",
                        description: Text(selectedSource == .configuration
                            ? "System wallpapers you create will appear here."
                            : "Saved featured wallpapers will appear here.")
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section("\(wallpapers.count) items") {
                    ForEach(wallpapers) { wallpaper in
                        InstalledWallpaperRow(wallpaper: wallpaper)
                            .swipeActions {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDelete([wallpaper])
                                }
                            }
                            .contextMenu {
                                Button("Delete", systemImage: "trash", role: .destructive) {
                                    onDelete([wallpaper])
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .environment(\.editMode, $editMode)
        .onChange(of: selectedSource) { _, _ in
            selectedWallpaperIDs.removeAll()
        }
        .refreshable { await onRefresh() }
    }
}

private struct InstalledWallpaperRow: View {
    let wallpaper: InstalledWallpaper

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
                    Text("No Snapshot")
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
                .accessibilityHint(wallpaper.snapshotError ?? "No preview available")
            }
        }
        .frame(width: 62, height: 88)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 0.5)
        }
        .accessibilityLabel("\(wallpaper.name)'s system wallpaper snapshot")
    }
}

#Preview("Installed wallpapers") {
    InstalledWallpapersView(library: .preview)
}
