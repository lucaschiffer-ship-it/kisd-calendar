import 'dart:io';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'mail_display.dart';
import 'mail_offline_cache.dart';

/// List previews for inbox mails whose first 500 bytes held no readable text.
///
/// HTML newsletters (every KISDspaces mail among them) open with kilobytes of
/// `<head>` and CSS, so the list fetch's 500-byte window ends before the first
/// visible word. The service already keeps the full bodies of the newest 50
/// inbox mails for offline reading; this reads the preview from that copy —
/// read-only, no network — in a background isolate, since parsing a whole
/// mail on the UI thread would drop frames.
class MailPreviews extends ChangeNotifier {
  MailPreviews._();
  static final instance = MailPreviews._();

  final _byMessageId = <String, String>{};

  /// When each Message-ID was last looked up without success. The offline
  /// copy is written shortly after a fetch, so a miss is retried — later.
  final _missedAt = <String, DateTime>{};
  final _inFlight = <String>{};

  static String? _idOf(MimeMessage m) =>
      (m.envelope?.messageId ?? m.getHeaderValue('message-id'))?.trim();

  /// The offline-copy preview for [m], if one has been read.
  String? previewFor(MimeMessage m) {
    final id = _idOf(m);
    return id == null ? null : _byMessageId[id];
  }

  /// Looks up previews for the [inbox] mails whose own preview came up empty.
  void fillMissing(List<MimeMessage> inbox, String Function(MimeMessage) own) {
    final now = DateTime.now();
    final wanted = <(int, String)>[];
    for (final m in inbox) {
      final uid = m.uid;
      final id = _idOf(m);
      if (uid == null || id == null) continue;
      if (_byMessageId.containsKey(id) || _inFlight.contains(id)) continue;
      final missed = _missedAt[id];
      if (missed != null && now.difference(missed).inSeconds < 20) continue;
      if (own(m).isNotEmpty) continue;
      wanted.add((uid, id));
    }
    if (wanted.isEmpty) return;
    _inFlight.addAll(wanted.map((w) => w.$2));
    _read(wanted);
  }

  Future<void> _read(List<(int, String)> wanted) async {
    Map<String, String> found = const {};
    try {
      final base = (await getApplicationCacheDirectory()).path;
      found = await compute(_readPreviews, (base, wanted));
    } catch (_) {
      // A missing or unreadable copy just leaves those rows without preview.
    }
    final now = DateTime.now();
    for (final (_, id) in wanted) {
      _inFlight.remove(id);
      if (!found.containsKey(id)) _missedAt[id] = now;
    }
    if (found.isEmpty) return;
    _byMessageId.addAll(found);
    notifyListeners();
  }
}

Future<Map<String, String>> _readPreviews(
  (String, List<(int, String)>) job,
) async {
  final (base, items) = job;
  final cache = MailOfflineCache(baseDirectory: () async => Directory(base));
  final out = <String, String>{};
  for (final (uid, id) in items) {
    final full = await cache.readBody(uid);
    if (full == null) continue;
    // The same guard the service applies: the saved body has to be the mail
    // listed under that UID (UIDVALIDITY or account changes).
    final savedId = full.getHeaderValue('message-id')?.trim();
    if (savedId != null && savedId != id) continue;
    final preview = mailPreviewText(full);
    if (preview.isNotEmpty) out[id] = preview;
  }
  return out;
}
