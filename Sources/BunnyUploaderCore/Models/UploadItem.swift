import Foundation

/// State of a single upload through its lifecycle.
public enum UploadState: Equatable, Codable, Sendable {
    case idle
    case creatingVideo
    case uploading
    case processing
    case done
    case cancelled
    /// Was running when the app quit or crashed.
    case interrupted
    case error(String)

    public var label: String {
        switch self {
        case .idle: return String(localized: "Waiting")
        case .creatingVideo: return String(localized: "Creating video")
        case .uploading: return String(localized: "Uploading")
        case .processing: return String(localized: "Bunny processing")
        case .done: return String(localized: "Done")
        case .cancelled: return String(localized: "Cancelled")
        case .interrupted: return String(localized: "Interrupted")
        case .error: return String(localized: "Failed")
        }
    }

    /// The reason of a failed upload, shown on its own line under the state.
    public var errorMessage: String? {
        if case .error(let message) = self {
            return message
        }
        return nil
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .interrupted, .error: return true
        default: return false
        }
    }

    /// An in-progress state that can be cancelled.
    public var isActive: Bool {
        switch self {
        case .creatingVideo, .uploading: return true
        default: return false
        }
    }

    /// A stopped upload that Retry can start again.
    public var canRetry: Bool {
        switch self {
        case .cancelled, .interrupted, .error: return true
        default: return false
        }
    }

    /// The state a saved row loads with after a restart: a row that was
    /// running becomes interrupted, a row Bunny was processing is done.
    public var restored: UploadState {
        switch self {
        case .idle, .creatingVideo, .uploading: return .interrupted
        case .processing: return .done
        default: return self
        }
    }
}

/// One item in the upload queue. Observable so the UI reacts to changes.
@MainActor
public final class UploadItem: ObservableObject, Identifiable {
    public let id: UUID
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String

    @Published public var state: UploadState = .idle
    @Published public var bytesUploaded: Int64 = 0
    @Published public var throughputMBps: Double = 0
    @Published public var videoId: String?
    /// Library the video was created in (kept so links stay right after a library change).
    @Published public var libraryId: String?
    /// When the upload reached a terminal state.
    @Published public var finishedAt: Date?

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        fileName: String,
        fileSize: Int64,
        mimeType: String
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }

    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1, Double(bytesUploaded) / Double(fileSize))
    }

    /// Embed player link, once the video exists.
    public var embedLink: String? {
        guard let videoId, let libraryId else { return nil }
        return BunnyAPIClient.embedLink(libraryId: libraryId, videoId: videoId)
    }

    /// Whether the source file is still where it was dropped from.
    public var fileExists: Bool {
        return FileManager.default.fileExists(atPath: fileURL.path)
    }
}
