import 'dart:async';
import 'dart:math' show min, max;

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'imap_preview_fix.dart';
import 'imap_session.dart';
import 'mail_attachments.dart';
import 'mail_notifier.dart';
import 'mail_offline_cache.dart';
import 'mail_sync.dart';
import 'mail_threads.dart';
import 'notification_service.dart';
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

/// Opening the main connection failed — offline, or the server said no.
class MailConnectException implements Exception {
  const MailConnectException(this.cause, {required this.rejected});

  final Object cause;

  /// The server refused the login (or there are no credentials): retrying
  /// on its own would only count against the server's login limit.
  final bool rejected;

  @override
  String toString() => '$cause';
}

/// One folder's list and how it stands with the server.
class _FolderState {
  List<MimeMessage> messages = [];
  int? uidValidity;
  bool hasOlder = false;
  DateTime? syncedAt;
  bool failed = false;
  String? error;
  Future<void>? refreshing;
  Future<void>? loadingOlder;
  DateTime? olderFailedAt;

  /// The folder's message count and next UID at the last sync — IDLE only
  /// starts when the server still says the same.
  int? exists;
  int? uidNext;
}

/// What a folder fetch brought back — applied to the list after the op, so
/// an op abandoned by its timeout changes nothing.
class _FolderFetch {
  const _FolderFetch({
    required this.uidValidity,
    required this.exists,
    required this.uidNext,
    required this.hasOlder,
    this.replace,
    this.fromUid,
    this.flags = const {},
    this.fetchedNew = const [],
    this.older = const [],
  });

  final int? uidValidity;
  final int exists;
  final int? uidNext;

  /// Whether the server has mail below the list's oldest.
  final bool hasOlder;

  /// The new list, when it starts over.
  final List<MimeMessage>? replace;

  /// Otherwise a delta: flags of every message from [fromUid] up, and the
  /// list rows of the new ones.
  final int? fromUid;
  final Map<int, List<String>> flags;
  final List<MimeMessage> fetchedNew;

  /// The page just older than the list, when one was asked for.
  final List<MimeMessage> older;
}

// Mail diagnostics include addresses and server responses — release builds
// log nothing to the device console.
void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

class MailService extends ChangeNotifier {
  // Public for the background check (mail_background_check.dart).
  static const imapHost = 'imap.intranet.fh-koeln.de';
  static const imapPort = 993;
  static const _imapHost = imapHost;
  static const _imapPort = imapPort;
  static const _smtpHost = 'smtp.intranet.fh-koeln.de';
  static const _smtpPort = 587;
  static const _smtpResponseTimeout = Duration(seconds: 30);
  static const _emailStorageKey = 'kisd_email';
  static const _smtpSizeLimitKey = 'mail_smtp_max_size';

  // A folder fetch as a whole, and each of its commands.
  static const _fetchTimeout = Duration(seconds: 90);
  static const _commandTimeout = Duration(seconds: 75);

  /// A folder synced this recently isn't fetched again just for being
  /// opened.
  static const _freshFor = Duration(seconds: 30);

  /// Servers drop an IDLE after 30 min (RFC 2177), mobile networks often
  /// sooner. Re-armed well before, which also proves the connection alive.
  static const _idleRearmEvery = Duration(minutes: 8);

  /// Without IDLE, the inbox is checked this often while the app is open.
  static const _pollEvery = Duration(seconds: 60);

  /// Away longer than this, the connection is replaced rather than probed:
  /// it is almost certainly dead, and probing it costs seconds.
  static const _replaceAfterBackground = Duration(minutes: 10);

