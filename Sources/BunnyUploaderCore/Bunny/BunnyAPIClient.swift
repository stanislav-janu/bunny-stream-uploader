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
        return "https://player.mediadelivery.net/embed/\(libraryId)/\(videoId)"
    }

    /// Bunny's own play page for a video.
    public static func playLink(libraryId: String, videoId: String) -> String {
        return "https://player.mediadelivery.net/play/\(libraryId)/\(videoId)"
    }

    /// A collection in the library.
    public struct Collection: Equatable, Sendable, Identifiable {
        public let id: String
        public let name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// The library's collections, sorted by name (`GET /library/{libraryId}/collections`).
    public func listCollections() async throws -> [Collection] {
        var components = URLComponents(url: baseURL.appendingPathComponent("collections"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "itemsPerPage", value: "1000"),
            URLQueryItem(name: "orderBy", value: "title"),
        ]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decoding
        }
        let items = object["items"] as? [[String: Any]] ?? []
        return items
            .compactMap { item -> Collection? in
                guard let guid = item["guid"] as? String, !guid.isEmpty else { return nil }
                return Collection(id: guid, name: item["name"] as? String ?? guid)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Creates a video object and returns its guid (videoId).
    /// `POST /library/{libraryId}/videos` with the `AccessKey` header.
    public func createVideo(title: String, collectionId: String? = nil) async throws -> String {
        let url = baseURL.appendingPathComponent("videos")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var body = ["title": title]
        if let collectionId, !collectionId.isEmpty {
            body["collectionId"] = collectionId
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

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

    /// The newest videos in the library as raw JSON objects (diagnostics only).
    public func listRecentVideos(count: Int = 10) async throws -> [[String: Any]] {
        var components = URLComponents(url: baseURL.appendingPathComponent("videos"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "page", value: "1"),
            URLQueryItem(name: "itemsPerPage", value: String(count)),
            URLQueryItem(name: "orderBy", value: "date"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw APIError.decoding
        }
        return object["items"] as? [[String: Any]] ?? []
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

    /// What Bunny's video `status` means for the person: 4 (Finished) plays,
    /// 5 (Error) and 6 (UploadFailed) failed, everything else is still processing.
    public static func processing(forStatus status: Int) -> BunnyProcessing {
        switch status {
        case 4: return .ready
        case 5, 6: return .failed
        default: return .processing
        }
    }

    /// Video status (e.g. to track transcoding after the upload completes).
    /// Returns Bunny's `status` code: 0 Created, 1 Uploaded, 2 Processing, 3 Transcoding,
    /// 4 Finished, 5 Error, 6 UploadFailed, 7 JitSegmenting, 8 JitPlaylistsCreated.
    public func getVideoStatus(guid: String) async throws -> Int {
        return try await getVideoInfo(guid: guid).status
    }

    /// Status and collection of a video (`GET /library/{libraryId}/videos/{guid}`).
    public func getVideoInfo(guid: String) async throws -> (status: Int, collectionId: String?) {
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
        let collectionId = (object["collectionId"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (status, collectionId)
    }

    /// Status and stored bytes of a video (diagnostics).
    public func getVideoStorage(guid: String) async throws -> (status: Int, storageSize: Int64) {
        let url = baseURL.appendingPathComponent("videos").appendingPathComponent(guid)
        var request = URLRequest(url: url)
        request.setValue(credentials.apiKey, forHTTPHeaderField: "AccessKey")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data: data)
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let status = object["status"] as? Int
        else {
            throw APIError.decoding
        }
        let size = (object["storageSize"] as? NSNumber)?.int64Value ?? 0
        return (status, size)
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
