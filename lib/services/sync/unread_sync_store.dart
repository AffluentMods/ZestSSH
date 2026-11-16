import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_kind.dart';

/// The store sync uses on this device could not be read (3.4.2), so it is not
/// known: neither ZestSSH Cloud nor a store of the person's own. A Mac's
/// keychain that macOS did not let ZestSSH read is the usual cause, said as
/// that, with its code ([keychain]); any other, as the store's setting not
/// read. Until it is read, nothing syncs, and nothing that would delete
/// sync's keys or write over the kept choice goes on.
///
/// (Before, a failed read left the hosted default in place for the whole run:
/// sync went to ZestSSH Cloud with the keys of a store of one's own, and a
/// sign-out deleted those keys as if they were ZestSSH Cloud's.)
class SyncStoreUnknownException extends SyncException {
  SyncStoreUnknownException(this.cause)
      : super(
          KeychainAccessDenied.statusOf(cause) != null
              ? ErrorCodes.withCode(gl10n.macKeychainDeniedTitle, ErrorCodes.macKeychainDenied)
              : gl10n.syncStoreNotRead,
          detail: 'The sync storage setting could not be read: ${errorKind(cause)}'
              '${KeychainAccessDenied.statusOf(cause) == null ? '' : ' (${KeychainAccessDenied.statusOf(cause)})'}',
        );

  /// What the read failed with.
  final Object cause;

  /// Whether macOS did not let ZestSSH read it: Try again on that notice
  /// reads it again.
  bool get keychain => KeychainAccessDenied.statusOf(cause) != null;

  @override
  String toString() => 'SyncStoreUnknownException(${errorKind(cause)})';

  @override
  String get typeName => 'SyncStoreUnknownException';
}

/// The store sync uses, while it could not be read
/// ([SyncStoreUnknownException]): every request to it fails with that, so
/// sync, a setup, a join, a reset and a recovery all stop before they ask
/// any store anything.
class UnreadSyncStore implements SyncBackend {
  UnreadSyncStore(this.cause);

  /// What the read of the store's setting failed with.
  final Object cause;

  Never _refuse() => throw SyncStoreUnknownException(cause);

  /// Not ZestSSH Cloud: nothing is said or done as if it were.
  @override
  SyncBackendKind get kind => SyncBackendKind.custom;

  @override
  String get displayName => '';

  @override
  bool get requiresEntitlement => false;

  @override
  Future<void> checkConnection() async => _refuse();

  @override
  Future<SyncStatus> getStatus() async => _refuse();

  @override
  Future<SyncPullResult> pull() async => _refuse();

  @override
  Future<({int version, int blobSize, DateTime? updatedAt})> push({
    required Map<String, dynamic> data,
    required SecretKey dek,
    required Uint8List salt,
    required Uint8List verificationHash,
    String? deviceId,
    Uint8List? wrappedDekPassword,
    Uint8List? wrappedDekRecovery,
    Uint8List? recoverySalt,
    Uint8List? recoveryHash,
    int? expectedVersion,
    bool createOnly = false,
    Map<String, dynamic>? argon2Params,
    Uint8List? authorizeHash,
    Uint8List? authorizeRecoveryHash,
  }) async =>
      _refuse();

  @override
  Future<bool> verifyPassword(SecretKey mek) async => _refuse();

  @override
  Future<void> verifyEntitlement() async => _refuse();

  @override
  Future<RecoveryPullResult> pullWithRecoveryKey(String recoveryKey) async => _refuse();

  @override
  Future<void> purge(Uint8List verificationHash) async => _refuse();

  @override
  Future<void> deleteAccount(Uint8List verificationHash) async => _refuse();
}
