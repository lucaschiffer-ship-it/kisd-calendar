import 'dart:convert';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'mail_attachments.dart';
import 'mail_service.dart' show MailFolder;

/// Display helpers for the mail UI — pure functions over [MimeMessage], so the
/// list rows, the message view and compose all format a mail the same way.
/// Pinned by `test/mail_display_test.dart`.

// ── List rows ─────────────────────────────────────────────────────────────────

/// Everything a list row shows, derived once per message.
///
/// Decoding a preview is a MIME parse plus several regex passes; doing it in
/// `build` re-ran it for every visible row on every `notifyListeners`, which is
/// most of why the old list stuttered. Cached in an [Expando] on the message
/// itself, so it lives exactly as long as the message object.
class MailRowData {
  const MailRowData({
    required this.title,
    required this.subject,
    required this.preview,
    required this.date,
    required this.hasAttachment,
  });

  /// Sender — or, in Sent and Drafts, the first recipient (as Apple Mail).
  final String title;
  final String subject;
  final String preview;
  final DateTime? date;
  final bool hasAttachment;

  static final _cache = Expando<MailRowData>('MailRowData');

  static MailRowData of(MimeMessage m, MailFolder folder) =>
      _cache[m] ??= MailRowData(
        title: rowTitle(m, folder),
        subject: subjectOf(m),
        preview: mailPreviewText(m),
        date: m.decodeDate()?.toLocal(),
        hasAttachment: _hasAttachment(m),
      );
}

bool _hasAttachment(MimeMessage m) {
  try {
    return m
        .findContentInfo(disposition: ContentDisposition.attachment)
        .isNotEmpty;
  } catch (_) {
    return false;
  }
}

String subjectOf(MimeMessage m) {
  final s = m.decodeSubject()?.trim();
  return (s == null || s.isEmpty) ? '(No subject)' : s;
}

/// Display name for an address: the personal name when there is one.
String addressLabel(MailAddress a) {
  final name = a.personalName?.trim();
  return (name != null && name.isNotEmpty) ? name : a.email;
}

String senderName(MimeMessage m) {
  final from = m.from?.firstOrNull;
  if (from != null) return addressLabel(from);
  final email = m.fromEmail;
  return (email != null && email.isNotEmpty) ? email : 'Unknown';
}

String? senderEmail(MimeMessage m) => m.from?.firstOrNull?.email ?? m.fromEmail;

String rowTitle(MimeMessage m, MailFolder folder) {
  if (folder == MailFolder.sent || folder == MailFolder.drafts) {
    final to = m.to;
    if (to == null || to.isEmpty) {
      return folder == MailFolder.drafts ? 'No Recipients' : senderName(m);
    }
    return to.map(addressLabel).join(', ');
  }
  return senderName(m);
}

/// The initial shown in a sender's avatar: the first letter or digit, so
/// `[KISDspaces] Nina` reads K rather than `[`.
String avatarInitial(String name) {
  final match = RegExp(r'[\p{L}\p{N}]', unicode: true).firstMatch(name);
  return match == null ? '?' : match.group(0)!.toUpperCase();
}

// ── Dates ─────────────────────────────────────────────────────────────────────

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _monthsShort = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];
const _monthsLong = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

String _two(int n) => n.toString().padLeft(2, '0');

String timeLabel(DateTime d) => '${_two(d.hour)}:${_two(d.minute)}';

/// The list's date column: `14:12` today, `Yesterday`, the weekday within the
/// last week, `12 Oct` this year, `12.10.25` before that.
String listDateLabel(DateTime? date, {DateTime? now}) {
  if (date == null) return '';
  final n = now ?? DateTime.now();
  final today = DateTime(n.year, n.month, n.day);
  final day = DateTime(date.year, date.month, date.day);
  final days = today.difference(day).inHours ~/ 24;
  if (days <= 0) return timeLabel(date);
  if (days == 1) return 'Yesterday';
  if (days < 7) return _weekdays[date.weekday - 1];
  if (date.year == n.year) return '${date.day} ${_monthsShort[date.month - 1]}';
  return '${_two(date.day)}.${_two(date.month)}.${_two(date.year % 100)}';
}

