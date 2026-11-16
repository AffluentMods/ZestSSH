import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/services/ssh_auth_prompts.dart' show SignInNotice, SignInNoticeShower, SshPromptCancelled, kSignInLinkPatience;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/worker/ssh_callback_router.dart';
import 'package:zestssh/services/worker/worker_connection_isolate.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// Raised when the worker-hosted connection fails after the isolate is up
/// (auth failure, host-key rejection, transport error). Surfaced to the session
/// layer like any other connect error - it does NOT trigger the in-isolate
/// fallback, because retrying in-isolate would just fail the same way (and would
/// double the login attempt / second-factor prompt).
class WorkerConnectionException implements Exception, HasTypeName {
  final String message;
  WorkerConnectionException(this.message);
  @override
  String toString() => message;

  @override
  String get typeName => 'WorkerConnectionException';
}

/// Design B (Phase 1) main-isolate facade: a [ShellService] whose SSH terminal
/// session actually runs on a dedicated worker isolate.
///
/// It spawns the worker ([workerConnectionMain]), owns the port pair, and turns
/// the worker's request events into decisions made HERE via [SshCallbackRouter]
/// (the same real host-key verifier and the same fail-closed prompt rule the
/// in-isolate path uses). The worker can never self-approve: it only ever posts
/// a request and waits for the reply this facade sends back.
///
/// Robustness: if the worker ISOLATE cannot start (spawn throws, or it never
/// reports its command port), [connect] transparently falls back to a normal
/// in-isolate [SshService] built by [fallbackFactory], so enabling the flag can
/// never leave a user unable to connect. A failure AFTER the isolate is up
/// (auth/host-key/transport) is surfaced as a real error, not retried.
///
/// It is deliberately NOT a subclass of [SshService]: it has no in-process
/// [SSHClient], so the SFTP / port-forward / exec gates (`is SshService`)
/// correctly exclude a worker session (Phase 1 keeps those on the in-isolate
/// path). [isEncryptedSsh] is still true so the padlock and other cosmetic
/// SSH-only affordances keep working.
class WorkerSshService implements ShellService, ShellEndReason {
  final ConnectParams params;

  /// Raw private-key PEM text(s) for public-key auth, crossed to the worker so
  /// the SSHClient there can sign. Empty for password-only auth.
  final List<String> keyPems;
  final String? passphrase;

  /// The account password. Held HERE, never crossed; answered per-request via
  /// the router so the fail-closed 2FA rule always runs on the main isolate.
  final String? password;

  final bool forwardAgent;
  final HostKeyVerifyCallback onHostKeyVerify;
  final ConnectionLogCallback? onLog;

  /// As [SshService.onAgentSigned]: the worker says it in its log.
  final void Function()? onAgentSigned;

  /// As [SshService.onSignInNotice] (3.4.1): a login banner with a link the
  /// sign-in waits on (Tailscale SSH's check mode) is cleaned on the worker
  /// ([WorkerSignInNotice]) and shown to the person through this, the same
  /// notice as on the in-isolate path; their cancel goes back
  /// ([WorkerSignInCancel]) and ends the sign-in as a cancel. Null where
  /// nobody watches (a run nobody watches): the worker then gives the
  /// sign-in no more time for a banner.
  final SignInNoticeShower? onSignInNotice;

  /// Runs the worker on this isolate instead of its own, for tests: a
  /// played server's connection cannot cross to another isolate. The worker
  /// is the same code, through the same ports.
  @visibleForTesting
  static bool debugInProcess = false;

  /// Builds a fresh in-isolate [SshService] with the identical connection so a
  /// worker-infrastructure failure degrades to today's proven path.
  final SshService Function() fallbackFactory;

  WorkerSshService({
    required this.params,
    required this.keyPems,
    required this.passphrase,
    required this.password,
    required this.forwardAgent,
    required this.onHostKeyVerify,
    required this.fallbackFactory,
    this.onLog,
    this.onAgentSigned,
    this.onSignInNotice,
  });

  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  Isolate? _isolate;
  ReceivePort? _fromWorker;
  ReceivePort? _exitPort;
  SendPort? _toWorker;
  SshCallbackRouter? _router;

  SshService? _fallback;
  StreamSubscription<Uint8List>? _fbStdoutSub;
  StreamSubscription<Uint8List>? _fbStderrSub;
  StreamSubscription<bool>? _fbStateSub;

  final _infraReady = Completer<void>();
  final _connectResult = Completer<void>();

  bool _isConnected = false;
  bool _exitedCleanly = false;
  bool _disposed = false;

  /// Completes when the sign-in is over (signed in, failed or cancelled):
  /// a notice shown for it is withdrawn then.
  final _signInOver = Completer<void>();
  bool _noticeShown = false;

  /// The backstop on a worker that never reports ([connect]): 45 seconds,
  /// and longer once a notice gave the server more time.
  Timer? _backstop;

