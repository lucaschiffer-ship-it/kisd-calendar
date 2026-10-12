import 'dart:convert';
import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// What [MailOfflineCache.readIndex] returns: whose mail it is, which inbox
/// generation its UIDs belong to, and the list rows in inbox order.
class MailCacheIndex {
  const MailCacheIndex({
    required this.owner,
    required this.uidValidity,
    required this.messages,
  });

  final String owner;
  final int uidValidity;
  final List<MimeMessage> messages;
}

/// On-disk copy of the newest inbox messages, so the Mail tab still has
/// something to show — the list and the full mails — without a connection.
///
/// Lives in Library/Caches/mail_offline: excluded from backups, and iOS may
/// purge it under storage pressure, which only costs a re-download.
/// - `index.json` — the owner's Campus ID, the inbox's UIDVALIDITY, and per
///   message what its list row needs (envelope, flags, size, the short body
///   preview). Loading the list never parses a full mail, so it stays cheap.
/// - `<uid>.eml` — a full mail's raw RFC 822 bytes, as the server sent them.
///
/// Inbox only: UIDs are per mailbox, so a Sent or Trash UID can share its
/// number with an unrelated inbox mail.
///
/// Every file operation runs one at a time, in call order, so a prune can't
/// delete a file another write is halfway through.
class MailOfflineCache {
  MailOfflineCache({Future<Directory> Function()? baseDirectory})
    : _baseDirectory = baseDirectory ?? getApplicationCacheDirectory;

  /// The newest inbox messages kept — the inbox list's own fetch size, so
  /// offline shows the same list as online.
  static const maxMessages = 50;

  /// Mails above this keep their list row but not their body: one big
  /// attachment would otherwise outweigh the other 49 mails put together.
  static const maxMessageBytes = 5 * 1024 * 1024;

  static const _version = 1;
  static const _indexName = 'index.json';

  final Future<Directory> Function() _baseDirectory;
  Future<void> _queue = Future.value();

