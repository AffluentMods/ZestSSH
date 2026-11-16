import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/worker/ssh_callback_router.dart'
    show WorkerAuthPrompt;
import 'package:zestssh/services/worker/worker_connection_host.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/services/worker/worker_transport.dart';

/// Design B worker lifecycle.
///
/// Exercises the full connect / auth / stream / disconnect lifecycle of
/// [WorkerConnectionHost] against a fake transport, with no live host. The
/// point that matters most: the host only ever acts on a reply command from the
/// main isolate. The reject test proves a `false` host-key reply aborts the
/// connection before auth is even attempted, and the id-correlation test proves
/// a stray reply cannot unblock a request it does not match.
void main() {
  late List<WorkerEvent> events;
  late FakeTransport fake;
  late WorkerConnectionHost host;
  late int closedCalls;

  void build({AuthMode auth = AuthMode.password}) {
    events = <WorkerEvent>[];
    closedCalls = 0;
    fake = FakeTransport(authMode: auth);
    host = WorkerConnectionHost(
      emit: events.add,
      transportFactory: (params, hooks) => fake..hooks = hooks,
      onClosed: () => closedCalls++,
    );
  }

  const params = ConnectParams(host: 'srv', port: 22, username: 'root');

  test('start announces readiness exactly once', () {
    build();
    host.start();
    expect(events, [isA<WorkerReady>()]);
  });

  test('happy path: host key accepted, password auth, shell streams', () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();

    final hkReq = events.whereType<WorkerHostKeyRequest>().single;
    expect(hkReq.type, 'ssh-ed25519');
    // Nothing has come up yet: the transport is parked on the reply.
    expect(events.whereType<WorkerConnectionState>(), isEmpty);

    host.handle(WorkerHostKeyReply(hkReq.id, true));
    await _pump();

    final pwReq = events.whereType<WorkerPasswordRequest>().single;
    host.handle(WorkerPasswordReply(pwReq.id, 'secret'));
    await _pump();

    expect(fake.receivedPassword, 'secret');
    expect(
      events.whereType<WorkerConnectionState>().map((e) => e.connected),
      contains(true),
    );
    expect(events.whereType<WorkerStdout>(), isNotEmpty);

    // Input and resize reach the transport once connected.
    host.handle(WorkerWrite(Uint8List.fromList([1, 2, 3])));
    host.handle(const WorkerResize(120, 40));
    expect(fake.written.single, orderedEquals([1, 2, 3]));
    expect(fake.resizes.single, (120, 40));

    host.handle(const WorkerDisconnect());
    await _pump();
    expect(events.whereType<WorkerExited>().single.clean, isTrue);
    expect(host.hasTransport, isFalse);
  });

  test('a login banner notice (3.4.1): emitted for the main isolate, answered true by a cancel, and false at a '
      'teardown, so nothing waits forever', () async {
    build(auth: AuthMode.none);
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();
    final cancelled = fake.hooks.signInNotice('visit https://login.example.com/a/1', 'https://login.example.com/a/1');
    final notice = events.whereType<WorkerSignInNotice>().single;
    expect(notice.text, 'visit https://login.example.com/a/1');
    expect(notice.link, 'https://login.example.com/a/1');
    host.handle(const WorkerSignInCancel());
    expect(await cancelled, isTrue);

    final withdrawn = fake.hooks.signInNotice('again', null);
    host.handle(const WorkerDisconnect());
    expect(await withdrawn, isFalse);
  });

  test('rejected host key aborts before auth is ever attempted', () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();

    final hkReq = events.whereType<WorkerHostKeyRequest>().single;
    host.handle(WorkerHostKeyReply(hkReq.id, false));
    await _pump();

    // Connection surfaced an error and never came up.
    expect(events.whereType<WorkerError>(), isNotEmpty);
    expect(
      events.whereType<WorkerConnectionState>().where((e) => e.connected),
      isEmpty,
    );
    // Auth was never reached: the password was never requested or received.
    expect(events.whereType<WorkerPasswordRequest>(), isEmpty);
    expect(fake.receivedPassword, isNull);
    // Transport dropped, back to a clean pre-connect state.
    expect(host.hasTransport, isFalse);
  });

  test('a reply with a mismatched id does not unblock the request', () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();

    final hkReq = events.whereType<WorkerHostKeyRequest>().single;
    // Wrong id: must be ignored, the request stays parked.
    host.handle(WorkerHostKeyReply(hkReq.id + 999, true));
    await _pump();
    expect(events.whereType<WorkerPasswordRequest>(), isEmpty);
    expect(events.whereType<WorkerConnectionState>(), isEmpty);

    // Correct id now unblocks it.
    host.handle(WorkerHostKeyReply(hkReq.id, true));
    await _pump();
    expect(events.whereType<WorkerPasswordRequest>(), isNotEmpty);
  });

  test('keyboard-interactive prompts round-trip their answers', () async {
    build(auth: AuthMode.userInfo);
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();
    host.handle(
        WorkerHostKeyReply(events.whereType<WorkerHostKeyRequest>().single.id, true));
    await _pump();

    final uiReq = events.whereType<WorkerUserInfoRequest>().single;
    expect(uiReq.name, 'Two-factor');
    expect(uiReq.prompts, hasLength(2));
    host.handle(WorkerUserInfoReply(uiReq.id, ['pw', '']));
    await _pump();

    expect(fake.receivedResponses, orderedEquals(['pw', '']));
    expect(
      events.whereType<WorkerConnectionState>().map((e) => e.connected),
      contains(true),
    );
  });

  test('disconnect while a request is parked fails it closed, no hang',
      () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();
    // A host-key request is now pending.
    expect(events.whereType<WorkerHostKeyRequest>(), isNotEmpty);

    // Tear down before answering. The parked host-key request must complete
    // (as reject) so nothing hangs, and the transport is dropped.
    host.handle(const WorkerDisconnect());
    await _pump();
    expect(host.hasTransport, isFalse);
    // It never came up.
    expect(
      events.whereType<WorkerConnectionState>().where((e) => e.connected),
      isEmpty,
    );
  });

  test('a spontaneous remote exit tears down and lets the isolate exit',
      () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();
    host.handle(
        WorkerHostKeyReply(events.whereType<WorkerHostKeyRequest>().single.id, true));
    await _pump();
    host.handle(WorkerPasswordReply(
        events.whereType<WorkerPasswordRequest>().single.id, 'pw'));
    await _pump();
    expect(host.hasTransport, isTrue);

    // The remote shell ends on its own (no WorkerDisconnect command).
    fake.endRemotely(clean: true);
    await _pump();

    // The exit is surfaced, the transport is dropped, and onClosed fired so the
    // owning isolate can exit (it does not linger waiting for a disconnect).
    expect(events.whereType<WorkerExited>().single.clean, isTrue);
    expect(host.hasTransport, isFalse);
    expect(closedCalls, 1);
  });

  test('a second connect while already connected is refused', () async {
    build();
    host.start();
    host.handle(const WorkerConnect(params));
    await _pump();
    host.handle(const WorkerConnect(params));
    await _pump();
    expect(
      events.whereType<WorkerError>().any(
          (e) => e.message.toLowerCase().contains('already')),
      isTrue,
    );
  });
}

