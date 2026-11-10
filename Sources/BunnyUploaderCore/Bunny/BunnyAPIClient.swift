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

    /// Why Bunny did not accept a Library ID and API key pair.
    public enum CredentialCheckError: Error, Equatable {
        /// HTTP 401 or 403: the key is wrong or belongs to another library.
        case keyRejected
        /// HTTP 404: no library with this ID.
        case libraryNotFound
        /// No response from Bunny (network error).
        case unreachable
        /// Any other HTTP status.
        case unexpected(Int)

        public var message: String {
            switch self {
            case .keyRejected:
                return String(localized: "Bunny rejected this API key. Copy the Stream API key from the library's API page.")
            case .libraryNotFound:
                return String(localized: "No library with this ID. Check the Library ID in the Bunny dashboard.")
            case .unreachable:
                return String(localized: "Unable to reach Bunny. Check your connection and try again.")
            case .unexpected(let code):
                return String(localized: "Bunny answered with HTTP \(code). Try again later.")
            }
        }
    }

    /// Checks the credentials with one cheap authenticated call
    /// (`GET /library/{libraryId}/videos?itemsPerPage=1`).
    public func checkCredentials() async throws(CredentialCheckError) {
        var components = URLComponents(url: baseURL.appendingPathComponent("videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "itemsPerPage", value: "1"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response: URLResponse
        do {
            (_, response) = try await session.data(for: request)
        } catch {
            throw .unreachable
        }
        guard let http = response as? HTTPURLResponse else {
            throw .unreachable
        }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw .keyRejected
        case 404:
            throw .libraryNotFound
        default:
            throw .unexpected(http.statusCode)
        }
    }

    /// Embed player link for a video in a library.
    public static func embedLink(libraryId: String, videoId: String) -> String {
        return "https://iframe.mediadelivery.net/embed/\(libraryId)/\(videoId)"
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

    /// Deletes a video (`DELETE /library/{libraryId}/videos/{guid}`).
    public func deleteVideo(guid: String) async throws {
        let url = baseURL.appendingPathComponent("videos").appendingPathComponent(guid)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
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