  // Must match LoginService's options — both services share the credential
  // keys, and iOS Keychain lookups are scoped by these attributes.
  final _storage = const FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
  );

  // Every command on the main connection goes through this — see
  // ImapSession for why. Replaced on an account switch.
  late ImapSession<ImapClient> _session = _newSession();

  Map<MailFolder, _FolderState> _folders = _emptyFolders();
  bool _isConnecting = false;
  String? _connectionError;
  String? _cachedUsername;
  Mailbox? _trashMailbox;
  Mailbox? _sentMailbox;
  Mailbox? _draftsMailbox;

  // Automatic refreshes (IDLE, polling, resume) back off after a failed
  // connect; a refused login stops them until the user asks.
  DateTime _autoNotBefore = DateTime(0);
  int _autoFailures = 0;
  bool _loginRejected = false;

  // New mail while the app is open: IDLE on the main connection.
  bool _started = false;
  bool? _idleSupported;
  ImapClient? _idleOn;
  StreamSubscription<ImapEvent>? _events;
  Timer? _idleRearmTimer;
  Timer? _pollTimer;
  Timer? _eventTimer;
  int _lostInARow = 0;
  (int, int?)? _staleInboxState;
  bool _foreground = true;
  DateTime? _backgroundSince;
  AppLifecycleListener? _lifecycle;

  /// The folder the Mail tab shows — refreshed with the inbox on resume.
  MailFolder activeFolder = MailFolder.inbox;

  /// Whether the Mail page is the one on screen (set by HomeScreen). New
  /// mail isn't announced while its inbox is in view.
  bool mailPageVisible = false;

  // Announcements in order: each reads and moves the shared mark.
  Future<void> _notifyChain = Future.value();

  final _offline = MailOfflineCache();
  // Bumped by resetForAccountSwitch, so a fetch, cache load or sync still in
  // flight sees its account is gone and drops what it has instead of
  // showing or writing it.
  int _generation = 0;
  bool _offlineSyncRunning = false;
  bool _offlineSyncAgain = false;
  bool _offlineFetchPending = false;
  ImapClient? _offlineImap;
  DateTime? _offlineImapUsed;
  Timer? _offlineIdleTimer;

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

  static Map<MailFolder, _FolderState> _emptyFolders() => {
    for (final f in MailFolder.values) f: _FolderState(),
  };

  bool get isConnected => _session.current?.isConnected ?? false;
  bool get isConnecting => _isConnecting;
  String? get connectionError => _connectionError;
  List<MimeMessage> get messages => messagesIn(MailFolder.inbox);
  List<MimeMessage> get trashedMessages => messagesIn(MailFolder.trash);
  List<MimeMessage> get sentMessages => messagesIn(MailFolder.sent);
  List<MimeMessage> get draftMessages => messagesIn(MailFolder.drafts);
  int get unreadCount => _inbox.where((m) => !m.isSeen).length;
  Stream<int> get unreadCountStream => _unreadController.stream;

  List<MimeMessage> messagesIn(MailFolder folder) =>
      List.unmodifiable(_folders[folder]!.messages);

  /// True while [folder]'s list is being fetched.
  bool isRefreshing(MailFolder folder) => _folders[folder]!.refreshing != null;

  /// True while an older page of [folder] is being fetched.
  bool isLoadingOlder(MailFolder folder) =>
      _folders[folder]!.loadingOlder != null;

  /// True when the server has mail older than [folder]'s list.
  bool hasOlder(MailFolder folder) => _folders[folder]!.hasOlder;

  /// Why [folder]'s last fetch failed; null after a successful one. A
  /// folder never fetched because the connection fails says so too, rather
  /// than looking empty.
  String? errorFor(MailFolder folder) {
    final s = _folders[folder]!;
    if (s.failed) return s.error;
    if (s.syncedAt == null) return _connectionError;
    return null;
  }

  /// The inbox UIDVALIDITY its list belongs to — a notification's UID only
  /// names one of these mails while it matches.
  int? get inboxUidValidity => _inboxUidValidity;

  List<MimeMessage> get _inbox => _folders[MailFolder.inbox]!.messages;
  // The inbox UIDVALIDITY the list belongs to — a cached UID only names the
  // same mail while this is unchanged.
  int? get _inboxUidValidity => _folders[MailFolder.inbox]!.uidValidity;

  // ── Connection ───────────────────────────────────────────────────────────

  ImapSession<ImapClient> _newSession() {
    final generation = _generation;
    return ImapSession<ImapClient>(
      connect: () => _openMainConnection(generation),
      isAlive: (c) => c.isConnected && c.isLoggedIn,
      probe: (c) => c.noop(),
      close: (c) {
        if (identical(_idleOn, c)) _idleOn = null;
        unawaited(c.disconnect().catchError((_) {}));
      },
      prepare: _leaveIdle,
      onDrained: _onSessionDrained,
      log: _log,
    );
  }

  Future<ImapClient> _openMainConnection(int generation) async {
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) {
      throw const MailConnectException(
        'No stored credentials — please log in first.',
        rejected: true,
      );
    }
    _log('[mail] connecting to $_imapHost...');
    // Same client, except that list previews keep their bytes — see
    // PreviewFixImapClient.
    final imap = PreviewFixImapClient(isLogEnabled: false);
    try {
      await imap.connectToServer(
        _imapHost,
        _imapPort,
        isSecure: true,
        timeout: const Duration(seconds: 15),
      );
    } catch (e) {
      unawaited(imap.disconnect().catchError((_) {}));
      throw MailConnectException(e, rejected: false);
    }
    try {
      await imap.login(username, password).timeout(const Duration(seconds: 20));
    } on ImapException catch (e) {
      unawaited(imap.disconnect().catchError((_) {}));
      throw MailConnectException(e, rejected: true);
    } catch (e) {
      unawaited(imap.disconnect().catchError((_) {}));
      throw MailConnectException(e, rejected: false);
    }
    if (generation != _generation) {
      unawaited(imap.disconnect().catchError((_) {}));
      throw const MailConnectException('signed out', rejected: false);
    }
    _cachedUsername = username;
    // The password works again: the background check may resume.
    unawaited(MailNotifier.setPaused(false).catchError((_) {}));
    final idle = imap.serverInfo.supportsIdle;
    if (_idleSupported == null) {
      _log(
        '[mail] server capabilities: '
        '${imap.serverInfo.capabilities?.map((c) => c.name).join(' ')}',
      );
    }
    _idleSupported = idle;
    _updatePolling();
    unawaited(_events?.cancel());
    _events = imap.eventBus.on<ImapEvent>().listen(
      (e) => _onImapEvent(imap, e),
    );
    _log(
      '[mail] connected (${idle ? 'IDLE' : 'polling every '
                '${_pollEvery.inSeconds} s'})',
    );
    return imap;
  }

  /// Runs [op] on the main connection, after checking the account is still
  /// the one this state belongs to.
  Future<T> _run<T>(
    String label,
    Future<T> Function(ImapClient c) op, {
    Duration timeout = const Duration(seconds: 45),
    bool idempotent = false,
  }) async {
    await _resetIfAccountChanged();
    return _session.run(label, op, timeout: timeout, idempotent: idempotent);
  }

  bool get _autoBlocked => DateTime.now().isBefore(_autoNotBefore);

  void _noteSuccess() {
    _connectionError = null;
    _autoFailures = 0;
    _loginRejected = false;
    _autoNotBefore = DateTime(0);
  }

  void _noteFailure(Object e) {
    if (e is! MailConnectException) return;
    _connectionError = 'Could not connect: ${e.cause}';
    if (e.rejected) {
      _loginRejected = true;
      _autoNotBefore = DateTime(9999);
    } else {
      _autoFailures++;
      _autoNotBefore = DateTime.now().add(
        Duration(seconds: min(300, 5 << min(_autoFailures, 6))),
      );
    }
  }

  /// Shows the offline copy, then fetches the inbox. Also starts keeping it
  /// current: IDLE (or polling) while the app is open, a refresh on resume.
  Future<void> connect() async {
    // Must run first: on an account switch the old session is still alive,
    // and it would hand the new user the previous account's mailbox.
    await _resetIfAccountChanged();
    _started = true;
    _lifecycle ??= AppLifecycleListener(onHide: _onHide, onShow: _onShow);
    if (_isConnecting) return;
    _isConnecting = true;
    _connectionError = null;
    notifyListeners();
    try {
      // The offline copy first, so the lists are up before — or instead
      // of — the server's answer.
      await _loadOfflineFolders();
      await refreshFolder(MailFolder.inbox, force: true);
    } finally {
      _isConnecting = false;
      notifyListeners();
    }
  }

  /// Clears every trace of the previously signed-in account when the stored
  /// Campus ID no longer matches the one this session authenticated as.
  ///
  /// `MailService` is a process-lifetime singleton (`service_locator.dart`)
  /// that nothing disposes, so without this a sign-out leaves a live IMAP
  /// socket still authenticated as the old user — and every early return
  /// then serves the new user that mailbox.
  Future<void> _resetIfAccountChanged() async {
    if (_cachedUsername == null) return; // never connected — nothing to compare
    final stored = await _storage.read(key: 'kisd_username');
    if (stored == _cachedUsername) return;
    _log('[mail] signed-in account changed — clearing mail state');
    await resetForAccountSwitch();
  }

  /// Drops the connections and all cached mail for the previous account.
  /// Safe to call when nothing is connected.
  Future<void> resetForAccountSwitch() async {
    _generation++;
    // `_started` stays: the lifecycle hooks serve the next account too.
    _session.dispose();
    _session = _newSession();
    _idleOn = null;
    _idleSupported = null;
    unawaited(_events?.cancel());
    _events = null;
    _idleRearmTimer?.cancel();
    _pollTimer?.cancel();
    _pollTimer = null;
    _eventTimer?.cancel();
    _lostInARow = 0;
    _offlineIdleTimer?.cancel();
    _offlineImap?.disconnect();
    _offlineImap = null;
    _threadImap?.disconnect();
    _threadImap = null;
    _threadCache.clear();
    _isConnecting = false;
    _connectionError = null;
    _folders = _emptyFolders();
    activeFolder = MailFolder.inbox;
    _autoNotBefore = DateTime(0);
    _autoFailures = 0;
    _loginRejected = false;
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

  // ── Keeping the lists current ────────────────────────────────────────────

  /// Leaves IDLE before the session's next op. True: the server answered.
  Future<bool> _leaveIdle(ImapClient c) async {
    if (!identical(_idleOn, c)) return false;
    _idleOn = null;
    _idleRearmTimer?.cancel();
    await c.idleDone();
    return true;
  }

  /// Nothing queued on the main connection: wait in IDLE on the inbox. Only
  /// on a connection that is already open — never a login just to idle.
  void _onSessionDrained() {
    if (!_started || !_foreground || _idleSupported != true) return;
    final current = _session.current;
    if (current == null || !current.isConnected) return;
    if (identical(_idleOn, current)) return;
    unawaited(
      _session
          .run('idle', (c) async {
            if (!_foreground || identical(_idleOn, c)) return false;
            final inbox = await c.selectInbox();
            // Mail that came while no IDLE was running (during a mail open,
            // a mark, the pause before this) was only announced in an
            // answer nobody listened to — and IDLE won't announce it again.
            final state = (inbox.messagesExists, inbox.uidNext);
            final synced = _folders[MailFolder.inbox]!;
            final moved = state != (synced.exists, synced.uidNext);
            if (moved && state != _staleInboxState) {
              _staleInboxState = state; // once per state: no refresh loop
              return true;
            }
            await c.idleStart();
            _idleOn = c;
            return false;
          }, timeout: const Duration(seconds: 20))
          .then((stale) {
            // Outside the op: these call back into the session.
            if (stale) {
              unawaited(_autoRefresh(MailFolder.inbox, announce: true));
            } else if (_idleOn != null) {
              _armIdleRearm();
            }
          })
          .catchError((Object e) {
            _log('[mail] could not start IDLE: $e');
          }),
    );
  }

  void _armIdleRearm() {
    _idleRearmTimer?.cancel();
    _idleRearmTimer = Timer(_idleRearmEvery, () {
      // IDLE held for minutes — the connection is a good one.
      _lostInARow = 0;
      // Leaving IDLE checks the connection; the delta sync catches
      // anything a silently dead one missed.
      if (_foreground) {
        unawaited(_autoRefresh(MailFolder.inbox, announce: true));
      }
    });
  }

  void _onImapEvent(ImapClient c, ImapEvent e) {
    if (e is ImapConnectionLostEvent) {
      if (!identical(_session.current, c)) return;
      if (identical(_idleOn, c)) _idleOn = null;
      _log('[mail] connection lost');
      if (!_foreground || !_started) return;
      // Back again soon, but not in a loop when the server keeps closing:
      // 5 s, 10 s, 20 s … up to 8 min.
      final delay = Duration(seconds: min(480, 5 << min(_lostInARow, 7)));
      _lostInARow++;
      _scheduleInboxRefresh(delay);
      return;
    }
    // Our own commands' responses carry these too; only while idling are
    // they news from the server.
    if (!identical(_idleOn, c)) return;
    if (e is ImapMessagesExistEvent ||
        e is ImapExpungeEvent ||
        e is ImapFetchEvent ||
        e is ImapVanishedEvent) {
      _scheduleInboxRefresh(const Duration(seconds: 1));
    }
  }

  // Only ever while the app is open: whatever it finds arrived just now.
  void _scheduleInboxRefresh(Duration delay) {
    _eventTimer?.cancel();
    _eventTimer = Timer(
      delay,
      () => unawaited(_autoRefresh(MailFolder.inbox, announce: true)),
    );
  }

  void _updatePolling() {
    final want = _started && _foreground && _idleSupported == false;
    if (want && _pollTimer == null) {
      _pollTimer = Timer.periodic(_pollEvery, (_) {
        unawaited(_autoRefresh(MailFolder.inbox, announce: true));
      });
    } else if (!want) {
      _pollTimer?.cancel();
      _pollTimer = null;
    }
  }

  void _onHide() {
    if (!_foreground) return;
    _foreground = false;
    _backgroundSince = DateTime.now();
    _updatePolling();
    _idleRearmTimer?.cancel();
    _eventTimer?.cancel();
    final current = _session.current;
    if (current != null && identical(_idleOn, current)) {
      // Ends IDLE (the session's prepare step) while iOS still lets the app
      // run.
      unawaited(
        _session
            .run('pause', (_) async {}, timeout: const Duration(seconds: 5))
            .catchError((_) {}),
      );
    }
  }

  void _onShow() {
    if (_foreground) return;
    _foreground = true;
    final since = _backgroundSince;
    _backgroundSince = null;
    if (!_started) return;
    if (since != null &&
        DateTime.now().difference(since) > _replaceAfterBackground) {
      _session.drop();
    }
    // The network may be back; a refused login stays refused.
    if (!_loginRejected) {
      _autoNotBefore = DateTime(0);
      _autoFailures = 0;
    }
    for (final s in _folders.values) {
      s.syncedAt = null;
    }
    unawaited(_autoRefresh(MailFolder.inbox));
    if (activeFolder != MailFolder.inbox) unawaited(_autoRefresh(activeFolder));
    _updatePolling();
  }

  // ── Folder lists ─────────────────────────────────────────────────────────

  /// Brings [folder]'s list up to date: only what changed since the last
  /// fetch (new mail, flags, deletions), or the newest page when it starts
  /// over. Skipped while a fetch of it runs (that one is returned) and,
  /// unless [force], when it was fetched in the last 30 s or the last
  /// connect failed moments ago. Never throws: a failure shows in
  /// [errorFor].
  Future<void> refreshFolder(MailFolder folder, {bool force = false}) =>
      _refresh(folder, ignoreFresh: force, ignoreBackoff: force);

  /// IDLE, polling and resume: always fetches, but respects the backoff.
  /// With [announce] (IDLE and polling — the app was open as the mail
  /// came), new inbox mail gets a notification; otherwise it is only marked
  /// as known, since the list is about to show it.
  Future<void> _autoRefresh(MailFolder folder, {bool announce = false}) =>
      _refresh(
        folder,
        ignoreFresh: true,
        ignoreBackoff: false,
        announce: announce,
      );

  Future<void> _refresh(
    MailFolder folder, {
    required bool ignoreFresh,
    required bool ignoreBackoff,
    bool announce = false,
  }) {
    final s = _folders[folder]!;
    final running = s.refreshing;
    if (running != null) return running;
    if (!ignoreFresh) {
      final synced = s.syncedAt;
      if (!s.failed &&
          synced != null &&
          DateTime.now().difference(synced) < _freshFor) {
        return Future.value();
      }
    }
    if (!ignoreBackoff && _autoBlocked) return Future.value();
    final future = _fetchAndApply(
      folder,
      s,
      older: false,
      announce: announce,
    );
    s.refreshing = future;
    notifyListeners();
    return future.whenComplete(() {
      if (identical(s.refreshing, future)) s.refreshing = null;
      notifyListeners();
    });
  }

  /// Fetches the page of [folder] just older than its list, as the list
  /// scrolls to its end.
  Future<void> loadOlder(MailFolder folder) {
    final s = _folders[folder]!;
    final running = s.loadingOlder;
    if (running != null) return running;
    if (!s.hasOlder || s.messages.isEmpty || _autoBlocked) {
      return Future.value();
    }
    // A failed page isn't retried on every scroll event.
    final failedAt = s.olderFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < const Duration(seconds: 10)) {
      return Future.value();
    }
    final future = _fetchAndApply(folder, s, older: true);
    s.loadingOlder = future;
    notifyListeners();
    return future.whenComplete(() {
      if (identical(s.loadingOlder, future)) s.loadingOlder = null;
      notifyListeners();
    });
  }

  Future<void> _fetchAndApply(
    MailFolder folder,
    _FolderState s, {
    required bool older,
    bool announce = false,
  }) async {
    final generation = _generation;
    final current = List.of(s.messages);
    final known = s.uidValidity;
    try {
      final result = await _run(
        '${older ? 'older' : 'refresh'} ${folder.name}',
        (c) => _fetchFolder(
          c,
          folder,
          current: current,
          knownValidity: known,
          older: older,
        ),
        timeout: _fetchTimeout,
        idempotent: true,
      );
      if (generation != _generation) return;
      _noteSuccess();
      s.failed = false;
      s.error = null;
      s.olderFailedAt = null;
      if (result == null) {
        _log('[mail] no ${folder.name} folder on the server');
        s.syncedAt = DateTime.now();
        return;
      }
      _apply(folder, s, result, announce: announce);
    } catch (e) {
      if (generation != _generation) return;
      _log(
        '[mail] ${older ? 'older page' : 'refresh'} of ${folder.name} '
        'failed: $e',
      );
      _noteFailure(e);
      if (older) {
        s.olderFailedAt = DateTime.now();
      } else {
        s.failed = true;
        s.error = e is MailConnectException
            ? 'Could not connect: ${e.cause}'
            : 'Could not load mail: $e';
      }
    }
  }

  /// One session op: SELECT, then the newest page or the delta, then — for
  /// [older] — the page below. Returns what to apply; null when the folder
  /// doesn't exist.
  Future<_FolderFetch?> _fetchFolder(
    ImapClient c,
    MailFolder folder, {
    required List<MimeMessage> current,
    required int? knownValidity,
    required bool older,
  }) async {
    final box = await _selectOn(c, folder);
    if (box == null) return null;
    final exists = box.messagesExists;
    final validity = box.uidValidity;
    final uidNext = box.uidNext;
    var kind = planRefresh(
      exists: exists,
      uidValidity: validity,
      knownUidValidity: knownValidity,
      current: current,
    );

    List<MimeMessage>? replace;
    int? fromUid;
    var flags = <int, List<String>>{};
    var fetchedNew = <MimeMessage>[];
    // The sequence number of the oldest listed message, where an older page
    // ends. 0: nothing listed.
    var lowestSeq = 0;
    if (kind == RefreshKind.delta) {
      final uids = [for (final m in current) m.uid!];
      final lowest = uids.reduce(min);
      final highest = uids.reduce(max);
      // Small: UID and flags of every listed message, plus any newer ones.
      final answer = await c.uidFetchMessages(
        MessageSequence.fromRangeToLast(lowest, isUidSequence: true),
        '(UID FLAGS)',
        responseTimeout: _commandTimeout,
      );
      int? seqOfLowest;
      for (final m in answer.messages) {
        final uid = m.uid;
        // `n:*` always includes the last message, even below n.
        if (uid == null || uid < lowest) continue;
        flags[uid] = [...?m.flags];
        final seq = m.sequenceId;
        if (seq != null && (seqOfLowest == null || seq < seqOfLowest)) {
          seqOfLowest = seq;
        }
      }
      final fresh = newUidsOf(flags, highest);
      // Every listed mail gone (deleted elsewhere): start over too.
      if (fresh.length > maxDeltaNewMessages || flags.isEmpty) {
        kind = RefreshKind.full;
      } else {
        if (fresh.isNotEmpty) {
          fetchedNew = (await c.uidFetchMessages(
            MessageSequence.fromIds(fresh, isUid: true),
            listFetchCriteria,
            responseTimeout: _commandTimeout,
          )).messages;
        }
        fromUid = lowest;
        lowestSeq = seqOfLowest ?? exists - flags.length + 1;
      }
    }
    if (kind == RefreshKind.full) {
      final range = newestRange(exists)!;
      replace = await _fetchRange(c, range);
      fromUid = null;
      flags = {};
      fetchedNew = [];
      lowestSeq = range.$1;
    } else if (kind == RefreshKind.empty) {
      replace = [];
    }

    var olderPage = const <MimeMessage>[];
    if (older && lowestSeq > 1) {
      final range = pageBelow(lowestSeq)!;
      olderPage = await _fetchRange(c, range);
      lowestSeq = range.$1;
    }
    return _FolderFetch(
      uidValidity: validity,
      exists: exists,
      uidNext: uidNext,
      hasOlder: lowestSeq > 1,
      replace: replace,
      fromUid: fromUid,
      flags: flags,
      fetchedNew: fetchedNew,
      older: olderPage,
    );
  }

  Future<List<MimeMessage>> _fetchRange(ImapClient c, (int, int) range) async {
    final result = await c.fetchMessages(
      MessageSequence.fromRange(range.$1, range.$2),
      listFetchCriteria,
      responseTimeout: _commandTimeout,
    );
    return sortNewestFirst(result.messages);
  }

  void _apply(
    MailFolder folder,
    _FolderState s,
    _FolderFetch r, {
    bool announce = false,
  }) {
    final before = {for (final m in s.messages) ?m.uid};
    final replace = r.replace;
    // Read before applyDelta, which updates the flags in place.
    final flagsChanged = s.messages.any((m) {
      final flags = r.flags[m.uid];
      return flags != null && !sameFlags(m.flags, flags);
    });
    var list = replace != null
        ? sortNewestFirst(replace)
        : applyDelta(
            current: s.messages,
            fromUid: r.fromUid!,
            flagsByUid: r.flags,
            fetchedNew: r.fetchedNew,
          );
    if (r.older.isNotEmpty) list = appendOlder(list, r.older);
    final arrived = list.any((m) => !before.contains(m.uid));
    final membership = arrived || list.length != before.length;
    // Polling and IDLE refresh often; an unchanged list isn't rewritten.
    final changed =
        membership ||
        flagsChanged ||
        replace != null ||
        s.uidValidity != r.uidValidity;
    s.messages = list;
    s.uidValidity = r.uidValidity;
    s.hasOlder = r.hasOlder;
    s.exists = r.exists;
    s.uidNext = r.uidNext;
    s.syncedAt = DateTime.now();
    _log(
      '[mail] ${folder.name}: ${list.length} of ${r.exists} listed'
      '${replace != null
          ? ' (new list)'
          : changed
          ? ''
          : ' (no change)'}',
    );
    // Mail that came or went may belong to a conversation looked up before.
    if (membership && folder != MailFolder.drafts) _threadCache.clear();
    if (folder == MailFolder.inbox) {
      _unreadController.add(unreadCount);
      // Bodies even when nothing changed: a download cut short last time
      // is finished now.
      unawaited(_updateOfflineCopy(fetchBodies: true, saveList: changed));
      _queueNotifications(announce: announce, listChanged: changed);
    } else if (changed) {
      unawaited(_saveFolderIndex(folder));
    }
  }

  // Selects the IMAP mailbox for [folder]; null if it cannot be resolved.
  Future<Mailbox?> _selectOn(ImapClient c, MailFolder folder) async {
    final Mailbox? box = switch (folder) {
      MailFolder.inbox => null,
      MailFolder.trash => await _resolveTrashMailbox(c),
      MailFolder.sent => await _resolveSentMailbox(c),
      MailFolder.drafts => await _resolveDraftsMailbox(c),
    };
    if (folder == MailFolder.inbox) return c.selectInbox();
    if (box == null) return null;
    return c.selectMailbox(box);
  }

  // ── New-mail notifications ───────────────────────────────────────────────

  /// After an inbox sync: announces mail above the shared mark (only for
  /// [announce] refreshes, with notifications on and the inbox not in
  /// view), always moves the mark to the newest mail — so the background
  /// check never announces what the app already showed — and removes the
  /// notifications of mails read or deleted since.
  void _queueNotifications({required bool announce, required bool listChanged}) {
    final owner = _cachedUsername;
    final validity = _inboxUidValidity;
    if (owner == null || validity == null) return;
    final generation = _generation;
    final inbox = List.of(_inbox);
    final uidNext = _folders[MailFolder.inbox]!.uidNext;
    final quiet =
        _foreground && mailPageVisible && activeFolder == MailFolder.inbox;
    _notifyChain = _notifyChain
        .then((_) async {
          if (generation != _generation) return;
          final plan = planMailAnnouncements(
            stored: await MailNotifier.readMark(),
            owner: owner,
            uidValidity: validity,
            uidNext: uidNext,
            inbox: [
              for (final m in inbox)
                if (m.uid != null) (uid: m.uid!, seen: m.isSeen),
            ],
          );
          if (announce && !quiet && MailNotifier.enabled.value) {
            final byUid = {for (final m in inbox) m.uid: m};
            for (final uid in plan.uids) {
              final m = byUid[uid];
              if (m == null) continue;
              final c = mailNotificationContent(m);
              await NotificationService.instance.show(
                mailNotificationId(uid),
                c.title,
                c.body,
                NotificationPayload(
                  type: 'mail',
                  id: mailPayloadId(validity, uid),
                ),
                subtitle: c.subtitle,
                threadIdentifier: mailThreadIdentifier,
              );
            }
          }
          if (generation != _generation) return;
          await MailNotifier.writeMark(plan.mark);
          if (listChanged) await _removeStaleNotifications(inbox, validity);
        })
        .catchError((Object e) {
          _log('[mail] notifications failed: $e');
        });
  }

  /// Notification Centre keeps a mail's notification until it is opened
  /// from there; once the mail is read here (or elsewhere) or deleted, it
  /// goes.
  Future<void> _removeStaleNotifications(
    List<MimeMessage> inbox,
    int validity,
  ) async {
    final svc = NotificationService.instance;
    final delivered = await svc.delivered('mail');
    if (delivered.isEmpty) return;
    final byUid = {for (final m in inbox) m.uid: m};
    final lowest = inbox.isEmpty
        ? null
        : inbox.map((m) => m.uid ?? 0).reduce(min);
    for (final MapEntry(key: id, value: payloadId) in delivered.entries) {
      final ref = parseMailPayloadId(payloadId);
      final m = ref == null ? null : byUid[ref.$2];
      final stale =
          ref == null ||
          ref.$1 != validity ||
          (m != null && m.isSeen) ||
          (m == null && lowest != null && ref.$2 >= lowest);
      if (stale) await svc.cancel(id);
    }
  }

  // ── Offline copy ─────────────────────────────────────────────────────────

  /// Shows the offline copy of every folder. Only the signed-in account's:
  /// a copy of someone else's is skipped, not deleted — deleting is the
  /// account switch's job, which only runs once a login has succeeded.
  Future<void> _loadOfflineFolders() async {
    final generation = _generation;
    final username = await _storage.read(key: 'kisd_username');
    if (username == null) return;
    var shown = 0;
    for (final folder in MailFolder.values) {
      final s = _folders[folder]!;
      if (s.messages.isNotEmpty) continue;
      try {
        final index = await _offline.readIndex(folder: folder.name);
        if (index == null || generation != _generation) continue;
        if (s.messages.isNotEmpty) continue;
        if (index.owner.trim().toLowerCase() != username.trim().toLowerCase()) {
          continue;
        }
        s.messages = index.messages;
        s.uidValidity = index.uidValidity;
        s.hasOlder = index.messages.isNotEmpty;
        // The account this mail belongs to — lets _resetIfAccountChanged
        // clear it on a switch even if this session never got online.
        _cachedUsername ??= username;
        shown += index.messages.length;
      } catch (e) {
        _log('[mail] could not load offline ${folder.name}: $e');
      }
    }
    if (shown == 0 || generation != _generation) return;
    _log('[mail] showing $shown offline messages');
    _unreadController.add(unreadCount);
    notifyListeners();
  }

  /// Saves [folder]'s list rows (not the inbox — see [_updateOfflineCopy]).
  Future<void> _saveFolderIndex(MailFolder folder) async {
    final owner = _cachedUsername;
    final uidValidity = _folders[folder]!.uidValidity;
    if (owner == null || uidValidity == null) return;
    try {
      await _offline.writeIndex(
        folder: folder.name,
        owner: owner,
        uidValidity: uidValidity,
        messages: _folders[folder]!.messages,
      );
    } catch (e) {
      _log('[mail] could not save offline ${folder.name}: $e');
    }
  }

  /// Mirrors the inbox list into the offline copy and drops the full mails
  /// that left it. With [fetchBodies], also downloads the ones it lacks — only
  /// after an inbox fetch, so marking or deleting never opens a connection.
  Future<void> _updateOfflineCopy({
    bool fetchBodies = false,
    bool saveList = true,
  }) async {
    final owner = _cachedUsername;
    final uidValidity = _inboxUidValidity;
    if (owner == null || uidValidity == null) return;
    if (saveList) {
      try {
        await _offline.writeIndex(
          owner: owner,
          uidValidity: uidValidity,
          messages: _inbox,
        );
      } catch (e) {
        _log('[mail] could not save offline list: $e');
        return;
      }
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
  /// [MailOfflineCache.maxBodies] inbox messages that aren't on disk yet —
  /// a mail never changes under its UID, so each is downloaded once. Then
  /// deletes the bodies of mails no longer in that list.
  Future<void> _syncOfflineBodies({required bool fetch}) async {
    final generation = _generation;
    final uidValidity = _inboxUidValidity;
    final wanted = [
      for (final m in _inbox.take(MailOfflineCache.maxBodies))
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
    if (generation == _generation) await _offline.prune(keep);
  }

  /// The offline copy's own connection, kept for a few minutes: new mail
  /// arriving one by one (IDLE) shouldn't cost a login each.
  Future<ImapClient?> _offlineClient() async {
    final current = _offlineImap;
    final used = _offlineImapUsed;
    final fresh = used != null && DateTime.now().difference(used).inMinutes < 4;
    if (current != null && current.isConnected && fresh) return current;
    current?.disconnect();
    _offlineImap = null;
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return null;
    final imap = ImapClient(isLogEnabled: false);
    try {
      await imap.connectToServer(
        _imapHost,
        _imapPort,
        isSecure: true,
        timeout: const Duration(seconds: 10),
      );
      await imap.login(username, password);
    } catch (_) {
      imap.disconnect();
      rethrow;
    }
    _offlineImap = imap;
    return imap;
  }

  /// On a connection of its own, with the inbox EXAMINEd read-only: a body
  /// download takes long enough that it would hold up the main connection's
  /// ops. BODY.PEEK so caching doesn't mark 50 mails read.
  Future<void> _fetchOfflineBodies(
    List<int> uids,
    Set<int> keep,
    int uidValidity,
    int generation,
  ) async {
    if (generation != _generation) return;
    _offlineIdleTimer?.cancel();
    var saved = 0;
    ImapClient? imap;
    try {
      imap = await _offlineClient();
      if (imap == null || generation != _generation) return;
      final inbox = await imap
          .examineMailbox(
            Mailbox(
              encodedName: 'INBOX',
              encodedPath: 'INBOX',
              flags: [],
              pathSeparator: '/',
            ),
          )
          .timeout(const Duration(seconds: 20));
      if (inbox.uidValidity != uidValidity) return;
      for (var i = 0; i < uids.length; i += 10) {
        if (generation != _generation) return;
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
          if (generation != _generation) return;
          await _offline.writeBody(uid, data.data);
          saved++;
        }
      }
    } catch (e) {
      _log('[mail] offline sync stopped: $e');
      if (identical(_offlineImap, imap)) _offlineImap = null;
      imap?.disconnect();
    } finally {
      _offlineImapUsed = DateTime.now();
      _offlineIdleTimer?.cancel();
      _offlineIdleTimer = Timer(const Duration(minutes: 4), () {
        if (_offlineSyncRunning) return;
        _offlineImap?.disconnect();
        _offlineImap = null;
      });
      _log('[mail] saved $saved messages for offline reading');
    }
  }

  Future<MimeMessage?> fetchFullMessage(
    int uid, {
    MailFolder folder = MailFolder.inbox,
  }) async {
    // A mail never changes under its UID, so the offline copy is as good as
    // the server's — and opens without a connection. Inbox only: UIDs are per
    // mailbox, so a Sent or Trash UID can name an unrelated inbox mail.
    if (folder == MailFolder.inbox) {
      final cached = await _offlineBody(uid);
      if (cached != null) return cached;
    }
    try {
      return await _run(
        'open ${folder.name} $uid',
        (c) async {
          if (await _selectOn(c, folder) == null) return null;
          final result = await c.uidFetchMessage(
            uid,
            'BODY[]',
            responseTimeout: _commandTimeout,
          );
          return result.messages.isNotEmpty ? result.messages.first : null;
        },
        timeout: _fetchTimeout,
        idempotent: true,
      );
    } catch (e) {
      _log('[mail] error: $e');
      _noteFailure(e);
      return null;
    }
  }

  /// The saved full mail for [uid] when it is the inbox message listed under
  /// that UID. The Message-ID comparison guards the narrow windows where the
  /// saved bodies trail a UIDVALIDITY or account change.
  Future<MimeMessage?> _offlineBody(int uid) async {
    final listed = _inbox.where((m) => m.uid == uid).firstOrNull;
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
  /// connection of its own with each folder EXAMINEd read-only: a lookup
  /// shouldn't wait behind the list's ops, and BODY.PEEK leaves the other
  /// mails' read state alone.
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
      final generation = _generation;
      // Whole-call: a dead socket that was never closed would otherwise hang
      // a command forever — and every later lookup queued behind it.
      final watch = Stopwatch()..start();
      final thread = await _lookUpThread(
        opened,
        folder,
      ).timeout(const Duration(seconds: 25));
      _threadImapUsed = DateTime.now();
      _log(
        '[mail] conversation: ${thread?.length ?? 0} mails '
        'in ${watch.elapsedMilliseconds} ms',
      );
      if (thread == null || generation != _generation) return null;
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
    final fresh = used != null && DateTime.now().difference(used).inMinutes < 4;
    if (current != null && current.isConnected && fresh) return current;
    current?.disconnect();
    _threadImap = null;
    final username = await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return null;
    final imap = ImapClient(isLogEnabled: false);
    await imap.connectToServer(
      _imapHost,
      _imapPort,
      isSecure: true,
      timeout: const Duration(seconds: 10),
    );
    await imap.login(username, password);
    _threadImap = imap;
    return imap;
  }

  Future<List<int>> _searchThread(ImapClient imap, MimeMessage opened) async {
    final id = messageIdOf(opened);
    final parents = parentIdsOf(opened);
    final subject = subjectSearchText(opened.decodeSubject());
    final criteria = threadSearchCriteria(
      messageId: id,
      parentIds: parents,
      subjectText: subject,
    );
    if (criteria == null) return const [];
    try {
      final result = await imap.uidSearchMessages(
        searchCriteria: criteria,
        responseTimeout: _threadResponseTimeout,
      );
      return result.matchingSequence?.toList() ?? const [];
    } on ImapException catch (e) {
      // A server that can't search headers still finds the subject.
      _log('[mail] header search refused ($e) — searching the subject only');
      final subjectOnly = threadSearchCriteria(
        messageId: id,
        parentIds: parents,
        subjectText: subject,
        headers: false,
      );
      if (subjectOnly == null) return const [];
      final result = await imap.uidSearchMessages(
        searchCriteria: subjectOnly,
        responseTimeout: _threadResponseTimeout,
      );
      return result.matchingSequence?.toList() ?? const [];
    }
  }

  Future<List<ThreadMessage>?> _lookUpThread(
    MimeMessage opened,
    MailFolder folder,
  ) async {
    final imap = await _threadClient();
    if (imap == null) return null;
    final sent = await _resolveSentMailbox(imap);
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
    final members = conversationOf(ThreadCandidate.of(opened, seedKey), [
      for (final e in found.entries) ThreadCandidate.of(e.value.$2, e.key),
    ]);
    // The same mail can sit in both folders (sent to oneself, a list
    // echoing it back): one card — the opened copy, else the inbox's.
    int rank(ThreadCandidate c) =>
        c.key == seedKey ? 0 : (found[c.key]?.$1 == MailFolder.inbox ? 1 : 2);
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
        keep = [...keep.skip(1), unique.firstWhere((m) => m.key == seedKey)]
          ..sort(
            (a, b) => (a.date ?? DateTime(0)).compareTo(b.date ?? DateTime(0)),
          );
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
  Future<void> sendEmail(
    String to,
    String subject,
    String body, {
    String? from,
    List<MailAttachmentData> attachments = const [],
    String? inReplyTo,
    List<String> references = const [],
  }) async {
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
        'From field (you can see it in webmail under Sent).',
      );
    }
    if (isCampusIdAddress(fromEmail, username)) {
      throw Exception(
        '$fromEmail is your Campus ID, not a real mailbox — the server '
        'accepts mail from it and then silently drops it. Use your real '
        'address (your.name@smail.th-koeln.de).',
      );
    }
    if (isRoleAddress(fromEmail)) {
      throw Exception(
        '$fromEmail is a system address, not yours. Use your real '
        'address (your.name@smail.th-koeln.de).',
      );
    }
    if (from != null) await setAccountEmail(from);

    _log('[mail] sending email to $to (from $fromEmail)');
    // Debug logging echoes every line sent — for a mail with attachments
    // that's megabytes of base64 in the console.
    final smtp = SmtpClient(
      'fh-koeln.de',
      isLogEnabled: kDebugMode && attachments.isEmpty,
    );
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
          throw Exception(
            mailTooBigMessage(
              sizes.fold(0, (a, b) => a + b),
              attachmentAllowance(
                limit!,
                bodyLength: body.length,
                count: attachments.length,
              ),
            ),
          );
        }
        // The timeout covers the whole upload. Fixed at 30 s, a few MB on a
        // weak uplink would be reported as failed while the server may
        // already have queued the mail — and the retry sends it twice. So
        // it only guards against a stall: at least 32 KB/s.
        sendTimeout =
            _smtpResponseTimeout +
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
      applyReplyHeaders(message, inReplyTo: inReplyTo, references: references);
      if (estimatedSize != null) {
        _log(
          '[mail] sending ${attachments.length} attachment(s), '
          '~$estimatedSize bytes',
        );
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
    // would never reach an account check further down — and a previous
    // account's real address passes both validity checks here, which would
    // make the new user compose with the old user's From.
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
      final official = acceptSpacesEmail(
        spaces?.email,
        spaces?.username,
        username,
      );
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
    try {
      receivedHeaders.addAll(
        await _run('received headers', _inboxReceivedHeaders, idempotent: true),
      );
    } catch (e) {
      _log('[mail] received-header lookup failed: $e');
    }
    if (_folders[MailFolder.sent]!.messages.isEmpty) {
      await refreshFolder(MailFolder.sent);
    }
    for (final m in _folders[MailFolder.sent]!.messages) {
      sentFrom.addAll(m.from ?? const []);
    }

    final email = pickAccountEmail(
      receivedHeaders: receivedHeaders,
      sentFrom: sentFrom,
      username: username,
    );
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
    String? email,
    String? spacesUsername,
    String? loginUsername,
  ) {
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

    bool isSmail(String email) => email.split('@').last == 'smail.th-koeln.de';

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
        e.contains('@') && !isCampusIdAddress(e, username) && !isRoleAddress(e);

    // A server only writes `for <addr>` when that copy has exactly one
    // envelope recipient, so it names this mailbox even for Bcc'd mass
    // mail. The final hop names the internal Campus-ID mailbox
    // (campusid@imap.intranet.fh-koeln.de), which isCampusIdAddress drops.
    final receivedAddresses = receivedHeaders
        .expand((h) => _receivedForPattern.allMatches(h))
        .map((m) => m.group(1)!.trim().toLowerCase())
        .where((e) => isThKoeln(e) && isOwnCandidate(e))
        .toList();
    final receivedPick =
        mostFrequent(receivedAddresses.where(isSmail)) ??
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
    caseSensitive: false,
  );

  /// Raw `Received:` header values of the newest inbox messages. Header-only
  /// fetch with PEEK, so nothing is marked read and no bodies are loaded.
  Future<List<String>> _inboxReceivedHeaders(ImapClient c) async {
    final inbox = await c.selectInbox();
    final range = newestRange(inbox.messagesExists, count: 30);
    if (range == null) return const [];
    final result = await c.fetchMessages(
      MessageSequence.fromRange(range.$1, range.$2),
      '(BODY.PEEK[HEADER.FIELDS (RECEIVED)])',
      responseTimeout: const Duration(seconds: 30),
    );
    return [
      for (final m in result.messages)
        for (final h in m.getHeader('received') ?? const <Header>[])
          if (h.value != null) h.value!,
    ];
  }

  /// How long an APPEND of a mail of [size] bytes may take: 30 s plus 1 s
  /// per 32 KB, the same floor as the SMTP upload.
  static Duration _appendTimeout(int? size) =>
      _smtpResponseTimeout + Duration(seconds: (size ?? 0) ~/ (32 * 1024));

  // Webmail parity: SMTP delivery alone stores no copy — webmail APPENDs one
  // to the Sent folder over IMAP. Failures here must not fail the send.
  //
  // Bounded like the SMTP upload — 30 s plus 1 s per 32 KB of [size] — so a
  // connection that died without the server closing it can't hang the send.
  // Never retried: the copy may have landed before the connection failed.
  Future<void> _appendToSent(MimeMessage message, {int? size}) async {
    try {
      final sent = await _run('append sent', (c) async {
        final box = await _resolveSentMailbox(c);
        if (box == null) return null;
        await c.appendMessage(message, targetMailbox: box, flags: [r'\Seen']);
        return box;
      }, timeout: _appendTimeout(size));
      if (sent == null) return;
      _log('[mail] appended sent copy to ${sent.path}');
      // The reply's Sent copy now belongs to a conversation looked up
      // before — attachment mails append after compose has closed.
      _threadCache.clear();
      unawaited(refreshFolder(MailFolder.sent, force: true));
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

  /// Appends a draft to the Drafts folder over IMAP, the way [_appendToSent]
  /// stores a sent copy. Returns false when it didn't land — also after the
  /// size-scaled timeout — so compose can stay open rather than lose what
  /// was typed.
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
      // Before the op: accountEmail runs ops of its own.
      final sender = from.contains('@')
          ? from.trim()
          : (await accountEmail() ?? from);
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
      applyReplyHeaders(message, inReplyTo: inReplyTo, references: references);
      final size = attachments.isEmpty
          ? null
          : estimateEncodedSize(
              body.length,
              attachments.map((a) => a.bytes.length),
            );
      final drafts = await _run('save draft', (c) async {
        final box = await _resolveDraftsMailbox(c);
        if (box == null) return null;
        await c.appendMessage(
          message,
          targetMailbox: box,
          flags: [r'\Draft', r'\Seen'],
        );
        return box;
      }, timeout: _appendTimeout(size));
      if (drafts == null) return false;
      _log('[mail] saved draft to ${drafts.path}');
      unawaited(refreshFolder(MailFolder.drafts, force: true));
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
    try {
      final done = await _run('discard draft', (c) async {
        if (await _selectOn(c, MailFolder.drafts) == null) return false;
        final seq = MessageSequence.fromId(uid, isUid: true);
        await c.uidMarkDeleted(seq);
        try {
          await c.uidExpunge(seq);
        } on ImapException {
          // No UIDPLUS: expunge the folder — only \Deleted drafts go.
          await c.expunge();
        }
        return true;
      }, idempotent: true);
      if (!done) return false;
      _removeFromList(MailFolder.drafts, uid);
      _log('[mail] discarded draft $uid');
      return true;
    } catch (e) {
      _log('[mail] discardDraft error: $e');
      return false;
    }
  }

  void _removeFromList(MailFolder folder, int uid) {
    final s = _folders[folder]!;
    s.messages = [
      for (final m in s.messages)
        if (m.uid != uid) m,
    ];
    if (folder == MailFolder.inbox) {
      _unreadController.add(unreadCount);
      unawaited(_updateOfflineCopy());
    } else {
      unawaited(_saveFolderIndex(folder));
    }
    notifyListeners();
  }

  // Moves message to Trash instead of permanent expunge. Never retried: a
  // MOVE whose answer was lost may have happened.
  Future<void> deleteMessage(
    MimeMessage message, {
    MailFolder folder = MailFolder.inbox,
  }) async {
    final uid = message.uid;
    if (uid == null) return;
    try {
      final done = await _run('delete', (c) async {
        // Resolve trash first — it may LIST/CREATE mailboxes — then select
        // the source folder so the UID operations run against it.
        final trash = await _resolveTrashMailbox(c);
        if (await _selectOn(c, folder) == null) return false;
        final seq = MessageSequence.fromId(uid, isUid: true);
        if (trash == null) {
          _log('[mail] deleteMessage: no trash folder — expunging instead');
          await c.uidMarkDeleted(seq);
          await c.uidExpunge(seq);
        } else {
          try {
            await c.uidMove(seq, targetMailbox: trash);
            _log('[mail] moved $uid to trash via MOVE');
          } on ImapException {
            await c.uidCopy(seq, targetMailbox: trash);
            await c.uidMarkDeleted(seq);
            await c.uidExpunge(seq);
            _log('[mail] moved $uid to trash via COPY+DELETE');
          }
        }
        return true;
      });
      if (!done) return;
      _removeFromList(folder, uid);
      // Refresh trash in background so the deleted message appears there.
      unawaited(refreshFolder(MailFolder.trash, force: true));
    } catch (e) {
      _log('[mail] deleteMessage error: $e');
    }
  }

  Future<void> markAsRead(
    MimeMessage message, {
    MailFolder folder = MailFolder.inbox,
  }) async {
    if (message.uid == null || message.isSeen) return;
    await _setSeen(message, folder, true);
  }

  Future<void> markAsUnread(
    MimeMessage message, {
    MailFolder folder = MailFolder.inbox,
  }) async {
    if (message.uid == null || !message.isSeen) return;
    await _setSeen(message, folder, false);
  }

  Future<void> _setSeen(
    MimeMessage message,
    MailFolder folder,
    bool seen,
  ) async {
    final uid = message.uid!;
    try {
      final done = await _run(seen ? 'mark read' : 'mark unread', (c) async {
        if (await _selectOn(c, folder) == null) return false;
        final seq = MessageSequence.fromId(uid, isUid: true);
        if (seen) {
          await c.uidMarkSeen(seq);
        } else {
          await c.uidMarkUnseen(seq);
        }
        return true;
      }, idempotent: true);
      if (!done) return;
      // The object the caller holds, and the listed one — a fresh list may
      // have replaced it meanwhile.
      message.isSeen = seen;
      for (final m in _folders[folder]!.messages) {
        if (m.uid == uid) m.isSeen = seen;
      }
      if (folder == MailFolder.inbox) {
        _unreadController.add(unreadCount);
        unawaited(_updateOfflineCopy());
      } else {
        unawaited(_saveFolderIndex(folder));
      }
      notifyListeners();
    } catch (e) {
      _log('[mail] error: $e');
    }
  }

  // Finds the Trash mailbox by \Trash flag first, then common names. Caches result.
  Future<Mailbox?> _resolveTrashMailbox(ImapClient c) async {
    if (_trashMailbox != null) return _trashMailbox;
    final mailboxes = await c.listMailboxes();

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
      'Trash',
      'Papierkorb',
      'Gelöscht',
      'Deleted',
      'Deleted Items',
      'Deleted Messages',
      'INBOX.Trash',
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
    _log(
      '[mail] no trash folder found (available: '
      '${mailboxes.map((m) => m.name).join(', ')}), creating "Trash"',
    );
    try {
      _trashMailbox = await c.createMailbox('Trash');
      _log('[mail] created trash folder: ${_trashMailbox!.path}');
    } on ImapException catch (e) {
      _log('[mail] could not create trash folder: $e');
    }
    return _trashMailbox;
  }

  // Moves a message from Trash back to Inbox. Never retried, like delete.
  Future<void> restoreFromTrash(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null) return;
    try {
      final done = await _run('restore', (c) async {
        final trash = await _resolveTrashMailbox(c);
        if (trash == null) {
          _log('[mail] restoreFromTrash: no trash folder found');
          return false;
        }
        await c.selectMailbox(trash);
        final seq = MessageSequence.fromId(uid, isUid: true);
        try {
          await c.uidMove(seq, targetMailboxPath: 'INBOX');
          _log('[mail] restored $uid from trash via MOVE');
        } on ImapException {
          await c.uidCopy(seq, targetMailboxPath: 'INBOX');
          await c.uidMarkDeleted(seq);
          await c.uidExpunge(seq);
          _log('[mail] restored $uid from trash via COPY+DELETE');
        }
        return true;
      });
      if (!done) return;
      _removeFromList(MailFolder.trash, uid);
      unawaited(refreshFolder(MailFolder.inbox, force: true));
    } catch (e) {
      _log('[mail] restoreFromTrash error: $e');
    }
  }

  // Finds a special-use mailbox by its IMAP flag first, then common names.
  // Unlike trash, sent/drafts folders are never created if missing.
  Future<Mailbox?> _resolveSpecialMailbox(
    ImapClient c, {
    required MailboxFlag flag,
    required List<String> nameCandidates,
    required String label,
  }) async {
    final mailboxes = await c.listMailboxes();

    try {
      final mb = mailboxes.firstWhere((mb) => mb.flags.contains(flag));
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

    _log(
      '[mail] no $label folder found (available: '
      '${mailboxes.map((m) => m.name).join(', ')})',
    );
    return null;
  }

  /// Lists on [c] — the main connection's op or the conversation lookup's
  /// own connection.
  Future<Mailbox?> _resolveSentMailbox(ImapClient c) async {
    _sentMailbox ??= await _resolveSpecialMailbox(
      c,
      flag: MailboxFlag.sent,
      nameCandidates: const [
        'Sent',
        'Sent Items',
        'Sent Messages',
        'Gesendet',
        'Gesendete Elemente',
        'Gesendete Objekte',
        'INBOX.Sent',
      ],
      label: 'sent',
    );
    return _sentMailbox;
  }

  Future<Mailbox?> _resolveDraftsMailbox(ImapClient c) async {
    _draftsMailbox ??= await _resolveSpecialMailbox(
      c,
      flag: MailboxFlag.drafts,
      nameCandidates: const ['Drafts', 'Draft', 'Entwürfe', 'INBOX.Drafts'],
      label: 'drafts',
    );
    return _draftsMailbox;
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _idleRearmTimer?.cancel();
    _pollTimer?.cancel();
    _eventTimer?.cancel();
    _offlineIdleTimer?.cancel();
    unawaited(_events?.cancel());
    _session.dispose();
    _offlineImap?.disconnect();
    _threadImap?.disconnect();
    _unreadController.close();
    super.dispose();
  }
}
