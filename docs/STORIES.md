# User stories

Backlog for Bunny Stream Uploader. Sources: `bunny-stream-uploader-navrh.md` (the brief), `docs/superpowers/specs/2026-06-27-bunny-stream-uploader-mvp-design.md`, and the current code. Stories already shipped are marked `done` so the backlog shows the whole app.

The one job: get one large video file into a Bunny Stream library as fast as the link allows, without babysitting it, and come away with the video ID to use.

## Snapshot pages

No reference app; snapshots are taken of these pages of the app itself, in light and dark.

| Page | Shows |
| --- | --- |
| `main-empty` | Main window, no uploads, credentials set |
| `main-no-credentials` | Main window, no credentials saved |
| `main-uploading` | One parallel upload in progress, one waiting in the queue |
| `main-finished` | One done, one failed, one cancelled row |
| `main-row-menu` | Context menu open on a finished row |
| `settings` | Settings window, credentials filled |
| `settings-invalid` | Settings after a failed credentials check |
| `quit-confirm` | Quit confirmation with an active upload |

## Seed data

Snapshot pages are seeded with upload rows only: file name, size, state, progress, throughput, video ID, and error message. All of these come from a real upload the user starts. Credentials are seeded with obvious fake values (`000000`, `test-key`).

## M1 Core loop: upload one video and use it

### S-001 Save Library ID and Stream API key
As the user, I open Settings (Command-Comma), enter my Library ID and Stream API key, and press Save.
Screens: settings
Acceptance:
- [snap] Settings shows a Library ID field, a secure API key field, and a Save button.
- [unit] Saved credentials load back from the store; the API key never appears in `debug.log`.
- [manual] After a restart the credentials are still there and the main window says "Ready".
Status: done

### S-002 Check credentials when saving them
As the user, I press Save in Settings and the app tells me right away whether Bunny accepts the Library ID and key.
Screens: settings, settings-invalid
Depends: S-001
Acceptance:
- [unit] Save calls the Bunny library API once; HTTP 401 maps to "wrong key", 404 to "wrong Library ID", a network error to "could not reach Bunny".
- [snap] A failed check shows the reason under the fields and keeps the values in place.
- [snap] A passed check shows "Saved" with a checkmark.
- [unit] Credentials are stored only after a passed check.
UX:
- Flow: Command-Comma, Open Settings button (S-003) -> type Library ID, paste API key -> Return or Save -> button shows a spinner and "Checking…" -> inline result; Escape or Command-W closes without saving
- Surface: inline in the Settings window (changes values already on screen); no alert
- States: checking: Save disabled with a small spinner, under one second usually; passed: green checkmark "Saved"; failed: red text under the field at fault, field keeps focus and value; editing a field clears the old result
- Words: "Save"; "Checking…"; "Saved"; "Bunny rejected this API key. Copy the Stream API key from the library's API page."; "No library with this ID. Check the Library ID in the Bunny dashboard."; "Unable to reach Bunny. Check your connection and try again."
- Access: Return saves, Tab order Library ID -> API key -> Save; VoiceOver announces the result; error text has an icon, not only red
Status: done

### S-003 Upload a video by dropping it on the window
As the user, I drag a video file from Finder onto the window and its upload starts.
Screens: main-empty, main-uploading
Depends: S-001
Acceptance:
- [snap] The drop zone highlights while a file hovers over it.
- [unit] A dropped file creates a Bunny video titled with the file name, then uploads with the strategy chosen by file size (64 / 32 / 16 / 8 threads, single stream under 50 MB).
- [snap] Without credentials the window says so and offers a button that opens Settings.
UX:
- Flow: launch without credentials -> header and drop zone say credentials are missing -> Open Settings button -> Settings (S-002); dropping a file anyway adds a Failed row with the same button
- Surface: inline in the main window (information plus one action); no alert, no automatic Settings window
- States: no credentials: drop zone shows "Add your Bunny credentials to start uploading." with "Open Settings…"; ready: header "Ready"; hovering a file: drop zone highlights in the accent with an icon change
- Words: "Open Settings…" (Title Case, ellipsis because it opens a window that asks for input); header "Credentials missing"; drop zone "Drop videos here"
- Access: Open Settings is the default focus in that state; status uses an icon plus text, not red alone
Status: done

