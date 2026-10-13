import 'dart:async';

/// One mail server connection that commands take turns on.
///
/// enough_mail queues single commands, but nothing stops two callers from
/// interleaving their *sequences*: a `SELECT Sent` landing between the
/// inbox's `SELECT INBOX` and its `FETCH` fetched the wrong folder, and two
/// callers reconnecting at once killed each other's login. Here every [run]
/// is one whole operation — select, fetch, mark, move — and the next one
/// starts only when it is done. Because ops never overlap, the connection is
/// also only ever (re)built by one op at a time.
///
/// Generic over the connection so the tests can use a fake; the app uses an
/// enough_mail `ImapClient`.
class ImapSession<C extends Object> {
  ImapSession({
    required this.connect,
    required this.isAlive,
    required this.probe,
    required this.close,
    this.prepare,
    this.onDrained,
    this.probeAfter = const Duration(seconds: 60),
    this.probeTimeout = const Duration(seconds: 8),
    this.drainedDelay = const Duration(milliseconds: 1500),
    this.log,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Opens and logs in a new connection. Throws when that fails.
  final Future<C> Function() connect;

  /// False once the socket is known to be closed.
  final bool Function(C) isAlive;

  /// A cheap round trip (NOOP). A socket that went quiet without closing —
  /// the phone slept, the network changed — still reports itself alive.
  final Future<void> Function(C) probe;

  final void Function(C) close;

  /// Readies the connection for a command (ends IDLE). Returns true when
  /// that heard back from the server, which proves the connection alive.
  final Future<bool> Function(C)? prepare;

  /// Called once no op has been queued for [drainedDelay].
  final void Function()? onDrained;

  /// Unheard from this long, the connection is probed before the next op.
  final Duration probeAfter;
  final Duration probeTimeout;
  final Duration drainedDelay;
  final void Function(String)? log;
  final DateTime Function() _clock;

  C? _current;
  DateTime? _lastHeard;
  int _generation = 0;
  Future<void> _tail = Future.value();
  int _pending = 0;
  Timer? _drainedTimer;
  bool _disposed = false;

  static final _zoneKey = Object();

  /// The live connection, if any.
  C? get current => _current;

  /// Bumped each time a new connection replaces the old one.
  int get generation => _generation;

  /// True while an op runs or waits.
  bool get isBusy => _pending > 0;

  /// Runs [op] once every op queued before it is done.
  ///
  /// The whole op is bounded by [timeout]: a command the server never
  /// answers would otherwise hold up every op behind it. A timeout, or the
  /// connection closing under the op, drops the connection. A server's
  /// NO/BAD on a live connection keeps it.
  ///
  /// Before the op, a connection unheard from for [probeAfter] is probed,
  /// and replaced when it doesn't answer — nothing was sent for the op yet,
  /// so that is safe for any op. [idempotent] ops are also retried once on a
  /// fresh connection when it failed *under* them; the others (APPEND, MOVE)
  /// might have landed, so their error goes to the caller.
  ///
  /// Never call [run] from inside an op: it would wait for itself. Ops
  /// should return what they fetched rather than change shared state —
  /// after a timeout an op's future is abandoned, but its code may still be
  /// running.
  Future<T> run<T>(
    String label,
    Future<T> Function(C connection) op, {
    Duration timeout = const Duration(seconds: 45),
    bool idempotent = false,
  }) {
    assert(
      () {
        final op = Zone.current[_zoneKey];
        return op is! _Op || !identical(op.session, this) || !op.running;
      }(),
      'ImapSession.run("$label") awaited from inside an op — it would wait '
      'for itself',
    );
    _drainedTimer?.cancel();
    _pending++;
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return () async {
      await previous;
      try {
        return await _attempt(label, op, timeout, idempotent);
      } finally {
        _pending--;
        done.complete();
        if (_pending == 0 && onDrained != null && !_disposed) {
          _drainedTimer = Timer(drainedDelay, () {
            if (_pending == 0 && !_disposed) onDrained!();
          });
        }
      }
    }();
  }

  /// Closes the connection; the next op opens a new one.
  void drop() {
    final c = _current;
    if (c != null) _drop(c);
  }

  /// Drops the connection and stops the drained callback, for good.
  void dispose() {
    _disposed = true;
    _drainedTimer?.cancel();
    drop();
  }

  Future<T> _attempt<T>(
    String label,
    Future<T> Function(C) op,
    Duration timeout,
    bool idempotent,
  ) async {
    var retried = false;
    while (true) {
      final c = await _ready();
      if (!await _check(c)) {
        _drop(c);
        if (retried) {
          throw ConnectionDeadException(
            '$label: no answer on a new connection',
          );
        }
        retried = true;
        continue;
      }
      // A timer or listener the op sets up keeps its zone, so the marker
      // goes stale once the op is over: only a run *during* it is a cycle.
      final marker = _Op(this);
      try {
        final result = await runZoned(
          () => op(c),
          zoneValues: {_zoneKey: marker},
        ).timeout(timeout);
        _lastHeard = _clock();
        return result;
      } catch (e) {
        final dead = e is TimeoutException || !isAlive(c);
        if (!dead) {
          _lastHeard = _clock(); // the server answered, if only with NO
          rethrow;
        }
        _drop(c);
        if (retried || !idempotent) rethrow;
        retried = true;
        log?.call('[imap] $label: connection failed ($e) — retrying');
      } finally {
        marker.running = false;
      }
    }
  }

  Future<C> _ready() async {
    final c = _current;
    if (c != null && isAlive(c)) return c;
    if (c != null) _drop(c);
    // An op queued before an account switch must not log in again.
    if (_disposed) throw const ConnectionDeadException('session closed');
    final fresh = await connect();
    if (_disposed) {
      close(fresh);
      throw const ConnectionDeadException('session closed');
    }
    _current = fresh;
    _generation++;
    _lastHeard = _clock();
    return fresh;
  }

  /// Ends IDLE, and probes a connection that has been quiet. False when it
  /// didn't answer.
  Future<bool> _check(C c) async {
    try {
      final prep = prepare;
      if (prep != null && await prep(c).timeout(probeTimeout)) {
        _lastHeard = _clock();
        return true;
      }
      final heard = _lastHeard;
      if (heard != null && _clock().difference(heard) <= probeAfter) {
        return true;
      }
      await probe(c).timeout(probeTimeout);
      _lastHeard = _clock();
      return true;
    } catch (e) {
      log?.call('[imap] connection check failed ($e) — reconnecting');
      return false;
    }
  }

  void _drop(C c) {
    if (identical(_current, c)) {
      _current = null;
      _lastHeard = null;
    }
    try {
      close(c);
    } catch (_) {}
  }
}

/// Marks the zone an op runs in.
class _Op {
  _Op(this.session);
  final Object session;
  bool running = true;
}

/// A connection that didn't answer even after being replaced.
class ConnectionDeadException implements Exception {
  const ConnectionDeadException(this.reason);
  final String reason;
  @override
  String toString() => 'ConnectionDeadException: $reason';
}
