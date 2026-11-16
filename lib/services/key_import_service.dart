import 'dart:convert';
import 'dart:isolate';

import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/utils/ppk_converter.dart';

/// The OpenSSH public key line of the private key [privatePem] ("ssh-ed25519
/// AAAA... [comment]"), what an authorized_keys file takes: made from the key
/// itself (opened with [passphrase] where it is sealed), with [comment] after
/// it where there is one. Null where it cannot be read: no key, or one sealed
/// under a passphrase that is not given.
///
/// The key is named by its type (`name`: ssh-rsa for an RSA key), not by
/// the signature it makes (`type`: rsa-sha2-256), which an authorized_keys
/// file, ssh-keygen and a site taking SSH keys do not take for a key.
String? publicKeyLineOf(String privatePem, {String? passphrase, String comment = ''}) {
  try {
    final pairs = SSHKeyPair.fromPem(privatePem, passphrase);
    if (pairs.isEmpty) return null;
    final pair = pairs.first;
    final line = '${pair.name} ${base64.encode(pair.toPublicKey().encode())}';
    final said = comment.replaceAll(RegExp(r'[\r\n]+'), ' ').trim();
    return said.isEmpty ? line : '$line $said';
  } catch (_) {
    return null;
  }
}

/// Whether [privatePem] is the key file of a security key (an OpenSSH "sk"
/// key: sk-ssh-ed25519@openssh.com or sk-ecdsa-sha2-nistp256@openssh.com).
/// Such a file holds no secret: its "private" part is the key handle the
/// security key is asked by, with the public key, the application and the
/// flags, and it signs in only with the security key itself. Read from the
/// file's public keys, which a passphrase does not seal, so a sealed file is
/// told too. False for anything else or what cannot be read.
bool isSecurityKeyFile(String privatePem) {
  try {
    final pem = SSHPem.decode(privatePem);
    if (pem.type != 'OPENSSH PRIVATE KEY') return false;
    final keys = OpenSSHKeyPairs.decode(pem.content).publicKeys;
    return keys.isNotEmpty && keys.every((blob) => OpenSSHSkKeyPair.isSkType(_keyTypeOf(blob)));
  } catch (_) {
    return false;
  }
}

/// The type name a public key [blob] starts with (an SSH string), or empty.
String _keyTypeOf(List<int> blob) {
  if (blob.length < 4) return '';
  final length = (blob[0] << 24) | (blob[1] << 16) | (blob[2] << 8) | blob[3];
  if (length > blob.length - 4) return '';
  return latin1.decode(blob.sublist(4, 4 + length));
}

/// [line], a public key line, with an RSA key named by its type: a line made
/// before 3.0 ([publicKeyLineOf]) named it by the signature it makes
/// (rsa-sha2-256), which OpenSSH reads but a site taking SSH keys does not.
String publicKeyLineNamed(String line) => line.replaceFirst(RegExp(r'^rsa-sha2-(256|512)(?=\s)'), 'ssh-rsa');

/// Result of importing a key file.
class ImportedKey {
  final String privatePem;
  final String keyType;
  final String fingerprint;

  const ImportedKey({
    required this.privatePem,
    required this.keyType,
    required this.fingerprint,
  });
}

/// Imports SSH keys from various formats.
class KeyImportService {
  /// Import an OpenSSH PEM private key.
  ///
  /// Throws if the key is invalid or the passphrase is wrong.
  ImportedKey importOpenSSHKey(String pemContent, [String? passphrase]) {
    AppLogger.info('Importing OpenSSH key');
    final pairs = SSHKeyPair.fromPem(pemContent, passphrase);
    if (pairs.isEmpty) throw const FormatException('No valid keys found in PEM');

    final pair = pairs.first;
    final fingerprint = _computeFingerprint(pair);
    return ImportedKey(
      privatePem: pemContent,
      keyType: pair.type,
      fingerprint: fingerprint,
    );
  }

  /// Import a PuTTY .ppk file, converting it to OpenSSH PEM.
  ImportedKey importPpkKey(String ppkContent, [String? passphrase]) {
    AppLogger.info('Importing PuTTY .ppk key');
    final pem = PpkConverter.toPem(ppkContent, passphrase);
    return importOpenSSHKey(pem);
  }

