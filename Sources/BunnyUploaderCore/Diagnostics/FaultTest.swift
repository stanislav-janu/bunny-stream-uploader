import Foundation

/// End-to-end check against the real Bunny library with simulated network faults:
/// 1. Retry: a parallel upload through `FaultInjectingURLProtocol` must finish, and no
///    block may reach Bunny twice (lost responses are resynced with HEAD).
/// 2. Resume: an upload cancelled midway must continue from its saved parts.
/// 3. Re-upload: a second full upload into the same video (what Retry does) must succeed.
///    It starts with an invalid signature, so Bunny's 401 must lead to a fresh one.
/// 4. API (with `--video <file>`): the collection list loads; a real video uploaded into the
///    first collection lands there and reaches Ready to play (status 4) or is still processing
///    when `processingWait` ends (Bunny's queue can be slow; that is reported, not failed).
/// Both test videos are deleted at the end. Run with `BunnyUploader --fault-test`.
public enum FaultTest {
    public struct Options: Sendable {
        public var fileSize: Int64 = 64 * 1024 * 1024
        public var partCount = 8
        public var faults = FaultInjectingURLProtocol.Faults(dropBeforeSend: 0.08, dropAfterSend: 0.08, serviceUnavailable: 0.08)
        public var retryDelays: [TimeInterval] = [0, 1, 2, 3, 5, 8]
        /// Fraction of the file uploaded before the resume check cancels.
        public var cancelAt = 0.4
        /// How long to wait for Bunny to give up on the zero-filled video.
        public var processingWait: TimeInterval = 120
        public var processingPollInterval: TimeInterval = 5
        /// A short real video for the processing check; without it the check only lists collections.
        public var realVideo: URL?

        public init() {}
    }

    /// Runs the check with the credentials saved in the Keychain.
    public static func runWithStoredCredentials(options: Options = Options(), log: @escaping @Sendable (String) -> Void) async -> Bool {
        let credentials = KeychainStore.load()
        guard credentials.isComplete else {
            log("FAIL: no credentials saved in Settings")
            return false
        }
        return await run(credentials: credentials, options: options, log: log)
    }

    /// Prints the newest videos with status, encode progress, size, and upload date
    /// (no keys, no titles).
    public static func printRecentVideos(log: @escaping @Sendable (String) -> Void) async {
        let credentials = KeychainStore.load()
        guard credentials.isComplete else {
            log("no credentials saved in Settings")
            return
        }
        do {
            let videos = try await BunnyAPIClient(credentials: credentials).listRecentVideos(count: 15)
            for video in videos {
                let fields = ["guid", "dateUploaded", "status", "encodeProgress", "storageSize", "length", "width", "height"]
                log(fields.map { "\($0)=\(video[$0].map { "\($0)" } ?? "-")" }.joined(separator: " "))
            }
        } catch {
            log("error: \(error.localizedDescription)")
        }
    }

    /// Prints status and stored bytes of one video (no title).
    public static func printVideoStatus(guid: String, log: @escaping @Sendable (String) -> Void) async {
        let credentials = KeychainStore.load()
        do {
            let info = try await BunnyAPIClient(credentials: credentials).getVideoStorage(guid: guid)
            log("\(guid): status \(info.status), storageSize \(info.storageSize)")
        } catch {
            log("\(guid): \(error.localizedDescription)")
        }
    }

    /// Deletes a test video left behind by these diagnostics. Refuses any video whose
    /// title does not start with "Bunny Uploader ", so real videos are never touched.
    public static func deleteTestVideo(guid: String, log: @escaping @Sendable (String) -> Void) async -> Bool {
        let credentials = KeychainStore.load()
        guard credentials.isComplete else {
            log("no credentials saved in Settings")
            return false
        }
        let api = BunnyAPIClient(credentials: credentials)
        do {
            let recent = try await api.listRecentVideos(count: 100)
            guard let video = recent.first(where: { ($0["guid"] as? String) == guid }) else {
                log("refused: \(guid) is not among the 100 newest videos")
                return false
            }
            guard (video["title"] as? String)?.hasPrefix("Bunny Uploader ") == true else {
                log("refused: \(guid) is not a test video")
                return false
            }
            try await api.deleteVideo(guid: guid)
            log("deleted test video \(guid)")
            return true
        } catch {
            log("could not delete \(guid): \(error.localizedDescription)")
            return false
        }
    }

