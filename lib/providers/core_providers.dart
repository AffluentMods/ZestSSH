import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/database/daos/automation_history_dao.dart';
import 'package:zestssh/database/daos/connection_groups_dao.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/host_accounts_dao.dart';
import 'package:zestssh/database/daos/identities_dao.dart';
import 'package:zestssh/database/daos/known_hosts_dao.dart';
import 'package:zestssh/database/daos/monitor_samples_dao.dart';
import 'package:zestssh/database/daos/port_forward_rules_dao.dart';
import 'package:zestssh/database/daos/scheduled_tasks_dao.dart';
import 'package:zestssh/database/daos/snippet_categories_dao.dart';
import 'package:zestssh/database/daos/command_history_dao.dart';
import 'package:zestssh/database/daos/snippets_dao.dart';
import 'package:zestssh/database/daos/terminal_triggers_dao.dart';
import 'package:zestssh/database/daos/workflows_dao.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/services/settings_service.dart';
import 'dart:io';

import 'package:zestssh/services/hardware_vault_service.dart';
import 'package:zestssh/services/mac_secure_enclave_vault_service.dart';
import 'package:zestssh/services/windows_tpm_vault_service.dart';
import 'package:zestssh/services/hardware_backed_vault.dart';
import 'package:zestssh/services/vault_slot_service.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/auth_providers.dart' show currentUserProvider;
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/services/sync_setup_state_service.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/orchards/rules/orchard_contact.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/core/errors/error_codes.dart';

// ── Async init ───────────────────────────────────────────────────

/// SharedPreferences must be awaited at app start.
/// Overridden in main.dart after initialisation.
final sharedPreferencesProvider = Provider<SharedPreferences>((ref) {
  throw UnimplementedError(
    'SharedPreferences must be overridden before use. '
    'Read the preferences store in main() and '
    'use ProviderScope overrides.',
  );
});

// ── Database ─────────────────────────────────────────────────────

/// Owns the open/closed state of the database executor.
///
/// With the 1.8 encrypting lock OFF, the database is opened at bootstrap and
/// [seed]ed here before `runApp` - behavior identical to the pre-1.8 one-shot
/// override. With the encrypting lock ON, the session starts `null` (the DB is
/// NOT opened at bootstrap); [open] runs only after a vault slot unwraps the DB
/// key, and [close] tears the DB back down on auto-lock so data-at-rest is no
/// longer decrypted while the app is locked.
class DatabaseSessionNotifier extends StateNotifier<AppDatabase?> {
  DatabaseSessionNotifier() : super(null);

  /// The database open now, told to the stores that seal their secrets with
  /// it and are reached through no provider ([SecretSeal.openTree]).
  @override
  set state(AppDatabase? value) {
    SecretSeal.openTree = value;
    super.state = value;
  }

  @override
  void dispose() {
    // Gone with its session: no store seals with a database nobody holds.
    if (identical(SecretSeal.openTree, state)) SecretSeal.openTree = null;
    super.dispose();
  }

  /// Adopt an already-opened database (the lock-OFF bootstrap path, where
  /// main.dart opened it with the migration/error-recovery handling).
  void seed(AppDatabase db) {
    _openedThisRun = true;
    state = db;
  }

  /// Another profile's database in place of the one open, with no moment
  /// without one: a screen that is up stays up. The one before closes after.
  Future<void> swap(AppDatabase next) async {
    final before = state;
    state = next;
    if (before != null && !identical(before, next)) {
      try {
        await before.close();
      } catch (_) {/* best effort: closing under live streams may throw */}
    }
  }

  /// A database that did not open after the lock's PIN: where it looks like a
  /// failed migration, the copy made before it is put back, as for [open].
  static Future<void> afterFailedOpen(Object e) async {
    if (MigrationBackupService.looksLikeMigrationFailure(e)) await _restoreLatestPreMigrationBackup();
  }

  /// In-flight open, so two rapid unlock taps (button + keyboard "done", or a
  /// re-entrant recovery submit) can't each pass the `state == null` check and
  /// open a SECOND executor on the same SQLCipher file.
  Future<void>? _opening;

  /// Open the database with a vault-unwrapped key hex (lock-ON unlock). Forces
  /// drift to run migrations now so any failure surfaces on the unlock screen,
  /// then flips the session ready. Throws on open/migration failure.
  Future<void> open(String dbKeyHex) {
    if (state != null) return Future<void>.value();
    return _opening ??=
        _open(dbKeyHex).whenComplete(() => _opening = null);
  }

