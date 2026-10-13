import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_offline_cache.dart';

/// A list row as `fetchInbox` builds it: ENVELOPE plus the first bytes of
/// the body as a headerless preview.
MimeMessage listMessage({
  int uid = 42,
  List<String> flags = const [],
  String preview = 'Hallo zusammen, die Abgabe ist am Freitag.',
}) =>
    MimeMessage.fromEnvelope(
        Envelope(
          date: DateTime.utc(2026, 10, 12, 9, 30),
          subject: 'Grüße aus der KISD',
          from: [const MailAddress('Erika Müller', 'erika@th-koeln.de')],
          to: [const MailAddress(null, 'me@smail.th-koeln.de')],
          messageId: '<abc@th-koeln.de>',
        ),
        uid: uid,
        flags: [...flags],
      )
      ..size = 1234
      ..mimeData = BinaryMimeData(
        Uint8List.fromList(utf8.encode(preview)),
        containsHeader: false,
      );

void main() {
  group('list rows survive the index round trip', () {
    MimeMessage roundTrip(MimeMessage m) => MailOfflineCache.decodeMessage(
      jsonDecode(jsonEncode(MailOfflineCache.encodeMessage(m)))
          as Map<String, dynamic>,
    );

    test('on everything the mail screens read', () {
      final original = listMessage(flags: [MessageFlags.seen]);
      final restored = roundTrip(original);

      expect(restored.uid, original.uid);
      expect(restored.size, original.size);
      expect(restored.isSeen, isTrue);
      expect(restored.decodeSubject(), original.decodeSubject());
      expect(restored.from?.first.personalName, 'Erika Müller');
      expect(restored.fromEmail, original.fromEmail);
      expect(restored.decodeDate(), original.decodeDate());
      expect(restored.decodeTextPlainPart(), original.decodeTextPlainPart());
      expect(restored.decodeTextHtmlPart(), original.decodeTextHtmlPart());
      expect(restored.envelope?.messageId, '<abc@th-koeln.de>');
    });

    test('with flags that can still be flipped', () {
      final restored = roundTrip(listMessage());
      expect(restored.isSeen, isFalse);
      restored.isSeen = true; // what markAsRead does in place
      expect(restored.isSeen, isTrue);
    });
  });

  group('on disk', () {
    late Directory base;
    late MailOfflineCache cache;

    setUp(() async {
      base = await Directory.systemTemp.createTemp('mail_offline_test');
      cache = MailOfflineCache(baseDirectory: () async => base);
    });
    tearDown(() => base.delete(recursive: true));

    test('the index reads back owner, UIDVALIDITY and rows in order', () async {
      expect(await cache.readIndex(), isNull);
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 7,
        messages: [listMessage(uid: 3), listMessage(uid: 2)],
      );
      final index = await cache.readIndex();
      expect(index?.owner, 'mmuster1');
      expect(index?.uidValidity, 7);
      expect(index?.messages.map((m) => m.uid), [3, 2]);
    });

    test(
      'keeps the newest 200 inbox rows and 100 of every other folder',
      () async {
        final many = [
          for (var uid = 260; uid > 0; uid--) listMessage(uid: uid),
        ];
        await cache.writeIndex(
          owner: 'mmuster1',
          uidValidity: 1,
          messages: many,
        );
        await cache.writeIndex(
          folder: 'sent',
          owner: 'mmuster1',
          uidValidity: 1,
          messages: many,
        );
        final inbox = await cache.readIndex();
        expect(inbox?.messages, hasLength(200));
        expect(inbox?.messages.first.uid, 260);
        final sent = await cache.readIndex(folder: 'sent');
        expect(sent?.messages, hasLength(100));
      },
    );

    test('each folder has its own list', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 5)],
      );
      await cache.writeIndex(
        folder: 'sent',
        owner: 'mmuster1',
        uidValidity: 9,
        messages: [listMessage(uid: 7), listMessage(uid: 6)],
      );
      expect((await cache.readIndex())?.messages.map((m) => m.uid), [5]);
      final sent = await cache.readIndex(folder: 'sent');
      expect(sent?.uidValidity, 9);
      expect(sent?.messages.map((m) => m.uid), [7, 6]);
      expect(await cache.readIndex(folder: 'drafts'), isNull);
    });

    test('a Sent list with a new UIDVALIDITY keeps the inbox bodies', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      await cache.writeBody(1, Uint8List.fromList(utf8.encode('x')));
      await cache.writeIndex(
        folder: 'sent',
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 3)],
      );
      await cache.writeIndex(
        folder: 'sent',
        owner: 'mmuster1',
        uidValidity: 2,
        messages: [listMessage(uid: 3)],
      );
      expect(await cache.bodyUids(), {1});
    });

    test(
      'lives in Application Support/mail_store, excluded from backup',
      () async {
        final excluded = <String>[];
        final store = MailOfflineCache(
          baseDirectory: () async => base,
          excludeFromBackup: (path) async => excluded.add(path),
        );
        await store.writeIndex(
          owner: 'mmuster1',
          uidValidity: 1,
          messages: [listMessage(uid: 1)],
        );
        await store.readIndex();
        expect(excluded, ['${base.path}/mail_store'], reason: 'once');
        expect(File('${base.path}/mail_store/inbox.json').existsSync(), isTrue);

        // Cleared and recreated: excluded again.
        await store.clear();
        await store.readIndex();
        expect(excluded, hasLength(2));
      },
    );

    test('moves the old Library/Caches copy over, bodies and all', () async {
      final legacy = Directory('${base.path}/Caches/mail_offline')
        ..createSync(recursive: true);
      // What the cache wrote before 13 Oct 2026: the inbox list as
      // index.json next to the bodies.
      final old = MailOfflineCache(baseDirectory: () async => legacy.parent);
      await old.writeIndex(
        owner: 'mmuster1',
        uidValidity: 4,
        messages: [listMessage(uid: 8)],
      );
      final oldDir = Directory('${legacy.parent.path}/mail_store');
      File('${oldDir.path}/inbox.json').renameSync('${legacy.path}/index.json');
      File('${legacy.path}/8.eml').writeAsStringSync('x');
      oldDir.deleteSync(recursive: true);

      final store = MailOfflineCache(
        baseDirectory: () async => Directory('${base.path}/Support'),
        legacyDirectory: () async => legacy,
      );
      final index = await store.readIndex();
      expect(index?.uidValidity, 4);
      expect(index?.messages.map((m) => m.uid), [8]);
      expect(await store.bodyUids(), {8});
      expect(legacy.existsSync(), isFalse);
    });

    test('bodies keep their raw 8-bit bytes', () async {
      // An unencoded 8-bit body: a String round trip through
      // `String.fromCharCodes` would turn the umlauts into mojibake.
      final raw = Uint8List.fromList(
        utf8.encode(
          'From: erika@th-koeln.de\r\n'
          'Subject: Test\r\n'
          'Message-ID: <abc@th-koeln.de>\r\n'
          'Content-Type: text/plain; charset=utf-8\r\n'
          'Content-Transfer-Encoding: 8bit\r\n'
          '\r\n'
          'Viele Grüße aus Köln\r\n',
        ),
      );
      await cache.writeBody(42, raw);

      expect(await cache.bodyUids(), {42});
      final body = await cache.readBody(42);
      expect(body?.uid, 42);
      expect(body?.decodeTextPlainPart(), contains('Viele Grüße aus Köln'));
      expect(await cache.readBody(43), isNull);
    });

    test('prune drops the bodies that left the list', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      for (final uid in [1, 2, 3]) {
        await cache.writeBody(uid, Uint8List.fromList(utf8.encode('x')));
      }
      await cache.writeIndex(
        folder: 'trash',
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 2)],
      );
      await cache.prune({1, 3});
      expect(await cache.bodyUids(), {1, 3});
      expect(await cache.readIndex(), isNotNull);
      expect(await cache.readIndex(folder: 'trash'), isNotNull);
    });

    test('a new UIDVALIDITY or owner drops every saved body', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      await cache.writeBody(1, Uint8List.fromList(utf8.encode('x')));

      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      expect(await cache.bodyUids(), {1}, reason: 'same inbox — kept');

      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 2,
        messages: [listMessage(uid: 1)],
      );
      expect(await cache.bodyUids(), isEmpty);

      await cache.writeBody(1, Uint8List.fromList(utf8.encode('x')));
      await cache.writeIndex(
        owner: 'emuster2',
        uidValidity: 2,
        messages: [listMessage(uid: 1)],
      );
      expect(await cache.bodyUids(), isEmpty);
    });

    test('clear removes everything', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      await cache.writeIndex(
        folder: 'sent',
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [listMessage(uid: 1)],
      );
      await cache.writeBody(1, Uint8List.fromList(utf8.encode('x')));
      await cache.clear();
      expect(await cache.readIndex(), isNull);
      expect(await cache.readIndex(folder: 'sent'), isNull);
      expect(await cache.bodyUids(), isEmpty);
    });
  });
}
