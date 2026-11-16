import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/sync/dumb_store_sync_backend.dart';
import 'package:zestssh/services/sync/google_drive_sync_backend.dart';
import 'package:zestssh/services/sync/kept_sync.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/sync/webdav_sync_backend.dart';
import 'package:zestssh/services/sync/zest_server_backend.dart';
import 'package:zestssh/providers/security_providers.dart' show vaultSessionProvider;
import 'package:zestssh/services/profiles/mac_keychain.dart' show KeychainAccessDenied;
import 'package:zestssh/services/sync/sync_disconnect.dart';
import 'package:zestssh/services/sync/unread_sync_store.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';

/// A request for the account page's own "Sync now", the one that asks for the
/// sync password again and brings this device's keys up to the account's:
/// made by the "Sync now" on a notice that says sync paused because the keys
/// no longer match. The app opens the account page for it, and the page
/// starts its Sync now and takes the request back.
final accountSyncNowRequestProvider = StateProvider<bool>((_) => false);

/// A request for the account page to ask for the sync password, at the end of
/// a sign-in on a device that is not in the account's sync
/// ([SyncAfterSignIn.ask]): the app opens the account page for it, and the page
/// asks and takes the request back.
final accountTurnSyncOnRequestProvider = StateProvider<bool>((_) => false);

/// What syncs this device, kept through a sign-out nobody asked for.
final keptSyncProvider = Provider<KeptSync>((ref) => KeptSync(
      storage: ref.watch(secureStorageProvider),
      tree: () => ref.read(treeDatabaseProvider),
      autoSync: ref.watch(autoSyncServiceProvider),
      setup: ref.watch(syncSetupStateServiceProvider),
      settings: ref.watch(settingsServiceProvider),
      data: ref.watch(syncDataServiceProvider),
    ));

/// Construct the concrete [SyncBackend] for a given config. Pure - no I/O.
class SyncBackendFactory {
  const SyncBackendFactory._();

  static SyncBackend build(SyncProviderConfig c) {
    switch (c.kind) {
      case SyncBackendKind.zestServer:
        return ZestServerBackend.hosted();
      case SyncBackendKind.custom:
        return ZestServerBackend(
          baseUrl: (c.serverUrl ?? '').trim(),
          staticToken: c.serverToken,
          requiresEntitlement: false,
          kind: SyncBackendKind.custom,
        );
      case SyncBackendKind.webdav:
        return WebDavSyncBackend(
          serverUrl: c.webdavUrl ?? '',
          username: c.webdavUsername ?? '',
          password: c.webdavPassword ?? '',
          remotePath: c.webdavPath,
          label: c.label,
        );
      case SyncBackendKind.s3:
        return S3SyncBackend(
          endpoint: c.s3Endpoint ?? '',
          region: c.s3Region ?? '',
          bucket: c.s3Bucket ?? '',
          accessKeyId: c.s3AccessKeyId ?? '',
          secretAccessKey: c.s3SecretAccessKey ?? '',
          prefix: c.s3Prefix,
          usePathStyle: c.s3UsePathStyle,
          label: c.label,
        );
      case SyncBackendKind.googleDrive:
        return GoogleDriveSyncBackend();
    }
  }
}

/// The persisted sync-provider configuration.
///
/// Seeds to the hosted ZestSSH Cloud, then asynchronously loads any saved
/// config from secure storage. Startup code should `await ensureLoaded()`
/// BEFORE auto-sync starts so a bring-your-own user's first cycle doesn't
/// briefly run against the wrong backend.
final syncProviderConfigProvider =
    NotifierProvider<SyncProviderConfigNotifier, SyncProviderConfig>(
  SyncProviderConfigNotifier.new,
);

class SyncProviderConfigNotifier extends Notifier<SyncProviderConfig> {
  /// The single in-flight (or completed) load. Shared so that a second
  /// [ensureLoaded] caller AWAITS the same read instead of returning early -
  /// otherwise startup could proceed (and start auto-sync) before the saved
  /// config had actually been applied to [state], briefly running a
  /// bring-your-own user against the hosted default.
  Future<void>? _loadFuture;

  /// Whether this notifier is gone (its container disposed): a read that
  /// ends after that says nothing.
  bool _gone = false;

  @override
  SyncProviderConfig build() {
    ref.onDispose(() => _gone = true);
    // Kick off the async load; state updates in place when it completes.
    // ensureLoaded() gives startup a way to await it deterministically.
    unawaited(ensureLoaded());
    return const SyncProviderConfig.zestServer();
  }

