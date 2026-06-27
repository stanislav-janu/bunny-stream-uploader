import SwiftUI

struct UploadRowView: View {
    @ObservedObject var item: UploadItem
    let onRemove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "film")
                    .foregroundStyle(.secondary)
                Text(item.fileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Self.formatBytes(item.fileSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if item.state.isActive {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .help("Cancel upload")
                } else if item.state.isTerminal {
                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove from list")
                }
            }

            ProgressView(value: item.progress)
                .tint(progressColor)

            HStack {
                Text(item.state.label)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Spacer()
                if item.state == .uploading {
                    Text(String(format: "%.1f MB/s", item.throughputMBps))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f %%", item.progress * 100))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
    }

    private var progressColor: Color {
        switch item.state {
        case .done: return .green
        case .error: return .red
        default: return .accentColor
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .error: return .red
        case .done: return .green
        default: return .secondary
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
