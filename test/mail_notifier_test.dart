import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_notifier.dart';
import 'package:kisd_calendar/services/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

const _owner = 'lschiffe';

MailNotifyMark _mark(int upTo, {String owner = _owner, int validity = 7}) =>
    MailNotifyMark(owner: owner, uidValidity: validity, upTo: upTo);

List<({int uid, bool seen})> _inbox(
  List<int> unread, [
  List<int> read = const [],
]) => [
  for (final u in unread) (uid: u, seen: false),
  for (final u in read) (uid: u, seen: true),
];

MimeMessage _row({String? subject = 'Abgabe Freitag', String preview = ''}) =>
    MimeMessage.fromEnvelope(
        Envelope(
          subject: subject,
          from: [const MailAddress('Erika Müller', 'erika@th-koeln.de')],
        ),
        uid: 12,
      )
      ..mimeData = BinaryMimeData(
        Uint8List.fromList(utf8.encode(preview)),
        containsHeader: false,
      );

void main() {
  group('planMailAnnouncements', () {
    test('announces only unread mail above the mark, newest first', () {
      final plan = planMailAnnouncements(
        stored: _mark(10),
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([9, 11, 13], [12]),
      );
      expect(plan.uids, [13, 11]);
      expect(plan.mark, _mark(13));
    });

    test('no mark yet: announces nothing, starts at the newest mail', () {
      final plan = planMailAnnouncements(
        stored: null,
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([3, 5, 8]),
      );
      expect(plan.uids, isEmpty);
      expect(plan.mark, _mark(8));
    });

    test('a new UIDVALIDITY resets the mark silently', () {
      final plan = planMailAnnouncements(
        stored: _mark(500, validity: 7),
        owner: _owner,
        uidValidity: 8,
        inbox: _inbox([2, 3]),
      );
      expect(plan.uids, isEmpty);
      expect(plan.mark, _mark(3, validity: 8));
    });

    test('another account resets it too; case and spaces don\'t count', () {
      final other = planMailAnnouncements(
        stored: _mark(4, owner: 'someone'),
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([5]),
      );
      expect(other.uids, isEmpty);

      final same = planMailAnnouncements(
        stored: _mark(4, owner: ' LSchiffe '),
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([5]),
      );
      expect(same.uids, [5]);
    });

    test(
      'a sync the app showed moves the mark: nothing is announced twice',
      () {
        final first = planMailAnnouncements(
          stored: _mark(10),
          owner: _owner,
          uidValidity: 7,
          inbox: _inbox([11]),
        );
        final again = planMailAnnouncements(
          stored: first.mark,
          owner: _owner,
          uidValidity: 7,
          inbox: _inbox([11]),
        );
        expect(first.uids, [11]);
        expect(again.uids, isEmpty);
      },
    );

    test('UIDNEXT moves the mark past mail deleted before it was seen', () {
      final plan = planMailAnnouncements(
        stored: _mark(10),
        owner: _owner,
        uidValidity: 7,
        uidNext: 21,
        inbox: _inbox([]),
      );
      expect(plan.mark, _mark(20));
    });

    test('the mark never moves back', () {
      final plan = planMailAnnouncements(
        stored: _mark(30),
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([], [12]),
      );
      expect(plan.mark, _mark(30));
    });

    test('at most $maxMailAnnouncements, the newest; the mark passes all', () {
      final plan = planMailAnnouncements(
        stored: _mark(0),
        owner: _owner,
        uidValidity: 7,
        inbox: _inbox([for (var u = 1; u <= 9; u++) u]),
      );
      expect(plan.uids, [9, 8, 7, 6, 5]);
      expect(plan.mark, _mark(9));
    });
  });

  group('ids and payloads', () {
    test('notification ids stay inside the mail range', () {
      for (final uid in [0, 1, 399999, 400000, 123456789]) {
        final id = mailNotificationId(uid);
        expect(
          id,
          inInclusiveRange(
            NotificationService.mailIdMin,
            NotificationService.mailIdMax,
          ),
        );
      }
      expect(mailNotificationId(5), isNot(mailNotificationId(6)));
    });

    test('payload ids round-trip; junk is refused', () {
      expect(parseMailPayloadId(mailPayloadId(7, 42)), (7, 42));
      expect(parseMailPayloadId('42'), isNull);
      expect(parseMailPayloadId('a:b'), isNull);
    });
  });

  group('mailNotificationContent', () {
    test('sender, subject, preview — like Apple Mail', () {
      final c = mailNotificationContent(
        _row(preview: 'Hallo zusammen, die Abgabe ist am Freitag.'),
      );
      expect(c.title, 'Erika Müller');
      expect(c.subtitle, 'Abgabe Freitag');
      expect(c.body, 'Hallo zusammen, die Abgabe ist am Freitag.');
    });

    test('no preview: the subject becomes the body', () {
      final c = mailNotificationContent(_row());
      expect(c.subtitle, isNull);
      expect(c.body, 'Abgabe Freitag');
    });
  });

  group('MailNotifier state', () {
    setUp(() {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('writeMark keeps the further mark of the same inbox', () async {
      await MailNotifier.writeMark(_mark(20));
      await MailNotifier.writeMark(_mark(15));
      expect(await MailNotifier.readMark(), _mark(20));
      // Another inbox replaces it whatever its number.
      await MailNotifier.writeMark(_mark(3, validity: 9));
      expect(await MailNotifier.readMark(), _mark(3, validity: 9));
    });

    test('the run log keeps times and outcomes, newest first', () async {
      final t = DateTime(2026, 10, 15, 9);
      await MailNotifier.logRun(t, 'no new mail');
      await MailNotifier.logRun(t.add(const Duration(minutes: 40)), '1 new');
      final log = await MailNotifier.runLog();
      expect(log.map((e) => e.$2), ['1 new', 'no new mail']);
      expect(log.first.$1, t.add(const Duration(minutes: 40)));
    });

    test('a refused login waits longer each time in a row', () async {
      final t = DateTime(2026, 10, 16, 3, 24);
      expect(await MailNotifier.readBackoff(), isNull);
      expect(await MailNotifier.noteRefused(t), 1);
      expect(
        (await MailNotifier.readBackoff())!.notBefore,
        t.add(const Duration(hours: 1)),
      );
      expect(await MailNotifier.noteRefused(t), 2);
      expect(await MailNotifier.noteRefused(t), 3);
      final third = (await MailNotifier.readBackoff())!;
      expect(third.refusals, 3);
      expect(third.notBefore, t.add(const Duration(hours: 4)));
    });

    test('a working login ends the wait and starts a new streak', () async {
      final t = DateTime(2026, 10, 16, 3, 24);
      await MailNotifier.noteRefused(t);
      await MailNotifier.noteRefused(t);
      expect(await MailNotifier.clearBackoff(), 2);
      expect(await MailNotifier.readBackoff(), isNull);
      expect(await MailNotifier.clearBackoff(), 0);
      expect(await MailNotifier.noteRefused(t), 1);
    });

    test('the old indefinite pause is dropped', () async {
      final store = SharedPreferencesAsync();
      await store.setBool(MailNotifier.legacyPausedKey, true);
      expect(await MailNotifier.readBackoff(), isNull);
      expect(await store.containsKey(MailNotifier.legacyPausedKey), isFalse);
    });
  });

  group('refused logins', () {
    test('the wait doubles from 1 h up to 8 h', () {
      expect(
        [for (var n = 1; n <= 6; n++) refusalBackoff(n).inHours],
        [1, 2, 4, 8, 8, 8],
      );
    });

    test('no mail id is the paused notice', () {
      const span =
          NotificationService.mailIdMax - NotificationService.mailIdMin;
      for (final uid in [span - 1, span, 2 * span - 1, 0]) {
        expect(mailNotificationId(uid), isNot(mailPausedNoticeId));
      }
      expect(
        mailPausedNoticeId,
        inInclusiveRange(
          NotificationService.mailIdMin,
          NotificationService.mailIdMax,
        ),
      );
    });

    test('the log keeps a response code or a known phrase, nothing else', () {
      expect(
        refusalCode('[AUTHENTICATIONFAILED] Authentication failed.'),
        '[AUTHENTICATIONFAILED]',
      );
      expect(refusalCode('[unavailable] try later'), '[UNAVAILABLE]');
      expect(
        refusalCode('Login failed: authentication failure'),
        'authentication failure',
      );
      // Unknown brackets and free text never reach the log as they are.
      expect(refusalCode('[LSCHIFFE] locked'), 'other');
      expect(refusalCode('user lschiffe@smail.th-koeln.de blocked'), 'other');
      expect(refusalCode(null), 'other');
    });
  });
}