### S-004 Watch throughput and progress of an upload
As the user, I see how fast the upload goes and how much is left while it runs.
Screens: main-uploading
Depends: S-003
Acceptance:
- [snap] The row shows state, progress bar, MB/s, and percent; the header shows total MB/s.
- [unit] Throughput is a 4 second moving average and drops to 0 when the upload ends.
- [self] Progress never goes backwards and reaches 100 % only after the final concatenation succeeds.
Status: done

### S-005 Cancel an upload in progress
As the user, I press the stop button on a row and the upload stops.
Screens: main-uploading, main-finished
Depends: S-003
Acceptance:
- [unit] Cancel stops every part connection and the row shows "Cancelled" within a second.
- [unit] Cancelling during "Creating video" does not start the upload afterwards.
Status: done

### S-006 Copy the video ID
As the user, I click the video ID on a row (or choose Copy ID from its context menu) and paste it where I need it.
Screens: main-finished, main-row-menu
Depends: S-003
Acceptance:
- [snap] As soon as the video exists, the row shows "Video ID" and the ID (shortened in the middle) with a copy icon.
- [self] One click on the ID puts exactly the GUID on the pasteboard; the icon turns into a checkmark with "Copied" for 1.5 s.
- [snap] The row's context menu offers Copy ID whenever the row has a video ID, and Copy Embed Link (`https://player.mediadelivery.net/embed/{libraryId}/{videoId}`) on done rows.
UX:
- Flow: click the ID, or right-click the row and choose Copy ID, or Command-C on the selected row (S-020) -> "Copied" for 1.5 s
- Surface: the ID itself is the control (pointing-hand cursor), the same action in the context menu
- Words: "Video ID", tooltip "Click to copy the video ID: <ID>", "Copy ID", "Copied", "Copy Embed Link"
- Access: VoiceOver reads "Copy ID" with the ID as value and announces "Copied"
Status: done

### S-007 Retry a failed or cancelled upload
As the user, I press "Retry" on a failed or cancelled row and the same file uploads again into the same Bunny video.
Screens: main-finished
Depends: S-003
Acceptance:
- [snap] Failed and cancelled rows show a Retry button; done rows do not.
- [unit] Retry of a failed or interrupted row reuses its video ID, so Bunny gets no duplicate video; a cancelled row has none (S-014) and gets a new one.
- [unit] Retry of a file that no longer exists shows "File not found" instead of starting.
- [unit] Retry of a row whose video Bunny already has (status 1 or higher) marks it Done without uploading; a video that is gone (404) is replaced by a new one.
- [unit] Retry asks first when it would upload the whole file from the start (no saved parts, a changed file, a video gone from Bunny, a cancelled row): alert "Upload again from the start?" with "Upload Again" and "Cancel". Continuing from saved parts and finishing a video Bunny already has do not ask.
- [snap] A failed row's error text can be selected, and the context menu has "Copy Error Message".
UX:
- Flow: failed, cancelled, or interrupted row -> Retry button, context menu Retry, or Command-R -> same row goes back to "Uploading" at 0 % (or the resumed offset after S-013); Cancel undoes it
- Surface: inline button in the row, replacing nothing; Remove stays beside it
- States: failed row shows "Failed" plus the reason on its own line (truncated, full text in the tooltip); missing file: "The file was moved or deleted. Drop it again to upload." and no Retry
- Words: "Retry"; tooltip "Upload this file again into the same video (⌘R)"; state label "Failed" replaces today's "Error: …"; "Remove" tooltip "Remove from the list. The video stays in Bunny."
- Access: Retry is reachable by Tab and Command-R; failed rows have an icon, not only red
Status: done

