import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash_lib;
import 'package:cryptography/cryptography.dart';
import 'package:zestssh/services/sync_service.dart';

/// Recovery Key generation and derivation service.
///
/// Generates a 24-character alphanumeric recovery key formatted as
/// `ZEST-XXXX-XXXX-XXXX-XXXX-XXXX`. The recovery key derives a second
/// copy of the Master Encryption Key (MEK) via Argon2id with its own
/// salt, providing an independent decryption path when the master
/// sync password is forgotten.
abstract final class RecoveryKeyService {
  // Unambiguous characters: no 0/O, 1/I/L
  static const _chars = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

  /// Number of random characters in the key (excluding prefix and dashes).
  static const _keyLength = 20;

  // ── Key Generation ──────────────────────────────────────────────

  /// Generate a cryptographically random recovery key.
  ///
  /// Format: `ZEST-XXXX-XXXX-XXXX-XXXX-XXXX` (20 random characters
  /// from an unambiguous alphabet, plus the `ZEST` prefix).
  static String generateRecoveryKey() {
    final rng = Random.secure();
    final buffer = StringBuffer('ZEST');

    for (var i = 0; i < _keyLength; i++) {
      if (i % 4 == 0) buffer.write('-');
      buffer.write(_chars[rng.nextInt(_chars.length)]);
    }

    return buffer.toString();
  }

  /// Strip formatting from a recovery key, returning only the raw
  /// alphanumeric characters (uppercase): dashes and spaces (a key typed in
  /// groups, a line break pasted with it) go, as [tidy] takes them out. Every
  /// restore with the key goes through here: they took the dashes out alone,
  /// so a key Check took was refused there (found while checking the 3.0 docs).
  static String normalize(String recoveryKey) {
    return recoveryKey.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
  }

  /// A recovery key as a person may type it back: dashes or spaces anywhere,
  /// any case; the key itself, or null when it cannot be one (the prefix
  /// and 20 characters of the key's alphabet).
  static String? tidy(String typed) {
    final raw = typed.replaceAll(RegExp(r'[\s-]'), '').toUpperCase();
    if (!RegExp('^ZEST[$_chars]{$_keyLength}\$').hasMatch(raw)) return null;
    final parts = [for (var i = 4; i < raw.length; i += 4) raw.substring(i, i + 4)];
    return 'ZEST-${parts.join('-')}';
  }

  // ── Key Derivation ─────────────────────────────────────────────

  /// Derive a 256-bit MEK from the recovery key + a dedicated salt.
  ///
  /// Uses the same Argon2id parameters as [SyncService.deriveKey] so
  /// that the resulting key has equivalent strength.
  static Future<SecretKey> deriveRecoveryMek(
    String recoveryKey,
    Uint8List recoverySalt,
  ) async {
    // Use the normalized (dash-stripped) form as the input secret.
    final normalized = normalize(recoveryKey);
    return SyncService.deriveKey(normalized, recoverySalt);
  }

  /// Generate a dedicated 32-byte salt for recovery key derivation.
  static Uint8List generateRecoverySalt() {
    return SyncService.generateSalt();
  }

  /// Compute HKDF + SHA-256 verification hash of the MEK derived from
  /// the recovery key, using a distinct HKDF info string to ensure
  /// cryptographic domain separation from the master password path.
  static Future<Uint8List> computeRecoveryVerificationHash(
    SecretKey mek,
  ) async {
    final keyBytes = await mek.extractBytes();
    final hkdf = Hkdf(hmac: Hmac(Sha256()), outputLength: 32);
    final verificationKey = await hkdf.deriveKey(
      secretKey: SecretKey(keyBytes),
      nonce: Uint8List(0),
      info: utf8.encode('zestssh-recovery-verification'),
    );
    final derivedBytes = await verificationKey.extractBytes();
    final digest = hash_lib.sha256.convert(derivedBytes);
    return Uint8List.fromList(digest.bytes);
  }

  // ── Confirmation Helpers ────────────────────────────────────────

  /// Pick [count] random character positions from the raw (no dashes)
  /// portion of the key for user confirmation.
  ///
  /// Returns a list of zero-based indices into the normalized key
  /// (which includes the `ZEST` prefix, so index 0 = 'Z').
  /// To make the challenge meaningful, only positions after the prefix
  /// (index >= 4) are selected.
  static List<int> pickChallengePositions(String recoveryKey,
      {int count = 3}) {
    final normalized = normalize(recoveryKey);
    final rng = Random.secure();

    // Only challenge on the random portion (after "ZEST" prefix).
    final availablePositions =
        List<int>.generate(normalized.length - 4, (i) => i + 4);
    availablePositions.shuffle(rng);

    return availablePositions.take(count).toList()..sort();
  }

  /// Verify that the user-entered characters match the expected
  /// characters at the given positions.
  static bool verifyChallengeResponse(
    String recoveryKey,
    List<int> positions,
    List<String> responses,
  ) {
    final normalized = normalize(recoveryKey);
    if (positions.length != responses.length) return false;

    for (var i = 0; i < positions.length; i++) {
      final expected = normalized[positions[i]].toUpperCase();
      final actual = responses[i].toUpperCase().trim();
      if (actual != expected) return false;
    }

    return true;
  }
}
