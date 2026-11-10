import Foundation

/// A thin custom TUS layer for parallel upload of a SINGLE file via the
/// `concatenation` extension. Splits the file into N parts, each uploaded over its own TCP
/// connection (its own URLSession with 1 connection per host), then sends the final
/// `Upload-Concat: final` request, which Bunny merges into one video.
///
/// Deliberately NOT an actor: parts run in parallel and disk reads go through `pread`
/// on a dedicated concurrent queue, so no thread blocks the others or the
/// cooperative async pool. Shared state is protected by a lock.
public final class ParallelTUSUploader: @unchecked Sendable {
    public struct Result {
        public let bytesUploaded: Int64
        public let elapsed: TimeInterval
    }

    public enum UploadError: LocalizedError, Equatable {
        case open(String)
        case read(Int)
        case partialCreateFailed(Int, String)
        case patchFailed(Int, String)
        case finalFailed(Int, String)
        case missingLocation
        case cancelled
        /// Bunny answered 401 twice in a row, also after a fresh signature.
        case signatureRejected

        public var errorDescription: String? {
            switch self {
            case .open(let path): return String(localized: "Could not open file: \(path)")
            case .read(let code): return String(localized: "File read error (errno \(code))")
            case .partialCreateFailed(let code, let body):
                return String(localized: "Creating part failed (HTTP \(code)): \(String(body.prefix(200)))")
            case .patchFailed(let code, let body):
                return String(localized: "Part upload failed (HTTP \(code)): \(String(body.prefix(200)))")
            case .finalFailed(let code, let body):
                return String(localized: "Final concatenation failed (HTTP \(code)): \(String(body.prefix(200)))")
            case .missingLocation: return String(localized: "Server did not return a part Location URL")
            case .cancelled: return String(localized: "Cancelled")
            case .signatureRejected: return String(localized: "Bunny rejected the signature")
            }
        }
    }

    private let endpoint = URL(string: "https://video.bunnycdn.com/tusupload")!
    /// Size of one PATCH block within a part. Smaller block = smoother progress
    /// (frequent Upload-Offset updates); round-trip overhead is negligible against transfer time.
    private let patchBlockSize = 4 * 1024 * 1024
    /// Concurrent queue for blocking disk reads, off the cooperative async pool.
    private let ioQueue = DispatchQueue(label: "net.bunnyuploader.BunnyUploader.fileio", attributes: .concurrent)

    private let lock = NSLock()
    private var _totalBytesUploaded: Int64 = 0
    private var _cancelled = false
    /// Auth headers in use; replaced when a 401 asks for a fresh signature.
    private var _authHeaders: [String: String] = [:]

    /// Waits before each retry of a failed request (network error, 408, 409, 429, 5xx).
    /// When they run out, the upload fails.
    public static let defaultRetryDelays: [TimeInterval] = [0, 3, 5, 10, 20, 60]
    private let retryDelays: [TimeInterval]

    /// Base config for each part's session. One TCP connection per host by default;
    /// tests inject a config with a mock URLProtocol.
    private let sessionConfiguration: URLSessionConfiguration

    public init(
        sessionConfiguration: URLSessionConfiguration? = nil,
        retryDelays: [TimeInterval] = ParallelTUSUploader.defaultRetryDelays
    ) {
        self.retryDelays = retryDelays
        if let sessionConfiguration {
            self.sessionConfiguration = sessionConfiguration
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.httpMaximumConnectionsPerHost = 1
            config.timeoutIntervalForRequest = 600
            config.timeoutIntervalForResource = 24 * 60 * 60
            self.sessionConfiguration = config
        }
    }

    /// Diagnostic logging to a file (no sensitive data).
    /// ~/Library/Application Support/BunnyUploader/debug.log
    static let logFileURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("BunnyUploader", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("debug.log")
    }()

    private var logStart = Date()
    private let logLock = NSLock()

    private func resetLog() {
        logLock.lock()
        try? Data().write(to: Self.logFileURL)
        logLock.unlock()
    }