  @override
  Future<void> connect() async {
    // Ensure a lone error completion never becomes an unhandled async error
    // (the fallback path returns without awaiting this future).
    _connectResult.future.catchError((_) {});
    try {
      await _startWorkerInfra();
    } catch (e) {
      // The worker ISOLATE could not start. Fall back to the in-isolate path.
      onLog?.call('worker: isolate unavailable ($e); using in-isolate SSH');
      AppLogger.warning('Design B worker path could not start: $e; falling back');
      await _killWorker();
      await _fallbackConnect();
      return;
    }
    // Isolate is up. Await the actual connection result; auth / host-key /
    // transport errors here PROPAGATE (surface to the user), no fallback. The
    // timeout is a backstop for a worker that dies without reporting (the
    // onExit listener normally surfaces that far sooner).
    _armBackstop(const Duration(seconds: 45));
    try {
      await _connectResult.future;
    } catch (_) {
      // Self-clean on ANY connect failure so a dead session never leaks the
      // worker isolate, its socket, or our ports. The caller is not required to
      // call disconnect() after a throw (the in-isolate SshService self-cleans
      // on auth failure the same way).
      await _shutdown();
      rethrow;
    } finally {
      _backstop?.cancel();
      if (!_signInOver.isCompleted) _signInOver.complete();
    }
    _isConnected = true;
  }

  void _armBackstop(Duration after) {
    _backstop?.cancel();
    _backstop = Timer(after, () {
      if (!_connectResult.isCompleted) {
        _connectResult.completeError(WorkerConnectionException('Connection timed out'));
      }
    });
  }

  /// The worker's notice of a login banner with a link: shown once, while
  /// the sign-in waits on it.
  void _showNotice(String text, String? link) {
    final show = onSignInNotice;
    if (show == null || _noticeShown || _connectResult.isCompleted) return;
    _noticeShown = true;
    // The worker gave the server kSignInLinkPatience: so does the backstop.
    _armBackstop(kSignInLinkPatience + const Duration(seconds: 45));
    final notice = SignInNotice.carried(text, link, withdrawn: _signInOver.future);
    show(notice).then((cancelled) {
      if (!cancelled || _connectResult.isCompleted) return;
      onLog?.call('ssh_auth: Sign-in cancelled at the link');
      _send(const WorkerSignInCancel());
      _connectResult.completeError(const SshPromptCancelled());
    }, onError: (Object _) {});
  }

  Future<void> _startWorkerInfra() async {
    _router = SshCallbackRouter(
      host: params.host,
      port: params.port,
      onHostKeyVerify: onHostKeyVerify,
      password: password,
      onLog: onLog,
    );

    final fromWorker = ReceivePort();
    _fromWorker = fromWorker;
    fromWorker.listen(_onWorkerMessage);

    final exitPort = ReceivePort();
    _exitPort = exitPort;
    exitPort.listen((_) => _onWorkerExit());

    final bootstrap = <Object?>[
      fromWorker.sendPort,
      params.toWire(),
      keyPems,
      passphrase,
      forwardAgent,
      // Whether a password is configured (a bool, NOT the password), so the
      // worker wires password / keyboard-interactive auth conditionally, exactly
      // like the in-isolate path. The password itself never crosses at bootstrap.
      password != null,
      // Whether someone watches the sign-in, to be shown a login banner's link.
      onSignInNotice != null,
    ];

    if (debugInProcess) {
      workerConnectionMain(bootstrap);
    } else {
      _isolate = await Isolate.spawn(
        workerConnectionMain,
        bootstrap,
        onExit: exitPort.sendPort,
        debugName: 'ssh-worker-${params.host}',
        errorsAreFatal: true,
      );
    }

    // Consider the isolate "started" once it hands back its command port.
    await _infraReady.future.timeout(
      const Duration(seconds: 12),
      onTimeout: () =>
          throw TimeoutException('worker did not report its command port'),
    );
  }

  void _onWorkerMessage(dynamic message) {
    if (message is SendPort) {
      _toWorker = message;
      if (!_infraReady.isCompleted) _infraReady.complete();
      return;
    }
    if (message is List) {
      _handleEvent(WorkerEvent.fromWire(message));
    }
  }

  /// An event from the worker, for tests (which have no worker isolate).
  @visibleForTesting
  void debugHandle(WorkerEvent event) => _handleEvent(event);