### S-008 Keep the upload list after a restart
As the user, I quit and reopen the app and still see what I uploaded today, with video IDs.
Screens: main-finished
Depends: S-006
Acceptance:
- [unit] Finished rows (name, size, state, video ID, finish date) are saved to Application Support and loaded on launch.
- [unit] A row that was active at quit loads as "Interrupted" with Retry (until S-013 resumes it).
- [snap] "Clear Finished" removes done rows from the list and from the saved file.
- [manual] Command-Z brings back rows removed with Clear Finished or with Remove on one row; an unfinished row's video was already deleted in Bunny, so Retry uploads it into a new one.
UX:
- Flow: quit -> reopen -> list shows earlier uploads, newest on top, with finish time; Clear Finished in the toolbar or Upload menu (S-021) removes done rows; Command-Z brings them back
- Surface: inline in the main list (a place people come back to, no separate History page in version one)
- States: empty list: "No uploads yet" with "Choose Videos…" (S-018); interrupted rows on launch: "Interrupted" with Retry; many rows: list scrolls, long file names truncate in the middle with the full name in a tooltip
- Words: "Clear Finished" (toolbar button with text, disabled when nothing is done); "Undo Clear Finished"; "Interrupted"; time as relative date ("Today 14:32")
- Access: Clear Finished has a text label and VoiceOver hint "Removes done uploads from the list"
Status: done

## M2 Reliability: big files finish without babysitting

### S-009 Retry a failed part without restarting the file
As the user, when one part connection drops, the upload carries on and only that part repeats.
Screens: main-uploading
Depends: S-003
Acceptance:
- [unit] A part that fails with a network error or 5xx retries after 0, 3, 5, 10, 20, 60 s, then fails the upload.
- [unit] A retried part resumes from its last confirmed offset (HEAD `Upload-Offset`), not from zero.
- [unit] Progress does not count retried bytes twice.
- [self] `--fault-test` injects dropped connections, lost responses, and 503s against the real library; Bunny gets every byte exactly once.
Note: covers the parallel path (files of 50 MB and more); single-stream files use TUSKit's own retry.
Status: done

### S-010 Continue after the signature expires
As the user, a long upload keeps going when Bunny rejects the signature with 401.
Depends: S-009
Acceptance:
- [unit] On 401 the engine makes a new signature for the same video ID and retries that request once.
- [unit] A second 401 in a row fails the upload with "Bunny rejected the signature".
- [self] `--fault-test` starts a re-upload with an invalid signature; Bunny answers 401 and the upload finishes after re-signing.
Note: covers the parallel path; a signature lasts 24 h, so only uploads longer than that hit it.
Status: done

### S-011 Keep the Mac awake while uploading
As the user, I leave the Mac during a long upload and it does not go to sleep until the upload ends.
Depends: S-003
Acceptance:
- [unit] The engine holds a "prevent idle sleep" assertion while any upload is active and releases it when none is.
- [manual] With display sleep set to 1 minute, a 10 minute upload finishes; the display may sleep, the system does not.
Status: doing

### S-012 Confirm quitting while uploads run
As the user, I press Command-Q during an upload and the app asks before stopping it.
Screens: quit-confirm
Depends: S-003
Acceptance:
- [snap] The alert names how many uploads are running and offers "Quit" and "Keep Uploading" (default).
- [unit] With no active uploads the app quits without asking.
- [unit] An upload whose final request already went out does not count: Bunny finishes it without the app, and the row loads as Done after the next launch.
UX:
- Flow: Command-Q or Quit from the menu with running uploads -> alert -> Return keeps uploading; Quit stops them without Cancel, so their videos stay in Bunny and the rows load as Interrupted
- Surface: alert (a problem people must act on right now)
- Words: title "Quit while uploading?"; message "Uploads still running: %lld. If you quit now, they stop and you can retry them after the next launch."; buttons "Keep Uploading" (default) and "Quit"
- Access: Return keeps uploading, Escape cancels quitting
Status: done

### S-013 Resume an interrupted parallel upload
As the user, after a crash, quit, or lost network, I press Retry and the upload continues from where its parts stopped.
Screens: main-finished
Depends: S-008, S-009
Acceptance:
- [unit] Part upload URLs, offsets, and the video ID are saved to Application Support while uploading and deleted after success.
- [unit] Retry asks each saved part for its offset (HEAD) and uploads only the rest, then sends the final concatenation.
- [unit] A changed file (size or modification date) starts over with a fresh split instead of resuming.
- [self] `--fault-test` cancels an upload at 40 % and resumes it against the real library; kept + resent bytes equal the file size.
Status: done

