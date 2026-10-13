import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:enough_mail/enough_mail.dart';

/// Building mails that carry files — pure functions, pinned by
/// `test/mail_attachments_test.dart`.
///
/// Only ever used when there *are* attachments: a text-only mail keeps going
/// through `MessageBuilder.buildSimpleTextMessage`, exactly as before.

/// A file going out with a mail, or coming back from a saved draft or a
/// forwarded original.
class MailAttachmentData {
  const MailAttachmentData({
    required this.name,
    required this.mimeType,
    required this.bytes,
    this.isPhoto = false,
  });

  final String name;
  final String mimeType;
  final Uint8List bytes;

  /// A picture from the photo library or the camera: offered for scaling at
  /// Send. A file picked in Files is sent untouched, even when it's an image.
  final bool isPhoto;
}

/// Marks a draft's photo parts, so a reopened draft can still offer scaling.
/// Written into drafts only — sent mail stays free of it.
const kPhotoPartHeader = 'X-KISD-Photo';

/// A multipart/mixed mail: the text first, then one part per file.
///
/// The root's content type is set explicitly. Setting `text` on the builder
/// instead makes enough_mail write the text's quoted-printable
/// `Content-Transfer-Encoding` onto the multipart root, which is invalid.
MimeMessage buildAttachmentMessage({
  required MailAddress from,
  required List<MailAddress> to,
  required String subject,
  required String body,
  required List<MailAttachmentData> attachments,
  bool markPhotos = false,
}) {
  // Same settings as buildSimpleTextMessage: utf-8, Q-encoded subject,
  // quoted-printable text.
  final builder = MessageBuilder()
    ..from = [from]
    ..to = to
    ..subject = subject
    ..subjectEncoding = HeaderEncoding.Q
    ..characterSet = CharacterSet.utf8
    ..setContentType(MediaSubtype.multipartMixed.mediaType);
  builder.addTextPlain(
    body,
    transferEncoding: TransferEncoding.quotedPrintable,
  );
  for (final a in attachments) {
    final part = builder.addBinary(
      a.bytes,
      _mediaType(a.mimeType),
      filename: attachmentFilename(a.name),
    );
    if (markPhotos && a.isPhoto) part.setHeader(kPhotoPartHeader, '1');
  }
  return builder.buildMimeMessage();
}

/// [buildAttachmentMessage] on a background isolate: base64-encoding a few
/// MB is long enough to stall the Send spinner. Top-level on purpose — a
/// closure made inside `MailService` could capture the service (and its
/// listeners), which can't cross to another isolate.
Future<MimeMessage> buildAttachmentMessageInBackground({
  required MailAddress from,
  required List<MailAddress> to,
  required String subject,
  required String body,
  required List<MailAttachmentData> attachments,
  bool markPhotos = false,
}) =>
    Isolate.run(
      () => buildAttachmentMessage(
        from: from,
        to: to,
        subject: subject,
        body: body,
        attachments: attachments,
        markPhotos: markPhotos,
      ),
    );

MediaType _mediaType(String mimeType) {
  try {
    if (mimeType.contains('/')) return MediaType.fromText(mimeType);
  } catch (_) {}
  return MediaType.fromText('application/octet-stream');
}

/// The filename as it goes into the `filename=` / `name=` parameters.
///
/// enough_mail writes those raw, so a name like `Präsentation.pdf` would
/// reach some clients garbled. Non-ASCII names become RFC 2047 encoded words
/// (what Outlook and Apple Mail send), which enough_mail's own parser
/// decodes again. Quotes, backslashes and line breaks would break the
/// header, so they go first.
String attachmentFilename(String name) {
  var clean = name
      .replaceAll(RegExp(r'[\r\n\t]'), ' ')
      .replaceAll(RegExp(r'["\\]'), '')
      .trim();
  if (clean.isEmpty) clean = 'Attachment';
  if (clean.runes.every((r) => r >= 0x20 && r < 0x7f)) return clean;

  // Each word carries at most 45 bytes (60 base64 chars, within the 75-char
  // word limit), split on whole characters so no UTF-8 sequence is cut.
  final words = <String>[];
  var chunk = <int>[];
  for (final rune in clean.runes) {
    final bytes = utf8.encode(String.fromCharCode(rune));
    if (chunk.length + bytes.length > 45) {
      words.add(_encodedWord(chunk));
      chunk = <int>[];
    }
    chunk.addAll(bytes);
  }
  if (chunk.isNotEmpty) words.add(_encodedWord(chunk));
  return words.join(' ');
}

String _encodedWord(List<int> bytes) => '=?UTF-8?B?${base64.encode(bytes)}?=';

/// The size of the mail on the wire, estimated before building it: base64
/// grows a file by 4/3 plus a line break every 76 characters, and each part
/// brings its own headers. Used for the running total and the limit check,
/// so it errs a little on the large side.
int estimateEncodedSize(int bodyLength, Iterable<int> attachmentSizes) {
  var total = 2048 + bodyLength * 3; // headers + worst-case QP for the text
  for (final size in attachmentSizes) {
    final base64Length = ((size + 2) ~/ 3) * 4;
    total += base64Length + (base64Length ~/ 76) * 2 + 512;
  }
  return total;
}

/// How many bytes of files fit into a mail of at most [limit] bytes on the
/// wire — the inverse of [estimateEncodedSize]. What the user can attach is
/// this, not the server's figure: base64 makes every file a third bigger.
int attachmentAllowance(int limit, {int bodyLength = 0, int count = 1}) {
  final room = limit - 2048 - bodyLength * 3 - count * 512;
  if (room <= 0) return 0;
  return (room * 3 * 76) ~/ (4 * 78);
}

/// Whether files of [sizes] with a body of [bodyLength] exceed [limit] on
/// the wire. An unknown limit never does — the server still has its say.
bool exceedsMailLimit(int bodyLength, Iterable<int> sizes, int? limit) =>
    limit != null && limit > 0 && estimateEncodedSize(bodyLength, sizes) > limit;

/// The error shown when the files don't fit, in file sizes — the numbers
/// the user sees on the tiles.
String mailTooBigMessage(int attachedBytes, int allowance) =>
    'The attachments add up to ${_mb(attachedBytes)} — the TH mail server '
    'takes at most ${_mb(allowance)} of attachments per mail. Remove one or '
    'choose a smaller photo size.';

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';

/// The files a mail carries — attachments only, never inline `cid:` images
/// (those belong to an HTML body that forwarding doesn't keep). Same lookup
/// as the message view's tiles.
List<MailAttachmentData> attachmentsOf(MimeMessage message) {
  final List<ContentInfo> infos;
  try {
    infos = message.findContentInfo(disposition: ContentDisposition.attachment);
  } catch (_) {
    return const [];
  }
  final result = <MailAttachmentData>[];
  for (final info in infos) {
    try {
      final part = message.getPart(info.fetchId);
      final bytes = part?.decodeContentBinary();
      if (part == null || bytes == null) continue;
      result.add(
        MailAttachmentData(
          name: info.fileName ?? 'Attachment',
          mimeType: info.mediaType?.text ?? 'application/octet-stream',
          bytes: bytes,
          isPhoto: part.getHeaderValue(kPhotoPartHeader)?.trim() == '1',
        ),
      );
    } catch (_) {
      // One unreadable part must not cost the others.
    }
  }
  return result;
}
