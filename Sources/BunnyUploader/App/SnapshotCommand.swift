import AppKit
import SwiftUI
import BunnyUploaderCore

/// `--snapshot <folder>`: renders the main window (with sample uploads and empty)
/// and Settings in light and dark mode to PNG files, then quits. Uses sample data
/// only: no Keychain, no saved list, no network.
enum SnapshotCommand {
    static func runAndExit(folder: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var failed = false
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let pages: [(String, AnyView, CGSize)] = [
                    ("main", AnyView(mainPage(engine: sampleEngine())), CGSize(width: 640, height: 1060)),
                    ("empty", AnyView(mainPage(engine: emptyEngine())), CGSize(width: 640, height: 480)),
                    ("settings", AnyView(SettingsView().environmentObject(emptyEngine())), CGSize(width: Layout.settingsWidth, height: 560)),
                ]
                for (page, view, size) in pages {
                    let file = output.appendingPathComponent("\(page)-\(name).png")
                    if await render(view, size: size, appearance: appearance, to: file) {
                        print(file.path)
                    } else {
                        print("FAILED \(file.path)")
                        failed = true
                    }
                }
            }
            exit(failed ? 1 : 0)
        }
        RunLoop.main.run()
        exit(1)
    }

    @MainActor
    private static func mainPage(engine: UploadEngine) -> some View {
        ContentView()
            .environmentObject(engine)
    }

    /// Draws the view in an offscreen window, so AppKit-backed controls render too.
    @MainActor
    private static func render(_ view: AnyView, size: CGSize, appearance: NSAppearance.Name, to file: URL) async -> Bool {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(.background))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.layoutIfNeeded()
        // Let SwiftUI finish its first layout pass before drawing.
        try? await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return false }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        window.close()
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return false }
        return (try? data.write(to: file)) != nil
    }

    @MainActor
    private static func emptyEngine() -> UploadEngine {
        return UploadEngine(credentials: Credentials(apiKey: "", libraryId: ""))
    }

    /// One row per state the list can show.
    @MainActor
    private static func sampleEngine() -> UploadEngine {
        let engine = UploadEngine(credentials: Credentials(apiKey: "sample", libraryId: "100000"))
        let now = Date()
        let gib: Int64 = 1_073_741_824

        let uploading = item("Conference keynote.mp4", size: 2 * gib + gib / 2)
        uploading.state = .uploading
        uploading.bytesUploaded = uploading.fileSize * 62 / 100
        uploading.throughputMBps = 48.3
        uploading.videoId = "3f2a9c1e-7b4d-4e8a-9c21-5d6e7f8a9b0c"

        let waiting = item("Interview B-roll.mov", size: 740 * 1_048_576)

        let processing = item("Product demo.mp4", size: 1 * gib)
        processing.state = .done
        processing.bytesUploaded = processing.fileSize
        processing.videoId = "a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"
        processing.libraryId = "100000"
        processing.finishedAt = now.addingTimeInterval(-120)

        let ready = item("Team update.m4v", size: 320 * 1_048_576)
        ready.state = .done
        ready.bytesUploaded = ready.fileSize
        ready.videoId = "9e8d7c6b-5a4f-4e3d-2c1b-0a9f8e7d6c5b"
        ready.libraryId = "100000"
        ready.processing = .ready
        ready.finishedAt = now.addingTimeInterval(-3600)

        let failed = item("Workshop recording.mkv", size: 4 * gib)
        failed.state = .error("Final merge failed (HTTP 400): Could not find some of the files supplied for concatenation")
        failed.bytesUploaded = failed.fileSize
        failed.videoId = "0c9b8a7f-6e5d-4c4b-3a2f-1e0d9c8b7a6f"
        failed.finishedAt = now.addingTimeInterval(-7200)

        let cancelled = item("Old teaser.webm", size: 90 * 1_048_576)
        cancelled.state = .cancelled
        cancelled.bytesUploaded = cancelled.fileSize / 4
        cancelled.finishedAt = now.addingTimeInterval(-9000)

        engine.reinsert([uploading, waiting, processing, ready, failed, cancelled])
        // The processing row only shows its label; no status check runs here.
        processing.processing = .processing
        return engine
    }

    @MainActor
    private static func item(_ name: String, size: Int64) -> UploadItem {
        let url = URL(fileURLWithPath: "/tmp/snapshot-samples").appendingPathComponent(name)
        return UploadItem(fileURL: url, fileName: name, fileSize: size, mimeType: "video/mp4")
    }
}
