import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;
import 'package:zestssh/services/ssh_cert/ssh_wire.dart';

import 'os_ssh_agent.dart';

/// A sign-in that was ended because the SSH agent, or the hardware key
/// behind it, that holds the sign-in's key did not sign for it. It ends the
/// sign-in for good (an [SSHAuthAbortError]): what else the sign-in could
/// offer, a saved password among it, is not tried in the key's place, which
/// is what breaking an agent would otherwise be good for.
///
/// Whatever shows the failure says it in the app's words, by
/// [keyNotLoaded]; the message is for the connection's log. (It was an
/// error with an English text and no kind, which was shown as a key that
/// the server had rejected.)
class AgentSignInAborted extends SSHAuthAbortError {
  /// The agent was reached and does not hold the key any more: it was
  /// removed from it, or another hardware key is plugged in.
  AgentSignInAborted.keyNotLoaded()
      : keyNotLoaded = true,
        pipeNotYours = false,
        super('The key of this sign-in is no longer loaded in the SSH agent (removed, or another one is in its '
            'place). No other way of signing in was tried in its place.');

  /// The agent was not reached, refused to sign (a touch that was not
  /// given, a wrong PIN), or answered with what is no signature: [detail]
  /// says which, in the agent's words or the system's.
  AgentSignInAborted.couldNotSign(String detail)
      : keyNotLoaded = false,
        pipeNotYours = false,
        super('The SSH agent or hardware key did not sign: $detail. No other way of signing in was tried in its '
            'place.');

  /// On Windows, the agent's pipe is served by another account's program, or
  /// by one Windows would not name ([AgentPipeNotYours], [detail] its words):
  /// nothing was asked of it.
  AgentSignInAborted.pipeNotYours(String detail)
      : keyNotLoaded = false,
        pipeNotYours = true,
        super('$detail No other way of signing in was tried in its place.');

  /// Whether the agent answered, and no longer has the key.
  final bool keyNotLoaded;

  /// Whether the agent's pipe was refused for who serves it.
  final bool pipeNotYours;
}

/// `SSHKeyPair` whose private key lives in an external ssh-agent
/// (OpenSSH agent / FIDO2 token / smart card / PKCS#11). All signing
/// is proxied through [OsSshAgent.sign]; this object never holds key
/// material.
///
/// One instance per *agent identity* - i.e. per public-key blob the
/// agent advertised. The instance keeps no persistent socket; it
/// opens a fresh connection for each [signAsync] call. That avoids
/// long-lived state we'd have to clean up on identity hot-reload and
/// matches how `ssh -A` behaves.
class OsAgentKeyPair extends SSHKeyPair implements SSHRsaSignatureChoice {
  OsAgentKeyPair({
    required Uint8List publicKeyBlob,
    required this.algorithm,
    this.comment,
    this.socketPath,
    String rsaSignature = SSHRsaSignatureType.sha256,
  })  : _publicKeyBlob = Uint8List.fromList(publicKeyBlob),
        rsaSignature = SSHRsaSignatureType.known(rsaSignature);

  /// The kind of signature an RSA key in the agent is asked for
  /// ([SSHRsaSignatureType]): with SHA-256, unless the key was made to sign
  /// otherwise ([signingAsRsa]). Of no meaning for a key of another kind.
  final String rsaSignature;

  /// An RSA key in an agent makes the three kinds of RSA signature, by what
  /// the agent is asked for; a key of another kind makes none.
  @override
  List<String> get rsaSignatureTypes => algorithm == 'ssh-rsa' ? SSHRsaSignatureType.all : const [];

  @override
  SSHKeyPair signingAsRsa(String type) => OsAgentKeyPair(
        publicKeyBlob: _publicKeyBlob,
        algorithm: algorithm,
        comment: comment,
        socketPath: socketPath,
        rsaSignature: type,
      );

  /// SSH-wire algorithm name, e.g. `ssh-ed25519`,
  /// `sk-ecdsa-sha2-nistp256@openssh.com`, …
  final String algorithm;

  /// Comment string the agent attached (often the original key's
  /// `id_*-pub` comment - usually `user@host`). Surface in identity UI.
  final String? comment;

  /// Override path for the agent socket. When null we use the
  /// platform default (`SSH_AUTH_SOCK` on Unix; the OpenSSH for
  /// Windows pipe on Windows).
  final String? socketPath;

  final Uint8List _publicKeyBlob;

  /// What answers as the agent, for tests (which have no agent to talk to,
  /// and no hardware key to touch). It is called in the isolate the signing
  /// is done in, so it has to be a top-level function. Null in the app.
  @visibleForTesting
  static Future<OsSshAgent> Function({String? socketPath})? debugOpenAgent;

  /// Public-key blob exactly as the agent gave it to us. Used as the
  /// cache key the agent's `SIGN_REQUEST` matches against.
  Uint8List get publicKeyBlob => Uint8List.fromList(_publicKeyBlob);

