import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/services/hardware_token/windows_pipe_ffi.dart';
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';
import 'package:zestssh/utils/type_name.dart';

/// Agent protocol message-type constants (draft-miller-ssh-agent-04 §3).
abstract class _Msg {
  static const int agentcRemoveIdentity = 18;
  static const int agentcFailure = 5;
  static const int agentSuccess = 6;
  static const int agentcRequestIdentities = 11;
  static const int agentIdentitiesAnswer = 12;
  static const int agentcSignRequest = 13;
  static const int agentSignResponse = 14;
}

/// Sign-request flags. OpenSSH uses these to ask the agent for a
/// specific RSA hash variant (the one piece of info that's not encoded
/// in the key itself).
abstract class OsAgentSignFlags {
  /// `SSH_AGENT_RSA_SHA2_256` - request RSA-SHA-256.
  static const int rsaSha2_256 = 0x02;

  /// `SSH_AGENT_RSA_SHA2_512` - request RSA-SHA-512.
  static const int rsaSha2_512 = 0x04;
}

/// One identity the agent has loaded. The blob is the bare-key public
/// blob (`string algo || …`). The comment is a human-readable label
/// the agent passed back (`ssh-add -L`'s third column).
class OsAgentIdentity {
  OsAgentIdentity({required this.publicKeyBlob, required this.comment});
  final Uint8List publicKeyBlob;
  final String comment;

  /// Algorithm name encoded in the public-key blob. Returns null for
  /// malformed blobs (which are silently dropped - the agent could
  /// hold a key type we don't understand without breaking us).
  String? get algorithm {
    try {
      return SshWireReader(publicKeyBlob).readUtf8String(maxLength: 256);
    } catch (_) {
      return null;
    }
  }
}

/// Thrown when the OS agent isn't reachable or returns an error.
///
/// Wraps the original IO error / failure cause so callers can surface
/// a useful message ("agent isn't running", "permission denied on
/// socket", "agent refused to sign - touch your hardware key?").
class OsAgentException implements Exception, HasTypeName {
  OsAgentException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() {
    if (cause == null) return 'OsAgentException: $message';
    return 'OsAgentException: $message (cause: $cause)';
  }

  @override
  String get typeName => 'OsAgentException';
}

/// The agent's pipe on Windows is served by a program that is neither
/// Windows' own OpenSSH agent nor the person's, or by one Windows would not
/// name ([agentPipeServerVerdict]): nothing was sent to it, no key, no
/// request, not even a list request. Another account on the computer may be
/// waiting on the pipe's name for keys (found in a security
/// review).
class AgentPipeNotYours extends OsAgentException {
  AgentPipeNotYours(this.verdict)
      : super(verdict == AgentPipeServer.otherAccount
            ? "Refused the SSH agent's pipe: the program serving it runs as another account of this computer, "
                'neither LocalSystem (the OpenSSH Authentication Agent) nor this one. Nothing was sent to it.'
            : "Refused the SSH agent's pipe: Windows did not say which account's program serves it, so it could "
                'not be confirmed as the OpenSSH Authentication Agent or a program of this account. Nothing was sent '
                'to it.');

  final AgentPipeServer verdict;

  @override
  String get typeName => 'AgentPipeNotYours';
}

/// LocalSystem, the account Windows' OpenSSH Authentication Agent service
/// runs as.
const String kLocalSystemSid = 'S-1-5-18';

/// What is made of whoever serves the agent's pipe on Windows.
enum AgentPipeServer {
  /// Windows' own agent, or a program of the person's (1Password, Bitwarden).
  trusted,

  /// A program of another account of the computer.
  otherAccount,

  /// Windows would not say enough to tell.
  unconfirmed,
}

