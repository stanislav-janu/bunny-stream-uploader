import Foundation

/// State of a single upload through its lifecycle.
enum UploadState: Equatable {
    case idle
    case creatingVideo
    case uploading
    case processing
    case done
    case cancelled
    case error(String)

    var label: String {
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

    var isTerminal: Bool {
        switch self {
        case .done, .cancelled, .error: return true
        default: return false
        }
    }

    /// An in-progress state that can be cancelled.
    var isActive: Bool {
        switch self {
        case .creatingVideo, .uploading: return true
        default: return false
        }
    }
}

/// One item in the upload queue. Observable so the UI reacts to changes.
@MainActor
final class UploadItem: ObservableObject, Identifiable {
    let id = UUID()
    let fileURL: URL
    let fileName: String
    let fileSize: Int64
    let mimeType: String

    @Published var state: UploadState = .idle
    @Published var bytesUploaded: Int64 = 0
    @Published var throughputMBps: Double = 0
    @Published var videoId: String?

    init(fileURL: URL, fileName: String, fileSize: Int64, mimeType: String) {
        self.fileURL = fileURL
        self.fileName = fileName
        self.fileSize = fileSize
        self.mimeType = mimeType
    }

    var progress: Double {
        guard fileSize > 0 else { return 0 }
        return min(1, Double(bytesUploaded) / Double(fileSize))
    }
}
