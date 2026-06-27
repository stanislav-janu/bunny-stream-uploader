# Bunny Stream Uploader

Native macOS app (Swift / SwiftUI) that uploads a single large video file to Bunny Stream in parallel over TUS `concatenation`, reaching multiples of single-stream throughput. Open source, MIT.

## Build and run

```sh
swift build -c release
./scripts/make-app.sh release   # builds, signs, packages BunnyUploader.app, registers it
open BunnyUploader.app
```

Minimum target is macOS 26; building needs the Xcode 26 toolchain (Swift 6). There is no Xcode project: `scripts/make-app.sh` assembles the `.app` bundle (Info.plist, icon, localizations, document types), code-signs it, and registers it with LaunchServices. Run via the `.app` bundle, not `swift run` (localizations and Finder integration need the bundle).

## Architecture

Two SwiftPM targets: `BunnyUploaderCore` (testable logic library) and `BunnyUploader` (executable: app + views). UI side-effects (Dock, notifications) stay in the executable and are wired into the engine via hooks (`onUploadFinished`, `onUploadFailed`), so Core has no AppKit/UserNotifications dependency.

`Sources/BunnyUploader/` (executable):
- `App/BunnyUploaderApp.swift` — `@main`, `AppDelegate` (Finder "Open with" + `NSServices` Quick Action "Upload to Bunny"), wires engine hooks and the Dock progress bar.
- `App/DockProgress`, `App/Notifications` — Dock icon progress bar and completion notifications.
- `Views/` — SwiftUI: `ContentView`, `DropZone`, `UploadRowView`, `SettingsView`.

`Sources/BunnyUploaderCore/` (library):
- `Engine/UploadEngine` — main-actor coordinator: queue, strategy choice, throughput (4 s moving average), cancellation. `init(credentials:)` and `apiSession` / `parallelSessionConfiguration` exist for test injection.
- `TUS/ParallelTUSUploader` — the core: custom parallel concatenation uploader (one `URLSession`/TCP connection per part, `pread` off the cooperative pool, merge with `Upload-Concat: final`). Not an actor on purpose; takes an injectable session config.
- `TUS/TUSUploader` — TUSKit wrapper for single-stream + resume (files < 50 MB and fallback).
- `Bunny/` — `BunnyAPIClient` (Create/Get Video, injectable session), `Signature` (`SHA256(libraryId+apiKey+expiration+videoId)`).
- `Keychain/KeychainStore` — credentials in one keychain item.
- `Models/UploadItem` — upload item and `UploadState`.

`Resources/Localizations/*.lproj` — en (base), cs, hu, pl, de.

## Tests

`swift test --enable-code-coverage`. Tests live in `Tests/BunnyUploaderCoreTests` and use `MockURLProtocol` for networking. CI enforces a coverage gate (min 80%) over Core, excluding the thin integration layers (`KeychainStore`, `TUSUploader`) that need a real system. Keep custom logic (parsing, signature, splitting, parallel upload, API, engine flow) covered. When testing code that constructs `UploadEngine`, pass `credentials:` to avoid a Keychain read that hangs in the test process.

## Conventions

- UI strings are English in code (`Text(...)` / `String(localized: ...)`); translations live in `Resources/Localizations`. When adding a string, add it to ALL five `.lproj` files and keep the `%@` / `%lld` format specifiers identical across languages.
- Code comments and docs in English.
- No personal or company data in source or docs: no real emails, signing identities, or team IDs. Bundle id is `net.bunnyuploader.BunnyUploader`; signing uses `BUNNY_SIGN_IDENTITY` env or auto-detects an identity, else ad-hoc.
- No em-dash in prose; use commas, colons, or parentheses.
- Commit only when asked; never add `Co-Authored-By`. Use the repo's normal git author.

## Key facts

- Bunny's TUS endpoint advertises `concatenation` over HTTP/1.1; parallel partial uploads merge into a pre-created `videoId` (verified against a real library).
- Thread count is auto-chosen by file size (>= 1 GB -> 64, 500 MB–1 GB -> 32, 100–500 MB -> 16, 50–100 MB -> 8, else single). See `docs/performance.md` for the measured scaling curve.
- Single TCP throughput to Bunny is RTT-bound (~0.8 MB/s/stream on the test link); aggregating connections is what multiplies it.
- Diagnostic log: `~/Library/Application Support/BunnyUploader/debug.log` (per-part timings, no credentials).
