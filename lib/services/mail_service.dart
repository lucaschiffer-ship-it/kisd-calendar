import 'dart:async';
import 'dart:math' show min;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'imap_preview_fix.dart';
import 'mail_attachments.dart';
import 'mail_offline_cache.dart';
import 'mail_threads.dart';
import 'service_locator.dart';

/// Which IMAP folder a message lives in — used for folder-aware operations.
enum MailFolder { inbox, drafts, sent, trash }

/// One mail of a conversation and the folder it was found in.
class ThreadMessage {
  const ThreadMessage(this.message, this.folder, {this.downloaded = true});

  /// The full mail — or, when not [downloaded], only its envelope and size.
  final MimeMessage message;
  final MailFolder folder;

  /// False when the body was left on the server (too large) or didn't come.
  final bool downloaded;
}

// Mail diagnostics include addresses and server responses — release builds
// log nothing to the device console.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

class MailService extends ChangeNotifier {
  static const _imapHost = 'imap.intranet.fh-koeln.de';
  static const _imapPort = 993;
  static const _smtpHost = 'smtp.intranet.fh-koeln.de';
  static const _smtpPort = 587;
  static const _smtpResponseTimeout = Duration(seconds: 30);
  static const _emailStorageKey = 'kisd_email';
  static const _smtpSizeLimitKey = 'mail_smtp_max_size';

  // Must match LoginService's options — both services share the credential
  // keys, and iOS Keychain lookups are scoped by these attributes.
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  ImapClient? _imap;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isFetching = false;
  bool _isFetchingTrash = false;
  bool _isFetchingSent = false;
  bool _isFetchingDrafts = false;
  String? _connectionError;
  List<MimeMessage> _messages = [];
  List<MimeMessage> _trashedMessages = [];
  List<MimeMessage> _sentMessages = [];
  List<MimeMessage> _draftMessages = [];
  String? _cachedUsername;
  Mailbox? _trashMailbox;
  Mailbox? _sentMailbox;
  Mailbox? _draftsMailbox;

  final _offline = MailOfflineCache();
  // The inbox UIDVALIDITY `_messages` belongs to — a cached UID only names
  // the same mail while this is unchanged.
  int? _inboxUidValidity;
  // Bumped by resetForAccountSwitch, so a cache load or sync still in flight
  // sees its account is gone and drops what it has instead of writing it.
  int _offlineGeneration = 0;
  bool _offlineSyncRunning = false;
  bool _offlineSyncAgain = false;
  bool _offlineFetchPending = false;
  ImapClient? _offlineImap;

  // Conversations (see fetchThread): a connection of their own, one lookup
  // at a time, and the last few results by the opened mail's Message-ID.
  ImapClient? _threadImap;
  DateTime? _threadImapUsed;
  Future<void> _threadQueue = Future.value();
  final _threadCache = <String, List<ThreadMessage>>{};
  static const _threadCacheSize = 8;
  static const _threadMaxMessages = 30;
  static const _threadBodyLimit = 3 * 1024 * 1024;
  // All bodies of one lookup together — newest first, so a long exchange of
  // PDFs costs neither the data plan nor the lookup's 25 s.
  static const _threadBodyBudget = 8 * 1024 * 1024;
  static const _threadResponseTimeout = Duration(seconds: 20);

  final _unreadController = StreamController<int>.broadcast();

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  bool get isFetching => _isFetching;
  bool get isFetchingTrash => _isFetchingTrash;
  bool get isFetchingSent => _isFetchingSent;
  bool get isFetchingDrafts => _isFetchingDrafts;
  String? get connectionError => _connectionError;
  List<MimeMessage> get messages => List.unmodifiable(_messages);
  List<MimeMessage> get trashedMessages => List.unmodifiable(_trashedMessages);
  List<MimeMessage> get sentMessages => List.unmodifiable(_sentMessages);
  List<MimeMessage> get draftMessages => List.unmodifiable(_draftMessages);
  int get unreadCount => _messages.where((m) => !m.isSeen).length;
  Stream<int> get unreadCountStream => _unreadController.stream;

  Future<void> connect() async {
    // Must run BEFORE the guard below: on an account switch the old session is
    // still alive, so `_isConnected` is true and every early return downstream
    // would hand the new user the previous account's mailbox.
    await _resetIfAccountChanged();
    if (_isConnecting || _isConnected) return;
    _isConnecting = true;
    _connectionError = null;
    notifyListeners();

    // The offline copy first, so the list is up before — or instead of —
    // the server's answer.
    if (_messages.isEmpty) await _loadOfflineInbox();

    final ok = await _ensureConnected();
    if (ok) {
      _isConnecting = false;
      notifyListeners();
      await fetchInbox();
    } else {
      _isConnecting = false;
      notifyListeners();
    }
  }

