import 'dart:async';
import 'dart:math' show max;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'imap_preview_fix.dart';
import 'mail_notifier.dart';
import 'mail_service.dart' show MailService;
import 'mail_sync.dart' show listFetchCriteria;
import 'notification_service.dart' show NotificationPayload;

/// The check iOS runs while the app is in the background (a BGAppRefresh or
/// BGProcessing task, see `ios/Runner/MailCheckTask.swift`): one login,
/// EXAMINE the inbox, the list rows of mail above the mark, a notification
/// each, logout.
///
/// It runs in a headless engine of its own, never touching `MailService`
/// (whose connection, timers and lifecycle hooks belong to the app's
/// isolate): its own short-lived client, read-only (EXAMINE, `BODY.PEEK`),
/// so nothing is marked read. iOS gives a refresh about 30 s; the whole
/// check is bounded well inside that, and iOS gives fewer runs to an app
/// whose tasks overrun.
const _budget = Duration(seconds: 20);

/// The newest this many mails above the mark are fetched; older ones are
/// skipped by the mark (a phone off for a week shouldn't fetch a week).
const _fetchAtMost = 20;

// Same options as MailService and LoginService — Keychain lookups are
// scoped by them, and `first_unlock_this_device` is what lets the check
// read the credentials while the phone is locked.
const _storage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
  ),
);

final _inbox = Mailbox(
  encodedName: 'INBOX',
  encodedPath: 'INBOX',
  flags: [],
  pathSeparator: '/',
);

void _log(String message) {
  if (kDebugMode) debugPrint('[mail-check] $message');
}

/// Runs one check and logs it; true unless it failed or ran out of time.
Future<bool> runMailBackgroundCheck() async {
  final started = DateTime.now();
  var outcome = 'failed';
  try {
    outcome = await _check().timeout(_budget);
    return true;
  } on TimeoutException {
    outcome = 'timed out';
    return false;
  } catch (e) {
    _log('failed: $e');
    return false;
  } finally {
    _log(outcome);
    try {
      await MailNotifier.logRun(started, outcome);
    } catch (_) {}
  }
}

Future<String> _check() async {
  if (!await MailNotifier.isEnabledInBackground()) return 'off';
  if (await MailNotifier.isPaused()) return 'paused: login refused';
  final username = await _storage.read(key: 'kisd_username');
  final password = await _storage.read(key: 'kisd_password');
  if (username == null || password == null) return 'signed out';

  final imap = PreviewFixImapClient(isLogEnabled: false);
  try {
    await imap.connectToServer(
      MailService.imapHost,
      MailService.imapPort,
      isSecure: true,
      timeout: const Duration(seconds: 8),
    );
    try {
      await imap.login(username, password);
    } on ImapException {
      await MailNotifier.setPaused(true);
      return 'login refused';
    }
    final box = await imap.examineMailbox(_inbox);
    final validity = box.uidValidity;
    if (validity == null) return 'no UIDVALIDITY';
    final stored = await MailNotifier.readMark();
    // The mark only names mails of this account under this UIDVALIDITY;
    // without one, the plan just starts it at the newest mail.
    final known = stored != null && stored.belongsTo(username, validity)
        ? stored
        : null;

    var fetched = const <MimeMessage>[];
    final uidNext = box.uidNext;
    if (known != null &&
        (uidNext == null || uidNext - 1 > known.upTo) &&
        box.messagesExists > 0) {
      final from = uidNext == null
          ? known.upTo + 1
          : max(known.upTo + 1, uidNext - _fetchAtMost);
      final result = await imap.uidFetchMessages(
        MessageSequence.fromRangeToLast(from, isUidSequence: true),
        listFetchCriteria,
        responseTimeout: const Duration(seconds: 10),
      );
      // `n:*` always includes the newest mail, even below n.
      fetched = [
        for (final m in result.messages)
          if ((m.uid ?? 0) > known.upTo) m,
      ];
    }
    final plan = planMailAnnouncements(
      stored: stored,
      owner: username,
      uidValidity: validity,
      uidNext: uidNext,
      inbox: [
        for (final m in fetched)
          if (m.uid != null) (uid: m.uid!, seen: m.isSeen),
      ],
    );
    final byUid = {for (final m in fetched) m.uid: m};
    final posts = [
      for (final uid in plan.uids)
        if (byUid[uid] case final m?) _post(m, validity, uid),
    ];
    // Read again: the user may have switched it off while the check ran.
    if (posts.isNotEmpty && await MailNotifier.isEnabledInBackground()) {
      await MailNotifier.channel.invokeMethod<void>('post', posts);
    }
    await MailNotifier.writeMark(plan.mark);
    if (known == null) return 'first check';
    return posts.isEmpty ? 'no new mail' : '${posts.length} new';
  } finally {
    unawaited(
      imap.logout().catchError((_) {}).whenComplete(() {
        imap.disconnect().catchError((_) {});
      }),
    );
  }
}

Map<String, Object?> _post(MimeMessage m, int validity, int uid) {
  final c = mailNotificationContent(m);
  return {
    'id': mailNotificationId(uid),
    'title': c.title,
    'subtitle': c.subtitle,
    'body': c.body,
    'thread': mailThreadIdentifier,
    'payload': NotificationPayload(
      type: 'mail',
      id: mailPayloadId(validity, uid),
    ).encode(),
  };
}
