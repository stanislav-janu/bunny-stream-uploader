import SwiftUI
import BunnyUploaderCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: UploadEngine
    @Environment(\.undoManager) private var undoManager
    @State private var isTargeted = false
    /// A row whose Retry would upload the whole file again; the alert asks first.
    @State private var restartCandidate: UploadItem?

    var body: some View {
        VStack(spacing: 0) {
            header

            DropZone(isTargeted: $isTargeted, hasCredentials: engine.hasCredentials) { urls in
                for url in urls {
                    engine.addFile(url)
                }
            }
            .padding(16)

            Divider()

            if engine.items.isEmpty {
                emptyState
            } else {
                uploadList
            }
        }
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
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.to.line.circle.fill")
                .foregroundStyle(.tint)
                .font(.title2)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bunny Stream Uploader")
                    .font(.headline)
                if engine.hasCredentials {
                    Text("Ready")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Credentials missing", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if engine.activeCount > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.1f MB/s", engine.totalThroughputMBps))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.tint)
                    Text("\(engine.activeCount) concurrent")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            Image(systemName: "tray.and.arrow.up")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
            Text("No uploads")
                .foregroundStyle(.secondary)
            Text("Drag a video file into the window above.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var uploadList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(engine.items) { item in
                    UploadRowView(
                        item: item,
                        hasCredentials: engine.hasCredentials,
                        onRemove: { remove(item) },
                        onCancel: { engine.cancelUpload(item) },
                        onRetry: { askRetry(item) }
                    )
                }
            }
            .padding(16)
        }
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
