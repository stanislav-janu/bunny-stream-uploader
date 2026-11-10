import AppKit
import UniformTypeIdentifiers

/// Open panel for choosing videos (File > Open… and "Choose Videos…").
enum VideoPicker {
    /// Content types of the video containers the app accepts.
    static var allowedTypes: [UTType] {
        AppDelegate.acceptedExtensions
            .compactMap { UTType(filenameExtension: $0) }
            .sorted { $0.identifier < $1.identifier }
    }

    /// Shows the panel and hands the chosen files to `onChoose`.
    @MainActor
    static func choose(_ onChoose: @escaping ([URL]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Videos")
        panel.prompt = String(localized: "Upload")
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = allowedTypes
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window) { response in
                if response == .OK {
                    onChoose(panel.urls)
                }
            }
        } else if panel.runModal() == .OK {
            onChoose(panel.urls)
        }
    }
}
