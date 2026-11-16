import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart' show AuthDeadline, SignInLinkBanners;
import 'package:zestssh/services/ssh_service.dart' show SshService, kAgentSignedLogLine, openSshSocket;
import 'package:zestssh/services/worker/terminal_output_batcher.dart';
import 'package:zestssh/services/worker/worker_connection_host.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';
import 'package:zestssh/services/worker/worker_transport.dart';

/// Design B (Phase 1) connection worker: the entrypoint that runs one SSH
/// terminal session on its OWN isolate, plus the [SSHClient]-backed transport it
/// drives.
///
/// Nothing here decides trust or holds a persistent secret. Host-key and auth
/// answers round-trip to the main isolate through [WorkerTransportHooks] (which
/// [WorkerConnectionHost] turns into request events); only key material needed
/// to SIGN (private-key PEM + passphrase) is passed in at spawn, because the
/// SSHClient must have its identities before auth and there is no external
/// signer hook. Crossing that key material is spec-sanctioned (same OS process
/// and heap; see docs/sftp-isolation-architecture.md); it is used once for the
/// single login and then dropped.
///
/// SECURITY: this code runs OFF the main isolate. It must NOT touch Flutter
/// bindings, providers, or plugins (FlutterSecureStorage etc.) - none are
/// available here. All UI-side effects go through the hooks / event protocol.

/// Top-level isolate entrypoint. Spawned by `WorkerSshService`.
///
/// [bootstrap] is a plain list so it crosses the spawn boundary with no custom
/// types:
///   [0] `SendPort`   - main isolate's receive port for events
///   [1] `List`       - `ConnectParams.toWire()`
///   [2] `List<String>` - private-key PEM texts (may be empty for password auth)
///   [3] `String?`    - key passphrase (null if keys are unencrypted / absent)
///   [4] `bool`       - forwardAgent
///   [5] `bool`       - hasPassword (whether the main isolate holds a password;
///                      NOT the password itself), so the worker wires password /
///                      keyboard-interactive auth conditionally like the direct path
///   [6] `bool`       - signInNotices (3.4.1): a person watches this sign-in, so a
///                      login banner with a link goes to them
///                      ([WorkerSignInNotice]) and the server is given
///                      kSignInLinkPatience; absent or false, a banner changes
///                      nothing (a run nobody watches)
void workerConnectionMain(List<Object?> bootstrap) {
  final mainSendPort = bootstrap[0] as SendPort;
  final params = ConnectParams.fromWire(bootstrap[1] as List<Object?>);
  final keyPems = (bootstrap[2] as List<Object?>).cast<String>();
  final passphrase = bootstrap[3] as String?;
  final forwardAgent = bootstrap[4] as bool;
  final hasPassword = bootstrap[5] as bool;
  final signInNotices = bootstrap.length > 6 && bootstrap[6] == true;

  final commandPort = ReceivePort();
  // First message back to main is our command port, so it can send us commands.
  mainSendPort.send(commandPort.sendPort);

  final host = WorkerConnectionHost(
    emit: (event) => mainSendPort.send(event.toWire()),
    transportFactory: (p, hooks) => _SshCoreTransport(
      params: p,
      hooks: hooks,
      keyPems: keyPems,
      passphrase: passphrase,
      forwardAgent: forwardAgent,
      hasPassword: hasPassword,
      signInNotices: signInNotices,
    ),
    // When the connection is torn down, close the port so the isolate's event
    // loop drains and the isolate exits on its own.
    onClosed: commandPort.close,
  );

  commandPort.listen((message) {
    if (message is List) {
      host.handle(WorkerCommand.fromWire(message));
    }
  });

  // Announce readiness, then immediately start the connect using the bootstrap
  // params (no separate WorkerConnect command needed - the worker exists solely
  // for this one connection).
  host.start();
  host.handle(WorkerConnect(params));
}

/// The real transport: wraps [SSHSocket] + [SSHClient] + the shell, wiring the
/// SSH callbacks to the [WorkerTransportHooks] so every decision round-trips to
/// the main isolate. Mirrors `SshService._authenticate` / `connect`.
///
/// Live-only: correctness is proven against a real host, not in unit tests
/// (the fake-transport tests cover [WorkerConnectionHost]'s side of this seam).
class _SshCoreTransport implements WorkerTransport {
  final ConnectParams params;
  final WorkerTransportHooks hooks;
  final List<String> keyPems;
  final String? passphrase;
  final bool forwardAgent;
  final bool hasPassword;

  /// A person watches the sign-in: a login banner with a link goes to them.
  final bool signInNotices;

  _SshCoreTransport({
    required this.params,
    required this.hooks,
    required this.keyPems,
    required this.passphrase,
    required this.forwardAgent,
    required this.hasPassword,
    required this.signInNotices,
  });

  SSHClient? _client;
  SSHSession? _shell;
  StreamSubscription<Uint8List>? _stdoutSub;
  StreamSubscription<Uint8List>? _stderrSub;
  bool _connected = false;
  bool _torn = false;

