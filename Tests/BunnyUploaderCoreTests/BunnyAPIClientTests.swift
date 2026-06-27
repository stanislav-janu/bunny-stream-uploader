import XCTest
@testable import BunnyUploaderCore

final class BunnyAPIClientTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> BunnyAPIClient {
        BunnyAPIClient(
            credentials: Credentials(apiKey: "key", libraryId: "42"),
            session: MockURLProtocol.makeSession()
        )
    }

    func testCreateVideoSuccess() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "AccessKey"), "key")
            XCTAssertTrue(request.url!.absoluteString.contains("/library/42/videos"))
            return (200, Data(#"{"guid":"abc-123"}"#.utf8), ["Content-Type": "application/json"])
        }
        let guid = try await makeClient().createVideo(title: "My Video")
        XCTAssertEqual(guid, "abc-123")
    }

    func testCreateVideoMissingGuid() async {
        MockURLProtocol.handler = { _ in (200, Data("{}".utf8), [:]) }
        await assertThrowsAPIError(.missingGuid) { try await self.makeClient().createVideo(title: "t") }
    }

    func testCreateVideoEmptyGuid() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"guid":""}"#.utf8), [:]) }
        await assertThrowsAPIError(.missingGuid) { try await self.makeClient().createVideo(title: "t") }
    }

    func testCreateVideoHTTPError() async {
        MockURLProtocol.handler = { _ in (500, Data("server error".utf8), [:]) }
        await assertThrowsAPIError(.http(500, "server error")) { try await self.makeClient().createVideo(title: "t") }
    }

    func testCreateVideoDecodingError() async {
        MockURLProtocol.handler = { _ in (200, Data("not json".utf8), [:]) }
        await assertThrowsAPIError(.decoding) { try await self.makeClient().createVideo(title: "t") }
    }

    func testGetVideoStatusSuccess() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.url!.absoluteString.contains("/library/42/videos/guid-9"))
            return (200, Data(#"{"status":4}"#.utf8), [:])
        }
        let status = try await makeClient().getVideoStatus(guid: "guid-9")
        XCTAssertEqual(status, 4)
    }

    func testGetVideoStatusDecodingError() async {
        MockURLProtocol.handler = { _ in (200, Data(#"{"foo":1}"#.utf8), [:]) }
        await assertThrowsAPIError(.decoding) { try await self.makeClient().getVideoStatus(guid: "g") }
    }

    func testAPIErrorMessages() {
        XCTAssertNotNil(BunnyAPIClient.APIError.http(404, "x").errorDescription)
        XCTAssertNotNil(BunnyAPIClient.APIError.decoding.errorDescription)
        XCTAssertNotNil(BunnyAPIClient.APIError.missingGuid.errorDescription)
    }

    // MARK: - Helper

    private func assertThrowsAPIError<T>(
        _ expected: BunnyAPIClient.APIError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ block: () async throws -> T
    ) async {
        do {
            _ = try await block()
            XCTFail("Expected error \(expected)", file: file, line: line)
        } catch let error as BunnyAPIClient.APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
