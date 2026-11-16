/// Design B (per-connection worker isolate) message protocol.
///
/// The connection worker owns the socket and the SSH state machine; the UI
/// isolate is a thin client. They speak only through these two closed message
/// families over a `SendPort`/`ReceivePort` pair:
///
///   * [WorkerCommand]  main isolate  ->  worker   (connect, write, resize, ...)
///   * [WorkerEvent]    worker        ->  main     (stdout, prompts, state, ...)
///
/// SECURITY: nothing in this protocol lets the worker decide trust. Host-key
/// and auth prompts travel OUT as request events ([WorkerHostKeyRequest],
/// [WorkerPasswordRequest], [WorkerUserInfoRequest]); the decision is made on
/// the main isolate by `SshCallbackRouter` and only the answer travels back as
/// a reply command. The worker never carries a known-hosts DB or the account
/// password, so it has no path to self-approve. See
/// `docs/sftp-isolation-architecture.md` and `ssh_callback_router.dart`.
///
/// Every message defines a `toWire()` that returns only primitives, [Uint8List]
/// and nested lists, so it crosses a `SendPort` unchanged, and a matching
/// `fromWire()` so the far side rebuilds it. Keeping the wire form explicit (and
/// round-trip tested) means a field can never silently stop crossing the
/// boundary the way an ad-hoc map would. Terminal-byte events additionally get
/// a zero-copy hand-off at the send boundary (see the transport layer); the
/// wire form here stays a plain [Uint8List] so it is trivially testable.
library;

import 'dart:typed_data';

import 'package:zestssh/services/worker/ssh_callback_router.dart'
    show WorkerAuthPrompt;

/// The non-secret identity and options the worker needs to DIAL and negotiate a
/// connection. Deliberately carries no credentials and no live SSH objects: the
/// account password stays on the main isolate inside `SshCallbackRouter`, and a
/// live `SSHClient`/`SSHSocket` cannot cross an isolate at all. Phase 1 selects
/// the worker path only for direct, terminal-only sessions, so there is no jump
/// chain or tunnel socket to describe here.
class ConnectParams {
  final String host;
  final int port;
  final String username;

  /// Advertise legacy algorithms (CBC, hmac-md5, DH group-1) alongside the
  /// modern defaults for old servers. Mirrors `SshService.compatibilityMode`.
  final bool compatibilityMode;
  final bool zlibCompression;
  final bool forwardAgent;
  final int keepAliveSeconds;

  const ConnectParams({
    required this.host,
    required this.port,
    required this.username,
    this.compatibilityMode = false,
    this.zlibCompression = false,
    this.forwardAgent = false,
    this.keepAliveSeconds = 0,
  });

  List<Object?> toWire() => [
        host,
        port,
        username,
        compatibilityMode,
        zlibCompression,
        forwardAgent,
        keepAliveSeconds,
      ];

  factory ConnectParams.fromWire(List<Object?> w) => ConnectParams(
        host: w[0] as String,
        port: w[1] as int,
        username: w[2] as String,
        compatibilityMode: w[3] as bool,
        zlibCompression: w[4] as bool,
        forwardAgent: w[5] as bool,
        keepAliveSeconds: w[6] as int,
      );

  @override
  bool operator ==(Object other) =>
      other is ConnectParams &&
      other.host == host &&
      other.port == port &&
      other.username == username &&
      other.compatibilityMode == compatibilityMode &&
      other.zlibCompression == zlibCompression &&
      other.forwardAgent == forwardAgent &&
      other.keepAliveSeconds == keepAliveSeconds;

  @override
  int get hashCode => Object.hash(host, port, username, compatibilityMode,
      zlibCompression, forwardAgent, keepAliveSeconds);
}

// ─────────────────────────────────────────────────────────────────────────
// Commands: main isolate -> worker
// ─────────────────────────────────────────────────────────────────────────

const _connectCmd = 'connect';
const _writeCmd = 'write';
const _resizeCmd = 'resize';
const _disconnectCmd = 'disconnect';
const _hostKeyReplyCmd = 'hostKeyReply';
const _passwordReplyCmd = 'passwordReply';
const _userInfoReplyCmd = 'userInfoReply';
const _signInCancelCmd = 'signInCancel';

/// A message from the UI isolate to the connection worker. The leading wire tag
/// is a short string so a protocol mismatch fails loudly instead of a silent
/// index shift.
sealed class WorkerCommand {
  const WorkerCommand();

  List<Object?> toWire();

