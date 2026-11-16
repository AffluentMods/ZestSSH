import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zest_ssh_core/dartssh2.dart';

import 'ssh_cert_signer.dart';
import 'ssh_certificate.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/database/database.dart';

/// High-level operations for SSH user certificates: import, generate,
/// load, delete.
///
/// Sensitive material (the cert blob, the CA private key) lives in
/// [FlutterSecureStorage]. The Drift `Identities` table mirrors the
/// non-secret cert metadata (serial, key id, principals, validity) so
/// the UI can render lists without round-tripping secure storage on
/// every build.
///
/// Storage keys:
///   * `identity_cert_{identityId}` - raw cert blob (cert algorithm +
///     base64-decoded body). Encrypted at rest by the secure-storage
///     backend.
///   * `ca_key_{caId}` - CA private key in OpenSSH PEM. Same secret
///     class as a normal identity private key.
class SshCertService {
  SshCertService(this._secureStorage, {IdentitySecretStore? secrets, this.sealedBy})
      : _secrets = secrets ?? SecureStorageIdentitySecrets(_secureStorage, sealedBy: sealedBy);

  final FlutterSecureStorage _secureStorage;

  /// Your Tree's database, whose seal keeps a CA's key while the encrypting
  /// lock is on ([SecretSeal]).
  final AppDatabase? sealedBy;

  /// Where identities keep their certificates and keys: the OS secure
  /// storage for your Tree, the Orchard's database for an Orchard.
  final IdentitySecretStore _secrets;

  // ── Cert import ─────────────────────────────────────────────────

