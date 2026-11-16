import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';

import 'fake_stream_server.dart';

/// The live line to ZestSSH Cloud (3.0) against a stand-in for its
/// server: it signs in with its first message and never in the address,
/// passes on what the server says once signed in, and answers each of the
/// server's close codes: a renewal with a fresh token, a refusal with one
/// more try, a sign-out by stopping for good, a full account by waiting.
void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would refuse the local line.

  late FakeStreamServer server;
  late List<bool> tokenAsks;
  late List<OrchardStreamEvent> events;
  late String? bearer;
  final streams = <OrchardStream>[];

  setUp(() async {
    server = await FakeStreamServer.start();
    tokenAsks = [];
    events = [];
    bearer = 'token-1';
  });

  tearDown(() async {
    for (final s in streams) {
      await s.dispose();
    }
    streams.clear();
    await server.close();
  });

  /// A line whose waits are short, except after a refusal or a full
  /// account, or after a drop when [droppedWait] says otherwise.
  OrchardStream line({Duration droppedWait = const Duration(milliseconds: 10)}) {
    final s = OrchardStream(
      url: server.url,
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async {
        tokenAsks.add(fresh);
        return bearer;
      },
      session: () => 'device-1',
      retryDelay: (why, attempt) => switch (why) {
        StreamRetry.refused || StreamRetry.busy => const Duration(minutes: 10),
        StreamRetry.dropped => droppedWait,
        _ => const Duration(milliseconds: 10),
      },
    );
    s.events.listen(events.add);
    streams.add(s);
    return s;
  }

  List<StreamConnected> connects() => events.whereType<StreamConnected>().toList();

  test('its address is the API base with /stream, over TLS', () {
    expect(OrchardStream.urlFor('https://api.zestssh.com/v1').toString(),
        'wss://api.zestssh.com/v1/stream');
    expect(OrchardStream.urlFor('http://127.0.0.1:39200/v1/').toString(),
        'ws://127.0.0.1:39200/v1/stream');
  });

  test('signs in with its first message, never in the address', () async {
    line().start();
    final c = await server.next();
    expect(await c.signIn, {'type': 'auth', 'token': 'token-1', 'session': 'device-1'});
    expect(c.uri.path, '/v1/stream');
    expect(c.uri.query, isEmpty);
    expect(tokenAsks, [false]);
  });

  test('once signed in, passes on what the server says and skips the rest', () async {
    final s = line()..start();
    final c = await server.next();
    await c.signIn;
    // Nothing counts before the server says the sign-in is good.
    c.send({'type': 'crate', 'crate_id': 'c-0', 'revision': 1});
    c.ready();
    await eventually(() => connects().isNotEmpty);
    expect(connects().single.reconnected, isFalse);
    expect(s.isConnected, isTrue);

    c.send({'type': 'crate', 'crate_id': 'c-1', 'revision': 7});
    c.send('not json');
    c.send({'type': 'crate', 'crate_id': 'c-1', 'revision': '8'});
    c.send({'type': 'a-message-from-a-newer-server'});
    c.send({'type': 'orchards'});
    await eventually(() => events.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(3));
    final changed = events[1] as CrateChanged;
    expect(changed.crateId, 'c-1');
    expect(changed.revision, 7);
    expect(events[2], isA<OrchardsChanged>());
  });

  test('word that a device approval moved on: a request id, nothing else', () async {
    line().start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    c.send({'type': 'device-approval', 'id': 42});
    c.send({'type': 'device-approval', 'id': ''});
    c.send({'type': 'device-approval', 'id': 'x' * 65});
    c.send({'type': 'device-approval', 'id': 'req-7'});
    await eventually(() => events.length >= 2);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(2));
    expect((events[1] as DeviceApprovalMoved).id, 'req-7');
  });

  test('word that a request for access moved, or an invitation to a shared session: that it did, nothing else',
      () async {
    line().start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    // Whatever else the message carries is not read.
    c.send({'type': 'access', 'orchard_id': 'o-1', 'request': 'r-1'});
    c.send({'type': 'share'});
    c.send({'type': 'Access'});
    await eventually(() => events.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(3));
    expect(events[1], isA<AccessRequestsChanged>());
    expect(events[2], isA<ShareInvitesChanged>());
  });

  test('word that a device request moved: that it did, nothing else', () async {
    line().start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    c.send({'type': 'device', 'orchard_id': 'o-1', 'device': 'AAAA'});
    c.send({'type': 'devices'});
    c.send({'type': 'Device'});
    c.send({'type': 'device'});
    await eventually(() => events.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(3));
    expect(events[1], isA<DeviceRequestsChanged>());
    expect(events[2], isA<DeviceRequestsChanged>());
  });

  test('word that the account\'s security changed (3.3): that it did, nothing else', () async {
    line().start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    c.send({'type': 'security', 'recovery': 'x'});
    c.send({'type': 'Security'});
    c.send({'type': 'security'});
    await eventually(() => events.length >= 3);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(events, hasLength(3));
    expect(events[1], isA<SecurityChanged>());
    expect(events[2], isA<SecurityChanged>());
  });

  test('a renewal opens a new line with a fresh token', () async {
    line().start();
    final first = await server.next();
    await first.signIn;
    first.ready();
    await eventually(() => connects().length == 1);
    await first.close(OrchardStream.closeRenew, 'renew');

    final second = await server.next();
    await second.signIn;
    expect(tokenAsks, [false, true]);
    second.ready();
    await eventually(() => connects().length == 2);
    expect(connects().last.reconnected, isTrue, reason: 'changes may have been missed');
  });

  test('a dropped line comes back', () async {
    line().start();
    final first = await server.next();
    await first.signIn;
    first.ready();
    await eventually(() => connects().length == 1);
    await first.drop();

    final second = await server.next();
    await second.signIn;
    second.ready();
    await eventually(() => connects().length == 2);
    expect(connects().last.reconnected, isTrue);
  });

  test('a device the server signed out stops for good and says so', () async {
    final s = line()..start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    await c.close(OrchardStream.closeSignedOut, 'signed out');
    await eventually(() => events.whereType<StreamSignedOut>().isNotEmpty);
    expect(s.isRunning, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.connections, hasLength(1));
  });

  test('a refused sign-in is tried once more with a fresh token, then waits', () async {
    line().start();
    final first = await server.next();
    await first.signIn;
    await first.close(OrchardStream.closeNotSignedIn, 'not signed in');
    final second = await server.next();
    await second.signIn;
    expect(tokenAsks, [false, true]);
    await second.close(OrchardStream.closeNotSignedIn, 'not signed in');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, hasLength(2), reason: 'no third try right away');
    expect(connects(), isEmpty);
  });

  test('an account with too many lines waits instead of trying again at once', () async {
    line().start();
    final c = await server.next();
    await c.signIn;
    await c.close(OrchardStream.closeBusy, 'too many connections');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, hasLength(1));
  });

  test('a successful sync cuts short the wait of a dropped line, not of a refusal', () async {
    final s = line(droppedWait: const Duration(minutes: 10))..start();
    final first = await server.next();
    await first.signIn;
    await first.drop();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.connections, hasLength(1));

    s.retryNow();
    final second = await server.next();
    await second.signIn;
    await second.close(OrchardStream.closeBusy);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    s.retryNow();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, hasLength(2));
  });

  test('opened afresh on demand, without waiting, and says it may have missed changes', () async {
    final s = line(droppedWait: const Duration(minutes: 10))..start();
    final first = await server.next();
    await first.signIn;
    first.ready();
    await eventually(() => connects().length == 1);
    s.reconnectNow();
    await first.closed;
    final second = await server.next();
    await second.signIn;
    second.ready();
    await eventually(() => connects().length == 2);
    expect(connects().last.reconnected, isTrue);
    expect(tokenAsks, [false, false]);
  });

  test('stop closes the line, and nothing opens it again', () async {
    final s = line()..start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => connects().isNotEmpty);
    await s.stop();
    await c.closed;
    expect(c.closeCode, WebSocketStatus.normalClosure);
    expect(s.isRunning, isFalse);
    expect(s.isConnected, isFalse);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.connections, hasLength(1));
  });

  test('signed out on this device, nothing opens', () async {
    bearer = null;
    final s = line()..start();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(server.connections, isEmpty);
    expect(s.isRunning, isFalse);
  });
}