  Future<bool> _ensureConnected() async {
    // Above the early return for the same reason as in `connect()` — folder
    // fetches reach here without ever going through `connect()`.
    await _resetIfAccountChanged();
    // `_isConnected` alone outlives the socket: the server drops an idle
    // connection, and every command on it then waits for an answer that
    // never comes (a Sent copy hung compose forever). enough_mail clears its
    // own flag when the server closes the socket — reconnect then.
    if (_isConnected && _imap != null) {
      if (_imap!.isConnected) return true;
      _log('[mail] connection was closed by the server — reconnecting');
      _isConnected = false;
    }
    try {
      final username = await _storage.read(key: 'kisd_username');
      final password = await _storage.read(key: 'kisd_password');
      if (username == null || password == null) {
        _connectionError = 'No stored credentials — please log in first.';
        return false;
      }
      _cachedUsername = username;

      _log('[mail] connecting to $_imapHost...');
      _imap?.disconnect();
      // Same client, except that list previews keep their bytes — see
      // PreviewFixImapClient.
      _imap = PreviewFixImapClient(isLogEnabled: false);
      await _imap!.connectToServer(_imapHost, _imapPort, isSecure: true);
      await _imap!.login(username, password);
      _isConnected = true;
      _connectionError = null;
      _log('[mail] connected — fetching inbox');
      return true;
    } catch (e) {
      _log('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      _connectionError = 'Could not connect: $e';
      return false;
    }
  }

  /// Clears every trace of the previously signed-in account when the stored
  /// Campus ID no longer matches the one this session authenticated as.
  ///
  /// `MailService` is a process-lifetime singleton (`service_locator.dart`)
  /// that nothing disposes, so without this a sign-out leaves a live IMAP
  /// socket still authenticated as the old user — and every `_isConnected`
  /// short-circuit then serves the new user that mailbox.
  Future<void> _resetIfAccountChanged() async {
    if (_cachedUsername == null) return; // never connected — nothing to compare
    final stored = await _storage.read(key: 'kisd_username');
    if (stored == _cachedUsername) return;
    _log('[mail] signed-in account changed — clearing mail state');
    await resetForAccountSwitch();
  }

  /// Drops the connection and all cached mail for the previous account. Safe
  /// to call when nothing is connected.
  Future<void> resetForAccountSwitch() async {
    _offlineGeneration++;
    _offlineImap?.disconnect();
    _offlineImap = null;
    _threadImap?.disconnect();
    _threadImap = null;
    _threadCache.clear();
    _inboxUidValidity = null;
    _imap?.disconnect();
    _imap = null;
    _isConnected = false;
    _isConnecting = false;
    _isFetching = false;
    _isFetchingTrash = false;
    _isFetchingSent = false;
    _isFetchingDrafts = false;
    _connectionError = null;
    _messages = [];
    _trashedMessages = [];
    _sentMessages = [];
    _draftMessages = [];
    // Mailbox handles are bound to the old session (and memoised), so they
    // have to go with it.
    _trashMailbox = null;
    _sentMailbox = null;
    _draftsMailbox = null;
    _cachedUsername = null;
    // The confirmed sender belongs to the old account. `LoginService.logout()`
    // deletes this key too, but a direct re-login from LoginScreen does not —
    // clearing it here covers both switch paths from one place.
    await _storage.delete(key: _emailStorageKey);
    try {
      await _offline.clear();
    } catch (e) {
      _log('[mail] could not clear offline mail: $e');
    }
    _unreadController.add(0);
    notifyListeners();
  }

  /// Shows the offline copy of the inbox. Only the signed-in account's: a
  /// copy of someone else's is skipped, not deleted — deleting is the
  /// account switch's job, which only runs once a login has succeeded.
  Future<void> _loadOfflineInbox() async {
    final generation = _offlineGeneration;
    try {
      final index = await _offline.readIndex();
      final username = await _storage.read(key: 'kisd_username');
      if (index == null || username == null) return;
      if (generation != _offlineGeneration || _messages.isNotEmpty) return;
      if (index.owner.trim().toLowerCase() != username.trim().toLowerCase()) {
        return;
      }
      _messages = index.messages;
      _inboxUidValidity = index.uidValidity;
      // The account this mail belongs to — lets _resetIfAccountChanged clear
      // it on a switch even if this session never got online.
      _cachedUsername ??= username;
      _log('[mail] showing ${_messages.length} offline messages');
      _unreadController.add(unreadCount);
      notifyListeners();
    } catch (e) {
      _log('[mail] could not load offline mail: $e');
    }
  }

  /// Mirrors the inbox list into the offline copy and drops the full mails
  /// that left it. With [fetchBodies], also downloads the ones it lacks — only
  /// after an inbox fetch, so marking or deleting never opens a connection.
  Future<void> _updateOfflineCopy({bool fetchBodies = false}) async {
    final owner = _cachedUsername;
    final uidValidity = _inboxUidValidity;
    if (owner == null || uidValidity == null) return;
    try {
      await _offline.writeIndex(
          owner: owner, uidValidity: uidValidity, messages: _messages);
    } catch (e) {
      _log('[mail] could not save offline list: $e');
      return;
    }
    if (fetchBodies) _offlineFetchPending = true;
    if (_offlineSyncRunning) {
      _offlineSyncAgain = true;
      return;
    }
    _offlineSyncRunning = true;
    try {
      do {
        _offlineSyncAgain = false;
        final fetch = _offlineFetchPending;
        _offlineFetchPending = false;
        await _syncOfflineBodies(fetch: fetch);
      } while (_offlineSyncAgain);
    } catch (e) {
      _log('[mail] offline sync failed: $e');
    } finally {
      _offlineSyncRunning = false;
    }
  }

  /// With [fetch], saves the full mails of the newest
  /// [MailOfflineCache.maxMessages] inbox messages that aren't on disk yet —
  /// a mail never changes under its UID, so each is downloaded once. Then
  /// deletes the bodies of mails no longer in that list.
  Future<void> _syncOfflineBodies({required bool fetch}) async {
    final generation = _offlineGeneration;
    final uidValidity = _inboxUidValidity;
    final wanted = [
      for (final m in _messages.take(MailOfflineCache.maxMessages))
        if (m.uid != null) m,
    ];
    if (uidValidity == null) return;
    final keep = {for (final m in wanted) m.uid!};

    final have = await _offline.bodyUids();
    final missing = [
      for (final m in wanted)
        if (!have.contains(m.uid) &&
            (m.size ?? 0) <= MailOfflineCache.maxMessageBytes)
          m.uid!,
    ];
    if (fetch && missing.isNotEmpty) {
      await _fetchOfflineBodies(missing, keep, uidValidity, generation);
    }
    if (generation == _offlineGeneration) await _offline.prune(keep);
  }

  /// On a connection of its own, with the inbox EXAMINEd read-only: the shared
  /// one's selected folder can change under any await (opening Sent mid-sync
  /// would fetch Sent mails under inbox UIDs). BODY.PEEK so caching doesn't
  /// mark 50 mails read.
  Future<void> _fetchOfflineBodies(List<int> uids, Set<int> keep,
      int uidValidity, int generation) async {
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return;
    if (generation != _offlineGeneration) return;

    final imap = ImapClient(isLogEnabled: false);
    _offlineImap = imap;
    var saved = 0;
    try {
      await imap.connectToServer(_imapHost, _imapPort, isSecure: true);
      await imap.login(username, password);
      final inbox = await imap.examineMailbox(Mailbox(
        encodedName: 'INBOX',
        encodedPath: 'INBOX',
        flags: [],
        pathSeparator: '/',
      ));
      if (inbox.uidValidity != uidValidity) return;
      for (var i = 0; i < uids.length; i += 10) {
        if (generation != _offlineGeneration) return;
        final chunk = uids.sublist(i, min(i + 10, uids.length));
        final result = await imap.uidFetchMessages(
          MessageSequence.fromIds(chunk, isUid: true),
          'BODY.PEEK[]',
          responseTimeout: const Duration(seconds: 90),
        );
        for (final m in result.messages) {
          final uid = m.uid;
          // Literal message bodies always arrive as bytes; keeping them
          // byte-exact is what keeps 8-bit (umlaut) mail intact.
          final data = m.mimeData;
          if (uid == null || !keep.contains(uid) || data is! BinaryMimeData) {
            continue;
          }
          if (data.data.length > MailOfflineCache.maxMessageBytes) continue;
          if (generation != _offlineGeneration) return;
          await _offline.writeBody(uid, data.data);
          saved++;
        }
      }
    } catch (e) {
      _log('[mail] offline sync stopped: $e');
    } finally {
      if (identical(_offlineImap, imap)) _offlineImap = null;
      imap.disconnect();
      _log('[mail] saved $saved messages for offline reading');
    }
  }

  Future<void> reloadInbox() async {
    _log('[mail] manual reload triggered');
    await fetchInbox();
    _log('[mail] fetched ${_messages.length} messages after reload');
  }

  Future<List<MimeMessage>> fetchInbox({int limit = 50}) async {
    if (!_isConnected) {
      final ok = await _ensureConnected();
      if (!ok) return _messages;
    }

    _isFetching = true;
    notifyListeners();

    try {
      final inbox = await _imap!.selectInbox();
      final result = await _imap!.fetchRecentMessages(
        messageCount: limit,
        // RFC822.SIZE: lets the offline copy skip mails too big to keep.
        criteria: '(FLAGS ENVELOPE UID RFC822.SIZE BODY.PEEK[TEXT]<0.500>)',
        responseTimeout: const Duration(seconds: 90),
      );
      _messages = result.messages.reversed.toList();
      _inboxUidValidity = inbox.uidValidity;
      // New mail may have joined a conversation looked up before.
      _threadCache.clear();
      final unread = unreadCount;
      _log('[mail] fetched ${_messages.length} messages ($unread unread)');
      _unreadController.add(unread);
      unawaited(_updateOfflineCopy(fetchBodies: true));
    } catch (e) {
      _log('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
    } finally {
      _isFetching = false;
      notifyListeners();
    }
    return _messages;
  }

  // Selects the IMAP mailbox for [folder]; false if it cannot be resolved.
  Future<bool> _selectFolder(MailFolder folder) async {
    switch (folder) {
      case MailFolder.inbox:
        await _imap!.selectInbox();
        return true;
      case MailFolder.trash:
        final mb = await _resolveTrashMailbox();
        if (mb == null) return false;
        await _imap!.selectMailbox(mb);
        return true;
      case MailFolder.sent:
        final mb = await _resolveSentMailbox();
        if (mb == null) return false;
        await _imap!.selectMailbox(mb);
        return true;
      case MailFolder.drafts:
        final mb = await _resolveDraftsMailbox();
        if (mb == null) return false;
        await _imap!.selectMailbox(mb);
        return true;
    }
  }

  List<MimeMessage> _mutableListFor(MailFolder folder) => switch (folder) {
        MailFolder.inbox => _messages,
        MailFolder.trash => _trashedMessages,
        MailFolder.sent => _sentMessages,
        MailFolder.drafts => _draftMessages,
      };

  Future<MimeMessage?> fetchFullMessage(int uid,
      {MailFolder folder = MailFolder.inbox}) async {
    // A mail never changes under its UID, so the offline copy is as good as
    // the server's — and opens without a connection. Inbox only: UIDs are per
    // mailbox, so a Sent or Trash UID can name an unrelated inbox mail.
    if (folder == MailFolder.inbox) {
      final cached = await _offlineBody(uid);
      if (cached != null) return cached;
    }
    final ok = await _ensureConnected();
    if (!ok) return null;
    try {
      if (!await _selectFolder(folder)) return null;
      final result = await _imap!.uidFetchMessage(uid, 'BODY[]');
      return result.messages.isNotEmpty ? result.messages.first : null;
    } catch (e) {
      _log('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      return null;
    }
  }

  /// The saved full mail for [uid] when it is the inbox message listed under
  /// that UID. The Message-ID comparison guards the narrow windows where the
  /// saved bodies trail a UIDVALIDITY or account change.
  Future<MimeMessage?> _offlineBody(int uid) async {
    final listed = _messages.where((m) => m.uid == uid).firstOrNull;
    if (listed == null) return null;
    final MimeMessage? cached;
    try {
      cached = await _offline.readBody(uid);
    } catch (_) {
      return null;
    }
    if (cached == null) return null;
    final listedId =
        (listed.envelope?.messageId ?? listed.getHeaderValue('message-id'))
            ?.trim();
    final cachedId = cached.getHeaderValue('message-id')?.trim();
    if (listedId != null && cachedId != null && listedId != cachedId) {
      return null;
    }
    return cached;
  }

  // ── Conversations ─────────────────────────────────────────────────────────

  static final _inboxMailbox = Mailbox(
    encodedName: 'INBOX',
    encodedPath: 'INBOX',
    flags: [],
    pathSeparator: '/',
  );

  /// The conversation [opened] belongs to, oldest first — [opened] itself
  /// included as the very object passed in. Null when it can't be looked up
  /// (offline, or the server refused).
  ///
  /// Searches Inbox and Sent (where the user's own replies are) by reply
  /// headers and by subject; [conversationOf] decides what belongs. On a
  /// connection of its own with each folder EXAMINEd read-only: the shared
  /// one's selected folder changes under any await, and BODY.PEEK leaves the
  /// other mails' read state alone.
  Future<List<ThreadMessage>?> fetchThread(
    MimeMessage opened,
    MailFolder folder,
  ) async {
    final previous = _threadQueue;
    final done = Completer<void>();
    _threadQueue = done.future;
    await previous;
    try {
      await _resetIfAccountChanged();
      final key = messageIdOf(opened);
      final cached = key == null ? null : _threadCache.remove(key);
      if (cached != null) {
        _threadCache[key!] = cached; // most recently used last
        return [
          for (final t in cached)
            messageIdOf(t.message) == key ? ThreadMessage(opened, folder) : t,
        ];
      }
      final generation = _offlineGeneration;
      // Whole-call: a dead socket that was never closed would otherwise hang
      // a command forever — and every later lookup queued behind it.
      final watch = Stopwatch()..start();
      final thread = await _lookUpThread(opened, folder)
          .timeout(const Duration(seconds: 25));
      _threadImapUsed = DateTime.now();
      _log('[mail] conversation: ${thread?.length ?? 0} mails '
          'in ${watch.elapsedMilliseconds} ms');
      if (thread == null || generation != _offlineGeneration) return null;
      if (key != null) {
        _threadCache[key] = thread;
        while (_threadCache.length > _threadCacheSize) {
          _threadCache.remove(_threadCache.keys.first);
        }
      }
      return thread;
    } catch (e) {
      _log('[mail] conversation lookup failed: $e');
      _threadImap?.disconnect();
      _threadImap = null;
      return null;
    } finally {
      done.complete();
    }
  }

  Future<ImapClient?> _threadClient() async {
    final current = _threadImap;
    final used = _threadImapUsed;
    // An idle connection may be dead without knowing it (the phone slept,
    // the network changed): after a few minutes, a fresh one is cheaper
    // than finding out by timeout.
    final fresh =
        used != null && DateTime.now().difference(used).inMinutes < 4;
    if (current != null && current.isConnected && fresh) return current;
    current?.disconnect();
    _threadImap = null;
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return null;
    final imap = ImapClient(isLogEnabled: false);
    await imap.connectToServer(_imapHost, _imapPort,
        isSecure: true, timeout: const Duration(seconds: 10));
    await imap.login(username, password);
    _threadImap = imap;
    return imap;
  }

  Future<List<int>> _searchThread(ImapClient imap, MimeMessage opened) async {
    final id = messageIdOf(opened);
    final parents = parentIdsOf(opened);
    final subject = subjectSearchText(opened.decodeSubject());
    final criteria = threadSearchCriteria(
        messageId: id, parentIds: parents, subjectText: subject);
    if (criteria == null) return const [];
    try {
      final result = await imap.uidSearchMessages(
          searchCriteria: criteria, responseTimeout: _threadResponseTimeout);
      return result.matchingSequence?.toList() ?? const [];
    } on ImapException catch (e) {
      // A server that can't search headers still finds the subject.
      _log('[mail] header search refused ($e) — searching the subject only');
      final subjectOnly = threadSearchCriteria(
          messageId: id,
          parentIds: parents,
          subjectText: subject,
          headers: false);
      if (subjectOnly == null) return const [];
      final result = await imap.uidSearchMessages(
          searchCriteria: subjectOnly, responseTimeout: _threadResponseTimeout);
      return result.matchingSequence?.toList() ?? const [];
    }
  }

  Future<List<ThreadMessage>?> _lookUpThread(
    MimeMessage opened,
    MailFolder folder,
  ) async {
    final imap = await _threadClient();
    if (imap == null) return null;
    final sent = await _resolveSentMailbox(via: imap);
    final boxes = <(MailFolder, Mailbox)>[
      (MailFolder.inbox, _inboxMailbox),
      if (sent != null) (MailFolder.sent, sent),
    ];

    // The candidates: metadata of every mail the searches turn up.
    final found = <String, (MailFolder, MimeMessage)>{};
    final validity = <MailFolder, int?>{};
    Mailbox? selected;
    for (final (f, box) in boxes) {
      validity[f] = (await imap.examineMailbox(box)).uidValidity;
      selected = box;
      final uids = await _searchThread(imap, opened);
      if (uids.isEmpty) continue;
      // The newest — a generic subject ("Frage") can match hundreds.
      final newest = (uids.toList()..sort()).reversed.take(60).toList();
      final meta = await imap.uidFetchMessages(
        MessageSequence.fromIds(newest, isUid: true),
        '(UID FLAGS ENVELOPE RFC822.SIZE '
        'BODY.PEEK[HEADER.FIELDS (REFERENCES)])',
        responseTimeout: _threadResponseTimeout,
      );
      for (final m in meta.messages) {
        if (m.uid != null) found['${f.name}:${m.uid}'] = (f, m);
      }
    }

    final seedKey = '${folder.name}:${opened.uid}';
    final members = conversationOf(
      ThreadCandidate.of(opened, seedKey),
      [for (final e in found.entries) ThreadCandidate.of(e.value.$2, e.key)],
    );
    // The same mail can sit in both folders (sent to oneself, a list
    // echoing it back): one card — the opened copy, else the inbox's.
    int rank(ThreadCandidate c) => c.key == seedKey
        ? 0
        : (found[c.key]?.$1 == MailFolder.inbox ? 1 : 2);
    final byId = <String, ThreadCandidate>{};
    final unique = <ThreadCandidate>[];
    for (final m in members) {
      final id = m.messageId;
      if (id == null) {
        unique.add(m);
      } else if (byId[id] == null || rank(m) < rank(byId[id]!)) {
        byId[id] = m;
      }
    }
    unique.addAll(byId.values);
    unique.sort((a, b) {
      final da = a.date, db = b.date;
      if (da == null || db == null) return 0;
      return da.compareTo(db);
    });
    var keep = unique;
    if (keep.length > _threadMaxMessages) {
      keep = keep.sublist(keep.length - _threadMaxMessages);
      if (!keep.any((m) => m.key == seedKey)) {
        keep = [
          ...keep.skip(1),
          unique.firstWhere((m) => m.key == seedKey),
        ]..sort((a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)));
      }
    }
    if (keep.length < 2) return [ThreadMessage(opened, folder)];

    // Bodies: the offline copy's first, the rest from the server — the
    // folder still selected first.
    final bodies = <String, MimeMessage>{};
    // Only while the list's UIDs are this connection's UIDs.
    if (validity[MailFolder.inbox] == _inboxUidValidity) {
      for (final m in keep) {
        final hit = found[m.key];
        if (hit == null || hit.$1 != MailFolder.inbox) continue;
        final body = await _offlineBody(hit.$2.uid!);
        if (body != null && messageIdOf(body) == m.messageId) {
          bodies[m.key] = body;
        }
      }
    }
    final wanted = <String>{};
    var budget = _threadBodyBudget;
    for (final m in keep.reversed) {
      final hit = found[m.key];
      if (m.key == seedKey || hit == null || bodies.containsKey(m.key)) {
        continue;
      }
      final size = hit.$2.size ?? 0;
      if (size > _threadBodyLimit || size > budget) continue;
      budget -= size;
      wanted.add(m.key);
    }
    final order = [
      for (final b in boxes)
        if (b.$2 == selected) b,
      for (final b in boxes)
        if (b.$2 != selected) b,
    ];
    for (final (f, box) in order) {
      final uids = [
        for (final m in keep)
          if (wanted.contains(m.key) && found[m.key]!.$1 == f)
            found[m.key]!.$2.uid!,
      ];
      if (uids.isEmpty) continue;
      if (box != selected) {
        final again = await imap.examineMailbox(box);
        selected = box;
        // The UIDs are from before: renumbered folder, different mails.
        if (again.uidValidity != validity[f]) return null;
      }
      final result = await imap.uidFetchMessages(
        MessageSequence.fromIds(uids, isUid: true),
        'BODY.PEEK[]',
        responseTimeout: const Duration(seconds: 60),
      );
      for (final m in result.messages) {
        if (m.uid != null) bodies['${f.name}:${m.uid}'] = m;
      }
    }

    return [
      for (final m in keep)
        if (m.key == seedKey)
          ThreadMessage(opened, folder)
        else if (bodies[m.key] case final body?)
          ThreadMessage(body, found[m.key]!.$1)
        else
          ThreadMessage(found[m.key]!.$2, found[m.key]!.$1, downloaded: false),
    ];
  }

  /// [attachments] empty sends exactly as before attachments existed:
  /// `buildSimpleTextMessage` and the 30 s timeout. Every attachment-only
  /// step below is guarded by `attachments.isNotEmpty`.
  /// [inReplyTo] and [references] mark a reply (see [applyReplyHeaders]).
  Future<void> sendEmail(String to, String subject, String body,
      {String? from,
      List<MailAttachmentData> attachments = const [],
      String? inReplyTo,
      List<String> references = const []}) async {
    // Storage, not `_cachedUsername`: the field is the account this session
    // connected as, which after a switch is the *previous* user.
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return;

    // The stored username is the Campus ID, not an email address — the
    // sender identity has to be a real, existing address. The TH relay
    // accepts mail from authenticated users regardless of the sender, then
    // silently drops/bounces it downstream when the address doesn't exist,
    // so a wrong From means the mail "sends" but never arrives.
    final fromEmail = from ?? await accountEmail();
    if (fromEmail == null || !fromEmail.contains('@')) {
      throw Exception(
          'No sender address set — enter your TH Köln email address in the '
          'From field (you can see it in webmail under Sent).');
    }
    if (isCampusIdAddress(fromEmail, username)) {
      throw Exception(
          '$fromEmail is your Campus ID, not a real mailbox — the server '
          'accepts mail from it and then silently drops it. Use your real '
          'address (your.name@smail.th-koeln.de).');
    }
    if (isRoleAddress(fromEmail)) {
      throw Exception(
          '$fromEmail is a system address, not yours. Use your real '
          'address (your.name@smail.th-koeln.de).');
    }
    if (from != null) await setAccountEmail(from);

    _log('[mail] sending email to $to (from $fromEmail)');
    // Debug logging echoes every line sent — for a mail with attachments
    // that's megabytes of base64 in the console.
    final smtp = SmtpClient('fh-koeln.de',
        isLogEnabled: kDebugMode && attachments.isEmpty);
    try {
      // enough_mail's SMTP commands await the server with no timeout of
      // their own — a stalled response would hang the send forever, with
      // the compose spinner stuck and no error shown.
      await smtp.connectToServer(_smtpHost, _smtpPort, isSecure: false);
      await smtp.ehlo().timeout(_smtpResponseTimeout);
      await smtp.startTls().timeout(_smtpResponseTimeout);
      var sendTimeout = _smtpResponseTimeout;
      int? estimatedSize;
      if (attachments.isNotEmpty) {
        // The server announces its limit after STARTTLS's EHLO. Checked
        // before logging in and before a single byte of the files is sent.
        final limit = smtp.serverInfo.maxMessageSize;
        await _rememberSmtpSizeLimit(limit);
        final sizes = attachments.map((a) => a.bytes.length);
        estimatedSize = estimateEncodedSize(body.length, sizes);
        if (exceedsMailLimit(body.length, sizes, limit)) {
          throw Exception(mailTooBigMessage(
            sizes.fold(0, (a, b) => a + b),
            attachmentAllowance(limit!,
                bodyLength: body.length, count: attachments.length),
          ));
        }
        // The timeout covers the whole upload. Fixed at 30 s, a few MB on a
        // weak uplink would be reported as failed while the server may
        // already have queued the mail — and the retry sends it twice. So
        // it only guards against a stall: at least 32 KB/s.
        sendTimeout = _smtpResponseTimeout +
            Duration(seconds: estimatedSize ~/ (32 * 1024));
      }
      await smtp.authenticate(username, password).timeout(_smtpResponseTimeout);
      final message = attachments.isEmpty
          ? MessageBuilder.buildSimpleTextMessage(
              MailAddress(null, fromEmail),
              [MailAddress(null, to)],
              body,
              subject: subject,
            )
          : await buildAttachmentMessageInBackground(
              from: MailAddress(null, fromEmail),
              to: [MailAddress(null, to)],
              subject: subject,
              body: body,
              attachments: attachments,
            );
      applyReplyHeaders(message,
          inReplyTo: inReplyTo, references: references);
      if (estimatedSize != null) {
        _log('[mail] sending ${attachments.length} attachment(s), '
            '~$estimatedSize bytes');
      }
      final response = await smtp.sendMessage(message).timeout(sendTimeout);
      // The acceptance line carries the server's queue ID — the proof the
      // message entered the mail system, and the handle Campus IT can trace.
      _log('[mail] smtp accepted: ${response.code} ${response.message}');
      if (attachments.isEmpty) {
        await _appendToSent(message);
      } else {
        // The mail is delivered now. Its Sent copy is the same MBs uploaded
        // a second time, so compose closes without waiting for it.
        unawaited(_appendToSent(message, size: estimatedSize));
      }
    } catch (e) {
      _log('[mail] error: $e');
      rethrow;
    } finally {
      try {
        await smtp.quit().timeout(const Duration(seconds: 5));
      } catch (_) {
        // A quit() failure after a dead connection must not mask the
        // original send error.
      }
    }
  }

  /// The account's email address: the stored/confirmed one, else the
  /// official address from the Spaces account (filled from the TH login, the
  /// same one the campusID-Center lists), else detected from mailbox data as
  /// a fallback. Returns null when unknown — deliberately no guessing; a
  /// plausible-but-wrong sender is accepted by the relay and then dropped
  /// silently, which is worse than asking the user once.
  Future<String?> accountEmail() async {
    // Before the cached-address read below: that read returns early, so it
    // never reaches the heal inside `_ensureConnected()` further down — and a
    // previous account's real address passes both validity checks here, which
    // would make the new user compose with the old user's From.
    await _resetIfAccountChanged();
    final username = await _storage.read(key: 'kisd_username');
    final cached = await _storage.read(key: _emailStorageKey);
    if (cached != null && cached.contains('@')) {
      if (!isCampusIdAddress(cached, username) && !isRoleAddress(cached)) {
        return cached;
      }
      // A Campus-ID identity (e.g. mmuster1@fh-koeln.de — webmail's broken
      // default, mail from it is accepted and then dropped) or a role
      // address (noreply@…) is never this account. Discard and re-detect.
      _log('[mail] discarding cached invalid sender $cached');
      await _storage.delete(key: _emailStorageKey);
    }

    // Authoritative: Spaces stores exactly one address per account, synced
    // from IDM. Official, so it is persisted like a confirmed address.
    try {
      final spaces = await scraperService.fetchAccountEmail();
      final official =
          acceptSpacesEmail(spaces?.email, spaces?.username, username);
      if (official != null) {
        _log('[mail] spaces account email: $official');
        await setAccountEmail(official);
        return official;
      }
    } catch (e) {
      _log('[mail] spaces account lookup failed: $e');
    }

    // Fallback when Spaces is unreachable (offline, expired session).
    final receivedHeaders = <String>[];
    final sentFrom = <MailAddress>[];
    if (await _ensureConnected()) {
      try {
        receivedHeaders.addAll(await _inboxReceivedHeaders());
      } catch (e) {
        _log('[mail] received-header lookup failed: $e');
      }
      try {
        if (_sentMessages.isEmpty) await fetchSent(limit: 10);
        for (final m in _sentMessages) {
          sentFrom.addAll(m.from ?? const []);
        }
      } catch (e) {
        _log('[mail] account email lookup failed: $e');
      }
    }

    final email = pickAccountEmail(
        receivedHeaders: receivedHeaders,
        sentFrom: sentFrom,
        username: username);
    if (email != null) _log('[mail] detected account email: $email');
    // Not persisted here: detection is only a prefill. The address is stored
    // once the user sends with it (setAccountEmail), i.e. after they saw it.
    return email;
  }

  /// Persists the user-confirmed sender address.
  Future<void> setAccountEmail(String email) async {
    final normalized = email.trim().toLowerCase();
    final current = await _storage.read(key: _emailStorageKey);
    if (current == normalized) return;
    await _storage.write(key: _emailStorageKey, value: normalized);
    _log('[mail] account email set to $normalized');
  }

  /// The Spaces account [email] if it can be this account's sender: the
  /// Spaces login must be the Campus ID this app is signed in as (a leftover
  /// session of the previous account must not leak its address), and the
  /// address must be a th-koeln one that is neither the Campus ID nor a role.
  @visibleForTesting
  static String? acceptSpacesEmail(
      String? email, String? spacesUsername, String? loginUsername) {
    final normalized = email?.trim().toLowerCase();
    final spacesLogin = spacesUsername?.trim().toLowerCase();
    final login = loginUsername?.trim().toLowerCase();
    if (normalized == null || !normalized.contains('@')) return null;
    if (login == null || login.isEmpty || spacesLogin != login) return null;
    final domain = normalized.split('@').last;
    if (domain != 'th-koeln.de' && !domain.endsWith('.th-koeln.de')) {
      return null;
    }
    if (isCampusIdAddress(normalized, login) || isRoleAddress(normalized)) {
      return null;
    }
    return normalized;
  }

  /// True when [email]'s local part is the login's Campus ID — webmail's
  /// default identity (campusid@fh-koeln.de), which is not a deliverable
  /// mailbox: the relay accepts mail from it and drops it downstream.
  @visibleForTesting
  static bool isCampusIdAddress(String email, String? username) {
    if (username == null || username.isEmpty) return false;
    final local = email.split('@').first.trim().toLowerCase();
    return local == username.trim().toLowerCase();
  }

  /// True for role/system addresses (noreply@… etc.) that can never be a
  /// person's identity. Mass mails are often addressed To: such an alias
  /// with the real recipients in Bcc, so they dominate inbox recipients.
  @visibleForTesting
  static bool isRoleAddress(String email) {
    final local = email
        .split('@')
        .first
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'[-_.]'), '');
    return const {
      'noreply',
      'donotreply',
      'postmaster',
      'mailerdaemon',
      'newsletter',
    }.contains(local);
  }

