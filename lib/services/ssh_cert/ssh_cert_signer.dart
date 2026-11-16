import 'dart:math';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';

import 'ssh_certificate.dart';
import 'ssh_wire.dart';

/// Parameters describing the cert about to be issued.
class SshCertIssueParams {
  SshCertIssueParams({
    required this.subjectPublicKeyBlob,
    required this.subjectAlgorithm,
    required this.serial,
    required this.type,
    required this.keyId,
    required this.principals,
    required this.validAfter,
    this.validBefore,
    this.criticalOptions = const {},
    this.extensions,
  });

  /// The subject's public key blob - i.e. the bytes that
  /// `<keytype-public-key>::encode()` returns. For Ed25519 it's
  /// `string ssh-ed25519 || string pk`. For RSA it's `string ssh-rsa
  /// || mpint e || mpint n`. We strip the leading algorithm-name
  /// string when building the cert (the cert algorithm name takes
  /// its place).
  final Uint8List subjectPublicKeyBlob;

  /// Subject's bare-key algorithm. Determines which `*-cert-v01@*`
  /// algorithm we encode as.
  final SshCertAlgorithm subjectAlgorithm;

  final int serial;
  final SshCertType type;
  final String keyId;
  final List<String> principals;

  /// Issue time. Defaults to "now" upstream; passed in explicitly
  /// here so callers can issue back-dated certs for testing.
  final DateTime validAfter;

  /// Expiry. `null` means "never expires" - encoded as
  /// 0xFFFFFFFFFFFFFFFF on the wire.
  final DateTime? validBefore;

  /// Critical-options key/value list. Unknown options force the
  /// server to reject the cert.
  final Map<String, Uint8List> criticalOptions;

  /// Extensions list. When `null`, the standard "permit-*" defaults
  /// are emitted (matches `ssh-keygen -s` defaults). Pass `{}` for an
  /// explicitly-empty list (no permits → very locked-down cert).
  final Map<String, Uint8List>? extensions;
}

/// Issues OpenSSH SSH user certificates by signing a to-be-signed
/// blob with the CA's private key.
///
/// Pure crypto - no UI, no IO. The caller is responsible for unlocking
/// the CA key (passphrase / agent), supplying the bytes, and persisting
/// the result.
class SshCertSigner {
  SshCertSigner._();

  /// Issue a fresh cert. Returns the full cert blob (signature
  /// included) - base64-encode + prefix with `<cert-algo>` to land on
  /// the OpenSSH `id_*-cert.pub` format.
  static Uint8List issue({
    required SshCertIssueParams params,
    required SSHKeyPair caKey,
  }) {
    _validateParams(params);

    // Spec says the nonce is 32 random bytes. Use [Random.secure] -
    // never [Random()]. The nonce is the ONLY thing that prevents
    // an attacker from producing two identical-content cert blobs
    // with the same signature, so weak randomness here is a real
    // problem (not just defense-in-depth).
    final nonce = _randomNonce(32);

    // Build the certificate body up to and including signatureKey.
    // Everything before `signature` is the to-be-signed payload.
    final w = SshWireWriter();
    w.writeUtf8String(params.subjectAlgorithm.name);
    w.writeString(nonce);
    _writeKeyParts(w, params);
    w.writeUint64(params.serial);
    w.writeUint32(params.type.wire);
    w.writeUtf8String(params.keyId);
    w.writeString(_encodePrincipals(params.principals));
    w.writeUint64(_unixSeconds(params.validAfter));
    w.writeUint64(_validBeforeWire(params.validBefore));
    w.writeString(_encodeOptions(_sortByKey(params.criticalOptions)));
    w.writeString(_encodeOptions(
      _sortByKey(params.extensions ?? _defaultExtensions()),
    ));
    w.writeString(const <int>[]); // reserved (always empty per spec)
    w.writeString(caKey.toPublicKey().encode());

    final toBeSigned = w.takeBytes();

    // Sign using the CA's private key. The fork's `SSHKeyPair.sign`
    // returns a fully-formed `SSHSignature` (algorithm name +
    // signature bytes); we serialise it as the standard SSH
    // signature wire format and append it to the cert.
    final signature = caKey.sign(toBeSigned).encode();

    final out = SshWireWriter();
    out.writeBytes(toBeSigned);
    out.writeString(signature);
    return out.takeBytes();
  }

  /// Render the cert as a single OpenSSH `id_*-cert.pub` line:
  ///   `<algo> <base64(blob)> <key-id>`
  /// Suitable for placement in `~/.ssh/`.
  static String toOpenSshLine(Uint8List certBlob, {String? comment}) {
    // Quick algorithm peek so we can prefix without a full re-parse.
    final reader = SshWireReader(certBlob);
    final algo = reader.readUtf8String(maxLength: 256);
    final encoded = _base64NoNewlines(certBlob);
    final commentPart = (comment == null || comment.isEmpty)
        ? ''
        : ' ${comment.replaceAll(RegExp(r'\s+'), '_')}';
    return '$algo $encoded$commentPart';
  }

  // ── Helpers ──────────────────────────────────────────────────────