  /// Whether [_loadFuture] is still running.
  bool _loading = false;

  /// What the last read of the kept choice failed with; null where it was
  /// read (or none is kept). Said to the rest of the app as
  /// [syncStoreUnreadProvider].
  Object? _unread;

  /// Whether the store sync uses is not known: its kept choice could not be
  /// read (3.4.2). [state] is then the hosted default, and is not to be
  /// taken for ZestSSH Cloud: nothing syncs ([syncBackendProvider] is an
  /// [UnreadSyncStore]), a sign-out deletes none of sync's keys, and the
  /// kept choice is not written over ([save]).
  bool get unknown => _unread != null;

  /// What the read failed with, while [unknown].
  Object? get unreadBecause => _unread;

  /// Reads the kept choice, once; where that read failed, again at each ask
  /// until it is read (3.4.2: a failed read was never read again in the run,
  /// and the hosted default stood for it). On a Mac a key macOS said no to is
  /// not asked about again until the person chooses Try again
  /// (KeychainDenials), so asking again here brings up no question.
  Future<void> ensureLoaded() {
    if (_loadFuture != null && !_loading && unknown) _loadFuture = null;
    return _loadFuture ??= _load();
  }

  /// Reads the kept choice again where it could not be read: Try again,
  /// after macOS said no to it.
  Future<void> readAgain() => ensureLoaded();

  Future<void> _load() async {
    _loading = true;
    try {
      await _doLoad();
    } finally {
      _loading = false;
    }
  }

  void _setUnread(Object? why) {
    _unread = why;
    if (!_gone) ref.read(syncStoreUnreadProvider.notifier).state = why;
  }

  Future<void> _doLoad() async {
    // (Never inside build, which starts this: what it says goes to another
    // provider.)
    await Future<void>.value();
    try {
      // Sealed while the encrypting lock is on (AccountSecret): where the
      // app is locked now, read at the unlock, and the load (which startup
      // awaits before sync's first cycle) waits for it. Nothing syncs while
      // locked, and a sealed store is never read as none, so the setting
      // is never lost.
      final raw = await AccountSecret.syncStore.readOnceOpen(ref.read(secureStorageProvider));
      var config = const SyncProviderConfig.zestServer();
      if (raw != null && raw.isNotEmpty) {
        final map = jsonDecode(raw) as Map<String, dynamic>;
        config = SyncProviderConfig.fromJson(map);
      }
      // What a sign-out made while it was not known owes, before anything
      // can sync with it.
      await _settleOwedDisconnect(config);
      if (_gone) return;
      state = config;
      _setUnread(null);
      AppLogger.info('Sync provider loaded: ${config.kind.name}');
    } catch (e) {
      // Not known, and not taken for ZestSSH Cloud: read again at the next
      // ask ([ensureLoaded]).
      AppLogger.warning('The store sync uses could not be read: ${errorKind(e)}'
          '${KeychainAccessDenied.statusOf(e) == null ? '' : ' (${KeychainAccessDenied.statusOf(e)})'}');
      _setUnread(e);
    }
  }

  /// A sign-out made while the store was not known ([unknown]) deleted none
  /// of sync's keys and owes it ([SettingsService.syncDisconnectOwed]): now
  /// that the store is [config], ZestSSH Cloud's sync is forgotten here as
  /// that sign-out would have done (set aside first for the account it names,
  /// where one is), and a store of one's own is left as it is. Throws where
  /// that could not be done: the store is then not known still, and nothing
  /// syncs.
  Future<void> _settleOwedDisconnect(SyncProviderConfig config) async {
    final settings = ref.read(settingsServiceProvider);
    final owed = settings.syncDisconnectOwed;
    if (owed == null) return;
    if (config.kind.isHosted) {
      await forgetHostedSyncHere(ref.read, keepFor: owed.isEmpty ? null : owed);
      AppLogger.info('Sync: what a sign-out owed is done now that the store is known (ZestSSH Cloud)');
    }
    await settings.setSyncDisconnectOwed(null);
  }

