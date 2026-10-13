import 'package:enough_mail/enough_mail.dart';

/// Conversations: which mails belong together, and the headers that tie a
/// reply to the mail it answers. Pure functions over plain data, pinned by
/// `test/mail_threads_test.dart`.

// ── Message-IDs ───────────────────────────────────────────────────────────────

final _idPattern = RegExp(r'<[^<>\s]+>');

/// The Message-IDs in a header value (`<a@b> <c@d>`), in order.
List<String> messageIdsIn(String? header) => [
  if (header != null)
    for (final m in _idPattern.allMatches(header)) m.group(0)!,
];

/// [message]'s own Message-ID, or null.
String? messageIdOf(MimeMessage message) => messageIdsIn(
  message.envelope?.messageId ?? message.getHeaderValue('message-id'),
).firstOrNull;

/// The mails [message] answers: its In-Reply-To and References.
List<String> parentIdsOf(MimeMessage message) => {
  ...messageIdsIn(
    message.envelope?.inReplyTo ?? message.getHeaderValue('in-reply-to'),
  ),
  ...messageIdsIn(message.getHeaderValue('references')),
}.toList();

/// The `References` a reply to [original] carries: the original's own chain
/// and its Message-ID last. A long chain keeps its first id and the newest
/// ones (RFC 5322 §3.6.4), so the header stays a sane length.
List<String> replyReferences(MimeMessage original) {
  final own = messageIdOf(original);
  final chain = messageIdsIn(original.getHeaderValue('references'));
  if (chain.isEmpty) {
    chain.addAll(
      messageIdsIn(
        original.envelope?.inReplyTo ?? original.getHeaderValue('in-reply-to'),
      ).take(1),
    );
  }
  if (own != null) {
    chain
      ..remove(own)
      ..add(own);
  }
  const keep = 10;
  if (chain.length <= keep) return chain;
  return [chain.first, ...chain.sublist(chain.length - keep + 1)];
}

/// Marks [message] as a reply: `In-Reply-To` and `References`, so it joins
/// the conversation here and in the recipient's client. No-op without
/// [inReplyTo].
void applyReplyHeaders(
  MimeMessage message, {
  required String? inReplyTo,
  List<String> references = const [],
}) {
  if (inReplyTo == null) return;
  message.setHeader(MailConventions.headerInReplyTo, inReplyTo);
  final refs = [...references];
  if (refs.isEmpty || refs.last != inReplyTo) {
    refs
      ..remove(inReplyTo)
      ..add(inReplyTo);
  }
  message.setHeader(MailConventions.headerReferences, refs.join(' '));
}

// ── Subjects ──────────────────────────────────────────────────────────────────

// `Re:`, `AW:` (German Outlook), `Fwd:`, `WG:` — also numbered (`Re[2]:`) —
// and list tags like `[KISD]`.
final _leadingPrefix = RegExp(
  r'^\s*(?:(?:re|aw|antw|fwd?|wg)\s*(?:\[\d+\]|\(\d+\))?\s*:|\[[^\]]*\])\s*',
  caseSensitive: false,
);
final _replyPrefix = RegExp(
  r'^\s*(?:\[[^\]]*\]\s*)*(?:re|aw|antw)\s*(?:\[\d+\]|\(\d+\))?\s*:',
  caseSensitive: false,
);
final _forwardPrefix = RegExp(
  r'^\s*(?:\[[^\]]*\]\s*)*(?:fwd?|wg)\s*(?:\[\d+\]|\(\d+\))?\s*:',
  caseSensitive: false,
);

String _withoutPrefixes(String subject) {
  var s = subject;
  while (true) {
    final m = _leadingPrefix.firstMatch(s);
    if (m == null || m.end == 0) return s.trim();
    s = s.substring(m.end);
  }
}

/// A subject as conversations compare it: without reply, forward and list
/// prefixes, with case and spacing folded.
String threadSubject(String? subject) => _withoutPrefixes(
  subject ?? '',
).replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

bool hasReplyPrefix(String? subject) => _replyPrefix.hasMatch(subject ?? '');

bool hasForwardPrefix(String? subject) =>
    _forwardPrefix.hasMatch(subject ?? '');

/// Text for an IMAP `SUBJECT` search that every mail of the conversation
/// contains: the longest plain-ASCII stretch of the subject without its
/// prefixes. ASCII, so the search needs no literal and no CHARSET (which
/// some servers refuse) — the exact comparison happens here, afterwards.
/// Null when too short to narrow anything down.
String? subjectSearchText(String? subject) {
  var best = '';
  for (final piece in _withoutPrefixes(
    subject ?? '',
  ).split(RegExp(r'[^\x20-\x7E]+'))) {
    final t = piece.trim();
    if (t.length > best.length) best = t;
  }
  return best.length >= 3 ? best : null;
}

/// [value] as an IMAP quoted string.
String imapQuoted(String value) =>
    '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';

/// The `UID SEARCH` criteria for the mails around a conversation: the mails
/// it names by Message-ID, the ones that answer it, and — as the fallback
/// for clients that send no reply headers — the ones with its subject. Null
/// when there is nothing to search for.
String? threadSearchCriteria({
  required String? messageId,
  required List<String> parentIds,
  required String? subjectText,
  bool headers = true,
}) {
  final terms = <String>[];
  bool ascii(String s) => s.runes.every((r) => r > 0x20 && r < 0x7f);
  if (headers) {
    final ids = {?messageId, ...parentIds}.where(ascii).toList();
    // The ancestors this mail names, newest last — keep the first (root)
    // and the most recent ones, as a reply's References do.
    final named = ids.length <= 12
        ? ids
        : [ids.first, ...ids.sublist(ids.length - 11)];
    for (final id in named) {
      terms.add('HEADER Message-ID ${imapQuoted(id)}');
    }
    // The replies to it. A reply's References start at the root.
    final root = parentIds.where(ascii).firstOrNull;
    for (final id in {?messageId, ?root}.where(ascii)) {
      terms.add('HEADER References ${imapQuoted(id)}');
    }
    if (messageId != null && ascii(messageId)) {
      terms.add('HEADER In-Reply-To ${imapQuoted(messageId)}');
    }
  }
  if (subjectText != null) terms.add('SUBJECT ${imapQuoted(subjectText)}');
  if (terms.isEmpty) return null;
  // IMAP's OR takes exactly two keys: `OR a OR b c`.
  var criteria = terms.last;
  for (final term in terms.reversed.skip(1)) {
    criteria = 'OR $term $criteria';
  }
  return criteria;
}