### S-014 Remove the empty Bunny video after cancelling
As the user, when I cancel an upload, the empty video does not stay in my Bunny library.
Depends: S-005
Acceptance:
- [unit] Cancel deletes the created video (`DELETE /library/{id}/videos/{guid}`); Retry then creates a new one.
- [unit] Remove deletes the video of a failed or interrupted row; Remove of a done row keeps the video in Bunny.
- [unit] Cancelling during "Creating video" deletes the video Bunny creates a moment later.
- [unit] A failed delete is logged and does not show an error to the user.
- [manual] After Cancel the video is gone from the Bunny library.
UX:
- Words: Cancel tooltip "Cancel this upload and delete the unfinished video in Bunny"; Remove tooltip on a done row "Remove from the list. The video stays in Bunny.", on other rows "Remove from the list and delete the unfinished video in Bunny"
Status: done

## M3 After upload: the video is ready to use

### S-015 Follow processing until the video plays
As the user, I see when Bunny has finished transcoding, not only when the upload ended.
Screens: main-finished
Depends: S-003
Acceptance:
- [unit] When the upload ends the row is Done at once (Copy ID works) and shows "Bunny processing" beside it; it polls Get Video every 10 s until status 4 (Ready to play), 5 or 6 (failed), or 2 hours after the upload ended.
- [snap] A processed row shows "Ready to play"; a Bunny failure shows "Bunny could not process the video".
- [unit] The notification and Dock badge fire when the upload ends, not when processing ends.
- [unit] The upload ends as soon as Bunny takes the video over (status 1 or higher, checked every 2 s while the final request is pending), not when Bunny answers the final request, which takes minutes for large files.
- [unit] Rows still processing at quit are checked again after launch; Remove and Clear Finished stop the checks.
- [self] `--fault-test --video <file>` uploads a real short video and follows its status against the real library.
UX:
- Flow: upload ends -> Done plus "Bunny processing" (hourglass) -> "Ready to play" (play icon) or the failure text (warning icon, red); after 2 hours without an answer the extra label disappears
- Surface: inline in the row's status line (information that needs no action)
- Words: "Bunny processing", tooltip "Bunny is transcoding the video. The video ID already works."; "Ready to play"; "Bunny could not process the video"
- Access: each state has its own icon, not only color
Note: status values from Bunny's Get Video reference: 0 Created, 1 Uploaded, 2 Processing, 3 Transcoding, 4 Finished, 5 Error, 6 UploadFailed, 7 JitSegmenting, 8 JitPlaylistsCreated.
Status: done


### S-016 Play the video in the browser
As the user, I choose "Play in Browser" on a finished row and Bunny's play page opens in my browser.
Screens: main-row-menu
Depends: S-006
Acceptance:
- [unit] The URL is `https://player.mediadelivery.net/play/{libraryId}/{videoId}`, built from the row's own library and video ID.
- [snap] The row's context menu has "Play in Browser".
UX:
- Flow: right-click a done row -> Play in Browser -> default browser opens the play page
- Surface: context menu item (a secondary action on one row)
- Words: "Play in Browser"
Note: Bunny documents the play and embed pages on player.mediadelivery.net; it documents no per-video dashboard URL, so the story opens the play page.
Status: done


### S-017 Upload into a collection
As the user, I pick a collection in Settings and new uploads land in it.
Screens: settings
Depends: S-002
Acceptance:
- [unit] Settings loads the library's collections; Create Video sends the chosen `collectionId`.
- [snap] Settings shows a collection picker with "No collection" as the first choice.
- [unit] A collection that no longer exists falls back to "No collection" with a note in Settings; a renamed one keeps its selection.
- [unit] The choice is kept per library and survives a restart.
- [self] `--fault-test --video <file>` creates a video in the library's first collection and checks it landed there.
UX:
- Flow: Settings -> Collection -> picker "New uploads go to" -> choice applies at once (no Save); loads on open and after saving credentials
- Surface: inline picker in Settings (changes one value)
- States: loading (spinner, picker disabled); failed: "Unable to load collections." with "Try Again"; gone: "The saved collection no longer exists. New uploads go to the library without a collection."
- Words: "Collection", "New uploads go to", "No collection", "Try Again"
Status: done


### S-018 Choose videos with File > Open
As the user, I press Command-O, pick one or more videos, and they upload.
Screens: main-empty
Acceptance:
- [self] Command-O opens a panel filtered to the supported video types, multiple selection allowed.
- [snap] The empty state also offers a "Choose Videos…" button.
Status: todo