  /// Persist and switch to a new config. Refused while the kept choice could
  /// not be read ([unknown]), so that it is not written over unseen
  /// (SyncStoreUnknownException); where it was read and could not be made
  /// sense of (not a refusal of the keychain), [overUnreadable] lets the
  /// person's own choice in the storage screen take its place.
  Future<void> save(SyncProviderConfig config, {bool overUnreadable = false}) async {
    final unread = _unread;
    if (unread != null && (!overUnreadable || KeychainAccessDenied.statusOf(unread) != null)) {
      throw SyncStoreUnknownException(unread);
    }
    await AccountSecret.syncStore.write(ref.read(secureStorageProvider), jsonEncode(config.toJson()));
    // Mark the initial load as satisfied so a late ensureLoaded() can't
    // overwrite this just-saved config with a stale disk read.
    if (unread != null) _loadFuture = null;
    _loadFuture ??= Future<void>.value();
    state = config;
    if (unread != null) _setUnread(null);
    AppLogger.info('Sync provider switched to: ${config.kind.name}');
  }

  /// Reset back to the hosted ZestSSH Cloud (used when a user disconnects a
  /// bring-your-own store).
  Future<void> resetToHosted() async {
    await save(const SyncProviderConfig.zestServer());
  }
}

/// Why the store sync uses could not be read on this device (3.4.2), or
/// null where it was read, or none is kept
/// ([SyncProviderConfigNotifier.unknown]). Set by that notifier only.
final syncStoreUnreadProvider = StateProvider<Object?>((_) => null);

/// Whether the store sync uses is known to be ZestSSH Cloud: false while it
/// could not be read (3.4.2), as for a store of the person's own. What goes
/// to ZestSSH Cloud only where it is the store (a recovery proof, a device's
/// approval) asks this, not the hosted default that stands in meanwhile.
final syncStoreKnownHostedProvider = Provider<bool>(
    (ref) => ref.watch(syncStoreUnreadProvider) == null && ref.watch(syncProviderConfigProvider).kind.isHosted);

/// Forgets ZestSSH Cloud's sync on this device, as a sign-out does: set aside
/// first for the account [keepFor] where one is given (KeptSync), then sync's
/// key, salt and setup state deleted, and changes waiting to go dropped.
Future<void> forgetHostedSyncHere(T Function<T>(ProviderListenable<T> provider) read, {String? keepFor}) async {
  if (keepFor != null) await read(keptSyncProvider).keep(keepFor);
  await disconnectSyncOnThisDevice(
    autoSync: read(autoSyncServiceProvider),
    setup: read(syncSetupStateServiceProvider),
    settings: read(settingsServiceProvider),
    secureStorage: read(secureStorageProvider),
    lockVault: () => read(vaultSessionProvider.notifier).lock(),
  );
}

/// The active [SyncBackend], rebuilt whenever the provider config changes.
/// While the store could not be read it is an [UnreadSyncStore], which
/// refuses every request: nothing goes to ZestSSH Cloud in its stead.
final syncBackendProvider = Provider<SyncBackend>((ref) {
  final unread = ref.watch(syncStoreUnreadProvider);
  if (unread != null) return UnreadSyncStore(unread);
  final config = ref.watch(syncProviderConfigProvider);
  final backend = SyncBackendFactory.build(config);
  // Dumb-store backends hold a reused http.Client; close it when the config
  // changes and this provider is rebuilt/disposed so socket pools don't leak.
  ref.onDispose(() {
    if (backend is DumbStoreSyncBackend) backend.dispose();
  });
  return backend;
});

/// Convenience: is the active backend a free bring-your-own store?
final syncIsBringYourOwnProvider = Provider<bool>((ref) {
  return !ref.watch(syncProviderConfigProvider).kind.isHosted;
});

/// Whether sync is fully set up on THIS device: first-time setup landed and
/// the first push was acknowledged (SyncSetupStateService.isSyncActive, the
/// one source of truth for "sync is on").
///
/// Backend-agnostic on purpose: the hosted ZestSSH Cloud and a free
/// bring-your-own store (WebDAV, S3, Google Drive, a custom server) both
/// count. Sync itself is free on every tier; only the hosted storage is the
/// Juiced purchase, so UI copy must key "Sync is on / off" on this rather than
/// on the Juiced entitlement.
///
/// Re-evaluated whenever sync status or the backend config changes, so it
/// flips without a restart once setup completes or sync is disconnected.
final syncIsActiveProvider = FutureProvider<bool>((ref) async {
  ref.watch(syncStatusProvider);
  ref.watch(syncProviderConfigProvider);
  return ref.watch(syncSetupStateServiceProvider).isSyncActive();
});
