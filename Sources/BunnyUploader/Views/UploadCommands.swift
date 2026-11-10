import SwiftUI
import BunnyUploaderCore

/// What the menu bar can do with the selected row, published by the main window.
struct UploadActions {
    var canCancel: Bool
    var canRetry: Bool
    var canCopyID: Bool
    var cancel: () -> Void
    var retry: () -> Void
    var copyID: () -> Void
    var clearFinished: () -> Void
}

extension FocusedValues {
    @Entry var uploadActions: UploadActions?
}

/// File > Open… and the Upload menu.
struct UploadCommands: Commands {
    @ObservedObject var engine: UploadEngine
    @FocusedValue(\.uploadActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open…") {
                VideoPicker.choose { urls in
                    for url in urls {
                        engine.addFile(url)
                    }
                }
            }
            .keyboardShortcut("o")
            .disabled(!engine.hasCredentials)
        }
        CommandMenu("Upload") {
            Button("Cancel") {
                actions?.cancel()
            }
            .keyboardShortcut(".")
            .disabled(!(actions?.canCancel ?? false))
            Button("Retry") {
                actions?.retry()
            }
            .keyboardShortcut("r")
            .disabled(!(actions?.canRetry ?? false))
            Button("Copy ID") {
                actions?.copyID()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(!(actions?.canCopyID ?? false))
            Divider()
            Button("Cancel All") {
                engine.cancelAll()
            }
            .disabled(!engine.hasRunningOrWaiting)
            Button("Clear Finished") {
                if let actions {
                    actions.clearFinished()
                } else {
                    engine.clearFinished()
                }
            }
            .disabled(!engine.hasFinished)
        }
    }
}