  @override
  String get name => algorithm;

  @override
  String get type {
    // The userauth request advertises `type` as the SIGNATURE algorithm. For an
    // RSA agent key that is the kind of signature the agent is asked for
    // ([rsaSignature]: rsa-sha2-256 unless the SSH core picked another for the
    // host at hand) - otherwise the server rejects a pkalg/sigtype mismatch
    // (RFC 8332). The public-key blob (toPublicKey) stays "ssh-rsa"; only the
    // algorithm name changes. Every other key type signs under its own name.
    if (algorithm == 'ssh-rsa') return rsaSignature;
    return algorithm;
  }

  @override
  core_hk.SSHHostKey toPublicKey() => _AgentHostKey(_publicKeyBlob);

  @override
  SSHSignature sign(Uint8List data) {
    // Agent-backed keys cannot sign synchronously - the userauth path
    // always goes through [signAsync]. Throwing here makes accidental
    // misuse loud instead of silently blocking the event loop.
    throw UnsupportedError(
      'OsAgentKeyPair.sign(): agent-backed keys must use signAsync(). '
      'Hardware-token signing requires socket IO and (for FIDO2) a '
      'physical user-presence test, neither of which is possible '
      'inside a synchronous call.',
    );
  }

  @override
  Future<SSHSignature> signAsync(Uint8List data) async {
    // Run the ENTIRE agent round-trip (open → verify-still-loaded → sign →
    // close) in a background isolate. The Windows named-pipe transport reads
    // synchronously via FFI and BLOCKS until the user physically touches the
    // FIDO2 token - doing that on the main isolate freezes the whole UI for the
    // seconds the user spends reaching for the key. A native pipe handle can't
    // cross an isolate boundary, so the entire open/sign/close lives inside.
    //
    // The isolate returns a plain sendable record and NEVER throws across the
    // boundary (exception objects may carry non-sendable native causes). The
    // typed, fail-closed [SSHAuthAbortError] is (re)thrown HERE in the main
    // isolate, so the userauth path's terminal-abort semantics are unchanged.
    //
    // FAIL-CLOSED: the whole body is wrapped so ANY unexpected failure - an
    // Isolate.run spawn/exit failure, OR a FormatException from _AgentSignature
    // validating a malformed blob (incl. a hostile/name-squatting agent's
    // signature) - becomes a terminal SSHAuthAbortError rather than a plain
    // error the SSH client treats as "try the next method" and silently
    // downgrades to password auth.
    try {
    final socketPathLocal = socketPath;
    final keyBlob = _publicKeyBlob;
    final openAgent = debugOpenAgent ?? OsSshAgent.open;
    // RSA signing wants a hash flag: the one of the kind of signature the key
    // was asked about as ([rsaSignature]). With no flag an agent makes the
    // first kind, with SHA-1. Ignored for non-RSA algorithms.
    final signFlags = algorithm != 'ssh-rsa'
        ? 0
        : switch (rsaSignature) {
            SSHRsaSignatureType.sha512 => OsAgentSignFlags.rsaSha2_512,
            SSHRsaSignatureType.sha256 => OsAgentSignFlags.rsaSha2_256,
            _ => 0,
          };

    final result =
        await Isolate.run<({Uint8List? sig, String? errKind, String? errMsg})>(
      () async {
        try {
          final agent = await openAgent(socketPath: socketPathLocal);
          try {
            // SECURITY: re-enumerate the agent and verify our public-key blob
            // is still loaded before signing. Mitigates the "user removed the
            // YubiKey, attacker plugged in a different one" swap - the new key
            // has a different public blob, so a missing match aborts rather
            // than signing with whatever key is loaded.
            final loaded = await agent.listIdentities();
            final found =
                loaded.any((id) => _bytesEqual(id.publicKeyBlob, keyBlob));
            if (!found) {
              return (sig: null, errKind: 'not-loaded', errMsg: null);
            }
            final sig = await agent.sign(
              keyBlob: keyBlob,
              data: data,
              flags: signFlags,
            );
            return (sig: sig, errKind: null, errMsg: null);
          } finally {
            await agent.close();
          }
        } on AgentPipeNotYours catch (e) {
          return (sig: null, errKind: 'not-yours', errMsg: e.message);
        } on OsAgentException catch (e) {
          return (sig: null, errKind: 'agent', errMsg: e.message);
        } catch (e) {
          return (sig: null, errKind: 'agent', errMsg: e.toString());
        }
      },
    );

    if (result.errKind == 'not-loaded') throw AgentSignInAborted.keyNotLoaded();
    if (result.errKind == 'not-yours') throw AgentSignInAborted.pipeNotYours('${result.errMsg}');
    final sig = result.sig;
    if (sig == null) {
      // SECURITY: hardware-token failures are TERMINAL. Never silently fall
      // back to password auth (the obvious downgrade an attacker would force by
      // breaking the agent socket). SSHAuthAbortError aborts the connection.
      throw AgentSignInAborted.couldNotSign('${result.errMsg}');
    }
    return _AgentSignature(sig);
    } on SSHAuthAbortError {
      // Already terminal - propagate unchanged.
      rethrow;
    } catch (e) {
      // FAIL CLOSED on anything else: an Isolate.run spawn/exit failure, or a
      // malformed-signature FormatException from _AgentSignature (incl. a
      // hostile agent's blob). Convert to a terminal abort so the SSH client
      // can NEVER downgrade to password auth on a hardware-token anomaly.
      throw AgentSignInAborted.couldNotSign('$e');
    }
  }