  static WorkerCommand fromWire(List<Object?> w) {
    final tag = w[0] as String;
    switch (tag) {
      case _connectCmd:
        return WorkerConnect(ConnectParams.fromWire(w[1] as List<Object?>));
      case _writeCmd:
        return WorkerWrite(w[1] as Uint8List);
      case _resizeCmd:
        return WorkerResize(w[1] as int, w[2] as int);
      case _disconnectCmd:
        return const WorkerDisconnect();
      case _hostKeyReplyCmd:
        return WorkerHostKeyReply(w[1] as int, w[2] as bool);
      case _passwordReplyCmd:
        return WorkerPasswordReply(w[1] as int, w[2] as String?);
      case _userInfoReplyCmd:
        return WorkerUserInfoReply(
          w[1] as int,
          (w[2] as List<Object?>).cast<String>(),
        );
      case _signInCancelCmd:
        return const WorkerSignInCancel();
      default:
        throw ArgumentError('Unknown WorkerCommand tag: $tag');
    }
  }
}

/// Dial + authenticate + open the shell. Sent once, after [WorkerReady].
class WorkerConnect extends WorkerCommand {
  final ConnectParams params;
  const WorkerConnect(this.params);
  @override
  List<Object?> toWire() => [_connectCmd, params.toWire()];
}

/// Terminal input (keystrokes / paste). Small and latency-critical.
class WorkerWrite extends WorkerCommand {
  final Uint8List data;
  const WorkerWrite(this.data);
  @override
  List<Object?> toWire() => [_writeCmd, data];
}

/// Terminal window resize.
class WorkerResize extends WorkerCommand {
  final int width;
  final int height;
  const WorkerResize(this.width, this.height);
  @override
  List<Object?> toWire() => [_resizeCmd, width, height];
}

/// Tear the connection down and let the worker exit.
class WorkerDisconnect extends WorkerCommand {
  const WorkerDisconnect();
  @override
  List<Object?> toWire() => const [_disconnectCmd];
}

/// The main-isolate answer to a [WorkerHostKeyRequest]. [id] correlates it with
/// the request. The worker acts only on this boolean; it never decides itself.
class WorkerHostKeyReply extends WorkerCommand {
  final int id;
  final bool accepted;
  const WorkerHostKeyReply(this.id, this.accepted);
  @override
  List<Object?> toWire() => [_hostKeyReplyCmd, id, accepted];
}

/// The main-isolate answer to a [WorkerPasswordRequest]. A null password means
/// "no password configured, skip the method" (mirrors the direct path).
class WorkerPasswordReply extends WorkerCommand {
  final int id;
  final String? password;
  const WorkerPasswordReply(this.id, this.password);
  @override
  List<Object?> toWire() => [_passwordReplyCmd, id, password];
}

/// The main-isolate answer to a [WorkerUserInfoRequest]: one response per
/// prompt, already run through the fail-closed rule on the main isolate.
class WorkerUserInfoReply extends WorkerCommand {
  final int id;
  final List<String> responses;
  const WorkerUserInfoReply(this.id, this.responses);
  @override
  List<Object?> toWire() => [_userInfoReplyCmd, id, responses];
}

/// The person cancelled the sign-in at the link of a [WorkerSignInNotice]
/// (3.4.1): the worker ends the sign-in, as the in-isolate path does
/// (SignInLinkBanners.orCancelled).
class WorkerSignInCancel extends WorkerCommand {
  const WorkerSignInCancel();
  @override
  List<Object?> toWire() => const [_signInCancelCmd];
}

// ─────────────────────────────────────────────────────────────────────────
// Events: worker -> main isolate
// ─────────────────────────────────────────────────────────────────────────

const _readyEvt = 'ready';
const _stdoutEvt = 'stdout';
const _stderrEvt = 'stderr';
const _stateEvt = 'state';
const _logEvt = 'log';
const _hostKeyReqEvt = 'hostKeyReq';
const _passwordReqEvt = 'passwordReq';
const _userInfoReqEvt = 'userInfoReq';
const _exitedEvt = 'exited';
const _errorEvt = 'error';
const _signInNoticeEvt = 'signInNotice';

/// A message from the connection worker back to the UI isolate.
sealed class WorkerEvent {
  const WorkerEvent();

  List<Object?> toWire();

  static WorkerEvent fromWire(List<Object?> w) {
    final tag = w[0] as String;
    switch (tag) {
      case _readyEvt:
        return const WorkerReady();
      case _stdoutEvt:
        return WorkerStdout(w[1] as Uint8List);
      case _stderrEvt:
        return WorkerStderr(w[1] as Uint8List);
      case _stateEvt:
        return WorkerConnectionState(w[1] as bool);
      case _logEvt:
        return WorkerLog(w[1] as String);
      case _hostKeyReqEvt:
        return WorkerHostKeyRequest(
            w[1] as int, w[2] as String, w[3] as Uint8List);
      case _passwordReqEvt:
        return WorkerPasswordRequest(w[1] as int);
      case _userInfoReqEvt:
        return WorkerUserInfoRequest(
          w[1] as int,
          w[2] as String,
          [
            for (final p in (w[3] as List<Object?>).cast<List<Object?>>())
              (promptText: p[0] as String, echo: p[1] as bool),
          ],
        );
      case _exitedEvt:
        return WorkerExited(w[1] as bool);
      case _errorEvt:
        return WorkerError(w[1] as String);
      case _signInNoticeEvt:
        return WorkerSignInNotice(w[1] as String, w[2] as String?);
      default:
        throw ArgumentError('Unknown WorkerEvent tag: $tag');
    }
  }
}

