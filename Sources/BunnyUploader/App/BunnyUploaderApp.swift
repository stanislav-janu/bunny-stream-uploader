import SwiftUI
import AppKit
import BunnyUploaderCore

/// Receives files from Finder two ways and adds them to the upload queue:
/// 1. Open with → BunnyUploader (`application(_:open:)`)
/// 2. Quick Action / Service "Upload to Bunny" (`uploadToBunny` via NSServices)
/// Buffers early-launch URLs until the UI is ready.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?
    /// Number of running uploads, asked before quitting.
    var activeUploads: (() -> Int)?
    private var buffered: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-window utility: no window tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        // Register the service provider for the Quick Action in Finder's context menu.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        // Ask for notification permission so completed uploads can notify.
        Notifications.requestAuthorization()
    }

    /// Asks before quitting while uploads run. Quitting leaves them as they are (no Cancel),
    /// so their videos stay in Bunny and the rows load as Interrupted for Retry.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = activeUploads?() ?? 0
        guard running > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Quit while uploading?")
        alert.informativeText = String(localized: "Uploads still running: \(running). If you quit now, they stop and you can retry them after the next launch.")
        alert.addButton(withTitle: String(localized: "Keep Uploading"))
        alert.addButton(withTitle: String(localized: "Quit"))
        let response = alert.runModal()
        return response == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        handle(urls)
    }

    /// Service handler pro Quick Action "Upload do Bunny" (NSMessage v Info.plist).
    @objc func uploadToBunny(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>?) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self]) as? [URL]) ?? []
        handle(urls)
    }

    private func handle(_ urls: [URL]) {
        let videos = urls.filter { Self.isAcceptedVideo($0) }
        guard !videos.isEmpty else { return }
        NSApp.activate(ignoringOtherApps: true)
        if let onOpen {
            onOpen(videos)
        } else {
            buffered.append(contentsOf: videos)
        }
    }

    /// Call once the UI is ready; flushes files received at launch.
    func flushPending() {
        guard let onOpen, !buffered.isEmpty else { return }
        onOpen(buffered)
        buffered.removeAll()
    }

    /// Video container extensions Bunny Stream accepts for ingestion.
    static let acceptedExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "mpeg", "mpg",
    ]

    static func isAcceptedVideo(_ url: URL) -> Bool {
        return acceptedExtensions.contains(url.pathExtension.lowercased())
    }
}

@main
struct BunnyUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = UploadEngine(history: .standard())

    init() {
        if CommandLine.arguments.contains("--fault-test") {
            FaultTestCommand.runAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--delete-test-video"), index + 1 < CommandLine.arguments.count {
            FaultTestCommand.deleteAndExit(guid: CommandLine.arguments[index + 1])
        }
        if let index = CommandLine.arguments.firstIndex(of: "--video-status"), index + 1 < CommandLine.arguments.count {
            FaultTestCommand.statusAndExit(guid: CommandLine.arguments[index + 1])
        }
        if CommandLine.arguments.contains("--sleep-check") {
            FaultTestCommand.sleepCheckAndExit()
        }
        if CommandLine.arguments.contains("--final-probe") {
            FaultTestCommand.probeAndExit()
        }
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), index + 1 < CommandLine.arguments.count {
            SnapshotCommand.runAndExit(folder: CommandLine.arguments[index + 1])
        }
        if CommandLine.arguments.contains("--recent-videos") {
            FaultTestCommand.listRecentAndExit()
        }
    }

    var body: some Scene {
        Window("Bunny Stream Uploader", id: "main") {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: Layout.windowMinWidth, minHeight: Layout.windowMinHeight)
                .onAppear {
                    appDelegate.onOpen = { urls in
                        for url in urls {
                            engine.addFile(url)
                        }
                    }
                    appDelegate.flushPending()
                    appDelegate.activeUploads = { engine.uploadsBlockingQuit }
                    engine.resumeProcessingChecks()
                    // Wire UI side-effects the Core engine intentionally does not depend on.
                    engine.onUploadFinished = { item in
                        Notifications.uploadFinished(fileName: item.fileName)
                    }
                    engine.onUploadFailed = { item, message in
                        Notifications.uploadFailed(fileName: item.fileName, message: message)
                    }
                }
                .onChange(of: engine.aggregateProgress) { _, progress in
                    if engine.activeCount > 0 {
                        DockProgress.show(progress: progress)
                    } else {
                        DockProgress.clear()
                    }
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            UploadCommands(engine: engine)
        }

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}

/// `BunnyUploader --fault-test`: runs `FaultTest` against the saved library from the
/// terminal (no window), prints the report, and exits 0 on pass, 1 on fail.
enum FaultTestCommand {
    static func runAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            var options = FaultTest.Options()
            let arguments = CommandLine.arguments
            if let index = arguments.firstIndex(of: "--video"), index + 1 < arguments.count {
                options.realVideo = URL(fileURLWithPath: arguments[index + 1])
            }
            let passed = await FaultTest.runWithStoredCredentials(options: options) { line in
                print(line)
                fflush(stdout)
            }
            result.passed = passed
            done.signal()
        }
        done.wait()
        exit(result.passed ? 0 : 1)
    }

    /// `BunnyUploader --delete-test-video <guid>`: removes a leftover diagnostics video.
    static func deleteAndExit(guid: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            result.passed = await FaultTest.deleteTestVideo(guid: guid) { line in
                print(line)
                fflush(stdout)
            }
            done.signal()
        }
        done.wait()
        exit(result.passed ? 0 : 1)
    }

    /// `BunnyUploader --video-status <guid>`: prints status and stored bytes of one video.
    static func statusAndExit(guid: String) -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await FaultTest.printVideoStatus(guid: guid) { line in
                print(line)
                fflush(stdout)
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    /// `BunnyUploader --sleep-check`: uploads a test file with the real engine and checks
    /// the sleep assertion with pmset. Runs the main run loop, since the engine is main-actor.
    static func sleepCheckAndExit() -> Never {
        Task { @MainActor in
            let passed = await SleepCheck.run { line in
                print(line)
                fflush(stdout)
            }
            exit(passed ? 0 : 1)
        }
        RunLoop.main.run()
        exit(1)
    }

    /// `BunnyUploader --final-probe`: checks whether Bunny finishes a dropped final request.
    static func probeAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        let result = ResultBox()
        Task.detached {
            result.passed = await FaultTest.probeFinalDetach { line in
                print(line)
                fflush(stdout)
            }
            done.signal()
        }
        done.wait()
        exit(result.passed ? 0 : 1)
    }

    /// `BunnyUploader --recent-videos`: prints the newest videos with status and encode progress.
    static func listRecentAndExit() -> Never {
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            await FaultTest.printRecentVideos { line in
                print(line)
                fflush(stdout)
            }
            done.signal()
        }
        done.wait()
        exit(0)
    }

    private final class ResultBox: @unchecked Sendable {
        var passed = false
    }
}