  /// Fallback for when the Spaces lookup ([acceptSpacesEmail]) is unavailable:
  /// picks the account's own address from mailbox data. Campus-ID identities
  /// and role addresses (noreply@… etc.) are excluded everywhere.
  ///
  /// Priority: the envelope recipient the TH servers stamp into inbox
  /// `Received: … for <addr>` lines (smail first), then th-koeln From of sent
  /// messages, then any remaining sent From as a last resort. Otherwise null.
  ///
  /// Deliberately NOT inbox To/Cc: group and course mails list many students
  /// there, so a popularity vote picked a classmate's address for an account
  /// with an empty Sent folder — and a wrong sender is silently dropped.
  @visibleForTesting
  static String? pickAccountEmail({
    required List<String> receivedHeaders,
    required List<MailAddress> sentFrom,
    String? username,
  }) {
    bool isThKoeln(String email) {
      final domain = email.split('@').last;
      return domain == 'th-koeln.de' || domain.endsWith('.th-koeln.de');
    }

    bool isSmail(String email) =>
        email.split('@').last == 'smail.th-koeln.de';

    String? mostFrequent(Iterable<String> emails) {
      final counts = <String, int>{};
      for (final email in emails) {
        counts[email] = (counts[email] ?? 0) + 1;
      }
      String? best;
      var bestCount = 0;
      for (final entry in counts.entries) {
        if (entry.value > bestCount) {
          best = entry.key;
          bestCount = entry.value;
        }
      }
      return best;
    }

    bool isOwnCandidate(String e) =>
        e.contains('@') &&
        !isCampusIdAddress(e, username) &&
        !isRoleAddress(e);

    // A server only writes `for <addr>` when that copy has exactly one
    // envelope recipient, so it names this mailbox even for Bcc'd mass
    // mail. The final hop names the internal Campus-ID mailbox
    // (campusid@imap.intranet.fh-koeln.de), which isCampusIdAddress drops.
    final receivedAddresses = receivedHeaders
        .expand((h) => _receivedForPattern.allMatches(h))
        .map((m) => m.group(1)!.trim().toLowerCase())
        .where((e) => isThKoeln(e) && isOwnCandidate(e))
        .toList();
    final receivedPick = mostFrequent(receivedAddresses.where(isSmail)) ??
        mostFrequent(receivedAddresses);
    if (receivedPick != null) return receivedPick;

    final sentAddresses = sentFrom
        .map((a) => a.email.trim().toLowerCase())
        .where(isOwnCandidate)
        .toList();
    final sentPick = mostFrequent(sentAddresses.where(isThKoeln));
    if (sentPick != null) return sentPick;

    // Last resort: a foreign sent address — only when the mailbox offers no
    // th-koeln evidence at all (already campus-id filtered above).
    return mostFrequent(sentAddresses);
  }

