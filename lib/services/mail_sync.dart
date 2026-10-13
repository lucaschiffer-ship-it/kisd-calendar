import 'dart:math' show max;

import 'package:enough_mail/enough_mail.dart';

/// The list-row fetch: what a mail row shows, plus the size the offline copy
/// checks and the first 500 body bytes for the preview.
const listFetchCriteria =
    '(FLAGS ENVELOPE UID RFC822.SIZE BODY.PEEK[TEXT]<0.500>)';

/// Mails fetched when a folder's list starts over, and per older page.
const folderPageSize = 50;

/// More new mails than this since the last sync and the list starts over
/// from the newest page instead of fetching them all.
const maxDeltaNewMessages = 200;

/// What a folder refresh does, decided from the folder's SELECT response and
/// the list already shown.
enum RefreshKind {
  /// The folder holds nothing — no FETCH at all: `FETCH 1:0` is a BAD that
  /// used to tear the connection down on every empty Drafts or Trash.
  empty,

  /// Fetch the newest page and replace the list.
  full,

  /// Fetch only what changed since the list was fetched.
  delta,
}

RefreshKind planRefresh({
  required int exists,
  required int? uidValidity,
  required int? knownUidValidity,
  required List<MimeMessage> current,
}) {
  if (exists < 1) return RefreshKind.empty;
  if (current.isEmpty ||
      knownUidValidity == null ||
      uidValidity != knownUidValidity ||
      current.any((m) => m.uid == null)) {
    return RefreshKind.full;
  }
  return RefreshKind.delta;
}

/// The sequence numbers of the newest [count] of [exists] messages, or null
/// for an empty folder.
(int, int)? newestRange(int exists, {int count = folderPageSize}) =>
    exists < 1 ? null : (max(1, exists - count + 1), exists);

/// The sequence numbers of the page just below sequence number [lowest]
/// (the oldest listed message), or null when that is the first.
///
/// From the oldest listed message's own sequence number, which the delta's
/// FLAGS answer carries — not from the message count, which mail arriving
/// mid-op would shift.
(int, int)? pageBelow(int lowest, {int pageSize = folderPageSize}) {
  final end = lowest - 1;
  if (end < 1) return null;
  return (max(1, end - pageSize + 1), end);
}

/// The UIDs above [maxKnownUid] in a `UID FETCH <from>:* (UID FLAGS)`
/// answer, oldest first.
List<int> newUidsOf(Map<int, List<String>> flagsByUid, int maxKnownUid) => [
  for (final uid in flagsByUid.keys)
    if (uid > maxKnownUid) uid,
]..sort();

/// [current] brought up to date with a delta fetch.
///
/// [flagsByUid] answers `UID FETCH <fromUid>:* (UID FLAGS)`: every message
/// at or above [fromUid] that the server still has, with its flags. A
/// listed message from that range that isn't in it was deleted or moved
/// away; one that is gets its flags **in place**, so the rows and the
/// optimistic actions (keyed by UID) keep their objects. [fetchedNew] — the
/// list rows of the new UIDs — joins at the top.
List<MimeMessage> applyDelta({
  required List<MimeMessage> current,
  required int fromUid,
  required Map<int, List<String>> flagsByUid,
  required List<MimeMessage> fetchedNew,
}) {
  final out = <MimeMessage>[];
  final seen = <int>{};
  for (final m in current) {
    final uid = m.uid;
    if (uid == null) continue;
    if (uid >= fromUid) {
      final flags = flagsByUid[uid];
      if (flags == null) continue; // gone from the server
      if (!sameFlags(m.flags, flags)) m.flags = [...flags];
    }
    if (seen.add(uid)) out.add(m);
  }
  for (final m in fetchedNew) {
    final uid = m.uid;
    if (uid != null && seen.add(uid)) out.add(m);
  }
  return sortNewestFirst(out);
}

/// [current] with an [older] page appended — only what is older than every
/// listed mail, once.
List<MimeMessage> appendOlder(
  List<MimeMessage> current,
  List<MimeMessage> older,
) {
  final known = {for (final m in current) ?m.uid};
  final oldest = known.isEmpty ? null : known.reduce((a, b) => a < b ? a : b);
  final extra = [
    for (final m in older)
      if (m.uid != null &&
          !known.contains(m.uid) &&
          (oldest == null || m.uid! < oldest))
        m,
  ];
  return [...current, ...sortNewestFirst(extra)];
}

/// Newest first: by UID, which is arrival order in the folder — the order
/// the list always had.
List<MimeMessage> sortNewestFirst(Iterable<MimeMessage> messages) =>
    messages.toList()..sort((a, b) => (b.uid ?? 0).compareTo(a.uid ?? 0));

bool sameFlags(List<String>? a, List<String> b) {
  final x = {...?a?.map((f) => f.toLowerCase())};
  final y = {...b.map((f) => f.toLowerCase())};
  return x.length == y.length && x.containsAll(y);
}
