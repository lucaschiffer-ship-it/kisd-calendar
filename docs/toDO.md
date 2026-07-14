# ✅ toDO — Manual verification before distributing

The privacy hardening landed on 14 July 2026. Everything below is what **you**
still need to check on your physical iPhone (simulator is fine for most, but the
real device is the honest test). Tick things off as you go.

---

## 0 · One-time heads-up (expected, not a bug)

- [ ] **You will be logged out once.** The Keychain items are now written with a
  stricter "this device only" policy, and the old items can't be read under it.
  Just log in again — everything after that behaves as before.

---

## 1 · No secrets in the device log 🔴 *most important check*

The old build printed your **plaintext password** to the device console. Verify
the fix on a **release or profile build** (debug builds intentionally still log):

1. Build & run: `flutter run --release` (device connected).
2. On the Mac, open **Console.app** → select your iPhone in the sidebar → press
   **Start streaming** → filter on your app process (`Runner`).
3. In the app: sign out, then do a **full fresh login including the OTP**.
4. Watch the stream. There must be **no `[login]`, `[mail]`, or `[startup]` lines
   at all** in release. Specifically nothing containing your password, cookie
   values, or `SAMLResponse`.
5. Send a test mail too — no `[mail]` lines may appear.

**Pass =** the app logs nothing. **Fail =** any credential/cookie/SAML content
shows up → stop, report it back.

## 2 · Fonts work offline (no Google CDN)

Space Grotesk and Inter are now bundled; runtime fetching from Google is disabled.

1. **Delete the app** from the phone (clears any previously cached fonts — this
   is what makes the test valid).
2. Enable **Airplane Mode**.
3. Install & launch a fresh build.
4. Check headlines (Space Grotesk) and body text (Inter) on the list screen.

**Pass =** typography looks exactly like before while offline.
**Fail =** generic/system-looking font → the asset bundling isn't being picked up.

## 3 · Spaces browser still renders everything (ATS change)

App Transport Security was re-enabled app-wide (previously fully disabled); only
WebView *content* keeps an exception.

- [ ] Log in and browse **several course pages** in the Spaces overlay, including
  ones with images/embeds.
- [ ] Open a couple of **external links** from course pages.
- [ ] Check the **mensa menu** loads (openmensa.org now goes through full ATS).
- [ ] Send and receive **mail** (SMTP STARTTLS path unchanged, but confirm).

**Pass =** everything loads as before. **Fail =** blank pages/missing images that
worked before → tell me which URL; the fix is a scoped ATS exception, *not*
re-enabling `NSAllowsArbitraryLoads`.

## 4 · Logout really wipes everything

`logout()` now also clears WebView cookies and the stored sender address.

1. Log in fully (incl. OTP, so a trust-device cookie exists).
2. Sign out via **Settings**.
3. Relaunch the app.

**Pass =** you land on the login screen, and logging back in requires the **full
flow including a fresh OTP** (proves the trust-device cookie was wiped).
**Fail =** auto-login or OTP skipped right after sign-out.

## 5 · Regression sanity pass

Quick once-over that the hardening broke nothing:

- [ ] Course list scrapes and favourites toggle correctly
- [ ] Calendar entries still written to the device calendar
- [ ] Mail: inbox, sent, drafts, trash load; unread badge updates
- [ ] Theme switching (dark/light/pastel, glass) still instant

---

## Before you actually ship 📦

- [ ] Read `PRIVACY.md` (repo root) once yourself — it's the public notice; make
  sure every sentence is still true for the build you ship.
- [ ] App Store Connect: set privacy label to **"Data Not Collected"** and the
  privacy policy URL to wherever you host `PRIVACY.md`.
- [ ] Decide on **open-sourcing the repo** — strongest possible answer to the
  Spaces admin's concern (see `docs/privacy.md`, Verdict section).
- [ ] Consider the display name ("Kisd Calendar") — an unofficial app using the
  KISD name is the most likely App Review question, not privacy.
- [ ] Optional: show the admin `docs/privacy.md` + `PRIVACY.md` — it answers his
  concern point by point, in his own terms (RFC 8252).
