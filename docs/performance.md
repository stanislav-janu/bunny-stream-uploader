# Parallel upload performance

How Bunny Stream Uploader pushes a single large file as fast as the link allows, and what was measured.

## Why parallelism

A single TCP connection to Bunny's ingest is bounded by the bandwidth-delay product. On the test link round-trip time to `video.bunnycdn.com` was about 22 ms and one stream sustained roughly 0.8 to 0.9 MB/s. Throughput per stream is limited by that one connection's congestion window, so the way to go faster is more independent connections, each with its own window.

Bunny's TUS endpoint advertises the `concatenation` extension and runs over HTTP/1.1, so parallel requests naturally use separate TCP connections.

## Upload flow (one file)

1. Create the video through the REST API to obtain a `videoId` (guid).
2. Sign: `SHA256(libraryId + apiKey + expiration + videoId)`. The same signature is valid for every request because it does not depend on offset or part URL.
3. For each of N parts: `POST /tusupload` with `Upload-Concat: partial`, `Upload-Length`, the auth headers (`AuthorizationSignature`, `AuthorizationExpire`, `LibraryId`, `VideoId`) and `Upload-Metadata`. Bunny returns `201` and a `Location`.
4. Send each part's bytes in `PATCH` blocks (`Upload-Offset`). Parts run in parallel, each in its own `URLSession` with `httpMaximumConnectionsPerHost = 1`.
5. `POST /tusupload` with `Upload-Concat: final;<url1> <url2> ...`. Bunny merges the parts and starts transcoding.

Parts are read from the file with `pread` on a dedicated concurrent queue, so blocking disk I/O never serializes the parallel tasks or stalls the async pool. The file is read in place and never copied.

## Measured scaling

Test link: upload capacity around 143 Mbps (`networkQuality`); 8 parallel streams to Cloudflare reached 310 Mbps from the same machine. Through Bunny's ingest via concatenation:

| Threads | Upload throughput | Per-stream | 9 GB file |
| --- | --- | --- | --- |
| 1 (single) | 2.8 MB/s | 2.8 | ~56 min |
| 8 | 10.7 MB/s | 1.5 | ~15 min |
| 16 | 13.7 MB/s | 0.9 | ~11 min |
| 32 | 23.4 MB/s | 0.8 | ~7 min |
| 64 | 31.0 MB/s (248 Mbps) | 0.6 | ~5 min |

Per-stream speed falls as threads increase (shared path), while the aggregate grows sublinearly. Above 64 threads the curve flattens, close to the link ceiling. For reference, Bunny's web uploader reached about 5 MB/s on the same link.

## Automatic thread count

The app picks a thread count by file size:

| File size | Threads |
| --- | --- |
| >= 1 GB | 64 |
| 500 MB to 1 GB | 32 |
| 100 to 500 MB | 16 |
| 50 to 100 MB | 8 |
| < 50 MB | 1 (single stream) |

This can be overridden with a manual count (1 to 64) in Settings.

## Parameters

- PATCH block size is 4 MB. Smaller blocks give a smoother progress indicator (frequent `Upload-Offset` updates); the round-trip overhead is negligible against transfer time.
- The final concatenation request takes a variable amount of time depending on Bunny's load (seconds to low tens of seconds), negligible against upload time for large files.
- The throughput shown in the UI is a 4-second moving average. Progress completes block by block and threads tend to finish in sync, so an instantaneous rate would otherwise show batch spikes.

## Single stream and resume

Small files and the fallback path use TUSKit, which handles resume and offset persistence. Its chunk size is raised to 64 MB, since the 512 kB default throttles throughput due to a round-trip after every chunk.

## Resilience