  Future<void> _open(String dbKeyHex) async {
    if (state != null) return;
    final db = await (debugOpen ?? AppDatabase.openWithKeyHex)(dbKeyHex);
    try {
      // First query through drift triggers the connection + onUpgrade migrations.
      await db.customSelect('SELECT 1').get();
    } catch (e) {
      // Never leak the half-opened executor (isolate + file handle + possible
      // write lock) on a probe/migration failure - a retry would otherwise
      // stack a second connection on the same file.
      try {
        await db.close();
      } catch (_) {/* best effort */}
      // On a migration failure, restore the pre-migration backup so the user's
      // data returns to its safe pre-upgrade state instead of being stranded
      // half-migrated. This mirrors the lock-OFF recovery in main.dart, which
      // the lock-ON unlock path otherwise skipped entirely. We do NOT retry the
      // open (the same migration would fail again); the caller surfaces the
      // error and the app stays locked until a fixed build, exactly like
      // lock-OFF, but now with the data preserved rather than left mid-migration.
      if (!_openedThisRun && MigrationBackupService.looksLikeMigrationFailure(e)) {
        await _restoreLatestPreMigrationBackup();
      }
      rethrow;
    }
    _openedThisRun = true;
    _lockedKeyHex = dbKeyHex;
    state = db;
  }

  /// The key the open database is opened by, kept while the encrypting lock is
  /// on and the app unlocked (a phone or tablet; on a computer the profiles'
  /// vault holds its keys). With the lock on that key is in the storage only
  /// wrapped behind the PIN, and "Delete all local data" turns the lock off:
  /// it writes this key back as it is with the lock off, before the wrapped
  /// one goes, so the database that is open stays openable (before,
  /// the wipe deleted the wrapped key and its slots, the only
  /// copies). Null while the lock is off or the app locked. It is in the
  /// connection's memory for as long anyway.
  String? get lockedKeyHex => state == null ? null : _lockedKeyHex;
  String? _lockedKeyHex;

  /// The lock was turned on over the database that is open: its key, wrapped
  /// behind the PIN from now on ([lockedKeyHex]).
  void lockTurnedOn(String dbKeyHex) => _lockedKeyHex = dbKeyHex;

  /// The lock was turned off: the key is in the storage as it is again.
  void lockTurnedOff() => _lockedKeyHex = null;

  /// The database has opened in this run, so its migrations passed: what fails at a
  /// later unlock (it was held for a moment) is no failed upgrade, and the copy from
  /// the start of the run would lose all that was done since.
  bool _openedThisRun = false;

  /// In a test, what opens it: the suite's builds do not have the real library.
  static Future<AppDatabase> Function(String hex)? debugOpen;

  /// Puts back the copy this start made before the upgrade, and only that one:
  /// with no upgrade ahead no copy is made (3.3), and the newest copy there is
  /// is then one from an earlier upgrade, which would lose all done since.
  static Future<void> _restoreLatestPreMigrationBackup() async {
    try {
      final copy = await MigrationBackupService.madeThisRun();
      if (copy == null) return;
      await MigrationBackupService.restoreFromBackup(copy);
      AppLogger.info(
        'Restored pre-migration backup after a locked-open migration failure',
      );
    } catch (restoreError) {
      AppLogger.error(
        'Failed to restore pre-migration backup on the unlock path',
        restoreError,
      );
    }
  }

  /// Close the database on re-lock. Flips the session to `null` FIRST so no new
  /// query starts against the executor being closed, then closes it.
  Future<void> close() async {
    final db = state;
    state = null;
    _lockedKeyHex = null;
    if (db != null) {
      try {
        await db.close();
      } catch (_) {/* best effort: closing under live streams may throw */}
    }
  }
}

final databaseSessionProvider =
    StateNotifierProvider<DatabaseSessionNotifier, AppDatabase?>(
  (ref) => DatabaseSessionNotifier(),
);

/// True once the database is open and queryable. The router + startup tasks
/// gate on this so nothing touches a DAO while the app is locked.
final dbReadyProvider =
    Provider<bool>((ref) => ref.watch(databaseSessionProvider) != null);

/// Your Tree's database, whichever space the app is looking at. Code that
/// must never see an Orchard's data reads this one: personal sync, backups
/// and auto-backups, the automation engine, and the device-local state
/// (feedback queue, saved workspaces, folder-sync records). Throws while the
/// app is locked - callers on the locked surface must gate on
/// [dbReadyProvider] first.
final treeDatabaseProvider = Provider<AppDatabase>((ref) {
  final db = ref.watch(databaseSessionProvider);
  if (db == null) {
    throw StateError('Database is locked - unlock the app to open it');
  }
  return db;
});

