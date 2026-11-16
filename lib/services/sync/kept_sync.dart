import 'dart:convert';

import 'package:cryptography/cryptography.dart' show SecretKey;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/utils/logger.dart';

// Signing in again never costs the sync setup (found in a security
// review).
//
// A device signed out without being asked (from another device, by Sign out
// everywhere, or by a change to the account's security: every password change,
// removed second step and used recovery code does it since 3.3) keeps what
// syncs it, set aside under the account it belongs to. The same account
// signing in again finds sync as it was, with no question; any other account
// finds nothing, and what was kept is gone before it can sync. The person's own
// Sign out still forgets it all, and the sign-in then ends by asking for the
// sync password ([syncAfterSignIn]).
//
// Nothing that syncs can reach it while it is set aside: the keys are not where
// sync looks for them, and it comes back only through the same steps as joining.
// What it costs is said in the whitepaper: someone who can sign in to the account,
// second step included, on this device's OS login resumes sync here without the
// sync password. That device already holds the same hosts and keys.

/// What the keys of a sign-out nobody asked for are kept as, for one account.
class KeptSync {
  KeptSync({
    required FlutterSecureStorage storage,
    required AppDatabase? Function() tree,
    required AutoSyncService autoSync,
    required SyncSetupStateService setup,
    required SettingsService settings,
    required SyncDataService data,
  })  : _storage = storage,
        _tree = tree,
        _autoSync = autoSync,
        _setup = setup,
        _settings = settings,
        _data = data;

  final FlutterSecureStorage _storage;
  final AppDatabase? Function() _tree;
  final AutoSyncService _autoSync;
  final SyncSetupStateService _setup;
  final SettingsService _settings;
  final SyncDataService _data;

  /// Sets aside what syncs this device, for the account [uid], before sync is
  /// taken apart on it. False, with nothing kept, where this device holds no
  /// complete set (sync is not set up here, or a sealed key does not open).
  Future<bool> keep(String uid) async {
    try {
      if (!await _setup.isSyncActive()) return false;
      final tree = _tree();
      final dek = await openKept(tree, 'sync_dek', await _storage.read(key: 'sync_dek'));
      final verification = await AccountSecret.syncVerification.read(_storage, tree: _tree);
      final salt = await _storage.read(key: 'sync_salt');
      final params = await _storage.read(key: 'sync_argon2_params');
      if (dek == null || dek.isEmpty || verification == null || verification.isEmpty || salt == null) return false;
      await AccountSecret.keptSync.write(
        _storage,
        jsonEncode({
          'uid': uid,
          'dek': dek,
          'verification': verification,
          'salt': salt,
          'params': params,
          'version': _settings.syncServerVersion,
          'content': _settings.syncContentHash,
          'dirty': _settings.syncDirty,
          'recovery': _settings.syncRecoveryKeySet,
        }),
        tree: _tree,
      );
      await _data.setSyncBaseAside();
      return true;
    } catch (e) {
      // It costs the sync password at the next sign-in, and nothing else.
      AppLogger.warning('Sync: its keys could not be kept for the next sign-in ($e)');
      return false;
    }
  }

  /// The account [uid] signed in: where this device kept its sync, it is put
  /// back, as joining puts it, and true comes back. Kept for another account, or
  /// where another store was set up meanwhile, it is forgotten.
  Future<bool> resume(String uid) async {
    final raw = await AccountSecret.keptSync.read(_storage, tree: _tree);
    if (raw == null) return false;
    final kept = _KeptKeys.parse(raw);
    if (kept == null || kept.uid != uid || await _setup.isSyncActive()) {
      await forget();
      return false;
    }
    await _autoSync.storeSyncCredentials(
      SecretKey(base64Decode(kept.dek)),
      base64Decode(kept.verification),
      argon2Params: kept.params,
    );
    await _storage.write(key: 'sync_salt', value: kept.salt);
    await _settings.setSyncServerVersion(kept.version);
    await _settings.setSyncContentHash(kept.content);
    await _settings.setSyncDirty(kept.dirty);
    await _settings.setSyncRecoveryKeySet(kept.recovery);
    await _data.takeSyncBaseBack();
    await _setup.markCompleteViaJoin(salt: base64Decode(kept.salt));
    await AccountSecret.keptSync.delete(_storage);
    _autoSync.resetFailures();
    return true;
  }

  /// Forgets what was kept: another account signed in, or this device's data
  /// goes.
  Future<void> forget() async {
    await AccountSecret.keptSync.delete(_storage);
    await _data.dropSyncBaseAside();
  }
}

class _KeptKeys {
  const _KeptKeys({
    required this.uid,
    required this.dek,
    required this.verification,
    required this.salt,
    required this.params,
    required this.version,
    required this.content,
    required this.dirty,
    required this.recovery,
  });

  final String uid;
  final String dek;
  final String verification;
  final String salt;
  final Map<String, dynamic>? params;
  final int version;
  final String content;
  final bool dirty;
  final bool? recovery;

  static _KeptKeys? parse(String raw) {
    try {
      final j = jsonDecode(raw) as Map<String, dynamic>;
      final params = j['params'];
      return _KeptKeys(
        uid: j['uid'] as String,
        dek: j['dek'] as String,
        verification: j['verification'] as String,
        salt: j['salt'] as String,
        params: params is String ? jsonDecode(params) as Map<String, dynamic> : null,
        version: j['version'] as int,
        content: j['content'] as String,
        dirty: j['dirty'] as bool,
        recovery: j['recovery'] as bool?,
      );
    } catch (_) {
      return null;
    }
  }
}

/// What the end of a sign-in does about sync.
enum SyncAfterSignIn {
  /// Nothing: there is nothing to bring back, or it was asked already.
  nothing,

  /// Sync came back by itself: this device kept it through a sign-out nobody
  /// asked for ([KeptSync]).
  resumed,

  /// The account syncs with ZestSSH Cloud and this device is not in it: ask for
  /// the sync password.
  ask,
}

/// What the end of a sign-in by the account [uid] does: the sync this device
/// kept for it comes back; else, once for each sign-in ([SettingsService.syncTurnOnAsked]),
/// an account that keeps its data on ZestSSH Cloud is asked to bring this device
/// back in. Not knowing yet (no network) asks nothing and leaves it for the next
/// start.
Future<SyncAfterSignIn> syncAfterSignIn({
  required String uid,
  required KeptSync kept,
  required SyncSetupStateService setup,
  required SettingsService settings,
  required SyncBackend Function() backend,
}) async {
  if (await kept.resume(uid)) return SyncAfterSignIn.resumed;
  if (settings.syncTurnOnAsked) return SyncAfterSignIn.nothing;
  final store = backend();
  // A store of one's own needs no account, and stays through every sign-out.
  if (!store.kind.isHosted) return SyncAfterSignIn.nothing;
  if (await setup.isSyncActive()) {
    await settings.setSyncTurnOnAsked(true);
    return SyncAfterSignIn.nothing;
  }
  try {
    await store.verifyEntitlement();
    final status = await store.getStatus();
    await settings.setSyncTurnOnAsked(true);
    return status.hasData ? SyncAfterSignIn.ask : SyncAfterSignIn.nothing;
  } on SyncHostingRequiredException {
    await settings.setSyncTurnOnAsked(true);
    return SyncAfterSignIn.nothing;
  } catch (e) {
    AppLogger.warning('Sync: whether this account syncs could not be asked after its sign-in ($e)');
    return SyncAfterSignIn.nothing;
  }
}
