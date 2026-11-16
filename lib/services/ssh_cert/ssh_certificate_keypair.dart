import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';
// Direct import for SSHHostKey because dartssh2.dart hides it to
// avoid colliding with the same-named class in lib/services/ssh_service.dart.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_hostkey.dart' as core_hk;

import 'ssh_certificate.dart';

/// `SSHKeyPair` wrapper that presents an OpenSSH user certificate to
/// the server during pubkey auth, but delegates actual signing to the
/// underlying private key.
///
/// Wire details:
/// * `type` is the algorithm announced in the userauth request (e.g.
///   `ssh-ed25519-cert-v01@openssh.com`). For RSA it names the hash the
///   inner key really signs with, whatever the blob says: see
///   [_announcedAlgorithm].
/// * `toPublicKey()` returns a key whose `encode()` is the full cert
///   blob (cert algorithm + nonce + key parts + … + signature), exactly
///   as issued.
/// * `sign()` and `signAsync()` are delegated to the inner key - the
///   cert doesn't change how we sign, only the algorithm string and
///   key-blob the server sees during auth.
///
/// `name` is the algorithm written in the certificate blob. `toPem()`
/// returns the inner key's PEM, since re-serialising the cert is
/// meaningless (the cert is opaque public material - there is no
/// "private cert").
class SshCertificateKeyPair extends SSHKeyPair implements SSHWrappedKeyPair, SSHRsaSignatureChoice {
  SshCertificateKeyPair({
    required SSHKeyPair innerKey,
    required SshCertificate certificate,
  })  : _innerKey = innerKey,
        _certificate = certificate {
    _validate();
  }

  final SSHKeyPair _innerKey;
  final SshCertificate _certificate;

  /// The certificate this pair authenticates with. Useful for UI
  /// display (expiry, key id, principals, …).
  SshCertificate get certificate => _certificate;

  /// The bare-key inner pair. Doing pubkey auth without the cert
  /// (e.g. on a server that doesn't accept this CA) requires this
  /// fallback, and a forwarded agent signs RSA requests with it at the
  /// hash they ask for.
  @override
  SSHKeyPair get innerKey => _innerKey;

  @override
  String get name => _certificate.algorithm.name;

  @override
  String get type => _announcedAlgorithm(_certificate, _innerKey);

  /// A certificate on an RSA key signs with the kinds of signature that key
  /// makes, and is announced under the certificate's name for the kind
  /// ([_announcedAlgorithm]); the SSH core picks the kind a host takes.
  @override
  List<String> get rsaSignatureTypes => switch (_innerKey) {
        SSHRsaSignatureChoice(:final rsaSignatureTypes) => rsaSignatureTypes,
        _ => const [],
      };

  @override
  SSHKeyPair signingAsRsa(String type) => SshCertificateKeyPair(
        innerKey: (_innerKey as SSHRsaSignatureChoice).signingAsRsa(type),
        certificate: _certificate,
      );

  /// The algorithm to announce for [certificate] signed by [inner].
  ///
  /// For RSA the announced name also fixes the signature hash, and a
  /// server refuses a signature whose hash differs ("unexpected signature
  /// type"). So it follows the hash the inner key signs with, not the
  /// name in the blob: OpenSSH writes `ssh-rsa-cert-v01@openssh.com` into
  /// every RSA certificate, and announcing that SHA-1 name is refused by
  /// OpenSSH 8.8 and later, while certificates this app issued up to
  /// 2.1.1 carry `rsa-sha2-512-cert-v01@openssh.com` but were signed with
  /// SHA-256. Both logged in nowhere before this. Every other key type
  /// has one signature algorithm, so its certificate's own name is right.
  static String _announcedAlgorithm(
      SshCertificate certificate, SSHKeyPair inner) {
    if (certificate.algorithm.bareKeyName != 'ssh-rsa') {
      return certificate.algorithm.name;
    }
    switch (inner.type) {
      case 'rsa-sha2-512':
        return SshCertAlgorithm.rsaSha2_512.name;
      case 'ssh-rsa':
        return SshCertAlgorithm.rsaSha1.name;
      default:
        return SshCertAlgorithm.rsaSha2_256.name;
    }
  }

