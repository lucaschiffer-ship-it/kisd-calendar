import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_attachments.dart';
import 'package:kisd_calendar/services/mail_display.dart';

Uint8List _binary(int length) =>
    Uint8List.fromList(List.generate(length, (i) => (i * 37 + 11) % 256));

const _body =
    'Hallo Frau Müller,\n\nanbei mein Entwurf für die Abgabe.\n\n'
    'Viele Grüße\nLuca';

MimeMessage _build({
  List<MailAttachmentData>? attachments,
  bool markPhotos = false,
}) => buildAttachmentMessage(
  from: MailAddress(null, 'luca@smail.th-koeln.de'),
  to: [MailAddress(null, 'mueller@th-koeln.de')],
  subject: 'Abgabe – Entwurf',
  body: _body,
  attachments:
      attachments ??
      [
        MailAttachmentData(
          name: 'Präsentation Übersicht.pdf',
          mimeType: 'application/pdf',
          bytes: _binary(5000),
        ),
        MailAttachmentData(
          name: 'IMG_2041.jpg',
          mimeType: 'image/jpeg',
          bytes: _binary(1234),
          isPhoto: true,
        ),
      ],
  markPhotos: markPhotos,
);

/// What the server stores and the recipient parses.
MimeMessage _roundTrip(MimeMessage m) =>
    MimeMessage.parseFromText(m.renderMessage());

