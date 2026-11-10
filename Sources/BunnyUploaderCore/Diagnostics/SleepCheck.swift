import Foundation

/// Real check of sleep prevention (S-011): uploads a zero-filled test file with the real
/// engine, reads `pmset -g assertions` while it runs and after it ends, and deletes the
/// test video. Run with `BunnyUploader --sleep-check`.
@MainActor
public enum SleepCheck {
    public static func run(sizeMB: Int = 96, log: @escaping (String) -> Void) async -> Bool {
        let credentials = KeychainStore.load()
        guard credentials.isComplete else {
            log("no credentials saved in Settings")
            return false
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Bunny Uploader sleep check \(UUID().uuidString).mp4")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        if let handle = try? FileHandle(forWritingTo: file) {
            try? handle.truncate(atOffset: UInt64(sizeMB) * 1024 * 1024)
            try? handle.close()
        }
        defer { try? FileManager.default.removeItem(at: file) }

        let engine = UploadEngine(credentials: credentials)
        engine.addFile(file)
        let item = engine.items[0]
        let pid = ProcessInfo.processInfo.processIdentifier

        var heldWhileUploading = false
        let start = Date()
        while !item.state.isTerminal, Date().timeIntervalSince(start) < 600 {
            if item.state == .uploading, !heldWhileUploading {
                heldWhileUploading = holdsSleepAssertion(pid: pid)
                log("while uploading: engine says \(engine.isPreventingSleep), pmset shows the assertion: \(heldWhileUploading)")
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        // Let the engine settle after the state change.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let heldAfter = holdsSleepAssertion(pid: pid)
        log("after the upload (\(item.state.label)): engine says \(engine.isPreventingSleep), pmset shows the assertion: \(heldAfter)")

        if let videoId = item.videoId {
            do {
                try await BunnyAPIClient(credentials: credentials).deleteVideo(guid: videoId)
                log("deleted test video \(videoId)")
            } catch {
                log("WARN could not delete test video \(videoId): \(error.localizedDescription)")
            }
        }
        let passed = heldWhileUploading && !heldAfter && item.state == .done
        log(passed ? "PASS" : "FAIL")
        return passed
    }

    /// Whether `pmset -g assertions` lists a PreventUserIdleSystemSleep assertion of this process.
    static func holdsSleepAssertion(pid: Int32) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "assertions"]
        let pipe = Pipe()
        process.standardOutput = pipe
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return assertionHeld(in: String(data: data, encoding: .utf8) ?? "", pid: pid)
    }

    /// Whether `pmset -g assertions` output lists a PreventUserIdleSystemSleep assertion of `pid`.
    nonisolated static func assertionHeld(in output: String, pid: Int32) -> Bool {
        return output
            .split(separator: "\n")
            .contains { $0.contains("pid \(pid)(") && $0.contains("PreventUserIdleSystemSleep") }
    }
}