### S-019 Queue several files
As the user, I drop ten files at once and they upload one after another at full speed instead of all at once.
Screens: main-uploading
Depends: S-003
Acceptance:
- [unit] Only one parallel upload runs at a time; small single-stream files may run up to 3 at once beside it.
- [snap] Queued rows show "Waiting" with their place in the queue.
- [unit] Cancelling the running upload starts the next queued one.
Status: todo

### S-020 Control rows with the keyboard
As the user, I select a row with the arrow keys and act on it without the mouse.
Screens: main-finished
Depends: S-007
Acceptance:
- [self] Up and Down move the selection; Delete removes a finished row; Command-Period cancels the selected active row; Command-C copies its video ID.
Status: todo

### S-021 Use the Upload menu
As the user, I find every action on uploads in a menu with its shortcut.
Depends: S-018, S-020
Acceptance:
- [self] The menu bar has File > Open (Command-O) and an Upload menu with Cancel (Command-Period), Retry (Command-R), Copy ID (Command-C), Cancel All, and Clear Finished.
- [self] Items are disabled when they do not apply to the selection.
Status: todo

## M5 System: upload from anywhere on the Mac

### S-022 Upload from Finder's Quick Actions
As the user, I right-click a video in Finder and choose "Upload to Bunny".
Acceptance:
- [manual] The service appears for mp4, m4v, mov, mkv, webm, avi, flv, wmv, ts, mpeg and starts the upload in the app.
Status: done

### S-023 Upload with Open With
As the user, I choose Open With > Bunny Stream Uploader on a video in Finder.
Acceptance:
- [manual] The app opens (or comes forward) and starts the upload.
Status: done

### S-024 See progress on the Dock icon
As the user, I see total progress on the Dock icon while the window is hidden.
Acceptance:
- [manual] A progress bar shows on the Dock icon during uploads and disappears when none are active.
Status: done

### S-025 Get notified when an upload ends
As the user, I get a notification when an upload finishes or fails.
Acceptance:
- [manual] Finished and failed uploads post a notification with the file name; clicking it brings the window forward.
Status: done

## M6 Polish

### S-026 One accent and design tokens
As the user, I see one consistent accent, spacing, and radius across the window, rows, and Settings.
Screens: main-empty, main-uploading, main-finished, settings
Acceptance:
- [snap] Colors, radii, and spacing come from Swift tokens described in `design/DESIGN-SYSTEM.md`; no literal colors or radii in views.
- [snap] Light and dark snapshots of every page pass the contrast check.
Status: todo

### S-027 Liquid Glass app icon
As the user, I see a sharp Liquid Glass icon in the Dock, Finder, and notifications.
Acceptance:
- [snap] `Icon/AppIcon.icon` compiles with actool and replaces `Resources/AppIcon.icns` in the bundle.
- [snap] The icon reads in default, dark, clear, and tinted looks.
Status: todo

### S-028 Act on a row from its context menu
As the user, I right-click a row and see everything I can do with it.
Screens: main-row-menu
Depends: S-006, S-007, S-016
Acceptance:
- [snap] The menu has Copy ID, Copy embed link, Open in Bunny, Show in Finder, Retry, Cancel, Remove, each only when it applies.
Status: todo

## Later

- Background `URLSession` for overnight uploads that survive quitting the app.
- Adaptive thread count from measured throughput instead of file size only.
- Thumbnail time (`thumbnailTime` metadata) and custom title before upload.
- Several Bunny libraries with a switcher.
- Shortcuts action "Upload video to Bunny" and a CLI for scripts and agents.
- Menu bar extra with total progress.

## Dropped

- Accounts, sign-in, or a server between the app and Bunny: the API key stays in the Keychain on the Mac.
- Sharing uploads with teammates inside the app: the video ID and Bunny dashboard cover it.
- Browsing, playing, or editing videos already in the library: that is the Bunny dashboard's job.
- Analytics and usage tracking.
- Upgrade prompts or paid tiers: the app is free and MIT.
- Manual choice of ingest region: Bunny routes the single TUS hostname to the nearest edge.
- Manual chunk size setting: parts are sized by thread count, and the number of threads is the only knob that measurably changes speed.