    /// Does Bunny finish the concatenation when the client drops the final request?
    /// Uploads all parts of a zero-filled file, sends `Upload-Concat: final` with a
    /// `detachAfter` timeout, then watches the video's status and stored bytes.
    public static func probeFinalDetach(
        sizeMB: Int = 512,
        partCount: Int = 32,
        detachAfter: TimeInterval = 3,
        watch: TimeInterval = 600,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let credentials = KeychainStore.load()
        guard credentials.isComplete else {
            log("no credentials saved in Settings")
            return false
        }
        let api = BunnyAPIClient(credentials: credentials)
        let size = Int64(sizeMB) * 1024 * 1024
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bunny-final-probe-\(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.truncate(atOffset: UInt64(size))
            try? handle.close()
        }
        defer { try? FileManager.default.removeItem(at: file) }

        var videoId: String?
        var detachedOK = false
        do {
            let guid = try await api.createVideo(title: "Bunny Uploader final probe (safe to delete)")
            videoId = guid
            let collector = Collector()
            let uploader = ParallelTUSUploader()
            let started = Date()
            do {
                _ = try await uploader.upload(
                    fileURL: file,
                    fileSize: size,
                    partCount: partCount,
                    authHeaders: headers(credentials, guid),
                    metadata: ["title": "final probe", "filetype": "video/mp4"],
                    onPartCreated: { collector.add($0, $1) },
                    onProgress: { bytes in
                        if bytes >= size {
                            uploader.cancel()
                        }
                    }
                )
            } catch {
                // Expected: cancelled right before the final request.
            }
            let parts = collector.parts
            log("probe: \(sizeMB) MB in \(parts.count) parts uploaded in \(Int(Date().timeIntervalSince(started))) s")
            guard parts.count == partCount else {
                log("probe: FAIL, only \(parts.count) part URLs")
                return false
            }

            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = detachAfter
            let session = URLSession(configuration: config)
            var request = URLRequest(url: URL(string: "https://video.bunnycdn.com/tusupload")!)
            request.httpMethod = "POST"
            request.setValue("1.0.0", forHTTPHeaderField: "Tus-Resumable")
            let ordered = (0..<partCount).compactMap { parts[$0]?.absoluteString }
            request.setValue("final;" + ordered.joined(separator: " "), forHTTPHeaderField: "Upload-Concat")
            request.setValue(ParallelTUSUploader.encodeMetadata(["title": "final probe", "filetype": "video/mp4"]), forHTTPHeaderField: "Upload-Metadata")
            for (key, value) in headers(credentials, guid) {
                request.setValue(value, forHTTPHeaderField: key)
            }
            let sent = Date()
            do {
                let (_, response) = try await session.data(for: request)
                log("probe: FINAL answered HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) in \(String(format: "%.1f", Date().timeIntervalSince(sent))) s (before the detach timeout)")
            } catch {
                log("probe: FINAL dropped by the client after \(String(format: "%.1f", Date().timeIntervalSince(sent))) s (\((error as? URLError)?.code.rawValue ?? 0))")
            }
            session.invalidateAndCancel()

            var last: (Int, Int64)?
            while Date().timeIntervalSince(sent) < watch {
                if let info = try? await api.getVideoStorage(guid: guid), last.map({ $0 != (info.status, info.storageSize) }) ?? true {
                    last = (info.status, info.storageSize)
                    log("probe: +\(Int(Date().timeIntervalSince(sent))) s status \(info.status), storageSize \(info.storageSize)")
                    if info.status >= 1 {
                        detachedOK = true
                        break
                    }
                }
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
            log(detachedOK
                ? "probe: RESULT Bunny finished the concatenation without the client"
                : "probe: RESULT video stayed at status 0 for \(Int(watch)) s; Bunny did not finish without the client")
        } catch {
            log("probe: error \(error.localizedDescription)")
        }
        if let videoId {
            do {
                try await api.deleteVideo(guid: videoId)
                log("probe: deleted test video \(videoId)")
            } catch {
                log("probe: WARN could not delete test video \(videoId): \(error.localizedDescription)")
            }
        }
        return detachedOK
    }

    public static func run(
        credentials: Credentials,
        options: Options = Options(),
        apiSession: URLSession = .shared,
        tusConfiguration: URLSessionConfiguration = FaultInjectingURLProtocol.configuration(),
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let api = BunnyAPIClient(credentials: credentials, session: apiSession)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("bunny-fault-test-\(UUID().uuidString).mp4")
        guard FileManager.default.createFile(atPath: file.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: file)
        else {
            log("FAIL: could not create the test file")
            return false
        }
        try? handle.truncate(atOffset: UInt64(options.fileSize))
        try? handle.close()
        defer { try? FileManager.default.removeItem(at: file) }

        var videos: [String] = []
        var passed = true
        do {
            let retryVideo = try await api.createVideo(title: "Bunny Uploader fault test (retry)")
            videos.append(retryVideo)
            passed = await checkRetry(videoId: retryVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, api: api, log: log) && passed

            let resumeVideo = try await api.createVideo(title: "Bunny Uploader fault test (resume)")
            videos.append(resumeVideo)
            passed = await checkResume(videoId: resumeVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, log: log) && passed

            passed = await checkReupload(videoId: retryVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, log: log) && passed

            passed = await checkAPI(api: api, credentials: credentials, options: options, configuration: tusConfiguration, videos: &videos, log: log) && passed
        } catch {
            log("FAIL: \(error.localizedDescription)")
            passed = false
        }

        for video in videos {
            do {
                try await api.deleteVideo(guid: video)
                log("deleted test video \(video)")
            } catch {
                log("WARN: could not delete test video \(video): \(error.localizedDescription)")
            }
        }
        log(passed ? "PASS" : "FAIL")
        return passed
    }

    private static func headers(_ credentials: Credentials, _ videoId: String) -> [String: String] {
        return UploadEngine.signer(credentials: credentials, videoId: videoId)()
    }

    static func checkRetry(
        videoId: String,
        file: URL,
        credentials: Credentials,
        options: Options,
        configuration: URLSessionConfiguration,
        api: BunnyAPIClient,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let state = FaultInjectingURLProtocol.state
        state.reset()
        state.faults = options.faults
        defer { state.faults = FaultInjectingURLProtocol.Faults() }
        log("retry check: \(options.fileSize / 1_048_576) MB in \(options.partCount) parts with faults \(options.faults)")
        let uploader = ParallelTUSUploader(sessionConfiguration: configuration, retryDelays: options.retryDelays)
        do {
            let result = try await uploader.upload(
                fileURL: file,
                fileSize: options.fileSize,
                partCount: options.partCount,
                authHeaders: headers(credentials, videoId),
                metadata: ["title": "fault test", "filetype": "video/mp4"],
                resign: UploadEngine.signer(credentials: credentials, videoId: videoId),
                finalAccepted: {
                    guard let status = try? await api.getVideoStatus(guid: videoId) else { return false }
                    return status >= 1
                },
                onProgress: { _ in }
            )
            let injected = state.injected
            let forwarded = state.forwardedBodyBytes
            log("retry check: done in \(String(format: "%.1f", result.elapsed)) s, faults injected \(describe(injected)), body bytes sent \(forwarded) of \(options.fileSize)")
            var ok = true
            if injected.values.reduce(0, +) == 0 {
                log("FAIL retry check: no fault was injected, raise the fault rates")
                ok = false
            }
            if forwarded != options.fileSize {
                log("FAIL retry check: Bunny got \(forwarded) body bytes, expected exactly \(options.fileSize)")
                ok = false
            }
            return ok
        } catch {
            log("FAIL retry check: \(error.localizedDescription), faults injected \(describe(state.injected))")
            return false
        }
    }

    /// Thread-safe collector for part URLs and progress.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var _parts: [Int: URL] = [:]
        private var _resumed: Int64 = 0
        var parts: [Int: URL] {
            lock.withLock { _parts }
        }
        var resumed: Int64 {
            lock.withLock { _resumed }
        }
        func add(_ index: Int, _ url: URL) {
            lock.withLock {
                _parts[index] = url
            }
        }
        func setResumed(_ bytes: Int64) {
            lock.withLock {
                _resumed = bytes
            }
        }
    }

