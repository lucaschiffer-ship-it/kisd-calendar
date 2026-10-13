# Mail client: open issues

State on 13 Oct 2026, after the attachments work. Branch
`agent-mail-attachments-2026-10-13`, **nothing committed yet**. Photo metadata
has its own note: [`photo-metadata.md`](photo-metadata.md).

---

## 1 · Never run, to test on the iPhone

- [ ] **Idle, then send a text mail.** Leave the app idle 15+ min, send a
  text mail, and check that it lands in Sent. The fix for the dead-connection
  hang has never met a real dropped connection.
- [ ] **Send with attachments.** Compose should close once the mail is delivered,
  and the mail should then show up in Sent. The background Sent upload has
  never run.
- [ ] **Draft round trip.** Save a draft with a photo, reopen it (the tile should
  come back), then send it. The size choice should still appear.
- [ ] **Forward** a mail that has attachments.
- [ ] **Metadata stripping, the untested paths** (`photo-metadata.md`).
  Library picks were verified on the simulator: JPEG and PNG under Strip GPS,
  JPEG and `.mov` under Strip all. Not yet run:
  - images and videos from Files;
  - a HEIC → JPEG library pick on a real iPhone;
  - Take Photo with the "Camera photos" row on.
- [ ] **Take Photo** and **Scan Document** (the simulator has no camera). Both
  showed as *enabled* in the simulator's menu anyway; not checked why.

## 2 · Issues that can persist

1. ~~**Save Draft can hang.**~~ Fixed 13 Oct 2026 (your go): every command
   on the main connection runs through `ImapSession` with a timeout. Save
   Draft's is size-scaled (30 s + 1 s per 32 KB); on timeout it returns
   `false` and the "Couldn't save the draft" banner shows.
2. ~~**The liveness check only catches closed sockets.**~~ Fixed 13 Oct 2026:
   a connection unheard from for 60 s is probed with NOOP (4 s) before the
   next command and replaced if it doesn't answer; after 10 min in the
   background it is replaced without probing.
3. **The Sent copy of an attachment mail can go missing silently.** It uploads
   in the background (`unawaited(_appendToSent(...))`). A failure is only
   logged, so the user isn't told. Leaving the app right after Send may also
   cut the upload short when iOS suspends it.
4. **A duplicate draft is possible.** If a reopened draft can't be fully fetched,
   its old copy is kept after Send or Save. This is deliberate: a duplicate
   is better than lost files.
5. **The privacy text overstates deletion.** It says attachment copies are
   deleted when compose closes. If the app is killed mid-compose, they stay in
   `Library/Caches/compose_attachments/` until iOS purges the cache. *Options:*
   soften the wording (`privacy_screen.dart`, `PRIVACY.md`, `docs/privacy.md`),
   or delete leftover folders at launch. **Your call.**

## 1b · Mail sync rework (13 Oct 2026), to test on the iPhone

- [ ] **Sent right after launch** shows mail without a reload, also on
  cellular. Open it within the first seconds, while the inbox still loads.
- [ ] **New mail without reload.** Keep the app open and have someone send
  you a mail: it should appear within seconds. On Wi-Fi and on cellular. The
  debug log shows `connected (IDLE)` or `(polling every 60 s)`.
- [ ] **Resume.** Leave the app for 15+ min, come back: the inbox refreshes
  by itself, with no stuck spinner.
- [ ] **Scrolling past 50** loads older mail, in every folder.
- [ ] **Offline launch** (flight mode): every folder still shows its last
  list; opening a recent inbox mail works.
- [x] **The first launch after the update** moves the old offline copy from
  `Library/Caches`. Verified on the simulator on 13 Oct 2026: `index.json` became
  `inbox.json`, all 49 bodies moved, the old folder is gone, and
  `mail_store` carries `com_apple_backup_excludeItem`. The inbox showed
  offline at once.
- [x] **A refused login stops automatic retries.** Verified on the
  simulator: there was exactly one login attempt. Opening Sent afterwards showed
  "Could not connect: Login failed: authentication failure" with Try Again
  rather than "No sent mail". The simulator's Keychain password was refused
  (probably outdated, or the login limit from earlier that day). So **the
  server side of the rework (delta sync, IDLE, paging, Sent refresh) has not
  run against the real server yet.**

## 3 · Changes to existing mail behaviour

If something old breaks, look here first:

- *(13 Oct 2026)* Every main-connection command goes through `ImapSession`
  (`lib/services/imap_session.dart`): one op at a time, a timeout per op, a
  probe of a quiet connection, one retry for read-only/flag ops. This
  replaced `_ensureConnected`. Folder lists are synced by delta
  (`lib/services/mail_sync.dart`) instead of refetched whole.
- *(13 Oct 2026)* The offline copy moved to `Library/Application
  Support/mail_store` and covers all four folders' lists.
- A text mail's Sent copy now gives up after 30 s and resets the connection.
  Before, it could wait forever.
- A reopened draft keeps Send disabled, and Save Draft waits, until the full
  draft has loaded.
- Text-only mails still use the old `buildSimpleTextMessage` path, unchanged.

## 4 · Loose ends

- The test mail sent from the simulator has **no copy in Sent**. The app
  hung on it before the fix, and a hot restart dropped it.
- `ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` is on
  `Release`. That is your own uncommitted change, and it stays out of the
  attachments commit. Simulator runs need it on `Debug`.
- When committed, push to **both** `origin` and `public`.
