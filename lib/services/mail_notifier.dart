import 'dart:convert';
import 'dart:math' show max;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'mail_display.dart';
import 'notification_service.dart';

/// New-mail notifications: which mails to announce, what a notification
/// says, and the state both the app and the background check share.
///
/// Two places announce. While the app is open, the inbox refreshes that IDLE
/// (or polling) starts (`MailService`). In the background, the check iOS runs
/// every so often (`mail_background_check.dart`). Both go through
/// [planMailAnnouncements] with the same stored [MailNotifyMark], so a mail
/// is announced once — and never after the app has shown it.
/// Pinned by `test/mail_notifier_test.dart`.

/// At most this many notifications per check; the mark moves past the rest.
const maxMailAnnouncements = 5;

/// iOS groups the notifications by this.
const mailThreadIdentifier = 'kisd-mail';

/// How far the inbox has been announced or shown: every UID up to [upTo]
/// counts as known. Only valid for one account and one UIDVALIDITY — a UID
/// names a different mail under another.
@immutable
class MailNotifyMark {
  const MailNotifyMark({
    required this.owner,
    required this.uidValidity,
    required this.upTo,
  });

  final String owner;
  final int uidValidity;
  final int upTo;

  bool belongsTo(String owner, int uidValidity) =>
      _norm(this.owner) == _norm(owner) && this.uidValidity == uidValidity;

  static String _norm(String id) => id.trim().toLowerCase();

  Map<String, Object> toJson() => {
    'owner': owner,
    'uidValidity': uidValidity,
    'upTo': upTo,
  };

  static MailNotifyMark? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return MailNotifyMark(
        owner: j['owner'] as String,
        uidValidity: j['uidValidity'] as int,
        upTo: j['upTo'] as int,
      );
    } catch (_) {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MailNotifyMark &&
      other.owner == owner &&
      other.uidValidity == uidValidity &&
      other.upTo == upTo;

  @override
  int get hashCode => Object.hash(owner, uidValidity, upTo);

  @override
  String toString() => 'MailNotifyMark($owner, $uidValidity, $upTo)';
}

/// What a check announces — newest first — and the mark to store after.
class MailAnnouncements {
  const MailAnnouncements(this.uids, this.mark);

  final List<int> uids;
  final MailNotifyMark mark;
}

/// Decides which of [inbox] to announce: unread mails above the stored mark.
///
/// Without a mark for this account and UIDVALIDITY (first check, another
/// account, the server renumbered the inbox) nothing is announced and the
/// mark starts at the newest mail — announcing every unread mail of the
/// inbox at once would be a flood, not news. [uidNext] moves the mark past
/// mails that were deleted before anyone saw them.
MailAnnouncements planMailAnnouncements({
  required MailNotifyMark? stored,
  required String owner,
  required int uidValidity,
  int? uidNext,
  required Iterable<({int uid, bool seen})> inbox,
}) {
  var highest = uidNext == null ? 0 : uidNext - 1;
  for (final m in inbox) {
    highest = max(highest, m.uid);
  }
  if (stored == null || !stored.belongsTo(owner, uidValidity)) {
    return MailAnnouncements(
      const [],
      MailNotifyMark(owner: owner, uidValidity: uidValidity, upTo: highest),
    );
  }
  final fresh = {
    for (final m in inbox)
      if (m.uid > stored.upTo && !m.seen) m.uid,
  }.toList()..sort((a, b) => b.compareTo(a));
  return MailAnnouncements(
    fresh.take(maxMailAnnouncements).toList(),
    MailNotifyMark(
      owner: owner,
      uidValidity: uidValidity,
      upTo: max(stored.upTo, highest),
    ),
  );
}

/// The notification id of inbox mail [uid] — inside the mail range, so a
/// mail notification only ever replaces or cancels another mail's. The top
/// of the range is left to [mailPausedNoticeId].
int mailNotificationId(int uid) {
  const span = NotificationService.mailIdMax - NotificationService.mailIdMin;
  return NotificationService.mailIdMin + uid % span;
}

/// The "notifications paused" notice — in the mail range, so an account
/// switch (`cancelMail`) removes it too, but never a mail's id.
const mailPausedNoticeId = NotificationService.mailIdMax;

/// Refused logins in a row after which the background check posts the
/// paused notice — once per streak.
const mailPausedNoticeAfter = 3;