  /// Parse an OpenSSH cert from either a `<algo> <base64>` line or a
  /// raw blob. Throws [FormatException] with a precise reason on bad
  /// input - surface that text directly in the UI.
  SshCertificate parseImported(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw const FormatException('No certificate text provided');
    }
    // Heuristic: text containing whitespace + a base64-looking blob is
    // an OpenSSH `<algo> <b64>` line. Otherwise treat as bare base64.
    if (trimmed.contains(RegExp(r'\s'))) {
      return SshCertificate.parseFromOpenSSH(trimmed);
    }
    final blob = base64.decode(trimmed);
    return SshCertificate.parse(blob);
  }

  // ── Cert generation ─────────────────────────────────────────────

  /// Issue a fresh user cert. The CA key is loaded from secure storage
  /// using [caKeyStorageKey] and decrypted with [caPassphrase]
  /// (null when the key is unencrypted).
  ///
  /// Returns both the cert object (parsed back from the bytes we just
  /// produced - no risk of write/read drift) and the OpenSSH text form
  /// for the UI to optionally hand to the user.
  Future<({SshCertificate cert, String openSshLine})> issueCertificate({
    required SSHKeyPair subjectKey,
    required SshCertAlgorithm subjectAlgorithm,
    required String caKeyStorageKey,
    String? caPassphrase,
    required int serial,
    required String keyId,
    required List<String> principals,
    required DateTime validAfter,
    DateTime? validBefore,
    Map<String, Uint8List> criticalOptions = const {},
    Map<String, Uint8List>? extensions,
  }) async {
    final caKey = await _loadCaKey(caKeyStorageKey, caPassphrase);
    try {
      final blob = SshCertSigner.issue(
        params: SshCertIssueParams(
          subjectPublicKeyBlob: subjectKey.toPublicKey().encode(),
          subjectAlgorithm: subjectAlgorithm,
          serial: serial,
          type: SshCertType.user,
          keyId: keyId,
          principals: principals,
          validAfter: validAfter,
          validBefore: validBefore,
          criticalOptions: criticalOptions,
          extensions: extensions,
        ),
        caKey: caKey,
      );
      final parsed = SshCertificate.parse(blob);
      final line = SshCertSigner.toOpenSshLine(blob, comment: keyId);
      return (cert: parsed, openSshLine: line);
    } finally {
      // No persistent CA-key cache; we discard the in-memory key after
      // each issuance so a leaked process snapshot can't re-sign certs.
    }
  }

  /// Verify the underlying public key inside [cert] matches
  /// [subjectKey] - call this immediately after [parseImported] when
  /// attaching a cert to an existing identity, so we never persist a
  /// cert/key mismatch.
  bool certMatchesKey(SshCertificate cert, SSHKeyPair subjectKey) {
    final innerPub = subjectKey.toPublicKey().encode();
    final reconstructed =
        _reconstructInnerPubFromCert(cert.keyAlgorithm, cert.keyParts);
    if (innerPub.length != reconstructed.length) return false;
    var diff = 0;
    for (var i = 0; i < innerPub.length; i++) {
      diff |= innerPub[i] ^ reconstructed[i];
    }
    return diff == 0;
  }

  /// Whether [cert] certifies the key whose public half is [openSshPublicKey]
  /// (a key's stored `<algo> <base64> [comment]` line): the same algorithm
  /// and the same public key bytes. What the attach dialog asks of every key
  /// it offers, before Attach (it compared the algorithm alone, so a key of
  /// the same kind that the certificate is not for could be picked, and only
  /// Attach said no).
  bool certMatchesPublicKey(SshCertificate cert, String openSshPublicKey) {
    final parts = openSshPublicKey.trim().split(RegExp(r'\s+'));
    if (parts.length < 2 || parts[0] != cert.keyAlgorithm) return false;
    final List<int> blob;
    try {
      blob = base64.decode(parts[1]);
    } on FormatException {
      return false;
    }
    final reconstructed = _reconstructInnerPubFromCert(cert.keyAlgorithm, cert.keyParts);
    if (blob.length != reconstructed.length) return false;
    var diff = 0;
    for (var i = 0; i < blob.length; i++) {
      diff |= blob[i] ^ reconstructed[i];
    }
    return diff == 0;
  }

  // ── Persistence ─────────────────────────────────────────────────

  /// Persist a cert blob alongside an identity. Storage key is derived
  /// from the identity id, matching the convention the rest of the app
  /// uses for identity secrets.
  Future<void> storeCertForIdentity(String identityId, Uint8List blob) async {
    if (blob.isEmpty) {
      throw ArgumentError('Refusing to persist an empty cert blob');
    }
    await _secrets.write(identityId, IdentitySecret.certificate, base64.encode(blob));
  }

  /// Read back a previously-stored cert. Returns null when the
  /// identity has none.
  Future<SshCertificate?> loadCertForIdentity(String identityId) async {
    final encoded = await _secrets.read(identityId, IdentitySecret.certificate);
    if (encoded == null) return null;
    return SshCertificate.parse(base64.decode(encoded));
  }

  /// Drop the cert attached to an identity. Idempotent.
  Future<void> deleteCertForIdentity(String identityId) async {
    await _secrets.write(identityId, IdentitySecret.certificate, null);
  }

  // ── CA key storage ──────────────────────────────────────────────

  /// Save a CA private key. The PEM is validated once (loaded + parsed
  /// + serialised back) so we never persist garbage.
  Future<void> storeCaKey(String storageKey, String pem,
      {String? passphrase}) async {
    // Validate by attempting a load - surfaces wrong passphrase /
    // malformed PEM right away.
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) {
      throw const FormatException(
          'Refusing to persist CA key: no key pairs found in PEM');
    }
    await _secureStorage.write(key: storageKey, value: await keepSealed(sealedBy, storageKey, pem));
  }

  Future<SSHKeyPair> _loadCaKey(String storageKey, String? passphrase) async {
    // A CA that is one of your keys lives where that key's space keeps it.
    final identityKey = RegExp(r'^identity_key_(.+)$').firstMatch(storageKey);
    final pem = identityKey != null
        ? await _secrets.read(identityKey.group(1)!, IdentitySecret.privateKey)
        : await openKept(sealedBy, storageKey, await _secureStorage.read(key: storageKey));
    if (pem == null) {
      throw StateError(
          'CA private key "$storageKey" is not present in secure storage');
    }
    final pairs = SSHKeyPair.fromPem(pem, passphrase);
    if (pairs.isEmpty) {
      throw StateError('CA key PEM contained no parsable key pairs');
    }
    return pairs.first;
  }

  // ── Helpers ─────────────────────────────────────────────────────

  /// Rebuild the bare-key public blob (`string algo || …`) given the
  /// algorithm name and the cert's captured `keyParts` slice.
  Uint8List _reconstructInnerPubFromCert(
      String keyAlgorithm, Uint8List keyParts) {
    final algoBytes = utf8.encode(keyAlgorithm);
    final out = Uint8List(4 + algoBytes.length + keyParts.length);
    out[0] = (algoBytes.length >> 24) & 0xFF;
    out[1] = (algoBytes.length >> 16) & 0xFF;
    out[2] = (algoBytes.length >> 8) & 0xFF;
    out[3] = algoBytes.length & 0xFF;
    out.setRange(4, 4 + algoBytes.length, algoBytes);
    out.setRange(4 + algoBytes.length, out.length, keyParts);
    return out;
  }
}