// ── Spaces (3.0) ────────────────────────────────────────

/// The space the app is looking at: your Tree, or one of your Orchards.
/// Change it through [spaceControllerProvider], which opens an Orchard's
/// database first.
final activeSpaceProvider = StateProvider<Space>((ref) => const TreeSpace());

/// Where Orchard databases live: files beside the Tree's (tests keep them in
/// memory).
final orchardDatabaseStorageProvider = Provider<OrchardDatabaseStorage>(
    (ref) => const FileOrchardDatabaseStorage());

/// The Orchard databases open right now. They close, and the app goes back
/// to the Tree, when the Tree's database closes (the app locks). Whenever the
/// Orchard on screen closes for any reason (locking, leaving, a wipe), the
/// app goes back to the Tree rather than point at a closed database.
final orchardDatabasesProvider =
    StateNotifierProvider<OrchardDatabasesNotifier, Map<String, AppDatabase>>(
        (ref) {
  final notifier = OrchardDatabasesNotifier(
    OrchardDatabaseKeys(
      ref.read(secureStorageProvider),
      tree: () => ref.read(databaseSessionProvider),
      // A team that waits for its owner, used where it lies.
      held: Profiles.on ? (id) async => ProfileManager.instance?.heldTeamKey(id) : null,
    ),
    storage: ref.read(orchardDatabaseStorageProvider),
    // Each team is the account's that joined it: listed and opened for that
    // account only (28 October 2026). On a computer that is where it lies:
    // a team's database is inside its account's profile.
    owners: Profiles.on ? null : OrchardOwners(ref.read(secureStorageProvider)),
    account: Profiles.on ? null : () => ref.read(currentUserProvider)?.uid,
    onSetAside: (_) => ref.read(notificationCenterProvider.notifier).warning(
          gl10n.teamSetAsideTitle,
          body: ErrorCodes.withCode(gl10n.teamSetAsideBody, ErrorCodes.teamSetAside),
          dismissAfter: const Duration(seconds: 20),
        ),
    // How this device stands with ZestSSH Cloud, for a Crate's own offline
    // limit. Read when asked: what is kept of it is read afresh at each
    // unlock, and a database outlives none of them.
    contact: DeviceContact(
      read: () => ref.read(orchardContactProvider),
      now: () => ref.read(orchardContactProvider.notifier).now(),
      loaded: () => ref.read(orchardContactProvider.notifier).loaded,
    ),
  );
  ref.listen<AppDatabase?>(databaseSessionProvider, (previous, next) {
    if (next == null) {
      ref.read(activeSpaceProvider.notifier).state = const TreeSpace();
      notifier.closeAll();
    }
  });
  final stopListening = notifier.addListener((open) {
    final space = ref.read(activeSpaceProvider);
    if (space is OrchardSpace && !open.containsKey(space.orchardId)) {
      ref.read(activeSpaceProvider.notifier).state = const TreeSpace();
    }
  }, fireImmediately: false);
  ref.onDispose(stopListening);
  return notifier;
});

/// The database of [space]: your Tree's, or an open Orchard's. Null while
/// it is not open (the app is locked, or the Orchard has left the device).
AppDatabase? databaseForSpace(Ref ref, Space space) => space is OrchardSpace
    ? ref.read(orchardDatabasesProvider)[space.orchardId]
    : ref.read(databaseSessionProvider);

/// Switches the whole app to a space.
final spaceControllerProvider =
    Provider<SpaceController>((ref) => SpaceController(ref));

class SpaceController {
  SpaceController(this._ref);

  final Ref _ref;

  Future<void> switchTo(Space space) async {
    if (space is OrchardSpace) {
      await _ref.read(orchardDatabasesProvider.notifier).open(space.orchardId);
    }
    _ref.read(activeSpaceProvider.notifier).state = space;
  }
}

/// The database of the space the app is looking at: your Tree's, or an
/// Orchard's. Every screen reads this (through the DAO providers below), so
/// switching spaces switches everything at once. Throws while the app is
/// locked - callers on the locked surface must gate on [dbReadyProvider].
final databaseProvider = Provider<AppDatabase>((ref) {
  final space = ref.watch(activeSpaceProvider);
  if (space is OrchardSpace) {
    final db = ref.watch(orchardDatabasesProvider)[space.orchardId];
    if (db == null) {
      throw StateError('The Orchard database is not open');
    }
    return db;
  }
  return ref.watch(treeDatabaseProvider);
});

