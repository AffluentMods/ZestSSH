import 'dart:typed_data';

import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';

/// One keyboard-interactive prompt as it crosses the worker<->UI boundary: the
/// prompt text plus whether the field echoes. A plain value record so it
/// serializes over a `SendPort` without any reference to the SSH library's own
/// request type.
typedef WorkerAuthPrompt = ({String promptText, bool echo});

/// Main-isolate owner of the interactive SSH callbacks for a worker-hosted
/// connection (Design B, Phase 1).
///
/// SECURITY - this is the seam that keeps a worker isolate from ever making a
/// trust or credential decision. In Design B the connection worker owns only
/// the socket and the SSH state machine; every host-key check, password answer,
/// and keyboard-interactive response is DECIDED HERE, on the isolate that owns
/// the SQLCipher known-hosts DB and the prompt UI, and only the boolean/string
/// result crosses back over the port.
///
/// The critical invariant: a worker CANNOT self-approve a host key. Its
/// `onVerifyHostKey` callback can only post a `verifyHostKey` request and await
/// the reply; it has no [KnownHostsService], no DAO, and no reference to this
/// router, so there is no code path by which it returns `true` on its own. The
/// host-key-change regression test
/// (`test/services/worker_hostkey_gate_test.dart`) is the merge gate for this
/// property.
class SshCallbackRouter {
  /// The target endpoint the worker is connecting to. Host-key trust is keyed
  /// by THIS identity (never anything the worker sends), so a worker cannot ask
  /// us to verify a different host than the one we dialed.
  final String host;
  final int port;

  /// The real host-key verifier: the SAME `_buildHostKeyVerifier()` closure the
  /// in-isolate [SshService] path uses. It runs [KnownHostsService.verify]
  /// (TOFU / changed-key / key-type-change / `viaScope` route scoping) and
  /// drives the accept/reject prompt. Injected, never reconstructed here, so the
  /// worker path and the direct path cannot drift apart.
  final HostKeyVerifyCallback onHostKeyVerify;

  /// The account password for direct-password / keyboard-interactive auth.
  ///
  /// Held on the MAIN isolate only; it never crosses to the worker. The worker
  /// forwards each auth prompt to this router and receives only the answer, so
  /// the credential-protection rule ([isRealPasswordPrompt]) always runs here.
  final String? password;

  final ConnectionLogCallback? onLog;

  SshCallbackRouter({
    required this.host,
    required this.port,
    required this.onHostKeyVerify,
    this.password,
    this.onLog,
  }) : _answerer = KeyboardInteractiveAnswerer(password: password, onLog: onLog);

  /// The same answerer the in-isolate path uses, with nobody to ask: the
  /// worker path does not show server questions yet, so anything other than
  /// a real password prompt fails closed.
  final KeyboardInteractiveAnswerer _answerer;

  /// Whether a password is configured. The worker asks this before advertising
  /// the password / keyboard-interactive auth methods, so the decision to
  /// attempt password auth at all stays on the main isolate (mirrors the direct
  /// path, which only wires `onPasswordRequest` / `onUserInfoRequest` when a
  /// password is present).
  bool get hasPassword => password != null;

  /// Answer a worker `verifyHostKey` request. Reconstructs the [SSHHostKey] from
  /// the wire bytes and defers the ENTIRE decision to [onHostKeyVerify] against
  /// OUR [host]/[port]. This is byte-for-byte the wrapper the in-isolate path
  /// runs inside `SshService._authenticate`.
  Future<bool> verifyHostKey(String type, Uint8List keyBlob) async {
    onLog?.call('ssh_hostkey: Verifying host key ($type)');
    final hostKey = SSHHostKey(type: type, bytes: keyBlob);
    final accepted = await onHostKeyVerify(host, port, hostKey);
    onLog?.call(accepted
        ? 'ssh_hostkey: Host key accepted'
        : 'ssh_hostkey: Host key REJECTED');
    return accepted;
  }

  /// Answer a worker password request (direct `onPasswordRequest`). Null when no
  /// password is configured (publickey-only), which tells the worker to skip the
  /// password method entirely.
  String? passwordRequest() {
    if (password == null) return null;
    onLog?.call('ssh_auth: Sending credentials');
    return password;
  }

  /// Answer a worker keyboard-interactive request with the SAME fail-closed rule
  /// the direct path uses ([isRealPasswordPrompt]): the account password goes
  /// ONLY to a genuine, non-echoed password prompt; every other prompt (2FA/OTP,
  /// verification codes, echoed fields) gets an empty string so the password is
  /// never leaked to a server-controlled prompt. With no password configured,
  /// every prompt is answered empty (fail closed).
  List<String> userInfoResponse(String name, List<WorkerAuthPrompt> prompts) {
    return _answerer.answerUnattended([
      for (final p in prompts) (text: p.promptText, echo: p.echo),
    ]);
  }
}
