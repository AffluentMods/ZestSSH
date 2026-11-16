import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:zestssh/services/recovery_key_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/type_name.dart';

// Replacing the vault's recovery key (3.0). The recovery key is the
// way back in when the master password is forgotten: the store keeps the data
// key wrapped under it, which it cannot open. A person who lost their key, or
// never had one, makes a new one from Account and security. The old one stops
// working once the new one is on the store.
//
// Making one needs the master password, proved against the store as it is
// now: a device that is merely unlocked is not enough to hand out a second
// way into the vault, and a device that missed a password change on another
// device must not accept the old password.

/// Why a master password did not prove the vault.
enum VaultProofFailure {
  /// The password does not open the store's data key.
  wrongPassword,

  /// It opens a data key, but not the one this device syncs with.
  otherKey,

  /// The store holds no password-wrapped data key to prove against.
  notSetUp,
}

class VaultProofException implements Exception, HasTypeName {
  const VaultProofException(this.failure);

  final VaultProofFailure failure;

  @override
  String toString() => 'VaultProofException(${failure.name})';

  @override
  String get typeName => 'VaultProofException';
}

/// The account's keys as the store holds them now, proved with the master
/// password.
class ProvenVault {
  const ProvenVault({
    required this.dek,
    required this.mek,
    required this.salt,
    required this.verificationHash,
    required this.argon2Params,
    required this.hadRecovery,
  });

  final SecretKey dek;

  /// The master password's key, proved: what the account's recovery proof
  /// is made from (lib/services/account/recovery_proof.dart).
  final SecretKey mek;

  /// The master password's salt on the store.
  final Uint8List salt;

  /// The master password's verification value, for the store's write check.
  final Uint8List verificationHash;

  /// The Argon2id parameters the store's wrapped keys are derived under.
  final Map<String, dynamic> argon2Params;

  /// Whether the store held a recovery key before.
  final bool hadRecovery;
}

/// Proves [password] is the master password of the vault in [backend], and
/// that the vault's data key is the one this device holds ([deviceDek]).
/// Opening the store's password-wrapped data key is the proof: no password
/// check is asked of the server. Throws a [VaultProofException] when it is
/// not proved, and whatever the store throws when it cannot be read.
Future<ProvenVault> proveMasterPassword(
  SyncBackend backend,
  String password, {
  required List<int> deviceDek,
}) async {
  final pulled = await backend.pull();
  final wrapped = pulled.wrappedDekPassword;
  if (wrapped == null) {
    throw const VaultProofException(VaultProofFailure.notSetUp);
  }
  final params = pulled.argon2Params ?? SyncService.legacyArgon2Params;
  final mek = await SyncService.deriveKey(password, pulled.salt, params: params);
  final SecretKey dek;
  try {
    dek = await SyncService.unwrapDek(wrapped, mek);
  } on SyncDecryptionException {
    throw const VaultProofException(VaultProofFailure.wrongPassword);
  }
  if (!_sameBytes(await dek.extractBytes(), deviceDek)) {
    throw const VaultProofException(VaultProofFailure.otherKey);
  }
  return ProvenVault(
    dek: dek,
    mek: mek,
    salt: pulled.salt,
    verificationHash: await SyncService.computeVerificationHash(mek),
    argon2Params: params,
    hadRecovery: pulled.wrappedDekRecovery != null,
  );
}

/// A recovery key's copy of the data key, ready for the store.
class RecoveryWrap {
  const RecoveryWrap({required this.wrappedDek, required this.salt, required this.hash});

  final Uint8List wrappedDek;
  final Uint8List salt;

  /// The recovery key's verification value, for the store's recovery check.
  final Uint8List hash;
}

/// Wraps [vault]'s data key under [recoveryKey] with a fresh salt, derived
/// under the vault's own Argon2id parameters: a recovery restore derives the
/// key with the parameters the store keeps, so any other set would make the
/// new key fail when it is needed.
Future<RecoveryWrap> wrapForRecovery(ProvenVault vault, String recoveryKey) async {
  final salt = RecoveryKeyService.generateRecoverySalt();
  final kek = await SyncService.deriveKey(
    RecoveryKeyService.normalize(recoveryKey),
    salt,
    params: vault.argon2Params,
  );
  return RecoveryWrap(
    wrappedDek: await SyncService.wrapDek(vault.dek, kek),
    salt: salt,
    hash: await SyncService.computeRecoveryVerificationHash(kek),
  );
}

/// What a recovery key opens (3.0).
enum RecoveryKeyCheck {
  /// The store's recovery copy of the data key, and it is the key this
  /// device syncs with: the key works.
  works,

  /// A data key, but not the one this device syncs with.
  otherVault,

  /// Nothing: it is not the key the store's recovery copy was made with.
  wrongKey,

  /// The store holds no recovery copy to check against.
  notSetUp,
}

/// Checks [recoveryKey], as a person typed it back from their kit, against
/// the store in [backend] without changing anything anywhere: it must open
/// the store's recovery copy of the data key, derived under the store's own
/// Argon2id parameters as a real restore derives it, and that key must be
/// [deviceDek]. Only a read of the store is made; the check itself happens
/// on this device. Throws whatever the store throws when it cannot be read.
Future<RecoveryKeyCheck> checkRecoveryKey(
  SyncBackend backend,
  String recoveryKey, {
  required List<int> deviceDek,
}) async {
  final tidy = RecoveryKeyService.tidy(recoveryKey);
  final pulled = await backend.pull();
  final wrapped = pulled.wrappedDekRecovery;
  final salt = pulled.recoverySalt;
  if (wrapped == null || salt == null) return RecoveryKeyCheck.notSetUp;
  if (tidy == null) return RecoveryKeyCheck.wrongKey;
  final kek = await SyncService.deriveKey(
    RecoveryKeyService.normalize(tidy),
    salt,
    params: pulled.argon2Params ?? SyncService.legacyArgon2Params,
  );
  final SecretKey dek;
  try {
    dek = await SyncService.unwrapDek(wrapped, kek);
  } on SyncDecryptionException {
    return RecoveryKeyCheck.wrongKey;
  }
  return _sameBytes(await dek.extractBytes(), deviceDek) ? RecoveryKeyCheck.works : RecoveryKeyCheck.otherVault;
}

/// Compares in time independent of where the bytes differ.
bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  var diff = 0;
  for (var i = 0; i < a.length; i++) {
    diff |= a[i] ^ b[i];
  }
  return diff == 0;
}
