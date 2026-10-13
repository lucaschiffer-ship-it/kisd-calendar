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
}
