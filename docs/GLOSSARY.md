# Glossary

One name per thing, used the same way in buttons, menus, tooltips, errors, and all five localizations.

## Things

| Term | Means | Not |
| --- | --- | --- |
| Upload | One file being sent to Bunny, shown as one row in the list | job, task, transfer, item |
| Video | The object in the Bunny library that an upload fills | asset, media, entry |
| Video ID | The GUID Bunny gives the video | guid, video key, identifier |
| Embed link | `https://iframe.mediadelivery.net/embed/{Library ID}/{Video ID}` | player URL, iframe, share link |
| Library | The Bunny Stream library uploads go into | account, project, zone |
| Library ID | The number of the library, from the Bunny dashboard | library key, zone ID |
| API key | The Stream API key of the library | access key, password, token |
| Credentials | Library ID and API key together | login, account, auth |
| Threads | Parallel connections one upload uses | streams, workers, parts, chunks |
| Throughput | Upload speed in MB/s | bandwidth, rate |
| Settings | The app's settings window (Command-Comma) | Preferences, options |

## States of an upload

| Term | Means | Not |
| --- | --- | --- |
| Waiting | Queued, not started yet | pending, idle |
| Creating video | Asking Bunny for a new video | preparing, init |
| Uploading | Bytes are moving | sending, transferring |
| Bunny processing | Upload done, Bunny is transcoding | encoding, converting |
| Done | Upload finished; the video ID is ready to use | complete, finished, success |
| Ready to play | Bunny finished transcoding; the video plays | live, published, encoded |
| Cancelled | Stopped by the user | aborted, stopped |
| Interrupted | Was running when the app quit or crashed | paused, broken |
| Failed | Stopped by an error; the reason shows in the row | error state, crashed |

## Actions

| Term | Means | Not |
| --- | --- | --- |
| Upload to Bunny | Start an upload from Finder | send, share, import |
| Cancel | Stop a running upload and delete its unfinished video in Bunny | abort, stop |
| Retry | Upload a failed, cancelled, or interrupted file again (into the same video when it still exists) | restart, redo, try again |
| Remove | Take an upload off the list; a done video stays in Bunny, an unfinished one is deleted there | delete, clear, dismiss |
| Clear Finished | Remove every done row at once | clean up, purge, clear all |
| Copy ID | Put the video ID on the pasteboard | copy GUID, copy key |
| Copy Embed Link | Put the embed link on the pasteboard | copy URL, share |
| Open Settings | Open the Settings window | configure, set up |
| Save | Check the credentials with Bunny, then store them in the Keychain | apply, OK, verify |
