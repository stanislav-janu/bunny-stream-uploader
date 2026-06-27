import XCTest
import CryptoKit
@testable import BunnyUploaderCore

private func sha256Hex(_ s: String) -> String {
    SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
}

final class SignatureTests: XCTestCase {
    func testDeterministicSignatureAndExpiration() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let signed = Signature.make(
            libraryId: "123",
            apiKey: "secret",
            videoId: "vid",
            validFor: 3600,
            now: now
        )
        // expiration = now + validFor
        XCTAssertEqual(signed.expiration, "1003600")
        // SHA256 hex is 64 chars
        XCTAssertEqual(signed.value.count, 64)
        // Deterministic for the same inputs
        let again = Signature.make(libraryId: "123", apiKey: "secret", videoId: "vid", validFor: 3600, now: now)
        XCTAssertEqual(signed, again)
    }

    func testKnownHash() {
        // SHA256("123secret1003600vid")
        let now = Date(timeIntervalSince1970: 1_000_000)
        let signed = Signature.make(libraryId: "123", apiKey: "secret", videoId: "vid", validFor: 3600, now: now)
        let expected = sha256Hex("123secret1003600vid")
        XCTAssertEqual(signed.value, expected)
    }

    func testDifferentInputsDiffer() {
        let now = Date(timeIntervalSince1970: 0)
        let a = Signature.make(libraryId: "a", apiKey: "k", videoId: "v", now: now)
        let b = Signature.make(libraryId: "b", apiKey: "k", videoId: "v", now: now)
        XCTAssertNotEqual(a.value, b.value)
    }
}

final class PartSplittingTests: XCTestCase {
    func testEvenSplit() {
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: 1000, partCount: 4)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts.map { $0.length }.reduce(0, +), 1000)
        XCTAssertEqual(parts[0].offset, 0)
        XCTAssertEqual(parts[1].offset, 250)
        // Offsets are contiguous
        for i in 1..<parts.count {
            XCTAssertEqual(parts[i].offset, parts[i - 1].offset + parts[i - 1].length)
        }
    }

    func testRemainderGoesToLastPart() {
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: 1003, partCount: 4)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts.map { $0.length }.reduce(0, +), 1003)
        XCTAssertEqual(parts.last?.length, 253) // 250 + remainder 3
    }

    func testSinglePart() {
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: 500, partCount: 1)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].offset, 0)
        XCTAssertEqual(parts[0].length, 500)
    }

    func testPartCountLargerThanSize() {
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: 3, partCount: 8)
        // base = 0, so early parts would be empty and are dropped; remainder lands in one part
        XCTAssertEqual(parts.map { $0.length }.reduce(0, +), 3)
        XCTAssertTrue(parts.allSatisfy { $0.length > 0 })
    }

    func testZeroPartCountTreatedAsOne() {
        let parts = ParallelTUSUploader.splitIntoParts(fileSize: 100, partCount: 0)
        XCTAssertEqual(parts.count, 1)
        XCTAssertEqual(parts[0].length, 100)
    }
}

final class MetadataEncodingTests: XCTestCase {
    func testEncodeMetadata() {
        let encoded = ParallelTUSUploader.encodeMetadata(["title": "My Video"])
        // "My Video" base64
        XCTAssertEqual(encoded, "title TXkgVmlkZW8=")
    }

    func testEncodeEmptyMetadataIsNil() {
        XCTAssertNil(ParallelTUSUploader.encodeMetadata([:]))
    }

    func testEncodeMultipleKeys() {
        let encoded = ParallelTUSUploader.encodeMetadata(["title": "a", "filetype": "video/mp4"])
        // Order is not guaranteed; check both pairs present, comma-separated
        XCTAssertTrue(encoded!.contains("title YQ=="))
        XCTAssertTrue(encoded!.contains("filetype dmlkZW8vbXA0"))
        XCTAssertTrue(encoded!.contains(","))
    }
}

final class UploadStateTests: XCTestCase {
    func testLabels() {
        XCTAssertFalse(UploadState.idle.label.isEmpty)
        XCTAssertFalse(UploadState.creatingVideo.label.isEmpty)
        XCTAssertFalse(UploadState.uploading.label.isEmpty)
        XCTAssertFalse(UploadState.processing.label.isEmpty)
        XCTAssertFalse(UploadState.done.label.isEmpty)
        XCTAssertFalse(UploadState.cancelled.label.isEmpty)
        XCTAssertTrue(UploadState.error("boom").label.contains("boom"))
    }

    func testIsTerminal() {
        XCTAssertTrue(UploadState.done.isTerminal)
        XCTAssertTrue(UploadState.cancelled.isTerminal)
        XCTAssertTrue(UploadState.error("x").isTerminal)
        XCTAssertFalse(UploadState.idle.isTerminal)
        XCTAssertFalse(UploadState.uploading.isTerminal)
        XCTAssertFalse(UploadState.creatingVideo.isTerminal)
        XCTAssertFalse(UploadState.processing.isTerminal)
    }

    func testIsActive() {
        XCTAssertTrue(UploadState.creatingVideo.isActive)
        XCTAssertTrue(UploadState.uploading.isActive)
        XCTAssertFalse(UploadState.idle.isActive)
        XCTAssertFalse(UploadState.done.isActive)
        XCTAssertFalse(UploadState.processing.isActive)
        XCTAssertFalse(UploadState.cancelled.isActive)
    }
}

final class CredentialsTests: XCTestCase {
    func testIsComplete() {
        XCTAssertTrue(Credentials(apiKey: "k", libraryId: "1").isComplete)
        XCTAssertFalse(Credentials(apiKey: "", libraryId: "1").isComplete)
        XCTAssertFalse(Credentials(apiKey: "k", libraryId: "").isComplete)
        XCTAssertFalse(Credentials(apiKey: "", libraryId: "").isComplete)
    }
}

@MainActor
final class UploadItemTests: XCTestCase {
    func testProgress() {
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/x.mp4"), fileName: "x.mp4", fileSize: 100, mimeType: "video/mp4")
        XCTAssertEqual(item.progress, 0)
        item.bytesUploaded = 50
        XCTAssertEqual(item.progress, 0.5)
        item.bytesUploaded = 200 // clamped to 1
        XCTAssertEqual(item.progress, 1)
    }

    func testProgressZeroSize() {
        let item = UploadItem(fileURL: URL(fileURLWithPath: "/tmp/x"), fileName: "x", fileSize: 0, mimeType: "")
        XCTAssertEqual(item.progress, 0)
    }
}

@MainActor
final class AutoPartCountTests: XCTestCase {
    let mb: Int64 = 1024 * 1024
    let gb: Int64 = 1024 * 1024 * 1024

    func testAutoPartCountThresholds() {
        XCTAssertEqual(UploadEngine.autoPartCount(for: 2 * gb), 64)
        XCTAssertEqual(UploadEngine.autoPartCount(for: gb), 64)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 700 * mb), 32)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 500 * mb), 32)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 200 * mb), 16)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 100 * mb), 16)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 60 * mb), 8)
        XCTAssertEqual(UploadEngine.autoPartCount(for: 1 * mb), 8)
    }

    func testThreadCountAutoVsManual() {
        let engine = UploadEngine(credentials: Credentials(apiKey: "k", libraryId: "1"))
        engine.autoThreads = true
        XCTAssertEqual(engine.threadCount(for: 2 * gb), 64)
        engine.autoThreads = false
        engine.partCount = 12
        XCTAssertEqual(engine.threadCount(for: 2 * gb), 12)
    }
}
