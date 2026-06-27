import XCTest
@testable import BunnyUploaderCore

@MainActor
final class UploadEngineTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Sparse temp file of the given size (fast, no real allocation).
    private func makeSparseFile(size: Int64, ext: String = "mp4") -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try! FileHandle(forWritingTo: url)
        try! handle.truncate(atOffset: UInt64(size))
        try! handle.close()
        return url
    }

    private func makeEngine() -> UploadEngine {
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        return engine
    }

    /// Full happy path: Create Video, parallel partials, final, status poll.
    private func installHappyHandler(guid: String = "g1", status: Int = 4) {
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("tusupload") {
                if request.httpMethod == "PATCH" {
                    return (204, Data(), [:])
                }
                let concat = request.value(forHTTPHeaderField: "Upload-Concat") ?? ""
                if concat == "partial" {
                    return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"])
                }
                return (200, Data(), [:]) // final
            }
            // REST API on /library/...
            if request.httpMethod == "GET" {
                return (200, Data("{\"status\":\(status)}".utf8), [:])
            }
            return (200, Data("{\"guid\":\"\(guid)\"}".utf8), [:]) // createVideo
        }
    }

    private func waitForTerminal(_ item: UploadItem, timeout: TimeInterval = 8) async {
        let start = Date()
        while !item.state.isTerminal, Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func testParallelUploadSuccess() async {
        installHappyHandler()
        let engine = makeEngine()
        var finishedName: String?
        engine.onUploadFinished = { finishedName = $0.fileName }

        let file = makeSparseFile(size: 60 * 1024 * 1024) // > 50 MB threshold -> parallel
        defer { try? FileManager.default.removeItem(at: file) }

        engine.addFile(file)
        XCTAssertEqual(engine.items.count, 1)
        let item = engine.items[0]
        await waitForTerminal(item)

        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.videoId, "g1")
        XCTAssertEqual(finishedName, item.fileName)
        XCTAssertEqual(engine.activeCount, 0)
    }

    func testMissingCredentials() async {
        let engine = UploadEngine(credentials: Credentials(apiKey: "", libraryId: ""))
        XCTAssertFalse(engine.hasCredentials)
        let file = makeSparseFile(size: 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitForTerminal(item)
        if case .error = item.state {} else {
            XCTFail("Expected error state, got \(item.state)")
        }
    }

    func testCreateVideoFailureNotifiesHook() async {
        MockURLProtocol.handler = { _ in (500, Data("nope".utf8), [:]) }
        let engine = makeEngine()
        var failedMessage: String?
        engine.onUploadFailed = { _, message in failedMessage = message }

        let file = makeSparseFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitForTerminal(item)

        if case .error = item.state {} else {
            XCTFail("Expected error, got \(item.state)")
        }
        XCTAssertNotNil(failedMessage)
    }

    func testCancelUpload() async {
        installHappyHandler()
        let engine = makeEngine()
        let file = makeSparseFile(size: 200 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        // Wait until it is actively uploading, then cancel.
        let start = Date()
        while item.state == .idle, Date().timeIntervalSince(start) < 3 {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        engine.cancelUpload(item)
        XCTAssertEqual(item.state, .cancelled)
        XCTAssertEqual(engine.activeCount, 0)
    }

    func testPollProcessingRetriesThenDone() async {
        // Status stays below 3, so the poll loop runs all attempts then settles on .done.
        installHappyHandler(status: 0)
        let engine = makeEngine()
        let file = makeSparseFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitForTerminal(item, timeout: 14)
        XCTAssertEqual(item.state, .done)
    }

    func testRemoveItem() async {
        installHappyHandler()
        let engine = makeEngine()
        let file = makeSparseFile(size: 60 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: file) }
        engine.addFile(file)
        let item = engine.items[0]
        await waitForTerminal(item)
        engine.removeItem(item)
        XCTAssertTrue(engine.items.isEmpty)
    }
}
