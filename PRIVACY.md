# Privacy Notice — KISD Calendar

*Last updated: 14 July 2026. The German version below is identical in substance.*

KISD Calendar is an unofficial student app for KISD / TH Köln. It is not
affiliated with, or endorsed by, TH Köln. Everything the app does happens
**on your device**. The developer operates **no server**, and no data about
you or your usage is ever transmitted to the developer or to any analytics
service.

## What the app stores, and where

| Data | Where | Why |
|---|---|---|
| Campus-ID username & password | iOS Keychain (hardware-encrypted, this device only — excluded from iCloud sync and backups) | To log you into spaces.kisd.de via TH Köln SSO and into your TH Köln mailbox |
| Login/session cookies (incl. the optional "trust this device" MFA cookie) | iOS Keychain | So you don't have to enter your password and one-time code on every launch |
| Your confirmed sender email address | iOS Keychain | So sent mail carries your real address |
| Course list, schedule, favourites, theme settings | Local app storage on your device | App functionality |

Your two-factor (TOTP) secret is **never** stored — you enter the one-time
code yourself when TH Köln asks for it. Signing out deletes the stored
credentials, cookies, and email address.

## Where your credentials are sent

Your username and password are transmitted **only** to official TH Köln /
KISD servers, always encrypted in transit (TLS):

- `login.th-koeln.de` / `mfa.th-koeln.de` — the official TH Köln single
  sign-on, into the same login form the website uses
- `spaces.kisd.de` — the KISD Spaces platform
- `imap.intranet.fh-koeln.de` / `smtp.intranet.fh-koeln.de` — the official
  TH Köln mail servers

They are never sent anywhere else. There is no way for the developer to see
them.

## The "trust this device" note

During login the app accepts TH Köln's "trust this device" option on your
behalf (device name "KISD App"), so future logins can skip the one-time
code for the period TH Köln allows (about two weeks). You can revoke
trusted devices at any time in the TH Köln MFA portal, and signing out of
the app deletes the cookie on the device.

## Other connections

- `openmensa.org` — fetches the mensa menu. The request contains only the
  canteen number and the date; no account or personal data.
- Fonts are bundled with the app; nothing is fetched from Google.
- The calendar feature writes course dates into your device calendar after
  you grant iOS calendar permission. Calendar data never leaves the device.

## No tracking

No analytics, no crash reporting, no advertising SDKs, no telemetry of any
kind. The App Store privacy label for this app is "Data Not Collected".

## Your rights & contact

Because the developer neither collects nor processes any personal data,
there is nothing the developer could disclose, correct, or delete on
request — all data is under your control on your device and in your TH Köln
account. Questions: Luca Schiffer, luca.schiffer@smail.th-koeln.de.

---

# Datenschutzhinweis — KISD Calendar (Deutsch)

KISD Calendar ist eine inoffizielle Studierenden-App für die KISD /
TH Köln und steht in keiner Verbindung zur TH Köln. Alles passiert **lokal
auf deinem Gerät**: Der Entwickler betreibt keinen Server und erhält
keinerlei Daten über dich oder deine Nutzung — keine Analytics, kein
Crash-Reporting, keine Telemetrie.

**Gespeichert werden** (ausschließlich lokal): Campus-ID-Benutzername und
-Passwort sowie Sitzungs-Cookies im iOS-Schlüsselbund (hardware-
verschlüsselt, vom iCloud-Sync und von Backups ausgeschlossen), außerdem
Kursliste, Favoriten und Einstellungen im lokalen App-Speicher. Das
TOTP-Geheimnis für die Zwei-Faktor-Authentifizierung wird **nie**
gespeichert — den Einmalcode gibst du selbst ein.

**Übertragen werden** die Zugangsdaten ausschließlich TLS-verschlüsselt an
die offiziellen Server der TH Köln bzw. der KISD (`login.th-koeln.de`,
`mfa.th-koeln.de`, `spaces.kisd.de`, `imap.intranet.fh-koeln.de`,
`smtp.intranet.fh-koeln.de`) — an niemanden sonst. Der Entwickler kann sie
technisch nicht einsehen.

Beim Login aktiviert die App die TH-Köln-Option „Diesem Gerät vertrauen"
(Gerätename „KISD App"), damit der Einmalcode ca. zwei Wochen lang nicht
erneut nötig ist; das lässt sich im MFA-Portal der TH Köln jederzeit
widerrufen. Der Mensaplan wird ohne Personenbezug von `openmensa.org`
geladen. Beim Abmelden werden Zugangsdaten, Cookies und E-Mail-Adresse
gelöscht.

Da der Entwickler keine personenbezogenen Daten verarbeitet, ist er für
diese Daten weder Verantwortlicher noch Auftragsverarbeiter im Sinne der
DSGVO. Fragen: Luca Schiffer, luca.schiffer@smail.th-koeln.de.