// ── DAOs ─────────────────────────────────────────────────────────

final connectionsDaoProvider = Provider<ConnectionsDao>((ref) {
  return ref.watch(databaseProvider).connectionsDao;
});

final identitiesDaoProvider = Provider<IdentitiesDao>((ref) {
  return ref.watch(databaseProvider).identitiesDao;
});

final connectionGroupsDaoProvider = Provider<ConnectionGroupsDao>((ref) {
  return ref.watch(databaseProvider).connectionGroupsDao;
});

final connectionTagsDaoProvider = Provider<ConnectionTagsDao>((ref) {
  return ref.watch(databaseProvider).connectionTagsDao;
});

/// The other accounts of the hosts of the space in view (3.0, accounts per
/// host).
final hostAccountsDaoProvider = Provider<HostAccountsDao>((ref) {
  return ref.watch(databaseProvider).hostAccountsDao;
});

final knownHostsDaoProvider = Provider<KnownHostsDao>((ref) {
  return ref.watch(databaseProvider).knownHostsDao;
});

final snippetsDaoProvider = Provider<SnippetsDao>((ref) {
  return ref.watch(databaseProvider).snippetsDao;
});

final snippetCategoriesDaoProvider = Provider<SnippetCategoriesDao>((ref) {
  return ref.watch(databaseProvider).snippetCategoriesDao;
});

final portForwardRulesDaoProvider = Provider<PortForwardRulesDao>((ref) {
  return ref.watch(databaseProvider).portForwardRulesDao;
});

final automationHistoryDaoProvider = Provider<AutomationHistoryDao>((ref) {
  return ref.watch(databaseProvider).automationHistoryDao;
});

final workflowsDaoProvider = Provider<WorkflowsDao>((ref) {
  return ref.watch(databaseProvider).workflowsDao;
});

final scheduledTasksDaoProvider = Provider<ScheduledTasksDao>((ref) {
  return ref.watch(databaseProvider).scheduledTasksDao;
});

/// Device-local Server Monitor history samples (not synced).
final monitorSamplesDaoProvider = Provider<MonitorSamplesDao>((ref) {
  return ref.watch(databaseProvider).monitorSamplesDao;
});

/// Trigger / highlight rules (synced across devices).
final terminalTriggersDaoProvider = Provider<TerminalTriggersDao>((ref) {
  return ref.watch(databaseProvider).terminalTriggersDao;
});

/// Synced command history (Pro feature; transport free).
final commandHistoryDaoProvider = Provider<CommandHistoryDao>((ref) {
  return ref.watch(databaseProvider).commandHistoryDao;
});

/// Search query for filtering port forward rules.
final portForwardSearchQueryProvider = StateProvider<String>((ref) => '');

/// Reactive stream of all port forward rules (for Manage tab).
final allPortForwardRulesProvider =
    StreamProvider<List<PortForwardRule>>((ref) {
  return ref.watch(portForwardRulesDaoProvider).watchAll();
});

/// Filtered port forward rules by search query.
final filteredPortForwardRulesProvider =
    StreamProvider<List<PortForwardRule>>((ref) {
  final query = ref.watch(portForwardSearchQueryProvider).toLowerCase();
  final stream = ref.watch(portForwardRulesDaoProvider).watchAll();
  if (query.isEmpty) return stream;
  return stream.map((list) => list.where((r) =>
      (r.label?.toLowerCase().contains(query) ?? false) ||
      r.remoteHost.toLowerCase().contains(query) ||
      r.bindPort.toString().contains(query)).toList());
});

/// Live saved port-forward rules for a single connection, keyed by
/// connection id. Shared by the connection editor and the per-host network
/// overrides section so both read ONE DB stream per connection rather than
/// each opening its own subscription.
final portForwardRulesForConnectionProvider =
    StreamProvider.family<List<PortForwardRule>, String>((ref, connectionId) {
  return ref
      .watch(portForwardRulesDaoProvider)
      .watchByConnection(connectionId);
});

/// Live per-`(rule, network)` state overrides for a single port-forward rule.
/// Drives the per-network 3-state port-forward controls in the host editor;
/// an empty list means every network inherits the rule's base semantics.
final portForwardNetworkOverridesForRuleProvider =
    StreamProvider.family<List<PortForwardNetworkOverrideRow>, String>(
        (ref, ruleId) {
  return ref
      .watch(portForwardRulesDaoProvider)
      .watchNetworkOverridesForRule(ruleId);
});

