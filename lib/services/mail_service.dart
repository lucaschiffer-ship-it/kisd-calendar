import 'dart:async';

import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class MailService extends ChangeNotifier {
  static const _imapHost = 'imap.intranet.fh-koeln.de';
  static const _imapPort = 993;
  static const _smtpHost = 'smtp.intranet.fh-koeln.de';
  static const _smtpPort = 587;

  final _storage = const FlutterSecureStorage();

  ImapClient? _imap;
  bool _isConnected = false;
  bool _isConnecting = false;
  bool _isFetching = false;
  bool _isFetchingTrash = false;
  String? _connectionError;
  List<MimeMessage> _messages = [];
  List<MimeMessage> _trashedMessages = [];
  String? _cachedUsername;
  Mailbox? _trashMailbox;

  final _unreadController = StreamController<int>.broadcast();

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  bool get isFetching => _isFetching;
  bool get isFetchingTrash => _isFetchingTrash;
  String? get connectionError => _connectionError;
  List<MimeMessage> get messages => List.unmodifiable(_messages);
  List<MimeMessage> get trashedMessages => List.unmodifiable(_trashedMessages);
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

      print('[mail] connecting to $_imapHost...');
      _imap?.disconnect();
      _imap = ImapClient(isLogEnabled: false);
      await _imap!.connectToServer(_imapHost, _imapPort, isSecure: true);
      await _imap!.login(username, password);
      _isConnected = true;
      _connectionError = null;
      print('[mail] connected — fetching inbox');
      return true;
    } catch (e) {
      print('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      _connectionError = 'Could not connect: $e';
      return false;
    }
  }

  Future<void> reloadInbox() async {
    print('[mail] manual reload triggered');
    await fetchInbox();
    print('[mail] fetched ${_messages.length} messages after reload');
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
      print('[mail] fetched ${_messages.length} messages ($unread unread)');
      _unreadController.add(unread);
    } catch (e) {
      print('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
    } finally {
      _isFetching = false;
      notifyListeners();
    }
    return _messages;
  }

  Future<MimeMessage?> fetchFullMessage(int uid) async {
    final ok = await _ensureConnected();
    if (!ok) return null;
    try {
      await _imap!.selectInbox();
      final result = await _imap!.uidFetchMessage(uid, 'BODY[]');
      return result.messages.isNotEmpty ? result.messages.first : null;
    } catch (e) {
      print('[mail] error: $e');
      _isConnected = false;
      _imap?.disconnect();
      _imap = null;
      return null;
    }
  }

  Future<void> sendEmail(String to, String subject, String body) async {
    final username =
        _cachedUsername ?? await _storage.read(key: 'kisd_username');
    final password = await _storage.read(key: 'kisd_password');
    if (username == null || password == null) return;

    print('[mail] sending email to $to');
    final smtp = SmtpClient('fh-koeln.de', isLogEnabled: false);
    try {
      await smtp.connectToServer(_smtpHost, _smtpPort, isSecure: false);
      await smtp.ehlo();
      await smtp.startTls();
      await smtp.authenticate(username, password);
      final message = MessageBuilder.buildSimpleTextMessage(
        MailAddress(null, username),
        [MailAddress(null, to)],
        body,
        subject: subject,
      );
      await smtp.sendMessage(message);
      print('[mail] email sent');
    } catch (e) {
      print('[mail] error: $e');
      rethrow;
    } finally {
      await smtp.quit();
    }
  }

  // Moves message to Trash instead of permanent expunge.
  Future<void> deleteMessage(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      await _imap!.selectInbox();
      final trash = await _resolveTrashMailbox();
      if (trash == null) {
        print('[mail] deleteMessage: no trash folder — expunging instead');
        final seq = MessageSequence.fromId(uid, isUid: true);
        await _imap!.uidMarkDeleted(seq);
        await _imap!.uidExpunge(seq);
      } else {
        final seq = MessageSequence.fromId(uid, isUid: true);
        try {
          await _imap!.uidMove(seq, targetMailbox: trash);
          print('[mail] moved $uid to trash via MOVE');
        } catch (_) {
          await _imap!.uidCopy(seq, targetMailbox: trash);
          await _imap!.uidMarkDeleted(seq);
          await _imap!.uidExpunge(seq);
          print('[mail] moved $uid to trash via COPY+DELETE');
        }
      }
      _messages.removeWhere((m) => m.uid == uid);
      _unreadController.add(unreadCount);
      notifyListeners();
      // Refresh trash in background so the deleted message appears immediately.
      unawaited(fetchTrash());
    } catch (e) {
      print('[mail] deleteMessage error: $e');
    }
  }

  Future<void> markAsRead(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null || message.isSeen) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      await _imap!.selectInbox();
      await _imap!.uidMarkSeen(MessageSequence.fromId(uid, isUid: true));
      final idx = _messages.indexWhere((m) => m.uid == uid);
      if (idx >= 0) _messages[idx].isSeen = true;
      final tIdx = _trashedMessages.indexWhere((m) => m.uid == uid);
      if (tIdx >= 0) _trashedMessages[tIdx].isSeen = true;
      _unreadController.add(unreadCount);
      notifyListeners();
    } catch (e) {
      print('[mail] error: $e');
    }
  }

  Future<void> markAsUnread(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null || !message.isSeen) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      await _imap!.selectInbox();
      await _imap!.uidMarkUnseen(MessageSequence.fromId(uid, isUid: true));
      final idx = _messages.indexWhere((m) => m.uid == uid);
      if (idx >= 0) _messages[idx].isSeen = false;
      final tIdx = _trashedMessages.indexWhere((m) => m.uid == uid);
      if (tIdx >= 0) _trashedMessages[tIdx].isSeen = false;
      _unreadController.add(unreadCount);
      notifyListeners();
    } catch (e) {
      print('[mail] error: $e');
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
        print('[mail] found trash folder by flag: ${_trashMailbox!.path}');
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
          print('[mail] found trash folder by name: ${_trashMailbox!.path}');
          return _trashMailbox;
        } on StateError {
          continue;
        }
      }

      // No matching folder — create one.
      print('[mail] no trash folder found (available: '
          '${mailboxes.map((m) => m.name).join(', ')}), creating "Trash"');
      _trashMailbox = await _imap!.createMailbox('Trash');
      print('[mail] created trash folder: ${_trashMailbox!.path}');
    } catch (e) {
      print('[mail] could not resolve trash folder: $e');
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
        print('[mail] restoreFromTrash: no trash folder found');
        return;
      }
      // Select inbox to get its Mailbox reference, then switch to trash to operate.
      final inboxMailbox = await _imap!.selectInbox();
      await _imap!.selectMailbox(trash);
      final seq = MessageSequence.fromId(uid, isUid: true);
      try {
        await _imap!.uidMove(seq, targetMailbox: inboxMailbox);
        print('[mail] restored $uid from trash via MOVE');
      } catch (_) {
        await _imap!.uidCopy(seq, targetMailbox: inboxMailbox);
        await _imap!.uidMarkDeleted(seq);
        await _imap!.uidExpunge(seq);
        print('[mail] restored $uid from trash via COPY+DELETE');
      }
      _trashedMessages.removeWhere((m) => m.uid == uid);
      notifyListeners();
    } catch (e) {
      print('[mail] restoreFromTrash error: $e');
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
        print('[mail] fetchTrash: no trash folder available');
      } else {
        await _imap!.selectMailbox(trash);
        final result = await _imap!.fetchRecentMessages(
          messageCount: limit,
          criteria: '(FLAGS ENVELOPE UID BODY.PEEK[TEXT]<0.500>)',
          responseTimeout: const Duration(seconds: 90),
        );
        _trashedMessages = result.messages.reversed.toList();
        print('[mail] fetched ${_trashedMessages.length} trashed messages');
      }
    } catch (e) {
      print('[mail] fetchTrash error: $e');
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

  @override
  void dispose() {
    _imap?.disconnect();
    _unreadController.close();
    super.dispose();
  }
}
