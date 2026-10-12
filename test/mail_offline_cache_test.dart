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

    test('keeps at most the newest 50 rows', () async {
      await cache.writeIndex(
        owner: 'mmuster1',
        uidValidity: 1,
        messages: [for (var uid = 60; uid > 0; uid--) listMessage(uid: uid)],
      );
      final index = await cache.readIndex();
      expect(index?.messages, hasLength(MailOfflineCache.maxMessages));
      expect(index?.messages.first.uid, 60);
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
      await cache.prune({1, 3});
      expect(await cache.bodyUids(), {1, 3});
      expect(await cache.readIndex(), isNotNull);
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
      await cache.writeBody(1, Uint8List.fromList(utf8.encode('x')));
      await cache.clear();
      expect(await cache.readIndex(), isNull);
      expect(await cache.bodyUids(), isEmpty);
    });
  });
}