  // Coalesce stdout bursts into one hand-off per event-loop turn (fewer port
  // messages for a firehose) without backpressure: the high-water mark is set
  // effectively infinite so it never pauses (Phase 1 has no ack command yet).
  late final TerminalOutputBatcher _out = TerminalOutputBatcher(
    onBatch: hooks.stdout,
    onPause: () {},
    onResume: () {},
    highWaterMark: 1 << 50,
    lowWaterMark: 1 << 49,
  );

  @override
  Future<void> connect() async {
    // Parse identities from the crossed PEM text. fromPem returns a LIST (an
    // OpenSSH file can hold several keys); include them all.
    final identities = <SSHKeyPair>[];
    for (final pem in keyPems) {
      identities.addAll(SSHKeyPair.fromPem(pem, passphrase));
    }

    hooks.log('Resolving ${params.host}...');
    final socket = await openSshSocket(params.host, params.port, const Duration(seconds: 15));
    hooks.log('tcp_connect: Connected to ${params.host}:${params.port}');
    hooks.log('ssh_session: Starting SSH-2.0 protocol negotiation');

    // The sign-in's clock: 15 seconds, as before, unless the server's login
    // banner gives a watching person a link to open (Tailscale SSH's check
    // mode), which gives the server kSignInLinkPatience instead
    // (SignInLinkBanners, the same as every watched sign-in in the app).
    final deadline = AuthDeadline();
    final signInOver = Completer<void>();
    final links = SignInLinkBanners(
      signInNotices ? (notice) => hooks.signInNotice(notice.text, notice.link?.toString()) : null,
      deadline: deadline,
      withdrawn: signInOver.future,
      onLog: hooks.log,
    );

    final agent = forwardAgent && identities.isNotEmpty
        ? SSHKeyPairAgent(identities, onSigned: () => hooks.log(kAgentSignedLogLine))
        : null;

    final client = SSHClient(
      socket,
      username: params.username,
      identities: identities,
      algorithms:
          SshService.buildAlgorithms(compatibility: params.compatibilityMode),
      onVerifyHostKey: hooks.verifyHostKey,
      // Wire password / keyboard-interactive ONLY when the main isolate holds a
      // password, mirroring the in-isolate path (which leaves these null for a
      // publickey-only session). The main isolate still applies the fail-closed
      // 2FA rule (isRealPasswordPrompt) to every answer it does give.
      onPasswordRequest: hasPassword ? () => hooks.passwordRequest() : null,
      onUserInfoRequest: hasPassword
          ? (request) => hooks.userInfoRequest(
                request.name,
                [
                  for (final p in request.prompts)
                    (promptText: p.promptText, echo: p.echo),
                ],
              )
          : null,
      onAuthenticated: () => hooks.log('ssh_auth: authenticated'),
      // SignInNotice.of runs here, where the banner arrives: only its
      // cleaned words and link go to the main isolate.
      onUserauthBanner: (message) {
        hooks.log('ssh_auth: Server sent a login banner');
        links.banner(message);
      },
      agentHandler: agent,
      keepAliveInterval: params.keepAliveSeconds > 0
          ? Duration(seconds: params.keepAliveSeconds)
          : null,
    );
    _client = client;

    // Surface a wrong-credential failure within seconds rather than waiting for
    // the whole connection to time out (mirrors SshService). A cancel at a
    // banner's link ends it at once (SshPromptCancelled).
    try {
      await deadline.wait(
        links.orCancelled(client.authenticated),
        onTimeout: () => TimeoutException(
          'Authentication timed out - server did not respond within ${deadline.limit.inSeconds} seconds.',
        ),
      );
    } catch (_) {
      client.close();
      rethrow;
    } finally {
      if (!signInOver.isCompleted) signInOver.complete();
    }

    if (_torn) {
      client.close();
      return;
    }

    hooks.log('ssh_channel: Opening PTY (xterm-256color)');
    final shell = await client.shell(
      pty: const SSHPtyConfig(type: 'xterm-256color'),
    );
    _shell = shell;
    _connected = true;
    hooks.state(true);
    hooks.log('ssh_session: Shell session established');

    _stdoutSub = shell.stdout.listen(
      _out.add,
      onDone: _onShellDone,
      onError: (_) => _onShellDone(),
    );
    _stderrSub = shell.stderr.listen(hooks.stderr);
  }

  void _onShellDone() {
    if (!_connected) return;
    _connected = false;
    _out.flush();
    // A non-null exitCode/exitSignal means the remote process ended (clean
    // exit -> close the tab); a bare channel close is an unexpected drop.
    // Emit ONLY exited(clean), not a separate state(false): the facade turns
    // WorkerExited into the connectionState(false) transition AFTER it records
    // the clean flag, so a clean `exit` is never briefly seen as an unexpected
    // drop (which would auto-reconnect instead of closing the tab).
    final clean = _shell?.exitCode != null || _shell?.exitSignal != null;
    hooks.exited(clean);
  }

  @override
  void write(Uint8List data) => _shell?.write(data);

  @override
  void resize(int width, int height) {
    if (width > 0 && height > 0) {
      _shell?.resizeTerminal(width, height);
    }
  }

  @override
  Future<void> close() async {
    if (_torn) return;
    _torn = true;
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _out.flush();
    _shell?.close();
    _client?.close();
  }
}