/// `Monday, 12 October 2026 at 14:12` — the expanded message header.
String fullDateLabel(DateTime d) =>
    '${_weekdays[d.weekday - 1]}, ${d.day} ${_monthsLong[d.month - 1]} '
    '${d.year} at ${timeLabel(d)}';

/// `12 Oct 2026 at 14:12` — reply attributions and forwarded headers.
String mediumDateLabel(DateTime d) =>
    '${d.day} ${_monthsShort[d.month - 1]} ${d.year} at ${timeLabel(d)}';

// ── Preview ───────────────────────────────────────────────────────────────────

/// The list preview for [m]: plain readable text, whitespace collapsed.
///
/// The list fetch is `BODY.PEEK[TEXT]<0.500>` with no BODYSTRUCTURE, so the
/// message holds the first 500 bytes of its *body* and none of its headers:
/// for a multipart mail that is boundary lines, part headers and a body in
/// quoted-printable or base64, all of which enough_mail would hand back
/// verbatim. This parses that fragment itself. A message that does carry its
/// headers (a full fetch) goes through enough_mail's own decoding.
String mailPreviewText(MimeMessage m, {int maxLength = 300}) {
  final data = m.mimeData;
  // An offline copy saved before PreviewFixImapClient holds only the partial
  // fetch's `<0>` origin marker, not text.
  if (data is TextMimeData && RegExp(r'^<?\d+>$').hasMatch(data.text.trim())) {
    return '';
  }
  if (data != null && !data.containsHeader) {
    final bytes = _bytesOf(data);
    if (bytes != null) return _clean(previewFromRawBody(bytes), maxLength);
  }
  final plain = _safe(m.decodeTextPlainPart);
  if (plain != null && plain.trim().isNotEmpty) return _clean(plain, maxLength);
  final html = _safe(m.decodeTextHtmlPart);
  if (html != null) return _clean(_htmlToPreviewText(html), maxLength);
  return '';
}

String? _safe(String? Function() f) {
  try {
    return f();
  } catch (_) {
    return null;
  }
}

Uint8List? _bytesOf(MimeData data) {
  if (data is BinaryMimeData) return data.data;
  if (data is TextMimeData) {
    final units = data.text.codeUnits;
    // An IMAP literal read as text holds the bytes 1:1 — unless it was already
    // decoded, in which case it is real Unicode and goes back out as UTF-8.
    return units.every((u) => u < 256)
        ? Uint8List.fromList(units)
        : Uint8List.fromList(utf8.encode(data.text));
  }
  return null;
}

/// Readable text from the start of a message body (no message headers).
String previewFromRawBody(Uint8List bytes) {
  // latin1 keeps every byte as one char, so the MIME structure (ASCII) can be
  // parsed as a string and a part's body turned back into its exact bytes.
  final raw = latin1.decode(bytes).replaceAll('\r\n', '\n');
  return _textFromEntity(raw, const {}, 0) ?? '';
}

final _boundaryLine = RegExp(r'^--([^\s]+)\s*$');
final _headerLine = RegExp(r'^[A-Za-z][\w-]*\s*:');

String? _textFromEntity(String raw, Map<String, String> headers, int depth) {
  if (depth > 4) return null;
  final type = (headers['content-type'] ?? '').toLowerCase();
  if (type.startsWith('multipart/') || headers.isEmpty) {
    final parts = _splitMultipart(raw);
    if (parts != null) {
      String? html;
      for (final part in parts) {
        final ptype = (part.headers['content-type'] ?? 'text/plain')
            .toLowerCase();
        if (ptype.startsWith('multipart/')) {
          final t = _textFromEntity(part.body, part.headers, depth + 1);
          if (t != null && t.trim().isNotEmpty) return t;
        } else if (ptype.startsWith('text/plain')) {
          final t = _decodePart(part.body, part.headers);
          if (t.trim().isNotEmpty) return t;
        } else if (ptype.startsWith('text/html')) {
          html ??= _htmlToPreviewText(_decodePart(part.body, part.headers));
        }
      }
      return html;
    }
  }
  if (headers.isNotEmpty) {
    final t = _decodePart(raw, headers);
    return type.startsWith('text/html') ? _htmlToPreviewText(t) : t;
  }
  return _decodeUnknown(raw);
}