- Every part request (`POST partial`, `PATCH`, `HEAD`) and the final `POST` retries after a network error or HTTP 408, 409, 423, 429, or 5xx, waiting 0, 3, 5, 10, 20, and 60 s (`ParallelTUSUploader.defaultRetryDelays`). When the waits run out, the upload fails.
- Before a `PATCH` is retried, the part asks Bunny for its `Upload-Offset` with `HEAD` and continues from there. A block Bunny stored while the client saw an error is not sent again, and progress does not count it twice.
- Bunny keeps a part locked (HTTP 423) for about 3 s after a `PATCH` to it was aborted; the retry waits cover that.
- On HTTP 401 the uploader asks `UploadEngine.signer` for a fresh signature for the same `videoId` and repeats the request. Bunny answers 401 per part, so each part renews once. A second 401 right after renewing fails the upload with "Bunny rejected the signature".
- Cancel also stops a running backoff wait (it sleeps in 0.25 s steps).
- Bunny answers the final `Upload-Concat` only after it has merged the parts: a 2.5 GB file in 64 parts got no answer within the 10-minute request timeout. It takes the video over as soon as the request arrives, though: a final request dropped by the client after 3 s still moved the video from status 0 (Created) to 2 (Processing) right away (`--final-probe` checks this against the real library). So while the final request is pending, the uploader asks Get Video every 2 s and, once the status is 1 or higher, drops the request and reports the upload done. A retry after a timeout first asks the status and resends only when the video is still at 0: a second final request for parts Bunny already merged fails with HTTP 400 "Could not find some of the files supplied for concatenation".
- Once the final request went out, quitting asks nothing (`UploadEngine.uploadsBlockingQuit` leaves such uploads out). The row is saved with `finalSent` and loads as Done after the next launch, with the processing check running.
- While any upload runs, the engine holds a `ProcessInfo` activity with `.idleSystemSleepDisabled`, so the Mac does not idle-sleep. The display may still sleep.

## Resume

- During a parallel upload, `uploads.json` keeps a `ResumeState` for the row: part count, file size and modification date, and each part URL as soon as Bunny hands it out.
- Retry on a failed or interrupted row continues into the same video: it asks every saved part for its offset (`HEAD`), sends the rest, and then the final `Upload-Concat`. Parts Bunny no longer knows (404, 410) start over.
- Bunny also keeps the partial bytes of an aborted `PATCH`, so the confirmed offset is often higher than the blocks the client got a response for. Resume always starts from Bunny's offset.
- A file that changed in the meantime (size or modification date) uploads from zero with a fresh split.
- Cancel and a finished upload clear the saved parts.
- Before reusing a row's video, Retry asks Get Video: status 1 or higher means Bunny already has the upload and the row becomes Done; 404 means the video is gone, so the upload starts over in a new video.

## Fault test against the real library

```sh
./scripts/make-app.sh release
./BunnyUploader.app/Contents/MacOS/BunnyUploader --fault-test
```

Without opening a window, the binary reads the credentials from the Keychain and creates two 64 MB test videos in the library. TUS requests go through `FaultInjectingURLProtocol`, which drops connections before sending, loses responses after the server took the data, and answers 503 at random. The run checks three things:

1. An upload with faults finishes, and Bunny gets every byte exactly once.
2. An upload cancelled at 40 % continues from its saved parts and sends only the missing bytes.
3. A second upload into the same video (what Retry does) succeeds even when it starts with an invalid signature (401, then a fresh one).

Both videos are deleted at the end. The exit code is 0 for PASS and 1 for FAIL; details go to `debug.log`.

## After the upload

- The row is Done as soon as the final `Upload-Concat` succeeds. The engine then asks Get Video every 10 s for up to 2 hours: status 4 (Finished) shows "Ready to play", 5 (Error) and 6 (UploadFailed) show the failure, anything else stays "Bunny processing".
- Bunny's queue decides when processing starts; a 6 s test clip stayed at status 2 for several minutes, while large 4K uploads in the same library reach status 4.
- Links: embed `https://player.mediadelivery.net/embed/{libraryId}/{videoId}`, play page `https://player.mediadelivery.net/play/{libraryId}/{videoId}`.
- Collections come from `GET /library/{libraryId}/collections`; the chosen `guid` goes into Create Video as `collectionId`. The choice is stored per library in user defaults.
- `--fault-test --video <file>` also uploads a real short video into the first collection, checks that it landed there, and follows its status. `--recent-videos` prints status and encode progress of the newest videos (no titles, no keys).

