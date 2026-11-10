import Foundation

/// Saves the upload list to a JSON file so it survives a restart.
public struct UploadHistoryStore: Sendable {
    /// One saved row.
    public struct Record: Codable, Equatable, Sendable {
        public var id: UUID
        public var filePath: String
        public var fileName: String
        public var fileSize: Int64
        public var mimeType: String
        public var state: UploadState
        public var bytesUploaded: Int64
        public var videoId: String?
        public var libraryId: String?
        public var finishedAt: Date?
        public var resume: ResumeState?
        public var processing: BunnyProcessing?
    }

    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// `~/Library/Application Support/BunnyUploader/uploads.json`.
    public static func standard() -> UploadHistoryStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = base
            .appendingPathComponent("BunnyUploader", isDirectory: true)
            .appendingPathComponent("uploads.json")
        return UploadHistoryStore(fileURL: url)
    }

    public func load() -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([Record].self, from: data)) ?? []
    }

    public func save(_ records: [Record]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(records) else { return }
        let directory = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

@MainActor
extension UploadItem {
    /// The saved form of this row.
    var record: UploadHistoryStore.Record {
        return UploadHistoryStore.Record(
            id: id,
            filePath: fileURL.path,
            fileName: fileName,
            fileSize: fileSize,
            mimeType: mimeType,
            state: state,
            bytesUploaded: bytesUploaded,
            videoId: videoId,
            libraryId: libraryId,
            finishedAt: finishedAt,
            resume: resume,
            processing: processing
        )
    }

    /// A row loaded after a restart, with running states turned into `interrupted`.
    convenience init(restoring record: UploadHistoryStore.Record) {
        self.init(
            id: record.id,
            fileURL: URL(fileURLWithPath: record.filePath),
            fileName: record.fileName,
            fileSize: record.fileSize,
            mimeType: record.mimeType
        )
        state = record.state.restored
        bytesUploaded = state == .done ? record.fileSize : record.bytesUploaded
        videoId = record.videoId
        libraryId = record.libraryId
        finishedAt = record.finishedAt
        resume = record.resume
        processing = record.state == .processing ? .processing : record.processing
    }
}
