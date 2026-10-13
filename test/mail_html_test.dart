import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/mail_html.dart';

const _darkColors = MailHtmlColors(
  dark: true,
  background: '#000000',
  text: '#FFFFFF',
  secondary: 'rgba(255,255,255,0.5)',
  tertiary: 'rgba(255,255,255,0.35)',
  divider: '#1E1E1E',
  accent: '#EB5A01',
  surface: '#141414',
);

MailDocumentSpec _spec({String? html, String? plain, bool dark = true}) =>
    MailDocumentSpec(
      colors: dark
          ? _darkColors
          : const MailHtmlColors(
              dark: false,
              background: '#FFFFFF',
              text: '#111111',
              secondary: '#666666',
              tertiary: '#888888',
              divider: '#E0E0E0',
              accent: '#EB5A01',
              surface: '#F5F5F5',
            ),
      senderName: 'no-reply@th-koeln.de',
      senderEmail: 'no-reply@th-koeln.de',
      avatarInitial: 'N',
      avatarTint: 'rgba(26,115,232,0.18)',
      avatarText: '#1A73E8',
      time: '14:12',
      toSummary: 'Luca <b>',
      to: const ['Luca'],
      cc: const [],
      fullDate: 'Monday, 12 October 2026 at 14:12',
      subject: 'Anmelde-Einmalpasswort <&>',
      html: html,
      plain: plain,
      attachments: const [MailAttachmentTile(name: 'plan.pdf', size: '120 KB')],
      viewportWidth: 402,
      topPadding: 62,
      bottomPadding: 120,
    );

/// The shape of the TH Köln one-time-password mail: plain paragraphs on a
/// white table — the user's reference for a mail that must go dark.
const _otpLike = '''
<html><head><meta http-equiv="Content-Type" content="text/html; charset=utf-8"></head>
<body bgcolor="#ffffff" style="background-color:#FFFFFF;">
<table width="100%" style="background:#fff"><tr><td style="font-family:Arial;color:#000000">
<p>Guten Tag,</p><p>Sie haben gerade eine Anmeldung bei unserem Dienst gestartet.</p>
<p style="font-size:28px"><b>502363</b></p>
<p><b>Hinweis:</b> Dieser Code ist nur für 2 Minuten gültig.</p>
</td></tr></table></body></html>''';

