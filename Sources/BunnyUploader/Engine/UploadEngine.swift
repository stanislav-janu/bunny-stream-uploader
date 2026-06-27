import Foundation
import SwiftUI

/// The heart of the app. Coordinates the upload flow, holds the queue and credentials,
/// computes aggregate throughput. Runs on the main actor; network work is
/// async (URLSession) or on TUSKit's internal queue, this layer only coordinates.
@MainActor
final class UploadEngine: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    @Published var credentials: Credentials
    /// Aggregate throughput of running uploads in MB/s (published for the UI header).
    @Published private(set) var totalThroughputMBps: Double = 0
    /// Number of currently running uploads.
    @Published private(set) var activeCount: Int = 0

    private let tus = TUSUploader()

    /// Per-upload progress history for a moving-average throughput over a window,
    /// so batched block completions do not show false spikes.
    private struct Sample {
        var history: [(t: Date, bytes: Int64)] = []
    }
    private var samples: [UUID: Sample] = [:]
    /// Moving-average window for throughput.
    private let throughputWindow: TimeInterval = 4
    /// Maps a queue item to its running TUSKit upload (for cancellation).
    private var tusIds: [UUID: UUID] = [:]
    /// Maps a queue item to its running parallel concatenation upload (for cancellation).
    private var parallelUploaders: [UUID: ParallelTUSUploader] = [:]

    /// Number of parallel threads to split a single file into (manual mode).
    @Published var partCount: Int {
        didSet { UserDefaults.standard.set(partCount, forKey: "partCount") }
    }
    /// Automatic thread count based on file size.
    @Published var autoThreads: Bool {
        didSet { UserDefaults.standard.set(autoThreads, forKey: "autoThreads") }
    }
    /// Files below this threshold use a single stream (splitting small files is pointless).
    private let parallelThresholdBytes: Int64 = 50 * 1024 * 1024

    /// Recommended thread count by file size (measured scaling curve).
    static func autoPartCount(for fileSize: Int64) -> Int {
        let mb: Int64 = 1024 * 1024
        let gb: Int64 = 1024 * mb
        if fileSize >= gb { return 64 }
        if fileSize >= 500 * mb { return 32 }
        if fileSize >= 100 * mb { return 16 }
        return 8
    }

    /// Thread count chosen for a given file (auto or manual).
    func threadCount(for fileSize: Int64) -> Int {
        return autoThreads ? Self.autoPartCount(for: fileSize) : partCount
    }

    init() {
        self.credentials = KeychainStore.load()
        let stored = UserDefaults.standard.integer(forKey: "partCount")
        self.partCount = stored > 0 ? stored : 64
        self.autoThreads = UserDefaults.standard.object(forKey: "autoThreads") as? Bool ?? true
    }

    var hasCredentials: Bool {
        return credentials.isComplete
    }

    /// Recomputes aggregate metrics for the header. Call on state/progress change.
    private func recomputeAggregate() {
        activeCount = items.filter { $0.state.isActive }.count
        totalThroughputMBps = items
            .filter { $0.state == .uploading }
            .reduce(0) { $0 + $1.throughputMBps }
    }

    func saveCredentials(_ new: Credentials) {
        credentials = new
        KeychainStore.save(new)
    }

    // MARK: - Queue

    /// Adds a file to the queue and starts its upload right away.
    func addFile(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values?.fileSize ?? 0)
        let mime = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
        let item = UploadItem(
            fileURL: url,
            fileName: url.lastPathComponent,
            fileSize: size,
            mimeType: mime
        )
        items.append(item)
        Task { await self.process(item) }
    }

    func removeItem(_ item: UploadItem) {
        cancelUpload(item)
        items.removeAll { $0 === item }
        samples[item.id] = nil
    }

    /// Cancels an item's in-progress upload.
    func cancelUpload(_ item: UploadItem) {
        guard item.state.isActive else { return }
        if let tusId = tusIds[item.id] {
            tus.cancel(id: tusId)
        }
        if let uploader = parallelUploaders[item.id] {
            uploader.cancel()
        }
        tusIds[item.id] = nil
        parallelUploaders[item.id] = nil
        samples[item.id] = nil
        item.throughputMBps = 0
        item.state = .cancelled
        recomputeAggregate()
    }

    // MARK: - Single upload flow

    private func process(_ item: UploadItem) async {
        guard credentials.isComplete else {
            item.state = .error(String(localized: "Missing API key or Library ID (Settings)"))
            return
        }

        // 1) Create Video
        item.state = .creatingVideo
        recomputeAggregate()
        let client = BunnyAPIClient(credentials: credentials)
        let guid: String
        do {
            guid = try await client.createVideo(title: item.fileName)
        } catch {
            item.state = .error(error.localizedDescription)
            return
        }
        // The user may have cancelled the upload in the meantime.
        guard item.state == .creatingVideo else { return }
        item.videoId = guid

        // 2) Signature + headers
        let signed = Signature.make(
            libraryId: credentials.libraryId,
            apiKey: credentials.apiKey,
            videoId: guid
        )
        let headers = [
            "AuthorizationSignature": signed.value,
            "AuthorizationExpire": signed.expiration,
            "LibraryId": credentials.libraryId,
            "VideoId": guid,
        ]
        let context = [
            "title": item.fileName,
            "filetype": item.mimeType,
        ]

        // 3) Start the upload; pick a strategy
        item.state = .uploading
        recomputeAggregate()
        samples[item.id] = Sample()

        let threads = threadCount(for: item.fileSize)
        let useParallel = threads > 1 && item.fileSize >= parallelThresholdBytes
        if useParallel {
            await runParallel(item, headers: headers, metadata: context, partCount: threads)
        } else {
            runSingleStream(item, headers: headers, context: context)
        }
    }

    /// Parallel upload of a single file via TUS concatenation (N threads).
    private func runParallel(_ item: UploadItem, headers: [String: String], metadata: [String: String], partCount: Int) async {
        let uploader = ParallelTUSUploader()
        parallelUploaders[item.id] = uploader
        let id = item.id
        do {
            _ = try await uploader.upload(
                fileURL: item.fileURL,
                fileSize: item.fileSize,
                partCount: partCount,
                authHeaders: headers,
                metadata: metadata,
                onProgress: { [weak self] bytes in
                    Task { @MainActor in
                        self?.handleProgress(item, bytes: bytes)
                    }
                }
            )
            parallelUploaders[id] = nil
            handleSuccess(item)
        } catch {
            guard item.state == .uploading else { return }
            parallelUploaders[id] = nil
            samples[id] = nil
            item.throughputMBps = 0
            item.state = .error(error.localizedDescription)
            recomputeAggregate()
        }
    }

    /// Robust single-stream TUS upload (TUSKit), fallback and small files.
    private func runSingleStream(_ item: UploadItem, headers: [String: String], context: [String: String]) {
        do {
            let tusId = try tus.start(
                fileURL: item.fileURL,
                customHeaders: headers,
                context: context,
                handlers: TUSUploader.Handlers(
                    onProgress: { [weak self] bytes in
                        self?.handleProgress(item, bytes: bytes)
                    },
                    onSuccess: { [weak self] in
                        self?.handleSuccess(item)
                    },
                    onFailure: { [weak self] error in
                        guard item.state == .uploading else { return }
                        item.state = .error(error.localizedDescription)
                        self?.samples[item.id] = nil
                        self?.tusIds[item.id] = nil
                        self?.recomputeAggregate()
                    }
                )
            )
            tusIds[item.id] = tusId
        } catch {
            item.state = .error(String(localized: "Could not start TUS: \(error.localizedDescription)"))
        }
    }

    private func handleProgress(_ item: UploadItem, bytes: Int64) {
        guard item.state == .uploading else { return }
        item.bytesUploaded = bytes
        guard var sample = samples[item.id] else { return }
        let now = Date()
        sample.history.append((now, bytes))
        // Drop samples older than the window.
        sample.history.removeAll { now.timeIntervalSince($0.t) > throughputWindow }
        samples[item.id] = sample
        // Moving average: byte delta over the actual time span in the window.
        if let first = sample.history.first {
            let dt = now.timeIntervalSince(first.t)
            if dt >= 1 {
                let db = Double(bytes - first.bytes)
                item.throughputMBps = db / dt / (1024 * 1024)
                recomputeAggregate()
            }
        }
    }

    private func handleSuccess(_ item: UploadItem) {
        guard item.state == .uploading else { return }
        item.bytesUploaded = item.fileSize
        item.throughputMBps = 0
        item.state = .processing
        samples[item.id] = nil
        tusIds[item.id] = nil
        recomputeAggregate()
        // Optionally track transcoding status.
        Task { await self.pollProcessing(item) }
    }

    private func pollProcessing(_ item: UploadItem) async {
        guard let guid = item.videoId else {
            item.state = .done
            return
        }
        let client = BunnyAPIClient(credentials: credentials)
        // A few attempts; Bunny status 3+ means done/playable.
        for _ in 0..<3 {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if let status = try? await client.getVideoStatus(guid: guid), status >= 3 {
                item.state = .done
                return
            }
        }
        // Processing continues on Bunny's side; for the user the upload is done.
        item.state = .done
    }
}