/// How long the background check waits after its [refusals]th refused login
/// in a row: 1 h, 2 h, 4 h, then 8 h each time.
///
/// A refusal isn't always a wrong password — this server also answers
/// "authentication failure" while it throttles logins, and that clears in
/// about an hour — so the check tries again by itself. The growing gap keeps
/// a really changed password to a few failed logins a day.
Duration refusalBackoff(int refusals) =>
    Duration(hours: 1 << (refusals.clamp(1, 4) - 1));

// RFC 5530 response codes, plus ALERT.
const _refusalCodes = {
  'ALERT',
  'UNAVAILABLE',
  'AUTHENTICATIONFAILED',
  'AUTHORIZATIONFAILED',
  'EXPIRED',
  'PRIVACYREQUIRED',
  'CONTACTADMIN',
  'NOPERM',
  'INUSE',
  'LIMIT',
  'SERVERBUG',
  'CANNOT',
};

const _refusalPhrases = [
  'authentication failure',
  'authentication failed',
  'invalid credentials',
  'too many',
  'try again',
  'unavailable',
];

/// What the check log keeps of a refused login: the server's response code
/// (`[UNAVAILABLE]`, `[LIMIT]`…) or one of a few known phrases, else
/// `other` — never the server's own words, which can echo the username. It
/// is what tells a throttle from a wrong password on the phone.
String refusalCode(String? serverText) {
  final text = serverText ?? '';
  final code = RegExp(r'\[([A-Za-z]+)').firstMatch(text)?.group(1);
  if (code != null && _refusalCodes.contains(code.toUpperCase())) {
    return '[${code.toUpperCase()}]';
  }
  final lower = text.toLowerCase();
  for (final phrase in _refusalPhrases) {
    if (lower.contains(phrase)) return phrase;
  }
  return 'other';
}

/// The background check's wait after refused logins: [refusals] in a row,
/// the last one answered with a wait until [notBefore].
@immutable
class MailLoginBackoff {
  const MailLoginBackoff({required this.refusals, required this.notBefore});

  final int refusals;
  final DateTime notBefore;

  Map<String, Object> toJson() => {
    'refusals': refusals,
    'notBefore': notBefore.millisecondsSinceEpoch,
  };

  static MailLoginBackoff? fromJson(String? raw) {
    if (raw == null) return null;
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      return MailLoginBackoff(
        refusals: j['refusals'] as int,
        notBefore: DateTime.fromMillisecondsSinceEpoch(j['notBefore'] as int),
      );
    } catch (_) {
      return null;
    }
  }
}

/// Log entries the app writes when its own connection logs in start with
/// this — notes between the checks, not checks.
const appLoginLogPrefix = 'app logged in';

/// The tap payload's id: the UID is only meaningful with its UIDVALIDITY.
String mailPayloadId(int uidValidity, int uid) => '$uidValidity:$uid';

/// The (uidValidity, uid) of a mail notification's payload id.
(int, int)? parseMailPayloadId(String id) {
  final parts = id.split(':');
  if (parts.length != 2) return null;
  final validity = int.tryParse(parts[0]);
  final uid = int.tryParse(parts[1]);
  if (validity == null || uid == null) return null;
  return (validity, uid);
}

/// One notification as iOS shows it: the sender, the subject, the preview.
class MailNotificationContent {
  const MailNotificationContent({
    required this.title,
    required this.subtitle,
    required this.body,
  });

  final String title;
  final String? subtitle;
  final String body;
}

/// Apple Mail's layout. A mail without a preview (an HTML newsletter whose
/// first bytes are all CSS) shows its subject as the body instead — iOS
/// shows nothing for a notification with an empty body.
MailNotificationContent mailNotificationContent(MimeMessage m) {
  final subject = subjectOf(m);
  final preview = mailPreviewText(m, maxLength: 180);
  return MailNotificationContent(
    title: senderName(m),
    subtitle: preview.isEmpty ? null : subject,
    body: preview.isEmpty ? subject : preview,
  );
}

/// The settings and stored state behind mail notifications.
///
/// The background check runs in a second isolate and writes the mark, the
/// login backoff and the log, so those go through [SharedPreferencesAsync],
/// which has no cache: each isolate reads what the other wrote. Not the
/// legacy API with `reload()` — a reload in flight replaces the app's whole
/// cache and can drop another feature's write made meanwhile. Only the
/// opt-in is legacy: `MailCheckTask.swift` reads its `flutter.` key.
class MailNotifier {
  MailNotifier._();

  static const enabledKey = 'mail_notify_enabled';
  static const markKey = 'mail_notify_mark_v1';
  static const backoffKey = 'mail_notify_backoff_v1';
  // Before 16 Oct 2026 a refused login paused the check until the app logged
  // in; that flag is dropped wherever the backoff is read.
  static const legacyPausedKey = 'mail_notify_paused';
  static const logKey = 'mail_check_log_v1';
  static const _logSize = 100;

