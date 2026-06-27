import Foundation
import TUSKit

/// Thin wrapper over TUSKit's `TUSClient`. Holds a single client for the whole app
/// and maps TUSKit callbacks (progress/success/failure) to per-upload handlers.
///
/// TUSKit's `reportingQueue` defaults to `.main`, so delegate methods run on the main thread.
final class TUSUploader: NSObject, TUSClientDelegate {
    /// Handlers for a single upload. Called on the main thread.
    struct Handlers {
        let onProgress: (Int64) -> Void
        let onSuccess: () -> Void
        let onFailure: (Error) -> Void
    }

    static let endpoint = URL(string: "https://video.bunnycdn.com/tusupload")!

    /// Chunk size. TUSKit's 512 kB default throttles throughput to ~1.5 MB/s
    /// because of a round-trip after every chunk. A large chunk minimizes overhead and lets
    /// a single TCP stream run close to the link capacity.
    static let chunkSize = 64 * 1024 * 1024

    private let client: TUSClient
    private var handlers: [UUID: Handlers] = [:]

    override init() {
        let storageDirectory = TUSUploader.makeStorageDirectory()
        // Default httpMaximumConnectionsPerHost is 6 on macOS, which caps parallel
        // uploads. Raise it so as many connections run as there are concurrent uploads.
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 32
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 24 * 60 * 60
        do {
            client = try TUSClient(
                server: TUSUploader.endpoint,
                sessionIdentifier: "net.bunnyuploader.BunnyUploader.tus",
                sessionConfiguration: config,
                storageDirectory: storageDirectory,
                chunkSize: TUSUploader.chunkSize,
                supportedExtensions: [.creation]
            )
        } catch {
            fatalError("Failed to initialize TUSClient: \(error)")
        }
        super.init()
        client.delegate = self
    }

    /// Starts a TUS upload of the file. Returns the TUSKit upload id.
    /// `customHeaders` nesou Bunny autorizaci, `context` nese Upload-Metadata (title, filetype).
    @discardableResult
    func start(
        fileURL: URL,
        customHeaders: [String: String],
        context: [String: String],
        handlers: Handlers
    ) throws -> UUID {
        let id = try client.uploadFileAt(
            filePath: fileURL,
            customHeaders: customHeaders,
            context: context
        )
        self.handlers[id] = handlers
        return id
    }

    /// Cancels an in-progress upload and deletes its persisted state.
    func cancel(id: UUID) {
        handlers[id] = nil
        _ = try? client.cancelAndDelete(id: id)
    }

    // MARK: - TUSClientDelegate

    func progressFor(id: UUID, context: [String: String]?, bytesUploaded: Int, totalBytes: Int, client: TUSClient) {
        handlers[id]?.onProgress(Int64(bytesUploaded))
    }

    func didFinishUpload(id: UUID, url: URL, context: [String: String]?, client: TUSClient) {
        handlers[id]?.onSuccess()
        handlers[id] = nil
    }

    func uploadFailed(id: UUID, error: Error, context: [String: String]?, client: TUSClient) {
        handlers[id]?.onFailure(error)
        handlers[id] = nil
    }

    func didStartUpload(id: UUID, context: [String: String]?, client: TUSClient) {}

    func fileError(error: TUSClientError, client: TUSClient) {}

    func totalProgress(bytesUploaded: Int, totalBytes: Int, client: TUSClient) {}

    // MARK: - Storage

    private static func makeStorageDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base
            .appendingPathComponent("BunnyUploader", isDirectory: true)
            .appendingPathComponent("tus", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
