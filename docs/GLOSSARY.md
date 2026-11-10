# Glossary

One name per thing, used the same way in buttons, menus, tooltips, errors, and all five localizations.

## Things

| Term | Means | Not |
| --- | --- | --- |
| Upload | One file being sent to Bunny, shown as one row in the list | job, task, transfer, item |
| Video | The object in the Bunny library that an upload fills | asset, media, entry |
| Video ID | The GUID Bunny gives the video | guid, video key, identifier |
| Embed link | `https://player.mediadelivery.net/embed/{Library ID}/{Video ID}` | player URL, iframe, share link |
| Play page | Bunny's player page, `https://player.mediadelivery.net/play/{Library ID}/{Video ID}` | preview, watch link |
| Collection | A folder in the library that new uploads can go into | folder, playlist, category |
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
| Bunny processing | Upload done, Bunny is transcoding; shown beside Done | encoding, converting |
| Done | Upload finished; the video ID is ready to use | complete, finished, success |
| Ready to play | Bunny finished transcoding (status 4); the video plays; shown beside Done | live, published, encoded |
| Bunny could not process the video | Bunny reported Error or UploadFailed (status 5, 6) | transcoding failed, broken |
| Cancelled | Stopped by the user | aborted, stopped |
| Interrupted | Was running when the app quit or crashed | paused, broken |
| Failed | Stopped by an error; the reason shows in the row | error state, crashed |

## Actions

| Term | Means | Not |
| --- | --- | --- |
| Upload to Bunny | Start an upload from Finder | send, share, import |
| Cancel | Stop a running upload and delete its unfinished video in Bunny | abort, stop |
| Retry | Upload a failed, cancelled, or interrupted file again: continue from saved parts, or finish at once when Bunny already has the video | restart, redo, try again |
| Upload Again | Confirm a Retry that has to upload the whole file from the start | restart, start over |
| Remove | Take an upload off the list; a done video stays in Bunny, an unfinished one is deleted there | delete, clear, dismiss |
| Clear Finished | Remove every done row at once | clean up, purge, clear all |
| Copy ID | Put the video ID on the pasteboard (click the ID, or the context menu) | copy GUID, copy key |
| Copy Embed Link | Put the embed link on the pasteboard | copy URL, share |
| Play in Browser | Open the play page in the default browser | open in Bunny, preview |
| Copy Error Message | Put a failed row's error text on the pasteboard (the text can also be selected) | copy log, copy details |
| Open Settings | Open the Settings window | configure, set up |
| Try Again | Load again after a load failed (collections) | reload, refresh |
| Keep Uploading | Stay in the app when Quit would stop running uploads | continue, stay, cancel |
| Quit | Close the app; running uploads stop and load as Interrupted | exit, close |
| Save | Check the credentials with Bunny, then store them in the Keychain | apply, OK, verify |
