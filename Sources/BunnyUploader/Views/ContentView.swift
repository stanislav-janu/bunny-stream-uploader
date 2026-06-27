import SwiftUI
import BunnyUploaderCore
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var engine: UploadEngine
    @State private var isTargeted = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header

            DropZone(isTargeted: $isTargeted) { urls in
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
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
                Text(engine.hasCredentials ? "Ready" : "Missing credentials. Open Settings (⌘,)")
                    .font(.caption)
                    .foregroundStyle(engine.hasCredentials ? Color.secondary : Color.red)
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
                        onRemove: { engine.removeItem(item) },
                        onCancel: { engine.cancelUpload(item) }
                    )
                }
            }
            .padding(16)
        }
    }
}
