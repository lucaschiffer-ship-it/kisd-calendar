# KISD Calendar — Privacy, Security & Legality Assessment

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
| Courses, favourites, theme | Local app storage | No personal data beyond course choices |
| TOTP / 2FA secret | ❌ **never stored** | The user types each one-time code |

This is the same storage mechanism Apple Passwords uses. Signing out wipes all of it.

### Network connections — the complete list

| Destination | Protocol | What is sent |
|---|---|---|
| `login.th-koeln.de`, `mfa.th-koeln.de` | HTTPS (SAML) | Credentials — into the official login form only |
| `spaces.kisd.de` | HTTPS | Session cookies |
| `imap.intranet.fh-koeln.de:993` | IMAP over TLS | Credentials, mail |
| `smtp.intranet.fh-koeln.de:587` | SMTP + STARTTLS | Credentials, mail (TLS established **before** auth) |
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
through its own servers** (strictly more invasive than KISD Calendar's fully-local
design). It has distributed lawfully on both app stores for years; initial
university warnings later became partnerships in several cases. KISD Calendar
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