    static func checkResume(
        videoId: String,
        file: URL,
        credentials: Credentials,
        options: Options,
        configuration: URLSessionConfiguration,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let state = FaultInjectingURLProtocol.state
        state.reset()
        state.faults = FaultInjectingURLProtocol.Faults()
        let collector = Collector()
        let first = ParallelTUSUploader(sessionConfiguration: configuration, retryDelays: options.retryDelays)
        let cancelBytes = Int64(Double(options.fileSize) * options.cancelAt)
        do {
            _ = try await first.upload(
                fileURL: file,
                fileSize: options.fileSize,
                partCount: options.partCount,
                authHeaders: headers(credentials, videoId),
                metadata: ["title": "fault test", "filetype": "video/mp4"],
                onPartCreated: { collector.add($0, $1) },
                onProgress: { bytes in
                    if bytes >= cancelBytes {
                        first.cancel()
                    }
                }
            )
            log("FAIL resume check: the first run finished before it could be cancelled")
            return false
        } catch {
            log("resume check: first run stopped at ~\(Int(options.cancelAt * 100)) % with \(collector.parts.count) saved parts")
        }
        let sentBefore = state.forwardedBodyBytes

        // The resume uses the app's real backoff: Bunny keeps a part locked (423) for a while
        // after its PATCH was aborted.
        let second = ParallelTUSUploader(sessionConfiguration: configuration)
        let tResume = Date()
        do {
            _ = try await second.upload(
                fileURL: file,
                fileSize: options.fileSize,
                partCount: options.partCount,
                authHeaders: headers(credentials, videoId),
                metadata: ["title": "fault test", "filetype": "video/mp4"],
                resumeParts: collector.parts,
                onResumed: { collector.setResumed($0) },
                onProgress: { _ in }
            )
        } catch {
            log("FAIL resume check: \(error.localizedDescription)")
            return false
        }
        let sentAfter = state.forwardedBodyBytes - sentBefore
        log("resume check: second run took \(String(format: "%.1f", Date().timeIntervalSince(tResume))) s")
        log("resume check: first run got 2xx for \(sentBefore) B; Bunny kept \(collector.resumed) B (aborted blocks partly stored); second run sent \(sentAfter) B; kept + sent = \(collector.resumed + sentAfter) of \(options.fileSize)")
        var ok = true
        if collector.resumed <= 0 {
            log("FAIL resume check: Bunny confirmed no bytes of the saved parts")
            ok = false
        }
        if sentAfter + collector.resumed != options.fileSize {
            log("FAIL resume check: resumed + resent = \(sentAfter + collector.resumed), expected \(options.fileSize)")
            ok = false
        }
        return ok
    }