void main() {
  group('buildAttachmentMessage', () {
    test('is multipart/mixed without a transfer encoding on the root', () {
      final raw = _build().renderMessage();
      final parsed = MimeMessage.parseFromText(raw);
      expect(parsed.mediaType.sub, MediaSubtype.multipartMixed);
      final rootCte = parsed.getHeaderValue('content-transfer-encoding');
      expect(
        rootCte == null || rootCte.toLowerCase() == '7bit',
        isTrue,
        reason: 'multipart roots must not be quoted-printable/base64',
      );
    });

    test('the text decodes unchanged, umlauts included', () {
      final parsed = _roundTrip(_build());
      expect(
        parsed.decodeTextPlainPart()?.replaceAll('\r\n', '\n').trimRight(),
        _body,
      );
      expect(messageBodyText(parsed), _body);
      expect(parsed.decodeSubject(), 'Abgabe – Entwurf');
    });

    test('files round-trip: names (umlauts too), types and bytes', () {
      final parsed = _roundTrip(_build());
      final infos = parsed.findContentInfo(
        disposition: ContentDisposition.attachment,
      );
      expect(infos.map((i) => i.fileName), [
        'Präsentation Übersicht.pdf',
        'IMG_2041.jpg',
      ]);
      final files = attachmentsOf(parsed);
      expect(files.map((f) => f.name), [
        'Präsentation Übersicht.pdf',
        'IMG_2041.jpg',
      ]);
      expect(files.map((f) => f.mimeType), ['application/pdf', 'image/jpeg']);
      expect(files[0].bytes, _binary(5000));
      expect(files[1].bytes, _binary(1234));
    });

    test('the raw message is pure ASCII (filenames are encoded words)', () {
      final raw = _build().renderMessage();
      expect(raw.runes.every((r) => r < 0x80), isTrue);
      expect(raw, contains('=?UTF-8?B?'));
    });

    test('photo marks are written for drafts only', () {
      final sent = attachmentsOf(_roundTrip(_build()));
      expect(sent.map((f) => f.isPhoto), [false, false]);
      expect(_build().renderMessage(), isNot(contains(kPhotoPartHeader)));

      final draft = attachmentsOf(_roundTrip(_build(markPhotos: true)));
      expect(draft.map((f) => f.isPhoto), [false, true]);
    });

    test('a draft without a recipient still builds', () {
      final m = buildAttachmentMessage(
        from: MailAddress(null, 'luca@smail.th-koeln.de'),
        to: const [],
        subject: '',
        body: '',
        attachments: [
          MailAttachmentData(
            name: 'a.txt',
            mimeType: 'text/plain',
            bytes: _binary(10),
          ),
        ],
      );
      expect(attachmentsOf(_roundTrip(m)).single.name, 'a.txt');
    });

    test(
      'estimateEncodedSize stays close to (and not below) the real size',
      () {
        final big = [
          MailAttachmentData(
            name: 'scan.pdf',
            mimeType: 'application/pdf',
            bytes: _binary(800000),
          ),
          MailAttachmentData(
            name: 'photo.jpg',
            mimeType: 'image/jpeg',
            bytes: _binary(300000),
          ),
        ];
        final real = _build(attachments: big).renderMessage().length;
        final estimate = estimateEncodedSize(
          _body.length,
          big.map((a) => a.bytes.length),
        );
        expect(estimate, greaterThanOrEqualTo(real));
        expect(estimate, lessThan(real * 1.03));
      },
    );
  });

  test('the background builder returns the same mail across the isolate',
      () async {
    final m = await buildAttachmentMessageInBackground(
      from: MailAddress(null, 'luca@smail.th-koeln.de'),
      to: [MailAddress(null, 'mueller@th-koeln.de')],
      subject: 'Abgabe – Entwurf',
      body: _body,
      attachments: [
        MailAttachmentData(
          name: 'Präsentation Übersicht.pdf',
          mimeType: 'application/pdf',
          bytes: _binary(5000),
        ),
      ],
    );
    final parsed = _roundTrip(m);
    expect(messageBodyText(parsed), _body);
    final files = attachmentsOf(parsed);
    expect(files.single.name, 'Präsentation Übersicht.pdf');
    expect(files.single.bytes, _binary(5000));
  });

  group('size limit', () {
    test('the allowance is what still fits under the limit', () {
      const limit = 25 * 1024 * 1024;
      final allowance =
          attachmentAllowance(limit, bodyLength: _body.length, count: 2);
      // Base64 costs a third: the files that fit are well under the limit.
      expect(allowance, lessThan(limit * 0.76));
      expect(allowance, greaterThan(limit * 0.70));
      final half = allowance ~/ 2;
      expect(exceedsMailLimit(_body.length, [half, half], limit), isFalse);
      expect(exceedsMailLimit(_body.length, [half, half + 64 * 1024], limit),
          isTrue);
    });

    test('an unknown limit never blocks', () {
      expect(exceedsMailLimit(0, [999999999], null), isFalse);
      expect(exceedsMailLimit(0, [999999999], 0), isFalse);
    });

    test('the error speaks in file sizes', () {
      expect(mailTooBigMessage(20 * 1024 * 1024, 18 * 1024 * 1024),
          contains('20.0 MB'));
      expect(mailTooBigMessage(20 * 1024 * 1024, 18 * 1024 * 1024),
          contains('18.0 MB'));
    });
  });

  group('attachmentFilename', () {
    test('ASCII names pass through', () {
      expect(attachmentFilename('Entwurf v2.pdf'), 'Entwurf v2.pdf');
    });

    test('quotes, backslashes and line breaks are removed', () {
      expect(attachmentFilename('a"b\\c\r\nd.pdf'), 'abc  d.pdf');
      expect(attachmentFilename('  '), 'Attachment');
    });

    test('long non-ASCII names split into words that each decode', () {
      final name = '${'Präsentationsübersicht ' * 6}.pdf';
      final encoded = attachmentFilename(name);
      for (final word in encoded.split(' ')) {
        expect(word.length, lessThanOrEqualTo(75));
      }
      expect(MailCodec.decodeHeader(encoded), name.trim());
    });
  });

  group('attachmentsOf', () {
    test('skips inline cid images', () {
      const raw =
          'From: a@b.de\r\n'
          'Subject: x\r\n'
          'MIME-Version: 1.0\r\n'
          'Content-Type: multipart/related; boundary="r"\r\n'
          '\r\n'
          '--r\r\n'
          'Content-Type: text/html; charset=utf-8\r\n'
          '\r\n'
          '<img src="cid:logo">\r\n'
          '--r\r\n'
          'Content-Type: image/png\r\n'
          'Content-ID: <logo>\r\n'
          'Content-Disposition: inline; filename="logo.png"\r\n'
          'Content-Transfer-Encoding: base64\r\n'
          '\r\n'
          'iVBORw0KGgo=\r\n'
          '--r--\r\n';
      expect(attachmentsOf(MimeMessage.parseFromText(raw)), isEmpty);
    });

    test('a plain text mail has none', () {
      final m = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, 'a@b.de'),
        [MailAddress(null, 'c@d.de')],
        'Hallo',
        subject: 'x',
      );
      expect(attachmentsOf(_roundTrip(m)), isEmpty);
    });
  });

  test('forwardDraft carries the original\'s attachments', () {
    final d = forwardDraft(_roundTrip(_build()));
    expect(d.attachments.map((a) => a.name), [
      'Präsentation Übersicht.pdf',
      'IMG_2041.jpg',
    ]);
    expect(d.attachments.first.bytes, _binary(5000));
    expect(d.body, contains('Viele Grüße'));
  });
}
