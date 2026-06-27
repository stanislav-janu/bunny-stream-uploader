# Bunny Stream Uploader

A native macOS app for uploading large video files to [Bunny Stream](https://bunny.net) as fast as the link allows. It splits a single file into many parts and uploads them in parallel over TUS `concatenation`, reaching multiples of single-stream throughput.

On a test link a single 9 GB file went from ~56 minutes (single stream) to ~5 minutes (64 parallel threads), roughly 11x faster.

![Bunny Stream Uploader](docs/screenshot.png)

## Features

- **Parallel single-file upload.** One file is split into N parts, each uploaded over its own TCP connection, then merged on Bunny via `Upload-Concat: final`.
- **Automatic thread count** based on file size (configurable).
- **Drag and drop**, plus a Finder **Quick Action / "Open with"** for common video formats (mp4, m4v, mov, mkv, webm, avi, flv, wmv, ts, mpeg).
- **Resumable single-stream** fallback for small files (via TUSKit).
- **Live throughput** and per-upload progress, with cancel.
- **Credentials stored in the macOS Keychain**, never shown or logged.
- **Localized** in English, Czech, Hungarian, Polish, and German.

## Requirements

- macOS 26 or later
- Xcode 26 toolchain (Swift 6) to build
- A Bunny Stream library (Library ID + Stream API key)

## Build

```sh
swift build -c release
./scripts/make-app.sh release
open BunnyUploader.app
```

`scripts/make-app.sh` builds the binary, assembles `BunnyUploader.app` (icon, localizations, document types), code-signs it, and registers it with LaunchServices.

### Code signing (optional but recommended)

A stable signing identity keeps the Keychain "Always Allow" decision valid across rebuilds. The script auto-detects the first available codesigning identity, or you can pin one:

```sh
BUNNY_SIGN_IDENTITY="Apple Development: you@example.com (TEAMID)" ./scripts/make-app.sh release
```

Without any identity it falls back to ad-hoc signing, and the app still runs locally (the Keychain will prompt on each rebuild).

For the Finder Quick Action and the app icon to behave reliably, move `BunnyUploader.app` into `/Applications`.

## Usage

1. Open **Settings** (⌘,) and enter your Bunny **Library ID** and **Stream API key**. They are stored in the Keychain.
2. Upload a video three ways:
   - **Drag and drop** an `.mp4`/`.mov` onto the window.
   - **Right-click** a video in Finder → **Quick Actions / Services → Upload to Bunny**.
   - **Open with → Bunny Stream Uploader**.
3. Watch the aggregate throughput and per-file progress. Uploads can be cancelled mid-flight.

By default the app picks the thread count by file size (≥ 1 GB → 64, 500 MB–1 GB → 32, 100–500 MB → 16, 50–100 MB → 8, under 50 MB → single stream). You can switch to a manual thread count in Settings.

If a new Service does not appear in the Finder menu, enable it under **System Settings → Keyboard → Keyboard Shortcuts → Services**.

## How it works

Bunny's TUS endpoint advertises the `concatenation` extension and runs over HTTP/1.1, so parallel requests use independent TCP connections (each with its own congestion window). For one file the app:

1. Creates the video via the REST API to get a `videoId`.
2. Signs the upload: `SHA256(libraryId + apiKey + expiration + videoId)`.
3. Creates N partial uploads (`Upload-Concat: partial`) and PATCHes each part's bytes in parallel, reading from disk with `pread` off the cooperative pool.
4. Merges them with `Upload-Concat: final;<urls>`.

Single TCP throughput to Bunny is bounded by round-trip time; aggregating independent connections is what multiplies it. See [docs/performance.md](docs/performance.md) for the measured scaling curve.

## License

MIT. See [LICENSE](LICENSE). You are free to use, modify, and distribute this software.

---

Built by [stanislav-janu](https://github.com/stanislav-janu), co-authored with Claude (Anthropic).
