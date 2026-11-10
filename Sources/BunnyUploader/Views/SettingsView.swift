import SwiftUI
import BunnyUploaderCore

struct SettingsView: View {
    @EnvironmentObject private var engine: UploadEngine

    @State private var apiKey: String = ""
    @State private var libraryId: String = ""
    @State private var savedNote = false
    @State private var isChecking = false
    @State private var checkError: BunnyAPIClient.CredentialCheckError?
    @State private var collections: [BunnyAPIClient.Collection] = []
    @State private var collectionsState: CollectionsState = .idle
    @State private var collectionGone = false

    private enum CollectionsState {
        case idle
        case loading
        case loaded
        case failed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            // MARK: Credentials
            VStack(alignment: .leading, spacing: Space.m) {
                Text("Bunny Stream credentials")
                    .font(.headline)

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Library ID")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. 123456", text: $libraryId)
                        .textFieldStyle(.roundedBorder)
                    if checkError == .libraryNotFound {
                        errorText
                    }
                }

                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("API key (Stream)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    SecureField("Paste API key", text: $apiKey)
                        .textFieldStyle(.roundedBorder)
                    if checkError == .keyRejected {
                        errorText
                    }
                }

                Text("Stored securely in Keychain. The key is never shown or logged.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            // MARK: Collection
            collectionSection

            Divider()

            // MARK: Speed
            VStack(alignment: .leading, spacing: Space.m) {
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
                                .frame(minWidth: Layout.stepperValueWidth, alignment: .trailing)
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
                if isChecking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if savedNote {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Palette.success)
                        .font(.caption)
                } else if let checkError, checkError != .keyRejected, checkError != .libraryNotFound {
                    errorText
                }
                Spacer()
                Button("Save") {
                    save()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isChecking || apiKey.isEmpty || libraryId.isEmpty)
            }
        }
        .padding(Space.xxl)
        .frame(width: Layout.settingsWidth)
        .onAppear {
            apiKey = engine.credentials.apiKey
            libraryId = engine.credentials.libraryId
            loadCollections()
        }
        .onChange(of: apiKey) {
            clearResult()
        }
        .onChange(of: libraryId) {
            clearResult()
        }
    }

    @ViewBuilder
    private var errorText: some View {
        if let checkError {
            Label(checkError.message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(Palette.failure)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var collectionSection: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text("Collection")
                .font(.headline)
            HStack {
                Picker("New uploads go to", selection: collectionBinding) {
                    Text("No collection")
                        .tag(String?.none)
                    ForEach(pickerCollections) { collection in
                        Text(collection.name)
                            .tag(Optional(collection.id))
                    }
                }
                .disabled(collectionsState != .loaded)
                if collectionsState == .loading {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            if collectionsState == .failed {
                HStack {
                    Label("Unable to load collections.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.failure)
                    Button("Try Again") {
                        loadCollections()
                    }
                    .controlSize(.small)
                }
                .font(.caption)
            } else if collectionGone {
                Text("The saved collection no longer exists. New uploads go to the library without a collection.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Loaded collections, plus the saved one while the list is not loaded yet.
    private var pickerCollections: [BunnyAPIClient.Collection] {
        if collectionsState != .loaded, let saved = engine.collection {
            return [saved]
        }
        return collections
    }

    private var collectionBinding: Binding<String?> {
        Binding(
            get: { engine.collection?.id },
            set: { id in
                engine.setCollection(collections.first { $0.id == id })
                collectionGone = false
            }
        )
    }

    private func loadCollections() {
        guard engine.hasCredentials else { return }
        collectionsState = .loading
        Task {
            do {
                let result = try await engine.loadCollections()
                collections = result.collections
                collectionGone = result.savedCollectionGone
                collectionsState = .loaded
            } catch {
                collectionsState = .failed
            }
        }
    }

    private func clearResult() {
        savedNote = false
        checkError = nil
    }

    private func save() {
        let new = Credentials(
            apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines),
            libraryId: libraryId.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        isChecking = true
        clearResult()
        Task {
            let error = await engine.checkAndSaveCredentials(new)
            isChecking = false
            checkError = error
            savedNote = error == nil
            if error == nil {
                loadCollections()
            }
            let announcement = error?.message ?? String(localized: "Saved")
            AccessibilityNotification.Announcement(announcement).post()
        }
    }
}
