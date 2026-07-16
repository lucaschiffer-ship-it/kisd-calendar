import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Native, offline-readable privacy notice (Apple guideline 5.1.1(i) requires
/// the policy to be accessible inside the app). Keep the substance in sync
/// with PRIVACY.md at the repo root — that file is the public/App Store copy.
class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppColorScheme>(
      valueListenable: AppColorScheme.currentListenable,
      builder: (context, s, _) => _buildScaffold(context, s),
    );
  }

  Widget _buildScaffold(BuildContext context, AppColorScheme s) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: s.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        centerTitle: true,
        title: Text(
          'Privacy Policy',
          style: AppTextStyles.navTitle(color: s.textPrimary),
        ),
      ),
      body: ListView(
        children: [
          const SizedBox(height: 24),
          _card(s, [
            _body(s,
                'KISD Calendar is an unofficial student app for KISD / '
                'TH Köln and is not affiliated with or endorsed by TH Köln. '
                'Everything the app does happens on your device: the '
                'developer operates no server and never receives any data '
                'about you or your usage.'),
          ]),

          _section(s, 'WHAT IS STORED'),
          _card(s, [
            _body(s,
                'Your Campus-ID username and password, your login/session '
                'cookies and your confirmed sender email address are kept in '
                'the iOS Keychain — the same hardware-encrypted store Apple '
                'Passwords uses, restricted to this device and excluded from '
                'iCloud sync and backups.'),
            _gap(),
            _body(s,
                'Your course list, favourites and theme settings are kept in '
                'local app storage.'),
            _gap(),
            _body(s,
                'Your two-factor (TOTP) secret is never stored — you enter '
                'each one-time code yourself when TH Köln asks for it. '
                'Signing out deletes the stored credentials, cookies and '
                'email address.'),
          ]),

          _section(s, 'WHERE YOUR CREDENTIALS ARE SENT'),
          _card(s, [
            _body(s,
                'Only to official TH Köln / KISD servers, always encrypted '
                'in transit (TLS):'),
            _gap(),
            _body(s,
                '•  login.th-koeln.de / mfa.th-koeln.de — the official '
                'TH Köln single sign-on, into the same login form the '
                'website uses\n'
                '•  spaces.kisd.de — the KISD Spaces platform\n'
                '•  imap.intranet.fh-koeln.de / smtp.intranet.fh-koeln.de — '
                'the official TH Köln mail servers'),
            _gap(),
            _body(s,
                'They are never sent anywhere else. There is no technical '
                'way for the developer to see them.'),
          ]),

          _section(s, '"TRUST THIS DEVICE"'),
          _card(s, [
            _body(s,
                'During login the app accepts TH Köln\'s "trust this device" '
                'option on your behalf (device name "KISD App"), so future '
                'logins can skip the one-time code for the period TH Köln '
                'allows (about two weeks). You can revoke trusted devices at '
                'any time in the TH Köln MFA portal.'),
          ]),

          _section(s, 'OTHER CONNECTIONS'),
          _card(s, [
            _body(s,
                '•  openmensa.org — fetches the mensa menu; the request '
                'contains only the canteen number and the date\n'
                '•  Fonts are bundled with the app; nothing is fetched from '
                'Google\n'
                '•  Course dates are written to your device calendar after '
                'you grant iOS calendar permission; calendar data never '
                'leaves the device'),
          ]),

          _section(s, 'NO TRACKING'),
          _card(s, [
            _body(s,
                'No analytics, no crash reporting, no advertising SDKs, no '
                'telemetry of any kind. The App Store privacy label for this '
                'app is "Data Not Collected".'),
          ]),

          _section(s, 'YOUR RIGHTS & CONTACT'),
          _card(s, [
            _body(s,
                'Because the developer neither collects nor processes any '
                'personal data, there is nothing the developer could '
                'disclose, correct or delete on request — all data is under '
                'your control, on your device and in your TH Köln account.\n\n'
                'Questions: Luca Schiffer, luca.schiffer@smail.th-koeln.de'),
          ]),

          _section(s, 'ZUSAMMENFASSUNG (DEUTSCH)'),
          _card(s, [
            _body(s,
                'Alles passiert lokal auf deinem Gerät: Der Entwickler '
                'betreibt keinen Server und erhält keinerlei Daten — keine '
                'Analytics, kein Crash-Reporting, keine Telemetrie.\n\n'
                'Campus-ID und Sitzungs-Cookies liegen im iOS-Schlüsselbund '
                '(hardware-verschlüsselt, vom iCloud-Sync und von Backups '
                'ausgeschlossen). Das TOTP-Geheimnis wird nie gespeichert. '
                'Übertragen werden die Zugangsdaten ausschließlich '
                'TLS-verschlüsselt an die offiziellen Server der TH Köln '
                'bzw. der KISD — an niemanden sonst.\n\n'
                'Beim Login aktiviert die App die Option „Diesem Gerät '
                'vertrauen" (Gerätename „KISD App"); das lässt sich im '
                'MFA-Portal der TH Köln jederzeit widerrufen. Beim Abmelden '
                'werden Zugangsdaten, Cookies und E-Mail-Adresse gelöscht.\n\n'
                'Da der Entwickler keine personenbezogenen Daten '
                'verarbeitet, ist er für diese Daten weder Verantwortlicher '
                'noch Auftragsverarbeiter im Sinne der DSGVO.'),
          ]),

          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              'Last updated: 16 July 2026',
              style: AppTextStyles.bodySmall(color: s.textSecondary),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _section(AppColorScheme s, String label) => Padding(
        padding: const EdgeInsets.only(left: 20, right: 20, top: 24, bottom: 8),
        child: Text(
          label,
          style: AppTextStyles.sectionLabel(color: s.textSecondary),
        ),
      );

  Widget _card(AppColorScheme s, List<Widget> children) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.input),
          child: Container(
            color: s.surfaceElevated,
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: children,
            ),
          ),
        ),
      );

  Widget _body(AppColorScheme s, String text) => Text(
        text,
        style: AppTextStyles.bodySmall(color: s.textPrimary),
      );

  Widget _gap() => const SizedBox(height: 12);
}
