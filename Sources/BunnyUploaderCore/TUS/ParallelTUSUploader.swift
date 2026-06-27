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

    /// Base config for each part's session. One TCP connection per host by default;
    /// tests inject a config with a mock URLProtocol.
    private let sessionConfiguration: URLSessionConfiguration

    public init(sessionConfiguration: URLSessionConfiguration? = nil) {
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
    public func upload(
        fileURL: URL,
        fileSize: Int64,
        partCount: Int,
        authHeaders: [String: String],
        metadata: [String: String],
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> Result {
        lock.lock()
        _totalBytesUploaded = 0
        _cancelled = false
        lock.unlock()

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

        var partialURLs = [URL?](repeating: nil, count: parts.count)
        try await withThrowingTaskGroup(of: (Int, URL).self) { group in
            for (index, part) in parts.enumerated() {
                group.addTask {
                    let url = try await self.uploadPart(
                        index: index,
                        fd: fd,
                        offset: part.offset,
                        length: part.length,
                        authHeaders: authHeaders,
                        metadataHeader: metadataHeader,
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
        try await sendFinal(partialURLs: ordered, authHeaders: authHeaders, metadataHeader: metadataHeader)
        log("FINAL done in \(ms(tFinal)). TOTAL \(ms(start)), \(total/1_048_576)MB")

        return Result(bytesUploaded: total, elapsed: Date().timeIntervalSince(start))
    }

    public func cancel() {
        lock.lock()
        _cancelled = true
        lock.unlock()
    }

    // MARK: - Part (partial)

    private func uploadPart(
        index: Int,
        fd: Int32,
        offset: Int64,
        length: Int64,
        authHeaders: [String: String],
        metadataHeader: String?,
        onProgress: @escaping @Sendable (Int64) -> Void
    ) async throws -> URL {
        // Own session = own TCP connection (independent congestion window).
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        // 1) POST creation s Upload-Concat: partial
        let tPost = Date()
        var createReq = URLRequest(url: endpoint)
        createReq.httpMethod = "POST"
        createReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        createReq.setValue("partial", forHTTPHeaderField: "Upload-Concat")
        createReq.setValue(String(length), forHTTPHeaderField: "Upload-Length")
        if let metadataHeader {
            createReq.setValue(metadataHeader, forHTTPHeaderField: "Upload-Metadata")
        }
        for (k, v) in authHeaders {
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

        // 2) PATCH the part's data in blocks; reads via pread off the async pool.
        var sent: Int64 = 0
        var block = 0
        while sent < length {
            if isCancelled { throw UploadError.cancelled }
            let blockLen = Int(min(Int64(patchBlockSize), length - sent))

            let tRead = Date()
            let data = try await readBlock(fd: fd, offset: offset + sent, length: blockLen)
            let readMs = ms(tRead)
            if data.isEmpty { break }

            var patchReq = URLRequest(url: partialURL)
            patchReq.httpMethod = "PATCH"
            patchReq.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            patchReq.setValue("application/offset+octet-stream", forHTTPHeaderField: "Content-Type")
            patchReq.setValue(String(sent), forHTTPHeaderField: "Upload-Offset")
            for (k, v) in authHeaders {
                patchReq.setValue(v, forHTTPHeaderField: k)
            }

            let tPatch = Date()
            let (patchData, patchResp) = try await session.upload(for: patchReq, from: data)
            let patchMs = Date().timeIntervalSince(tPatch)
            let patchCode = (patchResp as? HTTPURLResponse)?.statusCode ?? 0
            let mbps = patchMs > 0 ? Double(data.count) / patchMs / 1_048_576 : 0
            log("part \(index) block \(block): \(data.count/1_048_576)MB PATCH → HTTP \(patchCode), read \(readMs), patch \(String(format: "%.2fs", patchMs)) = \(String(format: "%.1f", mbps)) MB/s")
            guard (200..<300).contains(patchCode) else {
                throw UploadError.patchFailed(patchCode, String(data: patchData, encoding: .utf8) ?? "")
            }

            sent += Int64(data.count)
            block += 1
            bumpProgress(by: Int64(data.count), onProgress: onProgress)
        }

        log("part \(index): DONE (\(sent/1_048_576)MB)")
        return partialURL
    }

    private func ms(_ since: Date) -> String {
        return String(format: "%.2fs", Date().timeIntervalSince(since))
    }

    // MARK: - Final concatenation (final)

    private func sendFinal(
        partialURLs: [URL],
        authHeaders: [String: String],
        metadataHeader: String?
    ) async throws {
        let config = sessionConfiguration.copy() as! URLSessionConfiguration
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let concatValue = "final;" + partialURLs.map { $0.absoluteString }.joined(separator: " ")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
        req.setValue(concatValue, forHTTPHeaderField: "Upload-Concat")
        if let metadataHeader {
            req.setValue(metadataHeader, forHTTPHeaderField: "Upload-Metadata")
        }
        for (k, v) in authHeaders {
            req.setValue(v, forHTTPHeaderField: k)
        }

        let (data, resp) = try await session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else {
            throw UploadError.finalFailed(code, String(data: data, encoding: .utf8) ?? "")
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