  static SharedPreferencesAsync get _store => SharedPreferencesAsync();

  /// Talks to `MailCheckTask.swift`: schedules the background check, and in
  /// the background engine posts notifications and reports it is done.
  static const channel = MethodChannel('kisd/mail_check');

  /// The user's opt-in. A device setting, so it survives sign-out.
  static final ValueNotifier<bool> enabled = ValueNotifier<bool>(false);

  static Future<void> loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(enabledKey) ?? false;
    // iOS forgets a submitted request when the app is reinstalled or
    // updated; asking again at every launch keeps one pending.
    if (enabled.value) await _invoke('schedule');
  }

  static Future<void> setEnabled(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(enabledKey, v);
    enabled.value = v;
    if (v) await NotificationService.instance.requestPermission();
    await _invoke(v ? 'schedule' : 'cancel');
  }

  static Future<void> _invoke(String method) async {
    try {
      await channel.invokeMethod<void>(method);
    } catch (e) {
      if (kDebugMode) debugPrint('[mail-notify] $method failed: $e');
    }
  }

  /// The opt-in as stored, for the background isolate — it never ran
  /// [loadPrefs], and the user may switch it off while a check runs. The
  /// reload is safe there: nothing else in that isolate holds preferences.
  static Future<bool> isEnabledInBackground() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.reload();
    return prefs.getBool(enabledKey) ?? false;
  }

  static Future<MailNotifyMark?> readMark() async =>
      MailNotifyMark.fromJson(await _store.getString(markKey));

  /// Stores [mark] unless the stored one already reaches further for the
  /// same inbox — the app and the background check may both have checked.
  static Future<void> writeMark(MailNotifyMark mark) async {
    final stored = await readMark();
    if (stored != null &&
        stored.belongsTo(mark.owner, mark.uidValidity) &&
        stored.upTo >= mark.upTo) {
      return;
    }
    await _store.setString(markKey, jsonEncode(mark.toJson()));
  }

  /// The background check's wait after refused logins, if one is running.
  static Future<MailLoginBackoff?> readBackoff() async {
    final store = _store;
    await store.remove(legacyPausedKey);
    return MailLoginBackoff.fromJson(await store.getString(backoffKey));
  }

  /// Records a refused login at [now] and returns how many there have been
  /// in a row; the check waits [refusalBackoff] of that before the next.
  static Future<int> noteRefused(DateTime now) async {
    final refusals = ((await readBackoff())?.refusals ?? 0) + 1;
    final backoff = MailLoginBackoff(
      refusals: refusals,
      notBefore: now.add(refusalBackoff(refusals)),
    );
    await _store.setString(backoffKey, jsonEncode(backoff.toJson()));
    return refusals;
  }

  /// A login worked — the check's or the app's: the wait ends. Returns the
  /// refusals it cleared, 0 when there was no wait.
  static Future<int> clearBackoff() async {
    final backoff = await readBackoff();
    if (backoff == null) return 0;
    await _store.remove(backoffKey);
    return backoff.refusals;
  }

  /// Records when a background check ran and how it went — only times and
  /// outcomes, never an address or a subject. Settings shows it, so the
  /// real gaps iOS leaves between checks can be read off the phone.
  static Future<void> logRun(DateTime at, String outcome) async {
    final log = await _store.getStringList(logKey) ?? const [];
    final next = [...log, '${at.millisecondsSinceEpoch}|$outcome'];
    await _store.setStringList(
      logKey,
      next.length > _logSize ? next.sublist(next.length - _logSize) : next,
    );
  }

  /// The logged background checks, newest first.
  static Future<List<(DateTime, String)>> runLog() async {
    final out = <(DateTime, String)>[];
    for (final line in await _store.getStringList(logKey) ?? const <String>[]) {
      final bar = line.indexOf('|');
      final ms = int.tryParse(bar < 0 ? line : line.substring(0, bar));
      if (ms == null) continue;
      out.add((
        DateTime.fromMillisecondsSinceEpoch(ms),
        bar < 0 ? '' : line.substring(bar + 1),
      ));
    }
    return out.reversed.toList();
  }

  /// Account switch: the mark, the backoff and the log belong to the old
  /// account; its notifications go too. The opt-in stays.
  static Future<void> clear() async {
    await _store.remove(markKey);
    await _store.remove(backoffKey);
    await _store.remove(legacyPausedKey);
    await _store.remove(logKey);
    await NotificationService.instance.cancelMail();
  }
}
