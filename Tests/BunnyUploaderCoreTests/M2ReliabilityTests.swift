import XCTest
@testable import BunnyUploaderCore

/// Part retry with offset resync (S-009), re-signing after 401 (S-010), sleep prevention (S-011).
final class M2ReliabilityTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// A fake TUS server that keeps each part's received offset, with switches to inject failures.
    final class FakeTUS: @unchecked Sendable {
        private let lock = NSLock()
        private var offsets: [String: Int64] = [:]
        private var nextPart = 0
        /// PATCH failures still to inject: status code, or 0 for a network error.
        var patchFailures: [Int] = []
        /// When true, a failing PATCH still stores its bytes (the response got lost).
        var storeBytesOnFailure = false
        var finalFailures: [Int] = []
        /// 401 answers still to give to requests carrying this signature.
        var rejectSignature: String?
        var headCalls = 0
        var patchedBytes: Int64 = 0
        var createdParts = 0
        var finalsDone = 0

        /// Video status the way Bunny reports it: 0 (Created) until a final request arrived.
        var videoStatus: Int {
            lock.withLock { finalsDone > 0 ? 2 : 0 }
        }
        var signaturesSeen: Set<String> = []

        /// Replaces the PATCH failures still to inject (under the lock).
        func setPatchFailures(_ failures: [Int]) {
            lock.withLock {
                patchFailures = failures
            }
        }

        /// A part Bunny already knows, as after an interrupted run.
        func preset(_ url: String, offset: Int64) {
            lock.withLock {
                offsets[url] = offset
            }
        }

        var stats: (heads: Int, patched: Int64, created: Int) {
            lock.withLock { (headCalls, patchedBytes, createdParts) }
        }

        func handle(_ request: URLRequest) throws -> (Int, Data, [String: String]) {
            try lock.withLock {
                let signature = request.value(forHTTPHeaderField: "AuthorizationSignature") ?? ""
                signaturesSeen.insert(signature)
                if let rejected = rejectSignature, rejected == signature {
                    return (401, Data(), [:])
                }
                let url = request.url!.absoluteString
                let concat = request.value(forHTTPHeaderField: "Upload-Concat") ?? ""
                switch request.httpMethod {
                case "POST" where concat == "partial":
                    nextPart += 1
                    createdParts += 1
                    let location = "https://video.bunnycdn.com/tusupload/p\(nextPart)"
                    offsets[location] = 0
                    return (201, Data(), ["Location": location])
                case "POST":
                    if !finalFailures.isEmpty {
                        return (finalFailures.removeFirst(), Data(), [:])
                    }
                    finalsDone += 1
                    return (200, Data(), [:])
                case "HEAD":
                    headCalls += 1
                    guard let offset = offsets[url] else {
                        return (404, Data(), [:])
                    }
                    return (200, Data(), ["Upload-Offset": String(offset)])
                case "PATCH":
                    let offset = Int64(request.value(forHTTPHeaderField: "Upload-Offset") ?? "") ?? -1
                    guard offset == offsets[url] else {
                        return (409, Data(), [:])
                    }
                    let length = Int64(request.httpBodyStreamLength ?? 0)
                    if !patchFailures.isEmpty {
                        let failure = patchFailures.removeFirst()
                        if storeBytesOnFailure {
                            offsets[url, default: 0] += length
                        }
                        if failure == 0 {
                            throw URLError(.networkConnectionLost)
                        }
                        return (failure, Data(), [:])
                    }
                    offsets[url, default: 0] += length
                    patchedBytes += length
                    return (204, Data(), ["Upload-Offset": String(offsets[url]!)])
                default:
                    return (400, Data(), [:])
                }
            }
        }
    }

    private func makeFile(size: Int) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: size))
        return url
    }

    private func run(
        _ fake: FakeTUS,
        size: Int = 2000,
        parts: Int = 2,
        delays: [TimeInterval] = [0, 0, 0],
        headers: [String: String] = ["AuthorizationSignature": "s1"],
        resign: (@Sendable () -> [String: String])? = nil
    ) async throws -> (ParallelTUSUploader.Result, Int64) {
        MockURLProtocol.handler = { try fake.handle($0) }
        let file = makeFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration(), retryDelays: delays)
        let progress = ProgressBox()
        let result = try await uploader.upload(
            fileURL: file,
            fileSize: Int64(size),
            partCount: parts,
            authHeaders: headers,
            metadata: [:],
            resign: resign,
            onProgress: { progress.set($0) }
        )
        return (result, progress.value)
    }

    // MARK: - S-009

    func testDisposition() {
        XCTAssertEqual(ParallelTUSUploader.disposition(status: 401), .resign)
        for code in [408, 409, 429, 500, 502, 503] {
            XCTAssertEqual(ParallelTUSUploader.disposition(status: code), .retry, "\(code)")
        }
        for code in [400, 403, 404, 410] {
            XCTAssertEqual(ParallelTUSUploader.disposition(status: code), .fail, "\(code)")
        }
    }

    func testPatchServerErrorIsRetried() async throws {
        let fake = FakeTUS()
        fake.patchFailures = [503, 500]
        let (result, progress) = try await run(fake)
        XCTAssertEqual(result.bytesUploaded, 2000)
        XCTAssertEqual(progress, 2000)
        XCTAssertGreaterThanOrEqual(fake.headCalls, 2)
    }

    func testLostResponseResumesFromConfirmedOffset() async throws {
        // Bunny stored the block but the client saw a network error: the retry must
        // skip that block (HEAD) and progress must not count it twice.
        let fake = FakeTUS()
        fake.patchFailures = [0]
        fake.storeBytesOnFailure = true
        let (result, progress) = try await run(fake, parts: 1)
        XCTAssertEqual(result.bytesUploaded, 2000)
        XCTAssertEqual(progress, 2000)
        XCTAssertEqual(fake.headCalls, 1)
    }

    func testRetriesRunOut() async {
        let fake = FakeTUS()
        fake.patchFailures = [500, 500, 500]
        do {
            _ = try await run(fake, parts: 1, delays: [0, 0])
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            XCTAssertEqual(error, .patchFailed(500, ""))
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testFinalIsRetried() async throws {
        let fake = FakeTUS()
        fake.finalFailures = [502]
        let (result, _) = try await run(fake)
        XCTAssertEqual(result.bytesUploaded, 2000)
    }

    func testCancelDuringBackoff() async throws {
        let fake = FakeTUS()
        fake.patchFailures = [500]
        MockURLProtocol.handler = { try fake.handle($0) }
        let file = makeFile(size: 1000)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration(), retryDelays: [30])
        let task = Task {
            try await uploader.upload(fileURL: file, fileSize: 1000, partCount: 1, authHeaders: [:], metadata: [:], onProgress: { _ in })
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let start = Date()
        uploader.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancel")
        } catch let error as ParallelTUSUploader.UploadError {
            XCTAssertEqual(error, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    // MARK: - S-010

    func testExpiredSignatureIsRenewed() async throws {
        let fake = FakeTUS()
        fake.rejectSignature = "old"
        let (result, _) = try await run(
            fake,
            headers: ["AuthorizationSignature": "old"],
            resign: { ["AuthorizationSignature": "new"] }
        )
        XCTAssertEqual(result.bytesUploaded, 2000)
        XCTAssertTrue(fake.signaturesSeen.contains("new"))
    }

    func testSecond401FailsWithSignatureRejected() async {
        let fake = FakeTUS()
        fake.rejectSignature = "same"
        do {
            _ = try await run(
                fake,
                parts: 1,
                headers: ["AuthorizationSignature": "same"],
                resign: { ["AuthorizationSignature": "same"] }
            )
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            XCTAssertEqual(error, .signatureRejected)
            XCTAssertNotNil(error.errorDescription)
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testSignerMakesHeadersForSameVideo() {
        let signer = UploadEngine.signer(credentials: Credentials(apiKey: "k", libraryId: "7"), videoId: "v")
        let headers = signer()
        XCTAssertEqual(headers["VideoId"], "v")
        XCTAssertEqual(headers["LibraryId"], "7")
        XCTAssertEqual(headers["AuthorizationSignature"]?.count, 64)
        XCTAssertNotNil(headers["AuthorizationExpire"])
    }

    // MARK: - S-011

    @MainActor
    func testSleepIsPreventedOnlyWhileUploading() async {
        let fake = FakeTUS()
        MockURLProtocol.handler = { request in
            if request.url!.absoluteString.contains("tusupload") {
                Thread.sleep(forTimeInterval: 0.05)
                return try fake.handle(request)
            }
            if request.httpMethod == "GET" {
                return (200, Data("{\"status\":4}".utf8), [:])
            }
            return (200, Data("{\"guid\":\"g\"}".utf8), [:])
        }
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        engine.partRetryDelays = []
        XCTAssertFalse(engine.isPreventingSleep)

        let file = makeFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        var sawPrevention = false
        let start = Date()
        while !item.state.isTerminal, Date().timeIntervalSince(start) < 15 {
            if engine.isPreventingSleep {
                sawPrevention = true
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawPrevention)
        XCTAssertEqual(item.state, .done)
        XCTAssertFalse(engine.isPreventingSleep)
    }

    // MARK: - S-013 resume

    func testResumeStateMatches() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let state = ResumeState(partCount: 8, fileSize: 100, fileModified: date)
        XCTAssertTrue(state.matches(fileSize: 100, fileModified: date.addingTimeInterval(0.3)))
        XCTAssertFalse(state.matches(fileSize: 101, fileModified: date))
        XCTAssertFalse(state.matches(fileSize: 100, fileModified: date.addingTimeInterval(60)))
        XCTAssertFalse(state.matches(fileSize: 100, fileModified: nil))
        XCTAssertTrue(ResumeState(partCount: 1, fileSize: 1, fileModified: nil).matches(fileSize: 1, fileModified: nil))
        var withParts = state
        withParts.parts = [0: "https://video.bunnycdn.com/tusupload/a"]
        XCTAssertEqual(withParts.partURLs[0]?.absoluteString, "https://video.bunnycdn.com/tusupload/a")
    }

    func testUntrustedPartURLsAreDropped() {
        var state = ResumeState(partCount: 8, fileSize: 100, fileModified: nil)
        state.parts = [
            0: "https://video.bunnycdn.com/tusupload/ok",
            1: "https://evil.example.com/tusupload/x",
            2: "http://video.bunnycdn.com/tusupload/x",
            3: "https://video.bunnycdn.com.evil.example/tusupload/x",
            4: "https://user:pass@video.bunnycdn.com/tusupload/x",
            5: "https://video.bunnycdn.com:8443/tusupload/x",
            6: "https://video.bunnycdn.com/library/1/videos",
            7: "https://video.bunnycdn.com/tusupload/../library",
            9: "https://video.bunnycdn.com/tusupload/out-of-range",
        ]
        XCTAssertEqual(Array(state.partURLs.keys), [0])
        XCTAssertTrue(state.isValid)
        XCTAssertFalse(ResumeState(partCount: 0, fileSize: 100, fileModified: nil).isValid)
        XCTAssertFalse(ResumeState(partCount: 65, fileSize: 100, fileModified: nil).isValid)
        XCTAssertFalse(ResumeState(partCount: 8, fileSize: 0, fileModified: nil).isValid)
    }

    @MainActor
    func testRetryAdoptsVideoBunnyAlreadyHas() async throws {
        // The final request reached Bunny before the app gave up on it (status 2).
        let fake = FakeTUS()
        let engine = makeEngine(fake)
        MockURLProtocol.handler = { request in
            if request.url!.absoluteString.contains("tusupload") {
                return try fake.handle(request)
            }
            return (200, Data(#"{"status":2}"#.utf8), [:])
        }
        let file = makeFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = UploadItem(fileURL: file, fileName: "a.mp4", fileSize: Int64(60 * 1024 * 1024), mimeType: "video/mp4")
        item.videoId = "taken"
        item.libraryId = "1"
        item.state = .error("Final concatenation failed (HTTP 400)")
        engine.reinsert([item])
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.videoId, "taken")
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(fake.stats.created, 0)
        XCTAssertEqual(fake.stats.patched, 0)
    }

    @MainActor
    func testRetryOfDeletedVideoCreatesNewOne() async throws {
        let fake = FakeTUS()
        let engine = makeEngine(fake)
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("tusupload") {
                return try fake.handle(request)
            }
            if request.httpMethod == "GET" {
                if url.hasSuffix("/gone") {
                    return (404, Data(), [:])
                }
                return (200, Data("{\"status\":\(fake.videoStatus)}".utf8), [:])
            }
            return (200, Data(#"{"guid":"fresh"}"#.utf8), [:])
        }
        let file = makeFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        let item = UploadItem(fileURL: file, fileName: "a.mp4", fileSize: Int64(60 * 1024 * 1024), mimeType: "video/mp4")
        item.videoId = "gone"
        item.libraryId = "1"
        item.resume = ResumeState(partCount: 4, fileSize: Int64(60 * 1024 * 1024), fileModified: item.fileModified,
                                  parts: [0: "https://video.bunnycdn.com/tusupload/old0"])
        item.state = .error("x")
        engine.reinsert([item])
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.videoId, "fresh")
        XCTAssertEqual(fake.stats.heads, 0)
        XCTAssertEqual(fake.stats.patched, Int64(60 * 1024 * 1024))
    }

    @MainActor
    func testInvalidSavedSplitStartsOver() async throws {
        let fake = FakeTUS()
        let size = 60 * 1024 * 1024
        let file = makeFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let history = UploadHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uploads.json"))
        history.save([UploadHistoryStore.Record(
            id: UUID(), filePath: file.path, fileName: "a.mp4", fileSize: Int64(size), mimeType: "video/mp4",
            state: .interrupted, bytesUploaded: 0, videoId: "old-video", libraryId: "1", finishedAt: nil,
            resume: ResumeState(partCount: 100_000, fileSize: Int64(size), fileModified: modified,
                                parts: [0: "https://evil.example.com/tusupload/x"])
        )])
        let engine = makeEngine(fake, history: history)
        let item = engine.items[0]
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(fake.stats.heads, 0)
        XCTAssertEqual(fake.stats.created, engine.threadCount(for: Int64(size)))
    }

    func testUploaderResumesSavedParts() async throws {
        let fake = FakeTUS()
        let half = "https://video.bunnycdn.com/tusupload/saved-half"
        fake.preset(half, offset: 500)
        let resumed = ProgressBox()
        let created = ProgressBox()
        let (result, progress) = try await runResume(
            fake,
            resumeParts: [0: URL(string: half)!, 1: URL(string: "https://video.bunnycdn.com/tusupload/expired")!],
            onResumed: { resumed.set($0) },
            onPartCreated: { index, _ in created.set(Int64(index) + 1) }
        )
        XCTAssertEqual(result.bytesUploaded, 2000)
        XCTAssertEqual(progress, 2000)
        XCTAssertEqual(resumed.value, 500)
        // Part 0 sends only its second half; part 1 was gone and starts over.
        XCTAssertEqual(fake.stats.patched, 1500)
        XCTAssertEqual(fake.stats.created, 1)
        XCTAssertEqual(created.value, 2)
    }

    private func runResume(
        _ fake: FakeTUS,
        resumeParts: [Int: URL],
        onResumed: @escaping @Sendable (Int64) -> Void,
        onPartCreated: @escaping @Sendable (Int, URL) -> Void
    ) async throws -> (ParallelTUSUploader.Result, Int64) {
        MockURLProtocol.handler = { try fake.handle($0) }
        let file = makeFile(size: 2000)
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration(), retryDelays: [0])
        let progress = ProgressBox()
        let result = try await uploader.upload(
            fileURL: file,
            fileSize: 2000,
            partCount: 2,
            authHeaders: [:],
            metadata: [:],
            resumeParts: resumeParts,
            onResumed: onResumed,
            onPartCreated: onPartCreated,
            onProgress: { progress.set($0) }
        )
        return (result, progress.value)
    }

    @MainActor
    private func makeEngine(_ fake: FakeTUS, history: UploadHistoryStore? = nil) -> UploadEngine {
        MockURLProtocol.handler = { request in
            if request.url!.absoluteString.contains("tusupload") {
                return try fake.handle(request)
            }
            if request.httpMethod == "GET" {
                return (200, Data("{\"status\":\(fake.videoStatus)}".utf8), [:])
            }
            return (200, Data("{\"guid\":\"new\"}".utf8), [:])
        }
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"), history: history)
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        engine.partRetryDelays = []
        engine.persistCredentials = { _ in }
        return engine
    }

    @MainActor
    private func waitTerminal(_ item: UploadItem) async {
        let start = Date()
        while !item.state.isTerminal, Date().timeIntervalSince(start) < 15 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testFailedUploadSavesPartsAndRetryResumes() async throws {
        let fake = FakeTUS()
        let size = 60 * 1024 * 1024
        let file = makeFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        let history = UploadHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uploads.json"))
        let engine = makeEngine(fake, history: history)

        // First run: every PATCH fails, so the upload fails after the parts exist.
        let partCount = engine.threadCount(for: Int64(size))
        fake.setPatchFailures(Array(repeating: 500, count: partCount))
        engine.addFile(file)
        let item = engine.items[0]
        await waitTerminal(item)
        XCTAssertNotNil(item.state.errorMessage)
        XCTAssertEqual(item.resume?.partCount, partCount)
        let saved = item.resume?.parts.count ?? 0
        XCTAssertGreaterThan(saved, 0)
        XCTAssertEqual(history.load().first?.resume?.parts.count, saved)

        // Retry: saved parts continue (HEAD), missing ones are created, no new video.
        // Parts cancelled after the first failure never used their injected 500s; drop them.
        fake.setPatchFailures([])
        let createdBefore = fake.stats.created
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertNil(item.resume)
        XCTAssertGreaterThanOrEqual(fake.stats.heads, saved)
        XCTAssertEqual(fake.stats.created - createdBefore, partCount - saved)
        XCTAssertEqual(item.videoId, "new")
    }

    @MainActor
    func testInterruptedRowResumesAfterRestart() async throws {
        let fake = FakeTUS()
        let size = 60 * 1024 * 1024
        let file = makeFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: Int64(size), partCount: 4)
        var saved: [Int: String] = [:]
        for (index, part) in parts.enumerated() {
            let url = "https://video.bunnycdn.com/tusupload/old\(index)"
            fake.preset(url, offset: index == 3 ? 0 : part.length)
            saved[index] = url
        }
        let history = UploadHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uploads.json"))
        history.save([UploadHistoryStore.Record(
            id: UUID(), filePath: file.path, fileName: "a.mp4", fileSize: Int64(size), mimeType: "video/mp4",
            state: .uploading, bytesUploaded: 10, videoId: "old-video", libraryId: "1", finishedAt: nil,
            resume: ResumeState(partCount: 4, fileSize: Int64(size), fileModified: modified, parts: saved)
        )])

        let engine = makeEngine(fake, history: history)
        let item = engine.items[0]
        XCTAssertEqual(item.state, .interrupted)
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.videoId, "old-video")
        XCTAssertEqual(fake.stats.created, 0)
        XCTAssertEqual(fake.stats.patched, parts[3].length)
    }

    @MainActor
    func testChangedFileStartsOver() async throws {
        let fake = FakeTUS()
        let size = 60 * 1024 * 1024
        let file = makeFile(size: size)
        defer { try? FileManager.default.removeItem(at: file) }
        let history = UploadHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uploads.json"))
        history.save([UploadHistoryStore.Record(
            id: UUID(), filePath: file.path, fileName: "a.mp4", fileSize: Int64(size), mimeType: "video/mp4",
            state: .error("x"), bytesUploaded: 0, videoId: "old-video", libraryId: "1", finishedAt: nil,
            resume: ResumeState(partCount: 4, fileSize: Int64(size), fileModified: Date(timeIntervalSince1970: 0),
                                parts: [0: "https://video.bunnycdn.com/tusupload/stale"])
        )])
        let engine = makeEngine(fake, history: history)
        let item = engine.items[0]
        engine.retry(item)
        await waitTerminal(item)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(fake.stats.heads, 0)
        XCTAssertEqual(fake.stats.created, engine.threadCount(for: Int64(size)))
        XCTAssertEqual(fake.stats.patched, Int64(size))
    }
}

private extension URLRequest {
    /// Body length of an upload task (URLProtocol sees it as a stream).
    var httpBodyStreamLength: Int? {
        if let body = httpBody {
            return body.count
        }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var total = 0
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 {
                break
            }
            total += n
        }
        return total
    }
}
