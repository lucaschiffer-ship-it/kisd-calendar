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
  String? _connectionError;
  List<MimeMessage> _messages = [];
  String? _cachedUsername;

  final _unreadController = StreamController<int>.broadcast();

  bool get isConnected => _isConnected;
  bool get isConnecting => _isConnecting;
  bool get isFetching => _isFetching;
  String? get connectionError => _connectionError;
  List<MimeMessage> get messages => List.unmodifiable(_messages);
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

  Future<void> deleteMessage(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      await _imap!.selectInbox();
      final seq = MessageSequence.fromId(uid, isUid: true);
      await _imap!.uidMarkDeleted(seq);
      await _imap!.uidExpunge(seq);
      _messages.removeWhere((m) => m.uid == uid);
      _unreadController.add(unreadCount);
      notifyListeners();
    } catch (e) {
      print('[mail] error: $e');
    }
  }

  Future<void> markAsRead(MimeMessage message) async {
    final uid = message.uid;
    if (uid == null || message.isSeen) return;
    final ok = await _ensureConnected();
    if (!ok) return;
    try {
      await _imap!.uidMarkSeen(MessageSequence.fromId(uid, isUid: true));
      final idx = _messages.indexWhere((m) => m.uid == uid);
      if (idx >= 0) _messages[idx].isSeen = true;
      _unreadController.add(unreadCount);
      notifyListeners();
    } catch (e) {
      print('[mail] error: $e');
    }
  }

  @override
  void dispose() {
    _imap?.disconnect();
    _unreadController.close();
    super.dispose();
  }
}
