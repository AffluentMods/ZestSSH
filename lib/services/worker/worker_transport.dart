import 'dart:typed_data';

import 'package:zestssh/services/worker/ssh_callback_router.dart';
import 'package:zestssh/services/worker/worker_protocol.dart';

/// The seam between the worker's connection lifecycle ([WorkerConnectionHost])
/// and the actual SSH machinery.
///
/// A [WorkerTransport] owns exactly one dialled connection: it authenticates,
/// opens the shell, and streams bytes. It never decides trust or supplies a
/// credential on its own. Every host-key and auth decision is asked through the
/// [WorkerTransportHooks] callbacks, which the host forwards to the main isolate
/// and answers only from there. This is what keeps the "a worker cannot
/// self-approve" invariant true no matter which transport implementation is
/// underneath:
///
///   * the real [SSHClient]-backed transport (live-verified only), and
///   * a fake in-memory transport used to test the lifecycle with no live host.
abstract class WorkerTransport {
  /// Dial, run key exchange + host-key verification (via the hooks),
  /// authenticate (via the hooks), and open the interactive shell. Completes
  /// when the shell is established; throws if the host key is rejected or auth
  /// fails, which the host turns into a [WorkerError].
  Future<void> connect();

  /// Forward terminal input to the shell.
  void write(Uint8List data);

  /// Forward a terminal window resize to the shell.
  void resize(int width, int height);

  /// Tear the connection down.
  Future<void> close();
}

/// The callbacks a [WorkerTransport] uses to ask the main isolate for a decision
/// and to report progress and bytes. The request callbacks
/// ([verifyHostKey]/[passwordRequest]/[userInfoRequest]) are the trust seam:
/// they round-trip to the main isolate and the transport acts only on the
/// answer. The report callbacks feed [WorkerEvent]s back to the UI.
class WorkerTransportHooks {
  /// Ask the main isolate to verify the presented host key. Returns true to
  /// accept. The transport has no other way to approve a key.
  final Future<bool> Function(String type, Uint8List keyBlob) verifyHostKey;

  /// Ask the main isolate for the account password (direct password auth). Null
  /// means no password is configured, so the method is skipped. The password
  /// lives only on the main isolate; it reaches the transport only as this
  /// answer, for the single login.
  final Future<String?> Function() passwordRequest;

  /// Ask the main isolate to answer keyboard-interactive prompts. The main
  /// isolate applies the fail-closed rule ([isRealPasswordPrompt]); the
  /// transport just relays the returned responses.
  final Future<List<String>> Function(
      String name, List<WorkerAuthPrompt> prompts) userInfoRequest;

  /// A human-readable progress line for the connection log.
  final void Function(String message) log;

  /// Connection came up (true) or went down (false).
  final void Function(bool connected) state;

  /// Terminal stdout / stderr bytes.
  final void Function(Uint8List data) stdout;
  final void Function(Uint8List data) stderr;

  /// The remote shell exited. [clean] distinguishes a normal `exit`/Ctrl-D from
  /// an unexpected transport drop.
  final void Function(bool clean) exited;

  /// A fatal error to surface to the user.
  final void Function(String message) error;

  /// Shows the person the server's login banner [text] with its https [link]
  /// (3.4.1: SignInLinkBanners on the worker, where the banner arrives).
  /// Completes with true where they cancel the sign-in there, false where
  /// the connection ends first. Used only where a person watches the
  /// sign-in, which the worker is told at its start.
  final Future<bool> Function(String text, String? link) signInNotice;

  const WorkerTransportHooks({
    required this.verifyHostKey,
    required this.passwordRequest,
    required this.userInfoRequest,
    required this.log,
    required this.state,
    required this.stdout,
    required this.stderr,
    required this.exited,
    required this.error,
    required this.signInNotice,
  });
}

/// Builds a [WorkerTransport] for a connection. Injected into
/// [WorkerConnectionHost] so the real isolate entrypoint supplies the
/// [SSHClient]-backed transport while tests supply a fake, exercising the exact
/// same lifecycle and trust seam.
typedef WorkerTransportFactory = WorkerTransport Function(
  ConnectParams params,
  WorkerTransportHooks hooks,
);
