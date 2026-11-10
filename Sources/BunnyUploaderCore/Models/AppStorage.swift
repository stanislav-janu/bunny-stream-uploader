import Foundation

/// Names of the app's own storage, derived from the bundle id so a test build
/// (another `BUNNY_BUNDLE_ID`) keeps its own Keychain item and files. The main app
/// keeps the names it always had.
public enum AppStorage {
    public static let mainBundleId = "net.bunnyuploader.BunnyUploader"

    /// Service name of the Keychain item.
    public static func keychainService(bundleId: String? = Bundle.main.bundleIdentifier) -> String {
        return bundleId ?? mainBundleId
    }

    /// Folder name inside Application Support.
    public static func supportFolderName(bundleId: String? = Bundle.main.bundleIdentifier) -> String {
        guard let bundleId, bundleId != mainBundleId else { return "BunnyUploader" }
        return bundleId
    }

    /// `~/Library/Application Support/<folder>`, created when missing.
    public static func supportDirectory(bundleId: String? = Bundle.main.bundleIdentifier) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(supportFolderName(bundleId: bundleId), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
