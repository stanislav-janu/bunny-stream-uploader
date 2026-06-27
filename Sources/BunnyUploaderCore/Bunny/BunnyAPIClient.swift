import Foundation

/// Thin layer over the Bunny Stream REST API. No extra logic.
public struct BunnyAPIClient {
    let credentials: Credentials
    var session: URLSession

    public init(credentials: Credentials, session: URLSession = .shared) {
        self.credentials = credentials
        self.session = session
    }

    private var baseURL: URL {
        return URL(string: "https://video.bunnycdn.com/library/\(credentials.libraryId)")!
    }

    public enum APIError: LocalizedError, Equatable {
        case http(Int, String)
        case decoding
        case missingGuid

        public var errorDescription: String? {
            switch self {
            case .http(let code, let body): return "HTTP \(code): \(body)"
            case .decoding: return String(localized: "Unexpected server response")
            case .missingGuid: return String(localized: "Bunny did not return a videoId (guid)")
            }
        }
    }

    /// Creates a video object and returns its guid (videoId).
    /// `POST /library/{libraryId}/videos` with the `AccessKey` header.
    public func createVideo(title: String) async throws -> String {
        let url = baseURL.appendingPathComponent("videos")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["title": title])

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decoding
        }
        guard let guid = object["guid"] as? String, !guid.isEmpty else {
            throw APIError.missingGuid
        }
        return guid
    }

    /// Video status (e.g. to track transcoding after the upload completes).
    /// Returns Bunny's `status` code (0 = created, 3/4 = processing, 4 = ready ...).
    public func getVideoStatus(guid: String) async throws -> Int {
        let url = baseURL.appendingPathComponent("videos").appendingPathComponent(guid)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? Int
        else {
            throw APIError.decoding
        }
        return status
    }

    private static func validate(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.decoding
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, body)
        }
    }
}
