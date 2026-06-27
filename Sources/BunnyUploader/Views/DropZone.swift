import SwiftUI
import UniformTypeIdentifiers

/// Drag-and-drop zone for video files.
struct DropZone: View {
    @Binding var isTargeted: Bool
    let onDrop: ([URL]) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: [8, 6])
            )
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isTargeted ? Color.accentColor.opacity(0.08) : Color.clear)
            )
            .frame(height: 110)
            .overlay {
                VStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 26))
                    Text("Drop a video here")
                        .font(.callout)
                }
                .foregroundStyle(isTargeted ? Color.accentColor : .secondary)
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                handleDrop(providers)
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
