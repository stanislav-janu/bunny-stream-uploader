import Combine
import Foundation
import os
import SwiftUI

/// The heart of the app. Coordinates the upload flow, holds the queue and credentials,
/// computes aggregate throughput. Runs on the main actor; network work is
/// async (URLSession) or on TUSKit's internal queue, this layer only coordinates.
@MainActor
public final class UploadEngine: ObservableObject {
    @Published public private(set) var items: [UploadItem] = []
    @Published public var credentials: Credentials
    /// Aggregate throughput of running uploads in MB/s (published for the UI header).
    @Published public private(set) var totalThroughputMBps: Double = 0
    /// Number of currently running uploads.
    @Published public private(set) var activeCount: Int = 0
    /// Aggregate progress (0...1) across running uploads (for the Dock icon).
    @Published public private(set) var aggregateProgress: Double = 0

    /// UI side-effect hooks, set by the app layer (kept out of Core).
    public var onUploadFinished: ((UploadItem) -> Void)?
    public var onUploadFailed: ((UploadItem, String) -> Void)?

    /// Injection points for tests (mock URLProtocol). Default to production behavior.
    public var apiSession: URLSession = .shared
    public var parallelSessionConfiguration: URLSessionConfiguration?
    /// Where checked credentials are stored. Tests replace it to keep off the Keychain.
    public var persistCredentials: (Credentials) -> Void = { KeychainStore.save($0) }

    /// Saved upload list; `nil` keeps the list in memory only (tests).
    private let history: UploadHistoryStore?
    /// State observers per item, used to save the list on every state change.
    private var observers: [UUID: AnyCancellable] = [:]

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
    @Published public var partCount: Int {
        didSet { UserDefaults.standard.set(partCount, forKey: "partCount") }
    }
    /// Automatic thread count based on file size.
    @Published public var autoThreads: Bool {
        didSet { UserDefaults.standard.set(autoThreads, forKey: "autoThreads") }
    }
    /// Files below this threshold use a single stream (splitting small files is pointless).
    private let parallelThresholdBytes: Int64 = 50 * 1024 * 1024

    /// Recommended thread count by file size (measured scaling curve).
    public static func autoPartCount(for fileSize: Int64) -> Int {
        let mb: Int64 = 1024 * 1024
        let gb: Int64 = 1024 * mb
        if fileSize >= gb { return 64 }
        if fileSize >= 500 * mb { return 32 }
        if fileSize >= 100 * mb { return 16 }
        return 8
    }

    /// Thread count chosen for a given file (auto or manual).
    public func threadCount(for fileSize: Int64) -> Int {
        return autoThreads ? Self.autoPartCount(for: fileSize) : partCount
    }

    /// Pass `credentials` to skip the Keychain read (used by tests).
    /// Pass `history` to load and save the upload list (the app passes `.standard()`).
    public init(credentials: Credentials? = nil, history: UploadHistoryStore? = nil) {
        self.credentials = credentials ?? KeychainStore.load()
        self.history = history
        let stored = UserDefaults.standard.integer(forKey: "partCount")
        self.partCount = stored > 0 ? stored : 64
        self.autoThreads = UserDefaults.standard.object(forKey: "autoThreads") as? Bool ?? true
        if let history {
            items = history.load().map { UploadItem(restoring: $0) }
            for item in items {
                observe(item)
            }
            // Interrupted rows are saved as such right away.
            saveHistory()
        }
    }

    public var hasCredentials: Bool {
        return credentials.isComplete
    }

    /// Recomputes aggregate metrics for the header and Dock. Call on state/progress change.
    private func recomputeAggregate() {
        activeCount = items.filter { $0.state.isActive }.count
        let uploading = items.filter { $0.state == .uploading }
        totalThroughputMBps = uploading.reduce(0) { $0 + $1.throughputMBps }
        if uploading.isEmpty {
            aggregateProgress = 0
        } else {
            let total = uploading.reduce(0.0) { $0 + Double($1.fileSize) }
            let done = uploading.reduce(0.0) { $0 + Double($1.bytesUploaded) }
            aggregateProgress = total > 0 ? done / total : 0
        }
    }

    public func saveCredentials(_ new: Credentials) {
        credentials = new
        persistCredentials(new)
    }

    /// Checks the credentials with Bunny and stores them only when Bunny accepts them.
    /// Returns the reason when it does not.
    public func checkAndSaveCredentials(_ new: Credentials) async -> BunnyAPIClient.CredentialCheckError? {
        let client = BunnyAPIClient(credentials: new, session: apiSession)
        do {
            try await client.checkCredentials()
        } catch {
            return error
        }
        saveCredentials(new)
        return nil
    }

    // MARK: - History