/// Whether the agent's pipe may be used, by who serves it ([who], as
/// [WindowsNamedPipe.serverIdentity] reads it). The OpenSSH Authentication
/// Agent runs as LocalSystem; 1Password and Bitwarden serve the same pipe
/// as the person's own program. So:
///
/// * Where the serving process's user is known, it decides: LocalSystem or
///   the person is trusted, any other account is not.
/// * Where it is not (a person's program may not open a service's process,
///   nor another account's), the pipe's owner decides, and only LocalSystem
///   is trusted: the OpenSSH agent's pipe is owned by SYSTEM (measured on
///   Windows 11, 5 November 2026: O:SY), and only a program with the powers
///   of an administrator can make a pipe owned by SYSTEM. Not Administrators,
///   which owns what an elevated program makes and is not how Windows' agent
///   makes its pipe; and not the person either: their own programs can be
///   opened, so a pipe owned by them whose server cannot be is one where
///   another program added a server of its own.
/// * Without the person's own user nothing is trusted.
AgentPipeServer agentPipeServerVerdict(PipeServerIdentity who) {
  final own = who.ownUser;
  if (own == null || own.isEmpty) return AgentPipeServer.unconfirmed;
  final user = who.serverProcessUser;
  if (user != null) {
    return user == own || user == kLocalSystemSid ? AgentPipeServer.trusted : AgentPipeServer.otherAccount;
  }
  final owner = who.pipeOwner;
  if (owner == null || owner == own) return AgentPipeServer.unconfirmed;
  return owner == kLocalSystemSid ? AgentPipeServer.trusted : AgentPipeServer.otherAccount;
}

/// Stands in for who serves the agent's pipe, given what Windows said: for
/// a test, which has no other account to serve a pipe as. Null in the app.
@visibleForTesting
PipeServerIdentity Function(PipeServerIdentity read)? debugAgentPipeServerIdentity;

/// What a sign-in through the system's agent says where SSH_AUTH_SOCK is not
/// set: what can be done from here. It said to point the identity at a
/// socket path, which no screen sets (found while checking the 3.0
/// docs); a password manager's agent is found where it listens.
const String kNoAgentSocketSaid = 'SSH_AUTH_SOCK is not set, so no ssh-agent can be reached. Start an '
    'ssh-agent and start ZestSSH from a shell where SSH_AUTH_SOCK is set '
    '(or sign in to the desktop again so that it has it), or add the key '
    "from 1Password's or Bitwarden's agent instead (Keys, Connect via "
    'ssh-agent).';

/// Bridge to the operating system's running ssh-agent.
///
/// On Linux / macOS we connect to the Unix domain socket at
/// `$SSH_AUTH_SOCK`. On Windows we open the named pipe
/// `\\.\pipe\openssh-ssh-agent` (the OpenSSH for Windows agent).
///
/// `OsSshAgent` instances are short-lived: open → use → close. Each
/// message is a single round-trip and the underlying stream stays
/// connected until [close] is called. We do NOT pool connections - the
/// agent expects a fresh transport per logical operation in the
/// general case, and pooling wins us very little for the kinds of
/// operations we issue (a couple of dozen total per app session).
abstract class OsSshAgent {
  /// Open a connection to the OS agent. Throws [OsAgentException] when
  /// no agent is available.
  ///
  /// [socketPath] overrides the default discovery (env var on Unix,
  /// `\\.\pipe\openssh-ssh-agent` on Windows). Useful for unit tests
  /// pointing at a temp socket and for users on exotic setups.
  static Future<OsSshAgent> open({String? socketPath}) async {
    if (Platform.isWindows) {
      return _WindowsPipeAgent.connect(
        socketPath ?? r'\\.\pipe\openssh-ssh-agent',
      );
    }
    final path = socketPath ?? Platform.environment['SSH_AUTH_SOCK'];
    if (path == null || path.isEmpty) {
      throw OsAgentException(kNoAgentSocketSaid);
    }
    // SECURITY: validate the socket file permissions before connecting.
    // A world-writable / wrong-owner socket means another local user
    // (or a compromised process) can MITM every signing request - we
    // refuse the connection rather than handing them our challenges.
    await _verifyUnixSocketSafety(path);
    return _UnixSocketAgent.connect(path);
  }