  // `for <addr>` (Postfix) or `for addr` (Exim) in a Received header.
  static final _receivedForPattern = RegExp(
      r'\bfor\s+<?([A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+)>?',
      caseSensitive: false);

  /// Raw `Received:` header values of the newest inbox messages. Header-only
  /// fetch with PEEK, so nothing is marked read and no bodies are loaded.
  Future<List<String>> _inboxReceivedHeaders({int limit = 30}) async {
    await _imap!.selectInbox();
    final result = await _imap!.fetchRecentMessages(
      messageCount: limit,
      criteria: '(BODY.PEEK[HEADER.FIELDS (RECEIVED)])',
      responseTimeout: const Duration(seconds: 30),
    );
    return [
      for (final m in result.messages)
        for (final h in m.getHeader('received') ?? const <Header>[])
          if (h.value != null) h.value!,
    ];
  }

  // Webmail parity: SMTP delivery alone stores no copy — webmail APPENDs one
  // to the Sent folder over IMAP. Failures here must not fail the send.
  //
  // Bounded like the SMTP upload — 30 s plus 1 s per 32 KB of [size] — so a
  // connection that died without the server closing it can't hang the send.
  Future<void> _appendToSent(MimeMessage message, {int? size}) async {
    try {
      if (!await _ensureConnected()) return;
      final sent = await _resolveSentMailbox();
      if (sent == null) return;
      await _imap!
          .appendMessage(message, targetMailbox: sent, flags: [r'\Seen'])
          .timeout(_smtpResponseTimeout +
              Duration(seconds: (size ?? 0) ~/ (32 * 1024)));
      _log('[mail] appended sent copy to ${sent.path}');
      // The reply's Sent copy now belongs to a conversation looked up
      // before — attachment mails append after compose has closed.
      _threadCache.clear();
    } on TimeoutException catch (e) {
      _log('[mail] could not append to sent folder: $e');
      // Whatever the connection is doing, it isn't answering: start fresh
      // with the next command.
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
    } catch (e) {
      _log('[mail] could not append to sent folder: $e');
    }
  }

