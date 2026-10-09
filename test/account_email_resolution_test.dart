import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_service.dart';

void main() {
  // Shape of the TH chain (Cyrus via LMTP, no Delivered-To header): the
  // list server hop names the real address, the final hop the internal
  // Campus-ID mailbox.
  const thChain = [
    'from lvs-smtpgate2.nz.fh-koeln.de (lvs-smtpgate2.nz.FH-Koeln.DE '
        '[139.6.1.48]) by lvs-wm3.nz.fh-koeln.de (Postfix) with ESMTPS id '
        '0C6EA22006D for <mmuster1@imap.intranet.fh-koeln.de>; '
        'Thu,  8 Oct 2026 17:56:59 +0200 (CEST)',
    'from listserver.cit-is.fh-koeln.de ([139.6.21.93]) by '
        'smtp.intranet.fh-koeln.de with ESMTP; 08 Oct 2026 17:56:58 +0200',
    'from lvs-smtpgate2.nz.fh-koeln.de (lvs-smtpgate2.nz.FH-Koeln.DE '
        '[139.6.1.48]) by listserver.cit-is.fh-koeln.de (Postfix) with ESMTP '
        'id 7AF812000D1\r\n    for <Max_M.Mustermann@smail.th-koeln.de>; '
        'Thu,  8 Oct 2026 17:56:57 +0200 (CEST)',
  ];

  group('MailService.pickAccountEmail', () {
    test('reads the real address from the TH Received chain', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: thChain,
        sentFrom: const [],
        username: 'mmuster1',
      );
      expect(email, 'max_m.mustermann@smail.th-koeln.de');
    });

    test('never picks a classmate from inbox To/Cc (account-switch bug)', () {
      // The second account had an empty Sent folder and an inbox full of
      // group mails naming another student; the old To/Cc vote prefilled
      // that student's address. Without Received evidence: no guess.
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: const [],
        username: 'eschmi2',
      );
      expect(email, isNull);
    });

    test('Received evidence beats a sent From', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: thChain,
        sentFrom: [MailAddress(null, 'other.person@smail.th-koeln.de')],
        username: 'mmuster1',
      );
      expect(email, 'max_m.mustermann@smail.th-koeln.de');
    });

    test('most frequent Received recipient wins over a one-off', () {
      // A single mail forwarded via someone else's mailbox must not outvote
      // the address on every other delivery.
      final email = MailService.pickAccountEmail(
        receivedHeaders: [
          ...thChain,
          ...thChain,
          'by mx.th-koeln.de for <classmate@smail.th-koeln.de>; Thu',
        ],
        sentFrom: const [],
        username: 'mmuster1',
      );
      expect(email, 'max_m.mustermann@smail.th-koeln.de');
    });

    test('prefers smail over other th-koeln Received recipients', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: [
          'by a for <kisd-list@f02.th-koeln.de>; Thu',
          'by a for <kisd-list@f02.th-koeln.de>; Thu',
          'by b for <max.mustermann@smail.th-koeln.de>; Thu',
        ],
        sentFrom: const [],
      );
      expect(email, 'max.mustermann@smail.th-koeln.de');
    });

    test('accepts Exim-style "for addr" without brackets', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: ['by mx with esmtp for max@smail.th-koeln.de; Thu'],
        sentFrom: const [],
      );
      expect(email, 'max@smail.th-koeln.de');
    });

    test('ignores Received recipients outside th-koeln and role addresses', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: [
          'by gmail for <someone@gmail.com>; Thu',
          'by x for <noreply@th-koeln.de>; Thu',
          // Must not match via naive endsWith('th-koeln.de'):
          'by x for <spoof@nth-koeln.de>; Thu',
        ],
        sentFrom: const [],
      );
      expect(email, isNull);
    });

    test('only the Campus-ID mailbox in Received → falls back to sent', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: [thChain.first],
        sentFrom: [MailAddress(null, 'Max.Mustermann@smail.th-koeln.de')],
        username: 'mmuster1',
      );
      expect(email, 'max.mustermann@smail.th-koeln.de');
    });

    test('prefers a th-koeln sent address over a foreign one', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: [
          MailAddress(null, 'someone@example.com'),
          MailAddress(null, 'max.mustermann@smail.th-koeln.de'),
        ],
      );
      expect(email, 'max.mustermann@smail.th-koeln.de');
    });

    test('picks the most frequent sent address, not the newest', () {
      // A single message with a bad From (e.g. appended by an earlier app
      // version) must not outvote the addresses webmail actually stamped.
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: [
          MailAddress(null, 'wrongguess@smail.th-koeln.de'),
          MailAddress(null, 'max.mustermann@smail.th-koeln.de'),
          MailAddress(null, 'max.mustermann@smail.th-koeln.de'),
        ],
      );
      expect(email, 'max.mustermann@smail.th-koeln.de');
    });

    test('falls back to a foreign sent address when no th-koeln one exists',
        () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: [MailAddress(null, 'someone@example.com')],
      );
      expect(email, 'someone@example.com');
    });

    test('ignores the campus-id identity webmail stamps on sent mail', () {
      // Webmail's default identity is campusid@fh-koeln.de — not a real
      // mailbox; mail from it is silently dropped.
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: [
          MailAddress(null, 'mmuster1@fh-koeln.de'),
          MailAddress(null, 'mmuster1@fh-koeln.de'),
        ],
        username: 'mmuster1',
      );
      expect(email, isNull);
    });

    test('returns null on empty input', () {
      final email = MailService.pickAccountEmail(
        receivedHeaders: const [],
        sentFrom: const [],
      );
      expect(email, isNull);
    });
  });

  group('MailService.acceptSpacesEmail', () {
    const login = 'mmuster1';
    const official = 'max_m.mustermann@smail.th-koeln.de';

    test('accepts the official address when the Spaces login matches', () {
      expect(MailService.acceptSpacesEmail(official, login, login), official);
    });

    test('rejects a leftover Spaces session of the previous account', () {
      expect(
          MailService.acceptSpacesEmail(official, 'emuster2', login), isNull);
    });

    test('rejects when the signed-in login is unknown', () {
      expect(MailService.acceptSpacesEmail(official, login, null), isNull);
      expect(MailService.acceptSpacesEmail(official, login, ''), isNull);
    });

    test('rejects Campus-ID and role addresses', () {
      expect(
          MailService.acceptSpacesEmail('mmuster1@fh-koeln.de', login, login),
          isNull);
      expect(
          MailService.acceptSpacesEmail(
              'noreply@f02.th-koeln.de', login, login),
          isNull);
    });

    test('rejects non-th and look-alike domains', () {
      expect(MailService.acceptSpacesEmail('max@gmail.com', login, login),
          isNull);
      expect(
          MailService.acceptSpacesEmail('max@nth-koeln.de', login, login),
          isNull);
    });

    test('rejects missing or malformed input', () {
      expect(MailService.acceptSpacesEmail(null, login, login), isNull);
      expect(MailService.acceptSpacesEmail('', login, login), isNull);
      expect(MailService.acceptSpacesEmail(official, null, login), isNull);
    });

    test('normalises case and whitespace', () {
      expect(
          MailService.acceptSpacesEmail(
              '  Max_M.Mustermann@SMAIL.th-koeln.de ', ' MMuster1', login),
          official);
    });
  });

  group('MailService.isCampusIdAddress', () {
    test('matches the login Campus ID on any domain, case-insensitively', () {
      expect(
          MailService.isCampusIdAddress('mmuster1@fh-koeln.de', 'mmuster1'),
          isTrue);
      expect(
          MailService.isCampusIdAddress('MMuster1@fh-koeln.de', 'mmuster1'),
          isTrue);
      expect(
          MailService.isCampusIdAddress(
              'mmuster1@smail.th-koeln.de', 'mmuster1'),
          isTrue);
    });

    test('does not match real addresses or when username is unknown', () {
      expect(
          MailService.isCampusIdAddress(
              'max.mustermann@smail.th-koeln.de', 'mmuster1'),
          isFalse);
      expect(MailService.isCampusIdAddress('mmuster1@fh-koeln.de', null),
          isFalse);
      expect(
          MailService.isCampusIdAddress('mmuster1@fh-koeln.de', ''), isFalse);
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
      expect(MailService.isRoleAddress('max.mustermann@smail.th-koeln.de'),
          isFalse);
      expect(MailService.isRoleAddress('sekretariat@f02.th-koeln.de'),
          isFalse);
    });
  });
}