  static void _validateParams(SshCertIssueParams p) {
    if (p.serial < 0) {
      throw ArgumentError.value(
          p.serial, 'serial', 'cert serial must be ≥ 0');
    }
    if (p.keyId.length > 4096) {
      throw ArgumentError.value(
          p.keyId.length, 'keyId.length', 'key id capped at 4096 bytes');
    }
    for (final principal in p.principals) {
      if (principal.isEmpty) {
        throw ArgumentError.value(principal, 'principals',
            'empty principal - refusing to issue');
      }
      if (principal.length > 256) {
        throw ArgumentError.value(principal, 'principals',
            'principal longer than 256 chars; refusing to issue');
      }
    }
    if (p.validBefore != null && !p.validBefore!.isAfter(p.validAfter)) {
      throw ArgumentError(
          'validBefore (${p.validBefore}) must be strictly after '
          'validAfter (${p.validAfter})');
    }
  }

  static int _unixSeconds(DateTime t) =>
      t.toUtc().millisecondsSinceEpoch ~/ 1000;

  /// OpenSSH encodes "no expiry" as 0xFFFFFFFFFFFFFFFF. In Dart's
  /// signed 64-bit int that's `-1`. The wire writer emits the unsigned
  /// representation.
  static int _validBeforeWire(DateTime? t) {
    if (t == null) return -1; // 0xFFFFFFFFFFFFFFFF as signed
    return _unixSeconds(t);
  }

  /// Concatenated principals as a single SSH string. Each principal
  /// is an inner length-prefixed UTF-8 string. Order is preserved.
  static Uint8List _encodePrincipals(List<String> principals) {
    final w = SshWireWriter();
    for (final p in principals) {
      w.writeUtf8String(p);
    }
    return w.takeBytes();
  }

  /// Encode an option list. Order matters for [criticalOptions] (the
  /// spec says they MUST be lexically sorted by name); we sort
  /// extensions too for consistency.
  static Uint8List _encodeOptions(Map<String, Uint8List> opts) {
    final w = SshWireWriter();
    for (final entry in opts.entries) {
      w.writeUtf8String(entry.key);
      w.writeString(entry.value);
    }
    return w.takeBytes();
  }

  static Map<String, Uint8List> _sortByKey(Map<String, Uint8List> m) {
    final keys = m.keys.toList()..sort();
    return {for (final k in keys) k: m[k]!};
  }

  /// Default user-cert extensions emitted by `ssh-keygen -s`. Each
  /// extension's data is an empty string per the spec.
  static Map<String, Uint8List> _defaultExtensions() {
    return {
      'permit-X11-forwarding': Uint8List(0),
      'permit-agent-forwarding': Uint8List(0),
      'permit-port-forwarding': Uint8List(0),
      'permit-pty': Uint8List(0),
      'permit-user-rc': Uint8List(0),
    };
  }

  static void _writeKeyParts(SshWireWriter w, SshCertIssueParams p) {
    final reader = SshWireReader(p.subjectPublicKeyBlob);
    final headerAlgo = reader.readUtf8String(maxLength: 256);
    if (headerAlgo != p.subjectAlgorithm.bareKeyName) {
      throw ArgumentError(
          'Subject key algorithm "$headerAlgo" does not match '
          'cert algorithm "${p.subjectAlgorithm.name}" (expected '
          'bare key "${p.subjectAlgorithm.bareKeyName}")');
    }
    // Stream the rest of the public-key bytes verbatim. Each variant's
    // layout (mpint pairs for RSA, string pk for ed25519, etc.) is
    // already correctly framed in the source blob, so we just copy.
    while (!reader.isExhausted) {
      final field = reader.readString();
      w.writeString(field);
    }
  }

  static Uint8List _randomNonce(int len) {
    final r = Random.secure();
    final out = Uint8List(len);
    for (var i = 0; i < len; i++) {
      out[i] = r.nextInt(256);
    }
    return out;
  }

  static String _base64NoNewlines(Uint8List bytes) {
    // Just delegate to dart:convert's base64 - it produces a single
    // line by default, exactly what OpenSSH expects.
    return _b64.encode(bytes);
  }
}

const _b64 = _Base64Codec();

/// Tiny base64 encoder so we don't need to import dart:convert from
/// here - keeps the signer module's surface small and easy to audit.
class _Base64Codec {
  const _Base64Codec();
  static const String _alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

  String encode(Uint8List bytes) {
    final out = StringBuffer();
    var i = 0;
    while (i + 3 <= bytes.length) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2];
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write(_alphabet[(n >> 6) & 63]);
      out.write(_alphabet[n & 63]);
      i += 3;
    }
    final rem = bytes.length - i;
    if (rem == 1) {
      final n = bytes[i] << 16;
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write('==');
    } else if (rem == 2) {
      final n = (bytes[i] << 16) | (bytes[i + 1] << 8);
      out.write(_alphabet[(n >> 18) & 63]);
      out.write(_alphabet[(n >> 12) & 63]);
      out.write(_alphabet[(n >> 6) & 63]);
      out.write('=');
    }
    return out.toString();
  }
}
