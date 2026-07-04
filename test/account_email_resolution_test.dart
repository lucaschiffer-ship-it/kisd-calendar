import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_service.dart';

void main() {
  group('MailService.pickAccountEmail', () {
    test('prefers the From address of a sent message', () {
      final email = MailService.pickAccountEmail(
        sentFrom: [MailAddress(null, 'Luca.Schiffer@smail.th-koeln.de')],
        inboxRecipients: [
          MailAddress(null, 'other.person@smail.th-koeln.de'),
          MailAddress(null, 'other.person@smail.th-koeln.de'),
        ],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('prefers a th-koeln sent address over a foreign one', () {
      final email = MailService.pickAccountEmail(
        sentFrom: [
          MailAddress(null, 'someone@example.com'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
        inboxRecipients: const [],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('picks the most frequent sent address, not the newest', () {
      // A single message with a bad From (e.g. appended by an earlier app
      // version) must not outvote the addresses webmail actually stamped.
      final email = MailService.pickAccountEmail(
        sentFrom: [
          MailAddress(null, 'wrongguess@smail.th-koeln.de'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
        inboxRecipients: const [],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('falls back to a foreign sent address when no th-koeln one exists',
        () {
      final email = MailService.pickAccountEmail(
        sentFrom: [MailAddress(null, 'someone@example.com')],
        inboxRecipients: const [],
      );
      expect(email, 'someone@example.com');
    });

    test('ignores the campus-id identity webmail stamps on sent mail', () {
      // Webmail's default identity is campusid@fh-koeln.de — not a real
      // mailbox; mail from it is silently dropped. It floods Sent, so it
      // must never win detection over the deliverable smail address.
      final email = MailService.pickAccountEmail(
        sentFrom: [
          MailAddress(null, 'lschiff9@fh-koeln.de'),
          MailAddress(null, 'lschiff9@fh-koeln.de'),
          MailAddress(null, 'lschiff9@fh-koeln.de'),
        ],
        inboxRecipients: [
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
        username: 'lschiff9',
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('prefers a th-koeln inbox recipient over a foreign sent address', () {
      // Delivered-to evidence beats an unverified foreign From.
      final email = MailService.pickAccountEmail(
        sentFrom: [MailAddress(null, 'someone@example.com')],
        inboxRecipients: [
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('never picks a noreply mass-mail recipient over the smail address',
        () {
      // Faculty mass mails are addressed To: noreply@f02.th-koeln.de with
      // students in Bcc — it floods inbox recipients but is nobody's
      // identity, and the rarer smail address must win.
      final email = MailService.pickAccountEmail(
        sentFrom: const [],
        inboxRecipients: [
          MailAddress(null, 'noreply@f02.th-koeln.de'),
          MailAddress(null, 'noreply@f02.th-koeln.de'),
          MailAddress(null, 'noreply@f02.th-koeln.de'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('prefers a smail recipient over a more frequent staff-domain one',
        () {
      final email = MailService.pickAccountEmail(
        sentFrom: const [],
        inboxRecipients: [
          MailAddress(null, 'sekretariat@f02.th-koeln.de'),
          MailAddress(null, 'sekretariat@f02.th-koeln.de'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
        ],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('returns null when only campus-id addresses exist anywhere', () {
      final email = MailService.pickAccountEmail(
        sentFrom: [MailAddress(null, 'lschiff9@fh-koeln.de')],
        inboxRecipients: [MailAddress(null, 'lschiff9@smail.th-koeln.de')],
        username: 'lschiff9',
      );
      expect(email, isNull);
    });

    test('without sent mail, picks most frequent th-koeln inbox recipient',
        () {
      final email = MailService.pickAccountEmail(
        sentFrom: const [],
        inboxRecipients: [
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
          MailAddress(null, 'classmate@smail.th-koeln.de'),
          MailAddress(null, 'luca.schiffer@smail.th-koeln.de'),
          MailAddress(null, 'stranger@gmail.com'),
          MailAddress(null, 'stranger@gmail.com'),
          MailAddress(null, 'stranger@gmail.com'),
        ],
      );
      expect(email, 'luca.schiffer@smail.th-koeln.de');
    });

    test('ignores non-th-koeln inbox recipients entirely', () {
      final email = MailService.pickAccountEmail(
        sentFrom: const [],
        inboxRecipients: [
          MailAddress(null, 'stranger@gmail.com'),
          // Must not match via naive endsWith('th-koeln.de'):
          MailAddress(null, 'spoof@nth-koeln.de'),
        ],
      );
      expect(email, isNull);
    });

    test('returns null on empty input', () {
      final email = MailService.pickAccountEmail(
        sentFrom: const [],
        inboxRecipients: const [],
      );
      expect(email, isNull);
    });
  });

  group('MailService.isCampusIdAddress', () {
    test('matches the login Campus ID on any domain, case-insensitively', () {
      expect(
          MailService.isCampusIdAddress('lschiff9@fh-koeln.de', 'lschiff9'),
          isTrue);
      expect(
          MailService.isCampusIdAddress('LSchiff9@fh-koeln.de', 'lschiff9'),
          isTrue);
      expect(
          MailService.isCampusIdAddress(
              'lschiff9@smail.th-koeln.de', 'lschiff9'),
          isTrue);
    });

    test('does not match real addresses or when username is unknown', () {
      expect(
          MailService.isCampusIdAddress(
              'luca.schiffer@smail.th-koeln.de', 'lschiff9'),
          isFalse);
      expect(MailService.isCampusIdAddress('lschiff9@fh-koeln.de', null),
          isFalse);
      expect(
          MailService.isCampusIdAddress('lschiff9@fh-koeln.de', ''), isFalse);
    });
  });

  group('MailService.isRoleAddress', () {
    test('matches noreply variants and system mailboxes', () {
      expect(MailService.isRoleAddress('noreply@f02.th-koeln.de'), isTrue);
      expect(MailService.isRoleAddress('No-Reply@th-koeln.de'), isTrue);
      expect(MailService.isRoleAddress('do_not.reply@example.com'), isTrue);
      expect(MailService.isRoleAddress('postmaster@th-koeln.de'), isTrue);
    });

    test('does not match personal addresses', () {
      expect(MailService.isRoleAddress('luca.schiffer@smail.th-koeln.de'),
          isFalse);
      expect(MailService.isRoleAddress('sekretariat@f02.th-koeln.de'),
          isFalse);
    });
  });
}
