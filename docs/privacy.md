# KISDesk — Privacy, Security & Legality Assessment

> **Verdict up front: distributing the app is legal.**
> The app stores the Campus-ID only locally, sends it only to official TH Köln servers,
> and the developer never sees any user data — so German/EU privacy law places
> essentially no data-protection obligations on the distributor.
>
> *Assessment date: 14 July 2026 · Not legal advice, but based on primary sources (linked throughout).*

---

## 1 · How the app handles credentials — the technical facts

### The login (SAML SSO)

The app drives the **official TH Köln single sign-on** in a headless WebView:

```
Device ──TLS──▶ spaces.kisd.de          (clicks "TH Login")
       ──TLS──▶ login.th-koeln.de       (fills Campus-ID into the official form)
       ──TLS──▶ mfa.th-koeln.de         (user types the OTP themselves)
       ──TLS──▶ spaces.kisd.de          (logged in)
```

The password travels **exactly the route it travels in Safari** — device → TH Köln
identity provider, TLS-encrypted, no intermediary. There is no developer server
anywhere in the chain.

### Storage

| What | Where | Notes |
|---|---|---|
| Campus-ID username + password | **iOS Keychain** | Hardware-backed encryption; device-only (excluded from iCloud sync & backups) |
| Session + MFA "trust this device" cookies | **iOS Keychain** | Enables skipping the OTP for ~2 weeks; revocable in the TH MFA portal |
| Confirmed sender email | **iOS Keychain** | |
| Data owner (Campus ID the local data belongs to) | **iOS Keychain** | Lets a login with a different Campus ID wipe the previous account's data first |
| Courses, favourites, theme | Local app storage | No personal data beyond course choices |
| Liked/unliked courses (added 14 October 2026) | Local app storage (`kisd_course_choices`) | The user's explicit heart taps (course id, title, time), kept apart from the scraped course list so refreshes, cache schema bumps and semester switches can't reset them. Wiped by the account-switch teardown like the courses |
| Mail lists: newest 200 inbox rows, 100 each of Sent/Drafts/Trash (envelope, flags, size, 500-byte preview); raw bodies of the newest 50 inbox mails ≤ 5 MB each (moved 13 October 2026) | App storage (`Library/Application Support/mail_store`, one `<folder>.json` per folder + `<uid>.eml`) | Folders show at once; offline reading. Persistent (iOS doesn't purge it, unlike the previous `Library/Caches/mail_offline`, which is moved over once and then gone). Excluded from iCloud/computer backups via `URLResourceValues.isExcludedFromBackup` (`kisd/storage` channel in `AppDelegate.swift`); iOS default Data Protection. Owner Campus ID stored alongside; wiped by the account-switch teardown (`MailService.resetForAccountSwitch`). Never leaves the device |
| KISD events + hidden recurring events (added 14 October 2026) | Local app storage (`kisd_events_v2`, `kisd_events_hidden_v1`) | Public university events from Spaces, and the event ids (`post-NNNN`) of recurring ones switched off under Settings › Calendar › Recurring events. Nothing personal; a device setting, kept on account switch |
| Mensa menu, current + next two weeks | Local app storage | Public data, offline reading |
| Compose attachments (added 13 October 2026) | App cache folder (`Library/Caches/compose_attachments/<session>`) | Copies of the photos/files/scans picked for the mail being written. Deleted when the compose sheet closes. Picked via PHPicker (out of process — no photo-library permission), UIDocumentPicker, the camera or VisionKit's scanner (`NSCameraUsageDescription`). Sent only over SMTP to TH Köln, and APPENDed to the user's own Sent/Drafts. Metadata (EXIF/GPS) is kept unless Settings › Mail strips it — on device, when the file is added (local app storage `mail_metadata_strip`, `mail_metadata_sources`) |
| Opened mail attachments (added 13 October 2026) | Temporary folder (`tmp/mail_attachments/<id>`) | Copies of a received or sent mail's attachments, written when one is tapped so Quick Look can show it. Deleted when the message view closes; iOS also purges `tmp/`. Nothing leaves the device |
| New-mail notifications (added 15 October 2026) | Local app storage (`mail_notify_enabled`, `mail_notify_mark_v1`, `mail_notify_paused`, `mail_check_log_v1`) and iOS Notification Centre | Off until switched on under Settings › Notifications. Stored: the opt-in, the Campus ID + inbox UIDVALIDITY + highest mail UID already announced or shown (so nothing is announced twice), a pause flag set when the server refuses the stored password, and the times and outcomes of the last 100 background checks (no addresses, no subjects). The notifications themselves (sender, subject, preview) are posted locally — nothing passes through Apple's push service or any other server. The opt-in is a device setting; the rest and the delivered notifications are wiped by the account-switch teardown |
| SMTP size limit (added 13 October 2026) | Local app storage (`mail_smtp_max_size`) | The server's announced EHLO `SIZE` — a server property, nothing personal. Read by an unauthenticated EHLO probe when the first attachment is added |
| TOTP / 2FA secret | ❌ **never stored** | The user types each one-time code |

This is the same storage mechanism Apple Passwords uses. Signing out wipes all of it.

**Account switch (added 8 October 2026):** sign-out and a *successful* login with a different Campus ID share one teardown (`lib/services/account_teardown.dart`). It also clears the previous account's courses, local calendar store and its iOS "KISD" calendar mirror, pending reminders, and mail state. Before this, a rejected-login → different-Campus-ID path left the previous account's courses visible for up to 24 h. The comparison runs only after authentication succeeds, so a mistyped Campus ID can never delete data. Public data (KISD events, Mensa) and device settings are kept.

### Network connections — the complete list

| Destination | Protocol | What is sent |
|---|---|---|
| `login.th-koeln.de`, `mfa.th-koeln.de` | HTTPS (SAML) | Credentials — into the official login form only |
| `spaces.kisd.de` | HTTPS | Session cookies |
| `imap.intranet.fh-koeln.de:993` | IMAP over TLS | Credentials, mail. While the app is in the foreground the main connection stays open and waits in IMAP IDLE on the inbox, so new mail shows at once (polls every 60 s instead if the server lacks IDLE); it is ended when the app goes to the background and replaced after 10 min away (added 13 October 2026). After an inbox fetch, a second short read-only session (EXAMINE + `BODY.PEEK[]`) logs in with the same stored credentials to download the newest mails for offline reading (added 12 October 2026; since 13 October 2026 reused for up to 4 min, so mail arriving one by one doesn't cost a login each). Opening a mail runs another read-only session (EXAMINE + `UID SEARCH` + `BODY.PEEK`, same credentials) that finds the other mails of its conversation in Inbox and Sent; the result is kept in memory only, never written to disk (added 13 October 2026). With new-mail notifications on, iOS lets the app run a short background check every so often (BGAppRefresh/BGProcessing — iOS decides when): one read-only session with the same stored credentials (EXAMINE INBOX + `BODY.PEEK` of the list rows of mail newer than the last one announced), then logout. It is the same server and the same data the foreground sync fetches; it stops after a refused login until the app logs in again (added 15 October 2026) |
| `smtp.intranet.fh-koeln.de:587` | SMTP + STARTTLS | Credentials, mail (TLS established **before** auth). Since 13 October 2026 also a size-limit probe (connect, EHLO, STARTTLS, QUIT — no credentials, nothing sent) the first time an attachment is added |
| `openmensa.org` | HTTPS | Canteen number + date — nothing personal |

**Nothing else.** No analytics, no crash reporting, no telemetry, no font CDNs
(fonts are bundled). The truthful App Store privacy label is **"Data Not Collected."**

---

## 2 · The law

### 🇪🇺 DSGVO / GDPR — the distributor is *neither controller nor processor*

Under the [EDPB Guidelines 07/2020 on controller and processor](https://www.edpb.europa.eu/our-work-tools/our-documents/guidelines/guidelines-072020-concepts-controller-and-processor-gdpr_en),
those roles attach to whoever **actually processes** personal data in a specific
context — *not* to whoever wrote the software. Because credentials and mail never
reach the developer and he has no technical means to access them, the data
processing happens **between the student and TH Köln**; the app is merely the
student's local tool.

> **Legal footing = a password manager or Thunderbird.** Universities tell students
> to put these exact credentials into Apple Mail every day. A local app that acts
> as the user's agent on the user's device is the same legal category.

What German supervisory-authority practice still expects
([Bayerisches LDA, Orientierungshilfe Apps](https://www.lda.bayern.de/media/oh_apps.pdf)):
a **privacy policy** (✅ `PRIVACY.md`, EN + DE) and **privacy by design** (✅ local-only,
Keychain, data minimisation).

### 🏛️ TH Köln's own rules — they bind the *student*, and aren't violated anyway

From the [Benutzungsordnung für die zentralen IT-Services, Amtl. Mitteilung 43/2021](https://www.th-koeln.de/mam/downloads/deutsch/hochschule/amtlichemitteilungen/amtliche_mitteilung_nummer_43.pdf):

- **§ 5 (2) Nr. 8** — users must ensure "keine anderen **Personen** Kenntnis von den
  Benutzerpasswörtern erlangen." A local app that never discloses the password to
  any person is not a disclosure to a *Person*.
- **§ 8 (2)** — users are liable for "**Weitergabe der Benutzerkennung an Dritte**."
  The distributor never gains use of the account, so nothing is *weitergegeben* —
  any reading strict enough to catch this app would also outlaw Apple Mail.
- These terms regulate the **user's** relationship with Campus IT. The distributor
  is not a party to them. His exposure is institutional goodwill, not liability.

### 🛡️ Why the Spaces admin's concern is still legitimate (and what it really is)

His instinct is the canonical rule from [RFC 8252 — OAuth 2.0 for Native Apps](https://datatracker.ietf.org/doc/html/rfc8252):
apps should use the **system browser** for SSO, because an app that embeds the
login **could technically read** the credentials. IT departments cannot audit
third-party apps from outside, so they must treat every embedded-login app as a
question of **trust in its author** — regardless of what the app actually does.

He is applying the correct professional heuristic. It just happens that in this
app the answer is benign: nothing is exfiltrated, and that claim is verifiable
(and becomes *provable* if the repository is made public).

### 📱 Apple App Store

- **Guideline 5.1.1**: privacy policy required (✅) and a truthful privacy
  nutrition label — here the rare, clean **"Data Not Collected."**
- The realistic review risk is **not privacy** but 4.2 / 5.2.x: an unofficial app
  using a university's name may draw a question about naming rights. Be prepared
  to present it as an unofficial student project (and consider the app's display name).

### ⚖️ Precedent: Studo

[Studo](https://studo.com/en/privacy) — a commercial student app at German and
Austrian universities — asks for university credentials and even **routes traffic
through its own servers** (strictly more invasive than KISDesk's fully-local
design). It has distributed lawfully on both app stores for years; initial
university warnings later became partnerships in several cases. KISDesk
sits at the *conservative* end of an already-accepted category.

---

## 3 · Verdict

| Question | Answer |
|---|---|
| Does DSGVO block distribution? | **No** — no controller/processor role; policy + privacy-by-design satisfied |
| Do TH Köln's terms block it? | **No** — they bind users and aren't breached by a local tool |
| Does Apple block it? | **No** — clean privacy story; only naming (4.2/5.2.x) worth preparing for |
| Is Keychain storage a security flaw? | **No** — it's the platform-recommended mechanism, same as Apple Passwords |
| What risk remains? | **Reputational, not legal**: the university may discourage use; every future update must keep the "Data Not Collected" promise (no analytics SDKs, no new endpoints, no credential logging — ever) |

**The strongest remaining move:** make the repository public and link it from the
privacy notice. *"Don't trust me — read the code"* is the only complete answer to
the RFC 8252 trust problem, and directly addresses the admin's actual concern.

---

### Sources

[EDPB Guidelines 07/2020](https://www.edpb.europa.eu/our-work-tools/our-documents/guidelines/guidelines-072020-concepts-controller-and-processor-gdpr_en) ·
[TH Köln Benutzungsordnung 43/2021 (PDF)](https://www.th-koeln.de/mam/downloads/deutsch/hochschule/amtlichemitteilungen/amtliche_mitteilung_nummer_43.pdf) ·
[RFC 8252](https://datatracker.ietf.org/doc/html/rfc8252) ·
[Bayerisches LDA — Orientierungshilfe Apps (PDF)](https://www.lda.bayern.de/media/oh_apps.pdf) ·
[activeMind — Datenschutz bei Apps](https://www.activemind.de/magazin/datenschutz-app-entwickler-anbieter/) ·
[Studo Privacy](https://studo.com/en/privacy) ·
[Studo University Login FAQ](https://faq.studo.com/en/articles/3758574-university-login) ·
[William Denniss — In-app browsers and RFC 8252](https://wdenniss.com/in-app-browsers-and-rfc-8252)