Future<void> _pump([int times = 3]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

enum AuthMode { password, userInfo, none }

/// A fake [WorkerTransport] that drives the hooks in a realistic order without
/// any SSH. It records what the host forwarded to it so the test can assert the
/// answers actually arrived.
class FakeTransport implements WorkerTransport {
  FakeTransport({this.authMode = AuthMode.password});

  final AuthMode authMode;
  late WorkerTransportHooks hooks;

  final List<Uint8List> written = [];
  final List<(int, int)> resizes = [];
  String? receivedPassword;
  List<String>? receivedResponses;
  bool closed = false;

  @override
  Future<void> connect() async {
    hooks.log('ssh: dialing');
    final accepted =
        await hooks.verifyHostKey('ssh-ed25519', Uint8List.fromList([1, 2, 3]));
    if (!accepted) {
      throw Exception('Host key rejected');
    }
    switch (authMode) {
      case AuthMode.password:
        receivedPassword = await hooks.passwordRequest();
      case AuthMode.userInfo:
        receivedResponses = await hooks.userInfoRequest(
          'Two-factor',
          const <WorkerAuthPrompt>[
            (promptText: 'Password:', echo: false),
            (promptText: 'Verification code:', echo: true),
          ],
        );
      case AuthMode.none:
        break;
    }
    hooks.state(true);
    hooks.stdout(Uint8List.fromList([104, 105])); // "hi"
  }

  @override
  void write(Uint8List data) => written.add(data);

  @override
  void resize(int width, int height) => resizes.add((width, height));

  /// Simulate the remote shell ending on its own (no close() call), the way the
  /// real transport's shell.stdout.onDone does.
  void endRemotely({required bool clean}) => hooks.exited(clean);

  @override
  Future<void> close() async {
    closed = true;
    hooks.exited(true);
  }
}