  /// Constant-time byte comparison, used by the identity-still-loaded
  /// check so timing doesn't leak which prefix matched.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  @override
  String toPem() {
    // There IS no exportable PEM for an agent-backed key - that's the
    // whole point. Surface a clear error so backup / export code paths
    // don't silently produce a useless string.
    throw UnsupportedError(
      'OsAgentKeyPair.toPem(): the private key lives in an external '
      'agent and cannot be exported. Export the public key instead, '
      'or re-create the key using a software keypair.',
    );
  }
}

/// Pre-encoded host key blob backed by raw bytes from the agent. We
/// trust the agent's framing - all we have to do is hand the bytes
/// back during userauth.
class _AgentHostKey implements core_hk.SSHHostKey {
  _AgentHostKey(this._encoded);
  final Uint8List _encoded;

  @override
  Uint8List encode() => _encoded;
}

/// Pre-encoded signature blob coming from the agent's `SIGN_RESPONSE`.
/// Already in the right wire format (`string algo || string sig_bytes`)
/// so we just hand it to the SSH client.
///
/// We fully validate the blob on construction:
///  * algorithm name is parseable and ≤ 256 bytes
///  * algorithm name is in our known-good list (rules out gibberish)
///  * signature bytes is a length-prefixed string that fits the cap
///  * no trailing bytes (would indicate the agent is buggy or malicious)
///
/// Skipping any of these would let a hostile agent ship a signature
/// the SSH server then rejects, leaving the user confused about why
/// their hardware token "doesn't work".
class _AgentSignature implements SSHSignature {
  _AgentSignature(this._encoded) {
    _validate();
  }

  void _validate() {
    final reader = SshWireReader(_encoded);
    final String algo;
    try {
      algo = reader.readUtf8String(maxLength: 256);
    } catch (e) {
      throw FormatException(
          'Agent returned a signature with no algorithm string: $e');
    }
    if (!_knownSignatureAlgos.contains(algo)) {
      throw FormatException(
        'Agent returned signature with unknown algorithm "$algo". '
        'This may indicate a version mismatch between ZestSSH and '
        'the agent, or a hostile agent attempting to inject '
        'arbitrary data. Refusing to forward to server.',
      );
    }
    try {
      reader.readString(maxLength: 64 * 1024);
    } catch (e) {
      throw FormatException(
          'Agent signature has malformed signature bytes: $e');
    }
    // FIDO2 (sk-*) signatures legitimately carry a trailing
    // `byte flags || uint32 counter` (5 bytes, OpenSSH PROTOCOL.u2f) AFTER the
    // inner signature string. Those bytes ARE part of what the server verifies,
    // so they must be forwarded intact (encode() hands back the raw blob) - not
    // rejected as "trailing garbage". Every other algorithm ends exactly at the
    // signature string.
    if (_skSignatureAlgos.contains(algo)) {
      if (reader.remaining != 5) {
        throw FormatException(
          'FIDO signature blob has ${reader.remaining} trailing bytes after '
          'the signature field; expected exactly 5 (flags + counter). '
          'Refusing to forward a malformed signature to the server.',
        );
      }
      return;
    }
    if (!reader.isExhausted) {
      throw FormatException(
        'Agent signature blob has ${reader.remaining} trailing bytes '
        'after the algorithm + signature fields - refusing to forward '
        'a malformed signature to the server.',
      );
    }
  }

  /// FIDO2 algorithms whose signatures carry a trailing flags+counter tail.
  static const Set<String> _skSignatureAlgos = {
    'sk-ssh-ed25519@openssh.com',
    'sk-ecdsa-sha2-nistp256@openssh.com',
  };

  /// Set of signature algorithm names we recognise. Anything outside
  /// this list is rejected by [_validate]; expand here when adding
  /// new key types.
  static const Set<String> _knownSignatureAlgos = {
    'ssh-rsa',
    'rsa-sha2-256',
    'rsa-sha2-512',
    'ssh-dss',
    'ecdsa-sha2-nistp256',
    'ecdsa-sha2-nistp384',
    'ecdsa-sha2-nistp521',
    'ssh-ed25519',
    'sk-ssh-ed25519@openssh.com',
    'sk-ecdsa-sha2-nistp256@openssh.com',
  };

  final Uint8List _encoded;

  @override
  Uint8List encode() => _encoded;
}