  /// Reject obviously-dangerous socket paths. The full Unix `stat()`
  /// (uid / gid checks) isn't reachable from `dart:io` without ffi,
  /// so we cover the easy-and-impactful cases:
  ///
  ///   * world-writable bit set → anyone can replace it
  ///   * group-writable bit set on a path that isn't in our $HOME →
  ///     a different group could MITM
  ///   * symlink whose target is in /tmp owned by anyone other than us
  ///     (best-effort - `readlink` plus owner check isn't directly
  ///     exposed either, so we only check world/group writability)
  ///
  /// On platforms where `FileStat.mode` returns 0 (some containers,
  /// some CI runners) we proceed - refusing to connect there breaks
  /// legitimate use, and the underlying agent socket is still
  /// authenticated by the kernel-level Unix socket peer credentials.
  static Future<void> _verifyUnixSocketSafety(String path) async {
    if (Platform.isWindows) return; // not applicable
    try {
      final stat = await FileStat.stat(path);
      final mode = stat.mode;
      if (mode == 0) return; // mode unavailable; trust the agent
      // World-writable (`o+w`)
      if ((mode & 0x002) != 0) {
        throw OsAgentException(
          'Refusing to connect to ssh-agent at "$path": socket is '
          'world-writable. A local attacker could replace it and '
          'intercept every signing request. Fix with:\n'
          '  chmod 600 "$path"',
        );
      }
      // Group-writable (`g+w`)
      if ((mode & 0x010) != 0) {
        throw OsAgentException(
          'Refusing to connect to ssh-agent at "$path": socket is '
          'group-writable. Other members of your primary group could '
          'replace it. Fix with:\n'
          '  chmod 600 "$path"',
        );
      }
    } on OsAgentException {
      rethrow;
    } catch (_) {
      // FileStat failed - usually because the path doesn't exist.
      // Let the connect attempt produce a clearer error.
    }
  }

  /// Probe whether an agent is reachable on the default socket. Pure
  /// IO best-effort - returns false on any error.
  static Future<bool> isAvailable({String? socketPath}) async {
    try {
      final agent = await open(socketPath: socketPath);
      try {
        await agent.listIdentities();
        return true;
      } finally {
        await agent.close();
      }
    } catch (_) {
      return false;
    }
  }

  /// List all identities the agent has loaded.
  Future<List<OsAgentIdentity>> listIdentities();

  /// Ask the agent to sign [data] with the key whose public-key blob
  /// is [keyBlob]. Returns the SSH-wire signature string (algorithm
  /// name + signature bytes, in the same shape `SSHSignature.encode`
  /// emits).
  ///
  /// [flags] follows [OsAgentSignFlags]. RSA keys: pick a hash; other
  /// types ignore.
  Future<Uint8List> sign({
    required Uint8List keyBlob,
    required Uint8List data,
    int flags = 0,
  });

  /// Close the underlying transport.
  Future<void> close();
}

/// Gives the agent a key to keep (3.0, Keys, Add to agent): [request] as
/// the core's `SSHAgentProtocol.addIdentityRequest` makes it. Throws
/// [OsAgentException] where the agent says no, or [agent] is not one of
/// the system's.
Future<void> addIdentityToOsAgent(OsSshAgent agent, Uint8List request) async {
  if (agent is! _OsSshAgentBase) throw OsAgentException('Not a system agent');
  final reply = await agent._request(request);
  if (reply.isEmpty || reply[0] != _Msg.agentSuccess) {
    throw OsAgentException('The agent did not take the key (reply ${reply.isEmpty ? 'empty' : 'type ${reply[0]}'})');
  }
}