// ── Grouping ──────────────────────────────────────────────────────────────────

/// A mail as the conversation finder sees it.
class ThreadCandidate {
  const ThreadCandidate({
    required this.key,
    this.messageId,
    this.parents = const [],
    this.subject = '',
    this.replyPrefix = false,
    this.from,
    this.addresses = const {},
    this.date,
  });

  /// From the envelope (and a fetched `References` header) — what a search
  /// result's metadata fetch returns.
  factory ThreadCandidate.of(MimeMessage m, String key) {
    final env = m.envelope;
    final from = (env?.from ?? m.from)?.firstOrNull?.email.toLowerCase();
    final subject = env?.subject ?? m.decodeSubject();
    return ThreadCandidate(
      key: key,
      messageId: messageIdOf(m),
      parents: parentIdsOf(m),
      subject: threadSubject(subject),
      replyPrefix: hasReplyPrefix(subject),
      from: from,
      addresses: {
        ?from,
        for (final a in [...?(env?.to ?? m.to), ...?(env?.cc ?? m.cc)])
          a.email.toLowerCase(),
      },
      date: env?.date ?? m.decodeDate(),
    );
  }

  /// Unique per mail in one lookup — the folder and the UID.
  final String key;
  final String? messageId;

  /// In-Reply-To and References.
  final List<String> parents;

  /// [threadSubject] of its subject.
  final String subject;
  final bool replyPrefix;

  /// Sender address, lowercased.
  final String? from;

  /// From, To and Cc, lowercased.
  final Set<String> addresses;
  final DateTime? date;
}

/// The mails of [seed]'s conversation among [candidates], [seed] included,
/// oldest first.
///
/// Reply headers decide first: a mail joins when it is named by, or names,
/// a mail already in. Mails without usable headers — replies sent by clients
/// that set none — then join on the same subject, but only when at least one
/// side is a reply (two separate mails that share a subject stay apart),
/// when they are not older than the mail that started the conversation,
/// when the headers don't say otherwise (a reply whose own chain shares
/// nothing with this one answers a different mail), and when the same people
/// are writing: the newcomer's sender took part, and someone who wrote in
/// the conversation is among its participants.
List<ThreadCandidate> conversationOf(
  ThreadCandidate seed,
  Iterable<ThreadCandidate> candidates,
) {
  final others = [
    for (final c in candidates)
      if (c.key != seed.key) c,
  ];
  var members = _gather(seed, others, notBefore: null);
  // The latest mail that answers nothing — up to the opened one — started
  // the conversation; an earlier exchange under the same subject is a
  // different one. Known only once everything is gathered (the start may
  // join late), so gather again with that cutoff.
  DateTime? start;
  for (final m in members) {
    final d = m.date;
    if (d == null || m.parents.isNotEmpty || m.replyPrefix) continue;
    if (seed.date != null && d.isAfter(seed.date!)) continue;
    if (start == null || d.isAfter(start)) start = d;
  }
  if (start != null) members = _gather(seed, others, notBefore: start);

  final result = members.toList();
  result.sort((a, b) {
    final da = a.date, db = b.date;
    if (da == null || db == null) return 0;
    return da.compareTo(db);
  });
  return result;
}

List<ThreadCandidate> _gather(
  ThreadCandidate seed,
  List<ThreadCandidate> others, {
  required DateTime? notBefore,
}) {
  final members = <String, ThreadCandidate>{seed.key: seed};
  final ids = <String>{?seed.messageId, ...seed.parents};

  void absorb(ThreadCandidate c) {
    members[c.key] = c;
    ids
      ..addAll([?c.messageId])
      ..addAll(c.parents);
  }

  bool linked(ThreadCandidate c) =>
      (c.messageId != null && ids.contains(c.messageId)) ||
      c.parents.any(ids.contains);

  void linkAll() {
    for (var grew = true; grew;) {
      grew = false;
      for (final c in others) {
        if (members.containsKey(c.key) || !linked(c)) continue;
        absorb(c);
        grew = true;
      }
    }
  }

  bool sameTopic(ThreadCandidate c) {
    if (seed.subject.isEmpty || c.subject != seed.subject) return false;
    final date = c.date;
    if (notBefore != null && date != null && date.isBefore(notBefore)) {
      return false;
    }
    if (c.parents.isNotEmpty &&
        members.values.any((m) => m.parents.isNotEmpty)) {
      return false;
    }
    if (!c.replyPrefix && !members.values.any((m) => m.replyPrefix)) {
      return false;
    }
    final from = c.from;
    if (from == null ||
        !members.values.any((m) => m.addresses.contains(from))) {
      return false;
    }
    return members.values.any(
      (m) => m.from != null && c.addresses.contains(m.from),
    );
  }

  linkAll();
  for (var grew = true; grew;) {
    grew = false;
    for (final c in others) {
      if (members.containsKey(c.key) || !sameTopic(c)) continue;
      absorb(c);
      linkAll();
      grew = true;
    }
  }
  return members.values.toList();
}