/// The worker isolate has booted and is ready to receive [WorkerConnect].
class WorkerReady extends WorkerEvent {
  const WorkerReady();
  @override
  List<Object?> toWire() => const [_readyEvt];
}

/// Terminal stdout bytes. The wire form is a plain [Uint8List]; the transport
/// wraps a firehose in `TransferableTypedData` for a zero-copy hand-off.
class WorkerStdout extends WorkerEvent {
  final Uint8List data;
  const WorkerStdout(this.data);
  @override
  List<Object?> toWire() => [_stdoutEvt, data];
}

/// Terminal stderr bytes.
class WorkerStderr extends WorkerEvent {
  final Uint8List data;
  const WorkerStderr(this.data);
  @override
  List<Object?> toWire() => [_stderrEvt, data];
}

/// Connection came up (true) or went down (false).
class WorkerConnectionState extends WorkerEvent {
  final bool connected;
  const WorkerConnectionState(this.connected);
  @override
  List<Object?> toWire() => [_stateEvt, connected];
}

/// A human-readable progress line for the connection log UI.
class WorkerLog extends WorkerEvent {
  final String message;
  const WorkerLog(this.message);
  @override
  List<Object?> toWire() => [_logEvt, message];
}

/// The server presented a host key. The main isolate must answer with a
/// [WorkerHostKeyReply] carrying the same [id]. [type] is the key algorithm and
/// [keyBlob] the raw key bytes, rebuilt into an `SSHHostKey` by the router.
class WorkerHostKeyRequest extends WorkerEvent {
  final int id;
  final String type;
  final Uint8List keyBlob;
  const WorkerHostKeyRequest(this.id, this.type, this.keyBlob);
  @override
  List<Object?> toWire() => [_hostKeyReqEvt, id, type, keyBlob];
}

/// The server asked for a password (direct `onPasswordRequest`). Answer with a
/// [WorkerPasswordReply] carrying the same [id].
class WorkerPasswordRequest extends WorkerEvent {
  final int id;
  const WorkerPasswordRequest(this.id);
  @override
  List<Object?> toWire() => [_passwordReqEvt, id];
}

/// The server asked keyboard-interactive prompts. Answer with a
/// [WorkerUserInfoReply] carrying the same [id]; each [WorkerAuthPrompt] is
/// resolved by the fail-closed rule on the main isolate.
class WorkerUserInfoRequest extends WorkerEvent {
  final int id;
  final String name;
  final List<WorkerAuthPrompt> prompts;
  const WorkerUserInfoRequest(this.id, this.name, this.prompts);
  @override
  List<Object?> toWire() => [
        _userInfoReqEvt,
        id,
        name,
        [
          for (final p in prompts) [p.promptText, p.echo],
        ],
      ];
}

/// The remote shell process exited. [clean] is true for a normal `exit`/Ctrl-D
/// (close the tab) versus a transport drop (auto-reconnect makes sense).
class WorkerExited extends WorkerEvent {
  final bool clean;
  const WorkerExited(this.clean);
  @override
  List<Object?> toWire() => [_exitedEvt, clean];
}

/// A fatal connection error to surface to the user.
class WorkerError extends WorkerEvent {
  final String message;
  const WorkerError(this.message);
  @override
  List<Object?> toWire() => [_errorEvt, message];
}

/// The server's login banner has an https link the sign-in waits on
/// (Tailscale SSH's check mode, 3.4.1): [text] is the banner as
/// `SignInNotice.of` cleaned it on the worker, where the banner arrived, and
/// [link] the link it offers. Sent only where a person watches the sign-in
/// (the bootstrap says so), once per sign-in; the worker has given the
/// server kSignInLinkPatience to answer. The main isolate shows it through
/// the session's notice shower and answers a cancel with
/// [WorkerSignInCancel]; no answer is needed otherwise.
class WorkerSignInNotice extends WorkerEvent {
  final String text;
  final String? link;
  const WorkerSignInNotice(this.text, this.link);
  @override
  List<Object?> toWire() => [_signInNoticeEvt, text, link];
}
