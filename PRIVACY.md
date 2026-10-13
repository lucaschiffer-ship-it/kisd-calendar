# Privacy Notice — KISD Calendar

*Last updated: 13 October 2026. The German version below is identical in substance.*

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
| Which Campus ID the data on the device belongs to | iOS Keychain | So signing in with a different Campus ID clears the previous account's data |
| Course list, schedule, favourites, theme settings | Local app storage on your device | App functionality (your liked courses are kept separately, so a refresh never resets them) |
| Your mail lists — the newest 200 inbox emails and 100 each from Sent, Drafts and Trash (sender, subject, date, a short preview) — and the full text of the newest 50 inbox emails (up to 5 MB each) | The app's own storage on your device (excluded from iCloud and device backups) | So your folders open at once and recent mail can still be read offline |
| The mensa menu for this week and the next two | Local app storage on your device | So the menu still opens offline |

Your two-factor (TOTP) secret is **never** stored — you enter the one-time
code yourself when TH Köln asks for it. Signing out — or signing in with a
different Campus ID — deletes the stored credentials, cookies and email
address, plus that account's courses, calendar entries (including the "KISD"
calendar in Apple Calendar), pending reminders and cached mail.

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
- Mail attachments: photos, files and document scans are read only when you
  pick them — the iOS photo picker hands over only what you select, so the
  app has no access to your photo library. While you write, copies sit in
  the app's cache folder and are deleted when the compose sheet closes. They
  are sent only to the TH Köln mail servers (and stored there in your Sent
  or Drafts folder). The camera is used only for "Take Photo" and "Scan
  Document", after you grant iOS camera permission. Photos keep their
  metadata, such as where they were taken, unless you strip it in
  Settings › Mail; that happens on the device.

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
-Passwort, Sitzungs-Cookies, die bestätigte Absenderadresse und die Angabe,
zu welcher Campus-ID die Daten auf dem Gerät gehören, im iOS-Schlüsselbund
(hardware-verschlüsselt, vom iCloud-Sync und von Backups ausgeschlossen), außerdem
Kursliste, Favoriten und Einstellungen im lokalen App-Speicher. Damit die
Ordner sofort und auch offline zu sehen sind, liegen zusätzlich die Listen
der neuesten 200 E-Mails des Posteingangs und je 100 aus Gesendet, Entwürfe
und Papierkorb (Absender, Betreff, Datum, kurze Vorschau) sowie die neuesten
50 E-Mails des Posteingangs vollständig (bis 5 MB je Mail) im App-Speicher
(von Backups ausgeschlossen), außerdem der Mensaplan dieser und der nächsten
zwei Wochen. Das
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
geladen. E-Mail-Anhänge (Fotos, Dateien, Dokument-Scans) liest die App nur,
wenn du sie auswählst; beim Schreiben liegen Kopien im Cache-Ordner und
werden beim Schließen gelöscht. Gesendet werden sie nur an die Mailserver
der TH Köln. Die Kamera wird nur für „Take Photo" und „Scan Document"
genutzt, nach deiner iOS-Freigabe. Fotos behalten ihre Metadaten, etwa den
Aufnahmeort, außer du entfernst sie unter „Settings › Mail"; das geschieht
auf dem Gerät. Beim Abmelden – oder bei der Anmeldung mit einer anderen
Campus-ID – werden Zugangsdaten, Cookies und E-Mail-Adresse gelöscht, ebenso
die Kurse, Kalendereinträge (auch der Kalender „KISD" in Apple Kalender),
anstehende Erinnerungen und zwischengespeicherte E-Mails dieses Kontos.

Da der Entwickler keine personenbezogenen Daten verarbeitet, ist er für
diese Daten weder Verantwortlicher noch Auftragsverarbeiter im Sinne der
DSGVO. Fragen: Luca Schiffer, luca.schiffer@smail.th-koeln.de.
