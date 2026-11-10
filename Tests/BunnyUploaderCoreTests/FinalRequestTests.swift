import XCTest
@testable import BunnyUploaderCore

/// The final concatenation request: confirmed through the video status instead of
/// waiting minutes for Bunny's answer, and quitting allowed once it went out.
final class FinalRequestTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _finals = 0
        private var _sent = 0
        private var _asks = 0
        var finals: Int { lock.withLock { _finals } }
        var sent: Int { lock.withLock { _sent } }
        var asks: Int { lock.withLock { _asks } }
        func final() { lock.withLock { _finals += 1 } }
        func markSent() { lock.withLock { _sent += 1 } }
        func ask() -> Int {
            lock.withLock {
                _asks += 1
                return _asks
            }
        }
    }

    /// Parts succeed; the final request runs `final`.
    private func install(_ counter: Counter, final: @escaping @Sendable () throws -> (Int, Data, [String: String])) {
        MockURLProtocol.handler = { request in
            let concat = request.value(forHTTPHeaderField: "Upload-Concat") ?? ""
            if request.httpMethod == "POST", concat == "partial" {
                return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"])
            }
            if request.httpMethod == "PATCH" {
                return (204, Data(), [:])
            }
            counter.final()
            return try final()
        }
    }

    private func upload(_ counter: Counter, delays: [TimeInterval] = [0], accepted: @escaping @Sendable () async -> Bool) async throws -> TimeInterval {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(atPath: file.path, contents: Data(repeating: 1, count: 1000))
        defer { try? FileManager.default.removeItem(at: file) }
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration(), retryDelays: delays, finalPollInterval: 0.05)
        let start = Date()
        _ = try await uploader.upload(
            fileURL: file,
            fileSize: 1000,
            partCount: 2,
            authHeaders: [:],
            metadata: [:],
            onFinalSent: { counter.markSent() },
            finalAccepted: accepted,
            onProgress: { _ in }
        )
        return Date().timeIntervalSince(start)
    }

    func testSlowFinalIsConfirmedByVideoStatus() async throws {
        let counter = Counter()
        install(counter) {
            Thread.sleep(forTimeInterval: 3)
            return (200, Data(), [:])
        }
        let elapsed = try await upload(counter) { counter.ask() >= 2 }
        XCTAssertLessThan(elapsed, 2)
        XCTAssertEqual(counter.finals, 1)
        XCTAssertEqual(counter.sent, 1)
    }

    func testFastAnswerNeedsNoStatus() async throws {
        let counter = Counter()
        install(counter) { (200, Data(), [:]) }
        _ = try await upload(counter) {
            counter.ask()
            return false
        }
        XCTAssertEqual(counter.finals, 1)
    }

    func testDroppedFinalIsNotResentWhenBunnyHasIt() async throws {
        let counter = Counter()
        install(counter) { throw URLError(.timedOut) }
        // The status poll never fires before the drop; the retry asks first and finds the video.
        _ = try await upload(counter) { true }
        XCTAssertEqual(counter.finals, 1)
        XCTAssertEqual(counter.sent, 1)
    }

    func testDroppedFinalIsResentWhenBunnyHasNothing() async {
        let counter = Counter()
        install(counter) { throw URLError(.timedOut) }
        do {
            _ = try await upload(counter, delays: [0, 0]) { false }
            XCTFail("Expected failure")
        } catch {
            XCTAssertEqual(counter.finals, 3)
            XCTAssertEqual(counter.sent, 1)
        }
    }

    @MainActor
    func testQuitIsNotBlockedOnceFinalWentOut() {
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        let running = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/a.mp4"), fileName: "a.mp4", fileSize: 1, mimeType: "video/mp4")
        running.state = .uploading
        let finishing = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/b.mp4"), fileName: "b.mp4", fileSize: 1, mimeType: "video/mp4")
        finishing.state = .uploading
        finishing.finalSent = true
        engine.reinsert([running, finishing])
        XCTAssertEqual(engine.uploadsBlockingQuit, 1)
    }

    @MainActor
    func testRowQuitAfterFinalLoadsAsDone() {
        let record = UploadHistoryStore.Record(
            id: UUID(), filePath: "/tmp/a.mp4", fileName: "a.mp4", fileSize: 100, mimeType: "video/mp4",
            state: .uploading, bytesUploaded: 100, videoId: "g", libraryId: "1", finishedAt: nil,
            resume: ResumeState(partCount: 2, fileSize: 100, fileModified: nil), finalSent: true
        )
        let item = UploadItem(restoring: record)
        XCTAssertEqual(item.state, .done)
        XCTAssertEqual(item.processing, .processing)
        XCTAssertNil(item.resume)
        XCTAssertEqual(item.progress, 1)

        var stopped = record
        stopped.finalSent = nil
        XCTAssertEqual(UploadItem(restoring: stopped).state, .interrupted)
    }
}
