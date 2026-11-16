import 'dart:async';

import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/services/worker/worker_transport.dart';

/// The isolate-agnostic core of a Design B connection worker.
///
/// It owns the connection lifecycle and the request/reply correlation, but not
/// the isolate or the socket: it takes an [emit] sink for outgoing
/// [WorkerEvent]s and a [WorkerTransportFactory] for the SSH machinery, so the
/// exact same logic runs in the real worker isolate (emit = post to the main
/// `SendPort`, factory = the `SSHClient`-backed transport) and under
/// `flutter test` (emit = collect into a list, factory = a fake transport).
///
/// SECURITY: the host never approves a host key or supplies a credential
/// itself. When the transport needs a decision, the host allocates a request
/// id, emits the matching request event, and parks on a [Completer]; the
/// decision arrives later as a reply command from the main isolate and
/// completes that completer. A reply for an unknown id is dropped. There is no
/// code path here that answers a host-key or auth request without a main-isolate
/// reply, which is the worker-side half of the "cannot self-approve" invariant.
class WorkerConnectionHost {
  /// Sink for events headed to the main isolate.
  final void Function(WorkerEvent event) emit;

  /// Builds the transport once a [WorkerConnect] arrives.
  final WorkerTransportFactory transportFactory;

  /// Invoked after a [WorkerDisconnect] finishes tearing the transport down, so
  /// the isolate entrypoint can close its `ReceivePort` and let the isolate
  /// exit. Null under test.
  final void Function()? onClosed;

  WorkerConnectionHost({
    required this.emit,
    required this.transportFactory,
    this.onClosed,
  });

  WorkerTransport? _transport;
  var _nextRequestId = 1;
  final _pendingHostKey = <int, Completer<bool>>{};
  final _pendingPassword = <int, Completer<String?>>{};
  final _pendingUserInfo = <int, Completer<List<String>>>{};

  /// The login banner notices shown (one per sign-in), each completed with
  /// true by a [WorkerSignInCancel], or false at a teardown.
  final _pendingNotices = <Completer<bool>>[];

  /// Announce readiness to the main isolate. Called once after the port
  /// handshake; a [WorkerConnect] is only expected after this.
  void start() => emit(const WorkerReady());

  /// Route one incoming command. Synchronous dispatch: [WorkerConnect] kicks off
  /// an async connect that parks on reply completers, so this method must return
  /// promptly for the reply commands that unblock it to be handled.
  void handle(WorkerCommand command) {
    switch (command) {
      case WorkerConnect(:final params):
        _onConnect(params);
      case WorkerWrite(:final data):
        _transport?.write(data);
      case WorkerResize(:final width, :final height):
        _transport?.resize(width, height);
      case WorkerDisconnect():
        _onDisconnect();
      case WorkerHostKeyReply(:final id, :final accepted):
        _pendingHostKey.remove(id)?.complete(accepted);
      case WorkerPasswordReply(:final id, :final password):
        _pendingPassword.remove(id)?.complete(password);
      case WorkerUserInfoReply(:final id, :final responses):
        _pendingUserInfo.remove(id)?.complete(responses);
      case WorkerSignInCancel():
        for (final c in _pendingNotices) {
          if (!c.isCompleted) c.complete(true);
        }
        _pendingNotices.clear();
    }
  }

  void _onConnect(ConnectParams params) {
    if (_transport != null) {
      emit(const WorkerError('Worker already has a connection'));
      return;
    }
    final hooks = WorkerTransportHooks(
      verifyHostKey: (type, keyBlob) {
        final id = _nextRequestId++;
        final completer = Completer<bool>();
        _pendingHostKey[id] = completer;
        emit(WorkerHostKeyRequest(id, type, keyBlob));
        return completer.future;
      },
      passwordRequest: () {
        final id = _nextRequestId++;
        final completer = Completer<String?>();
        _pendingPassword[id] = completer;
        emit(WorkerPasswordRequest(id));
        return completer.future;
      },
      userInfoRequest: (name, prompts) {
        final id = _nextRequestId++;
        final completer = Completer<List<String>>();
        _pendingUserInfo[id] = completer;
        emit(WorkerUserInfoRequest(id, name, prompts));
        return completer.future;
      },
      log: (message) => emit(WorkerLog(message)),
      state: (connected) => emit(WorkerConnectionState(connected)),
      stdout: (data) => emit(WorkerStdout(data)),
      stderr: (data) => emit(WorkerStderr(data)),
      exited: (clean) {
        emit(WorkerExited(clean));
        // A SPONTANEOUS end (remote `exit`/Ctrl-D or a transport drop) must also
        // let the isolate exit, mirroring the WorkerDisconnect path - otherwise
        // the owning isolate lingers because onClosed only runs on an explicit
        // disconnect the unexpected-drop path never sends.
        _onRemoteEnd();
      },
      error: (message) => emit(WorkerError(message)),
      signInNotice: (text, link) {
        final completer = Completer<bool>();
        _pendingNotices.add(completer);
        emit(WorkerSignInNotice(text, link));
        return completer.future;
      },
    );
    _transport = transportFactory(params, hooks);
    unawaited(_runConnect());
  }

  Future<void> _runConnect() async {
    try {
      await _transport!.connect();
    } catch (e) {
      // A rejected host key or an auth failure lands here. Surface it and drop
      // the transport so the worker is back to a clean pre-connect state, and
      // fail any auth request still parked (the connect aborted before its
      // reply arrived) so nothing on the main side awaits forever.
      emit(WorkerError('$e'));
      _transport = null;
      _failPending();
    }
  }

  void _onDisconnect() {
    final transport = _transport;
    _transport = null;
    _failPending();
    if (transport == null) {
      onClosed?.call();
      return;
    }
    unawaited(transport.close().whenComplete(() => onClosed?.call()));
  }

  /// A spontaneous remote end (the transport already tore its own socket down;
  /// it does NOT need close() called again). Drop the transport, fail any parked
  /// request, and signal the isolate to exit. No-op if already torn down (an
  /// explicit disconnect that raced the exit).
  void _onRemoteEnd() {
    if (_transport == null) return;
    _transport = null;
    _failPending();
    onClosed?.call();
  }

  /// Complete every still-parked request with a safe default so no future on
  /// either side hangs after a teardown: a host key defaults to REJECT (fail
  /// closed), auth answers to empty.
  void _failPending() {
    for (final c in _pendingHostKey.values) {
      if (!c.isCompleted) c.complete(false);
    }
    for (final c in _pendingPassword.values) {
      if (!c.isCompleted) c.complete(null);
    }
    for (final c in _pendingUserInfo.values) {
      if (!c.isCompleted) c.complete(const <String>[]);
    }
    for (final c in _pendingNotices) {
      if (!c.isCompleted) c.complete(false);
    }
    _pendingNotices.clear();
    _pendingHostKey.clear();
    _pendingPassword.clear();
    _pendingUserInfo.clear();
  }

  /// True once a [WorkerConnect] has built a transport and before teardown.
  /// Writes and resizes arriving before this is true are dropped (no
  /// connection yet). Exposed for tests to assert lifecycle state.
  bool get hasTransport => _transport != null;
}
