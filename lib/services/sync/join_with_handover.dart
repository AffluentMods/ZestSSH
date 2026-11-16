import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/account/recovery_proof.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';

/// Joins this device to the account's sync with the key another of its
/// devices handed over after both screens showed the same words (3.0):
/// the steps of joining with the sync password, from the
/// unwrapped key on. The pulled data must open with the key handed over
/// ([SyncDecryptionException] otherwise), and nothing is kept unless it
/// opens and restores: the credentials are stored last. As when joining with
/// the password, a device that held rows the cloud did not is left with
/// changes waiting, so the next sync pushes them up.
Future<({SyncPullResult pull, SyncRestoreResult restore})> joinWithHandover({
  required SyncBackend backend,
  required SyncHandover handover,
  required SyncDataService dataService,
  required AutoSyncService autoSync,
  required FlutterSecureStorage secureStorage,
  required SettingsService settings,
}) async {
  final pull = await backend.pull();
  final dek = SecretKey(handover.dek);
  final data = await SyncService.decrypt(pull.encryptedData, dek);
  final restore = await dataService.restoreAll(data);
  if (!restore.success) return (pull: pull, restore: restore);

  await _keepJoined(
    pull: pull,
    cloudData: data,
    dek: dek,
    verificationHash: handover.verificationHash,
    // What the server says the key is wrapped under wins over what the
    // approving device remembered.
    argon2Params: pull.argon2Params ?? handover.argon2Params,
    dataService: dataService,
    autoSync: autoSync,
    secureStorage: secureStorage,
    settings: settings,
  );
  return (pull: pull, restore: restore);
}

/// Joins this device to the account's sync with the sync [password]: the
/// key is derived with the account's salt and params, checked with the
/// backend, the account's existing data key unwrapped with it (never a new
/// one minted; old stores used the derived key itself), the data opened and
/// merged in, and then the same things kept as [joinWithHandover] keeps. A
/// device that held rows the cloud did not is left with changes waiting, so
/// the first sync sends them up.
///
/// `restore` is null when the backend says the password is wrong; nothing is
/// kept then. Data that does not open throws [SyncDecryptionException], and
/// nothing is kept either.
///
/// Once joined, the password's key is a verified one: [recoveryProof] is
/// asked to register the account's recovery proof with it, on the side.
Future<({SyncPullResult pull, SyncRestoreResult? restore})> joinWithPassword({
  required SyncBackend backend,
  required String password,
  required SyncDataService dataService,
  required AutoSyncService autoSync,
  required FlutterSecureStorage secureStorage,
  required SettingsService settings,
  RecoveryProofService? recoveryProof,
}) async {
  final pull = await backend.pull();
  final mek = await SyncService.deriveKey(password, pull.salt, params: pull.argon2Params);
  if (!await backend.verifyPassword(mek)) return (pull: pull, restore: null);

  final dek = pull.wrappedDekPassword != null ? await SyncService.unwrapDek(pull.wrappedDekPassword!, mek) : mek;
  final data = await SyncService.decrypt(pull.encryptedData, dek);
  final restore = await dataService.restoreAll(data);
  if (!restore.success) return (pull: pull, restore: restore);

  await _keepJoined(
    pull: pull,
    cloudData: data,
    dek: dek,
    verificationHash: await SyncService.computeVerificationHash(mek),
    argon2Params: pull.argon2Params,
    dataService: dataService,
    autoSync: autoSync,
    secureStorage: secureStorage,
    settings: settings,
  );
  unawaited(recoveryProof?.register(mek));
  return (pull: pull, restore: restore);
}

/// What every way of joining keeps once the account's data opened and was
/// merged in: the key, the check and the salt, the server's version, and
/// whether changes wait. Joining itself never pushes; but if this device
/// held rows the cloud did not, the merged data now differs from the
/// cloud's, so changes are left waiting and the next sync sends the union up
/// instead of leaving them on this device until the first edit. A fresh
/// device added nothing and stays clean. The stored content hash is the
/// cloud's fingerprint, so the next push is not taken for an echo.
Future<void> _keepJoined({
  required SyncPullResult pull,
  required Map<String, dynamic> cloudData,
  required SecretKey dek,
  required Uint8List verificationHash,
  required Map<String, dynamic>? argon2Params,
  required SyncDataService dataService,
  required AutoSyncService autoSync,
  required FlutterSecureStorage secureStorage,
  required SettingsService settings,
}) async {
  await autoSync.storeSyncCredentials(dek, verificationHash, argon2Params: argon2Params);
  await secureStorage.write(key: 'sync_salt', value: base64Encode(pull.salt));
  await settings.setSyncServerVersion(pull.version);
  final dekBytes = await dek.extractBytes();
  final cloud = SyncDataService.contentFingerprint(cloudData, dekBytes);
  final merged = SyncDataService.contentFingerprint(await dataService.gatherAll(), dekBytes);
  await settings.setSyncContentHash(cloud);
  await settings.setSyncDirty(merged != cloud);
  await settings.setSyncMode('auto');
}
