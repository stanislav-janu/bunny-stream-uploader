import XCTest
@testable import BunnyUploaderCore

/// Processing after upload (S-015), play page (S-016), and collections (S-017).
@MainActor
final class M3AfterUploadTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        for key in ["collectionId", "collectionName", "collectionLibraryId"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    /// Thread-safe answers for the mock: video status sequence and request log.
    final class Bunny: @unchecked Sendable {
        private let lock = NSLock()
        private var statuses: [Int]
        private var _bodies: [String] = []
        private var _gets = 0

        init(statuses: [Int]) {
            self.statuses = statuses
        }

        var bodies: [String] {
            lock.withLock { _bodies }
        }

        var gets: Int {
            lock.withLock { _gets }
        }

        func handle(_ request: URLRequest) -> (Int, Data, [String: String]) {
            lock.withLock {
                let url = request.url!.absoluteString
                if url.contains("tusupload") {
                    if request.httpMethod == "PATCH" {
                        return (204, Data(), [:])
                    }
                    if request.value(forHTTPHeaderField: "Upload-Concat") == "partial" {
                        return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"])
                    }
                    return (200, Data(), [:])
                }
                if request.httpMethod == "GET" {
                    _gets += 1
                    let status = statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? 0)
                    return (200, Data("{\"status\":\(status)}".utf8), [:])
                }
                if let body = request.httpBody ?? request.httpBodyStream.map(Self.read) {
                    _bodies.append(String(data: body, encoding: .utf8) ?? "")
                }
                return (200, Data("{\"guid\":\"g\"}".utf8), [:])
            }
        }

        private static func read(_ stream: InputStream) -> Data {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 {
                    break
                }
                data.append(buffer, count: n)
            }
            return data
        }
    }

    private func makeEngine(_ bunny: Bunny) -> UploadEngine {
        MockURLProtocol.handler = { bunny.handle($0) }
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        engine.partRetryDelays = []
        engine.processingPollInterval = 0.02
        engine.persistCredentials = { _ in }
        return engine
    }

    private func makeFile() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.truncate(atOffset: 60 * 1024 * 1024)
        try! handle.close()
        return url
    }

    private func wait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) async {
        let start = Date()
        while !condition(), Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - S-015

    func testStatusMapping() {
        XCTAssertEqual(BunnyAPIClient.processing(forStatus: 4), .ready)
        XCTAssertEqual(BunnyAPIClient.processing(forStatus: 5), .failed)
        XCTAssertEqual(BunnyAPIClient.processing(forStatus: 6), .failed)
        for status in [0, 1, 2, 3, 7, 8] {
            XCTAssertEqual(BunnyAPIClient.processing(forStatus: status), .processing, "\(status)")
        }
        for value in [BunnyProcessing.processing, .ready, .failed] {
            XCTAssertFalse(value.label.isEmpty)
        }
    }

    func testDoneRightAwayThenReadyToPlay() async {
        let bunny = Bunny(statuses: [2, 3, 4])
        let engine = makeEngine(bunny)
        var finished = 0
        engine.onUploadFinished = { _ in finished += 1 }
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await wait { item.state == .done }
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(finished, 1)
        await wait { item.processing == .ready }
        XCTAssertEqual(item.processing, .ready)
        XCTAssertGreaterThanOrEqual(bunny.gets, 3)
    }

    func testProcessingFailure() async {
        let bunny = Bunny(statuses: [2, 5])
        let engine = makeEngine(bunny)
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await wait { item.processing == .failed }
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.processing, .failed)
    }

    func testProcessingGivesUpAfterTimeout() async {
        let bunny = Bunny(statuses: [3])
        let engine = makeEngine(bunny)
        engine.processingTimeout = 0.1
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await wait { item.state == .done && item.processing == nil }
        XCTAssertNil(item.processing)
    }

    func testRestoredProcessingRowIsCheckedAgain() async {
        let bunny = Bunny(statuses: [4])
        MockURLProtocol.handler = { bunny.handle($0) }
        let history = UploadHistoryStore(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("uploads.json"))
        history.save([UploadHistoryStore.Record(
            id: UUID(), filePath: "/tmp/a.mp4", fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4",
            state: .processing, bytesUploaded: 1, videoId: "g", libraryId: "1", finishedAt: Date()
        )])
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"), history: history)
        engine.apiSession = MockURLProtocol.makeSession()
        engine.processingPollInterval = 0.02
        let item = engine.items[0]
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.processing, .processing)
        engine.resumeProcessingChecks()
        await wait { item.processing == .ready }
        XCTAssertEqual(item.processing, .ready)
        await wait { history.load().first?.processing == .ready }
        XCTAssertEqual(history.load().first?.processing, .ready)
    }

    func testRemoveStopsProcessingCheck() async {
        let bunny = Bunny(statuses: [3])
        let engine = makeEngine(bunny)
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await wait { item.state == .done }
        engine.removeItem(item)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let gets = bunny.gets
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(bunny.gets, gets)
    }

    // MARK: - S-016

    func testPlayLink() {
        XCTAssertEqual(BunnyAPIClient.playLink(libraryId: "42", videoId: "abc"), "https://player.mediadelivery.net/play/42/abc")
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        XCTAssertNil(item.playLink)
        item.videoId = "abc"
        item.libraryId = "42"
        XCTAssertEqual(item.playLink?.absoluteString, "https://player.mediadelivery.net/play/42/abc")
    }

    // MARK: - S-017

    func testListCollectionsParsesAndSorts() async throws {
        var seen: URLRequest?
        MockURLProtocol.handler = { request in
            seen = request
            let body = """
            {"totalItems":3,"items":[{"guid":"b","name":"Zoo"},{"guid":"a","name":"apples"},{"name":"no guid"}]}
            """
            return (200, Data(body.utf8), [:])
        }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "k", libraryId: "9"), session: MockURLProtocol.makeSession())
        let list = try await client.listCollections()
        XCTAssertEqual(list, [.init(id: "a", name: "apples"), .init(id: "b", name: "Zoo")])
        XCTAssertTrue(seen?.url?.absoluteString.hasPrefix("https://video.bunnycdn.com/library/9/collections?") ?? false)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "AccessKey"), "k")
    }

    func testListCollectionsBadResponse() async {
        MockURLProtocol.handler = { _ in (200, Data("[]".utf8), [:]) }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "k", libraryId: "9"), session: MockURLProtocol.makeSession())
        do {
            _ = try await client.listCollections()
            XCTFail("Expected decoding error")
        } catch {
            XCTAssertEqual(error as? BunnyAPIClient.APIError, .decoding)
        }
    }

    func testUploadGoesIntoChosenCollection() async {
        let bunny = Bunny(statuses: [4])
        let engine = makeEngine(bunny)
        engine.setCollection(.init(id: "col-1", name: "Ads"))
        let file = makeFile()
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await wait { item.state == .done }
        XCTAssertTrue(bunny.bodies.contains { $0.contains("\"collectionId\":\"col-1\"") }, "\(bunny.bodies)")

        engine.setCollection(nil)
        XCTAssertNil(engine.collection)
    }

    func testCollectionIsPerLibraryAndSurvivesRestart() {
        let engine = makeEngine(Bunny(statuses: [4]))
        engine.setCollection(.init(id: "col-1", name: "Ads"))
        let again = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        XCTAssertEqual(again.collection, .init(id: "col-1", name: "Ads"))
        let otherLibrary = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "2"))
        XCTAssertNil(otherLibrary.collection)
        again.persistCredentials = { _ in }
        again.saveCredentials(Credentials(apiKey: "k", libraryId: "2"))
        XCTAssertNil(again.collection)
    }

    func testSavedCollectionGoneFallsBackToNone() async throws {
        let engine = makeEngine(Bunny(statuses: [4]))
        engine.setCollection(.init(id: "old", name: "Old"))
        MockURLProtocol.handler = { _ in (200, Data(#"{"items":[{"guid":"new","name":"New"}]}"#.utf8), [:]) }
        let result = try await engine.loadCollections()
        XCTAssertTrue(result.savedCollectionGone)
        XCTAssertNil(engine.collection)
        XCTAssertEqual(result.collections.map(\.id), ["new"])
    }

    func testListRecentVideosAndVideoInfo() async throws {
        MockURLProtocol.handler = { request in
            if request.url!.path.hasSuffix("/videos") {
                return (200, Data(#"{"items":[{"status":4},{"status":2}]}"#.utf8), [:])
            }
            return (200, Data(#"{"status":3,"collectionId":""}"#.utf8), [:])
        }
        let client = BunnyAPIClient(credentials: Credentials(apiKey: "k", libraryId: "9"), session: MockURLProtocol.makeSession())
        let recent = try await client.listRecentVideos(count: 2)
        XCTAssertEqual(recent.count, 2)
        let info = try await client.getVideoInfo(guid: "g")
        XCTAssertEqual(info.status, 3)
        XCTAssertNil(info.collectionId)
    }

    func testRenamedCollectionKeepsSelection() async throws {
        let engine = makeEngine(Bunny(statuses: [4]))
        engine.setCollection(.init(id: "c", name: "Old name"))
        MockURLProtocol.handler = { _ in (200, Data(#"{"items":[{"guid":"c","name":"New name"}]}"#.utf8), [:]) }
        let result = try await engine.loadCollections()
        XCTAssertFalse(result.savedCollectionGone)
        XCTAssertEqual(engine.collection, .init(id: "c", name: "New name"))
    }
}
