import AppKit
import SwiftUI
import BunnyUploaderCore

struct UploadRowView: View {
    @ObservedObject var item: UploadItem
    let hasCredentials: Bool
    var isSelected = false
    /// Place in the upload queue while Waiting.
    var queuePosition: Int?
    let onRemove: () -> Void
    let onCancel: () -> Void
    let onRetry: () -> Void

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            titleLine

            ProgressView(value: item.progress)
                .tint(progressColor)

            statusLine

            if let message = item.state.errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(message)
            }

            if let videoId = item.videoId {
                videoIdLine(videoId)
            }
        }
        .padding(Space.m)
        .background(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .fill(isSelected ? Surface.rowSelected : Surface.row)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(isSelected ? Surface.rowSelectedBorder : Color.clear, lineWidth: Layout.selectionBorderWidth)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .contextMenu {
            contextMenuItems
        }
    }

    // MARK: - Lines

    private var titleLine: some View {
        HStack {
            Image(systemName: "film")
                .foregroundStyle(.secondary)
            Text(item.fileName)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(item.fileName)
            Spacer()
            Text(Self.formatBytes(item.fileSize))
                .font(.caption)
                .foregroundStyle(.secondary)
            actionButtons
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if item.state.isActive || item.state == .idle {
            Button {
                onCancel()
            } label: {
                Image(systemName: "stop.circle.fill")
                    .foregroundStyle(Palette.failure)
            }
            .buttonStyle(.plain)
            .help("Cancel this upload and delete the unfinished video in Bunny")
            .accessibilityLabel(Text("Cancel"))
        } else if item.state.isTerminal {
            if item.state.errorMessage != nil, !hasCredentials {
                SettingsLink {
                    Text("Open Settings…")
                }
                .controlSize(.small)
            } else if item.state.canRetry, item.fileExists {
                Button("Retry") {
                    onRetry()
                }
                .controlSize(.small)
                .help("Upload this file again into the same video")
            }
            Button {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help(item.state == .done ? Text("Remove from the list. The video stays in Bunny.") : Text("Remove from the list and delete the unfinished video in Bunny"))
            .accessibilityLabel(Text("Remove"))
        }
    }

    private var statusLine: some View {
        HStack {
            Label {
                Text(item.state.label)
            } icon: {
                Image(systemName: statusIcon)
            }
            .font(.caption)
            .foregroundStyle(statusColor)
            if item.state == .done, let processing = item.processing {
                processingLabel(processing)
            }
            Spacer()
            if item.state == .idle, let queuePosition {
                Text("Position \(queuePosition) in the queue")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if item.state == .uploading {
                Text(String(format: "%.1f MB/s", item.throughputMBps))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(String(format: "%.0f %%", item.progress * 100))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if item.state.isTerminal, let finishedAt = item.finishedAt {
                Text(Self.timeFormatter.string(from: finishedAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func videoIdLine(_ videoId: String) -> some View {
        HStack(spacing: Space.s) {
            Text("Video ID")
                .font(.caption)
                .foregroundStyle(.tertiary)
            // The whole ID is the control: one click copies it.
            Button {
                copy(videoId)
            } label: {
                HStack(spacing: Space.xs) {
                    Text(videoId)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                    if copied {
                        Text("Copied")
                            .font(.caption)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Palette.success : Color.secondary)
            .help(Text("Click to copy the video ID: \(videoId)"))
            .accessibilityLabel(Text("Copy ID"))
            .accessibilityValue(Text(videoId))
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let videoId = item.videoId {
            Button("Copy ID") {
                copy(videoId)
            }
        }
        if item.videoId != nil, item.state == .done {
            if let link = item.embedLink {
                Button("Copy Embed Link") {
                    Self.writeToPasteboard(link)
                }
            }
            if let playLink = item.playLink {
                Button("Play in Browser") {
                    NSWorkspace.shared.open(playLink)
                }
            }
        }
        if item.videoId != nil {
            Divider()
        }
        if let message = item.state.errorMessage {
            Button("Copy Error Message") {
                Self.writeToPasteboard(message)
            }
        }
        if item.state.canRetry, item.fileExists, hasCredentials {
            Button("Retry") {
                onRetry()
            }
        }
        if item.state.isActive || item.state == .idle {
            Button("Cancel") {
                onCancel()
            }
        }
        if item.fileExists {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.fileURL])
            }
        }
        if item.state.isTerminal {
            Button("Remove") {
                onRemove()
            }
        }
    }

    private func processingLabel(_ processing: BunnyProcessing) -> some View {
        Label {
            Text(processing.label)
        } icon: {
            switch processing {
            case .processing:
                Image(systemName: "hourglass")
            case .ready:
                Image(systemName: "play.circle.fill")
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill")
            }
        }
        .font(.caption)
        .foregroundStyle(processing == .failed ? Palette.failure : Color.secondary)
        .help(processing == .processing ? Text("Bunny is transcoding the video. The video ID already works.") : Text(processing.label))
    }

    // MARK: - Helpers

    private func copy(_ videoId: String) {
        Self.writeToPasteboard(videoId)
        copied = true
        AccessibilityNotification.Announcement(String(localized: "Copied")).post()
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }

    private static func writeToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private var statusIcon: String {
        switch item.state {
        case .done: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        case .cancelled: return "stop.circle"
        case .interrupted: return "pause.circle"
        default: return "arrow.up.circle"
        }
    }

    private var progressColor: Color {
        switch item.state {
        case .done: return Palette.success
        case .error: return Palette.failure
        default: return .accentColor
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .error: return Palette.failure
        case .done: return Palette.success
        default: return .secondary
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
