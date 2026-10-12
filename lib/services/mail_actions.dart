import 'package:enough_mail/enough_mail.dart';
import 'package:flutter/foundation.dart';

import 'mail_service.dart' show MailFolder;
import 'service_locator.dart';

/// The mail UI's optimistic layer over [MailService]'s mutations.
///
/// The service changes its lists only *after* the IMAP round-trip (0.5–2 s),
/// so a swipe used to leave the row unchanged for a beat. This hides a deleted
/// row and flips a read state immediately, then reconciles once the service
/// call completes — rolling back, with [onFailure], if the server never took
/// it. The service itself is untouched.
///
/// Calls per message are serialised: `markAsRead` / `markAsUnread` early-return
/// on the message's *current* `isSeen`, which only flips when a call lands, so
/// a quick read-then-unread run concurrently would lose the second call.
class MailActions extends ChangeNotifier {
  MailActions({this.onFailure});

  /// Shown to the user when an optimistic change had to be rolled back.
  void Function(String message)? onFailure;

  final _hidden = <String>{};
  final _seen = <String, bool>{};
  final _tails = <String, Future<void>>{};
  final _pending = <String, int>{};

  bool _disposed = false;

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }

  @override
  void notifyListeners() {
    // Service calls outlive the screen that started them.
    if (!_disposed) super.notifyListeners();
  }

  static String keyOf(MimeMessage m, MailFolder folder) =>
      '${folder.name}:${m.uid ?? identityHashCode(m)}';

  bool isHidden(MimeMessage m, MailFolder folder) =>
      _hidden.contains(keyOf(m, folder));

  /// The read state to *show*: the optimistic one while a change is in flight.
  bool isSeen(MimeMessage m, MailFolder folder) =>
      _seen[keyOf(m, folder)] ?? m.isSeen;

  void toggleSeen(MimeMessage m, MailFolder folder) =>
      setSeen(m, folder, !isSeen(m, folder));

  void setSeen(MimeMessage m, MailFolder folder, bool seen) {
    final key = keyOf(m, folder);
    if (isSeen(m, folder) == seen) return;
    _seen[key] = seen;
    notifyListeners();
    _enqueue(
      key,
      () => seen
          ? mailService.markAsRead(m, folder: folder)
          : mailService.markAsUnread(m, folder: folder),
      onIdle: () {
        // Every queued call has landed: the message's own flag is the truth.
        final wanted = _seen.remove(key);
        notifyListeners();
        if (wanted != null && m.isSeen != wanted) {
          onFailure?.call(
            wanted ? "Couldn't mark as read" : "Couldn't mark as unread",
          );
        }
      },
    );
  }

  /// Moves to Trash. The row disappears now; it comes back if the server
  /// didn't take the move.
  Future<void> delete(MimeMessage m, MailFolder folder) => _remove(
    m,
    folder,
    () => mailService.deleteMessage(m, folder: folder),
    "Couldn't delete the message",
  );

  Future<void> restore(MimeMessage m) => _remove(
    m,
    MailFolder.trash,
    () => mailService.restoreFromTrash(m),
    "Couldn't restore the message",
  );

  Future<void> _remove(
    MimeMessage m,
    MailFolder folder,
    Future<void> Function() op,
    String failure,
  ) {
    final key = keyOf(m, folder);
    _hidden.add(key);
    notifyListeners();
    return _enqueue(
      key,
      op,
      onIdle: () {
        final uid = m.uid;
        final stillThere =
            uid == null || _listFor(folder).any((x) => x.uid == uid);
        _hidden.remove(key);
        notifyListeners();
        if (stillThere) onFailure?.call(failure);
      },
    );
  }

  List<MimeMessage> _listFor(MailFolder folder) => switch (folder) {
    MailFolder.inbox => mailService.messages,
    MailFolder.trash => mailService.trashedMessages,
    MailFolder.sent => mailService.sentMessages,
    MailFolder.drafts => mailService.draftMessages,
  };

  Future<void> _enqueue(
    String key,
    Future<void> Function() op, {
    required VoidCallback onIdle,
  }) {
    _pending[key] = (_pending[key] ?? 0) + 1;
    final previous = _tails[key] ?? Future<void>.value();
    final next = previous.then((_) => op()).catchError((Object _) {});
    _tails[key] = next;
    return next.whenComplete(() {
      final left = (_pending[key] ?? 1) - 1;
      if (left > 0) {
        _pending[key] = left;
        return;
      }
      _pending.remove(key);
      _tails.remove(key);
      onIdle();
    });
  }
}