class _Part {
  _Part(this.headers, this.body);
  final Map<String, String> headers;
  final String body;
}

/// Splits a (possibly truncated) multipart body on its boundary, which is the
/// first `--token` line within the first few lines (after any preamble).
List<_Part>? _splitMultipart(String raw) {
  final lines = raw.split('\n');
  String? boundary;
  for (var i = 0; i < lines.length && i < 12; i++) {
    final match = _boundaryLine.firstMatch(lines[i]);
    // A real boundary is followed by the part's headers (or a blank line); a
    // `-----` rule in a plain-text mail is not.
    final next = i + 1 < lines.length ? lines[i + 1] : '';
    if (match != null && (next.trim().isEmpty || _headerLine.hasMatch(next))) {
      boundary = match.group(1);
      break;
    }
  }
  if (boundary == null) return null;
  final delimiter = '--$boundary';
  final parts = <_Part>[];
  List<String>? current;
  void flush() {
    final partLines = current;
    if (partLines != null) parts.add(_parsePart(partLines));
  }

  for (final line in lines) {
    if (line.startsWith(delimiter)) {
      flush();
      // The closing delimiter (`--b--`) ends the multipart.
      current = line.trimRight() == '$delimiter--' ? null : <String>[];
    } else {
      current?.add(line);
    }
  }
  flush();
  return parts;
}

_Part _parsePart(List<String> lines) {
  final headers = <String, String>{};
  var i = 0;
  String? lastName;
  for (; i < lines.length; i++) {
    final line = lines[i];
    if (line.trim().isEmpty) {
      i++;
      break;
    }
    if ((line.startsWith(' ') || line.startsWith('\t')) && lastName != null) {
      headers[lastName] = '${headers[lastName]} ${line.trim()}';
      continue;
    }
    final colon = line.indexOf(':');
    if (colon <= 0) {
      // Not a header block at all — the part starts straight with its body.
      return _Part(const {}, lines.join('\n'));
    }
    lastName = line.substring(0, colon).trim().toLowerCase();
    headers[lastName] = line.substring(colon + 1).trim();
  }
  return _Part(headers, lines.skip(i).join('\n'));
}

String _decodePart(String body, Map<String, String> headers) {
  final cte = (headers['content-transfer-encoding'] ?? '').trim().toLowerCase();
  final charset = RegExp(
    r'charset\s*=\s*"?([^";\s]+)',
    caseSensitive: false,
  ).firstMatch(headers['content-type'] ?? '')?.group(1);
  final List<int> bytes = switch (cte) {
    'base64' => _base64Prefix(body),
    'quoted-printable' => quotedPrintableBytes(body),
    _ => body.codeUnits,
  };
  return _decodeCharset(bytes, charset);
}

/// A body whose encoding is unknown: a single-part mail's headers (and so its
/// Content-Transfer-Encoding) are not in the list fetch.
String _decodeUnknown(String raw) {
  final compact = raw.replaceAll(RegExp(r'\s'), '');
  final looksBase64 =
      compact.length >= 16 &&
      RegExp(r'^[A-Za-z0-9+/]+=*$').hasMatch(compact) &&
      raw.trim().split('\n').every((l) => !l.trim().contains(' '));
  String text;
  if (looksBase64) {
    text = _decodeCharset(_base64Prefix(raw), null);
  } else if (raw.contains('=\n') ||
      RegExp(r'=[0-9A-F]{2}').allMatches(raw).length >= 2) {
    text = _decodeCharset(quotedPrintableBytes(raw), null);
  } else {
    text = _decodeCharset(raw.codeUnits, null);
  }
  return _looksLikeHtml(text) ? _htmlToPreviewText(text) : text;
}

List<int> _base64Prefix(String body) {
  var s = body.replaceAll(RegExp(r'[^A-Za-z0-9+/]'), '');
  // Truncated mid-quantum (or padded): re-pad what can still be decoded.
  final rem = s.length % 4;
  if (rem == 1) {
    s = s.substring(0, s.length - 1);
  } else if (rem > 0) {
    s = s + '=' * (4 - rem);
  }
  try {
    return base64.decode(s);
  } catch (_) {
    return const [];
  }
}

