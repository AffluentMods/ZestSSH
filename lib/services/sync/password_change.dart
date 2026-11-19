import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';

/// What a change of the sync password wrote: the store's new version and
/// size, and the salt, key and proof of the new password.
typedef PasswordChangeWritten = ({
  int version,
  int blobSize,
  Uint8List salt,
  SecretKey mek,
  Uint8List verificationHash,
  Map<String, dynamic>? argon2Params,
});

/// Writes the store again under a new sync password: the same data key,
/// wrapped by a key derived from [newPassword] with a new salt, and the data
/// as [pulled] holds it.
///
/// The write is made only onto the version that was read ([pulled]): the
/// person types the new password twice between the read and the write, and a
/// device of theirs that synced meanwhile had its upload replaced by the copy
/// read before it. Where the store has moved on, it is read again and the
/// change made on what it holds now, [tries] times in all; a store whose
/// password was changed elsewhere meanwhile ends it with the conflict.
///
/// The new key is derived with the account's own Argon2 parameters
/// ([pulled]'s): a change of password cannot wrap the data key for the
/// recovery key again, so the parameters stay as that wrapper has them.
/// [stamp] is SyncDataService.stampForPush; [oldVerificationHash] proves the
/// old password to a server that asks for it before it takes another.
Future<PasswordChangeWritten> pushPasswordChange({
  required SyncBackend backend,
  required SyncPullResult pulled,
  required SecretKey dek,
  required SecretKey currentMek,
  required String newPassword,
  required Uint8List oldVerificationHash,
  required Future<Map<String, dynamic>> Function(Map<String, dynamic> data) stamp,
  String? deviceId,
  int tries = 3,
}) async {
  final salt = SyncService.generateSalt();
  final mek = await SyncService.deriveKey(newPassword, salt, params: pulled.argon2Params);
  final verificationHash = await SyncService.computeVerificationHash(mek);
  final wrapped = await SyncService.wrapDek(dek, mek);
  var from = pulled;
  for (var attempt = 1;; attempt++) {
    try {
      final data = await SyncService.decrypt(from.encryptedData, dek);
      final (:version, :blobSize, updatedAt: _) = await backend.push(
        data: await stamp(data),
        dek: dek,
        salt: salt,
        verificationHash: verificationHash,
        wrappedDekPassword: wrapped,
        deviceId: deviceId,
        argon2Params: pulled.argon2Params,
        authorizeHash: oldVerificationHash,
        expectedVersion: from.version,
      );
      return (
        version: version,
        blobSize: blobSize,
        salt: salt,
        mek: mek,
        verificationHash: verificationHash,
        argon2Params: pulled.argon2Params,
      );
    } on SyncConflictException {
      if (attempt >= tries) rethrow;
      final now = await backend.pull();
      // Another password than the one typed here opens it now: not this change's to replace.
      if (!listEquals(now.salt, pulled.salt) || now.wrappedDekPassword == null) rethrow;
      try {
        await SyncService.unwrapDek(now.wrappedDekPassword!, currentMek);
      } catch (_) {
        rethrow;
      }
      from = now;
    }
  }
}