    private func log(_ msg: String) {
        let t = String(format: "%7.2f", Date().timeIntervalSince(logStart))
        let line = "[\(t)s] \(msg)\n"
        logLock.lock()
        if let handle = try? FileHandle(forWritingTo: Self.logFileURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: Self.logFileURL)
        }
        logLock.unlock()
    }

    /// Starts the parallel upload. `onProgress` receives the total bytes uploaded.
    /// `resign` returns fresh auth headers when Bunny answers 401 (expired signature).
    /// `resumeParts` holds part URLs of an earlier, interrupted run (index -> URL); those parts
    /// continue from the offset Bunny confirms, and `onResumed` gets the bytes already there.
    /// `onPartCreated` reports each new part URL so the caller can save it for a later resume.
    public func upload(
        fileURL: URL,
        fileSize: Int64,
        partCount: Int,
        authHeaders: [String: String],
        metadata: [String: String],
        resign: (@Sendable () -> [String: String])? = nil,
        resumeParts: [Int: URL] = [:],
        onResumed: (@Sendable (Int64) -> Void)? = nil,
        onPartCreated: (@Sendable (Int, URL) -> Void)? = nil,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Result {
        lock.withLock {
            _totalBytesUploaded = 0
            _cancelled = false
            _authHeaders = authHeaders
        }

        let start = Date()
        logStart = start
        resetLog()

        let parts0 = Self.splitIntoParts(fileSize: fileSize, partCount: partCount)
        log("START upload: \(fileSize) B, \(parts0.count) parts of ~\(parts0.first?.length ?? 0) B, block \(patchBlockSize) B")

        // One shared file descriptor; pread reads from an offset and is thread-safe.
        let fd = open(fileURL.path, O_RDONLY)
        guard fd >= 0 else { throw UploadError.open(fileURL.path) }
        defer { close(fd) }

        let parts = Self.splitIntoParts(fileSize: fileSize, partCount: partCount)
        let metadataHeader = Self.encodeMetadata(metadata)

        // Resume: ask Bunny how far each saved part got. Unknown or expired parts start over.
        var starts: [Int: (url: URL, offset: Int64)] = [:]
        if !resumeParts.isEmpty {
            starts = try await resumeOffsets(resumeParts, parts: parts, resign: resign)
            let already = starts.values.reduce(Int64(0)) { $0 + $1.offset }
            lock.withLock {
                _totalBytesUploaded = already
            }
            log("RESUME: \(starts.count) of \(parts.count) parts known, \(already) B already on Bunny")
            onResumed?(already)
        }

        var partialURLs = [URL?](repeating: nil, count: parts.count)
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, part) in parts.enumerated() {
                let start = starts[index]
                group.addTask {
                    let url = try await self.uploadPart(
                        index: index,
                        fd: fd,
                        offset: part.offset,
                        length: part.length,
                        metadataHeader: metadataHeader,
                        resign: resign,
                        existing: start,
                        onPartCreated: onPartCreated,
                        onProgress: onProgress
                    )
                    return (index, url)
                }
            }
            for try await (index, url) in group {
                partialURLs[index] = url
            }
        }

        if isCancelled { throw UploadError.cancelled }
        log("all parts done in \(ms(start)), sending FINAL")

        let ordered = partialURLs.compactMap { $0 }
        let tFinal = Date()
        try await sendFinal(partialURLs: ordered, metadataHeader: metadataHeader, resign: resign)
        log("FINAL done in \(ms(tFinal)). TOTAL \(ms(start)), \(total/1_048_576)MB")

        return Result(bytesUploaded: total, elapsed: Date().timeIntervalSince(start))
    }

    public func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    // MARK: - Retry

    enum Disposition {
        case retry
        case resign
        case fail
    }

    /// What to do after an HTTP status: 401 asks for a new signature; 408, 409
    /// (offset conflict), 423 (part still locked by an aborted request), 429, and 5xx
    /// are worth another try; anything else fails.
    static func disposition(status: Int) -> Disposition {
        switch status {
        case 401: return .resign
        case 408, 409, 423, 429, 500..<600: return .retry
        default: return .fail
        }
    }

    private static func disposition(for error: Error) -> Disposition {
        if let error = error as? UploadError {
            switch error {
            case .partialCreateFailed(let code, _), .patchFailed(let code, _), .finalFailed(let code, _):
                return disposition(status: code)
            default:
                return .fail
            }
        }
        if let error = error as? URLError {
            return error.code == .cancelled ? .fail : .retry
        }
        return .fail
    }

    /// Runs `operation` until it succeeds, retrying with `retryDelays` and asking for
    /// a fresh signature once per 401. `operation` gets the current auth headers and
    /// whether this is a retry (so it can resync its offset first).
    private func withRetry<T>(
        _ label: String,
        resign: (@Sendable () -> [String: String])?,
        _ operation: ([String: String], Bool) async throws -> T
    ) async throws -> T {
        var attempt = 0
        var resignedSinceLastTry = false
        var isRetry = false
        while true {
            if isCancelled { throw UploadError.cancelled }
            do {
                let result = try await operation(currentHeaders, isRetry)
                return result
            } catch {
                if isCancelled { throw UploadError.cancelled }
                switch Self.disposition(for: error) {
                case .fail:
                    throw error
                case .resign:
                    guard let resign, !resignedSinceLastTry else {
                        throw UploadError.signatureRejected
                    }
                    log("\(label): HTTP 401, new signature")
                    replaceHeaders(resign())
                    resignedSinceLastTry = true
                    isRetry = true
                case .retry:
                    guard attempt < retryDelays.count else { throw error }
                    let delay = retryDelays[attempt]
                    attempt += 1
                    log("\(label): \(error.localizedDescription), retry \(attempt) in \(delay)s")
                    try await sleepUnlessCancelled(delay)
                    resignedSinceLastTry = false
                    isRetry = true
                }
            }
        }
    }

    /// Sleeps in short steps so Cancel does not wait for a long backoff.
    private func sleepUnlessCancelled(_ seconds: TimeInterval) async throws {
        var remaining = seconds
        while remaining > 0 {
            if isCancelled { throw UploadError.cancelled }
            let step = min(remaining, 0.25)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            remaining -= step
        }
    }

    // MARK: - Part (partial)

    /// Confirmed offsets of saved parts. A part Bunny no longer knows (404, 410) is left
    /// out and starts over.
    private func resumeOffsets(
        _ saved: [Int: URL],
        parts: [(offset: Int64, length: Int64)],
        resign: (@Sendable () -> [String: String])?
    ) async throws -> [Int: (url: URL, offset: Int64)] {
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        return try await withThrowingTaskGroup(of: (Int, URL, Int64?).self) { group in
            for (index, url) in saved where index < parts.count {
                group.addTask {
                    do {
                        let offset = try await self.withRetry("part \(index) HEAD", resign: resign) { headers, _ in
                            try await self.fetchOffset(partialURL: url, headers: headers, session: session, label: "part \(index)")
                        }
                        return (index, url, min(offset, parts[index].length))
                    } catch ParallelTUSUploader.UploadError.patchFailed(let code, _) where code == 404 || code == 410 {
                        self.log("part \(index): saved part gone (HTTP \(code)), starting it over")
                        return (index, url, nil)
                    }
                }
            }
            var result: [Int: (url: URL, offset: Int64)] = [:]
            for try await (index, url, offset) in group {
                if let offset {
                    result[index] = (url, offset)
                }
            }
            return result
        }
    }

    private func uploadPart(
        index: Int,
        fd: Int32,
        offset: Int64,
        length: Int64,
        metadataHeader: String?,
        resign: (@Sendable () -> [String: String])?,
        existing: (url: URL, offset: Int64)?,
        onPartCreated: (@Sendable (Int, URL) -> Void)?,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        // Own session = own TCP connection (independent congestion window).
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        // 1) POST creation with Upload-Concat: partial, unless a resumed part exists.
        let partialURL: URL
        if let existing {
            partialURL = existing.url
        } else {
            partialURL = try await withRetry("part \(index) POST", resign: resign) { headers, _ in
                try await self.createPartial(index: index, length: length, metadataHeader: metadataHeader, headers: headers, session: session)
            }
            onPartCreated?(index, partialURL)
        }

        // 2) PATCH the part's data in blocks; reads via pread off the async pool.
        // `sent` is the offset Bunny confirmed; a retry first asks Bunny for it (HEAD).
        var sent: Int64 = existing?.offset ?? 0
        var block = 0
        while sent < length {
            try await withRetry("part \(index) block \(block)", resign: resign) { headers, isRetry in
                if isRetry {
                    let confirmed = try await self.fetchOffset(partialURL: partialURL, headers: headers, session: session, label: "part \(index)")
                    if confirmed != sent {
                        self.log("part \(index): resync offset \(sent) -> \(confirmed)")
                        self.bumpProgress(by: confirmed - sent, onProgress: onProgress)
                        sent = confirmed
                    }
                    if sent >= length {
                        return
                    }
                }
                let blockLen = Int(min(Int64(self.patchBlockSize), length - sent))
                let tRead = Date()
                let data = try await self.readBlock(fd: fd, offset: offset + sent, length: blockLen)
                let readMs = self.ms(tRead)
                if data.isEmpty {
                    throw UploadError.read(0)
                }
                let tPatch = Date()
                let patchCode = try await self.patch(partialURL: partialURL, offset: sent, data: data, headers: headers, session: session)
                let patchMs = Date().timeIntervalSince(tPatch)
                let mbps = patchMs > 0 ? Double(data.count) / patchMs / 1_048_576 : 0
                self.log("part \(index) block \(block): \(data.count/1_048_576)MB PATCH → HTTP \(patchCode), read \(readMs), patch \(String(format: "%.2fs", patchMs)) = \(String(format: "%.1f", mbps)) MB/s")
                sent += Int64(data.count)
                self.bumpProgress(by: Int64(data.count), onProgress: onProgress)
            }
            block += 1
        }

        log("part \(index): DONE (\(sent/1_048_576)MB)")
        return partialURL
    }

    private func createPartial(
        index: Int,
        length: Int64,
        metadataHeader: String?,
        headers: [String: String],
        session: URLSession
    ) async throws -> URL {
        let tPost = Date()
        var createReq = URLRequest(url: endpoint)
        createReq.httpMethod = "POST"
        createReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        createReq.setValue("partial", forHTTPHeaderField: "Upload-Concat")
        createReq.setValue(String(length), forHTTPHeaderField: "Upload-Length")
        if let metadataHeader {
            createReq.setValue(metadataHeader, forHTTPHeaderField: "Upload-Metadata")
        }
        for (k, v) in headers {
            createReq.setValue(v, forHTTPHeaderField: k)
        }

        let (createData, createResp) = try await session.data(for: createReq)
        let createHTTP = createResp as? HTTPURLResponse
        let createCode = createHTTP?.statusCode ?? 0
        log("part \(index): POST partial → HTTP \(createCode) in \(ms(tPost))")
        guard (200..<300).contains(createCode) else {
            throw UploadError.partialCreateFailed(createCode, String(data: createData, encoding: .utf8) ?? "")
        }
        guard let location = createHTTP?.value(forHTTPHeaderField: "Location"),
              let partialURL = URL(string: location, relativeTo: endpoint)?.absoluteURL
        else {
            throw UploadError.missingLocation
        }
        return partialURL
    }

    /// Sends one block; returns the HTTP status (2xx) or throws `patchFailed`.
    private func patch(
        partialURL: URL,
        offset: Int64,
        data: Data,
        headers: [String: String],
        session: URLSession
    ) async throws -> Int {
        var patchReq = URLRequest(url: partialURL)
        patchReq.httpMethod = "PATCH"
        patchReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        patchReq.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
        patchReq.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        for (k, v) in headers {
            patchReq.setValue(v, forHTTPHeaderField: k)
        }
        let (patchData, patchResp) = try await session.upload(for: patchReq, from: data)
        let patchCode = (patchResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(patchCode) else {
            throw UploadError.patchFailed(patchCode, String(data: patchData, encoding: .utf8) ?? "")
        }
        return patchCode
    }

    /// Asks Bunny how many bytes of a part it has (`HEAD`, `Upload-Offset`).
    private func fetchOffset(partialURL: URL, headers: [String: String], session: URLSession, label: String) async throws -> Int64 {
        let tHead = Date()
        var req = URLRequest(url: partialURL)
        req.httpMethod = "HEAD"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        for (k, v) in headers {
            req.setValue(v, forHTTPHeaderField: k)
        }
        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        log("\(label): HEAD → HTTP \(code), offset \(http?.value(forHTTPHeaderField: "Upload-Offset") ?? "-") in \(ms(tHead))")
        guard (200..<300).contains(code),
              let value = http?.value(forHTTPHeaderField: "Upload-Offset"),
              let offset = Int64(value)
        else {
            throw UploadError.patchFailed(code == 200 ? 0 : code, String(data: data, encoding: .utf8) ?? "")
        }
        return offset
    }

    private func ms(_ since: Date) -> String {
        return String(format: "%.2fs", Date().timeIntervalSince(since))
    }

    // MARK: - Final concatenation (final)

    private func sendFinal(
        partialURLs: [URL],
        metadataHeader: String?,
        resign: (@Sendable () -> [String: String])?
    ) async throws {
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let concatValue = "final;" + partialURLs.map { $0.absoluteString }.joined(separator: " ")

        try await withRetry("FINAL", resign: resign) { headers, _ in
            var req = URLRequest(url: self.endpoint)
            req.httpMethod = "POST"
            req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            req.setValue(concatValue, forHTTPHeaderField: "Upload-Concat")
            if let metadataHeader {
                req.setValue(metadataHeader, forHTTPHeaderField: "Upload-Metadata")
            }
            for (k, v) in headers {
                req.setValue(v, forHTTPHeaderField: k)
            }

            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else {
                throw UploadError.finalFailed(code, String(data: data, encoding: .utf8) ?? "")
            }
        }
    }

    // MARK: - Disk reads (off the async pool)

    private func readBlock(fd: Int32, offset: Int64, length: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            ioQueue.async {
                var buffer = [UInt8](repeating: 0, count: length)
                let n = buffer.withUnsafeMutableBytes { ptr in
                    pread(fd, ptr.baseAddress, length, off_t(offset))
                }
                if n < 0 {
                    cont.resume(throwing: UploadError.read(Int(errno)))
                } else {
                    cont.resume(returning: Data(buffer.prefix(n)))
                }
            }
        }
    }

    // MARK: - Shared state (under lock)

    private var total: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return _totalBytesUploaded
    }

    private var currentHeaders: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return _authHeaders
    }

    private func replaceHeaders(_ headers: [String: String]) {
        lock.lock()
        _authHeaders = headers
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _cancelled
    }

    private func bumpProgress(by delta: Int64, onProgress: @escaping @Sendable (Int64) -> Void) {
        lock.lock()
        _totalBytesUploaded += delta
        let snapshot = _totalBytesUploaded
        lock.unlock()
        onProgress(snapshot)
    }

    // MARK: - Helpers

    public static func splitIntoParts(fileSize: Int64, partCount: Int) -> [(offset: Int64, length: Int64)] {
        guard fileSize > 0 else { return [] }
        // Never make more parts than there are bytes (keeps every part non-empty).
        let n = max(1, min(partCount, Int(fileSize)))
        let base = fileSize / Int64(n)
        var parts: [(offset: Int64, length: Int64)] = []
        var offset: Int64 = 0
        for i in 0..<n {
            let length = (i == n - 1) ? (fileSize - offset) : base
            parts.append((offset: offset, length: length))
            offset += length
        }
        return parts
    }

    public static func encodeMetadata(_ metadata: [String: String]) -> String? {
        guard !metadata.isEmpty else { return nil }
        return metadata
            .map { key, value in "\(key) \(Data(value.utf8).base64EncodedString())" }
            .joined(separator: ",")
    }
}