  // ── Attachment size limit ────────────────────────────────────────────────

  Future<int?>? _sizeProbe;

  /// The largest mail the TH SMTP server accepts, as announced in its EHLO
  /// (`SIZE`). Remembered on the device — a server property, nothing
  /// personal. Until the first send with attachments it comes from a probe:
  /// connect, EHLO, STARTTLS, quit — no login, nothing sent. Null when the
  /// server doesn't say (the server's own rejection then still surfaces).
  Future<int?> smtpSizeLimit() async {
    final prefs = await SharedPreferences.getInstance();
    final known = prefs.getInt(_smtpSizeLimitKey);
    if (known != null) return known;
    // One probe per app run, however often compose asks.
    return _sizeProbe ??= _probeSmtpSizeLimit();
  }

  Future<int?> _probeSmtpSizeLimit() async {
    final smtp = SmtpClient('fh-koeln.de', isLogEnabled: false);
    try {
      await smtp
          .connectToServer(_smtpHost, _smtpPort, isSecure: false)
          .timeout(_smtpResponseTimeout);
      await smtp.ehlo().timeout(_smtpResponseTimeout);
      await smtp.startTls().timeout(_smtpResponseTimeout);
      final limit = smtp.serverInfo.maxMessageSize;
      await _rememberSmtpSizeLimit(limit);
      return limit != null && limit > 0 ? limit : null;
    } catch (e) {
      _log('[mail] smtp size probe failed: $e');
      _sizeProbe = null; // offline: try again next time
      return null;
    } finally {
      try {
        await smtp.quit().timeout(const Duration(seconds: 5));
      } catch (_) {
        // A probe that timed out mid-connect must not leave its socket open.
        try {
          await smtp.disconnect();
        } catch (_) {}
      }
    }
  }