    static func checkReupload(
        videoId: String,
        file: URL,
        credentials: Credentials,
        options: Options,
        configuration: URLSessionConfiguration,
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let state = FaultInjectingURLProtocol.state
        state.reset()
        state.faults = FaultInjectingURLProtocol.Faults()
        let uploader = ParallelTUSUploader(sessionConfiguration: configuration)
        var stale = headers(credentials, videoId)
        stale["AuthorizationSignature"] = String(repeating: "0", count: 64)
        let renewed = RenewCounter()
        let signer = UploadEngine.signer(credentials: credentials, videoId: videoId)
        do {
            let result = try await uploader.upload(
                fileURL: file,
                fileSize: options.fileSize,
                partCount: options.partCount,
                authHeaders: stale,
                metadata: ["title": "fault test", "filetype": "video/mp4"],
                resign: {
                    renewed.bump()
                    return signer()
                },
                onProgress: { _ in }
            )
            log("re-upload check: second upload into the same video done in \(String(format: "%.1f", result.elapsed)) s, signature renewed \(renewed.count) times after 401")
            if renewed.count == 0 {
                log("FAIL re-upload check: Bunny accepted an invalid signature, the 401 path was not exercised")
                return false
            }
            return true
        } catch {
            log("FAIL re-upload check: \(error.localizedDescription)")
            return false
        }
    }

