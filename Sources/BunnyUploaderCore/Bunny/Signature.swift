import Foundation
import CryptoKit

/// Presigned signature for a Bunny TUS upload.
/// `SHA256(libraryId + apiKey + expirationTime + videoId)`.
public enum Signature {
    public struct Signed: Equatable {
        public let value: String
        /// Expiration as a UNIX timestamp in seconds (string), the form Bunny expects.
        public let expiration: String
    }

    /// Generates a signature expiring `validFor` seconds from now (default 24 h).
    public static func make(
        libraryId: String,
        apiKey: String,
        videoId: String,
        validFor: TimeInterval = 24 * 60 * 60,
        now: Date = Date()
    ) -> Signed {
        let expiration = Int((now.timeIntervalSince1970 + validFor).rounded())
        let raw = "\(libraryId)\(apiKey)\(expiration)\(videoId)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Signed(value: hex, expiration: String(expiration))
    }
}
