import SwiftUI
import AppKit

/// Receives files from Finder two ways and adds them to the upload queue:
/// 1. Open with → BunnyUploader (`application(_:open:)`)
/// 2. Quick Action / Service "Upload to Bunny" (`uploadToBunny` via NSServices)
/// Buffers early-launch URLs until the UI is ready.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpen: (([URL]) -> Void)?
    private var buffered: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the service provider for the Quick Action in Finder's context menu.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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

    private static func isAcceptedVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "mp4" || ext == "mov" || ext == "m4v"
    }
}

@main
struct BunnyUploaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = UploadEngine()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .frame(minWidth: 560, minHeight: 420)
                .onAppear {
                    appDelegate.onOpen = { urls in
                        for url in urls {
                            engine.addFile(url)
                        }
                    }
                    appDelegate.flushPending()
                }
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environmentObject(engine)
        }
    }
}
