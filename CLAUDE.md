# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## gstack (REQUIRED — global install)

**Before doing ANY work, verify gstack is installed:**

```bash
test -d ~/.claude/skills/gstack/bin && echo "GSTACK_OK" || echo "GSTACK_MISSING"
```

If GSTACK_MISSING: STOP. Do not proceed. Tell the user:

> gstack is required for all AI-assisted work in this repo.
> Install it:
> ```bash
> git clone --depth 1 https://github.com/garrytan/gstack.git ~/.claude/skills/gstack
> cd ~/.claude/skills/gstack && ./setup --team
> ```
> Then restart your AI coding tool.

Do not skip skills, ignore gstack errors, or work around missing gstack.

Using gstack skills: After install, skills like /qa, /ship, /review, /investigate,
and /browse are available. Use /browse for all web browsing.
Use ~/.claude/skills/gstack/... for gstack file paths (the global path).

---

## Git & Push Conventions

- This repo has TWO remotes. Every commit must be pushed to BOTH remotes:
  ```bash
  git push origin <branch> && git push public <branch>
  ```
  (`origin` = `lucaschiffer-ship-it/KISDCalendar`, `public` = `lucaschiffer-ship-it/kisd-calendar`)
- Default to ONE commit containing all dirty changes unless explicitly asked for multiple commits. Do not over-scope or split commits.
- Never create a commit that includes credentials, tokens, or `.env` files; check `.gitignore` coverage first.

---

## Commands

```bash
flutter pub get          # install dependencies
flutter run              # run on connected iOS device / simulator
flutter build ios        # production iOS build
flutter analyze          # lint / static analysis
flutter test             # run tests
```

There is no separate lint config beyond the default `analysis_options.yaml` (`flutter_lints`).

---

## Flutter / iOS Build Verification

- After any multi-file change, run `flutter analyze` and then a build (`flutter build ios --simulator` or `flutter run`) before declaring done.

### Self-verifying UI loop

Verify visual work yourself — do not ask for a screenshot. Never iterate blind on styling hypotheses; look at the actual result instead.

Set a scratch dir first — `$CLAUDE_JOB_DIR` is only set inside background jobs, and an unset one silently collapses to bare `/tmp`, which parallel jobs clobber:

```bash
OUT="${CLAUDE_JOB_DIR:-.claude}/tmp"; mkdir -p "$OUT"
```

1. **Run the app** in the background (verified UDID: `EC80B6FF-246B-44EF-AE0E-A10A3B9772CE` = iPhone 17 Pro):
   ```bash
   flutter run -d <sim-udid> --pid-file="$OUT/flutter.pid" > "$OUT/flutter_run.log" 2>&1
   ```
2. **Reload after each change, and confirm the reload actually landed** — this is the freshness guard, because `xcrun simctl io booted screenshot` succeeds even with no `flutter run` attached, silently returning the previously installed build. A stale shot is indistinguishable from a successful verification of the *pre-change* UI:
   ```bash
   before=$(grep -c "^Reloaded" "$OUT/flutter_run.log")
   kill -SIGUSR1 $(cat "$OUT/flutter.pid")          # SIGUSR2 = hot restart
   until [ "$(grep -c '^Reloaded' "$OUT/flutter_run.log")" -gt "$before" ]; do sleep 1; done
   ```
   Do **not** use `cmp` on consecutive screenshots for this — the header and iOS status bar both render a live clock, so any two shots differ regardless of whether the reload landed. That guard always passes and is worthless here.
3. **Screenshot and look:**
   ```bash
   xcrun simctl io booted screenshot "$OUT/shot-NN.png"
   ```
   Then `Read` the PNG and actually inspect it against what was asked.
4. **Iterate up to ~4 cycles**, then report with what you actually see — matched, or stuck and why.

**Prerequisite:** `ios/Runner.xcodeproj/xcshareddata/xcschemes/Runner.xcscheme` LaunchAction must be `buildConfiguration = "Debug"`. On `Release` the Runner scheme exposes no simulator destinations at all and `flutter run` fails with *"Unable to find a destination matching the provided destination specifier"*.

---

## Architecture overview

iOS-only Flutter app for KISD (Köln International School of Design) students. Scrapes the university's Spaces platform for course data, surfaces a Gmail-style IMAP mail client, and writes course schedules to the device calendar.

### Entry point & navigation

`main.dart` initialises `ThemeService` and `LoginService`, then renders `AppRoot`. `AppRoot` shows `LoginScreen` until credentials exist and login succeeds, then switches to `HomeScreen`.