  void _handleEvent(WorkerEvent event) {
    // Once torn down, ignore any in-flight worker message so nothing is added to
    // a closed controller.
    if (_disposed) return;
    switch (event) {
      case WorkerReady():
        break; // infra readiness is signalled by the command SendPort
      case WorkerStdout(:final data):
        _stdoutController.add(data);
      case WorkerStderr(:final data):
        _stderrController.add(data);
      case WorkerConnectionState(:final connected):
        _isConnected = connected;
        _connectionStateController.add(connected);
        if (connected && !_connectResult.isCompleted) {
          _connectResult.complete();
        }
      case WorkerLog(:final message):
        if (message == kAgentSignedLogLine) {
          onAgentSigned?.call();
        } else {
          onLog?.call(message);
        }
      case WorkerHostKeyRequest(:final id, :final type, :final keyBlob):
        // Decide HERE, on the isolate that owns the known-hosts DB + prompt UI.
        _router!.verifyHostKey(type, keyBlob).then(
          (accepted) => _send(WorkerHostKeyReply(id, accepted)),
          onError: (_) => _send(WorkerHostKeyReply(id, false)),
        );
      case WorkerPasswordRequest(:final id):
        _send(WorkerPasswordReply(id, _router!.passwordRequest()));
      case WorkerUserInfoRequest(:final id, :final name, :final prompts):
        _send(WorkerUserInfoReply(id, _router!.userInfoResponse(name, prompts)));
      case WorkerExited(:final clean):
        // The worker does not say why; an error it said first stands.
        _ended(null);
        _exitedCleanly = clean;
        _isConnected = false;
        _connectionStateController.add(false);
        if (!_connectResult.isCompleted) {
          _connectResult
              .completeError(WorkerConnectionException('Connection closed'));
        }
      case WorkerSignInNotice(:final text, :final link):
        _showNotice(text, link);
      case WorkerError(:final message):
        if (!_connectResult.isCompleted) {
          _connectResult.completeError(WorkerConnectionException(message));
        } else {
          // A fatal error AFTER connect: surface it and tear the session down
          // (unclean drop) rather than leaving the UI showing "connected".
          _ended(message);
          onLog?.call('error: $message');
          _isConnected = false;
          _connectionStateController.add(false);
        }
    }
  }

  void _send(WorkerCommand command) => _toWorker?.send(command.toWire());

  void _onWorkerExit() {
    if (_disposed) return; // normal teardown: we killed it
    if (_fallback != null) return; // already switched off the worker path
    if (!_connectResult.isCompleted) {
      _connectResult.completeError(
          WorkerConnectionException('worker isolate exited unexpectedly'));
    } else if (_isConnected) {
      _isConnected = false;
      _connectionStateController.add(false);
    }
  }

  Future<void> _fallbackConnect() async {
    final fb = fallbackFactory();
    _fallback = fb;
    // Pipe the fallback's streams into OUR controllers so subscribers set up
    // before connect() (the session layer listens to stdout first) keep working.
    _fbStdoutSub = fb.stdout.listen(_stdoutController.add);
    _fbStderrSub = fb.stderr.listen(_stderrController.add);
    _fbStateSub = fb.connectionState.listen((c) {
      _isConnected = c;
      _connectionStateController.add(c);
    });
    await fb.connect();
    _isConnected = fb.isConnected;
  }

  Future<void> _killWorker() async {
    _fromWorker?.close();
    _fromWorker = null;
    _exitPort?.close();
    _exitPort = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _toWorker = null;
  }

  @override
  void write(Uint8List data) {
    if (_fallback != null) {
      _fallback!.write(data);
      return;
    }
    _send(WorkerWrite(data));
  }

  @override
  void resize(int width, int height) {
    if (_fallback != null) {
      _fallback!.resize(width, height);
      return;
    }
    _send(WorkerResize(width, height));
  }

  @override
  Future<void> disconnect() async => _shutdown();

  /// Single teardown path, shared by [disconnect] and the connect-failure
  /// cleanup, so a failed connect leaks nothing and a normal disconnect and a
  /// failure converge on the same cleanup. Idempotent via [_disposed].
  Future<void> _shutdown() async {
    if (_disposed) return;
    _disposed = true;
    if (_fallback != null) {
      await _fbStdoutSub?.cancel();
      await _fbStderrSub?.cancel();
      await _fbStateSub?.cancel();
      await _fallback!.disconnect();
    } else {
      _send(const WorkerDisconnect());
      await _killWorker();
    }
    _isConnected = false;
    if (!_connectResult.isCompleted) {
      _connectResult.completeError(WorkerConnectionException('Disconnected'));
    }
    if (!_stdoutController.isClosed) await _stdoutController.close();
    if (!_stderrController.isClosed) await _stderrController.close();
    if (!_connectionStateController.isClosed) {
      await _connectionStateController.close();
    }
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;

  @override
  bool get isConnected => _fallback?.isConnected ?? _isConnected;

  @override
  bool get exitedCleanly => _fallback?.exitedCleanly ?? _exitedCleanly;

  final _endReason = Completer<String?>();

  @override
  Future<String?> get endReason => _fallback?.endReason ?? _endReason.future;

  void _ended(String? reason) {
    if (!_endReason.isCompleted) _endReason.complete(reason);
  }

  @override
  bool get isEncryptedSsh => true;
}
