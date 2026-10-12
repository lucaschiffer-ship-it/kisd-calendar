import 'dart:math' as math;

import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

/// Builds the one HTML document the message view shows: the mail header and
/// the mail body together, so the header scrolls natively *with* the mail
/// instead of sitting pinned above a separate web view.
///
/// Pure Dart with plain-data inputs, so it can run in an isolate — parsing a
/// large newsletter takes long enough to drop frames on the UI thread.
/// Pinned by `test/mail_html_test.dart`.

/// The custom scheme the document is loaded under. The page's own origin, so
/// the bundled fonts it serves are same-origin (WebKit fetches `@font-face`
/// with CORS, and `CustomSchemeResponse` cannot send CORS headers).
const kMailScheme = 'kisd-mail';
const kMailBaseUrl = '$kMailScheme://local/';

/// The bundled fonts the document asks for, by file name under `google_fonts/`.
const kMailFontFiles = [
  'SpaceGrotesk-SemiBold.ttf',
  'SpaceGrotesk-Bold.ttf',
  'Inter-Regular.ttf',
  'Inter-SemiBold.ttf',
];

/// How a mail's own styling is treated — the "smart, like Apple" policy.
enum MailRenderMode {
  /// Plain or lightly styled mail: takes on the app's colours, dark included.
  themed,

  /// The mail ships its own dark-mode CSS: its media queries are pointed at
  /// the app's theme and it styles itself.
  darkNative,

  /// A designed newsletter with its own colours: shown as designed — in dark
  /// mode on a white rounded card, since forcing dark onto it breaks it.
  original,
}

/// Colours as CSS strings, from the app's colour scheme.
class MailHtmlColors {
  const MailHtmlColors({
    required this.dark,
    required this.background,
    required this.text,
    required this.secondary,
    required this.tertiary,
    required this.divider,
    required this.accent,
    required this.surface,
  });

  final bool dark;
  final String background;
  final String text;
  final String secondary;
  final String tertiary;
  final String divider;
  final String accent;

  /// Attachment tiles.
  final String surface;
}

class MailAttachmentTile {
  const MailAttachmentTile({required this.name, required this.size});

  final String name;

  /// Human label (`120 KB`), or empty when unknown.
  final String size;
}

/// Everything the document needs, as plain data.
class MailDocumentSpec {
  const MailDocumentSpec({
    required this.colors,
    required this.senderName,
    required this.senderEmail,
    required this.avatarInitial,
    required this.avatarTint,
    required this.avatarText,
    required this.time,
    required this.toSummary,
    required this.to,
    required this.cc,
    required this.fullDate,
    required this.subject,
    required this.html,
    required this.plain,
    required this.attachments,
    required this.viewportWidth,
    required this.topPadding,
    required this.bottomPadding,
  });

  final MailHtmlColors colors;
  final String senderName;
  final String? senderEmail;
  final String avatarInitial;
  final String avatarTint;
  final String avatarText;
  final String time;
  final String toSummary;
  final List<String> to;
  final List<String> cc;
  final String? fullDate;
  final String subject;

  /// The mail's HTML body, if it has one — preferred over [plain].
  final String? html;
  final String? plain;
  final List<MailAttachmentTile> attachments;

  /// CSS px the page is laid out at (the screen width).
  final double viewportWidth;
  final double topPadding;
  final double bottomPadding;
}

// ── Classification ────────────────────────────────────────────────────────────

final _darkSupport = RegExp(
  r'prefers-color-scheme\s*:\s*dark'
  r'|<meta[^>]+name\s*=\s*["\x27]?(?:supported-)?color-scheme["\x27]?[^>]*content\s*=\s*["\x27][^"\x27]*dark'
  r'|color-scheme\s*:\s*[^;}"\x27]*dark',
  caseSensitive: false,
);

final _bgcolorAttr = RegExp(
  r'\bbgcolor\s*=\s*["\x27]?\s*([^"\x27\s>]+)',
  caseSensitive: false,
);

final _bgDeclaration = RegExp(
  r'background(-color|-image)?\s*:\s*([^;"\x27}]+)',
  caseSensitive: false,
);

final _bgImageAttr = RegExp(
  r'<(?:td|table|body|div)\b[^>]*\bbackground\s*=\s*["\x27]?[^"\x27\s>]+',
  caseSensitive: false,
);

