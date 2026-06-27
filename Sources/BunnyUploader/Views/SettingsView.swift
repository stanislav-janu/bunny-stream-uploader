import SwiftUI
import BunnyUploaderCore

struct SettingsView: View {
    @EnvironmentObject private var engine: UploadEngine

    @State private var apiKey: String = ""
    @State private var libraryId: String = ""
    @State private var savedNote = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // MARK: Credentials
            VStack(alignment: .leading, spacing: 10) {
                Text("Bunny Stream credentials")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Library ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 123456", text: $libraryId)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("API key (Stream)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Paste API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                }

                Text("Stored securely in Keychain. The key is never shown or logged.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: Speed
            VStack(alignment: .leading, spacing: 10) {
                Text("Upload speed")
                    .font(.headline)

                Toggle("Automatically by file size", isOn: $engine.autoThreads)

                if engine.autoThreads {
                    Text("≥ 1 GB → 64 threads · 500 MB–1 GB → 32 · 100–500 MB → 16 · 50–100 MB → 8 · under 50 MB → single stream.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Parallel threads")
                        Spacer()
                        Stepper(value: $engine.partCount, in: 1...64) {
                            Text("\(engine.partCount)")
                                .monospacedDigit()
                                .frame(minWidth: 24, alignment: .trailing)
                        }
                    }
                    Text("The file is split into this many parts uploaded in parallel (TUS concatenation). Files under 50 MB always use a single stream.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Divider()

            // MARK: Save
            HStack {
                if savedNote {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                }
                Spacer()
                Button("Save") {
                    engine.saveCredentials(Credentials(apiKey: apiKey, libraryId: libraryId))
                    savedNote = true
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            apiKey = engine.credentials.apiKey
            libraryId = engine.credentials.libraryId
        }
    }
}