  @override
  core_hk.SSHHostKey toPublicKey() {
    return _CertHostKey(_certificate.fullBlob);
  }

  @override
  SSHSignature sign(Uint8List data) {
    // The signature wire format is identical to a bare-key signature
    // - the algorithm name encoded inside the signature string is the
    // bare-key algorithm (ssh-ed25519, rsa-sha2-512, etc.), not the
    // cert algorithm. The server is responsible for knowing that a
    // cert auth carries a bare-key signature.
    return _innerKey.sign(data);
  }

  /// Userauth always signs through this path. A hardware-token or agent
  /// key can only sign here (its [sign] throws), so without the
  /// delegation a certificate on such a key could never log in.
  @override
  Future<SSHSignature> signAsync(Uint8List data) =>
      _innerKey.signAsync(data);

  @override
  String toPem() => _innerKey.toPem();

  /// Round-trip-safe equality based on certificate serial + CA, plus
  /// the inner key's public bytes. Two cert pairs with the same
  /// underlying key + same cert are interchangeable.
  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SshCertificateKeyPair) return false;
    return _certificate.serial == other._certificate.serial &&
        _bytesEqual(
            _certificate.signatureKey, other._certificate.signatureKey) &&
        _bytesEqual(
            _innerKey.toPublicKey().encode(),
            other._innerKey.toPublicKey().encode());
  }

  @override
  int get hashCode => Object.hash(
        _certificate.serial,
        _bytesHash(_certificate.signatureKey),
        _bytesHash(_innerKey.toPublicKey().encode()),
      );

  /// Make sure the certificate's embedded public key actually belongs
  /// to the inner private key. Without this check, a malicious cert
  /// containing someone *else's* public key would still be accepted -
  /// the server would reject the bad signature, but only after we'd
  /// already disclosed our identity attempt to the network.
  void _validate() {
    final innerPub = _innerKey.toPublicKey().encode();
    final certPub = _reconstructInnerPubFromCert();
    if (!_bytesEqual(innerPub, certPub)) {
      throw ArgumentError(
        'SSH certificate / private key mismatch: the certificate\'s '
        'embedded public key does not match the supplied private key. '
        'Check that you imported the cert that was issued for this '
        'specific key (re-issuing the cert may be required).',
      );
    }
    // Refuse host certificates outright - they're meant to authenticate
    // *servers*, not users.
    if (_certificate.type != SshCertType.user) {
      throw ArgumentError(
        'SSH certificate type is "${_certificate.type.name}", but only '
        'user certificates can be used for client authentication.',
      );
    }
  }

  /// Rebuild what the inner key's public-blob would look like by
  /// concatenating the cert's bare-key algorithm name with its
  /// captured `keyParts` slice. For Ed25519 this yields
  /// `ssh-ed25519 || pk` - exactly what `SSHHostkey.encode()` returns
  /// for that algorithm.
  Uint8List _reconstructInnerPubFromCert() {
    final builder = BytesBuilder(copy: false);
    final algoBytes = _utf8Bytes(_certificate.keyAlgorithm);
    builder.add(_uint32(algoBytes.length));
    builder.add(algoBytes);
    builder.add(_certificate.keyParts);
    return builder.toBytes();
  }

  static Uint8List _uint32(int v) => Uint8List.fromList([
        (v >> 24) & 0xFF,
        (v >> 16) & 0xFF,
        (v >> 8) & 0xFF,
        v & 0xFF,
      ]);

  static Uint8List _utf8Bytes(String s) {
    return Uint8List.fromList(s.codeUnits);
  }

  /// Constant-time byte comparison so our public-key match checks
  /// don't leak information through timing.
  static bool _bytesEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a[i] ^ b[i];
    }
    return diff == 0;
  }

  static int _bytesHash(Uint8List a) {
    // Cheap stable hash - only used for collection bucketing.
    var h = 0;
    for (final b in a) {
      h = 0x1FFFFFFF & (h * 31 + b);
    }
    return h;
  }
}

/// Minimal `core_hk.SSHHostKey` that wraps a pre-encoded blob. Used for cert
/// public-key advertising during userauth.
class _CertHostKey implements core_hk.SSHHostKey {
  _CertHostKey(this._encoded);
  final Uint8List _encoded;

  @override
  Uint8List encode() => _encoded;
}