MailRenderMode classifyMailHtml(String html) {
  if (_darkSupport.hasMatch(html)) return MailRenderMode.darkNative;
  if (_bgImageAttr.hasMatch(html)) return MailRenderMode.original;
  for (final m in _bgcolorAttr.allMatches(html)) {
    if (!isNeutralBackground(m.group(1)!)) return MailRenderMode.original;
  }
  for (final m in _bgDeclaration.allMatches(html)) {
    final value = m.group(2)!.trim();
    if (value.toLowerCase().contains('url(')) return MailRenderMode.original;
    if (m.group(1)?.toLowerCase() == '-image') continue;
    if (!isNeutralBackground(value)) return MailRenderMode.original;
  }
  return MailRenderMode.themed;
}

/// True for backgrounds that carry no design of their own: transparent, none,
/// white or near-white. Simple mails often set `bgcolor="#ffffff"`, and a
/// themed rendering is exactly right for them.
bool isNeutralBackground(String value) {
  final v = value.trim().toLowerCase();
  if (v.isEmpty) return true;
  const neutralWords = {
    'none',
    'transparent',
    'inherit',
    'initial',
    'unset',
    'revert',
    'white',
    'currentcolor',
    'auto',
    '#fff',
    '#ffffff',
    '0',
  };
  if (neutralWords.contains(v)) return true;
  final rgba = parseCssColor(v);
  if (rgba == null) {
    // A shorthand like `#f4f4f4 none repeat`: judge it by its colour token.
    // Gradients and unknown colour names are design; layout keywords are not.
    if (v.contains('gradient')) return false;
    for (final token in v.split(RegExp(r'\s+'))) {
      final c = parseCssColor(token);
      if (c != null) return _isNeutral(c);
    }
    const layoutWords = {
      'none',
      'repeat',
      'no-repeat',
      'repeat-x',
      'repeat-y',
      'center',
      'top',
      'left',
      'right',
      'bottom',
      'scroll',
      'fixed',
      'cover',
      'contain',
      'auto',
      'initial',
      'inherit',
      'transparent',
      'padding-box',
      'border-box',
      'content-box',
      '!important',
    };
    return v
        .split(RegExp(r'\s+'))
        .every(
          (t) => layoutWords.contains(t) || !RegExp(r'^[a-z]+$').hasMatch(t),
        );
  }
  return _isNeutral(rgba);
}

bool _isNeutral(List<double> c) {
  if (c[3] < 0.1) return true;
  double lin(double v) {
    final s = v / 255;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  final l = 0.2126 * lin(c[0]) + 0.7152 * lin(c[1]) + 0.0722 * lin(c[2]);
  return l >= 0.9;
}

/// `[r, g, b, a]` (0–255, alpha 0–1), or null when [value] is not a colour
/// this parser knows.
List<double>? parseCssColor(String value) {
  final v = value.trim().toLowerCase().replaceAll('!important', '').trim();
  const named = {
    'white': [255, 255, 255],
    'black': [0, 0, 0],
    'red': [255, 0, 0],
    'green': [0, 128, 0],
    'blue': [0, 0, 255],
    'gray': [128, 128, 128],
    'grey': [128, 128, 128],
    'silver': [192, 192, 192],
    'whitesmoke': [245, 245, 245],
    'snow': [255, 250, 250],
    'ghostwhite': [248, 248, 255],
    'ivory': [255, 255, 240],
    'linen': [250, 240, 230],
    'navy': [0, 0, 128],
    'yellow': [255, 255, 0],
    'orange': [255, 165, 0],
  };
  if (v == 'transparent') return [0, 0, 0, 0];
  if (named.containsKey(v)) {
    final n = named[v]!;
    return [n[0].toDouble(), n[1].toDouble(), n[2].toDouble(), 1];
  }
  final hex = RegExp(r'^#?([0-9a-f]{3,8})$').firstMatch(v)?.group(1);
  if (hex != null && (v.startsWith('#') || hex.length == 6)) {
    String h = hex;
    if (h.length == 3 || h.length == 4) {
      h = h.split('').map((c) => '$c$c').join();
    }
    if (h.length != 6 && h.length != 8) return null;
    final r = int.parse(h.substring(0, 2), radix: 16).toDouble();
    final g = int.parse(h.substring(2, 4), radix: 16).toDouble();
    final b = int.parse(h.substring(4, 6), radix: 16).toDouble();
    final a = h.length == 8
        ? int.parse(h.substring(6, 8), radix: 16) / 255
        : 1.0;
    return [r, g, b, a];
  }
  final fn = RegExp(r'^rgba?\(([^)]*)\)$').firstMatch(v)?.group(1);
  if (fn != null) {
    final parts = fn
        .split(RegExp(r'[\s,/]+'))
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.length < 3) return null;
    double channel(String p) => p.endsWith('%')
        ? (double.tryParse(p.substring(0, p.length - 1)) ?? 0) * 2.55
        : double.tryParse(p) ?? 0;
    final a = parts.length > 3
        ? (parts[3].endsWith('%')
              ? (double.tryParse(parts[3].substring(0, parts[3].length - 1)) ??
                        100) /
                    100
              : double.tryParse(parts[3]) ?? 1)
        : 1.0;
    return [channel(parts[0]), channel(parts[1]), channel(parts[2]), a];
  }
  return null;
}