    private func observe(_ item: UploadItem) {
        observers[item.id] = item.$state
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] state in
                guard let self, let item else { return }
                MainActor.assumeIsolated {
                    if state.isTerminal, item.finishedAt == nil {
                        item.finishedAt = Date()
                    }
                    // Rows changing state affect engine-level UI such as Clear Finished.
                    self.objectWillChange.send()
                    self.saveHistory()
                }
            }
    }

    private func saveHistory() {
        history?.save(items.map(\.record))
    }

    /// Done rows that Clear Finished would remove.
    public var hasFinished: Bool {
        return items.contains { $0.state == .done }
    }

    /// Removes every done row and returns them, so the caller can offer Undo.
    @discardableResult
    public func clearFinished() -> [UploadItem] {
        let removed = items.filter { $0.state == .done }
        items.removeAll { $0.state == .done }
        for item in removed {
            observers[item.id] = nil
        }
        saveHistory()
        return removed
    }

    /// Puts rows back (Undo Clear Finished), newest on top.
    public func reinsert(_ restored: [UploadItem]) {
        for item in restored where !items.contains(where: { $0 === item }) {
            items.append(item)
            observe(item)
        }
        items.sort { ($0.finishedAt ?? .distantFuture) > ($1.finishedAt ?? .distantFuture) }
        saveHistory()
    }

    // MARK: - Queue

    /// Adds a file to the queue and starts its upload right away.
    public func addFile(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values?.fileSize ?? 0)
        let mime = values?.contentType?.preferredMIMEType ?? "application/octet-stream"
        let item = UploadItem(
            fileURL: url,
            fileName: url.lastPathComponent,
            fileSize: size,
            mimeType: mime
        )
        items.insert(item, at: 0)
        observe(item)
        saveHistory()
        Task { await self.process(item) }
    }

    /// Removes a row. A video that never finished uploading is deleted in Bunny too;
    /// a done video stays there.
    public func removeItem(_ item: UploadItem) {
        cancelUpload(item)
        if item.state != .done, item.state != .processing {
            discardVideo(item)
        }
        items.removeAll { $0 === item }
        samples[item.id] = nil
        observers[item.id] = nil
        saveHistory()
    }

    /// Uploads a failed, cancelled, or interrupted file again, into the same
    /// Bunny video when one was already created in the current library.
    public func retry(_ item: UploadItem) {
        guard item.state.canRetry else { return }
        guard item.fileExists else {
            item.state = .error(String(localized: "The file was moved or deleted. Drop it again to upload."))
            return
        }
        item.bytesUploaded = 0
        item.throughputMBps = 0
        item.finishedAt = nil
        samples[item.id] = nil
        item.state = .idle
        Task { await self.process(item) }
    }

    /// Cancels an item's in-progress upload.
    public func cancelUpload(_ item: UploadItem) {
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
        discardVideo(item)
    }

    private static let logger = Logger(subsystem: "net.bunnyuploader.BunnyUploader", category: "engine")

    /// Deletes the item's unfinished video in Bunny, so cancelled uploads leave no
    /// empty videos behind. Runs in the background; a failure is only logged.
    private func discardVideo(_ item: UploadItem) {
        guard let guid = item.videoId else { return }
        item.videoId = nil
        guard item.libraryId == nil || item.libraryId == credentials.libraryId else { return }
        deleteVideo(guid: guid)
    }

    private func deleteVideo(guid: String) {
        let client = BunnyAPIClient(credentials: credentials, session: apiSession)
        Task {
            do {
                try await client.deleteVideo(guid: guid)
            } catch {
                Self.logger.error("Could not delete video \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Single upload flow

    private func process(_ item: UploadItem) async {
        guard credentials.isComplete else {
            item.state = .error(String(localized: "Missing API key or Library ID (Settings)"))
            return
        }

        // 1) Create Video, or reuse the one a retried upload already has.
        item.state = .creatingVideo
        recomputeAggregate()
        let guid: String
        var createdNow = false
        if let existing = item.videoId, item.libraryId == credentials.libraryId {
            guid = existing
        } else {
            createdNow = true
            let client = BunnyAPIClient(credentials: credentials, session: apiSession)
            do {
                guid = try await client.createVideo(title: item.fileName)
            } catch {
                item.state = .error(error.localizedDescription)
                recomputeAggregate()
                onUploadFailed?(item, error.localizedDescription)
                return
            }
        }
        // The user may have cancelled the upload in the meantime; drop the new video then.
        guard item.state == .creatingVideo else {
            // A reused video was already deleted by Cancel.
            if createdNow {
                deleteVideo(guid: guid)
            }
            return
        }
        item.videoId = guid
        item.libraryId = credentials.libraryId

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
        let uploader = ParallelTUSUploader(sessionConfiguration: parallelSessionConfiguration)
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
            onUploadFailed?(item, error.localizedDescription)
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
                        self?.onUploadFailed?(item, error.localizedDescription)
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
        onUploadFinished?(item)
        // Optionally track transcoding status.
        Task { await self.pollProcessing(item) }
    }

    private func pollProcessing(_ item: UploadItem) async {
        guard let guid = item.videoId else {
            item.state = .done
            return
        }
        let client = BunnyAPIClient(credentials: credentials, session: apiSession)
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
