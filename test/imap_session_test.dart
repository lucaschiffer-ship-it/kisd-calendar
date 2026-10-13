import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:kisd_calendar/services/imap_session.dart';

class FakeConnection {
  FakeConnection(this.id);
  final int id;
  bool alive = true;
  bool answersProbe = true;
  bool closed = false;
  int probes = 0;
}

/// A server NO/BAD: the connection is fine, the command wasn't.
class ServerNo implements Exception {}

void main() {
  late List<FakeConnection> opened;
  late DateTime now;

  ImapSession<FakeConnection> session({
    Future<bool> Function(FakeConnection)? prepare,
    void Function()? onDrained,
  }) => ImapSession<FakeConnection>(
    connect: () async {
      await Future<void>.delayed(const Duration(milliseconds: 5));
      final c = FakeConnection(opened.length + 1);
      opened.add(c);
      return c;
    },
    isAlive: (c) => c.alive && !c.closed,
    probe: (c) async {
      c.probes++;
      if (!c.answersProbe) await Completer<void>().future; // never answers
    },
    close: (c) => c.closed = true,
    prepare: prepare,
    onDrained: onDrained,
    probeTimeout: const Duration(milliseconds: 50),
    drainedDelay: const Duration(milliseconds: 20),
    clock: () => now,
  );

  setUp(() {
    opened = [];
    now = DateTime(2026, 10, 13, 12);
  });

  test('ops run one after another, never interleaved', () async {
    final s = session();
    final log = <String>[];
    Future<void> op(String name) => s.run(name, (_) async {
      log.add('$name start');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      log.add('$name end');
    });
    await Future.wait([op('inbox'), op('sent'), op('mark')]);
    expect(log, [
      'inbox start',
      'inbox end',
      'sent start',
      'sent end',
      'mark start',
      'mark end',
    ]);
  });

  test('callers arriving together share one login', () async {
    final s = session();
    await Future.wait([
      for (var i = 0; i < 4; i++) s.run('op $i', (c) async => c.id),
    ]);
    expect(opened, hasLength(1));
  });

  test('a timeout drops the connection; the next op gets a new one', () async {
    final s = session();
    await expectLater(
      s.run(
        'hangs',
        (_) => Completer<void>().future,
        timeout: const Duration(milliseconds: 30),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(opened.single.closed, isTrue);
    expect(await s.run('next', (c) async => c.id), 2);
  });

  test('a server NO keeps the connection', () async {
    final s = session();
    await expectLater(
      s.run('no', (_) async => throw ServerNo(), idempotent: true),
      throwsA(isA<ServerNo>()),
    );
    expect(opened.single.closed, isFalse);
    expect(await s.run('next', (c) async => c.id), 1);
  });

  test(
    'an idempotent op is retried once when the connection dies under it',
    () async {
      final s = session();
      var calls = 0;
      final id = await s.run('fetch', (c) async {
        calls++;
        if (calls == 1) {
          c.alive = false; // the socket closed mid-command
          throw StateError('socket closed');
        }
        return c.id;
      }, idempotent: true);
      expect(calls, 2);
      expect(id, 2);
    },
  );

  test('an APPEND or MOVE is not retried — it may have landed', () async {
    final s = session();
    var calls = 0;
    await expectLater(
      s.run('append', (c) async {
        calls++;
        c.alive = false;
        throw StateError('socket closed');
      }),
      throwsA(isA<StateError>()),
    );
    expect(calls, 1);
  });

  test(
    'a quiet connection is probed, and replaced when it does not answer',
    () async {
      final s = session();
      await s.run('first', (_) async {});
      now = now.add(const Duration(minutes: 5));
      opened.single.answersProbe = false; // went quiet without closing
      var ran = 0;
      final id = await s.run('after sleep', (c) async {
        ran++;
        return c.id;
      });
      expect(ran, 1, reason: 'the op itself ran once, on the new connection');
      expect(id, 2);
      expect(opened.first.closed, isTrue);
    },
  );

  test('a recently used connection is not probed', () async {
    final s = session();
    await s.run('first', (_) async {});
    now = now.add(const Duration(seconds: 30));
    await s.run('second', (_) async {});
    expect(opened.single.probes, 0);
  });

  test(
    'prepare runs before every op, and its answer counts as a probe',
    () async {
      var prepared = 0;
      final s = session(
        prepare: (_) async {
          prepared++;
          return true;
        },
      );
      await s.run('first', (_) async {});
      now = now.add(const Duration(minutes: 5));
      await s.run('second', (_) async {});
      expect(prepared, 2);
      expect(opened.single.probes, 0);
    },
  );

  test('a failing prepare replaces the connection before the op', () async {
    var first = true;
    final s = session(
      prepare: (_) async {
        if (first) {
          first = false;
          throw StateError('no answer to DONE');
        }
        return false;
      },
    );
    var calls = 0;
    final id = await s.run('append', (c) async {
      calls++;
      return c.id;
    });
    expect(calls, 1);
    expect(id, 2);
  });

  test('onDrained fires once the queue has been empty a moment', () async {
    var drained = 0;
    final s = session(onDrained: () => drained++);
    await s.run('a', (_) async {});
    final b = s.run('b', (_) async {});
    await b;
    expect(drained, 0);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(drained, 1);
  });

  test('a timer set up inside an op may run ops once the op is over', () async {
    final s = session();
    final later = Completer<int>();
    await s.run('arms a timer', (_) async {
      // Timers keep the zone they were made in — the op's.
      Timer(const Duration(milliseconds: 10), () {
        later.complete(s.run('from the timer', (c) async => c.id));
      });
    });
    expect(await later.future, 1);
  });

  test('after dispose, a queued op does not log in again', () async {
    final s = session();
    await s.run('a', (_) async {});
    s.dispose();
    await expectLater(
      s.run('late', (_) async {}),
      throwsA(isA<ConnectionDeadException>()),
    );
    expect(opened, hasLength(1));
  });
}
