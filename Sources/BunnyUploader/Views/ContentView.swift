import SwiftUI
import BunnyUploaderCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: UploadEngine
    @Environment(\.undoManager) private var undoManager
    @State private var isTargeted = false
    /// A row whose Retry would upload the whole file again; the alert asks first.
    @State private var restartCandidate: UploadItem?
    /// Selected row, moved with the arrow keys.
    @State private var selectedId: UUID?
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header

            DropZone(isTargeted: $isTargeted, hasCredentials: engine.hasCredentials) { urls in
                for url in urls {
                    engine.addFile(url)
                }
            }
            .padding(Space.l)

            Divider()

            if engine.items.isEmpty {
                emptyState
            } else {
                uploadList
            }
        }
        .focusedSceneValue(\.uploadActions, actions)
        .alert(
            Text("Upload again from the start?"),
            isPresented: Binding(
                get: { restartCandidate != nil },
                set: { shown in
                    if !shown {
                        restartCandidate = nil
                    }
                }
            ),
            presenting: restartCandidate
        ) { item in
            Button("Upload Again") {
                engine.retry(item)
            }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("Bunny has no part of this upload to continue from, so the whole file (\(Self.formatBytes(item.fileSize))) uploads again.")
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear Finished") {
                    clearFinished()
                }
                .disabled(!engine.hasFinished)
                .help("Remove done uploads from the list. The videos stay in Bunny.")
                .accessibilityHint(Text("Removes done uploads from the list"))
            }
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Open Settings (⌘,)")
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "arrow.up.to.line.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Bunny Stream Uploader")
                    .font(.headline)
                if engine.hasCredentials {
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Credentials missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Palette.failure)
                }
            }
            Spacer()
            if engine.activeCount > 0 {
                VStack(alignment: .trailing, spacing: Space.xxs) {
                    Text(String(format: "%.1f MB/s", engine.totalThroughputMBps))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("\(engine.activeCount) concurrent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.top, Space.m)
    }

    private var emptyState: some View {
        VStack(spacing: Space.s) {
            Spacer()
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: Layout.heroSymbol))
                .foregroundStyle(.secondary)
            Text("No uploads yet")
                .foregroundStyle(.secondary)
            Text("Drag videos into the window above, or choose them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Button("Choose Videos…") {
                VideoPicker.choose { urls in
                    for url in urls {
                        engine.addFile(url)
                    }
                }
            }
            .padding(.top, Space.s)
            .disabled(!engine.hasCredentials)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var uploadList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: Space.s) {
                    ForEach(engine.items) { item in
                        UploadRowView(
                            item: item,
                            hasCredentials: engine.hasCredentials,
                            isSelected: item.id == selectedId,
                            queuePosition: engine.queuePosition(of: item),
                            onRemove: { remove(item) },
                            onCancel: { engine.cancelUpload(item) },
                            onRetry: { askRetry(item) }
                        )
                        .id(item.id)
                        .simultaneousGesture(TapGesture().onEnded {
                            selectedId = item.id
                            listFocused = true
                        })
                    }
                }
                .padding(Space.l)
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.upArrow) {
                moveSelection(by: -1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.downArrow) {
                moveSelection(by: 1, proxy: proxy)
                return .handled
            }
            .onKeyPress(.delete) {
                removeSelectedIfFinished()
            }
            .onKeyPress(.deleteForward) {
                removeSelectedIfFinished()
            }
            .onCopyCommand {
                guard let videoId = selectedItem?.videoId else { return [] }
                return [NSItemProvider(object: videoId as NSString)]
            }
        }
    }

    // MARK: - Selection and keyboard

    private var selectedItem: UploadItem? {
        guard let selectedId else { return nil }
        return engine.items.first { $0.id == selectedId }
    }

    private func moveSelection(by step: Int, proxy: ScrollViewProxy) {
        let items = engine.items
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.id == selectedId }
        let next: Int
        if let current {
            next = min(max(current + step, 0), items.count - 1)
        } else {
            next = step > 0 ? 0 : items.count - 1
        }
        selectedId = items[next].id
        proxy.scrollTo(items[next].id)
    }

    private func removeSelectedIfFinished() -> KeyPress.Result {
        guard let item = selectedItem, item.state.isTerminal else { return .ignored }
        let index = engine.items.firstIndex { $0 === item }
        remove(item)
        if let index, !engine.items.isEmpty {
            selectedId = engine.items[min(index, engine.items.count - 1)].id
        } else {
            selectedId = nil
        }
        return .handled
    }

    /// What the Upload menu can do with the selected row.
    private var actions: UploadActions {
        let item = selectedItem
        return UploadActions(
            canCancel: item.map { $0.state.isActive || $0.state == .idle } ?? false,
            canRetry: item.map { $0.state.canRetry && $0.fileExists && engine.hasCredentials } ?? false,
            canCopyID: item?.videoId != nil,
            cancel: {
                if let item {
                    engine.cancelUpload(item)
                }
            },
            retry: {
                if let item {
                    askRetry(item)
                }
            },
            copyID: {
                if let videoId = item?.videoId {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(videoId, forType: .string)
                }
            },
            clearFinished: {
                clearFinished()
            }
        )
    }

    /// Retry continues or finishes without asking; only a full upload from the start is confirmed.
    private func askRetry(_ item: UploadItem) {
        Task {
            if await engine.retryStartsOver(item) {
                restartCandidate = item
            } else {
                engine.retry(item)
            }
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Removes one row; Command-Z puts it back. A video that never finished is deleted
    /// in Bunny at once, so the restored row uploads into a new video on Retry.
    private func remove(_ item: UploadItem) {
        engine.removeItem(item)
        let engine = engine
        undoManager?.registerUndo(withTarget: engine) { target in
            MainActor.assumeIsolated {
                target.reinsert([item])
            }
        }
        undoManager?.setActionName(String(localized: "Remove"))
    }

    private func clearFinished() {
        let removed = engine.clearFinished()
        guard !removed.isEmpty else { return }
        let engine = engine
        undoManager?.registerUndo(withTarget: engine) { target in
            MainActor.assumeIsolated {
                target.reinsert(removed)
            }
        }
        undoManager?.setActionName(String(localized: "Clear Finished"))
    }
}