// ── Secure Storage ───────────────────────────────────────────────

final secureStorageProvider = Provider<FlutterSecureStorage>((ref) => appKeychain);

// ── Local Auth ───────────────────────────────────────────────────

final localAuthProvider = Provider<LocalAuthentication>((ref) {
  return LocalAuthentication();
});

// ── Encrypting-lock vault (1.8) ──────────────────────────────────

/// Wraps the SQLCipher DB key behind PIN / master-password / recovery slots.
/// Uses the same secure-storage options as everything else.
final vaultSlotServiceProvider = Provider<VaultSlotService>((ref) {
  return VaultSlotService(ref.watch(secureStorageProvider));
});

/// Hardware-backed key store for the opt-in "Hardware-backed encryption" layer
/// over the at-rest vault. Android Keystore / iOS Secure Enclave on mobile, the
/// TPM (CNG Platform Crypto Provider) on Windows, the Secure Enclave on a Mac
/// that has one (4.0; CryptoKit, through the runner), and an unavailable stub
/// on Linux (the toggle simply never appears there).
final hardwareVaultServiceProvider = Provider<HardwareBackedVault>((ref) {
  if (Platform.isAndroid || Platform.isIOS) {
    return HardwareVaultService();
  }
  if (Platform.isWindows) {
    return WindowsTpmVaultService(ref.watch(secureStorageProvider));
  }
  if (Platform.isMacOS) {
    return MacSecureEnclaveVaultService(ref.watch(secureStorageProvider));
  }
  return const UnsupportedHardwareVault();
});

// ── Services ─────────────────────────────────────────────────────

final settingsServiceProvider = Provider<SettingsService>((ref) {
  return SettingsService(ref.watch(sharedPreferencesProvider));
});

final securityLockServiceProvider = Provider<SecurityLockService>((ref) {
  return SecurityLockService(
    ref.watch(secureStorageProvider),
    ref.watch(localAuthProvider),
  );
});

final knownHostsServiceProvider = Provider<KnownHostsService>((ref) {
  return KnownHostsService(ref.watch(knownHostsDaoProvider));
});

final keyGenerationServiceProvider = Provider<KeyGenerationService>((ref) {
  return KeyGenerationService();
});

final keyImportServiceProvider = Provider<KeyImportService>((ref) {
  return KeyImportService();
});


/// Where the secrets of the space on screen's identities live: the OS
/// secure storage for your Tree, the Orchard's own database for an Orchard
/// (3.0).
final identitySecretsProvider = Provider<IdentitySecretStore>((ref) =>
    IdentitySecretStore.forDatabase(
        ref.watch(databaseProvider), ref.watch(secureStorageProvider)));

/// Personal sync and backups: always the Tree's database, never the active
/// space's, so an Orchard's data can never reach your own sync or a `.zest`
/// file (3.0).
final syncDataServiceProvider = Provider<SyncDataService>((ref) {
  final tree = ref.watch(treeDatabaseProvider);
  return SyncDataService(
    database: tree,
    connectionsDao: tree.connectionsDao,
    identitiesDao: tree.identitiesDao,
    groupsDao: tree.connectionGroupsDao,
    knownHostsDao: tree.knownHostsDao,
    snippetsDao: tree.snippetsDao,
    snippetCategoriesDao: tree.snippetCategoriesDao,
    portForwardRulesDao: tree.portForwardRulesDao,
    networksDao: tree.networksDao,
    connectionTagsDao: tree.connectionTagsDao,
    secureStorage: ref.watch(secureStorageProvider),
    settingsService: ref.watch(settingsServiceProvider),
    // Only the signed-in account's team keys travel (whitepaper re-check,
    // 18 October 2026); read when the payload is made.
    accountUid: () => ref.read(currentUserProvider)?.uid,
  );
});

final backupServiceProvider = Provider<BackupService>((ref) {
  return BackupService(ref.watch(syncDataServiceProvider));
});

