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

## Architecture overview

iOS-only Flutter app for KISD (Köln International School of Design) students. Scrapes the university's Spaces platform for course data, surfaces a Gmail-style IMAP mail client, and writes course schedules to the device calendar.

### Entry point & navigation

`main.dart` initialises `ThemeService` and `LoginService`, then renders `AppRoot`. `AppRoot` shows `LoginScreen` until credentials exist and login succeeds, then switches to `HomeScreen`.

`HomeScreen` owns:
- A `PageView` (non-swipeable) with three pages: `MailScreen` (index 0), `ListScreen` (index 1), `CalendarScreen` (index 2). Default page is `ListScreen`.
- A slide-up **Spaces browser overlay** (`BrowserSheet`) driven by an `AnimationController`. A mini bar floats above the tab bar when the overlay is collapsed. Any code that needs to open a URL calls `SpacesBrowser.open(url)` — the `HomeScreen` registers itself as the handler.

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

## GBrain Configuration (configured by /setup-gbrain)
- Mode: local-stdio
- Engine: pglite
- Config file: ~/.gbrain/config.json (mode 0600)
- Setup date: 2026-05-26
- MCP registered: yes (user scope, `/Users/luca/.bun/bin/gbrain serve`)
- Artifacts sync: full → https://github.com/lucaschiffer-ship-it/gstack-artifacts-luca.git
- Current repo policy: read-write (github.com/lucaschiffer-ship-it/KISDCalendar)

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