/// Takes the key [publicKeyBlob] back from the agent. A key it no longer holds is no
/// failure. Throws [OsAgentException] where [agent] is not one of the system's.
Future<void> removeIdentityFromOsAgent(OsSshAgent agent, Uint8List publicKeyBlob) async {
  if (agent is! _OsSshAgentBase) throw OsAgentException('Not a system agent');
  final length = publicKeyBlob.length;
  await agent._request(Uint8List.fromList([
    _Msg.agentcRemoveIdentity,
    (length >> 24) & 0xff,
    (length >> 16) & 0xff,
    (length >> 8) & 0xff,
    length & 0xff,
    ...publicKeyBlob,
  ]));
}

/// Shared protocol logic. Subclasses provide a transport that exposes
/// `_sendBytes` / `_readBytes`; the request/response framing lives here.
abstract class _OsSshAgentBase implements OsSshAgent {
  bool _closed = false;

  Future<void> _sendBytes(Uint8List bytes);
  Future<Uint8List> _readExact(int count);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _doClose();
    } catch (_) {/* swallow - we're shutting down */}
  }

  Future<void> _doClose();

  @override
  Future<List<OsAgentIdentity>> listIdentities() async {
    final reqBody = Uint8List.fromList([_Msg.agentcRequestIdentities]);
    final resp = await _request(reqBody);
    final reader = SshWireReader(resp);
    final type = reader.readUint8();
    if (type == _Msg.agentcFailure) {
      throw OsAgentException('Agent refused listIdentities');
    }
    if (type != _Msg.agentIdentitiesAnswer) {
      throw OsAgentException('Unexpected agent reply: type $type');
    }
    final count = reader.readUint32();
    if (count > 1024) {
      // Sanity bound. Real agents never load this many.
      throw OsAgentException(
        'Implausible identity count $count - refusing to allocate.',
      );
    }
    final out = <OsAgentIdentity>[];
    for (var i = 0; i < count; i++) {
      final keyBlob = reader.readString(maxLength: 64 * 1024);
      final comment = reader.readUtf8String(maxLength: 4096);
      out.add(OsAgentIdentity(publicKeyBlob: keyBlob, comment: comment));
    }
    return out;
  }

  @override
  Future<Uint8List> sign({
    required Uint8List keyBlob,
    required Uint8List data,
    int flags = 0,
  }) async {
    final body = SshWireWriter()
      ..writeUint8(_Msg.agentcSignRequest)
      ..writeString(keyBlob)
      ..writeString(data)
      ..writeUint32(flags);
    final resp = await _request(body.takeBytes());
    final reader = SshWireReader(resp);
    final type = reader.readUint8();
    if (type == _Msg.agentcFailure) {
      throw OsAgentException(
        'Agent refused to sign - possible causes: the key isn\'t '
        'loaded, the device requires a touch you didn\'t give, the '
        'PIN was wrong, or the connection to the FIDO2 token timed '
        'out.',
      );
    }
    if (type != _Msg.agentSignResponse) {
      throw OsAgentException('Unexpected agent reply: type $type');
    }
    final sig = reader.readString(maxLength: 64 * 1024);
    return sig;
  }

  /// Wire one request/response round-trip.
  Future<Uint8List> _request(Uint8List body) async {
    if (_closed) {
      throw OsAgentException('Agent connection is closed');
    }
    final framed = _frame(body);
    await _sendBytes(framed);

    final lengthBytes = await _readExact(4);
    final length = (lengthBytes[0] << 24) |
        (lengthBytes[1] << 16) |
        (lengthBytes[2] << 8) |
        lengthBytes[3];
    // Realistic upper bound. listIdentities responses are ~100 bytes
    // per loaded key (key blob + comment); a workstation with 50 keys
    // tops out at ~10 KB. Sign responses are ≤ 8 KB even for
    // RSA-8192. A frame >256 KiB is either a buggy / hostile agent,
    // so we cap there rather than allowing a multi-MB allocation
    // a malicious local agent could trick us into.
    const maxFrame = 256 * 1024;
    if (length < 0 || length > maxFrame) {
      throw OsAgentException(
          'Implausible frame length $length from agent - refusing to '
          'allocate. The agent may be buggy or hostile.');
    }
    return _readExact(length);
  }

  /// Apply the 4-byte length prefix.
  static Uint8List _frame(Uint8List body) {
    final out = Uint8List(4 + body.length);
    out[0] = (body.length >> 24) & 0xFF;
    out[1] = (body.length >> 16) & 0xFF;
    out[2] = (body.length >> 8) & 0xFF;
    out[3] = body.length & 0xFF;
    out.setRange(4, 4 + body.length, body);
    return out;
  }
}

