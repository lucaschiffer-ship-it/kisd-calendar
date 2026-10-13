import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_sync.dart';

MimeMessage row(int uid, {List<String> flags = const []}) =>
    MimeMessage.fromEnvelope(
      Envelope(subject: 'Mail $uid'),
      uid: uid,
      flags: [...flags],
    );

List<int?> uids(List<MimeMessage> list) => [for (final m in list) m.uid];

void main() {
  group('planRefresh', () {
    test('an empty folder fetches nothing (FETCH 1:0 is a BAD)', () {
      expect(
        planRefresh(
          exists: 0,
          uidValidity: 1,
          knownUidValidity: 1,
          current: [row(1)],
        ),
        RefreshKind.empty,
      );
    });

    test('starts over without a list, or when UIDVALIDITY changed', () {
      expect(
        planRefresh(
          exists: 3,
          uidValidity: 1,
          knownUidValidity: null,
          current: const [],
        ),
        RefreshKind.full,
      );
      expect(
        planRefresh(
          exists: 3,
          uidValidity: 2,
          knownUidValidity: 1,
          current: [row(1)],
        ),
        RefreshKind.full,
      );
    });

    test('otherwise only fetches what changed', () {
      expect(
        planRefresh(
          exists: 3,
          uidValidity: 1,
          knownUidValidity: 1,
          current: [row(3), row(2)],
        ),
        RefreshKind.delta,
      );
    });
  });

  group('sequence ranges', () {
    test('the newest page', () {
      expect(newestRange(0), isNull);
      expect(newestRange(10), (1, 10));
      expect(newestRange(120), (71, 120));
    });

    test('the page below the oldest listed message, down to message 1', () {
      expect(pageBelow(71), (21, 70));
      expect(pageBelow(21), (1, 20));
      expect(pageBelow(1), isNull);
    });
  });

  group('applyDelta', () {
    test('adds new mail on top, drops what left the server', () {
      final current = [row(12), row(11), row(10)];
      final result = applyDelta(
        current: current,
        fromUid: 10,
        // 11 was deleted elsewhere; 14 and 13 arrived.
        flagsByUid: {10: [], 12: [], 13: [], 14: []},
        fetchedNew: [row(13), row(14)],
      );
      expect(uids(result), [14, 13, 12, 10]);
    });

    test('updates flags in place, keeping the row objects', () {
      final read = row(5);
      final result = applyDelta(
        current: [read],
        fromUid: 5,
        flagsByUid: {
          5: [MessageFlags.seen],
        },
        fetchedNew: const [],
      );
      expect(identical(result.single, read), isTrue);
      expect(read.isSeen, isTrue);
      // Still growable: markAsRead flips it in place later.
      read.isSeen = false;
      expect(read.isSeen, isFalse);
    });

    test('leaves rows below the fetched range alone', () {
      final result = applyDelta(
        current: [row(9), row(4)],
        fromUid: 9,
        flagsByUid: {9: []},
        fetchedNew: const [],
      );
      expect(uids(result), [9, 4]);
    });

    test('a mail fetched twice is listed once', () {
      final result = applyDelta(
        current: [row(2)],
        fromUid: 2,
        flagsByUid: {2: [], 3: []},
        fetchedNew: [row(3), row(3), row(2)],
      );
      expect(uids(result), [3, 2]);
    });
  });

  test('newUidsOf: only those above the newest listed, oldest first', () {
    expect(newUidsOf({4: [], 9: [], 7: [], 5: []}, 5), [7, 9]);
    expect(newUidsOf({4: []}, 5), isEmpty);
  });

  test('appendOlder: only older mail, once, newest first', () {
    final result = appendOlder(
      [row(10), row(9)],
      [row(7), row(9), row(8), row(11)],
    );
    expect(uids(result), [10, 9, 8, 7]);
  });

  test('sameFlags ignores order and case', () {
    expect(sameFlags([r'\Seen', r'\Flagged'], [r'\flagged', r'\seen']), isTrue);
    expect(sameFlags(null, const []), isTrue);
    expect(sameFlags([r'\Seen'], const []), isFalse);
  });
}
