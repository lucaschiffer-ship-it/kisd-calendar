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

1. **Save Draft can hang.** The Drafts `appendMessage` call in
   `saveDraft` (`lib/services/mail_service.dart`) has no timeout. If the
   connection goes silent without the server closing it, the spinner never
   stops, ✕ stays disabled, and killing the app loses the draft. Big drafts make
   this more likely. *Proposed fix:* a Dart `.timeout()` that returns `false`,
   which shows the existing "Couldn't save the draft" banner. **Waiting for
   your go**, since that code is shared with text drafts.
2. **The liveness check only catches closed sockets.** `_ensureConnected` now
   also checks enough_mail's `isConnected`. That notices a socket the
   *server closed*, not one that just went quiet. Only the Sent copy has a
   timeout for the quiet case.
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

## 3 · Changes to existing mail behaviour

If something old breaks, look here first:

- `_ensureConnected` also checks enough_mail's `isConnected` and reconnects if
  it's false. This affects **every** IMAP operation.
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
