import XCTest
@testable import BunnyUploaderCore

/// Runs the fault test end to end against the in-process fake TUS server.
final class FaultTestTests: XCTestCase {
    private var savedForwarding: URLSession!

    override func setUp() {
        super.setUp()
        savedForwarding = FaultInjectingURLProtocol.forwardingSession
        FaultInjectingURLProtocol.forwardingSession = MockURLProtocol.makeSession()
    }

    override func tearDown() {
        FaultInjectingURLProtocol.forwardingSession = savedForwarding
        FaultInjectingURLProtocol.state.setRandom { Double.random(in: 0..<1) }
        FaultInjectingURLProtocol.state.faults = FaultInjectingURLProtocol.Faults()
        FaultInjectingURLProtocol.state.reset()
        MockURLProtocol.reset()
        super.tearDown()
    }

    /// Deterministic dice: cycles through the given rolls.
    final class Dice: @unchecked Sendable {
        private let lock = NSLock()
        private let rolls: [Double]
        private var index = 0
        init(_ rolls: [Double]) {
            self.rolls = rolls
        }
        func next() -> Double {
            lock.withLock {
                let value = rolls[index % rolls.count]
                index += 1
                return value
            }
        }
    }

    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var _all: [String] = []
        var all: [String] {
            lock.withLock { _all }
        }
        func add(_ line: String) {
            lock.withLock {
                _all.append(line)
            }
        }
    }

    private func install(_ fake: M2ReliabilityTests.FakeTUS, deleted: Lines) {
        MockURLProtocol.handler = { request in
            fake.rejectSignature = String(repeating: "0", count: 64)
            let url = request.url!.absoluteString
            if url.contains("tusupload") {
                return try fake.handle(request)
            }
            if request.httpMethod == "DELETE" {
                deleted.add(url)
                return (200, Data(), [:])
            }
            if url.contains("/collections") {
                return (200, Data(#"{"items":[{"guid":"c","name":"C"}]}"#.utf8), [:])
            }
            if request.httpMethod == "GET" {
                return (200, Data(#"{"status":4,"collectionId":"c"}"#.utf8), [:])
            }
            return (200, Data("{\"guid\":\"\(UUID().uuidString)\"}".utf8), [:])
        }
    }

    private var options: FaultTest.Options {
        var options = FaultTest.Options()
        options.fileSize = 16 * 1024 * 1024
        options.partCount = 2
        options.retryDelays = [0, 0, 0, 0, 0, 0]
        options.faults = FaultInjectingURLProtocol.Faults(dropBeforeSend: 0.1, dropAfterSend: 0.1, serviceUnavailable: 0.1)
        options.processingWait = 1
        options.processingPollInterval = 0.01
        return options
    }

    func testPassesWithInjectedFaults() async {
        let fake = M2ReliabilityTests.FakeTUS()
        let deleted = Lines()
        install(fake, deleted: deleted)
        // One of each fault early on, then clean requests.
        let dice = Dice([0.05, 0.9, 0.15, 0.9, 0.25, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9, 0.9])
        FaultInjectingURLProtocol.state.setRandom { dice.next() }
        let lines = Lines()

        let passed = await FaultTest.run(
            credentials: Credentials(apiKey: "k", libraryId: "1"),
            options: options,
            apiSession: MockURLProtocol.makeSession(),
            log: { lines.add($0) }
        )

        XCTAssertTrue(passed, lines.all.joined(separator: "\n"))
        XCTAssertEqual(deleted.all.count, 2)
        XCTAssertTrue(lines.all.contains("api check: no --video given, skipping the processing check"))
        XCTAssertEqual(lines.all.last, "PASS")
        XCTAssertTrue(lines.all.contains { $0.hasPrefix("re-upload check: second upload") })
    }

    func testProcessingCheckWithRealVideo() async {
        let fake = M2ReliabilityTests.FakeTUS()
        let deleted = Lines()
        install(fake, deleted: deleted)
        let dice = Dice([0.05, 0.9, 0.9, 0.9])
        FaultInjectingURLProtocol.state.setRandom { dice.next() }
        let video = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        FileManager.default.createFile(atPath: video.path, contents: Data(repeating: 1, count: 4096))
        defer { try? FileManager.default.removeItem(at: video) }
        var options = self.options
        options.realVideo = video
        let lines = Lines()
        let passed = await FaultTest.run(
            credentials: Credentials(apiKey: "k", libraryId: "1"),
            options: options,
            apiSession: MockURLProtocol.makeSession(),
            log: { lines.add($0) }
        )
        XCTAssertTrue(passed, lines.all.joined(separator: "\n"))
        XCTAssertEqual(deleted.all.count, 3)
        XCTAssertTrue(lines.all.contains { $0.contains("maps to ready; collection c (asked for c)") }, lines.all.joined(separator: "\n"))
    }

    func testFailsWhenNoFaultIsInjected() async {
        let fake = M2ReliabilityTests.FakeTUS()
        let deleted = Lines()
        install(fake, deleted: deleted)
        FaultInjectingURLProtocol.state.setRandom { 0.99 }
        let lines = Lines()

        let passed = await FaultTest.run(
            credentials: Credentials(apiKey: "k", libraryId: "1"),
            options: options,
            apiSession: MockURLProtocol.makeSession(),
            log: { lines.add($0) }
        )

        XCTAssertFalse(passed)
        XCTAssertTrue(lines.all.contains { $0.contains("no fault was injected") })
        XCTAssertEqual(deleted.all.count, 2)
    }

    func testFailsWhenVideoCannotBeCreated() async {
        MockURLProtocol.handler = { _ in (401, Data("no".utf8), [:]) }
        let lines = Lines()
        let passed = await FaultTest.run(
            credentials: Credentials(apiKey: "k", libraryId: "1"),
            options: options,
            apiSession: MockURLProtocol.makeSession(),
            log: { lines.add($0) }
        )
        XCTAssertFalse(passed)
        XCTAssertEqual(lines.all.last, "FAIL")
    }

    func testDescribeAndServiceUnavailable() async throws {
        XCTAssertEqual(
            FaultTest.describe([.dropAfterSend: 2]),
            "dropBeforeSend=0 dropAfterSend=2 serviceUnavailable=0"
        )
        FaultInjectingURLProtocol.state.faults = FaultInjectingURLProtocol.Faults(serviceUnavailable: 1)
        FaultInjectingURLProtocol.state.reset()
        let session = URLSession(configuration: FaultInjectingURLProtocol.configuration())
        let (_, response) = try await session.data(from: URL(string: "https://video.bunnycdn.com/tusupload/x")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual(FaultInjectingURLProtocol.state.injected[.serviceUnavailable], 1)
    }
}