    static func checkAPI(
        api: BunnyAPIClient,
        credentials: Credentials,
        options: Options,
        configuration: URLSessionConfiguration,
        videos: inout [String],
        log: @escaping @Sendable (String) -> Void
    ) async -> Bool {
        let collections: [BunnyAPIClient.Collection]
        do {
            collections = try await api.listCollections()
            log("api check: collection list loaded, \(collections.count) collections")
        } catch {
            log("FAIL api check: collection list: \(error.localizedDescription)")
            return false
        }
        guard let realVideo = options.realVideo else {
            log("api check: no --video given, skipping the processing check")
            return true
        }
        let size = (try? realVideo.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size > 0 else {
            log("FAIL api check: cannot read \(realVideo.path)")
            return false
        }
        let collection = collections.first
        let videoId: String
        do {
            videoId = try await api.createVideo(title: "Bunny Uploader fault test (processing)", collectionId: collection?.id)
            videos.append(videoId)
            FaultInjectingURLProtocol.state.faults = FaultInjectingURLProtocol.Faults()
            let uploader = ParallelTUSUploader(sessionConfiguration: configuration)
            _ = try await uploader.upload(
                fileURL: realVideo,
                fileSize: size,
                partCount: 2,
                authHeaders: headers(credentials, videoId),
                metadata: ["title": "fault test", "filetype": "video/mp4"],
                onProgress: { _ in }
            )
        } catch {
            log("FAIL api check: upload of the real video: \(error.localizedDescription)")
            return false
        }
        let start = Date()
        var statuses: [Int] = []
        var collectionId: String?
        while Date().timeIntervalSince(start) < options.processingWait {
            if let info = try? await api.getVideoInfo(guid: videoId) {
                collectionId = info.collectionId
                if statuses.last != info.status {
                    statuses.append(info.status)
                }
                if BunnyAPIClient.processing(forStatus: info.status) != .processing {
                    break
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(options.processingPollInterval * 1_000_000_000))
        }
        let final = statuses.last.map { BunnyAPIClient.processing(forStatus: $0) }
        log("api check: status sequence \(statuses) in \(Int(Date().timeIntervalSince(start))) s, maps to \(final.map { "\($0)" } ?? "nothing"); collection \(collectionId ?? "none") (asked for \(collection?.id ?? "none"))")
        var ok = true
        switch final {
        case .ready:
            break
        case .processing:
            log("api check: still processing after \(Int(options.processingWait)) s; Bunny's queue decides when, not a failure")
        default:
            log("FAIL api check: Bunny reported the real video as failed or never answered")
            ok = false
        }
        if collectionId != collection?.id {
            log("FAIL api check: the video is not in the requested collection")
            ok = false
        }
        return ok
    }

    final class RenewCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var _count = 0
        var count: Int {
            lock.withLock { _count }
        }
        func bump() {
            lock.withLock {
                _count += 1
            }
        }
    }

    static func describe(_ injected: [FaultInjectingURLProtocol.Kind: Int]) -> String {
        return FaultInjectingURLProtocol.Kind.allCases
            .map { "\($0.rawValue)=\(injected[$0] ?? 0)" }
            .joined(separator: " ")
    }
}
