import XCTest
@testable import BunnyUploaderCore

/// Credentials check (S-002), embed link (S-006), Retry (S-007), and the saved list (S-008).
@MainActor
final class M1FeatureTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func tempHistory() -> UploadHistoryStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("uploads.json")
        return UploadHistoryStore(fileURL: url)
    }

    private func makeFile(size: Int = 1024) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        FileManager.default.createFile(atPath: url.path, contents: Data(count: size))
        return url
    }

    private func makeEngine(history: UploadHistoryStore? = nil) -> UploadEngine {
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"), history: history)
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        engine.partRetryDelays = []
        engine.persistCredentials = { _ in }
        return engine
    }

    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - S-002 credentials check

    private func check(status: Int) async -> BunnyAPIClient.CredentialCheckError? {
        MockURLProtocol.handler = { _ in (status, Data("{}".utf8), [:]) }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "k", libraryId: "1"), session: MockURLProtocol.makeSession())
        do {
            try await client.checkCredentials()
            return nil
        } catch {
            return error
        }
    }

    func testCheckCredentialsMapsStatus() async {
        let passed = await check(status: 200)
        XCTAssertNil(passed)
        let rejected = await check(status: 401)
        XCTAssertEqual(rejected, .keyRejected)
        let forbidden = await check(status: 403)
        XCTAssertEqual(forbidden, .keyRejected)
        let missing = await check(status: 404)
        XCTAssertEqual(missing, .libraryNotFound)
        let other = await check(status: 500)
        XCTAssertEqual(other, .unexpected(500))
    }

    func testCheckCredentialsNetworkError() async {
        MockURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "k", libraryId: "1"), session: MockURLProtocol.makeSession())
        do {
            try await client.checkCredentials()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error, .unreachable)
        }
    }

    func testCheckCredentialsRequest() async {
        var seen: URLRequest?
        MockURLProtocol.handler = { request in
            seen = request
            return (200, Data(), [:])
        }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "secret", libraryId: "42"), session: MockURLProtocol.makeSession())
        try? await client.checkCredentials()
        XCTAssertEqual(seen?.httpMethod, "GET")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "AccessKey"), "secret")
        XCTAssertTrue(seen?.url?.absoluteString.hasPrefix("https://video.bunnycdn.com/library/42/videos?") ?? false)
    }

    func testCheckErrorMessagesAreNotEmpty() {
        let all: [BunnyAPIClient.CredentialCheckError] = [.keyRejected, .libraryNotFound, .unreachable, .unexpected(502)]
        for error in all {
            XCTAssertFalse(error.message.isEmpty)
        }
        XCTAssertTrue(BunnyAPIClient.CredentialCheckError.unexpected(502).message.contains("502"))
    }

    func testSaveStoresOnlyAfterPassedCheck() async {
        let engine = UploadEngine(credentials: Credentials(apiKey: "", libraryId: ""))
        engine.apiSession = MockURLProtocol.makeSession()
        var stored: [Credentials] = []
        engine.persistCredentials = { stored.append($0) }

        MockURLProtocol.handler = { _ in (401, Data(), [:]) }
        let failed = await engine.checkAndSaveCredentials(Credentials(apiKey: "bad", libraryId: "1"))
        XCTAssertEqual(failed, .keyRejected)
        XCTAssertTrue(stored.isEmpty)
        XCTAssertFalse(engine.hasCredentials)

        MockURLProtocol.handler = { _ in (200, Data(), [:]) }
        let passed = await engine.checkAndSaveCredentials(Credentials(apiKey: "good", libraryId: "1"))
        XCTAssertNil(passed)
        XCTAssertEqual(stored, [Credentials(apiKey: "good", libraryId: "1")])
        XCTAssertTrue(engine.hasCredentials)
    }

    // MARK: - S-006 embed link

    func testEmbedLink() {
        XCTAssertEqual(
            BunnyAPIClient.embedLink(libraryId: "42", videoId: "abc"),
            "https://player.mediadelivery.net/embed/42/abc"
        )
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        XCTAssertNil(item.embedLink)
        item.videoId = "abc"
        item.libraryId = "42"
        XCTAssertEqual(item.embedLink, "https://player.mediadelivery.net/embed/42/abc")
    }

    // MARK: - S-007 Retry

    func testStateRetryRules() {
        XCTAssertTrue(UploadState.cancelled.canRetry)
        XCTAssertTrue(UploadState.interrupted.canRetry)
        XCTAssertTrue(UploadState.error("x").canRetry)
        XCTAssertFalse(UploadState.done.canRetry)
        XCTAssertFalse(UploadState.uploading.canRetry)
        XCTAssertEqual(UploadState.error("boom").errorMessage, "boom")
        XCTAssertNil(UploadState.done.errorMessage)
        XCTAssertTrue(UploadState.interrupted.isTerminal)
        XCTAssertFalse(UploadState.interrupted.label.isEmpty)
    }

    /// Shared state for a mock handler that runs on several URLSession queues at once.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _createCalls = 0
        private var _videoIds: [String] = []
        private var _failTus = true
        private var _finalDone = false

        var finalDone: Bool {
            get { lock.withLock { _finalDone } }
            set { lock.withLock { _finalDone = newValue } }
        }

        var createCalls: Int {
            lock.withLock { _createCalls }
        }
        var videoIds: [String] {
            lock.withLock { _videoIds }
        }
        var failTus: Bool {
            get { lock.withLock { _failTus } }
            set { lock.withLock { _failTus = newValue } }
        }

        func nextCreate() -> Int {
            lock.withLock {
                _createCalls += 1
                return _createCalls
            }
        }

        func record(_ id: String) {
            lock.withLock {
                _videoIds.append(id)
            }
        }

        func clearIds() {
            lock.withLock {
                _videoIds.removeAll()
            }
        }
    }

    func testRetryReusesVideoId() async {
        let recorder = Recorder()
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("tusupload") {
                if let id = request.value(forHTTPHeaderField: "VideoId") {
                    recorder.record(id)
                }
                if recorder.failTus {
                    return (500, Data("down".utf8), [:])
                }
                if request.httpMethod == "PATCH" {
                    return (204, Data(), [:])
                }
                if request.value(forHTTPHeaderField: "Upload-Concat") == "partial" {
                    return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"])
                }
                recorder.finalDone = true
                return (200, Data(), [:])
            }
            if request.httpMethod == "GET" {
                // Bunny keeps the video at 0 (Created) until a final request arrives.
                return (200, Data("{\"status\":\(recorder.finalDone ? 4 : 0)}".utf8), [:])
            }
            let call = recorder.nextCreate()
            return (200, Data("{\"guid\":\"g-\(call)\"}".utf8), [:])
        }
        let engine = makeEngine()
        let file = makeFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }

        engine.addFile(file)
        let item = engine.items[0]
        await waitUntil { item.state.isTerminal }
        XCTAssertNotNil(item.state.errorMessage)
        XCTAssertEqual(item.videoId, "g-1")
        XCTAssertEqual(item.libraryId, "1")

        recorder.failTus = false
        recorder.clearIds()
        engine.retry(item)
        await waitUntil(12) { item.state == .done }
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(recorder.createCalls, 1)
        XCTAssertEqual(Set(recorder.videoIds), ["g-1"])
    }

    func testRetryMissingFile() async {
        let engine = makeEngine()
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mp4"), fileName: "x.mp4", fileSize: 10, mimeType: "video/mp4")
        item.state = .cancelled
        engine.reinsert([item])
        engine.retry(item)
        XCTAssertNotNil(item.state.errorMessage)
        XCTAssertFalse(item.fileExists)
    }

    func testRetryIgnoresDoneItem() {
        let engine = makeEngine()
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        item.state = .done
        engine.retry(item)
        XCTAssertEqual(item.state, .done)
    }

    // MARK: - S-008 saved list

    func testRestoredStates() {
        XCTAssertEqual(UploadState.uploading.restored, .interrupted)
        XCTAssertEqual(UploadState.creatingVideo.restored, .interrupted)
        XCTAssertEqual(UploadState.idle.restored, .interrupted)
        XCTAssertEqual(UploadState.processing.restored, .done)
        XCTAssertEqual(UploadState.done.restored, .done)
        XCTAssertEqual(UploadState.error("x").restored, .error("x"))
    }

    func testHistoryRoundTrip() {
        let store = tempHistory()
        XCTAssertTrue(store.load().isEmpty)
        let record = UploadHistoryStore.Record(
            id: UUID(),
            filePath: "/tmp/a.mp4",
            fileName: "a.mp4",
            fileSize: 100,
            mimeType: "video/mp4",
            state: .error("boom"),
            bytesUploaded: 40,
            videoId: "g",
            libraryId: "1",
            finishedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        store.save([record])
        XCTAssertEqual(store.load(), [record])
    }

    func testEngineLoadsHistoryAsInterrupted() {
        let store = tempHistory()
        let running = UploadHistoryStore.Record(
            id: UUID(), filePath: "/tmp/a.mp4", fileName: "a.mp4", fileSize: 100, mimeType: "video/mp4",
            state: .uploading, bytesUploaded: 40, videoId: "g1", libraryId: "1", finishedAt: nil
        )
        let finished = UploadHistoryStore.Record(
            id: UUID(), filePath: "/tmp/b.mp4", fileName: "b.mp4", fileSize: 100, mimeType: "video/mp4",
            state: .processing, bytesUploaded: 100, videoId: "g2", libraryId: "1", finishedAt: Date()
        )
        store.save([running, finished])

        let engine = makeEngine(history: store)
        XCTAssertEqual(engine.items.map(\.state), [.interrupted, .done])
        XCTAssertEqual(engine.items[0].videoId, "g1")
        XCTAssertEqual(engine.items[1].progress, 1)
        XCTAssertEqual(store.load().map(\.state), [.interrupted, .done])
    }

    func testFinishedUploadIsSavedAndClearFinished() async {
        MockURLProtocol.handler = { request in
            if request.url!.absoluteString.contains("tusupload") {
                return (500, Data(), [:])
            }
            return (200, Data("{\"guid\":\"g\"}".utf8), [:])
        }
        let store = tempHistory()
        let engine = makeEngine(history: store)
        let file = makeFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitUntil { item.state.isTerminal && item.finishedAt != nil }
        await waitUntil { store.load().first?.state.isTerminal == true }
        XCTAssertNotNil(item.finishedAt)
        XCTAssertNotNil(store.load().first?.state.errorMessage)

        // A done row added by hand, then cleared and restored (Undo).
        let done = UploadItem(fileURL: file, fileName: "done.mp4", fileSize: 1, mimeType: "video/mp4")
        done.state = .done
        done.finishedAt = Date()
        engine.reinsert([done])
        XCTAssertTrue(engine.hasFinished)
        XCTAssertEqual(engine.items.count, 2)

        let removed = engine.clearFinished()
        XCTAssertEqual(removed.count, 1)
        XCTAssertFalse(engine.hasFinished)
        XCTAssertEqual(store.load().count, 1)

        engine.reinsert(removed)
        XCTAssertEqual(engine.items.count, 2)
        XCTAssertEqual(store.load().count, 2)
    }

    func testRemovedRowComesBack() {
        let store = tempHistory()
        let engine = makeEngine(history: store)
        let done = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        done.state = .done
        done.videoId = "kept"
        done.finishedAt = Date()
        engine.reinsert([done])
        engine.removeItem(done)
        XCTAssertTrue(engine.items.isEmpty)
        XCTAssertTrue(store.load().isEmpty)

        // What Command-Z does after Remove.
        engine.reinsert([done])
        XCTAssertEqual(engine.items.first?.videoId, "kept")
        XCTAssertEqual(store.load().first?.videoId, "kept")
    }

    func testNewestUploadIsOnTop() {
        MockURLProtocol.handler = { _ in (500, Data(), [:]) }
        let engine = makeEngine()
        let first = makeFile()
        let second = makeFile()
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        engine.addFile(first)
        engine.addFile(second)
        XCTAssertEqual(engine.items.first?.fileURL, second)
    }

    // MARK: - S-014 delete unfinished videos

    /// Thread-safe list of DELETE paths seen by the mock.
    private final class DeleteLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _paths: [String] = []
        var paths: [String] {
            lock.withLock { _paths }
        }
        func add(_ path: String) {
            lock.withLock {
                _paths.append(path)
            }
        }
    }

    /// Create Video answers `guid`; uploads stall or fail as asked; DELETE is recorded.
    private func installDeleteHandler(_ log: DeleteLog, tusStatus: Int = 500, createDelay: TimeInterval = 0) {
        MockURLProtocol.handler = { request in
            let url = request.url!
            if request.httpMethod == "DELETE" {
                log.add(url.path)
                return (200, Data(), [:])
            }
            if url.absoluteString.contains("tusupload") {
                return (tusStatus, Data(), [:])
            }
            if createDelay > 0 {
                Thread.sleep(forTimeInterval: createDelay)
            }
            return (200, Data("{\"guid\":\"g\"}".utf8), [:])
        }
    }

    func testCancelDeletesVideo() async {
        let log = DeleteLog()
        installDeleteHandler(log)
        let engine = makeEngine()
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        item.videoId = "g"
        item.libraryId = "1"
        item.state = .uploading
        engine.reinsert([item])
        engine.cancelUpload(item)
        await waitUntil { !log.paths.isEmpty }
        XCTAssertEqual(log.paths, ["/library/1/videos/g"])
        XCTAssertNil(item.videoId)
        XCTAssertEqual(item.state, .cancelled)
    }

    func testRemoveFailedDeletesVideoButDoneKeepsIt() async {
        let log = DeleteLog()
        installDeleteHandler(log)
        let engine = makeEngine()
        let done = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        done.videoId = "kept"
        done.libraryId = "1"
        done.state = .done
        let failed = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/b.mp4"), fileName: "b.mp4", fileSize: 1, mimeType: "video/mp4")
        failed.videoId = "gone"
        failed.libraryId = "1"
        failed.state = .error("x")
        engine.reinsert([done, failed])

        engine.removeItem(done)
        engine.removeItem(failed)
        await waitUntil { !log.paths.isEmpty }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(log.paths, ["/library/1/videos/gone"])
        XCTAssertTrue(engine.items.isEmpty)
    }

    func testOtherLibraryVideoIsNotDeleted() async {
        let log = DeleteLog()
        installDeleteHandler(log)
        let engine = makeEngine()
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        item.videoId = "g"
        item.libraryId = "999"
        item.state = .interrupted
        engine.reinsert([item])
        engine.removeItem(item)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(log.paths.isEmpty)
    }

    func testCancelWhileCreatingVideoDeletesNewVideo() async {
        let log = DeleteLog()
        installDeleteHandler(log, createDelay: 0.3)
        let engine = makeEngine()
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitUntil { item.state == .creatingVideo }
        engine.cancelUpload(item)
        await waitUntil { !log.paths.isEmpty }
        XCTAssertEqual(log.paths, ["/library/1/videos/g"])
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertNil(item.videoId)
    }

    func testDeleteVideoFailureIsSilent() async {
        MockURLProtocol.handler = { _ in (500, Data("no".utf8), [:]) }
        let engine = makeEngine()
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        item.videoId = "g"
        item.libraryId = "1"
        item.state = .uploading
        engine.reinsert([item])
        engine.cancelUpload(item)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(item.state, .cancelled)
    }

    func testDeleteVideoRequest() async throws {
        var seen: URLRequest?
        MockURLProtocol.handler = { request in
            seen = request
            return (204, Data(), [:])
        }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "secret", libraryId: "42"), session: MockURLProtocol.makeSession())
        try await client.deleteVideo(guid: "abc")
        XCTAssertEqual(seen?.httpMethod, "DELETE")
        XCTAssertEqual(seen?.url?.absoluteString, "https://video.bunnycdn.com/library/42/videos/abc")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "AccessKey"), "secret")
    }
}
