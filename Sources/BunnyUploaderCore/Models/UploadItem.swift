import Foundation

/// State of a single upload through its lifecycle.
public enum UploadState: Equatable {
    case idle
    case creatingVideo
    case uploading
    case processing
    case done
    case cancelled
    case error(String)

    public var label: String {
        switch self {
        case .idle: return String(localized: "Waiting")
        case .creatingVideo: return String(localized: "Creating video")
        case .uploading: return String(localized: "Uploading")
        case .processing: return String(localized: "Bunny processing")
        case .done: return String(localized: "Done")
        case .cancelled: return String(localized: "Cancelled")
        case .error(let message): return String(localized: "Error: \(message)")
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .error: return true
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
}

/// One item in the upload queue. Observable so the UI reacts to changes.
@MainActor
public final class UploadItem: ObservableObject, Identifiable {
    public let id = UUID()
    public let fileURL: URL
    public let fileName: String
    public let fileSize: Int64
    public let mimeType: String

    @Published public var state: UploadState = .idle
    @Published public var bytesUploaded: Int64 = 0
    @Published public var throughputMBps: Double = 0
    @Published public var videoId: String?

    public init(fileURL: URL, fileName: String, fileSize: Int64, mimeType: String) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }

    public var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1, Double(bytesUploaded) / Double(fileSize))
    }
}