// ── CSS rewrites ──────────────────────────────────────────────────────────────

/// Points a mail's `prefers-color-scheme` queries at the *app's* theme. The web
/// view would answer them from the system appearance, which can differ from
/// the theme picked in Settings.
String rewriteColorSchemeQueries(String html, {required bool dark}) {
  const always = '(min-width: 0px)';
  const never = '(max-width: 0px)';
  return html
      .replaceAll(
        RegExp(
          r'\(\s*prefers-color-scheme\s*:\s*dark\s*\)',
          caseSensitive: false,
        ),
        dark ? always : never,
      )
      .replaceAll(
        RegExp(
          r'\(\s*prefers-color-scheme\s*:\s*light\s*\)',
          caseSensitive: false,
        ),
        dark ? never : always,
      );
}

/// Retargets a mail's `html` / `body` selectors at the wrapper it is rendered
/// in, so its page styles (background, font, colour) land on the mail and not
/// on the whole document — which also holds our header.
String rewriteBodySelectors(String css) {
  final htmlBody = RegExp(
    r'(^|[\s,>+~(])html\s+body(?=$|[\s,.#:\[>+~)])',
    caseSensitive: false,
  );
  final single = RegExp(
    r'(^|[\s,>+~(])(?:html|body)(?=$|[\s,.#:\[>+~)])',
    caseSensitive: false,
  );
  return css.replaceAllMapped(RegExp(r'([^{}]+)\{'), (m) {
    final prelude = m.group(1)!;
    // At-rule preludes (`@media …`) hold no selectors to retarget.
    if (prelude.trimLeft().startsWith('@')) return m.group(0)!;
    final rewritten = prelude
        .replaceAllMapped(htmlBody, (b) => '${b.group(1)}#kisd-body')
        .replaceAllMapped(single, (b) => '${b.group(1)}#kisd-body');
    return '$rewritten{';
  });
}

final _fixedTableWidth = RegExp(
  r'<table\b[^>]*?\bwidth\s*=\s*["\x27]?\s*(\d{3,4})(?:px)?["\x27\s>]',
  caseSensitive: false,
);
final _fixedStyleWidth = RegExp(
  r'<(?:table|div|td|center)\b[^>]*?\bstyle\s*=\s*["\x27][^"\x27]*?(?<![-\w])width\s*:\s*(\d{3,4})px',
  caseSensitive: false,
);

/// The widest fixed layout width a mail declares (`width="600"` tables and
/// the like), or null. `max-width` layouts are responsive and don't count.
double? fixedLayoutWidth(String html) {
  var widest = 0;
  for (final re in [_fixedTableWidth, _fixedStyleWidth]) {
    for (final m in re.allMatches(html)) {
      final w = int.tryParse(m.group(1)!) ?? 0;
      if (w > widest) widest = w;
    }
  }
  return widest >= 400 ? widest.toDouble() : null;
}

// ── Plain text ────────────────────────────────────────────────────────────────