// ── Unix domain socket transport ─────────────────────────────────

class _UnixSocketAgent extends _OsSshAgentBase {
  _UnixSocketAgent._(this._socket) {
    _subscription = _socket.listen(_onData,
        onError: _onError, onDone: _onDone, cancelOnError: false);
  }

  static Future<_UnixSocketAgent> connect(String path) async {
    try {
      final socket = await Socket.connect(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
      return _UnixSocketAgent._(socket);
    } on SocketException catch (e) {
      throw OsAgentException(
          'Could not connect to ssh-agent at "$path": ${e.message}', e);
    }
  }

  final Socket _socket;
  late final StreamSubscription<Uint8List> _subscription;
  final List<_SizedWaiter> _waiters = [];
  final List<int> _readBuffer = [];
  Object? _streamError;
  bool _streamDone = false;

  void _onData(List<int> chunk) {
    _readBuffer.addAll(chunk);
    _drainWaiters();
  }

  void _onError(Object err, [StackTrace? st]) {
    _streamError = err;
    _drainWaiters();
  }

  void _onDone() {
    _streamDone = true;
    _drainWaiters();
  }

  void _drainWaiters() {
    while (_waiters.isNotEmpty) {
      final w = _waiters.first;
      final need = w.count;
      if (_readBuffer.length >= need) {
        _waiters.removeAt(0);
        final out = Uint8List(need);
        for (var i = 0; i < need; i++) {
          out[i] = _readBuffer[i];
        }
        _readBuffer.removeRange(0, need);
        w.completer.complete(out);
        continue;
      }
      if (_streamError != null) {
        _waiters.removeAt(0);
        w.completer.completeError(_streamError!);
        continue;
      }
      if (_streamDone) {
        _waiters.removeAt(0);
        w.completer.completeError(
          OsAgentException(
              'Agent closed the connection while we were waiting on $need bytes'),
        );
        continue;
      }
      return;
    }
  }

  @override
  Future<void> _sendBytes(Uint8List bytes) async {
    _socket.add(bytes);
    await _socket.flush();
  }

  @override
  Future<Uint8List> _readExact(int count) {
    final completer = Completer<Uint8List>();
    _waiters.add(_SizedWaiter(count, completer));
    _drainWaiters();
    return completer.future;
  }

  @override
  Future<void> _doClose() async {
    await _subscription.cancel();
    await _socket.close();
    _socket.destroy();
  }
}

class _SizedWaiter {
  _SizedWaiter(this.count, this.completer);
  final int count;
  final Completer<Uint8List> completer;
}

// ── Windows named-pipe transport ─────────────────────────────────

class _WindowsPipeAgent extends _OsSshAgentBase {
  _WindowsPipeAgent._(this._pipe);