void main() {
  group('classifyMailHtml', () {
    test('a simple mail on white is themed', () {
      expect(classifyMailHtml(_otpLike), MailRenderMode.themed);
      expect(classifyMailHtml('<p>Hallo</p>'), MailRenderMode.themed);
      expect(
        classifyMailHtml('<td style="background:#ffffff none repeat">'),
        MailRenderMode.themed,
      );
    });

    test('designed newsletters keep their look', () {
      expect(
        classifyMailHtml('<table bgcolor="#eeeeee">'),
        MailRenderMode.original,
      );
      expect(
        classifyMailHtml('<a style="background-color:#EB5A01">Buy</a>'),
        MailRenderMode.original,
      );
      expect(
        classifyMailHtml('<div style="background-image:url(x.png)">'),
        MailRenderMode.original,
      );
      expect(
        classifyMailHtml('<div style="background:linear-gradient(red,blue)">'),
        MailRenderMode.original,
      );
      expect(
        classifyMailHtml('<td background="hero.jpg">'),
        MailRenderMode.original,
      );
    });

    test('mails with their own dark mode style themselves', () {
      expect(
        classifyMailHtml(
          '<style>@media (prefers-color-scheme: dark)'
          '{body{background:#111}}</style><table bgcolor="#eee">',
        ),
        MailRenderMode.darkNative,
      );
      expect(
        classifyMailHtml('<meta name="color-scheme" content="light dark">'),
        MailRenderMode.darkNative,
      );
    });
  });

  test('colour-scheme queries follow the app theme, not the system', () {
    const css =
        '@media (prefers-color-scheme: dark){a{}} '
        '@media (prefers-color-scheme:light){b{}}';
    expect(
      rewriteColorSchemeQueries(css, dark: true),
      '@media (min-width: 0px){a{}} @media (max-width: 0px){b{}}',
    );
    expect(
      rewriteColorSchemeQueries(css, dark: false),
      '@media (max-width: 0px){a{}} @media (min-width: 0px){b{}}',
    );
  });

  test('body and html selectors are retargeted at the mail wrapper', () {
    expect(
      rewriteBodySelectors(
        'body{color:red} html body .x{a:b} .body{c:d} '
        'tbody td{e:f} @media (max-width:600px){body,p{g:h}}',
      ),
      '#kisd-body{color:red} #kisd-body .x{a:b} .body{c:d} '
      'tbody td{e:f} @media (max-width:600px){#kisd-body,p{g:h}}',
    );
  });

  test('fixed layout widths are found, responsive ones ignored', () {
    expect(fixedLayoutWidth('<table width="600" align="center">'), 600);
    expect(fixedLayoutWidth('<table width="100%">'), isNull);
    expect(
      fixedLayoutWidth('<div style="max-width:600px;margin:auto">'),
      isNull,
    );
    expect(fixedLayoutWidth('<td style="padding:0;width:640px">'), 640);
  });

  group('plainTextToHtml', () {
    test('escapes, keeps breaks and linkifies', () {
      final html = plainTextToHtml(
        'Hi <you>,\nsee https://spaces.kisd.de/x. Mail me@th-koeln.de',
      );
      expect(html, contains('Hi &lt;you&gt;,\nsee '));
      expect(
        html,
        contains(
          '<a href="https://spaces.kisd.de/x">https://spaces.kisd.de/x</a>.',
        ),
      );
      expect(html, contains('<a href="mailto:me@th-koeln.de">'));
    });

    test('quote runs become nested blockquotes', () {
      final html = plainTextToHtml('Answer\n> quoted\n>> deeper\nafter');
      expect(
        html,
        '<div class="kisd-pre">Answer</div>'
        '<blockquote class="kisd-q"><div class="kisd-pre">quoted</div>'
        '<blockquote class="kisd-q"><div class="kisd-pre">deeper</div>'
        '</blockquote></blockquote>'
        '<div class="kisd-pre">after</div>',
      );
    });
  });

  group('buildMailDocument', () {
    test('header is escaped and the mail is sanitised', () {
      final doc = buildMailDocument(
        _spec(
          html:
              '<html><head><meta http-equiv="refresh" content="0;url=x">'
              '<script>alert(1)</script><style>body{color:red}</style></head>'
              '<body bgcolor="#ffffff"><p>Hallo</p><iframe src="t"></iframe>'
              '</body></html>',
        ),
      );
      expect(doc, contains('Anmelde-Einmalpasswort &lt;&amp;&gt;'));
      expect(doc, contains('Luca &lt;b&gt;'));
      expect(doc, isNot(contains('<script')));
      expect(doc, isNot(contains('http-equiv="refresh"')));
      expect(doc, isNot(contains('<iframe')));
      expect(doc, contains('#kisd-body{color:red}'));
      expect(doc, contains('class="kisd-mode-themed"'));
      expect(doc, contains('style="background-color:#ffffff;"'));
      expect(doc, contains('plan.pdf'));
    });

    test('a fixed 600 px newsletter is zoomed to fit, on a card in dark', () {
      final doc = buildMailDocument(
        _spec(html: '<table width="600" bgcolor="#eeeeee"><tr><td>x'),
      );
      expect(doc, contains('id="kisd-card"'));
      expect(doc, contains('zoom:0.637'));
    });

    test('no card in light mode', () {
      final doc = buildMailDocument(
        _spec(html: '<table bgcolor="#eeeeee"><tr><td>x', dark: false),
      );
      expect(doc, isNot(contains('id="kisd-card"')));
    });

    test('plain text goes through the same template', () {
      final doc = buildMailDocument(_spec(plain: 'Hallo\n> zitat'));
      expect(doc, contains('kisd-plain'));
      expect(doc, contains('<blockquote class="kisd-q">'));
      expect(doc, contains('id="kisd-hdr"'));
    });

    test('each attachment tile is a link the message view can open', () {
      final dom = parseMailDocument(buildMailDocument(_spec(plain: 'x')));
      final tiles = dom.querySelectorAll('#kisd-att a.t');
      expect(tiles, hasLength(1));
      final href = Uri.parse(tiles.single.attributes['href']!);
      expect(attachmentIndexOf(href), 0);
    });
  });

  test('attachmentIndexOf only reads attachment links', () {
    expect(attachmentIndexOf(Uri.parse('kisd-mail://local/attachment/3')), 3);
    expect(attachmentIndexOf(Uri.parse('kisd-mail://local/')), isNull);
    expect(
      attachmentIndexOf(Uri.parse('kisd-mail://local/fonts/x.ttf')),
      isNull,
    );
    expect(attachmentIndexOf(Uri.parse('https://x.de/attachment/1')), isNull);
  });

  group('splitQuotedPlain', () {
    test('a reply from this app folds below its attribution', () {
      final split = splitQuotedPlain(
        'Thanks, see you then!\n\n'
        'On 12 Oct 2026 at 10:00, Anna <anna@th-koeln.de> wrote:\n\n'
        '> Shall we meet at 3?\n>\n> Anna',
      );
      expect(split?.head, 'Thanks, see you then!');
      expect(split?.quote, startsWith('On 12 Oct 2026'));
      expect(split?.quote, endsWith('> Anna'));
    });

    test('a wrapped German attribution comes along', () {
      final split = splitQuotedPlain(
        'Passt.\n\nAm 12.10.2026 um 10:00 schrieb Anna Müller <\n'
        'anna@th-koeln.de>:\n> Treffen um 3?',
      );
      expect(split?.head, 'Passt.');
      expect(split?.quote, startsWith('Am 12.10.2026'));
    });

    test('Outlook history folds from its separator down', () {
      expect(
        splitQuotedPlain(
          'Danke!\n\n-----Ursprüngliche Nachricht-----\nVon: Anna\n'
          'Gesendet: Montag\nBetreff: Frage\n\nHallo',
        )?.head,
        'Danke!',
      );
      expect(
        splitQuotedPlain(
          'Danke!\n________________________________\nVon: Anna\n'
          'Gesendet: Montag, 12. Oktober 2026 10:00\nAn: Luca\n\nHallo',
        )?.head,
        'Danke!',
      );
      expect(
        splitQuotedPlain(
          'Thanks\n\nFrom: Anna <a@b>\nSent: Monday\nTo: Luca\n\nHi',
        )?.head,
        'Thanks',
      );
    });

    test('an inline answer and a bare quote are left whole', () {
      expect(splitQuotedPlain('> Question?\nAnswer.\n> Other?\nYes.'), isNull);
      expect(splitQuotedPlain('> only quoted text'), isNull);
      expect(splitQuotedPlain('No quote at all.'), isNull);
    });
  });

  test('a mail\'s CSS is confined to its own wrapper', () {
    expect(
      scopeMailCss(
        '/* x{} */ <!-- body{a:b} p,.c:is(a, b){c:d} :root{e:f} '
            '@media (max-width:600px){td{g:h}} '
            '@keyframes k{from{o:0}50%{o:1}to{o:1}} -->',
        '#kisd-b2',
      ),
      '#kisd-b2{a:b}#kisd-b2 p,#kisd-b2 .c:is(a, b){c:d}#kisd-b2{e:f} '
      '@media (max-width:600px){#kisd-b2 td{g:h}} '
      '@keyframes k{from{o:0}50%{o:1}to{o:1}} ',
    );
  });

  group('buildThreadDocument', () {
    ThreadEntrySpec entry(
      String name, {
      String? html,
      String? plain,
      bool open = false,
      bool foldQuotes = true,
      List<MailAttachmentTile> attachments = const [],
      String? unavailable,
    }) => ThreadEntrySpec(
      senderName: name,
      senderEmail: '${name.toLowerCase()}@th-koeln.de',
      avatarInitial: name[0],
      avatarTint: '#333333',
      avatarText: '#FFFFFF',
      time: '12 Oct',
      toSummary: 'Luca',
      to: const ['Luca'],
      cc: const [],
      fullDate: 'Monday, 12 October 2026 at 10:00',
      html: html,
      plain: plain,
      attachments: attachments,
      open: open,
      foldQuotes: foldQuotes,
      unavailable: unavailable,
    );

    ThreadDocumentSpec thread(List<ThreadEntrySpec> entries) =>
        ThreadDocumentSpec(
          colors: _darkColors,
          subject: 'Projektwoche <&>',
          entries: entries,
          viewportWidth: 402,
          topPadding: 62,
          bottomPadding: 120,
        );

    test('cards in order, only the opened one unfolded, previews', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry('Anna', plain: 'Shall we meet at 3?'),
            entry('Luca', plain: 'Sure.\n\nOn Mon, Anna wrote:\n> Shall we'),
            entry('Anna', html: '<p>Great, see you!</p>', open: true),
          ]),
        ),
      );
      expect(dom.querySelector('.kisd-subj')?.text, 'Projektwoche <&>');
      final cards = dom.querySelectorAll('details.kisd-m');
      expect(cards.map((c) => c.attributes.containsKey('open')), [
        false,
        false,
        true,
      ]);
      expect(cards.map((c) => c.querySelector('.kisd-name')?.text), [
        'Anna',
        'Luca',
        'Anna',
      ]);
      // The preview is the new text only, without the quoted history.
      expect(cards[1].querySelector('.kisd-pv')?.text, 'Sure.');
      expect(cards[2].querySelector('.kisd-pv')?.text, 'Great, see you!');
      expect(dom.querySelector('#kisd-b2')?.text, contains('Great, see you!'));
    });

    test('Gmail and Outlook history fold behind a toggle', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry(
              'Anna',
              html:
                  '<div dir="ltr">Yes!</div><div class="gmail_quote">'
                  '<div class="gmail_attr">On Mon, Luca wrote:</div>'
                  '<blockquote class="gmail_quote">Meet?</blockquote></div>',
            ),
            entry(
              'Bob',
              open: true,
              html:
                  '<div>Passt.</div><div id="appendonsend"></div>'
                  '<hr tabindex="-1"><div id="divRplyFwdMsg"><b>Von:</b> Anna'
                  '</div><div>Yes!</div>',
            ),
          ]),
        ),
      );
      final gmail = dom.querySelector('#kisd-b0')!;
      expect(gmail.querySelector('details.kisd-quote .gmail_quote'), isNotNull);
      expect(gmail.querySelector('details.kisd-quote')?.parent, gmail);
      final outlook = dom.querySelector('#kisd-b1')!;
      final fold = outlook.querySelector('details.kisd-quote .kisd-qb')!;
      expect(fold.querySelector('hr'), isNotNull);
      expect(fold.querySelector('#divRplyFwdMsg'), isNotNull);
      expect(fold.text, contains('Yes!'));
      expect(outlook.text, startsWith('Passt.'));
    });

    test('Outlook desktop history folds out of its Word wrapper', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry(
              'Anna',
              open: true,
              html:
                  '<div class="WordSection1">'
                  '<p class="MsoNormal">Danke, passt so.</p>'
                  '<p class="MsoNormal">&nbsp;</p>'
                  '<div><div style="border:none;border-top:solid #E1E1E1 '
                  '1.0pt;padding:3.0pt 0cm 0cm 0cm"><p class="MsoNormal">'
                  '<b>Von:</b> Luca<br><b>Gesendet:</b> Montag, 12. Oktober '
                  '2026 10:00<br><b>Betreff:</b> Frage</p></div></div>'
                  '<p class="MsoNormal">&nbsp;</p>'
                  '<p class="MsoNormal">Hallo Anna, kurze Frage …</p></div>',
            ),
            entry('Bob', plain: 'x'),
          ]),
        ),
      );
      final body = dom.querySelector('#kisd-b0')!;
      final fold = body.querySelector('details.kisd-quote .kisd-qb')!;
      expect(fold.text, contains('Gesendet:'));
      expect(fold.text, contains('Hallo Anna'));
      // What stays above the fold is the new text, without the blank
      // paragraph Outlook leaves before its history.
      final head = body.text.substring(0, body.text.indexOf('•••'));
      expect(head.replaceAll('\u00a0', ' ').trim(), 'Danke, passt so.');
      expect(
        dom
            .querySelectorAll('details.kisd-m')[0]
            .querySelector('.kisd-pv')
            ?.text,
        'Danke, passt so.',
      );
    });

    test('a quote answered below it, and forwards, stay unfolded', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry(
              'Anna',
              html:
                  '<blockquote type="cite">Meet at 3?</blockquote>'
                  '<div>Yes, at 3.</div>',
            ),
            entry(
              'Bob',
              open: true,
              foldQuotes: false,
              plain: 'FYI\n\n-----Original Message-----\nFrom: Carl\n\nhi',
            ),
          ]),
        ),
      );
      expect(dom.querySelectorAll('details.kisd-quote'), isEmpty);
    });

    test('each mail keeps its CSS and its attachments to itself', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry('Anna', html: '<style>p{color:red}</style><p>x</p>'),
            entry(
              'Bob',
              open: true,
              plain: 'y',
              attachments: const [MailAttachmentTile(name: 'a.pdf', size: '')],
            ),
          ]),
        ),
      );
      final styles = dom.querySelectorAll('style').map((s) => s.text).join();
      expect(styles, contains('#kisd-b0 p{color:red}'));
      expect(styles, isNot(contains(RegExp(r'(^|\})\s*p\{color:red'))));
      final link = dom.querySelector('#kisd-th .kisd-att a.t')!;
      final target = threadAttachmentOf(Uri.parse(link.attributes['href']!));
      expect(target?.entry, 1);
      expect(target?.index, 0);
    });

    test('a long run of folded cards collapses its middle', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            for (var i = 0; i < 5; i++) entry('M$i', plain: 'm$i'),
            entry('Last', plain: 'last', open: true),
          ]),
        ),
      );
      final older = dom.querySelector('details.kisd-older')!;
      expect(older.querySelector('summary')?.text, '3 more messages');
      expect(
        older.querySelectorAll('details.kisd-m .kisd-name').map((e) => e.text),
        ['M1', 'M2', 'M3'],
      );
      expect(dom.querySelectorAll('details.kisd-m'), hasLength(6));
    });

    test('a mail too large to download shows a note instead', () {
      final dom = parseMailDocument(
        buildThreadDocument(
          thread([
            entry('Anna', unavailable: 'Too large (12 MB).'),
            entry('Bob', plain: 'x', open: true),
          ]),
        ),
      );
      expect(dom.querySelector('.kisd-note')?.text, 'Too large (12 MB).');
    });
  });

  test('threadAttachmentOf reads conversation attachment links only', () {
    expect(threadAttachmentOf(Uri.parse('kisd-mail://local/attachment/2/1')), (
      entry: 2,
      index: 1,
    ));
    expect(
      threadAttachmentOf(Uri.parse('kisd-mail://local/attachment/2')),
      isNull,
    );
    expect(
      attachmentIndexOf(Uri.parse('kisd-mail://local/attachment/2/1')),
      isNull,
    );
  });
}