  /// Check if a PEM key is encrypted (requires a passphrase).
  ///
  /// Handles three formats:
  /// 1. Old PEM (RSA PRIVATE KEY): has "Proc-Type: 4,ENCRYPTED" header
  /// 2. Old PEM with explicit header: "ENCRYPTED PRIVATE KEY"
  /// 3. Modern OpenSSH format: the encryption is inside the binary
  ///    payload - try parsing without a passphrase and catch the error.
  bool isEncrypted(String pemContent) {
    // A PuTTY key says so in its own header (it was taken for a key without
    // a passphrase, and then refused as not supported).
    if (isPpkFormat(pemContent)) return PpkConverter.isEncrypted(pemContent);
    // Old-style PEM encryption headers (SSH.com's key says ENCRYPTED as well,
    // in a form that is not read here, so no passphrase is asked for it).
    if (pemContent.contains('-----BEGIN ENCRYPTED PRIVATE KEY-----') ||
        pemContent.contains('Proc-Type: 4,ENCRYPTED')) {
      return true;
    }
    // Modern OpenSSH format (BEGIN OPENSSH PRIVATE KEY) stores
    // encryption metadata in the binary blob, not in PEM headers.
    // Try a no-passphrase parse - if it throws, the key is encrypted.
    if (pemContent.contains('BEGIN OPENSSH PRIVATE KEY')) {
      try {
        SSHKeyPair.fromPem(pemContent);
        return false; // Parsed OK → not encrypted
      } catch (_) {
        return true; // Parse failed → likely encrypted
      }
    }
    return false;
  }

  /// Whether [content] is in a form that is read here at all: PEM, as OpenSSH
  /// and OpenSSL write it, or PuTTY's. Not SSH.com's or PGP's, nor a file that
  /// is no text (DER, PKCS#12, the old SSH 1 file).
  bool readsForm(String content) =>
      isPpkFormat(content) ||
      (content.contains(RegExp(r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----')) && !content.contains('-----BEGIN PGP '));

  /// Check if content looks like a PuTTY .ppk file.
  bool isPpkFormat(String content) {
    return content.trimLeft().startsWith('PuTTY-User-Key-File-');
  }

  /// What a key that could not be imported is said as, in the app's language
  /// (it was English in every language, or the raw error). What was thrown
  /// goes in the notice's details, not in its sentence.
  static String problemSaid(Object error, AppLocalizations l10n) {
    if (error is PpkPassphraseError) {
      return error.missing ? l10n.keyImportHasPassphrase : l10n.identityIncorrectPassphrase;
    }
    final raw = '$error';
    final lower = raw.toLowerCase();
    if (lower.contains('mac verification failed') || lower.contains('missing the private-mac')) {
      return l10n.keyImportDamaged;
    }
    if (lower.contains('unsupported') || lower.contains('unknown key type')) {
      return l10n.keyImportUnsupportedKind;
    }
    if (lower.contains('no valid keys')) return l10n.keyImportNoKeys;
    if (isPassphraseError(raw)) return l10n.identityIncorrectPassphrase;
    if (error is FormatException || lower.contains('header') || lower.contains('begin')) {
      return l10n.keyImportNotAKey;
    }
    return l10n.keyImportNotImported;
  }

  /// [importPpkKey] for a key with a passphrase, off the screen's thread: its
  /// key is derived with Argon2, which takes a moment the app should not
  /// freeze for.
  Future<ImportedKey> importPpkKeyInBackground(String ppkContent, String? passphrase) =>
      Isolate.run(() => KeyImportService().importPpkKey(ppkContent, passphrase));

  /// Returns true if the error was caused by an incorrect passphrase.
  ///
  /// Covers dartssh2's various exception messages across formats:
  /// OpenSSH modern keys, old-style PEM, and PuTTY .ppk.
  static bool isPassphraseError(String rawError) {
    final lower = rawError.toLowerCase();
    return lower.contains('ppkpassphraseerror') ||
        lower.contains('bad decrypt') ||
        lower.contains('incorrect passphrase') ||
        lower.contains('wrong passphrase') ||
        lower.contains('mac check') ||
        lower.contains('bad pkcs') ||
        lower.contains('padding') ||
        lower.contains('decryption failed') ||
        lower.contains('invalid key') ||
        lower.contains('rangeerror') ||
        lower.contains('sshkeydecrypterror') ||
        lower.contains('decrypt error') ||
        lower.contains('authentication');
  }

  /// Compute an SHA-256 fingerprint from a key pair's public key, as
  /// ssh-keygen -l writes it and a key made in the app keeps it: without
  /// base64's padding (3.0; found 16 October 2026: an imported key's ended in
  /// "=", so it matched neither, nor the same key made here).
  String _computeFingerprint(SSHKeyPair pair) {
    try {
      return OpenSSHKeySerializer.fingerprintFromBlob(pair.toPublicKey().encode());
    } catch (_) {
      // Fallback if public key encoding fails
      return 'SHA256:unknown';
    }
  }
}
