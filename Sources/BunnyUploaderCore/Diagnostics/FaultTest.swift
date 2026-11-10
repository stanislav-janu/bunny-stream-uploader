import Foundation

/// End-to-end check against the real Bunny library with simulated network faults:
/// 1. Retry: a parallel upload through `FaultInjectingURLProtocol` must finish, and no
///    block may reach Bunny twice (lost responses are resynced with HEAD).
/// 2. Resume: an upload cancelled midway must continue from its saved parts.
/// 3. Re-upload: a second full upload into the same video (what Retry does) must succeed.
///    It starts with an invalid signature, so Bunny's 401 must lead to a fresh one.
/// Both test videos are deleted at the end. Run with `BunnyUploader --fault-test`.
public enum FaultTest {
    public struct Options: Sendable {
        public var fileSize: Int64 = 64 * 1024 * 1024
        public var partCount = 8
        public var faults = FaultInjectingURLProtocol.Faults(dropBeforeSend: 0.08, dropAfterSend: 0.08, serviceUnavailable: 0.08)
        public var retryDelays: [TimeInterval] = [0, 1, 2, 3, 5, 8]
        /// Fraction of the file uploaded before the resume check cancels.
        public var cancelAt = 0.4

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
            passed = await checkRetry(videoId: retryVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, log: log) && passed

            let resumeVideo = try await api.createVideo(title: "Bunny Uploader fault test (resume)")
            videos.append(resumeVideo)
            passed = await checkResume(videoId: resumeVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, log: log) && passed

            passed = await checkReupload(videoId: retryVideo, file: file, credentials: credentials, options: options, configuration: tusConfiguration, log: log) && passed
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