`HomeScreen` owns:
- A `PageView` (non-swipeable) with three pages: `MailScreen` (index 0), `ListScreen` (index 1), `CalendarScreen` (index 2). Default page is `ListScreen`.
- A slide-up **Spaces browser overlay** driven by an `AnimationController`. A mini bar floats above the tab bar when the overlay is collapsed. Any code that needs to open a URL calls `SpacesBrowser.open(url)` — the `HomeScreen` registers itself as the handler.

**Safe-area insets inside HomeScreen: `ScreenInsets.of(context)`** (`lib/widgets/page_floating_actions.dart`, pinned by `test/screen_insets_test.dart`), never MediaQuery and never `View.of` directly. The Scaffold strips the top (appBar) and bottom (bottomNavigationBar) padding off the pages' MediaQuery. `View.of` never rebuilds on an insets change, and the pages are built once (`_pages`), so a page built while iOS still reported zero insets at launch kept its header under the status bar until the app was killed.

### Spaces browser (iOS platform view)

The browser is **native Swift**, not Dart: its chrome is real iOS 26 Liquid Glass
(`UIGlassEffect`), which only samples web content when it is a sibling of the
`WKWebView` in the same UIView hierarchy. (Flutter's own `BackdropFilter` *does*
blur a platform view — the engine's `PlatformViewFilter` turns it into a native
gaussian blur, verified on iOS 26.4 / Flutter 3.41 — but only plain blur, never
Liquid Glass, and only a `ClipRRect`'s first corner radius.) Three files:

| File | Role |
|---|---|
| `lib/widgets/native_spaces_browser.dart` | `UiKitView` + method channel `kisd/spaces_browser_<viewId>` |
| `ios/Runner/SpacesBrowserPlatformView.swift` | Two `WKWebView`s (pinned home tab + content tab), nav delegate, pull-to-dismiss, KVO, omnibox query resolution |
| `ios/Runner/SpacesBrowserChrome.swift` | Glass chrome: three bottom pills, status-bar scrim, progress bar |

The chrome is a four-state machine — `rest` / `collapsed` / `menu` / `editing`:

- **rest**: `[≡] [ host ] [⌄]` as three separate `GlassSurface` pills.
- **collapsed** (scroll-driven, Safari-style): side pills fade out, the address pill shrinks to a centred host pill.
- **menu**: ≡ widens into a back/forward pill and a stack of action pills (`+` add to course, reload, open in Safari) springs up above it, staggered bottom-to-top.
- **editing**: the address pill flies to the middle of the space above the keyboard, the page dims, the full URL is pre-selected. Submitting resolves scheme → bare host → DuckDuckGo search (`resolveQuery`).

Gotchas that will bite:

- **`hitTest` is per-state** (`SpacesBrowserChrome.hitTest`). `rest`/`collapsed` return `nil` outside the live pills so the page keeps its scrolls and links; `menu`/`editing` claim the whole bounds so a tap outside dismisses. Adding a pill without adding it to the right state's list makes it silently untappable.
- **Use a tap recogniser on a pill, not a `UIButton` pinned inside it.** Buttons nested in the menu stack's pills never receive `touchUpInside` — the hit stops at the pill's `contentView`.
- **Never give the address pill a permanent bottom anchor.** It owns its vertical placement per state; a stray bottom constraint fights the editing centre and stretches the pill to fill the screen.
- **The hidden `urlField` still votes on the collapsed pill's width.** It is pinned to both of the pill's edges in the *permanently-active* list, and a `UITextField` resists horizontal compression at 750 down to its intrinsic width — its **placeholder** (~180 pt) while the text is empty. `isHidden` does not exempt it: only a `UIStackView` drops hidden *arranged* subviews. Left at 750 it outranks `hostLabel`'s deliberately-lowered 250 and pins the pill open at placeholder width, which makes every `hostLabel`-derived width constraint a silent no-op — the label stretches inside a pill that never moves, so tuning that constant looks like it does nothing (and a negative constant makes the label overhang instead). Hence the explicit 249 on `urlField`. Symptom to recognise: the collapsed pill changes height but never width.
- `bottomContentInset` is constant across all four states, so `updateContentInsets()` never re-runs on both webviews for a transient overlay.
- The `\.url` KVO emits `onUrlChanged` to Dart for the **content tab only**; the chrome's host label is a separate native-only path (`chrome.setURL`). Widening that guard corrupts `_lastTabUrl` tracking.
- Geometry constants `pillHeight 50` and `bottomInset 32` are duplicated from `lib/widgets/page_floating_actions.dart`. Change both or the toolbar desyncs from the app's bottom cluster. `sideInset` (34) is the one deliberate exception — it matches Safari's own toolbar margin instead of the app's `_kSideInset` (12), so the browser's side pills sit further from the edge than the rest of the app's floating buttons on purpose. The collapsed pill has its own shorter height (`collapsedHeight 32`) and bottom inset (`collapsedBottomInset 14`), also matched to Safari rather than the resting toolbar's values.

### Attaching a page to a course

The ≡ menu's `+` sends `onAddToCourse {url, title}` to Dart, which gates on
`_isTrackablePage` and shows `AddToCourseSheet` (a Flutter overlay inside the
sheet's `Stack` — deliberately **not** glass; the native chrome around it is
Liquid Glass, which Flutter can't match).

`lib/services/course_link_attach.dart` owns the rules, pinned by
`test/course_link_attach_test.dart`:

- Real Spaces course URLs are **single-segment** (`spaces.kisd.de/<slug>/`) — a `/courses/`-style path test classifies every real one as `other`.
- A course-space link overtakes a lone `Course selection` link, because `links.first` is the primary everywhere (`CourseShellCard._openPrimary`, `EventStore`, `PagePrefetcher`).
- Writes go through `CacheService.addShell` — `updateShell` silently no-ops on a missing id.
- `editedFields` gains `'links'`, without which the next `scrapeMyCourses` drops the attachment. One-way door: that course's links stop tracking Spaces.
- The write bumps `CourseUpdates.instance.revision`, which `ListScreen` listens to and reloads from. **Load-bearing:** `ListScreen` rewrites the whole cache array from its in-memory `_shells` on every heart tap, so without the reload an attached link is silently clobbered by the next ♥.

### Global singletons (`lib/services/service_locator.dart`)

| Symbol | Type | Purpose |
|---|---|---|
| `loginService` | `LoginService` | TH Köln SAML SSO via headless WebView |
| `mailService` | `MailService` | IMAP client (enough_mail) |
| `scraperService` | `ScraperService` | Scrapes spaces.kisd.de for courses |
| `navigatorKey` | `GlobalKey<NavigatorState>` | Used by LoginService for MFA dialog |

### Authentication flow (`LoginService`)

Headless `InAppWebView` drives the full SAML/OAuth2 flow against `login.th-koeln.de` and `mfa.th-koeln.de`. Credentials are stored in `FlutterSecureStorage`. On subsequent launches it tries to restore saved cookies first; only if session validation fails does it run the full SAML flow. MFA (TOTP) prompts a dialog via `navigatorKey`.

### Course scraping (`ScraperService`)

Uses a headless `InAppWebView` + `callAsyncJavaScript` to extract course cards from `spaces.kisd.de/course-selection`. Two scrape paths:

- **`scrapeMyCourses()`** — fast path, `?mycourses=on`. Sets `isMyCourse: true` for all results. Keeps cached user edits and one-off events (`withCachedOverrides`), and **keeps every cached non-enrolled course** (`carryOver`), so courses liked from "All" stay listed and in the calendar until the all-courses scrape refreshes them. Saving only the enrolled courses here is what used to unlike them on every daily refresh. Writes cache and device calendar.
- **`scrapeAllCourses()`** — slow path, full listing. Skips only enrolled + own titles. `mergeAll` keeps enrolled/own courses as cached, takes non-enrolled ones fresh (with cached edits), and keeps a **liked** course Spaces no longer lists. It writes the calendar only when a liked non-enrolled course is in the result.
- The merge rules live in `lib/services/course_merge.dart`, pinned by `test/course_merge_test.dart`.

Both paths fetch per-course detail pages for location and Spaces URL via a separate `fetch()` call injected into the same WebView.

### KISD events (`scrapeKisdEvents` → `CalendarService.writeKisdEvents`)

University events come from the Event Organiser list in wp-admin (`/home/wp-admin/edit.php?post_type=event…`), are cached (`kisd_events_v2`) and written to the iOS calendar "KISD Events", which the in-app calendar reads back. Parse helpers pinned by `test/kisd_events_test.dart`. Gotchas:

- **Markup (Oct 2026):** the Event cell is a `<th data-colname="Event">` — select by attribute, never `td[...]` (that matched nothing and emptied the calendar). Empty cells hold `—` plus a `.screen-reader-text` label ("No Venue"); read them with `visibleText`. All-day events show the date with no time line → `allDay`.
- The list is paged; the scrape follows `a.next-page` (401 events at 400 per page dropped one).
- **Zero events is a failure, never a result:** it throws, so nothing is saved — an empty save wipes the calendar and sets the 24 h stamp. An empty cache counts as stale at launch.
- `writeKisdEvents` wipes and rewrites, one write at a time (later calls queue). The wipe deletes each event id once: every occurrence of a series shares its id, and the first delete removes the series.
- Recurring events the user switched off (Settings › Calendar › Recurring events, `kisd_events_hidden_v1`, by `post-NNNN` id) are filtered at write time. Deleting in Apple Calendar never sticks — the next refresh rewrites everything.
- Only weekly patterns become an RRULE; "custom recurrence" / "every day" are written as their first date. If those ever matter: `admin-ajax.php?action=eventorganiser-fullcal&start=…&end=` returns every occurrence as JSON (logged-in session).
- EventKit ends an all-day event at 23:59:59 of its last day; `getAllDayEventsForRange` takes the last day from end − 1 s.

### Cache (`CacheService`)

`SharedPreferences`, key `kisd_courses`, JSON array. Bump `_currentVersion` (currently `14`) whenever the stored schema changes — the app clears and re-scrapes on version mismatch.

**Hearts** (`lib/services/course_choices.dart`, pinned by `test/course_choices_test.dart`):
- `CourseChoices` (SharedPreferences `kisd_course_choices`) is the record of the user's explicit heart taps, by course id only (no title fallback: same-named courses, or the next semester's, would share a heart).
- `isFavourite` = its choice ?? the default (enrolled liked, the rest not). Every list on its way to the screen, cache or calendar passes through `apply`: `loadCached`, both scrapes.
- It is written only by `ListScreen._onFavouriteChanged`, never by scrapes. It survives schema bumps and semester switches; `AccountTeardown` clears it.
- Its first run seeds it from the cache (hearts that differ from their default), so `ListScreen._init` loads it *before* the schema check may clear the cache.
- The list screen still writes the cache via `scraperService.saveToCache(_shells)` on a heart tap; the card widget itself does **not** write to cache directly.

### Theme system

Two layers:

1. **`lib/theme/app_theme.dart`** — static `AppColors`, `AppSpacing`, `AppTextStyle` (Space Grotesk + Inter via `google_fonts`), `AppCard`, `buildDarkTheme()`. These are compile-time constants used throughout.

2. **`lib/config/app_theme.dart` (`AppThemeTokens`)** — dynamic tokens that read `ThemeService.instance.currentColor` and `currentStyle` at call time. Every getter is a `switch` over the color key (`'dark'` / `'light'` / `'pastel'`) or style key (`'vivid'` / `'minimal'`). Widgets that need to react to theme changes wrap with `AnimatedBuilder` or `ValueListenableBuilder` on `ThemeService.instance.currentColor`, `currentStyle`, and `glassEnabled`.

`ThemeService` is a singleton with three `ValueNotifier`s (color, style, glass). `glassEnabled` activates `BackdropFilter` blur on cards and nav bars via `AppThemeTokens.glassContainer(...)`.

### `CourseShell` model

`isMyCourse` — enrolled via spaces.kisd.de  
`isFavourite` — heart-toggled by the user (defaults to `true` for enrolled courses); the tap is recorded in `CourseChoices`, which every scrape respects  
`isLiked` — unused legacy field (kept for JSON round-trip compatibility)  
`id` — derived from the last URL path segment of the course/detail page, or a title slug as fallback

The `ListScreen` pre-computes three filtered lists (`_myCourses`, `_favourites`, `_allCourses`) in `_rebuildFilteredLists()` and switches between them based on `_filterMode`. `CourseShellCard` is stateful; `_liked` mirrors `widget.shell.isFavourite` and is synced via `didUpdateWidget`.

The list search bar uses typo-tolerant fuzzy matching (`fuzzy` package, a Fuse.js port) over course title and lecturer — see `_fuzzySearch()` in `list_screen.dart`. Tuning knob: if matches feel too loose or too strict, adjust `threshold` there (currently `0.35`; lower = stricter, `0` = near-exact, the package default of `0.6` is far too loose). Behaviour is pinned by `test/fuzzy_search_test.dart`.

### Mail (`MailService`)

IMAP via `enough_mail`. Credentials reused from `LoginService` (TH Köln email). Surfaces unread count to `HomeScreen` for the badge on the Mail tab.

**Main connection** (`lib/services/imap_session.dart`, pinned by `test/imap_session_test.dart`): every command on the main connection goes through `_run` → `ImapSession.run` — one op at a time, so a `SELECT` and its `FETCH` can't be split by another caller (that split, and two callers reconnecting at once, made Sent/Inbox come up empty). Gotchas:

- **Ops never call ops** (it would wait for itself — asserted). Anything that runs its own ops (`accountEmail`, message building) happens *before* the op. Internal helpers take the `ImapClient` as a parameter.
- **Ops return data, the caller applies it** — an op abandoned by its timeout may still be running.
- Each op has a timeout; a timeout or a closed socket drops the connection. Only idempotent ops (fetch, select, flags, draft expunge) are retried; APPEND/MOVE are not (they may have landed). A connection quiet > 60 s is NOOP-probed first.
- **IDLE** runs on the main connection, inbox selected, once the queue has drained 1.5 s (`_onSessionDrained`); the session's `prepare` (`_leaveIdle`) sends DONE before any op. Re-armed every 8 min; ended on hide; replaced after 10 min in the background. Without the IDLE capability: a 60 s poll. Server events count only while idling (our own responses carry EXISTS too). Never open a connection *just* to idle (login rate limit).
- Automatic refreshes back off after a failed connect; a refused login stops them until the user pulls to refresh.

**Folder sync** (`lib/services/mail_sync.dart`, pinned by `test/mail_sync_test.dart`): `refreshFolder` selects the folder, then fetches either the newest 50 (new list) or a delta — `UID FETCH <lowest>:* (UID FLAGS)`, then the list rows of the new UIDs. Flags are updated **in place** (row objects and `MailActions` keys survive). An empty folder fetches nothing: `FETCH 1:0` is a BAD. `loadOlder` (list scrolled to its end) runs the delta and then the 50 sequence numbers below the oldest listed message (its number comes with the delta's FLAGS answer) in one op. Before IDLE starts, the inbox's EXISTS/UIDNEXT are compared with the last sync: mail that came while nothing idled is never announced again. Opening a folder refreshes it unless it was synced < 30 s ago.

**Offline copy** (`lib/services/mail_offline_cache.dart`, pinned by `test/mail_offline_cache_test.dart`): `Library/Application Support/mail_store`, excluded from backups (`kisd/storage` channel in `AppDelegate.swift`) — `<folder>.json` holds the list rows (envelope, flags, size, preview) of the newest 200 inbox / 100 Sent, Drafts, Trash mails, `<uid>.eml` the raw bodies of the newest 50 inbox mails (skipped above 5 MB). The pre-13-Oct-2026 `Library/Caches/mail_offline` is moved over once. `connect()` shows every folder's list before going online; `fetchFullMessage` reads it first for the inbox. Gotchas:

- **Bodies are inbox only.** UIDs are per mailbox; never read a body for Sent/Trash/Drafts.
- Bodies are downloaded on a **separate, EXAMINE'd `ImapClient` with `BODY.PEEK[]`** (kept 4 min for reuse) — a download would hold up the main connection's ops, and plain `BODY[]` would mark 50 mails read.
- Store bodies as **raw bytes** (`BinaryMimeData.data`), never via `renderMessage()` — it maps bytes to chars and mangles 8-bit umlauts.
- `resetForAccountSwitch` bumps `_generation`, replaces the session and clears the folder; every async fetch and cache step re-checks the generation so a sync in flight can't show or write the old account back.

### Mail UI (list, message view, compose)

Apple Mail–style, in the app's own tokens. The service logic stays as it was; the
UI keeps its own optimistic state on top.

- **Mail route layer** (`lib/widgets/mail_route_layer.dart`): an opened mail is
  pushed on `mailNavigatorKey`, a `Navigator` HomeScreen layers **between the pages
  and the browser sheet** — so `SpacesBrowser.open` from a mail shows the browser
  *over* it, and closing returns to the same mail. Only the mail page pushes there
  (`MailRouteLayer.push`); Settings and everything else stay on the root navigator.
  `MailRouteParallax` moves HomeScreen's pages + bottom cluster like the page behind
  an iOS push (a third left, dimmed) — its child structure must never change with
  the animation, or the pages lose their state.
- **Message view** (`email_detail_screen.dart` + `lib/services/mail_html.dart`,
  pinned by `test/mail_html_test.dart`): one HTML document holds the header *and*
  the body, so the header scrolls natively with the mail (`<details>` expands it —
  JS stays off). Loaded under `kisd-mail://local/` so the bundled fonts it serves
  via `resourceCustomSchemes` are same-origin (CORS); `cid:` inline images come
  from the same handler. `classifyMailHtml` decides dark mode: `themed` (simple
  mail, takes the theme), `darkNative` (its `prefers-color-scheme` queries are
  rewritten to the *app's* theme — the web view follows the system), `original`
  (designed newsletter: white rounded card in dark mode). Near-white backgrounds
  count as neutral — simple mails often carry `bgcolor="#ffffff"`. Only main-frame,
  link-activated navigations open anything. The web view mounts after the push and
  fades in; a Flutter replica of the header shows meanwhile. Attachment tiles
  are links to `kisd-mail://local/attachment/<i>` (`attachmentIndexOf`): a tap
  writes the mail's attachments to `tmp/mail_attachments/<id>` (deleted on
  close) and opens Quick Look via `ComposeAttachments.preview`.
- **Optimistic actions** (`lib/services/mail_actions.dart`): delete/restore hide the
  row and read flags flip at once; a failed server call rolls back with a toast.
  Calls per message are **serialised** — `markAsRead`/`markAsUnread` early-return on
  the *current* `isSeen`, so never mutate `isSeen` from the UI.
- **Swipe** (`lib/widgets/swipe_action_row.dart`, pinned by
  `test/swipe_action_row_test.dart`): short swipe rests open (80 pt), past 55 % of
  the width commits with a haptic; destructive actions collapse the row *before*
  their callback runs.
- **List previews** (`lib/services/mail_display.dart`, pinned by
  `test/mail_display_test.dart`): the list fetches `BODY.PEEK[TEXT]<0.500>`, which
  stock enough_mail drops (it splits `BODY[TEXT]<0>` and reads `0>` as the body).
  `PreviewFixImapClient` (`lib/services/imap_preview_fix.dart`, private enough_mail
  imports — re-check on any enough_mail upgrade) puts the bytes back, and
  `mailPreviewText` parses the headerless fragment (boundaries, QP, base64, HTML).
  HTML newsletters whose first 500 bytes are all `<head>`/CSS get their preview from
  the offline copy instead (`lib/services/mail_previews.dart`, background isolate).
- **Compose** (`compose_screen.dart`): `openComposeSheet` pushes a
  `CupertinoSheetRoute` on the **root** navigator (the whole app scales back). It
  can't be dragged away while dirty; ✕ offers Save Draft / Delete Draft. Drafts use
  the only service additions of the rework: `saveDraft()` (IMAP APPEND, like
  `_appendToSent`) and `discardDraft()` (expunge from Drafts). A reopened draft's old
  copy is discarded only after the new save/send succeeds.
- **Attachments** (`lib/services/mail_attachments.dart`, pinned by
  `test/mail_attachments_test.dart`; pickers in `ios/Runner/ComposeAttachmentsBridge.swift`
  via `lib/services/compose_attachments.dart`): `sendEmail`/`saveDraft` take
  `attachments`, and **an empty list must keep running the old
  `buildSimpleTextMessage` path untouched**. Every attachment step sits behind
  `attachments.isNotEmpty`. The one approved exception (13 Oct 2026): a reply's
  `In-Reply-To`/`References` are set on the built message on both paths
  (`applyReplyHeaders`, see Conversations). Gotchas:
  - Set the root to multipart/mixed explicitly and add the text with `addTextPlain`.
    `..text` + quoted-printable on the builder writes a QP `Content-Transfer-Encoding`
    onto the multipart root.
  - enough_mail writes `filename=` raw; `attachmentFilename` makes non-ASCII names
    RFC 2047 words (enough_mail's own `encodeHeader` labels them `utf8`, not `UTF-8`).
  - Sizes: tiles show file sizes, but the server's EHLO `SIZE` counts the base64'd
    mail (×~1.37). Limits are shown via `attachmentAllowance`. The SMTP send timeout
    scales with size only for attachment mails.
  - `X-KISD-Photo: 1` marks photo parts **in drafts only**, so a reopened draft can
    still offer Small/Medium/Large at Send.
  - A reopened draft (or forward) gates Send/Save on `_prepared` until its files are
    on disk; if the draft never loaded, its old copy is **kept** after send/save.
  - Attachment mails don't wait for their Sent copy: compose closes once SMTP accepts,
    and `_appendToSent` uploads in the background (text mails still await it).
  - **Metadata stripping** (Settings › Mail; `lib/services/attachment_metadata.dart`,
    pinned by `test/attachment_metadata_test.dart`, details in `docs/photo-metadata.md`)
    runs in place right after a *pick*, never at Send, and fails closed. Forwards and
    reopened drafts (`fromData`) are deliberately never stripped. `CGImageDestinationCopyImageSource` with only `ShouldExcludeGPS` silently
    drops **all** metadata incl. orientation; it needs a `kCGImageDestinationMetadata`
    entry. PNG ignores those options and is re-encoded instead.
- **Conversations** (`lib/services/mail_threads.dart`, pinned by
  `test/mail_threads_test.dart`; page in `mail_html.dart` `buildThreadDocument`,
  pinned by `test/mail_html_test.dart`): opening a mail looks up its
  conversation (`MailService.fetchThread`) and, with 2+ mails, shows them as
  `<details>` cards oldest first, the opened and the newest unfolded. The list
  stays one row per mail; Back and the bottom actions act on the opened mail.
  - The lookup runs on **its own client, folders EXAMINE'd, bodies via
    `BODY.PEEK[]`** (same reasons as the offline copy), one at a time, wrapped
    in a whole-call 25 s `.timeout()`; the client is replaced after 4 min idle.
    It searches Inbox and Sent with one `UID SEARCH` of ORed `HEADER
    Message-ID/References/In-Reply-To` and an ASCII-only `SUBJECT` term (no
    CHARSET literal); if the server refuses HEADER search it retries subject
    only. `conversationOf` decides: header links first, then same subject +
    a reply prefix + the same people — never older than the conversation's
    start (the latest mail that answers nothing). The start can join late, so
    it gathers twice: once to find the start, once with it as the cutoff.
  - The message view waits **3 s** (`_threadWait`) and otherwise shows the mail
    alone — and doesn't look up at all while `mailService.isConnected` is false,
    so offline opens stay instant; the lookup still finishes into an in-memory cache (8 entries,
    cleared when a sync adds or removes Inbox/Sent mail, a Sent copy landing and
    the account switch).
  - Offline bodies are only reused while the lookup's inbox UIDVALIDITY equals
    the list's, and only when the Message-IDs match.
  - Each mail's CSS is confined to `#kisd-b<i>` (`scopeMailCss`); external
    stylesheets are dropped. Attachment links are `attachment/<mail>/<i>`
    (`threadAttachmentOf`).
  - Quoted history folds behind "•••": Outlook's `divRplyFwdMsg`/`appendonsend`
    / Von-Gesendet block (everything after it), `gmail_quote`,
    `blockquote[type=cite]`, `moz-cite-prefix` (only when nothing is written
    below), and `splitQuotedPlain` for plain text. Forwards never fold.
  - Envelope-only entries (a body > 3 MB, or past 8 MB for the whole lookup,
    newest first, stays on the server): read date and
    subject from `envelope` — the `HEADER.FIELDS (REFERENCES)` fetch replaces
    the headers the envelope parse added.
- **Stale IMAP connection:** the server drops an idle connection without the
  socket noticing. `ImapSession` checks enough_mail's `isConnected`, probes a
  quiet connection and bounds every op with a Dart `.timeout()` (APPENDs
  size-scaled). Before this, a Sent copy after ~15 min idle hung compose forever.
  enough_mail's own `responseTimeout` only starts *after* the write, so the
  whole call needs the Dart timeout.

### New-mail notifications (`lib/services/mail_notifier.dart`, pinned by `test/mail_notifier_test.dart`)

Off by default (Settings › Notifications › Mail). Two announcers share one stored mark, `(owner, inbox UIDVALIDITY, upTo)`:

- **App open:** inbox refreshes started by IDLE, polling or the IDLE re-arm (`_autoRefresh(…, announce: true)`) post through `NotificationService.show`. Every other inbox sync (connect, resume, pull to refresh) only moves the mark, so mail the app has shown is never announced later. Quiet while the Mail page shows the inbox (`mailService.mailPageVisible`, set by HomeScreen).
- **Background:** `ios/Runner/MailCheckTask.swift` registers a BGAppRefresh and a BGProcessing task. Both are resubmitted (earliest in 15 min) on every run and every `didEnterBackground`, and iOS decides when they actually run. Each run starts a headless engine on `mailCheckMain` (`main.dart`), which calls `runMailBackgroundCheck` (`mail_background_check.dart`): its own client, EXAMINE, `BODY.PEEK`, a 20 s budget. A 27 s native watchdog backs it up.

Gotchas:

- **The background engine registers only secure storage and shared_preferences.** Never flutter_local_notifications: a second instance registers as an app delegate and takes the app engine's taps. Swift posts the notifications itself with the plugin's userInfo keys (`NotificationId`, `payload`, `present*`), so the app's plugin presents, routes and cancels them like its own.
- The two isolates share the mark, the log and the pause flag through `SharedPreferencesAsync`, which has no cache. Never move them to the legacy API with `reload()`: a reload in flight replaces the app's whole preferences cache and can drop another feature's write (a heart tap's course cache) made meanwhile. Only the opt-in is legacy, because Swift reads its `flutter.` key. `writeMark` never moves the mark back.
- No mark for this account and UIDVALIDITY (first check, account switch, renumbered inbox) announces nothing; the mark starts at the newest mail.
- A refused login is **not** proof of a wrong password: this server also answers "authentication failure" while it throttles logins. So the background check backs off (`mail_notify_backoff_v1`: 1 h, 2 h, 4 h, then 8 h) and retries by itself; any working login — the check's or the app's (`_noteAppLogin`) — ends the wait. The old indefinite pause (`mail_notify_paused`, dropped on read) silenced notifications for a day after one refusal. After 3 refusals in a row it posts one "paused" notice (`mailPausedNoticeId` = `mailIdMax`, which no mail's id uses; payload id `paused` just opens the inbox), removed by the next working login (`unpost` in `MailCheckTask.swift`).
- The check log keeps only `refusalCode` of a refusal (an RFC 5530 response code or a known phrase, else `other`) — never the server text, which can echo the username. The app adds `app logged in…` rows when its own login ends a wait or happens while not in the foreground; the log page skips them for the gaps.
- Notification ids are `mailIdMin + uid % span` (inside `mailIdMin..mailIdMax`); the payload id is `<uidValidity>:<uid>`. A tap opens the mail via `MailScreen._openFromNotification`, which waits up to 15 s for the list to have it. Root routes (compose, Settings) stay open, because a notification must never close a draft.
- BG tasks never run on the simulator. On a device, pause in Xcode and run `e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"de.th-koeln.kisd-calendar.mailcheck"]`. Settings › Notifications › Background checks lists the real run times.

### Mensa (`MensaService`)

openmensa.org, canteen 383. Network first; on failure falls back to an offline copy (SharedPreferences `mensa_offline_days`) of this week + the next two (Mon–Sun). `startOfflineSync()` (from `main.dart`) refreshes that window at launch and on resume, at most every 3 h after a complete pass. Pinned by `test/mensa_offline_test.dart`.

---

## Working Style

- Start with a short plan BEFORE exploring with subagents. Don't spend turns on tooling/environment setup (skills, upgrades, stack verification) unless asked.
- When the request is ambiguous about WHICH screen/component is meant, ask ONE targeted question up front rather than guessing and editing.
- Prefer the smallest possible change. Do not refactor, rename, or remove existing features (e.g. the 'heart' feature) as part of an unrelated fix.

---

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore

---

## Licensing & Privacy

- Do NOT default to MIT. This project ships under a restrictive source-available license (`LICENSE` — "KISD Calendar Source-Available License") — reuse the existing LICENSE file wording.
- Campus-ID credentials must be stored in the iOS Keychain / `flutter_secure_storage` only, never in `SharedPreferences` or logs. Any change touching auth requires a note in the privacy/DSGVO doc.

---

## Multi-Agent Git & Mobile Workflow Instructions

### 1. Mandatory Git Transparency (Explain Everything)
- Whenever you (Claude) need to use a git command, you MUST stop and explain your plan to the user in plain English first.
- Explain WHAT you are doing, WHY you are doing it, and the exact git command you plan to run.
- Wait for the user to say "Go" or approve before running destructive commands (like reset, rebase, or deleting branches).

### 2. Multi-Agent Git Isolation
- **Assume Concurrent Agents:** Assume other AI agents are working in this repository at the same time.
- **Worktree Safety:** Never modify files outside of your designated worktree or branch.
- **Branch Naming:** Create branches using the format: `agent-[feature-or-fix-name]-[date]`.
- **Atomic Commits:** Make small, logical commits. Do not bundle massive, unrelated changes into a single commit.

### 3. Mobile App Build & Test Isolation
- **Shared State Hazard:** Because multiple agents are building the phone app on the same machine, you must isolate your builds.
- **Build Caches:** Never use the global default build directories. Always append localized build paths to your commands (e.g., if using iOS/Xcode, use `-derivedDataPath .build/DerivedData-agent`).
- **Ports:** If starting a local server, Metro bundler, or API, dynamically assign a port (e.g., `8081`, `8082`) and explicitly state which port you are using so you do not crash other agents.
- **Headless Testing Only:** When running tests, ensure they are strictly headless. Do not launch visual UI simulators unless explicitly instructed, as they will steal window focus from the human user and other agents.

### 4. Ask Before Simulator/Multi-Agent Test Runs
- This file also has a **Self-verifying UI loop** workflow (see "Flutter / iOS Build Verification") that requires launching the iOS simulator and taking screenshots — that is in direct tension with "Headless Testing Only" above.
- Before running ANY simulator-based build/test (`flutter run`, `xcrun simctl ...`), STOP and ask the user:
  1. Are other agents currently active in this repo right now?
  2. Given that, should this run be headless-only, or is it safe to launch the simulator (verified UDID `EC80B6FF-246B-44EF-AE0E-A10A3B9772CE`) for visual verification?
  3. Is a specific `-derivedDataPath` / port already claimed by another agent that this run needs to avoid?
- Do not silently pick one rule over the other or guess at what other agents are doing — always confirm the current multi-agent situation first, then proceed with whichever mode the user approves.
