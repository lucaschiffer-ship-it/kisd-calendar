import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_display.dart';
import 'package:kisd_calendar/services/mail_service.dart' show MailFolder;

Uint8List _bytes(String s) => Uint8List.fromList(latin1.encode(s));

String _previewUtf8(String text) => mailPreviewText(
  MimeMessage()
    ..mimeData = BinaryMimeData(
      Uint8List.fromList(utf8.encode(text)),
      containsHeader: false,
    ),
);

String _preview(String raw) => mailPreviewText(
  MimeMessage()..mimeData = BinaryMimeData(_bytes(raw), containsHeader: false),
);

void main() {
  group('list preview from a partial BODY[TEXT] fetch', () {
    test('multipart/alternative: decodes the quoted-printable text part', () {
      const raw =
          '--b1\r\n'
          'Content-Type: text/plain; charset="UTF-8"\r\n'
          'Content-Transfer-Encoding: quoted-printable\r\n'
          '\r\n'
          'Guten Tag, Sie haben gerade eine Anmeldung bei unserem Dienst gest=\r\n'
          'artet. Gr=C3=BC=C3=9Fe\r\n'
          '--b1\r\n'
          'Content-Type: text/html; charset="UTF-8"\r\n'
          '\r\n'
          '<p>ignored</p>';
      expect(
        _preview(raw),
        'Guten Tag, Sie haben gerade eine Anmeldung bei unserem Dienst '
        'gestartet. Grüße',
      );
    });

    test('skips a preamble and descends into nested multiparts', () {
      final b64 = base64.encode(
        utf8.encode('Hallo Luca, anbei die Unterlagen.'),
      );
      final raw =
          'This is a multi-part message in MIME format.\n'
          '--outer\n'
          'Content-Type: multipart/alternative; boundary="inner"\n'
          '\n'
          '--inner\n'
          'Content-Type: text/plain; charset=utf-8\n'
          'Content-Transfer-Encoding: base64\n'
          '\n'
          '$b64\n'
          '--inner--\n';
      expect(_preview(raw), 'Hallo Luca, anbei die Unterlagen.');
    });

    test('html-only part: strips tags, styles and entities', () {
      const raw =
          '--x9\n'
          'Content-Type: text/html; charset=utf-8\n'
          'Content-Transfer-Encoding: quoted-printable\n'
          '\n'
          '<html><head><style>p{color:red}</style></head><body>'
          '<p>Hey&nbsp;luca! Dies ist eine Erinnerung &amp; mehr</p><img src=3D"x';
      expect(_preview(raw), 'Hey luca! Dies ist eine Erinnerung & mehr');
    });

    test('single part, unknown encoding: quoted-printable is decoded', () {
      expect(
        _preview('Sch=C3=B6ne Gr=C3=BC=C3=9Fe aus K=C3=B6ln=\n und so'),
        'Schöne Grüße aus Köln und so',
      );
    });

    test('single part, unknown encoding: base64 is decoded', () {
      final b64 = base64.encode(
        utf8.encode('Lock in interest with Fixed Income'),
      );
      expect(_preview('$b64\n'), 'Lock in interest with Fixed Income');
    });

    test('single part 8-bit UTF-8 and a fetch cut mid-escape', () {
      expect(_previewUtf8('Grüße aus Köln'), 'Grüße aus Köln');
      expect(_preview('Hallo =C3=A4=C3'), 'Hallo ä');
    });

    test('newsletter preheader padding is removed', () {
      expect(
        _previewUtf8('Big sale‌͏ ‌͏ today'),
        'Big sale today',
      );
    });
  });

  group('dates', () {
    final now = DateTime(2026, 10, 13, 15, 0);
    test('today, yesterday, weekday, this year, older', () {
      expect(listDateLabel(DateTime(2026, 10, 13, 9, 5), now: now), '09:05');
      expect(
        listDateLabel(DateTime(2026, 10, 12, 23, 0), now: now),
        'Yesterday',
      );
      expect(listDateLabel(DateTime(2026, 10, 10, 8, 0), now: now), 'Saturday');
      expect(listDateLabel(DateTime(2026, 3, 2), now: now), '2 Mar');
      expect(listDateLabel(DateTime(2025, 12, 24), now: now), '24.12.25');
      expect(listDateLabel(null, now: now), '');
    });

    test('full header date', () {
      expect(
        fullDateLabel(DateTime(2026, 10, 12, 14, 12)),
        'Monday, 12 October 2026 at 14:12',
      );
    });
  });

  group('compose prefill', () {
    test('Re:/Fwd: are added once, German prefixes count', () {
      expect(replySubject('Hallo'), 'Re: Hallo');
      expect(replySubject('Re: Hallo'), 'Re: Hallo');
      expect(replySubject('AW: Hallo'), 'AW: Hallo');
      expect(replySubject(null), 'Re:');
      expect(forwardSubject('Plan'), 'Fwd: Plan');
      expect(forwardSubject('WG: Plan'), 'WG: Plan');
    });

    MimeMessage original() => MessageBuilder.buildSimpleTextMessage(
      MailAddress('Alice Example', 'alice@example.org'),
      [MailAddress(null, 'me@smail.th-koeln.de')],
      'Line one\nLine two',
      subject: 'Projekt',
    );

    test('reply quotes the original and answers the sender', () {
      final d = replyDraft(original());
      expect(d.to, 'alice@example.org');
      expect(d.subject, 'Re: Projekt');
      expect(d.body, contains('Alice Example <alice@example.org> wrote:'));
      expect(d.body, contains('> Line one\n> Line two'));
      expect(d.body.startsWith('\n\n'), isTrue);
    });

    test('a reply names the mail it answers; a forward does not', () {
      final o = original()
        ..setHeader('Message-ID', '<2@x>')
        ..setHeader('References', '<1@x>');
      final d = replyDraft(o);
      expect(d.inReplyTo, '<2@x>');
      expect(d.references, ['<1@x>', '<2@x>']);
      expect(forwardDraft(o).inReplyTo, isNull);
    });

    test('a reopened draft keeps its reply headers', () {
      final draft = original()
        ..setHeader('In-Reply-To', '<2@x>')
        ..setHeader('References', '<1@x> <2@x>');
      final d = draftFromMessage(draft);
      expect(d.inReplyTo, '<2@x>');
      expect(d.references, ['<1@x>', '<2@x>']);
    });

    test('forward leaves To empty and carries the original', () {
      final d = forwardDraft(original());
      expect(d.to, '');
      expect(d.subject, 'Fwd: Projekt');
      expect(d.body, contains('---------- Forwarded message ---------'));
      expect(d.body, contains('From: Alice Example <alice@example.org>'));
      expect(d.body, contains('Line one\nLine two'));
    });

    test('mailto: takes the first address, subject and body', () {
      final d = mailtoDraft(
        Uri.parse('mailto:a@b.de,c@d.de?subject=Hallo%20Welt&body=Text'),
      );
      expect(d.to, 'a@b.de');
      expect(d.subject, 'Hallo Welt');
      expect(d.body, 'Text');
    });
  });

  test('htmlToPlainText keeps paragraph and line breaks', () {
    expect(
      htmlToPlainText(
        '<html><head><style>x{}</style></head><body>'
        '<p>Hallo&nbsp;Luca,</p><p>Zeile 1<br>Zeile 2</p></body></html>',
      ),
      'Hallo Luca,\n\nZeile 1\nZeile 2',
    );
  });

  test('row title shows recipients in Sent and Drafts', () {
    final m = MessageBuilder.buildSimpleTextMessage(
      MailAddress('Me', 'me@x.de'),
      [MailAddress('Bob', 'bob@x.de')],
      'x',
    );
    expect(rowTitle(m, MailFolder.inbox), 'Me');
    expect(rowTitle(m, MailFolder.sent), 'Bob');
  });
}