String escapeHtml(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

final _linkPattern = RegExp(
  r'(https?://[^\s<>"]+|www\.[^\s<>"]+)|([\w.+-]+@[\w-]+(?:\.[\w-]+)+)',
  caseSensitive: false,
);

/// Turns URLs and addresses in already-escaped text into links.
String linkify(String escaped) {
  return escaped.replaceAllMapped(_linkPattern, (m) {
    final url = m.group(1);
    if (url != null) {
      final trail = RegExp(r'[.,;:!?)\]]+$').firstMatch(url)?.group(0) ?? '';
      final core = url.substring(0, url.length - trail.length);
      final href = core.toLowerCase().startsWith('www.')
          ? 'http://$core'
          : core;
      return '<a href="$href">$core</a>$trail';
    }
    final email = m.group(2)!;
    return '<a href="mailto:$email">$email</a>';
  });
}

/// A plain-text mail as HTML: escaped, linkified, line breaks kept, and `>`
/// quote runs as nested blockquotes.
String plainTextToHtml(String text) {
  final lines = text.replaceAll('\r\n', '\n').split('\n');
  // Trailing blank lines would only add empty space under the mail.
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  return _blocks(lines, 0);
}

String _blocks(List<String> lines, int depth) {
  final out = StringBuffer();
  final run = <String>[];
  var quoting = false;

  void flush() {
    if (run.isEmpty) return;
    if (quoting && depth < 6) {
      final inner = run.map((l) {
        final s = l.substring(1);
        return s.startsWith(' ') ? s.substring(1) : s;
      }).toList();
      out.write(
        '<blockquote class="kisd-q">${_blocks(inner, depth + 1)}</blockquote>',
      );
    } else {
      final escaped = run.map((l) => linkify(escapeHtml(l))).join('\n');
      out.write('<div class="kisd-pre">$escaped</div>');
    }
    run.clear();
  }

  for (final line in lines) {
    final isQuote = line.startsWith('>');
    if (isQuote != quoting) {
      flush();
      quoting = isQuote;
    }
    run.add(line);
  }
  flush();
  return out.toString();
}

// ── Document ──────────────────────────────────────────────────────────────────

class _MailBody {
  _MailBody(
    this.mode,
    this.headExtras,
    this.bodyAttrs,
    this.content,
    this.zoom,
  );

  final MailRenderMode mode;
  final String headExtras;
  final String bodyAttrs;
  final String content;
  final double zoom;
}

_MailBody _prepareHtml(String html, MailDocumentSpec spec) {
  final dark = spec.colors.dark;
  final mode = classifyMailHtml(html);
  final source = rewriteColorSchemeQueries(html, dark: dark);
  final doc = html_parser.parse(source);

  // No scripts (JS is off anyway), no frames, no meta refresh — which would
  // navigate even with JS off — and no viewport or base of the mail's own.
  for (final selector in const [
    'script',
    'noscript',
    'base',
    'meta',
    'title',
    'iframe',
    'frame',
    'frameset',
    'object',
    'embed',
    'applet',
  ]) {
    for (final e in doc.querySelectorAll(selector)) {
      e.remove();
    }
  }

  final head = StringBuffer();
  for (final e in doc.querySelectorAll('style')) {
    head.write('<style>${rewriteBodySelectors(e.text)}</style>');
    e.remove();
  }
  for (final e in doc.querySelectorAll('link')) {
    if ((e.attributes['rel'] ?? '').toLowerCase().contains('stylesheet')) {
      head.write(e.outerHtml);
    }
    e.remove();
  }

  final body = doc.body;
  final attrs = StringBuffer();
  final style = StringBuffer();
  if (body != null) {
    final a = body.attributes;
    if (a['bgcolor'] != null) style.write('background-color:${a['bgcolor']};');
    if (a['text'] != null) style.write('color:${a['text']};');
    if (a['background'] != null) {
      style.write("background-image:url('${a['background']}');");
    }
    if (a['style'] != null) style.write(a['style']);
    if (a['class'] != null) {
      attrs.write(' class="kisd-mode-${mode.name} ${escapeHtml(a['class']!)}"');
    }
  }
  if (attrs.isEmpty) attrs.write(' class="kisd-mode-${mode.name}"');
  if (style.isNotEmpty) attrs.write(' style="${escapeHtml(style.toString())}"');

  final available = mode == MailRenderMode.original
      ? spec.viewportWidth - (dark ? 20 : 0)
      : spec.viewportWidth - 40;
  final declared = fixedLayoutWidth(html);
  final zoom = declared != null && declared > available
      ? (available / declared).clamp(0.3, 1.0).toDouble()
      : 1.0;

  return _MailBody(
    mode,
    head.toString(),
    attrs.toString(),
    body?.innerHtml ?? doc.outerHtml,
    zoom,
  );
}

String buildMailDocument(MailDocumentSpec spec) {
  final c = spec.colors;
  final htmlSource = spec.html;
  final _MailBody body;
  if (htmlSource != null && htmlSource.trim().isNotEmpty) {
    body = _prepareHtml(htmlSource, spec);
  } else {
    body = _MailBody(
      MailRenderMode.themed,
      '',
      ' class="kisd-mode-themed kisd-plain"',
      plainTextToHtml(spec.plain ?? ''),
      1.0,
    );
  }

  final mode = body.mode;
  final cardInDark = mode == MailRenderMode.original && c.dark;
  final scheme = c.dark ? 'dark' : 'light';

  final css = StringBuffer()
    ..write(_fontFaces)
    ..write('''
html,body{margin:0!important;padding:0!important;background:${c.background}!important;-webkit-text-size-adjust:100%!important;}
body{color-scheme:${c.dark ? 'dark' : 'light'};}
#kisd-page{padding:${spec.topPadding.round()}px 0 ${spec.bottomPadding.round()}px;}
''')
    ..write(_headerCss(c))
    ..write(_bodyCss(c, mode, body.zoom))
    ..write(_attachmentCss(c));

  final header = _headerHtml(spec);
  final content = cardInDark
      ? '<div id="kisd-card"><div id="kisd-body"${body.bodyAttrs}>${_zoomed(body)}</div></div>'
      : '<div id="kisd-body"${body.bodyAttrs}>${_zoomed(body)}</div>';

  return '<!DOCTYPE html><html><head><meta charset="utf-8">'
      '<meta name="viewport" content="width=device-width, initial-scale=1, '
      'maximum-scale=5, viewport-fit=cover">'
      '<meta name="color-scheme" content="$scheme">'
      '<style>$css</style>${body.headExtras}</head><body>'
      '<div id="kisd-page">$header'
      '<div id="kisd-scroll">$content</div>'
      '${_attachmentsHtml(spec.attachments)}'
      '</div></body></html>';
}

String _zoomed(_MailBody body) => body.zoom < 1
    ? '<div id="kisd-zoom" style="zoom:${body.zoom.toStringAsFixed(3)}">${body.content}</div>'
    : body.content;

String get _fontFaces {
  final b = StringBuffer();
  void face(String family, String file, int weight) => b.write(
    "@font-face{font-family:'$family';src:url('fonts/$file');"
    'font-weight:$weight;font-style:normal;}',
  );
  face('KISD Grotesk', 'SpaceGrotesk-SemiBold.ttf', 600);
  face('KISD Grotesk', 'SpaceGrotesk-Bold.ttf', 700);
  face('KISD Inter', 'Inter-Regular.ttf', 400);
  face('KISD Inter', 'Inter-SemiBold.ttf', 600);
  return b.toString();
}

const _grotesk = "'KISD Grotesk',-apple-system,system-ui,sans-serif";
const _inter = "'KISD Inter',-apple-system,system-ui,sans-serif";

// Every header rule is `#kisd-hdr`-scoped and !important: the mail's own CSS
// shares this document, and a newsletter's `* { font-family: … !important }`
// or `div { padding: 20px }` must not restyle it. The reset comes first so the
// more specific rules below win over it.
String _headerCss(MailHtmlColors c) =>
    '''
#kisd-hdr,#kisd-hdr *,#kisd-att,#kisd-att *{all:revert!important;box-sizing:border-box!important;-webkit-tap-highlight-color:transparent!important;}
#kisd-hdr{display:block!important;padding:0 20px!important;font-family:$_inter!important;color:${c.text}!important;}
#kisd-hdr details{display:block!important;}
#kisd-hdr summary{display:flex!important;align-items:flex-start!important;gap:12px!important;list-style:none!important;padding:8px 0 14px!important;cursor:pointer!important;outline:none!important;}
#kisd-hdr summary::-webkit-details-marker{display:none!important;}
#kisd-hdr .av{flex:none!important;display:flex!important;align-items:center!important;justify-content:center!important;width:44px!important;height:44px!important;border-radius:22px!important;font:600 19px/1 $_grotesk!important;}
#kisd-hdr .who{display:block!important;flex:1!important;min-width:0!important;padding-top:1px!important;}
#kisd-hdr .r1{display:flex!important;align-items:baseline!important;gap:10px!important;}
#kisd-hdr .name{display:block!important;flex:1!important;min-width:0!important;font:600 17px/1.3 $_grotesk!important;letter-spacing:-0.2px!important;color:${c.text}!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;}
#kisd-hdr .time{display:block!important;flex:none!important;font:400 15px/1.3 $_inter!important;color:${c.secondary}!important;}
#kisd-hdr .r2{display:flex!important;align-items:center!important;margin-top:3px!important;font:400 15px/1.35 $_inter!important;color:${c.secondary}!important;white-space:nowrap!important;overflow:hidden!important;}
#kisd-hdr .r2 .lbl{color:${c.text}!important;margin-right:4px!important;}
#kisd-hdr .r2 .to{overflow:hidden!important;text-overflow:ellipsis!important;}
#kisd-hdr .chev{flex:none!important;display:inline-block!important;margin-left:6px!important;width:7px!important;height:7px!important;border-right:1.5px solid ${c.tertiary}!important;border-bottom:1.5px solid ${c.tertiary}!important;transform:rotate(-45deg)!important;}
#kisd-hdr details[open] .r2{display:none!important;}
#kisd-hdr .more{display:block!important;padding:0 0 14px 56px!important;font:400 14px/1.5 $_inter!important;color:${c.secondary}!important;animation:kisdIn .22s ease-out!important;}
#kisd-hdr .kv{display:flex!important;gap:8px!important;padding:1px 0!important;}
#kisd-hdr .k{display:block!important;flex:none!important;width:42px!important;color:${c.tertiary}!important;}
#kisd-hdr .v{display:block!important;flex:1!important;min-width:0!important;color:${c.text}!important;overflow-wrap:anywhere!important;}
#kisd-hdr a{color:${c.accent}!important;text-decoration:none!important;}
#kisd-hdr .rule{display:block!important;height:0!important;border-top:0.5px solid ${c.divider}!important;margin:0!important;}
#kisd-hdr h1{display:block!important;margin:16px 0 14px!important;font:700 24px/1.22 $_grotesk!important;letter-spacing:-0.4px!important;color:${c.text}!important;overflow-wrap:anywhere!important;}
@keyframes kisdIn{from{opacity:0;transform:translateY(-4px);}to{opacity:1;transform:none;}}
''';

String _bodyCss(MailHtmlColors c, MailRenderMode mode, double zoom) {
  final b = StringBuffer('''
#kisd-scroll{overflow-x:auto;overflow-y:hidden;}
#kisd-body{display:block;word-wrap:break-word;}
#kisd-body img{max-width:100%!important;height:auto;}
#kisd-body .kisd-pre{white-space:pre-wrap;}
#kisd-body blockquote.kisd-q{margin:6px 0!important;padding:0 0 0 12px!important;border-left:2px solid ${c.divider}!important;}
''');
  switch (mode) {
    case MailRenderMode.themed:
      b.write('''
#kisd-body{padding:2px 20px 0;color:${c.text};font:400 16px/1.5 $_inter;}
#kisd-body a{color:${c.accent};}
''');
      if (c.dark) {
        // Nothing in a themed mail has a background worth keeping (that's what
        // put it in this mode), so the theme can take every colour over.
        b.write('''
#kisd-body,#kisd-body *:not(a):not(a *){color:${c.text}!important;background-color:transparent!important;border-color:${c.divider}!important;}
#kisd-body a,#kisd-body a *{color:${c.accent}!important;}
#kisd-body .kisd-q,#kisd-body .kisd-q *:not(a):not(a *){color:${c.secondary}!important;}
''');
      } else {
        b.write('#kisd-body .kisd-q{color:${c.secondary};}');
      }
    case MailRenderMode.darkNative:
      b.write(
        '#kisd-body{padding:2px 12px 0;font:400 16px/1.5 $_inter;'
        'color:${c.text};}',
      );
    case MailRenderMode.original:
      b.write('#kisd-body{padding:0;color:#000;}');
      if (c.dark) {
        b.write(
          '#kisd-card{margin:4px 10px 0;border-radius:14px;'
          'overflow:hidden;background:#fff;color-scheme:light;}'
          '#kisd-card #kisd-body{background-color:#fff;}',
        );
      }
  }
  return b.toString();
}

String _attachmentCss(MailHtmlColors c) =>
    '''
#kisd-att{display:block!important;padding:18px 20px 0!important;}
#kisd-att .t{display:flex!important;align-items:center!important;gap:12px!important;margin:0 0 8px!important;padding:10px 12px!important;border-radius:12px!important;background:${c.surface}!important;}
#kisd-att .ic{display:flex!important;flex:none!important;align-items:center!important;justify-content:center!important;width:38px!important;height:38px!important;border-radius:9px!important;background:${c.accent}22!important;color:${c.accent}!important;font:600 11px/1 $_inter!important;letter-spacing:0.3px!important;}
#kisd-att .tx{display:block!important;flex:1!important;min-width:0!important;}
#kisd-att .n{display:block!important;font:600 15px/1.3 $_inter!important;color:${c.text}!important;white-space:nowrap!important;overflow:hidden!important;text-overflow:ellipsis!important;}
#kisd-att .s{display:block!important;font:400 13px/1.3 $_inter!important;color:${c.secondary}!important;margin-top:2px!important;}
''';

String _headerHtml(MailDocumentSpec s) {
  final more = StringBuffer();
  void row(String k, String v) => more.write(
    '<div class="kv"><span class="k">$k</span><span class="v">$v</span></div>',
  );
  final email = s.senderEmail;
  final from = email == null || email.isEmpty
      ? escapeHtml(s.senderName)
      : email == s.senderName
      ? '<a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>'
      : '${escapeHtml(s.senderName)} &lt;<a href="mailto:${escapeHtml(email)}">${escapeHtml(email)}</a>&gt;';
  row('From', from);
  if (s.to.isNotEmpty) row('To', s.to.map(escapeHtml).join(', '));
  if (s.cc.isNotEmpty) row('Cc', s.cc.map(escapeHtml).join(', '));
  if (s.fullDate != null) row('Date', escapeHtml(s.fullDate!));

  return '<div id="kisd-hdr"><details><summary>'
      '<span class="av" style="background:${s.avatarTint}!important;'
      'color:${s.avatarText}!important">${escapeHtml(s.avatarInitial)}</span>'
      '<span class="who"><span class="r1">'
      '<span class="name">${escapeHtml(s.senderName)}</span>'
      '<span class="time">${escapeHtml(s.time)}</span></span>'
      '<span class="r2"><span class="lbl">To:</span>'
      '<span class="to">${escapeHtml(s.toSummary)}</span>'
      '<span class="chev"></span></span></span>'
      '</summary><div class="more">$more</div></details>'
      '<div class="rule"></div>'
      '<h1>${escapeHtml(s.subject)}</h1></div>';
}

String _attachmentsHtml(List<MailAttachmentTile> tiles) {
  if (tiles.isEmpty) return '';
  final b = StringBuffer('<div id="kisd-att">');
  for (final t in tiles) {
    final dot = t.name.lastIndexOf('.');
    final ext = dot > 0 && dot < t.name.length - 1
        ? t.name.substring(dot + 1).toUpperCase()
        : 'FILE';
    b.write(
      '<div class="t"><span class="ic">'
      '${escapeHtml(ext.length > 4 ? ext.substring(0, 4) : ext)}</span>'
      '<span class="tx"><span class="n">${escapeHtml(t.name)}</span>'
      '${t.size.isEmpty ? '' : '<span class="s">${escapeHtml(t.size)}</span>'}'
      '</span></div>',
    );
  }
  b.write('</div>');
  return b.toString();
}

/// For tests and debugging: the parsed DOM of a built document.
dom.Document parseMailDocument(String html) => html_parser.parse(html);
