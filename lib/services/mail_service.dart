import 'dart:async';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Which IMAP folder a message lives in — used for folder-aware operations.
enum MailFolder { inbox, drafts, sent, trash }

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
    if (_isConnecting || _isConnected) return;
    _isConnecting = true;
    _connectionError = null;
    notifyListeners();

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
    if (_isConnected && _imap != null) return true;
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
      _imap = ImapClient(isLogEnabled: false);
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
      await _imap!.selectInbox();
      final result = await _imap!.fetchRecentMessages(
        messageCount: limit,
        criteria: '(FLAGS ENVELOPE UID BODY.PEEK[TEXT]<0.500>)',
        responseTimeout: const Duration(seconds: 90),
      );
      _messages = result.messages.reversed.toList();
      final unread = unreadCount;
      _log('[mail] fetched ${_messages.length} messages ($unread unread)');
      _unreadController.add(unread);
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

  Future<void> sendEmail(String to, String subject, String body,
      {String? from}) async {
    final username =
        _cachedUsername ?? await _storage.read(key: 'kisd_username');
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
    final smtp = SmtpClient('fh-koeln.de', isLogEnabled: kDebugMode);
    try {
      // enough_mail's SMTP commands await the server with no timeout of
      // their own — a stalled response would hang the send forever, with
      // the compose spinner stuck and no error shown.
      await smtp.connectToServer(_smtpHost, _smtpPort, isSecure: false);
      await smtp.ehlo().timeout(_smtpResponseTimeout);
      await smtp.startTls().timeout(_smtpResponseTimeout);
      await smtp.authenticate(username, password).timeout(_smtpResponseTimeout);
      final message = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, fromEmail),
        [MailAddress(null, to)],
        body,
        subject: subject,
      );
      final response =
          await smtp.sendMessage(message).timeout(_smtpResponseTimeout);
      // The acceptance line carries the server's queue ID — the proof the
      // message entered the mail system, and the handle Campus IT can trace.
      _log('[mail] smtp accepted: ${response.code} ${response.message}');
      await _appendToSent(message);
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

  /// The account's email address: the stored/confirmed one, else detected
  /// from mailbox data. Returns null when unknown — deliberately no guessing;
  /// a plausible-but-wrong sender is accepted by the relay and then dropped
  /// silently, which is worse than asking the user once.
  Future<String?> accountEmail() async {
    final username =
        _cachedUsername ?? await _storage.read(key: 'kisd_username');
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

    final sentFrom = <MailAddress>[];
    final inboxRecipients = <MailAddress>[];
    if (await _ensureConnected()) {
      try {
        if (_sentMessages.isEmpty) await fetchSent(limit: 10);
        for (final m in _sentMessages) {
          sentFrom.addAll(m.from ?? const []);
        }
        if (_messages.isEmpty) await fetchInbox();
        for (final m in _messages) {
          inboxRecipients
            ..addAll(m.to ?? const [])
            ..addAll(m.cc ?? const []);
        }
      } catch (e) {
        _log('[mail] account email lookup failed: $e');
      }
    }

    final email = pickAccountEmail(
        sentFrom: sentFrom,
        inboxRecipients: inboxRecipients,
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

  /// Picks the account's own address from mailbox data. Campus-ID identities
  /// and role addresses (noreply@… etc.) are excluded everywhere — mass
  /// mails are often addressed To: a no-reply alias with the students in
  /// Bcc, so those dominate inbox recipients without being anyone's
  /// identity. Priority: th-koeln From of sent messages, then smail (the
  /// student domain) inbox recipients, then other th-koeln recipients, then
  /// any remaining sent From as a last resort.
  @visibleForTesting
  static String? pickAccountEmail({
    required List<MailAddress> sentFrom,
    required List<MailAddress> inboxRecipients,
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

    final sentAddresses = sentFrom
        .map((a) => a.email.trim().toLowerCase())
        .where((e) =>
            e.contains('@') &&
            !isCampusIdAddress(e, username) &&
            !isRoleAddress(e))
        .toList();
    final sentPick = mostFrequent(sentAddresses.where(isThKoeln));
    if (sentPick != null) return sentPick;

    final recipientAddresses = inboxRecipients
        .map((a) => a.email.trim().toLowerCase())
        .where((e) =>
            e.contains('@') &&
            isThKoeln(e) &&
            !isCampusIdAddress(e, username) &&
            !isRoleAddress(e))
        .toList();
    final recipientPick = mostFrequent(recipientAddresses.where(isSmail)) ??
        mostFrequent(recipientAddresses);
    if (recipientPick != null) return recipientPick;

    // Last resort: a foreign sent address — only when the mailbox offers no
    // th-koeln evidence at all (already campus-id filtered above).
    return mostFrequent(sentAddresses);
  }

  // Webmail parity: SMTP delivery alone stores no copy — webmail APPENDs one
  // to the Sent folder over IMAP. Failures here must not fail the send.
  Future<void> _appendToSent(MimeMessage message) async {
    try {
      if (!await _ensureConnected()) return;
      final sent = await _resolveSentMailbox();
      if (sent == null) return;
      await _imap!.appendMessage(message,
          targetMailbox: sent, flags: [r'\Seen']);
      _log('[mail] appended sent copy to ${sent.path}');
    } catch (e) {
      _log('[mail] could not append to sent folder: $e');
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
  }) async {
    try {
      final mailboxes = await _imap!.listMailboxes();

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

  Future<Mailbox?> _resolveSentMailbox() async {
    _sentMailbox ??= await _resolveSpecialMailbox(
      flag: MailboxFlag.sent,
      nameCandidates: const [
        'Sent', 'Sent Items', 'Sent Messages', 'Gesendet',
        'Gesendete Elemente', 'Gesendete Objekte', 'INBOX.Sent',
      ],
      label: 'sent',
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
    _imap?.disconnect();
    _unreadController.close();
    super.dispose();
  }
}
