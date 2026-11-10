import XCTest
@testable import BunnyUploaderCore

/// The upload queue (S-019): one parallel upload at a time, up to three small ones beside it.
final class QueueTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private let a = UUID()
    private let b = UUID()
    private let c = UUID()
    private let d = UUID()
    private let e = UUID()

    func testOneParallelAtATime() {
        let start = UploadEngine.uploadsToStart(queued: [(a, true), (b, true)], parallelRunning: false, singleRunning: 0)
        XCTAssertEqual(start, [a])
        let busy = UploadEngine.uploadsToStart(queued: [(a, true)], parallelRunning: true, singleRunning: 0)
        XCTAssertEqual(busy, [])
    }

    func testSmallFilesFillBesideAndPassAWaitingBigOne() {
        let start = UploadEngine.uploadsToStart(
            queued: [(a, true), (b, false), (c, false), (d, false), (e, false)],
            parallelRunning: true,
            singleRunning: 0
        )
        XCTAssertEqual(start, [b, c, d])
        let full = UploadEngine.uploadsToStart(queued: [(b, false)], parallelRunning: false, singleRunning: 3)
        XCTAssertEqual(full, [])
    }

    final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var _open = false
        var open: Bool {
            get { lock.withLock { _open } }
            set { lock.withLock { _open = newValue } }
        }
    }

    @MainActor
    func testSecondBigFileWaitsAndStartsAfterTheFirst() async {
        let gate = Gate()
        MockURLProtocol.handler = { request in
            let url = request.url!.absoluteString
            if url.contains("tusupload") {
                if request.httpMethod == "PATCH" {
                    // Hold the uploads until the test opens the gate.
                    while !gate.open {
                        Thread.sleep(forTimeInterval: 0.01)
                    }
                    return (204, Data(), [:])
                }
                if request.value(forHTTPHeaderField: "Upload-Concat") == "partial" {
                    return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"])
                }
                return (200, Data(), [:])
            }
            if request.httpMethod == "GET" {
                return (200, Data(#"{"status":0}"#.utf8), [:])
            }
            return (200, Data("{\"guid\":\"\(UUID().uuidString)\"}".utf8), [:])
        }
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        engine.apiSession = MockURLProtocol.makeSession()
        engine.parallelSessionConfiguration = MockURLProtocol.makeConfiguration()
        engine.partRetryDelays = []
        engine.autoThreads = true

        var files: [URL] = []
        for _ in 0..<2 {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try! FileHandle(forWritingTo: url)
            try! handle.truncate(atOffset: 60 * 1024 * 1024)
            try! handle.close()
            files.append(url)
        }
        defer {
            for url in files {
                try? FileManager.default.removeItem(at: url)
            }
        }
        engine.addFile(files[0])
        engine.addFile(files[1])
        let first = engine.items[1]
        let second = engine.items[0]
        XCTAssertTrue(first.state.isActive)
        XCTAssertEqual(second.state, .idle)
        XCTAssertEqual(engine.queuePosition(of: second), 1)
        XCTAssertNil(engine.queuePosition(of: first))
        XCTAssertEqual(engine.uploadsBlockingQuit, 2)

        // Cancelling the running upload starts the waiting one.
        engine.cancelUpload(first)
        let start = Date()
        while !second.state.isActive, Date().timeIntervalSince(start) < 3 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(second.state.isActive)
        gate.open = true
        while !second.state.isTerminal, Date().timeIntervalSince(start) < 10 {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(second.state, .done)
    }

    @MainActor
    func testCancelAllStopsRunningAndWaiting() {
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        let running = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a", fileSize: 1, mimeType: "video/mp4")
        running.state = .uploading
        let waiting = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/b.mp4"), fileName: "b", fileSize: 1, mimeType: "video/mp4")
        waiting.state = .idle
        let done = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/c.mp4"), fileName: "c", fileSize: 1, mimeType: "video/mp4")
        done.state = .done
        engine.reinsert([running, waiting, done])
        engine.cancelAll()
        XCTAssertEqual(running.state, .cancelled)
        XCTAssertEqual(waiting.state, .cancelled)
        XCTAssertEqual(done.state, .done)
    }
}
