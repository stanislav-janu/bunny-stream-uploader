import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop zone for video files. Without credentials it asks for them instead.
struct DropZone: View {
    @Binding var isTargeted: Bool
    let hasCredentials: Bool
    let onDrop: ([URL]) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: Layout.dropBorderWidth, dash: Layout.dropBorderDash)
            )
            .foregroundStyle(isTargeted ? Color.accentColor : Surface.dropBorder)
            .background(
                RoundedRectangle(cornerRadius: Radius.md, style: .continuous)
                    .fill(isTargeted ? Surface.dropTarget : Color.clear)
            )
            .frame(height: Layout.dropZoneHeight)
            .overlay {
                if hasCredentials {
                    readyContent
                } else {
                    missingCredentialsContent
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
            }
    }

    private var readyContent: some View {
        VStack(spacing: Space.s) {
            Image(systemName: isTargeted ? "arrow.down.circle.fill" : "square.and.arrow.down")
                .font(.system(size: Layout.dropSymbol))
            Text("Drop videos here")
                .font(.callout)
        }
        .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
    }

    private var missingCredentialsContent: some View {
        VStack(spacing: Space.s) {
            Text("Add your Bunny credentials to start uploading.")
                .font(.callout)
                .foregroundStyle(.secondary)
            SettingsLink {
                Text("Open Settings…")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var collected: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    collected.append(url)
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            if !collected.isEmpty {
                onDrop(collected)
            }
        }
        return true
    }
}