/// Quoted-printable → bytes. Tolerates a fragment cut off mid-escape.
List<int> quotedPrintableBytes(String s) {
  final out = <int>[];
  final input = s.replaceAll('\r\n', '\n');
  for (var i = 0; i < input.length; i++) {
    final c = input.codeUnitAt(i);
    if (c != 0x3D) {
      out.add(c & 0xFF);
      continue;
    }
    if (i + 1 < input.length && input[i + 1] == '\n') {
      i += 1; // soft line break
      continue;
    }
    if (i + 2 < input.length) {
      final v = int.tryParse(input.substring(i + 1, i + 3), radix: 16);
      if (v != null) {
        out.add(v);
        i += 2;
        continue;
      }
    } else {
      break; // `=` or `=X` at the very end: the fetch cut the escape off
    }
    out.add(c);
  }
  return out;
}

String _decodeCharset(List<int> bytes, String? charset) {
  final cs = charset?.toLowerCase();
  if (cs != null && cs != 'utf-8' && cs != 'utf8' && cs != 'us-ascii') {
    if (cs.contains('8859') || cs.contains('1252') || cs == 'latin1') {
      return latin1.decode(bytes, allowInvalid: true);
    }
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  // Undeclared and not valid UTF-8 — most likely Latin-1.
  if (cs == null && text.contains('�') && '�'.allMatches(text).length > 2) {
    return latin1.decode(bytes, allowInvalid: true);
  }
  return text;
}

bool _looksLikeHtml(String s) => RegExp(
  r'<(html|body|div|p|br|table|span|a|td|head|style|!doctype)\b',
  caseSensitive: false,
).hasMatch(s);

String _htmlToPreviewText(String html) {
  var s = html
      .replaceAll(RegExp(r'<!--[\s\S]*?(-->|$)'), ' ')
      .replaceAll(
        RegExp(
          r'<(style|script|head|title)\b[\s\S]*?(</\1\s*>|$)',
          caseSensitive: false,
        ),
        ' ',
      )
      .replaceAll(RegExp(r'<[^>]*>'), ' ')
      // A tag cut off by the 500-byte fetch.
      .replaceAll(RegExp(r'<[^>]*$'), ' ');
  if (s.contains('&')) {
    s = html_parser.parseFragment(s).text ?? s;
  }
  return s;
}

/// Invisible characters newsletters pad their preheader with.
final _invisible = RegExp('[​-‏͏­﻿⁠᠎ ]');

String _clean(String s, int maxLength) {
  var t = s
      .replaceAll(_invisible, '')
      .replaceAll(' ', ' ')
      .replaceAll('�', '')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
  if (t.length > maxLength) t = t.substring(0, maxLength);
  return t;
}

// ── Plain text from HTML (quoting, forwarding) ───────────────────────────────

const _blockTags = {
  'p',
  'div',
  'tr',
  'li',
  'ul',
  'ol',
  'table',
  'h1',
  'h2',
  'h3',
  'h4',
  'h5',
  'h6',
  'blockquote',
  'section',
  'article',
  'header',
  'footer',
  'pre',
  'hr',
};

/// Readable plain text from an HTML body: block elements become line breaks,
/// `<br>` a newline, scripts and styles dropped, entities decoded.
String htmlToPlainText(String html) {
  final doc = html_parser.parse(html);
  doc.querySelectorAll('script, style, head, title').forEach((e) => e.remove());
  final buffer = StringBuffer();
  void walk(dom.Node node) {
    if (node is dom.Text) {
      buffer.write(node.text.replaceAll(RegExp(r'\s+'), ' '));
      return;
    }
    if (node is dom.Element) {
      final tag = node.localName ?? '';
      if (tag == 'br') {
        buffer.write('\n');
        return;
      }
      final block = _blockTags.contains(tag);
      if (block) buffer.write('\n');
      for (final child in node.nodes) {
        walk(child);
      }
      if (block) buffer.write('\n');
      return;
    }
    for (final child in node.nodes) {
      walk(child);
    }
  }

  walk(doc.body ?? doc.documentElement ?? doc);
  return buffer
      .toString()
      .split('\n')
      .map((l) => l.trim())
      .join('\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

/// The readable text of a fully fetched message, for quoting and forwarding.
String messageBodyText(MimeMessage m) {
  final plain = _safe(m.decodeTextPlainPart);
  if (plain != null && plain.trim().isNotEmpty) {
    return plain.replaceAll('\r\n', '\n').trimRight();
  }
  final html = _safe(m.decodeTextHtmlPart);
  if (html != null && html.trim().isNotEmpty) return htmlToPlainText(html);
  return '';
}

// ── Compose prefill ──────────────────────────────────────────────────────────

/// What a compose sheet opens with.
class ComposeDraft {
  const ComposeDraft({
    this.to = '',
    this.subject = '',
    this.body = '',
    this.from,
    this.attachments = const [],
  });

  final String to;
  final String subject;
  final String body;

  /// Files compose opens with: a forwarded mail's attachments.
  final List<MailAttachmentData> attachments;

  /// Only set when reopening a saved draft; otherwise compose fills in the
  /// account address itself.
  final String? from;
}

String _prefixed(String? subject, String prefix, List<String> known) {
  final s = (subject ?? '').trim();
  final lower = s.toLowerCase();
  if (known.any((k) => lower.startsWith(k))) return s;
  return s.isEmpty ? '$prefix:' : '$prefix: $s';
}

/// `Re:` once — German clients' `AW:` counts as already prefixed.
String replySubject(String? subject) =>
    _prefixed(subject, 'Re', const ['re:', 'aw:']);

String forwardSubject(String? subject) =>
    _prefixed(subject, 'Fwd', const ['fwd:', 'fw:', 'wg:']);

String _addressLine(MailAddress a) {
  final name = a.personalName?.trim();
  return (name != null && name.isNotEmpty) ? '$name <${a.email}>' : a.email;
}

ComposeDraft replyDraft(MimeMessage original) {
  final replyTo =
      original.replyTo?.firstOrNull ??
      original.decodeSender().firstOrNull ??
      original.from?.firstOrNull;
  final date = original.decodeDate()?.toLocal();
  final from = original.from?.firstOrNull;
  final who = from != null ? _addressLine(from) : senderName(original);
  final text = messageBodyText(original);
  final quoted = text.isEmpty
      ? ''
      : '\n\n${date != null ? 'On ${mediumDateLabel(date)}, ' : ''}'
            '$who wrote:\n\n'
            '${text.split('\n').map((l) => l.isEmpty ? '>' : '> $l').join('\n')}';
  return ComposeDraft(
    to: replyTo?.email ?? '',
    subject: replySubject(original.decodeSubject()),
    body: quoted,
  );
}

ComposeDraft forwardDraft(MimeMessage original) {
  final date = original.decodeDate()?.toLocal();
  final from = original.from?.firstOrNull;
  final to = original.to ?? const <MailAddress>[];
  final header = StringBuffer('\n\n---------- Forwarded message ---------\n');
  header.writeln(
    'From: ${from != null ? _addressLine(from) : senderName(original)}',
  );
  if (date != null) header.writeln('Date: ${mediumDateLabel(date)}');
  header.writeln('Subject: ${original.decodeSubject() ?? ''}');
  if (to.isNotEmpty) header.writeln('To: ${to.map(_addressLine).join(', ')}');
  return ComposeDraft(
    subject: forwardSubject(original.decodeSubject()),
    body: '$header\n${messageBodyText(original)}',
    attachments: attachmentsOf(original),
  );
}

/// A `mailto:` link → compose. Only the first address: sending supports one.
ComposeDraft mailtoDraft(Uri uri) {
  final to = Uri.decodeComponent(uri.path).split(',').first.trim();
  final q = uri.queryParameters;
  return ComposeDraft(
    to: to,
    subject: q['subject'] ?? '',
    body: q['body'] ?? '',
  );
}

/// A saved draft reopened in compose.
ComposeDraft draftFromMessage(MimeMessage draft) => ComposeDraft(
  to: draft.to?.firstOrNull?.email ?? '',
  subject: draft.decodeSubject() ?? '',
  body: messageBodyText(draft),
  from: draft.from?.firstOrNull?.email,
);

// ── Sizes ─────────────────────────────────────────────────────────────────────

String byteSizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).round()} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