  Future<T> _serial<T>(Future<T> Function() op) {
    final result = _queue.then((_) => op());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<Directory> _dir() async =>
      Directory('${(await _baseDirectory()).path}/mail_offline');

  static int? _uidOf(String fileName) => fileName.endsWith('.eml')
      ? int.tryParse(fileName.substring(0, fileName.length - 4))
      : null;

  /// The saved list, or null when there is none or it can't be read.
  Future<MailCacheIndex?> readIndex() => _serial(() async {
    final file = File('${(await _dir()).path}/$_indexName');
    if (!await file.exists()) return null;
    try {
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (json['version'] != _version) return null;
      return MailCacheIndex(
        owner: json['owner'] as String,
        uidValidity: json['uidValidity'] as int,
        messages: [
          for (final m in json['messages'] as List)
            decodeMessage(m as Map<String, dynamic>),
        ],
      );
    } catch (_) {
      return null; // unreadable — the next successful inbox fetch rewrites it
    }
  });

  /// Replaces the saved list with the first [maxMessages] of [messages].
  ///
  /// Saved bodies are dropped when [owner] or [uidValidity] differ from the
  /// list they were saved under: their UIDs no longer name the same mails.
  Future<void> writeIndex({
    required String owner,
    required int uidValidity,
    required List<MimeMessage> messages,
  }) {
    // Encoded now, not when the queue gets to it — by then the caller's list
    // may already hold something else.
    final json = jsonEncode({
      'version': _version,
      'owner': owner,
      'uidValidity': uidValidity,
      'messages': [
        for (final m in messages.take(maxMessages))
          if (m.uid != null) encodeMessage(m),
      ],
    });
    return _serial(() async {
      final dir = await _dir();
      await dir.create(recursive: true);
      final file = File('${dir.path}/$_indexName');
      if (await file.exists()) {
        Map<String, dynamic>? old;
        try {
          old = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        } catch (_) {}
        if (old == null ||
            old['owner'] != owner ||
            old['uidValidity'] != uidValidity) {
          await _deleteBodies(dir, keep: const {});
        }
      }
      // Write-then-rename: a crash mid-write must not leave a torn index.
      final tmp = File('${dir.path}/$_indexName.tmp');
      await tmp.writeAsString(json, flush: true);
      await tmp.rename(file.path);
    });
  }

  /// UIDs whose full mail is saved.
  Future<Set<int>> bodyUids() => _serial(() async {
    final dir = await _dir();
    if (!await dir.exists()) return <int>{};
    return {
      await for (final e in dir.list())
        ?_uidOf(e.uri.pathSegments.last),
    };
  });

  /// Saves a full mail's raw bytes under [uid].
  Future<void> writeBody(int uid, Uint8List bytes) => _serial(() async {
    final dir = await _dir();
    await dir.create(recursive: true);
    final tmp = File('${dir.path}/$uid.eml.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename('${dir.path}/$uid.eml');
  });

  /// The saved full mail for [uid], or null.
  Future<MimeMessage?> readBody(int uid) => _serial(() async {
    final file = File('${(await _dir()).path}/$uid.eml');
    try {
      if (!await file.exists()) return null;
      return MimeMessage.parseFromData(await file.readAsBytes())..uid = uid;
    } catch (_) {
      return null;
    }
  });

  /// Deletes the saved bodies not in [keep], plus any leftover temp files.
  Future<void> prune(Set<int> keep) => _serial(() async {
    final dir = await _dir();
    if (await dir.exists()) await _deleteBodies(dir, keep: keep);
  });

  Future<void> _deleteBodies(Directory dir, {required Set<int> keep}) async {
    await for (final e in dir.list()) {
      final name = e.uri.pathSegments.last;
      if (name == _indexName) continue;
      final uid = _uidOf(name);
      if (uid != null && keep.contains(uid)) continue;
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// Deletes everything — for an account switch.
  Future<void> clear() => _serial(() async {
    final dir = await _dir();
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// A list row as JSON: what `fetchInbox`'s ENVELOPE fetch gave it, plus the
  /// raw preview bytes, so [decodeMessage] rebuilds the same object.
  @visibleForTesting
  static Map<String, dynamic> encodeMessage(MimeMessage m) {
    final env = m.envelope;
    final preview = m.mimeData;
    return {
      'uid': m.uid,
      'flags': m.flags,
      'size': m.size,
      'date': (env?.date ?? m.decodeDate())?.toIso8601String(),
      'subject': env?.subject ?? m.decodeSubject(),
      'from': _encodeAddresses(m.from),
      'sender': _encodeAddresses([?m.sender]),
      'replyTo': _encodeAddresses(m.replyTo),
      'to': _encodeAddresses(m.to),
      'cc': _encodeAddresses(m.cc),
      'bcc': _encodeAddresses(m.bcc),
      'inReplyTo': env?.inReplyTo,
      'messageId': env?.messageId ?? m.getHeaderValue('message-id'),
      if (preview is BinaryMimeData) 'previewBytes': base64Encode(preview.data),
      if (preview is TextMimeData) 'previewText': preview.text,
    };
  }

  /// The inverse of [encodeMessage].
  @visibleForTesting
  static MimeMessage decodeMessage(Map<String, dynamic> json) {
    final date = json['date'] as String?;
    final sender = _decodeAddresses(json['sender']);
    final message = MimeMessage.fromEnvelope(
      Envelope(
        date: date == null ? null : DateTime.parse(date),
        subject: json['subject'] as String?,
        from: _decodeAddresses(json['from']),
        sender: (sender?.isNotEmpty ?? false) ? sender!.first : null,
        replyTo: _decodeAddresses(json['replyTo']),
        to: _decodeAddresses(json['to']),
        cc: _decodeAddresses(json['cc']),
        bcc: _decodeAddresses(json['bcc']),
        inReplyTo: json['inReplyTo'] as String?,
        messageId: json['messageId'] as String?,
      ),
      uid: json['uid'] as int?,
      // Growable: markAsRead/markAsUnread flip `isSeen` in place.
      flags: (json['flags'] as List?)?.cast<String>().toList(),
    )..size = json['size'] as int?;
    final bytes = json['previewBytes'] as String?;
    final text = json['previewText'] as String?;
    if (bytes != null) {
      message.mimeData = BinaryMimeData(
        base64Decode(bytes),
        containsHeader: false,
      );
    } else if (text != null) {
      message.mimeData = TextMimeData(text, containsHeader: false);
    }
    return message;
  }

  static List<Map<String, String?>>? _encodeAddresses(
    List<MailAddress>? addresses,
  ) => addresses
      ?.map((a) => {'name': a.personalName, 'email': a.email})
      .toList();

  static List<MailAddress>? _decodeAddresses(Object? json) => (json as List?)
      ?.map(
        (a) => MailAddress(
          (a as Map<String, dynamic>)['name'] as String?,
          a['email'] as String,
        ),
      )
      .toList();
}
