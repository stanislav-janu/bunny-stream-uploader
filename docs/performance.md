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
