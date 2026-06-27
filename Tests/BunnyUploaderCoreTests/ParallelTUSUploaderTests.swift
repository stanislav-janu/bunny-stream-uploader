import XCTest
@testable import BunnyUploaderCore

final class ParallelTUSUploaderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    private func makeTempFile(size: Int) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".bin")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0x41, count: size))
        return url
    }

    /// Default happy-path handler: partial -> 201 + Location, PATCH -> 204, final -> 200.
    private func installHappyHandler() {
        MockURLProtocol.handler = { request in
            let concat = request.value(forHTTPHeaderField: "Upload-Concat") ?? ""
            if request.httpMethod == "POST", concat == "partial" {
                let loc = "https://video.bunnycdn.com/tusupload/\(UUID().uuidString)"
                return (201, Data(), ["Location": loc])
            }
            if request.httpMethod == "PATCH" {
                return (204, Data(), [:])
            }
            if request.httpMethod == "POST", concat.hasPrefix("final") {
                return (200, Data(), [:])
            }
            return (400, Data("unexpected".utf8), [:])
        }
    }

    func testUploadSuccess() async throws {
        let fileURL = makeTempFile(size: 2000)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        installHappyHandler()

        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration())
        let progress = ProgressBox()
        let result = try await uploader.upload(
            fileURL: fileURL,
            fileSize: 2000,
            partCount: 4,
            authHeaders: ["VideoId": "v", "LibraryId": "1"],
            metadata: ["title": "t", "filetype": "video/mp4"],
            onProgress: { progress.set($0) }
        )
        XCTAssertEqual(result.bytesUploaded, 2000)
        XCTAssertEqual(progress.value, 2000)
    }

    func testPartialCreateFailure() async {
        let fileURL = makeTempFile(size: 500)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        MockURLProtocol.handler = { _ in (403, Data("forbidden".utf8), [:]) }

        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration())
        do {
            _ = try await uploader.upload(fileURL: fileURL, fileSize: 500, partCount: 2, authHeaders: [:], metadata: [:], onProgress: { _ in })
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            if case .partialCreateFailed(let code, _) = error {
                XCTAssertEqual(code, 403)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testMissingLocation() async {
        let fileURL = makeTempFile(size: 500)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        MockURLProtocol.handler = { _ in (201, Data(), [:]) } // 201 but no Location

        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration())
        do {
            _ = try await uploader.upload(fileURL: fileURL, fileSize: 500, partCount: 1, authHeaders: [:], metadata: [:], onProgress: { _ in })
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            XCTAssertEqual(error, .missingLocation)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testOpenFailureForMissingFile() async {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).bin")
        installHappyHandler()
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration())
        do {
            _ = try await uploader.upload(fileURL: missing, fileSize: 100, partCount: 1, authHeaders: [:], metadata: [:], onProgress: { _ in })
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            if case .open = error {
                // expected
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testPatchFailure() async {
        let fileURL = makeTempFile(size: 500)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        MockURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                return (201, Data(), ["Location": "https://video.bunnycdn.com/tusupload/x"])
            }
            return (409, Data("conflict".utf8), [:]) // PATCH fails
        }
        let uploader = ParallelTUSUploader(sessionConfiguration: MockURLProtocol.makeConfiguration())
        do {
            _ = try await uploader.upload(fileURL: fileURL, fileSize: 500, partCount: 1, authHeaders: [:], metadata: [:], onProgress: { _ in })
            XCTFail("Expected failure")
        } catch let error as ParallelTUSUploader.UploadError {
            if case .patchFailed(let code, _) = error {
                XCTAssertEqual(code, 409)
            } else {
                XCTFail("Wrong error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }

    func testErrorMessages() {
        XCTAssertNotNil(ParallelTUSUploader.UploadError.open("/p").errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.read(2).errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.partialCreateFailed(1, "x").errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.patchFailed(1, "x").errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.finalFailed(1, "x").errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.missingLocation.errorDescription)
        XCTAssertNotNil(ParallelTUSUploader.UploadError.cancelled.errorDescription)
    }
}

/// Thread-safe box for capturing progress from a @Sendable closure.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Int64 = 0
    var value: Int64 {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: Int64) {
        lock.lock(); _value = max(_value, v); lock.unlock()
    }
}