  /// Open the named pipe via direct Win32 `CreateFileW`.
  ///
  /// Why FFI: `dart:io`'s `File('\\.\pipe\…').open()` fails with
  /// `ERROR_BAD_NETPATH (53)` because Dart's path normaliser routes
  /// the `\\.\` prefix through SMB resolution. Every other SSH tool
  /// on the system (`ssh`, `ssh-add`, `git`) calls `CreateFileW`
  /// directly with the canonical pipe path and works fine. We do
  /// the same via [WindowsNamedPipe.open] (see windows_pipe_ffi.dart).
  ///
  /// SECURITY: Windows lets any account of the computer create the pipe
  /// `\\.\pipe\openssh-ssh-agent` while no agent holds it (pipe names are
  /// one namespace for the whole machine, first come first served), and the
  /// protocol probe below is passed by any program that speaks it. So the
  /// pipe is opened with identification-only flags (the server can never
  /// act as the person: [kPipeOpenSecurityFlags]), and before a byte is
  /// sent, who serves it is asked of Windows and judged by
  /// [agentPipeServerVerdict]: Windows' own agent (LocalSystem) or a program
  /// of the person's, else [AgentPipeNotYours] and the pipe is closed. Every
  /// use of the agent comes through here: listing, signing in, Add to agent,
  /// taking a key back (a security review
  /// found a private key given to whatever served the pipe).
  static Future<_WindowsPipeAgent> connect(String pipePath) async {
    try {
      final pipe = WindowsNamedPipe.open(pipePath);
      final AgentPipeServer verdict;
      try {
        final read = pipe.serverIdentity();
        verdict = agentPipeServerVerdict(debugAgentPipeServerIdentity?.call(read) ?? read);
      } catch (_) {
        pipe.close();
        rethrow;
      }
      if (verdict != AgentPipeServer.trusted) {
        pipe.close();
        throw AgentPipeNotYours(verdict);
      }
      final agent = _WindowsPipeAgent._(pipe);
      // Probe the protocol. If the responder isn't speaking the
      // SSH-agent protocol we throw; the caller closes the pipe.
      try {
        await agent._probe();
      } catch (_) {
        await agent.close();
        rethrow;
      }
      return agent;
    } on WindowsPipeException catch (e) {
      throw OsAgentException(
        'Could not open OpenSSH agent pipe "$pipePath". ${e.message}',
        e,
      );
    } on OsAgentException {
      rethrow;
    } catch (e) {
      throw OsAgentException(
        'Could not open OpenSSH agent pipe "$pipePath". '
        'Make sure the OpenSSH Authentication Agent service is '
        'running ("Get-Service ssh-agent").',
        e,
      );
    }
  }

  /// Issue a list-identities request and verify the response shape
  /// before letting any caller use this connection. Cheap (a few KB). It
  /// says only that the server speaks the protocol, which any program can:
  /// who the server is was decided before it ([agentPipeServerVerdict]).
  Future<void> _probe() async {
    final probe = await listIdentities();
    for (final id in probe) {
      final algo = id.algorithm;
      if (algo == null) {
        throw OsAgentException(
          'Pipe responder produced an identity with no algorithm '
          'string - refusing to trust it.',
        );
      }
      if (algo.length > 64 || !_looksLikeSshAlgoName(algo)) {
        throw OsAgentException(
          'Pipe responder produced a suspicious algorithm name '
          '"$algo" - refusing to trust it.',
        );
      }
    }
  }

  /// Quick algorithm-name allow-list. Just enough to rule out
  /// random garbage / non-ASCII.
  static bool _looksLikeSshAlgoName(String s) {
    if (s.isEmpty) return false;
    return RegExp(r'^[A-Za-z0-9@\.\-]+$').hasMatch(s);
  }

  final WindowsNamedPipe _pipe;

  @override
  Future<void> _sendBytes(Uint8List bytes) async {
    // FFI is synchronous; bytes <= 256 KiB by our cap, so doing it
    // off the event loop is overkill. If we ever see UI jank from
    // this we can wrap in `Isolate.run`.
    _pipe.write(bytes);
  }

  @override
  Future<Uint8List> _readExact(int count) async {
    return _pipe.readExact(count);
  }

  @override
  Future<void> _doClose() async {
    try {
      _pipe.close();
    } catch (_) {/* pipe might be already gone */}
  }
}