// Explicit types: these three refer to each other (lazily, inside closures).
final Provider<AutoSyncService> autoSyncServiceProvider =
    Provider<AutoSyncService>((ref) {
  final service = AutoSyncService(
    syncDataService: ref.watch(syncDataServiceProvider),
    settingsService: ref.watch(settingsServiceProvider),
    secureStorage: ref.watch(secureStorageProvider),
    // Resolve the active backend lazily each cycle so a provider switch in
    // settings takes effect without recreating this service.
    resolveBackend: () => ref.read(syncBackendProvider),
    // With sync in place, make sure the account has published keys.
    onCycleSucceeded: () =>
        unawaited(ref.read(accountKeyCheckerProvider).afterSync()),
  );
  // Each lock and unlock makes a new one: the one before is let go, and runs
  // nothing more by itself (3.4.2 sweep, L2).
  ref.onDispose(service.retire);
  return service;
});

/// The signed-in account's keys (3.0), on the hosted server with the
/// account's own sign-in: the Firebase ID token, or the desktop session.
final Provider<AccountKeyService> accountKeyServiceProvider =
    Provider<AccountKeyService>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return AccountKeyService(
    api: AccountKeysApi(
      bearer: () async =>
          await AuthService.getIdToken(forceRefresh: false) ??
          await AccountSecret.sessionToken.read(storage),
    ),
    store: AccountKeyStore(storage, tree: () => ref.read(databaseSessionProvider)),
    // Newly confirmed keys go out with the next sync.
    onKeysChanged: () => ref.read(autoSyncServiceProvider).notifyLocalChange(),
  );
});

final Provider<AccountKeyChecker> accountKeyCheckerProvider =
    Provider<AccountKeyChecker>((ref) {
  return AccountKeyChecker(ref.watch(accountKeyServiceProvider));
});

/// This device's place in the account's device list (3.0): the
/// Firebase ID token on devices signed in with Firebase (which also register
/// themselves), the session token after a browser sign-in.
/// Approving a new device (3.0), with the same sign-in as
/// the device list.
final Provider<DeviceApprovalsApi> deviceApprovalsApiProvider = Provider<DeviceApprovalsApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return DeviceApprovalsApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ?? await AccountSecret.sessionToken.read(storage),
  );
});

/// What this device hands to a new device it approves (3.0):
/// its sync key and what goes with it; null while sync is not set up
/// here.
final Provider<Future<SyncHandover?> Function()> syncHandoverProvider =
    Provider<Future<SyncHandover?> Function()>((ref) => () async {
          final creds = await ref.read(autoSyncServiceProvider).readCredentials();
          final salt = fromB64urlOrStandard(await ref.read(secureStorageProvider).read(key: 'sync_salt'));
          if (creds == null || salt == null) return null;
          return SyncHandover(
            dek: creds.dek,
            verificationHash: creds.verificationHash,
            argon2Params: creds.argon2Params,
            salt: salt,
          );
        });

final Provider<DeviceSessionService> deviceSessionServiceProvider =
    Provider<DeviceSessionService>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return DeviceSessionService(
    api: DeviceSessionsApi(
      bearer: () async =>
          await AuthService.getIdToken(forceRefresh: false) ??
          await AccountSecret.sessionToken.read(storage),
    ),
    store: DeviceSessionStore(storage),
    firebaseUid: () => AuthService.currentUser?.uid,
    sessionToken: () => AccountSecret.sessionToken.read(storage),
    saveSessionToken: (token) =>
        AccountSecret.sessionToken.write(storage, token),
    labels: () async => DeviceLabels.forThisDevice(),
    saverForNow: () => renewedSessionSaver(storage),
  );
});

/// What keeps a renewed session in the profile open now and under its seal, whatever
/// opens while it is written. On a phone it is [storage] as it is.
Future<void> Function(String token) renewedSessionSaver(FlutterSecureStorage storage) {
  if (storage is! ProfileKeychain) return (token) => AccountSecret.sessionToken.write(storage, token);
  final bound = storage.boundToNow();
  return (token) => AccountSecret.sessionToken.write(bound.$1, token, tree: () => bound.$2);
}

/// Recovery codes for two-step sign-in (3.0) on ZestSSH Cloud. A
/// Firebase sign-in sends a freshly refreshed ID token, so a sign-in the
/// person just confirmed counts as recent; a browser sign-in sends its
/// session token.
final Provider<RecoveryCodesApi> recoveryCodesApiProvider =
    Provider<RecoveryCodesApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return RecoveryCodesApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: true) ??
        await AccountSecret.sessionToken.read(storage),
  );
});

final syncSetupStateServiceProvider = Provider<SyncSetupStateService>((ref) {
  return SyncSetupStateService(ref.watch(secureStorageProvider));
});

// ── App Version ─────────────────────────────────────────────────

/// Dynamic app version from `package_info_plus`.
final appVersionProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});
