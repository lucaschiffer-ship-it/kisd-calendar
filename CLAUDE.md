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

### Spaces browser (iOS platform view)

The browser is **native Swift**, not Dart: a `UIVisualEffectView` only samples web
content when it is a sibling of the `WKWebView` in the same UIView hierarchy, so
Flutter's `BackdropFilter` can never blur a page. Three files:

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
- `bottomContentInset` is constant across all four states, so `updateContentInsets()` never re-runs on both webviews for a transient overlay.
- The `\.url` KVO emits `onUrlChanged` to Dart for the **content tab only**; the chrome's host label is a separate native-only path (`chrome.setURL`). Widening that guard corrupts `_lastTabUrl` tracking.
- Geometry constants `pillHeight 50` and `bottomInset 32` are duplicated from `lib/widgets/page_floating_actions.dart`. Change both or the toolbar desyncs from the app's bottom cluster. `sideInset` (34) is the one deliberate exception — it matches Safari's own toolbar margin instead of the app's `_kSideInset` (12), so the browser's side pills sit further from the edge than the rest of the app's floating buttons on purpose. The collapsed pill has its own shorter height (`collapsedHeight 32`) and bottom inset (`collapsedBottomInset 14`), also matched to Safari rather than the resting toolbar's values.

### Attaching a page to a course

The ≡ menu's `+` sends `onAddToCourse {url, title}` to Dart, which gates on
`_isTrackablePage` and shows `AddToCourseSheet` (a Flutter overlay inside the
sheet's `Stack` — deliberately **not** glass, since a `BackdropFilter` over a
platform view samples nothing).

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

- **`scrapeMyCourses()`** — fast path, `?mycourses=on`. Sets `isMyCourse: true` and `isFavourite: true` for all results. Preserves the user's explicit `isFavourite: false` toggles from cache **only if the cached entry was already `isMyCourse: true`** (prevents non-enrolled items accidentally suppressing the favourite default). Overwrites cache and writes to device calendar.
- **`scrapeAllCourses()`** — slow path, full listing. Skips titles already in cache. Merges with `_mergeShells()` (cached myCourse items take priority by ID then title). Re-reads the latest favourite state from cache before saving to avoid race-condition overwrites during the long scrape.

Both paths fetch per-course detail pages for location and Spaces URL via a separate `fetch()` call injected into the same WebView.

### Cache (`CacheService`)

`SharedPreferences`, key `kisd_courses`, JSON array. Bump `_currentVersion` (currently `11`) whenever the stored schema changes — the app clears and re-scrapes on version mismatch.

`isFavourite` is persisted per course. The list screen writes cache via `scraperService.saveToCache(_shells)` when the user toggles a heart; the card widget itself does **not** write to cache directly.

### Theme system

Two layers:

1. **`lib/theme/app_theme.dart`** — static `AppColors`, `AppSpacing`, `AppTextStyle` (Space Grotesk + Inter via `google_fonts`), `AppCard`, `buildDarkTheme()`. These are compile-time constants used throughout.

2. **`lib/config/app_theme.dart` (`AppThemeTokens`)** — dynamic tokens that read `ThemeService.instance.currentColor` and `currentStyle` at call time. Every getter is a `switch` over the color key (`'dark'` / `'light'` / `'pastel'`) or style key (`'vivid'` / `'minimal'`). Widgets that need to react to theme changes wrap with `AnimatedBuilder` or `ValueListenableBuilder` on `ThemeService.instance.currentColor`, `currentStyle`, and `glassEnabled`.

`ThemeService` is a singleton with three `ValueNotifier`s (color, style, glass). `glassEnabled` activates `BackdropFilter` blur on cards and nav bars via `AppThemeTokens.glassContainer(...)`.

### `CourseShell` model

`isMyCourse` — enrolled via spaces.kisd.de  
`isFavourite` — heart-toggled by the user (defaults to `true` for enrolled courses)  
`isLiked` — unused legacy field (kept for JSON round-trip compatibility)  
`id` — derived from the last URL path segment of the course/detail page, or a title slug as fallback

The `ListScreen` pre-computes three filtered lists (`_myCourses`, `_favourites`, `_allCourses`) in `_rebuildFilteredLists()` and switches between them based on `_filterMode`. `CourseShellCard` is stateful; `_liked` mirrors `widget.shell.isFavourite` and is synced via `didUpdateWidget`.

The list search bar uses typo-tolerant fuzzy matching (`fuzzy` package, a Fuse.js port) over course title and lecturer — see `_fuzzySearch()` in `list_screen.dart`. Tuning knob: if matches feel too loose or too strict, adjust `threshold` there (currently `0.35`; lower = stricter, `0` = near-exact, the package default of `0.6` is far too loose). Behaviour is pinned by `test/fuzzy_search_test.dart`.

### Mail (`MailService`)

IMAP via `enough_mail`. Credentials reused from `LoginService` (TH Köln email). Surfaces unread count to `HomeScreen` for the badge on the Mail tab.

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