  // SIZE 0 means "no limit announced" (RFC 1870).
  Future<void> _rememberSmtpSizeLimit(int? limit) async {
    if (limit == null || limit <= 0) return;
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getInt(_smtpSizeLimitKey) == limit) return;
    await prefs.setInt(_smtpSizeLimitKey, limit);
    _log('[mail] smtp size limit: $limit bytes');
  }

  // ── Drafts ───────────────────────────────────────────────────────────────
  // The only additions the mail UI rework made to this service (explicitly
  // allowed): saving a compose sheet as a draft, and removing a draft once it
  // is sent, saved again or deleted. Nothing above was changed for them.

  /// Appends a draft to the Drafts folder over IMAP, the way [_appendToSent]
  /// stores a sent copy. Returns false when it didn't land, so compose can
  /// stay open rather than lose what was typed.
  Future<bool> saveDraft({
    required String from,
    required String to,
    required String subject,
    required String body,
    List<MailAttachmentData> attachments = const [],
    String? inReplyTo,
    List<String> references = const [],
  }) async {
    try {
      if (!await _ensureConnected()) return false;
      final drafts = await _resolveDraftsMailbox();
      if (drafts == null) return false;
      final sender =
          from.contains('@') ? from.trim() : (await accountEmail() ?? from);
      // Attachments travel inside the draft, photos marked so a reopened
      // draft can still offer scaling them.
      final message = attachments.isEmpty
          ? MessageBuilder.buildSimpleTextMessage(
              MailAddress(null, sender),
              [if (to.trim().isNotEmpty) MailAddress(null, to.trim())],
              body,
              subject: subject,
            )
          : await buildAttachmentMessageInBackground(
              from: MailAddress(null, sender),
              to: [if (to.trim().isNotEmpty) MailAddress(null, to.trim())],
              subject: subject,
              body: body,
              attachments: attachments,
              markPhotos: true,
            );
      // Kept in the draft, so a reopened reply is still sent as one.
      applyReplyHeaders(message,
          inReplyTo: inReplyTo, references: references);
      await _imap!.appendMessage(message,
          targetMailbox: drafts, flags: [r'\Draft', r'\Seen']);
      _log('[mail] saved draft to ${drafts.path}');
      unawaited(fetchDrafts());
      return true;
    } catch (e) {
      _log('[mail] could not save draft: $e');
      return false;
    }
  }

  /// Permanently removes [draft] from the Drafts folder. Drafts are not moved
  /// to Trash: a superseded draft is not a deleted mail.
  Future<bool> discardDraft(MimeMessage draft) async {
    final uid = draft.uid;
    if (uid == null) return false;
    if (!await _ensureConnected()) return false;
    try {
      if (!await _selectFolder(MailFolder.drafts)) return false;
      final seq = MessageSequence.fromId(uid, isUid: true);
      await _imap!.uidMarkDeleted(seq);
      try {
        await _imap!.uidExpunge(seq);
      } catch (_) {
        // No UIDPLUS: expunge the folder — only \Deleted drafts go.
        await _imap!.expunge();
      }
      _draftMessages.removeWhere((m) => m.uid == uid);
      notifyListeners();
      _log('[mail] discarded draft $uid');
      return true;
    } catch (e) {
      _log('[mail] discardDraft error: $e');
      return false;
    }
  }

  // Moves message to Trash instead of permanent expunge.
  Future<void> deleteMessage(MimeMessage message,
      {MailFolder folder = MailFolder.inbox}) async {
    final uid = message.uid;
    if (uid == null) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      // Resolve trash first — it may LIST/CREATE mailboxes — then select the
      // source folder so the UID operations run against the right mailbox.
      final trash = await _resolveTrashMailbox();
      if (!await _selectFolder(folder)) return;
      if (trash == null) {
        _log('[mail] deleteMessage: no trash folder — expunging instead');
        final seq = MessageSequence.fromId(uid, isUid: true);
        await _imap!.uidMarkDeleted(seq);
        await _imap!.uidExpunge(seq);
      } else {
        final seq = MessageSequence.fromId(uid, isUid: true);
        try {
          await _imap!.uidMove(seq, targetMailbox: trash);
          _log('[mail] moved $uid to trash via MOVE');
        } catch (_) {
          await _imap!.uidCopy(seq, targetMailbox: trash);
          await _imap!.uidMarkDeleted(seq);
          await _imap!.uidExpunge(seq);
          _log('[mail] moved $uid to trash via COPY+DELETE');
        }
      }
      _mutableListFor(folder).removeWhere((m) => m.uid == uid);
      _unreadController.add(unreadCount);
      notifyListeners();
      if (folder == MailFolder.inbox) unawaited(_updateOfflineCopy());
      // Refresh trash in background so the deleted message appears immediately.
      unawaited(fetchTrash());
    } catch (e) {
      _log('[mail] deleteMessage error: $e');
    }
  }

  Future<void> markAsRead(MimeMessage message,
      {MailFolder folder = MailFolder.inbox}) async {
    final uid = message.uid;
    if (uid == null || message.isSeen) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      if (!await _selectFolder(folder)) return;
      await _imap!.uidMarkSeen(MessageSequence.fromId(uid, isUid: true));
      final list = _mutableListFor(folder);
      final idx = list.indexWhere((m) => m.uid == uid);
      if (idx >= 0) list[idx].isSeen = true;
      _unreadController.add(unreadCount);
      notifyListeners();
      if (folder == MailFolder.inbox) unawaited(_updateOfflineCopy());
    } catch (e) {
      _log('[mail] error: $e');
    }
  }

  Future<void> markAsUnread(MimeMessage message,
      {MailFolder folder = MailFolder.inbox}) async {
    final uid = message.uid;
    if (uid == null || !message.isSeen) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      if (!await _selectFolder(folder)) return;
      await _imap!.uidMarkUnseen(MessageSequence.fromId(uid, isUid: true));
      final list = _mutableListFor(folder);
      final idx = list.indexWhere((m) => m.uid == uid);
      if (idx >= 0) list[idx].isSeen = false;
      _unreadController.add(unreadCount);
      notifyListeners();
      if (folder == MailFolder.inbox) unawaited(_updateOfflineCopy());
    } catch (e) {
      _log('[mail] error: $e');
    }
  }

  // Finds the Trash mailbox by \Trash flag first, then common names. Caches result.
  Future<Mailbox?> _resolveTrashMailbox() async {
    if (_trashMailbox != null) return _trashMailbox;
    try {
      final mailboxes = await _imap!.listMailboxes();

      // Prefer server-advertised \Trash special-use attribute.
      try {
        _trashMailbox = mailboxes.firstWhere(
          (mb) => mb.flags.contains(MailboxFlag.trash),
        );
        _log('[mail] found trash folder by flag: ${_trashMailbox!.path}');
        return _trashMailbox;
      } on StateError {
        // No \Trash flag — fall through to name matching.
      }

      const candidates = [
        'Trash', 'Papierkorb', 'Gelöscht', 'Deleted',
        'Deleted Items', 'Deleted Messages', 'INBOX.Trash',
      ];
      for (final name in candidates) {
        try {
          _trashMailbox = mailboxes.firstWhere(
            (mb) =>
                mb.name.toLowerCase() == name.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase(),
          );
          _log('[mail] found trash folder by name: ${_trashMailbox!.path}');
          return _trashMailbox;
        } on StateError {
          continue;
        }
      }

      // No matching folder — create one.
      _log('[mail] no trash folder found (available: '
          '${mailboxes.map((m) => m.name).join(', ')}), creating "Trash"');
      _trashMailbox = await _imap!.createMailbox('Trash');
      _log('[mail] created trash folder: ${_trashMailbox!.path}');
    } catch (e) {
      _log('[mail] could not resolve trash folder: $e');
    }
    return _trashMailbox;
  }

  // Moves a message from Trash back to Inbox.
  Future<void> restoreFromTrash(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      final trash = _trashMailbox ?? await _resolveTrashMailbox();
      if (trash == null) {
        _log('[mail] restoreFromTrash: no trash folder found');
        return;
      }
      // Select inbox to get its Mailbox reference, then switch to trash to operate.
      final inboxMailbox = await _imap!.selectInbox();
      await _imap!.selectMailbox(trash);
      final seq = MessageSequence.fromId(uid, isUid: true);
      try {
        await _imap!.uidMove(seq, targetMailbox: inboxMailbox);
        _log('[mail] restored $uid from trash via MOVE');
      } catch (_) {
        await _imap!.uidCopy(seq, targetMailbox: inboxMailbox);
        await _imap!.uidMarkDeleted(seq);
        await _imap!.uidExpunge(seq);
        _log('[mail] restored $uid from trash via COPY+DELETE');
      }
      _trashedMessages.removeWhere((m) => m.uid == uid);
      notifyListeners();
    } catch (e) {
      _log('[mail] restoreFromTrash error: $e');
    }
  }

  Future<List<MimeMessage>> fetchTrash({int limit = 50}) async {
    final ok = await _ensureConnected();
    if (!ok) return _trashedMessages;

    _isFetchingTrash = true;
    notifyListeners();

    try {
      final trash = await _resolveTrashMailbox();
      if (trash == null) {
        _log('[mail] fetchTrash: no trash folder available');
      } else {
        await _imap!.selectMailbox(trash);
        final result = await _imap!.fetchRecentMessages(
          messageCount: limit,
          criteria: '(FLAGS ENVELOPE UID BODY.PEEK[TEXT]<0.500>)',
          responseTimeout: const Duration(seconds: 90),
        );
        _trashedMessages = result.messages.reversed.toList();
        _log('[mail] fetched ${_trashedMessages.length} trashed messages');
      }
    } catch (e) {
      _log('[mail] fetchTrash error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      _trashMailbox = null; // invalidate cache on connection failure
    } finally {
      _isFetchingTrash = false;
      notifyListeners();
    }
    return _trashedMessages;
  }

  // Finds a special-use mailbox by its IMAP flag first, then common names.
  // Unlike trash, sent/drafts folders are never created if missing.
  Future<Mailbox?> _resolveSpecialMailbox({
    required MailboxFlag flag,
    required List<String> nameCandidates,
    required String label,
    ImapClient? via,
  }) async {
    try {
      final mailboxes = await (via ?? _imap!).listMailboxes();

      try {
        final mb = mailboxes.firstWhere(
          (mb) => mb.flags.contains(flag),
        );
        _log('[mail] found $label folder by flag: ${mb.path}');
        return mb;
      } on StateError {
        // No special-use flag — fall through to name matching.
      }

      for (final name in nameCandidates) {
        try {
          final mb = mailboxes.firstWhere(
            (mb) =>
                mb.name.toLowerCase() == name.toLowerCase() ||
                mb.path.toLowerCase() == name.toLowerCase(),
          );
          _log('[mail] found $label folder by name: ${mb.path}');
          return mb;
        } on StateError {
          continue;
        }
      }

      _log('[mail] no $label folder found (available: '
          '${mailboxes.map((m) => m.name).join(', ')})');
    } catch (e) {
      _log('[mail] could not resolve $label folder: $e');
    }
    return null;
  }

  /// [via]: list on that connection instead of the shared one.
  Future<Mailbox?> _resolveSentMailbox({ImapClient? via}) async {
    _sentMailbox ??= await _resolveSpecialMailbox(
      flag: MailboxFlag.sent,
      nameCandidates: const [
        'Sent', 'Sent Items', 'Sent Messages', 'Gesendet',
        'Gesendete Elemente', 'Gesendete Objekte', 'INBOX.Sent',
      ],
      label: 'sent',
      via: via,
    );
    return _sentMailbox;
  }

  Future<Mailbox?> _resolveDraftsMailbox() async {
    _draftsMailbox ??= await _resolveSpecialMailbox(
      flag: MailboxFlag.drafts,
      nameCandidates: const [
        'Drafts', 'Draft', 'Entwürfe', 'INBOX.Drafts',
      ],
      label: 'drafts',
    );
    return _draftsMailbox;
  }

  Future<List<MimeMessage>> fetchSent({int limit = 50}) async {
    final ok = await _ensureConnected();
    if (!ok) return _sentMessages;

    _isFetchingSent = true;
    notifyListeners();

    try {
      final sent = await _resolveSentMailbox();
      if (sent == null) {
        _log('[mail] fetchSent: no sent folder available');
      } else {
        await _imap!.selectMailbox(sent);
        final result = await _imap!.fetchRecentMessages(
          messageCount: limit,
          criteria: '(FLAGS ENVELOPE UID BODY.PEEK[TEXT]<0.500>)',
          responseTimeout: const Duration(seconds: 90),
        );
        _sentMessages = result.messages.reversed.toList();
        _log('[mail] fetched ${_sentMessages.length} sent messages');
      }
    } catch (e) {
      _log('[mail] fetchSent error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      _sentMailbox = null; // invalidate cache on connection failure
    } finally {
      _isFetchingSent = false;
      notifyListeners();
    }
    return _sentMessages;
  }

  Future<List<MimeMessage>> fetchDrafts({int limit = 50}) async {
    final ok = await _ensureConnected();
    if (!ok) return _draftMessages;

    _isFetchingDrafts = true;
    notifyListeners();

    try {
      final drafts = await _resolveDraftsMailbox();
      if (drafts == null) {
        _log('[mail] fetchDrafts: no drafts folder available');
      } else {
        await _imap!.selectMailbox(drafts);
        final result = await _imap!.fetchRecentMessages(
          messageCount: limit,
          criteria: '(FLAGS ENVELOPE UID BODY.PEEK[TEXT]<0.500>)',
          responseTimeout: const Duration(seconds: 90),
        );
        _draftMessages = result.messages.reversed.toList();
        _log('[mail] fetched ${_draftMessages.length} draft messages');
      }
    } catch (e) {
      _log('[mail] fetchDrafts error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      _draftsMailbox = null; // invalidate cache on connection failure
    } finally {
      _isFetchingDrafts = false;
      notifyListeners();
    }
    return _draftMessages;
  }

  @override
  void dispose() {
    _offlineImap?.disconnect();
    _imap?.disconnect();
    _unreadController.close();
    super.dispose();
  }
}
