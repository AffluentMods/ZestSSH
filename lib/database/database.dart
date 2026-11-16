import 'dart:ffi';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/common.dart' show CommonDatabase;
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:zestssh/database/daos/connection_groups_dao.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/host_accounts_dao.dart';
import 'package:zestssh/database/daos/identities_dao.dart';
import 'package:zestssh/database/daos/known_hosts_dao.dart';
import 'package:zestssh/database/daos/automation_history_dao.dart';
import 'package:zestssh/database/daos/monitor_samples_dao.dart';
import 'package:zestssh/database/daos/networks_dao.dart';
import 'package:zestssh/database/daos/port_forward_rules_dao.dart';
import 'package:zestssh/database/daos/snippets_dao.dart';
import 'package:zestssh/database/daos/scheduled_tasks_dao.dart';
import 'package:zestssh/database/daos/snippet_categories_dao.dart';
import 'package:zestssh/database/daos/sftp_sync_manifest_dao.dart';
import 'package:zestssh/database/daos/command_history_dao.dart';
import 'package:zestssh/database/daos/terminal_triggers_dao.dart';
import 'package:zestssh/database/daos/tombstones_dao.dart';
import 'package:zestssh/database/daos/workflows_dao.dart';
import 'package:zestssh/database/tables/automation_history.dart';
import 'package:zestssh/database/tables/connection_groups.dart';
import 'package:zestssh/database/tables/connection_tags.dart';
import 'package:zestssh/database/tables/host_accounts.dart';
import 'package:zestssh/database/tables/connections.dart';
import 'package:zestssh/database/tables/identities.dart';
import 'package:zestssh/database/tables/known_hosts.dart';
import 'package:zestssh/database/tables/monitor_samples.dart';
import 'package:zestssh/database/tables/networks.dart';
import 'package:zestssh/database/tables/port_forward_network_overrides.dart';
import 'package:zestssh/database/tables/orchard_sync.dart';
import 'package:zestssh/database/tables/port_forward_rules.dart';
import 'package:zestssh/database/tables/scheduled_tasks.dart';
import 'package:zestssh/database/tables/snippet_categories.dart';
import 'package:zestssh/database/tables/snippets.dart';
import 'package:zestssh/database/tables/sftp_sync_manifest.dart';
import 'package:zestssh/database/tables/feedback_queue.dart';
import 'package:zestssh/database/tables/support_tickets.dart';
import 'package:zestssh/database/tables/local_state.dart';
import 'package:zestssh/database/tables/command_history.dart';
import 'package:zestssh/database/tables/terminal_triggers.dart';
import 'package:zestssh/database/tables/tombstones.dart';
import 'package:zestssh/database/tables/workflows.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show kItemEditedAtMaxMs;
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/services/migration_backup_service.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/utils/type_name.dart';

part 'database.g.dart';

/// Open the bundled SQLCipher on macOS deterministically.
///
/// macOS ships a system `libsqlite3` that other pods (firebase_auth,
/// google_sign_in) can pull into the process. A flat `DynamicLibrary.process()`
/// lookup may then bind sqlite3 symbols to that vanilla build instead of
/// SQLCipher, which trips the `cipher_version` fail-closed check and surfaces as
/// a "database error". The app bundles and links `SQLCipher.framework`, so we
/// open its binary by an absolute path derived from the running executable -
/// every sqlite3 symbol then resolves from SQLCipher. Falls back to `process()`
/// if the bundle layout ever differs (the cipher_version check still guards it).
///
/// The previous override opened `sqlcipher.framework/sqlcipher`, a relative path
/// that never resolves inside a `.app`, so macOS could not open its DB at all.
DynamicLibrary _openSqlcipherMacOS() {
  try {
    final contents = File(Platform.resolvedExecutable).parent.parent.path;
    final lib = p.join(contents, 'Frameworks', 'SQLCipher.framework',
        'Versions', 'A', 'SQLCipher');
    if (File(lib).existsSync()) return DynamicLibrary.open(lib);
  } catch (_) {}
  return DynamicLibrary.process();
}

/// Open the bundled SQLCipher on Linux.
///
/// `sqlcipher_flutter_libs` compiles SQLCipher straight INTO the plugin's own
/// shared object (`libsqlcipher_flutter_libs_plugin.so`) on Linux - it does NOT
/// ship a standalone `libsqlcipher.so` (that filename only exists on Android,
/// which is why the package's `openCipherOnAndroid` helper uses it). The plugin
/// `.so` is bundled under the app's `lib/` and already loaded into the process
/// at startup, and it exports the sqlite3 C ABI, so we open it by name. Falls
/// back to the legacy standalone name, then to a flat process lookup; either
/// way the `cipher_version` fail-closed check downstream still refuses a vanilla
/// sqlite3. The previous override opened `libsqlcipher.so`, a file that does not
/// exist in a Linux bundle, so the DB could not open at all ("Failed to load
/// dynamic library 'libsqlcipher.so'").
DynamicLibrary _openSqlcipherLinux() {
  for (final name in const [
    'libsqlcipher_flutter_libs_plugin.so',
    'libsqlcipher.so',
  ]) {
    try {
      return DynamicLibrary.open(name);
    } catch (_) {}
  }
  return DynamicLibrary.process();
}

/// Thrown when post-migration integrity checks fail.
///
/// Contains diagnostic details about what failed so the caller (main.dart)
/// can log the error and show a meaningful message to the user.
class MigrationIntegrityException implements Exception, HasTypeName {
  final String message;
  final int fromVersion;
  final int toVersion;
  final List<String> failures;

  const MigrationIntegrityException({
    required this.message,
    required this.fromVersion,
    required this.toVersion,
    required this.failures,
  });

  @override
  String toString() =>
      'MigrationIntegrityException: $message\n'
      'Migration: v$fromVersion -> v$toVersion\n'
      'Failures:\n${failures.map((f) => '  - $f').join('\n')}';

  @override
  String get typeName => 'MigrationIntegrityException';
}

/// Thrown when the data on this device was written by a newer ZestSSH: its
/// version ([fileVersion]) is higher than the one this app knows
/// ([appVersion]). Nothing is changed: the file keeps its version, and the
/// error screen says to update ZestSSH and offers nothing that changes data.
///
/// The open went ahead without a word and stamped the file with the older
/// version, so the older app ran on newer data: a remote screen read as an
/// SSH host, and in a team an edit of it by the older app cleared its options
/// for everyone (found in a code audit). The words here name no table or
/// step, so nothing takes it for a failed upgrade and puts a copy back.
class DatabaseNewerThanApp implements Exception, HasTypeName {
  const DatabaseNewerThanApp(this.fileVersion, this.appVersion);

  final int fileVersion;
  final int appVersion;

  @override
  String toString() =>
      'DatabaseNewerThanApp: the data was written by a newer ZestSSH (data version $fileVersion, this app '
      'reads up to $appVersion). Update ZestSSH to open it.';

  @override
  String get typeName => 'DatabaseNewerThanApp';
}

/// Key used to store the SQLCipher encryption key in FlutterSecureStorage.
/// The Orchard item kind of a team-pinned host key (3.0).
const String kHostKeyKind = 'hostkey';

/// What an Orchard database's write guard says when a change would move a
/// team's host to another kind class (ConnectionProtocol.kindClassOf): from
/// FTPS or a remote screen into another kind of host, or the other way
/// ([AppDatabase.createOrchardTriggers]).
const String kTeamHostKindRefused = 'orchard-host-kind';

const _dbEncryptionKeyId = 'zestssh_db_encryption_key';

/// The keychain, as everything else opens it: the profile's own names on a
/// computer (lib/services/profiles/keychain.dart).
FlutterSecureStorage get _secureStorage => appKeychain;

@DriftDatabase(
  tables: [
    Connections,
    Identities,
    ConnectionGroups,
    KnownHosts,
    Snippets,
    SnippetCategories,
    PortForwardRules,
    PortForwardNetworkOverrides,
    AutomationHistory,
    Workflows,
    ScheduledTasks,
    Networks,
    HostNetworkOverrides,
    ConnectionTags,
    HostAccounts,
    MonitorSamples,
    Tombstones,
    SftpSyncManifest,
    FeedbackQueue,
    LocalState,
    TerminalTriggers,
    CommandHistory,
    CrateItemsMeta,
    CrateLeftovers,
    CrateOutbox,
    OrchardInfo,
    OrchardCrates,
    SpaceKeys,
    OrchardSecrets,
    OrchardSyncControl,
    MemberKeys,
    OrchardRecordEntries,
    ChangeNext,
    TeamHostKeys,
    SupportTickets,
    TicketOutbox,
  ],
  daos: [
    ConnectionsDao,
    IdentitiesDao,
    ConnectionGroupsDao,
    KnownHostsDao,
    SnippetsDao,
    SnippetCategoriesDao,
    PortForwardRulesDao,
    AutomationHistoryDao,
    WorkflowsDao,
    ScheduledTasksDao,
    NetworksDao,
    ConnectionTagsDao,
    HostAccountsDao,
    MonitorSamplesDao,
    TombstonesDao,
    SftpSyncManifestDao,
    TerminalTriggersDao,
    CommandHistoryDao,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.e, {this.ownFolder})
      : skipMigrationBackup = false,
        isOrchard = false;

  /// An Orchard's own database (3.0): the same schema as the Tree's,
  /// plus the triggers that record every change of an item for its Crate's
  /// sync. It never makes the pre-migration backup, which copies the Tree's
  /// file; an Orchard's data is also on the server.
  AppDatabase.orchard(super.e)
      : skipMigrationBackup = true,
        isOrchard = true,
        ownFolder = null;

  /// For testing - inject an executor. [skipMigrationBackup] defaults to
  /// TRUE here so a test that drives the real onUpgrade path never reaches
  /// into the production app-data directory to copy the live encrypted DB
  /// (see [backupDatabase]). Production always uses the unnamed constructor
  /// and keeps the pre-migration backup.
  AppDatabase.forTesting(super.e,
      {this.skipMigrationBackup = true, this.isOrchard = false}) : ownFolder = null;

  /// The folder this database is in, where it is not the open profile's: a
  /// sign-in opens the next profile beside the one on screen, and an upgrade
  /// that runs then copies this database, not that one.
  final Directory? ownFolder;

  /// When true, onUpgrade skips [backupDatabase]. Only tests set this.
  final bool skipMigrationBackup;

  /// True for an Orchard's database, false for the Tree's.
  final bool isOrchard;

  /// This app's schema version, for what must know it before a database opens
  /// (whether opening one will upgrade it: [MigrationBackupService]).
  static const int currentSchemaVersion = 56;

  /// What every connection to the app's own database file is set to as it
  /// opens: write-ahead logging, and a wait of up to five seconds for a lock
  /// another connection holds. With no wait, a write while another process
  /// held the file (`zestssh admin` beside the open app, or a second start)
  /// failed at once with "database is locked" (found in a code audit).
  static void applyConnectionSettings(CommonDatabase rawDb) {
    rawDb.execute('PRAGMA busy_timeout = 5000');
    rawDb.execute('PRAGMA journal_mode = WAL');
  }

  @override
  int get schemaVersion => currentSchemaVersion;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (Migrator m) async {
      await m.createAll();
      await _createUpdatedAtTriggers();
    },
    beforeOpen: (details) async {
      // A host's other accounts are looked up by their identity: the index
      // a new install has (3.0, 17 October 2026: the step that made the
      // table did not make it, so a database upgraded from 2.3.0 or a test
      // build before this went without; made here where it is missing).
      await customStatement(_hostAccountsIdentityIndexSql);
      if (isOrchard) {
        // The outbox triggers are made again on every open, so an Orchard
        // database always has this version's.
        await createOrchardTriggers();
        // A sync that stopped halfway (the app was closed) must not leave
        // the outbox triggers switched off.
        await customStatement(
          'UPDATE orchard_sync_control SET applying = 0 WHERE id = 1',
        );
      }
      // The version it opened at, its migrations passed: the next start makes
      // no copy of it unless it is to be upgraded, and the copies kept are cut
      // (every way a database opens comes here). Not an Orchard's (it makes no
      // copy) nor a test's (it would reach the real app data).
      if (!skipMigrationBackup && !isOrchard) {
        await MigrationBackupService.noteOpened(schemaVersion, folder: ownFolder);
      }
    },
    onUpgrade: (Migrator m, int from, int to) async {
      // Data from a newer ZestSSH: drift comes here for any version that
      // differs, and every step below is "from < n", so none ran and the
      // file was stamped with this older version. It is left as it is.
      if (from > to) throw DatabaseNewerThanApp(from, to);
      // An Orchard's triggers read its Crate tables, and SQLite will not
      // drop or rename a column a trigger names: they go before any step,
      // and beforeOpen makes this version's again.
      if (isOrchard) await _dropOrchardTriggers();
      // Auto-backup before any migration so data is recoverable.
      // Skipped under tests so the migration path never copies the real
      // profile's DB out of the app-data directory.
      if (!skipMigrationBackup) {
        try {
          await AppDatabase.backupDatabase(ownFolder);
        } catch (_) {
          // Don't let backup failure prevent migration
        }
      }

      // Record pre-migration table row counts for integrity verification.
      final preMigrationCounts = await _recordTableCounts(m);

      if (from < 2) {
        await m.createTable(snippets);
      }
      if (from < 3) {
        await _addColumnIfAbsent(m, connections, connections.snippetId);
        await _addColumnIfAbsent(m, connections, connections.connectViaId);
        await _addColumnIfAbsent(m, snippets, snippets.confirmBeforeRun);
        await _addColumnIfAbsent(m, snippets, snippets.isDefault);
      }
      if (from < 4) {
        // Wake-on-LAN fields
        await _addColumnIfAbsent(m, connections, connections.wolMacAddress);
        await _addColumnIfAbsent(
          m,
          connections,
          connections.wolBroadcastAddress,
        );
        await _addColumnIfAbsent(m, connections, connections.wolPort);
      }
      if (from < 5) {
        // Port forward rules table
        await m.createTable(portForwardRules);
      }
      if (from < 6) {
        // Color labels for identities
        await _addColumnIfAbsent(m, identities, identities.colorIndex);
      }
      if (from < 7) {
        // Performance indices for frequently queried columns
        await m.createIndex(
          Index(
            'idx_connections_label',
            'CREATE INDEX IF NOT EXISTS idx_connections_label ON connections (label)',
          ),
        );
        await m.createIndex(
          Index(
            'idx_connections_host',
            'CREATE INDEX IF NOT EXISTS idx_connections_host ON connections (host)',
          ),
        );
        await m.createIndex(
          Index(
            'idx_known_hosts_host',
            'CREATE INDEX IF NOT EXISTS idx_known_hosts_host ON known_hosts (host)',
          ),
        );
      }
      if (from < 8) {
        // Automation history + workflows tables
        await m.createTable(automationHistory);
        await m.createTable(workflows);
      }
      if (from < 9) {
        // Scheduled tasks table (WorkManager-backed background automation)
        await m.createTable(scheduledTasks);
      }
      if (from < 10) {
        // Environment variables per connection (JSON key-value pairs)
        await _addColumnIfAbsent(m, connections, connections.envVars);
      }
      if (from < 11) {
        // SSH agent forwarding toggle per connection
        await _addColumnIfAbsent(m, connections, connections.forwardAgent);
      }
      if (from < 12) {
        // v1.6 Networks feature: named environments + per-host overrides
        await m.createTable(networks);
        await m.createTable(hostNetworkOverrides);
        // Indices declared on HostNetworkOverrides via @TableIndex
        // are created automatically as part of createTable.
      }
      if (from < 13) {
        // Free-form tags per connection. Composite PK on
        // (connectionId, tag); the tag indices declared on the
        // table are created automatically as part of createTable.
        await m.createTable(connectionTags);
      }
      if (from < 14) {
        // SSH user certificates + hardware-token / agent-backed
        // identities. We add nullable columns to Identities so
        // existing rows keep working untouched - every old row
        // is implicitly authMethod='password'|'publicKey' with no
        // cert metadata and `usesAgent = false`.
        await _addColumnIfAbsent(m, identities, identities.certSerial);
        await _addColumnIfAbsent(m, identities, identities.certKeyId);
        await _addColumnIfAbsent(m, identities, identities.certPrincipals);
        await _addColumnIfAbsent(m, identities, identities.certCaFingerprint);
        await _addColumnIfAbsent(m, identities, identities.certValidBefore);
        await _addColumnIfAbsent(m, identities, identities.certValidAfter);
        await _addColumnIfAbsent(m, identities, identities.agentSocketPath);
        await _addColumnIfAbsent(m, identities, identities.usesAgent);
      }
      if (from < 15) {
        // Network-aware port forwarding (v1.5). New nullable
        // column on PortForwardRules so existing rules keep the
        // pre-v1.5 semantics ("auto-start on every network").
        // Setting a value pins the rule to a specific Network -
        // the auto-start path skips it when the active network
        // doesn't match.
        await _addColumnIfAbsent(
          m,
          portForwardRules,
          portForwardRules.networkId,
        );
      }
      if (from < 16) {
        // Legacy SSH algorithm support per connection.
        // Off by default - only enabled when the user opts in
        // for a specific host (typically Proxmox LXC containers
        // and other older OpenSSH servers).
        await _addColumnIfAbsent(m, connections, connections.compatibilityMode);
      }
      if (from < 17) {
        // User-picked group accent colors. Nullable - existing
        // groups keep their legacy name-hash color until the user
        // explicitly picks one from the context menu.
        await _addColumnIfAbsent(
          m,
          connectionGroups,
          connectionGroups.colorIndex,
        );
      }
      if (from < 18) {
        // Customizable Hosts home screen (Part B): per-host card size
        // tier (default Medium), pinned-as-a-synced-property (was a
        // per-device SharedPreferences set), and an optional user note.
        // All have column defaults so existing rows migrate untouched.
        await _addColumnIfAbsent(m, connections, connections.sizeTier);
        await _addColumnIfAbsent(m, connections, connections.pinned);
        await _addColumnIfAbsent(m, connections, connections.note);
      }
      if (from < 19) {
        // v1.6 Networks completion: per-(port-forward rule, network)
        // enable state. Purely additive - the absence of a row means
        // "inherit", so every existing port-forward rule keeps its exact
        // pre-v1.6 autoStart + networkId-pin semantics until the user
        // toggles one for a specific network. The (ruleId, networkId)
        // unique key + indices declared on the table are created
        // automatically as part of createTable.
        await m.createTable(portForwardNetworkOverrides);
      }
      if (from < 20) {
        // v1.6 Server Monitor: opt-in agentless SSH polling. Additive
        // boolean column (default false) mirroring `pinned` - a host is
        // polled by the background monitor only after the user explicitly
        // enables it. Existing rows migrate untouched (default false).
        await _addColumnIfAbsent(m, connections, connections.monitored);
      }
      if (from < 21) {
        // User-picked folder (group) icons. Nullable - existing groups
        // keep their default folder glyph until the user picks one from
        // the folder editor. Mirrors the v17 colorIndex step exactly.
        await _addColumnIfAbsent(
          m,
          connectionGroups,
          connectionGroups.iconCodePoint,
        );
      }
      if (from < 22) {
        // Snippet-category ("group") metadata: per-category display order,
        // accent color, and hidden state so those PERSIST + SYNC. Purely
        // additive - a category with no row keeps the pre-v22 defaults
        // (alpha order, no color, visible), so existing snippets migrate
        // untouched. Rows are created lazily on first customization.
        await m.createTable(snippetCategories);
      }
      if (from < 23) {
        // 1.7 snippet detail pane: an optional JSON `metadata` column on
        // Snippets holding a snippet description + per-variable
        // descriptions. Purely additive and nullable - existing snippets
        // migrate untouched (NULL = no description). Variable *defaults*
        // live in the command (`${VAR:-default}`), so no data is moved.
        await _addColumnIfAbsent(m, snippets, snippets.metadata);
      }
      if (from < 24) {
        // Custom colour labels: a nullable ARGB `colorValue` on every
        // coloured entity, overriding the palette `colorIndex` when set so
        // users can pick ANY colour (not just a preset). Additive +
        // nullable - existing rows migrate untouched (NULL = keep the
        // index / default behaviour).
        await _addColumnIfAbsent(m, connections, connections.colorValue);
        await _addColumnIfAbsent(m, identities, identities.colorValue);
        await _addColumnIfAbsent(
          m,
          connectionGroups,
          connectionGroups.colorValue,
        );
        await _addColumnIfAbsent(
          m,
          snippetCategories,
          snippetCategories.colorValue,
        );
        await _addColumnIfAbsent(m, networks, networks.colorValue);
      }
      if (from < 25) {
        // Unattended-runs opt-in: a device-local boolean on identities
        // (default false) that authorises a saved credential for headless
        // automation (scheduled workflows / deep links / API keys). Additive
        // + defaulted, so existing identities migrate untouched and stay
        // OFF - no credential becomes usable by a no-user-present run until
        // the user opts it in. Deliberately NOT added to the sync blob (see
        // the column doc): it's a per-device trust decision.
        await _addColumnIfAbsent(m, identities, identities.allowUnattended);
      }
      if (from < 26) {
        // v1.6 Port Forwarding Advanced options: per-rule reconnect /
        // exit-on-failure / gateway-ports (-g LAN exposure) toggles + a
        // free-form sshFlags field. All additive with safe defaults, so
        // existing rules migrate untouched (reconnect ON, exit-on-fail ON,
        // gateway OFF, no extra flags). gatewayPorts is force-disabled on
        // sync restore - never expose beyond loopback without re-approval.
        await _addColumnIfAbsent(
          m,
          portForwardRules,
          portForwardRules.reconnect,
        );
        await _addColumnIfAbsent(
          m,
          portForwardRules,
          portForwardRules.exitOnFailure,
        );
        await _addColumnIfAbsent(
          m,
          portForwardRules,
          portForwardRules.gatewayPorts,
        );
        await _addColumnIfAbsent(
          m,
          portForwardRules,
          portForwardRules.sshFlags,
        );
      }
      if (from < 27) {
        // v1.6 Server Monitor host detail pane: device-local metric history.
        // A new append-only samples table (one row per completed check),
        // deliberately NOT added to the sync blob - it is device-specific
        // observation, not configuration. Additive create, so existing rows
        // migrate untouched. Retention (48h full-res → 15-min averages to
        // 30d → discard) is enforced at runtime by MonitorHistoryService.
        await m.createTable(monitorSamples);
      }
      if (from < 28) {
        // Tombstones (delete-propagation): a synced table of
        // "(entityType, entityId) deleted at deletedAt" markers, so a record
        // deleted on one device is removed on the others instead of being
        // re-added by the union-merge. Purely additive - a new table; existing
        // rows migrate untouched.
        await m.createTable(tombstones);
      }
      if (from < 29) {
        // Universal "newest wins": give the 5 previously-timestamp-less synced
        // tables an `updatedAt` so tombstone arbitration compares real edit
        // times instead of always delete-wins. Idempotent add (the helper skips
        // it where an earlier createTable already added it - snippet_categories
        // @v22, networks @v12); backfill from createdAt so existing rows aren't
        // treated as "never edited".
        await _addColumnIfAbsent(
            m, connectionGroups, connectionGroups.updatedAt);
        await _addColumnIfAbsent(m, identities, identities.updatedAt);
        await _addColumnIfAbsent(m, networks, networks.updatedAt);
        await _addColumnIfAbsent(
            m, portForwardRules, portForwardRules.updatedAt);
        await _addColumnIfAbsent(
            m, snippetCategories, snippetCategories.updatedAt);
        await _backfillUpdatedAtFromCreatedAt('connection_groups');
        await _backfillUpdatedAtFromCreatedAt('identities');
        await _backfillUpdatedAtFromCreatedAt('networks');
        await _backfillUpdatedAtFromCreatedAt('port_forward_rules');
        // snippet_categories has no created_at → leave null (delete-wins until
        // first edited on v29+).
        await _createUpdatedAtTriggers();
      }
      if (from < 30) {
        // SFTP per-host directory pins: a nullable JSON column on
        // connections so pins ride the existing connection sync. Purely
        // additive; the connection sync blob needs no version bump because an
        // older client simply ignores the unknown `pins` field (no data loss).
        await _addColumnIfAbsent(m, connections, connections.pins);
      }
      if (from < 31) {
        // known_hosts provenance: `recordedDevice` (the machine that first
        // recorded a host key, SYNCED so an adopted key shows where it came
        // from) and `locallyVerified` (DEVICE-LOCAL, defaults true so existing
        // TOFU'd rows stay confirmed; a vault-adopted key starts false so the
        // first local connect fires the provenance notice). Purely additive.
        await _addColumnIfAbsent(m, knownHosts, knownHosts.recordedDevice);
        await _addColumnIfAbsent(m, knownHosts, knownHosts.locallyVerified);
      }
      if (from < 32) {
        // Re-scope known_hosts trust by the jump route: add a nullable
        // `viaScope` (NULL = direct connection, so every existing pinned key
        // keeps matching byte-for-byte) and widen the natural key to
        // {host, port, keyType, viaScope} so two different servers reached via
        // different jump hosts at the same destination host:port no longer
        // collide into one trust record. That unique key is a table-level
        // constraint SQLite cannot ALTER, so rebuild the table from the current
        // schema with drift's TableMigration, defaulting via_scope to NULL for
        // every existing row (idempotent + row-count-preserving). The rebuild
        // drops the table's index, so recreate idx_known_hosts_host after.
        // drift marks TableMigration experimental; this step (schema 32) has shipped and stays.
        // ignore: experimental_member_use
        await m.alterTable(TableMigration(
          knownHosts,
          newColumns: [knownHosts.viaScope],
        ));
        await customStatement(
          'CREATE INDEX IF NOT EXISTS idx_known_hosts_host '
          'ON known_hosts (host)',
        );
      }
      if (from < 33) {
        // Device-local folder-sync manifest (spec §4). Purely additive: a new
        // table only, no existing row touched, never synced or backed up.
        await m.createTable(sftpSyncManifest);
      }
      if (from < 34) {
        // SFTP remember-last-folder (spec §2): the host default rides on the
        // connection record. Three nullable columns, purely additive; synced
        // (sync blob v14).
        await _addColumnIfAbsent(m, connections, connections.lastRemotePath);
        await _addColumnIfAbsent(m, connections, connections.lastRemoteUser);
        await _addColumnIfAbsent(m, connections, connections.lastRemotePathAt);
      }
      if (from < 35) {
        // Unsent in-app reports (help/feedback/support spec 3b) move from
        // plaintext preferences into the encrypted database. A new
        // device-local table only; never synced or backed up. Any leftover
        // preferences queue is imported once by FeedbackService.retryQueued.
        await m.createTable(feedbackQueue);
      }
      if (from < 36) {
        // Tab snapshots, saved workspaces and folder-pin counters (all of
        // which name SFTP folders and remote users) move from plaintext
        // preferences into the encrypted database. A new device-local
        // key-value table only; never synced or backed up. The preference
        // copies are imported once by their readers and then removed.
        await m.createTable(localState);
      }
      if (from < 37) {
        // Trigger / highlight rules (2.0): a synced, tombstoned table of user
        // regexes watched in terminal output. Purely additive; its auto-bump
        // updatedAt trigger is (idempotently) registered below.
        await m.createTable(terminalTriggers);
        await _createUpdatedAtTriggers();
      }
      if (from < 38) {
        // Synced command history (2.0): the commands the user ran, captured
        // client-side. Purely additive; its auto-bump updatedAt trigger is
        // (idempotently) registered below.
        await m.createTable(commandHistory);
        await _createUpdatedAtTriggers();
      }
      if (from < 39) {
        // Command-history record extension (2.0 Phase 2b): exit code, duration
        // and working directory, captured from OSC 133 / OSC 7 shell
        // integration. Purely additive nullable columns; LOCAL-ONLY (stripped
        // from the sync dump), so the blob shape and schema_version are
        // unchanged.
        await _addColumnIfAbsent(m, commandHistory, commandHistory.exitCode);
        await _addColumnIfAbsent(m, commandHistory, commandHistory.durationMs);
        await _addColumnIfAbsent(m, commandHistory, commandHistory.cwd);
      }
      if (from < 40) {
        // Host-card icon override (2.0): a chosen built-in icon and an optional
        // uploaded custom icon, both SYNCED. Additive nullable columns; the
        // sync blob schema version bumps 16 -> 17 to signal the new fields.
        await _addColumnIfAbsent(m, connections, connections.iconId);
        await _addColumnIfAbsent(m, connections, connections.customIcon);
      }
      if (from < 41) {
        // Orchard bookkeeping (3.0): which Crate each item is in, copies
        // left in Crates items moved out of, local changes waiting to sync,
        // the Orchard and its Crates as this device knows them, opened keys,
        // the keys' secrets and the sync control row. Only an Orchard's own
        // database fills them; in the Tree's they stay empty.
        await m.createTable(crateItemsMeta);
        await m.createTable(crateLeftovers);
        await m.createTable(crateOutbox);
        await m.createTable(orchardInfo);
        await m.createTable(orchardCrates);
        await m.createTable(spaceKeys);
        await m.createTable(orchardSecrets);
        await m.createTable(orchardSyncControl);
        await m.createTable(memberKeys);
      }
      if (from < 42) {
        // Member fingerprints (3.0) came after a v41 test build had gone
        // out, so a database that build made has neither the members table
        // nor the Orchard's members tag. Both are made only when absent: a
        // database made at v41 by a later build already has them.
        await _createTableIfAbsent(m, memberKeys);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.membersTag);
      }
      if (from < 43) {
        // The Orchard's record (3.0): its entries as this device checked
        // them, and what follows from them for this account (what it may do,
        // its standing, each Crate's switches and settings) and for each
        // member. Additive, each step safe to repeat.
        await _createTableIfAbsent(m, orchardRecordEntries);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.can);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.status);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.rotationDue);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.recordProblem);
        await _addColumnIfAbsent(m, orchardCrates, orchardCrates.switches);
        await _addColumnIfAbsent(m, orchardCrates, orchardCrates.ownersOnly);
        await _addColumnIfAbsent(m, orchardCrates, orchardCrates.allow);
        await _addColumnIfAbsent(m, orchardCrates, orchardCrates.rotationDue);
        await _addColumnIfAbsent(m, memberKeys, memberKeys.status);
        await _addColumnIfAbsent(m, memberKeys, memberKeys.endsAt);
      }
      if (from < 44) {
        // Removing people and replacing keys (3.0): members whose account
        // was deleted since the record added them, and who wrote the version
        // of each item this device holds. Additive, safe to repeat.
        await _addColumnIfAbsent(m, memberKeys, memberKeys.accountDeleted);
        await _addColumnIfAbsent(m, crateItemsMeta, crateItemsMeta.author);
      }
      if (from < 45) {
        // The Orchard's rules (3.0): the rules from its record, what the
        // server says this account falls short of, and each Crate's "ask
        // again before revealing". Additive, safe to repeat.
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.rules);
        await _addColumnIfAbsent(m, orchardInfo, orchardInfo.held);
        await _addColumnIfAbsent(m, orchardCrates, orchardCrates.confirmReveal);
      }
      if (from < 46) {
        // Trust on the Team page (3.0 UI): a member whose keys were
        // replaced since this device's person compared them, the date this
        // device first saw each record entry, and the keys to change after
        // someone lost access. Additive, safe to repeat.
        await _addColumnIfAbsent(m, memberKeys, memberKeys.replacedSinceCompared);
        await _addColumnIfAbsent(m, orchardRecordEntries, orchardRecordEntries.firstSeen);
        await _createTableIfAbsent(m, changeNext);
      }
      if (from < 47) {
        // Team-pinned host keys (3.0): an Orchard item kind, so only an
        // Orchard's own database fills it. Additive, safe to repeat.
        await _createTableIfAbsent(m, teamHostKeys);
      }
      if (from < 48) {
        // The trash (3.0): whether the Crate's copy of an item is a
        // deletion, since bringing it back is adding it. Additive; an item
        // this device holds no row of, based on a copy in its Crate and not
        // waiting to be sent, was deleted there.
        await _addColumnIfAbsent(m, crateItemsMeta, crateItemsMeta.serverDeleted);
        await markServerDeletions();
      }
      if (from < 49) {
        // Password managers (3.0): whose agent holds an agent-backed
        // key, and where a password in a password manager lives. Additive.
        await _addColumnIfAbsent(m, identities, identities.agentSource);
        await _addColumnIfAbsent(m, identities, identities.passwordRef);
      }
      if (from < 50) {
        // Cloud import (3.0): where a host was imported from. Additive and
        // synced (blob 19 -> 20); in an Orchard it travels in the record.
        await _addColumnIfAbsent(m, connections, connections.cloudSource);
      }
      if (from < 51) {
        // Tickets (3.0, S1): the tickets this device has sent, each with the
        // token that makes it readable, and follow-ups waiting to be sent.
        // Two new device-local tables; never synced or backed up. Additive,
        // safe to repeat.
        await _createTableIfAbsent(m, supportTickets);
        await _createTableIfAbsent(m, ticketOutbox);
      }
      if (from < 52) {
        // What colours a host's icon (3.0): its own colour (the default, and
        // what every host there is gets), the colour of the host's label, or
        // a custom one. Additive and synced (blob 20 -> 21); in an Orchard it
        // travels in the record.
        await _addColumnIfAbsent(m, connections, connections.iconColor);
      }
      if (from < 53) {
        // The other accounts of a host (3.0, accounts per host): identities
        // it can also be signed in to with, beside its default, which stays
        // connections.identity_id. A new table, empty; in an Orchard it
        // travels with the host in its record, and its triggers are made
        // when the database opens.
        await _createTableIfAbsent(m, hostAccounts);
      }
      if (from < 54) {
        // A key's password, tried after the key (3.0, accounts per host):
        // false for every identity there is, so a password left from before
        // an identity became a key is never sent. Additive and synced (in
        // blob 22); in an Orchard it travels in the key's record, and the
        // triggers that carry the record's columns are made again when the
        // database opens.
        await _addColumnIfAbsent(m, identities, identities.passwordAfterKey);
      }
      if (from < 55) {
        // A remote screen's options (4.0, VNC hosts): null for every host
        // there is, and left out of what syncs and of a team's record while
        // null, so an SSH host travels as it did. Additive; in an Orchard the
        // triggers that carry the record's columns are made again when the
        // database opens.
        await _addColumnIfAbsent(m, connections, connections.screenOptions);
      }
      if (from < 56) {
        // A team host's shared SFTP bookmarks (4.0): null for every host
        // there is. In an Orchard it travels in the host's record, and only
        // while it holds one, so every record stays what it was; personal
        // sync never carries it. Additive; the triggers that carry the
        // record's columns are made again when the database opens.
        await _addColumnIfAbsent(m, connections, connections.sharedPins);
      }

      // Verify migration didn't corrupt data.
      await _verifyMigrationIntegrity(m, from, to, preMigrationCounts);

      // Migration succeeded - cap the pre-migration DB copies so they don't
      // accumulate forever (each is a full plaintext-referencing DB copy).
      await _pruneOldDatabaseBackups(keep: 2, folder: ownFolder);
    },
  );

  /// The index of [HostAccounts] by identity, as its table declares it
  /// (`idx_host_accounts_identity`), made on every open where it is missing
  /// (the step that made the table made no index: see beforeOpen).
  static const _hostAccountsIdentityIndexSql =
      'CREATE INDEX IF NOT EXISTS idx_host_accounts_identity ON host_accounts (identity_id)';

  /// Creates [table] unless the database already has it.
  Future<void> _createTableIfAbsent(Migrator m, TableInfo table) async {
    final rows = await customSelect(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?",
      variables: [Variable<String>(table.actualTableName)],
    ).get();
    if (rows.isEmpty) await m.createTable(table);
  }

  /// Idempotent replacement for [Migrator.addColumn].
  ///
  /// A migration that `createTable`s a table in an EARLIER step builds it from
  /// the CURRENT schema - which already contains columns introduced in LATER
  /// steps - so a subsequent `addColumn` for one of those columns throws
  /// `duplicate column name` and aborts the whole upgrade. Example: the from<22
  /// step creates `snippet_categories` (already carrying `color_value`), then
  /// the from<24 step tries to add `color_value` again. `networks` (created
  /// at from<12) hit the identical trap. The migration-backup/restore layer
  /// can likewise re-run a step against a DB that already has the column.
  /// Checking `PRAGMA table_info` first makes every column-add safe to repeat.
  Future<void> _addColumnIfAbsent(
    Migrator m,
    TableInfo table,
    GeneratedColumn column,
  ) async {
    final rows = await customSelect(
      'PRAGMA table_info("${table.actualTableName}")',
    ).get();
    final exists = rows.any((r) => r.read<String>('name') == column.name);
    if (!exists) {
      await m.addColumn(table, column);
    }
  }

  /// Backfill a freshly-added nullable `updated_at` from the row's `created_at`
  /// so pre-v29 rows aren't treated as "never edited" (null) by the cloud-sync
  /// newest-wins tombstone arbitration. Guarded on BOTH columns existing: the
  /// migration-test harness seeds minimal id-only stub tables that have neither
  /// `created_at` nor rows, so a bare `UPDATE ... SET updated_at = created_at`
  /// would throw `no such column: created_at`. The real DB always has both.
  Future<void> _backfillUpdatedAtFromCreatedAt(String table) async {
    final rows =
        await customSelect('PRAGMA table_info("$table")').get();
    final names = rows.map((r) => r.read<String>('name')).toSet();
    if (names.contains('updated_at') && names.contains('created_at')) {
      await customStatement(
        'UPDATE $table SET updated_at = created_at WHERE updated_at IS NULL',
      );
    }
  }

  /// Tables whose `updatedAt` is auto-bumped on every edit by a trigger, so
  /// cloud-sync tombstone "newest wins" always has a real modification time
  /// without every DAO write site having to remember to set it. The trigger
  /// only fires when the write did NOT set `updated_at` (an ordinary edit), so
  /// the sync restore's EXPLICIT updated_at is preserved. Value = the table's
  /// primary-key column. (connections/snippets/overrides are excluded: they set
  /// updatedAt in their own write + restore paths, and connections must not
  /// bump on a mere `lastConnected` touch.)
  static const _updatedAtTriggerTables = {
    'connection_groups': 'id',
    'identities': 'id',
    'networks': 'id',
    'port_forward_rules': 'id',
    'snippet_categories': 'name',
    'terminal_triggers': 'id',
    'command_history': 'id',
  };

  /// The rows each Orchard item is made of: table -> (item kind, the column
  /// naming the item, the columns that stay on this device). A host is its
  /// connection plus its tags, per-network overrides and other accounts; a key is its
  /// identity plus its secrets; a port forward is its rule plus its
  /// per-network overrides.
  ///
  /// The columns that stay on the device never travel in a record and never
  /// queue a change: when you last connected and the last folder you were in
  /// (sharing those with a team would be an activity log), and
  /// your own arrangement (pins, order, card size, what is expanded, what is
  /// monitored, your default key, auto-start). A host's shared SFTP
  /// bookmarks (`shared_pins`, 4.0) are the team's, not yours, so they
  /// travel. `updated_at` is local bookkeeping; a record carries its own
  /// edit time.
  static const orchardItemTables = <String, (String, String, Set<String>)>{
    'connections': ('host', 'id', {
      'updated_at',
      'last_connected',
      'last_remote_path',
      'last_remote_user',
      'last_remote_path_at',
      'pinned',
      'monitored',
      'pins',
      'sort_order',
      'size_tier',
    }),
    'connection_tags': ('host', 'connection_id', {}),
    'host_network_overrides': ('host', 'connection_id', {'updated_at'}),
    'host_accounts': ('host', 'connection_id', {}),
    'identities': ('key', 'id', {
      'updated_at',
      'is_default',
      'allow_unattended',
      'agent_socket_path',
    }),
    'orchard_secrets': ('key', 'identity_id', {}),
    'connection_groups': ('group', 'id', {'updated_at', 'sort_order', 'is_expanded'}),
    'snippets': ('snippet', 'id', {'updated_at', 'sort_order'}),
    'snippet_categories': ('category', 'name', {'updated_at', 'sort_order', 'hidden'}),
    // Where a forward listens, gateway ports and extra ssh flags are each
    // device's own, as in a personal space's sync: a teammate's record could
    // open a listener to every member's network, or put a command into the
    // ssh command a member copies (they travelled).
    'port_forward_rules': ('forward', 'id', {'updated_at', 'auto_start', 'bind_address', 'gateway_ports', 'ssh_flags'}),
    'port_forward_network_overrides': ('forward', 'rule_id', {'updated_at'}),
    'networks': ('network', 'id', {'updated_at', 'sort_order'}),
    'terminal_triggers': ('trigger', 'id', {'updated_at', 'sort_order', 'enabled'}),
    // Team-pinned host keys: writing one needs edit, not add.
    'team_host_keys': (kHostKeyKind, 'id', {}),
  };

  /// The columns of an Orchard item table that travel in its record: every
  /// column but the ones that stay on this device.
  List<String> orchardRecordColumns(String table) {
    final spec = orchardItemTables[table];
    if (spec == null) {
      throw ArgumentError.value(table, 'table', 'not an Orchard item table');
    }
    final info = allTables.firstWhere((t) => t.actualTableName == table);
    return [
      for (final c in info.$columns)
        if (!spec.$3.contains(c.name)) c.name,
    ];
  }

  /// Tells every open query on the Orchard item tables, and on which Crate
  /// each item is in, to read again. The sync engine writes rows with plain
  /// SQL, which queries do not see by themselves, so it calls this after it
  /// writes.
  void notifyOrchardItemsChanged() => notifyUpdates({
        for (final t in allTables)
          if (orchardItemTables.containsKey(t.actualTableName)) TableUpdate.onTable(t),
        TableUpdate.onTable(crateItemsMeta),
      });

  /// Drops every Orchard trigger (the outbox and the write guards).
  Future<void> _dropOrchardTriggers() async {
    final triggers = await customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND (name LIKE 'trg_ob_%' OR name LIKE 'trg_gd_%')")
        .get();
    for (final t in triggers) {
      await customStatement('DROP TRIGGER IF EXISTS "${t.read<String>('name')}"');
    }
  }

  /// (Re)create the Orchard outbox triggers (Orchard databases only). Every
  /// insert and delete of an item's rows, and every update that changes a
  /// column its record carries, queues that item with this device's time and
  /// a change number that rises each time, unless the sync engine is writing
  /// changes from the server (orchard_sync_control.applying = 1). An update
  /// that renames an item's key queues both names. Dropped and made again,
  /// so a migration that adds a column refreshes them.
  Future<void> createOrchardTriggers() async {
    await customStatement(
      'INSERT OR IGNORE INTO orchard_sync_control (id, applying, change_seq) '
      'VALUES (1, 0, 0)',
    );
    const quiet =
        '(SELECT applying FROM orchard_sync_control WHERE id = 1) IS NOT 1';
    const nowMs =
        "CAST((julianday('now') - 2440587.5) * 86400000.0 AS INTEGER)";
    // Delete, then insert: never a conflict clause inside a trigger, because
    // SQLite applies the conflict policy of the statement that fired it
    // (an upsert or INSERT OR IGNORE would turn OR REPLACE into a failure,
    // or into keeping an old change number).
    // A change is later than the version it replaces, whatever this
    // device's clock says: a device that runs behind would stamp its edit
    // older than the version it edited, and every device refuses a version
    // older than the one it holds (CrateSyncEngine, found in a client
    // security review). Never past the latest time a record
    // may say (itemEditedAfter, orchard_crypto.dart): a member's version
    // stamped there made every later change one past it, which every other
    // device refused (found in a security review).
    String later(String kind, String key) =>
        'MIN(MAX($nowMs, COALESCE((SELECT edited_at FROM crate_items_meta '
        "WHERE kind = '$kind' AND item_key = $key), 0) + 1), $kItemEditedAtMaxMs)";
    String queue(String kind, String key) =>
        'UPDATE orchard_sync_control SET change_seq = change_seq + 1 WHERE id = 1; '
        "DELETE FROM crate_outbox WHERE kind = '$kind' AND item_key = $key; "
        'INSERT INTO crate_outbox (kind, item_key, change_seq, edited_at) '
        "VALUES ('$kind', $key, "
        '(SELECT change_seq FROM orchard_sync_control WHERE id = 1), ${later(kind, key)});';
    // A write this account may not make is refused before it happens (3.0):
    // no screen can leave a change on this device that its Crate
    // does not allow, which would never sync. An item not on the server yet
    // needs add in its Crate (the one it was placed in, else where new items
    // go); one that is needs edit to change it, and delete to remove it.
    // Local-only columns (pins, order, last connected) and changes the sync
    // engine applies from the server are not checked.
    String crateOf(String kind, String key) =>
        "COALESCE((SELECT crate_id FROM crate_items_meta WHERE kind = '$kind' AND item_key = $key), "
        '(SELECT default_crate_id FROM orchard_info WHERE id = 1))';
    String has(String kind, String key, String what) =>
        'EXISTS (SELECT 1 FROM orchard_crates WHERE crate_id = ${crateOf(kind, key)} '
        "AND switches LIKE '%\"$what\"%')";
    // A copy in the Crate that is a deletion (the trash) is not there:
    // bringing the item back is adding it.
    String onServer(String kind, String key) =>
        "EXISTS (SELECT 1 FROM crate_items_meta WHERE kind = '$kind' AND item_key = $key "
        'AND server_revision IS NOT NULL AND server_deleted = 0)';
    // A team-pinned host key is trust for everyone in the Crate: only
    // someone who may edit it writes one, new or not.
    String may(String kind, String key, String what) => kind == kHostKeyKind
        ? has(kind, key, what)
        : '((NOT ${onServer(kind, key)} AND ${has(kind, key, 'add')}) OR '
            '(${onServer(kind, key)} AND ${has(kind, key, what)}))';
    const refuse = "SELECT RAISE(ABORT, 'orchard-access');";
    final mainTables = <String>{};
    final kinds = <String>{};
    for (final e in orchardItemTables.entries) {
      if (kinds.add(e.value.$1)) mainTables.add(e.key);
    }
    for (final entry in orchardItemTables.entries) {
      final table = entry.key;
      final (kind, column, _) = entry.value;
      final changed = orchardRecordColumns(table)
          .map((c) => 'NEW."$c" IS NOT OLD."$c"')
          .join(' OR ');
      for (final suffix in const ['ins', 'upd', 'del']) {
        await customStatement('DROP TRIGGER IF EXISTS trg_ob_${table}_$suffix');
        await customStatement('DROP TRIGGER IF EXISTS trg_gd_${table}_$suffix');
      }
      await customStatement(
        'CREATE TRIGGER trg_gd_${table}_ins BEFORE INSERT ON $table '
        'WHEN $quiet AND NOT ${may(kind, 'NEW.$column', 'edit')} BEGIN $refuse END;',
      );
      await customStatement(
        'CREATE TRIGGER trg_gd_${table}_upd BEFORE UPDATE ON $table '
        'WHEN $quiet AND ($changed) AND NOT (${may(kind, 'OLD.$column', 'edit')} AND '
        '${may(kind, 'NEW.$column', 'edit')}) BEGIN $refuse END;',
      );
      await customStatement(
        'CREATE TRIGGER trg_gd_${table}_del BEFORE DELETE ON $table '
        "WHEN $quiet AND NOT ${may(kind, 'OLD.$column', mainTables.contains(table) ? 'delete' : 'edit')} "
        'BEGIN $refuse END;',
      );
      await customStatement(
        'CREATE TRIGGER trg_ob_${table}_ins AFTER INSERT ON $table '
        'WHEN $quiet BEGIN ${queue(kind, 'NEW.$column')} END;',
      );
      await customStatement(
        'CREATE TRIGGER trg_ob_${table}_upd AFTER UPDATE ON $table '
        'WHEN $quiet AND ($changed) '
        'BEGIN ${queue(kind, 'NEW.$column')} ${queue(kind, 'OLD.$column')} END;',
      );
      await customStatement(
        'CREATE TRIGGER trg_ob_${table}_del AFTER DELETE ON $table '
        'WHEN $quiet BEGIN ${queue(kind, 'OLD.$column')} END;',
      );
    }
    // A team's host never changes kind class (ConnectionProtocol.kindClassOf):
    // SSH-like, FTPS (3.4), a VNC screen or an RDP one (4.0; the two are
    // apart because an RDP host gives its key's password to whatever answers
    // at its address, which a VNC host turned into one would do to a server
    // nobody chose for that). A version before a class
    // reads its records not at all (orchard_crypto.dart, kItemRecordFormat),
    // so a host it holds that turned into one would stay there as it was, and
    // a change of its own to it would replace the host. Within a class it may
    // change (SSH to Mosh, explicit to implicit FTPS). Its own changes alone:
    // what the sync engine writes is not checked here but where it is
    // written (OrchardItemStore.write refuses such a record). The class lists
    // come from the enum (storedNamesOfClass), so they cannot drift from it.
    String inList(int kindClass) =>
        "(${ConnectionProtocol.storedNamesOfClass(kindClass).map((n) => "'$n'").join(', ')})";
    // Every class above the first by its names; anything else is the first
    // (an unknown or missing protocol among it, read as SSH).
    String classOf(String row) => 'CASE '
        '${[
          for (final kindClass in ConnectionProtocol.kindClasses)
            if (kindClass != ConnectionProtocol.kindClassShell)
              "WHEN COALESCE($row.protocol, '') IN ${inList(kindClass)} THEN $kindClass ",
        ].join()}'
        'ELSE ${ConnectionProtocol.kindClassShell} END';
    await customStatement('DROP TRIGGER IF EXISTS trg_gd_connections_kind');
    await customStatement(
      'CREATE TRIGGER trg_gd_connections_kind BEFORE UPDATE OF protocol ON connections '
      'WHEN $quiet AND (${classOf('OLD')}) IS NOT (${classOf('NEW')}) '
      "BEGIN SELECT RAISE(ABORT, '$kTeamHostKindRefused'); END;",
    );
  }

  /// Marks the items whose copy in their Crate is a deletion, for a
  /// database from before that was noted: no row here, a copy in the Crate
  /// to base on, and no change of this device's waiting to be sent.
  Future<void> markServerDeletions() async {
    final kinds = <String>{};
    for (final e in orchardItemTables.entries) {
      final (kind, column, _) = e.value;
      if (!kinds.add(kind)) continue;
      await customStatement(
        'UPDATE crate_items_meta SET server_deleted = 1 '
        "WHERE kind = '$kind' AND server_revision IS NOT NULL "
        'AND NOT EXISTS (SELECT 1 FROM ${e.key} WHERE "$column" = crate_items_meta.item_key) '
        'AND NOT EXISTS (SELECT 1 FROM crate_outbox o '
        'WHERE o.kind = crate_items_meta.kind AND o.item_key = crate_items_meta.item_key)',
      );
    }
  }

  /// (Re)create the auto-bump triggers. Idempotent (`IF NOT EXISTS`); called
  /// from onCreate and the v29 migration. The `WHEN NEW.updated_at IS
  /// OLD.updated_at` guard makes the AFTER UPDATE trigger self-limiting, so it
  /// can't recurse even if `recursive_triggers` is ever enabled.
  Future<void> _createUpdatedAtTriggers() async {
    const nowSecs = "CAST(strftime('%s','now') AS INTEGER)";
    // This runs at several migration points (v29, v37, ...) and on create. A
    // table named in the map may not exist yet at an earlier point (e.g.
    // terminal_triggers is only created at v37), so only attach triggers to
    // tables that already exist. `CREATE TRIGGER` on a missing table throws
    // "no such table", which would abort every multi-version upgrade.
    final existingTables = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get())
        .map((r) => r.read<String>('name'))
        .toSet();
    for (final entry in _updatedAtTriggerTables.entries) {
      final t = entry.key;
      if (!existingTables.contains(t)) continue;
      final pk = entry.value;
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS trg_${t}_ua_ins AFTER INSERT ON $t '
        'WHEN NEW.updated_at IS NULL '
        'BEGIN UPDATE $t SET updated_at = $nowSecs WHERE $pk = NEW.$pk; END;',
      );
      await customStatement(
        'CREATE TRIGGER IF NOT EXISTS trg_${t}_ua_upd AFTER UPDATE ON $t '
        'WHEN NEW.updated_at IS OLD.updated_at '
        'BEGIN UPDATE $t SET updated_at = $nowSecs WHERE $pk = NEW.$pk; END;',
      );
    }
  }

  /// Open the database.
  ///
  /// In **debug mode**, the database is NOT encrypted to avoid data loss
  /// caused by signing key changes (flutter run / clean rebuilds wipe
  /// FlutterSecureStorage on Android, making the encrypted DB unreadable).
  ///
  /// In **release mode**, uses SQLCipher encryption with a random key
  /// stored in FlutterSecureStorage (Android Keystore / iOS Keychain).
  static Future<AppDatabase> open() async {
    final dbFolder = await _databaseDirectory();
    if (!await dbFolder.exists()) {
      await dbFolder.create(recursive: true);
    }
    final file = File(p.join(dbFolder.path, 'zestssh.db'));

    if (kDebugMode) {
      return _openUnencrypted(file);
    }

    return _openEncrypted(file);
  }

  /// Open an UNENCRYPTED database (debug mode only).
  ///
  /// This eliminates the entire encryption-key-loss chain of events:
  /// FlutterSecureStorage key lost → can't decrypt → error screen → reset → data gone.
  static Future<AppDatabase> _openUnencrypted(
    File file, {
    AppDatabase Function(QueryExecutor) build = AppDatabase.new,
    bool encryptedFallback = true,
  }) async {
    // If there's an existing encrypted database from a previous release build,
    // try to migrate it to unencrypted. Otherwise just open normally.
    final dbExists = await file.exists();

    final executor = NativeDatabase.createInBackground(
      file,
      isolateSetup: () async {
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.android,
          openCipherOnAndroid,
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.windows,
          () => DynamicLibrary.open('sqlite3.dll'),
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.linux,
          _openSqlcipherLinux,
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.macOS,
          _openSqlcipherMacOS,
        );
      },
      setup: (rawDb) {
        // No PRAGMA key in debug mode - plain SQLite.
        // If the existing file was encrypted, this will fail at the first
        // query (not here). The caller (main.dart) handles that case.
        AppDatabase.applyConnectionSettings(rawDb);
      },
    );

    final db = build(executor);

    // Verify we can actually read the database
    if (dbExists) {
      try {
        await db.customSelect('SELECT count(*) FROM sqlite_master').get();
      } catch (e) {
        // Database exists but is unreadable (probably encrypted from a
        // previous release build). Try with encryption key as fallback.
        await db.close();
        if (!encryptedFallback) rethrow;
        debugPrint(
          '[DB] Unencrypted open failed, trying encrypted fallback: $e',
        );
        return _openEncrypted(file);
      }
    }

    return db;
  }

  /// Open an ENCRYPTED database with SQLCipher (release mode) using the DB key
  /// read from (or minted into) secure storage. This is the encrypting-lock-OFF
  /// path.
  static Future<AppDatabase> _openEncrypted(File file) async {
    final dbExists = await file.exists();
    final encryptionKey = await _getOrCreateEncryptionKey(dbExists: dbExists);
    return _openWithKeyHex(file, encryptionKey, dbExists: dbExists);
  }

  /// Open the database with an ALREADY-RESOLVED SQLCipher key hex. Used by the
  /// 1.8 encrypting-lock unlock path, where the key was produced by unwrapping
  /// the vault (via a PIN / master-password / recovery slot) rather than read
  /// as plaintext from secure storage. In debug the DB is unencrypted, so the
  /// supplied key is not applied (the lock still gates the UI + the session);
  /// in release it runs the same PRAGMA-key + cipher guard as [_openEncrypted].
  static Future<AppDatabase> openWithKeyHex(String dbKeyHex) async {
    final dbFolder = await _databaseDirectory();
    if (!await dbFolder.exists()) {
      await dbFolder.create(recursive: true);
    }
    final file = File(p.join(dbFolder.path, 'zestssh.db'));
    if (kDebugMode) {
      return _openUnencrypted(file);
    }
    return _openWithKeyHex(file, dbKeyHex, dbExists: await file.exists());
  }

  /// Open (or create) the personal database in [dir], the folder of a profile,
  /// with its key [hex]. Debug builds keep it unencrypted, as ever. Nothing
  /// needs the profile to be the one bound: a sign-in opens the next one and
  /// checks it before the one on screen closes.
  static Future<AppDatabase> openAt(Directory dir, String hex) async {
    if (!await dir.exists()) await dir.create(recursive: true);
    final file = File(p.join(dir.path, 'zestssh.db'));
    AppDatabase build(QueryExecutor e) => AppDatabase(e, ownFolder: dir);
    if (kDebugMode) return _openUnencrypted(file, build: build);
    return _openWithKeyHex(file, hex, dbExists: await file.exists(), build: build);
  }

  /// Open an Orchard's database at [file], where it lies (one that waits for
  /// its account, to read whether its own record names it).
  static Future<AppDatabase> openOrchardFile(File file, {required String keyHex}) async {
    if (kDebugMode) return _openUnencrypted(file, build: AppDatabase.orchard, encryptedFallback: false);
    return _openWithKeyHex(file, keyHex, dbExists: await file.exists(), build: AppDatabase.orchard);
  }

  /// Open (or create) an Orchard's own database (3.0): the file
  /// `orchards/<orchardId>.db` beside the Tree's, under its own key. Debug
  /// builds keep it unencrypted, like the Tree's.
  static Future<AppDatabase> openOrchard(
    String orchardId, {
    required String keyHex,
  }) async {
    final file = await orchardDatabaseFile(orchardId);
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    if (kDebugMode) {
      return _openUnencrypted(
        file,
        build: AppDatabase.orchard,
        encryptedFallback: false,
      );
    }
    return _openWithKeyHex(
      file,
      keyHex,
      dbExists: await file.exists(),
      build: AppDatabase.orchard,
    );
  }

  /// Where an Orchard's database lives. The id is checked, so it can never
  /// name a path outside the Orchards folder.
  static Future<File> orchardDatabaseFile(String orchardId) async {
    if (!RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
        .hasMatch(orchardId)) {
      throw ArgumentError.value(orchardId, 'orchardId', 'not an Orchard id');
    }
    // One with no owner yet, used where it lies until ZestSSH Cloud says whose
    // it is (ProfileManager.useHeldTeamsInPlace).
    if (Profiles.on && Profiles.provisionalTeams.contains(orchardId)) {
      return File(p.join(ProfilePaths.heldTeams(await ProfilePaths.base()).path, '$orchardId.db'));
    }
    final dbFolder = await _databaseDirectory();
    return File(p.join(dbFolder.path, 'orchards', '$orchardId.db'));
  }

  /// Resolve the SQLCipher DB key hex to WRAP when enabling the encrypting lock.
  /// Release: the existing (or freshly minted) `zestssh_db_encryption_key`.
  /// Debug: a random placeholder - the debug DB is unencrypted, so the value is
  /// never used to decrypt; the vault only needs a stable secret to round-trip.
  static Future<String> exportDbKeyHexForVault() async {
    if (kDebugMode) {
      final rng = Random.secure();
      final bytes = List<int>.generate(32, (_) => rng.nextInt(256));
      return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    }
    final dbFolder = await _databaseDirectory();
    final file = File(p.join(dbFolder.path, 'zestssh.db'));
    return _getOrCreateEncryptionKey(dbExists: await file.exists());
  }

  static Future<AppDatabase> _openWithKeyHex(
    File file,
    String encryptionKey, {
    required bool dbExists,
    AppDatabase Function(QueryExecutor) build = AppDatabase.new,
  }) async {
    final executor = NativeDatabase.createInBackground(
      file,
      isolateSetup: () async {
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.android,
          openCipherOnAndroid,
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.windows,
          () => DynamicLibrary.open('sqlite3.dll'),
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.linux,
          _openSqlcipherLinux,
        );
        sqlite_open.open.overrideFor(
          sqlite_open.OperatingSystem.macOS,
          _openSqlcipherMacOS,
        );
      },
      setup: (rawDb) {
        // Validate key format to prevent SQL injection via corrupted storage.
        if (!RegExp(r'^[0-9a-f]+$').hasMatch(encryptionKey)) {
          throw StateError('Invalid encryption key format');
        }
        rawDb.execute("PRAGMA key = '$encryptionKey';");

        // Verify that SQLCipher is actually loaded (not vanilla SQLite).
        // If a plain sqlite3.dll was loaded instead of the SQLCipher build,
        // cipher_version will be empty/missing and the DB would be unencrypted.
        final cipherVersionResult = rawDb.select('PRAGMA cipher_version;');
        if (cipherVersionResult.isEmpty ||
            cipherVersionResult.first.values.isEmpty ||
            cipherVersionResult.first.values.first == null ||
            (cipherVersionResult.first.values.first as String).isEmpty) {
          throw StateError(
            'SQLCipher is not loaded - the native library appears to be '
            'vanilla SQLite. The database cannot be safely encrypted. '
            'Ensure the sqlcipher_flutter_libs package is correctly bundled.',
          );
        }

        AppDatabase.applyConnectionSettings(rawDb);
      },
    );

    final db = build(executor);

    // Verify the database is actually readable (catches wrong encryption key)
    if (dbExists) {
      try {
        await db.customSelect('SELECT count(*) FROM sqlite_master').get();
      } catch (e) {
        await db.close();
        rethrow;
      }
    }

    return db;
  }

  /// Expected user-data tables after all migrations have run.
  ///
  /// Drift internal tables (`_drift_schema_version`, `sqlite_sequence`) and
  /// indices are excluded - they are implementation details.
  static const _expectedTables = [
    'connections',
    'identities',
    'connection_groups',
    'known_hosts',
    'snippets',
    'snippet_categories',
    'port_forward_rules',
    'port_forward_network_overrides',
    'automation_history',
    'workflows',
    'scheduled_tasks',
    'networks',
    'host_network_overrides',
    'connection_tags',
    'monitor_samples',
    // v33: created by the `from < 33` step on every upgrade path and by
    // createAll on a fresh install, so it is always present afterwards.
    'sftp_sync_manifest',
    // v35: unsent in-app reports, same rule (from < 35 step + createAll).
    'feedback_queue',
    // v36: device-local key-value state, same rule (from < 36 + createAll).
    'local_state',
    // v37: synced trigger / highlight rules (from < 37 step + createAll).
    'terminal_triggers',
    // v38: synced command history (from < 38 step + createAll).
    'command_history',
    // v53: a host's other accounts (from < 53 step + createAll).
    'host_accounts',
  ];

  /// Record the row count of every existing user-data table.
  ///
  /// Called BEFORE migrations run so we can compare counts afterward.
  /// Tables that don't yet exist (because an earlier schema didn't have
  /// them) are silently skipped - they'll have zero rows post-migration
  /// and that's expected.
  static Future<Map<String, int>> _recordTableCounts(Migrator m) async {
    final counts = <String, int>{};
    try {
      final result = await m.database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_drift_%'",
          )
          .get();

      for (final row in result) {
        final tableName = row.read<String>('name');
        try {
          final countResult = await m.database
              .customSelect('SELECT COUNT(*) AS cnt FROM "$tableName"')
              .getSingle();
          counts[tableName] = countResult.read<int>('cnt');
        } catch (_) {
          // Table might be in a bad state pre-migration; skip it.
        }
      }
    } catch (_) {
      // If we can't read sqlite_master at all, return empty - the
      // integrity check will still verify tables exist post-migration.
    }
    return counts;
  }

  /// Verify the database is in a healthy state after migration.
  ///
  /// Checks:
  /// 1. All expected tables exist in sqlite_master.
  /// 2. Record counts for pre-existing tables haven't dropped > 10%.
  /// 3. Each table is queryable (SELECT * LIMIT 1).
  ///
  /// Throws [MigrationIntegrityException] on failure.
  static Future<void> _verifyMigrationIntegrity(
    Migrator m,
    int from,
    int to,
    Map<String, int> preMigrationCounts,
  ) async {
    final failures = <String>[];

    // 1. Check all expected tables exist.
    final existingTables = <String>{};
    try {
      final result = await m.database
          .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
          .get();
      for (final row in result) {
        existingTables.add(row.read<String>('name'));
      }
    } catch (e) {
      failures.add('Cannot query sqlite_master: $e');
    }

    for (final table in _expectedTables) {
      if (!existingTables.contains(table)) {
        failures.add('Missing table: $table');
      }
    }

    // 2. Check record counts haven't dropped dramatically.
    for (final entry in preMigrationCounts.entries) {
      final table = entry.key;
      final priorCount = entry.value;
      if (priorCount == 0) continue; // Nothing to lose.
      if (!existingTables.contains(table)) continue; // Already flagged above.

      try {
        final countResult = await m.database
            .customSelect('SELECT COUNT(*) AS cnt FROM "$table"')
            .getSingle();
        final postCount = countResult.read<int>('cnt');

        if (postCount < priorCount * 0.9) {
          failures.add(
            'Table "$table" lost >10% of rows: $priorCount -> $postCount',
          );
        }
      } catch (e) {
        failures.add('Cannot count rows in "$table": $e');
      }
    }

    // 3. Verify each table is queryable.
    for (final table in _expectedTables) {
      if (!existingTables.contains(table)) continue;
      try {
        await m.database.customSelect('SELECT * FROM "$table" LIMIT 1').get();
      } catch (e) {
        failures.add('Table "$table" is not readable: $e');
      }
    }

    if (failures.isNotEmpty) {
      throw MigrationIntegrityException(
        message: 'Post-migration integrity check failed',
        fromVersion: from,
        toVersion: to,
        failures: failures,
      );
    }
  }

  /// Delete every row from every table, leaving an empty but valid database.
  /// Backs the "Delete all local data" action. Safe to call while the database
  /// is OPEN (unlike [setAsideAndRecreate], which moves the file and cannot run
  /// mid-session on Windows where the file is locked).
  Future<void> wipeAllData() async {
    await transaction(() async {
      await customStatement('PRAGMA foreign_keys = OFF');
      for (final table in allTables) {
        // The seal's key stays with its database as long as that is open:
        // every entry is sealed with it, and one written after this would
        // open by no key at the next start. (It was kept on a computer only;
        // a phone that went on after a wipe sealed a new sign-in's token and
        // a new key's private key with a key its database no longer held:
        // found in a code audit.)
        if (table.actualTableName == localState.actualTableName) {
          await (delete(localState)..where((t) => t.key.isNotIn(SecretSeal.ownRows))).go();
          continue;
        }
        await delete(table).go();
      }
      await customStatement('PRAGMA foreign_keys = ON');
    });
  }

  /// The secure-storage key holding this database's encryption key. A full
  /// wipe of secure storage must keep it while the database is open.
  static const encryptionKeyStorageKey = _dbEncryptionKeyId;

  /// Delete every pre-migration copy of the database (`zestssh_backup_*.db`
  /// next to it). They are full copies of old data, so a wipe removes them.
  static Future<void> deleteBackupCopies() =>
      _pruneOldDatabaseBackups(keep: 0);

  /// Where Reset puts the database it sets aside, beside the database.
  static const resetAsideFolder = 'reset_aside';

  /// The name the key of a database set aside by Reset at [at] is kept under.
  static String resetAsideKeyName(int at) => '$_dbEncryptionKeyId.aside.$at';

  /// Reset on the error screen of a phone: the database's files are set aside and
  /// the next [open] starts fresh. Nothing is deleted, and the key never: before 3.3.3
  /// Reset deleted the database, its copies and its key, and a key the keychain had
  /// only not answered for was gone for good.
  /// The files go to `reset_aside/<time>/` beside the database, the key is kept under
  /// [resetAsideKeyName] too (and stays where it is), so whoever helps can put them
  /// back. A key that cannot be read stops it with nothing moved: the next [open]
  /// would make a new one in its place. On a computer a profile is set aside instead
  /// (ProfileManager.setAsideCurrent), which Put it back undoes. Returns the folder.
  static Future<Directory> setAsideAndRecreate() async {
    if (Profiles.on) throw StateError('On a computer the profile is set aside instead');
    final dbFolder = await _databaseDirectory();
    // Throws where the keychain does not answer: nothing has moved.
    final key = await _secureStorage.read(key: _dbEncryptionKeyId);
    final at = DateTime.now().millisecondsSinceEpoch;
    if (key != null) {
      final kept = resetAsideKeyName(at);
      await _secureStorage.write(key: kept, value: key);
      if (await _secureStorage.read(key: kept) != key) throw StateError('The key did not read back under its new name');
    }
    final aside = Directory(p.join(dbFolder.path, resetAsideFolder, '$at'));
    await aside.create(recursive: true);
    final basePath = p.join(dbFolder.path, 'zestssh.db');
    // SQLite may create WAL and SHM journal files alongside the main DB, and the copies
    // made before each upgrade are the same data: all of it goes, together.
    final files = [
      for (final suffix in ['', '-wal', '-shm', '-journal']) File('$basePath$suffix'),
      for (final f in dbFolder.listSync().whereType<File>())
        if (p.basename(f.path).startsWith('zestssh_backup_') &&
            (p.basename(f.path).endsWith('.db') || p.basename(f.path).endsWith('.db-wal')))
          f,
    ];
    for (final f in files) {
      if (await f.exists()) await f.rename(p.join(aside.path, p.basename(f.path)));
    }
    return aside;
  }

  /// Keep only the [keep] newest `zestssh_backup_*.db` pre-migration copies,
  /// deleting the rest. Best-effort - never throws into a migration/reset path.
  @visibleForTesting
  static Future<void> pruneDatabaseBackups({required int keep, required Directory folder}) =>
      _pruneOldDatabaseBackups(keep: keep, folder: folder);

  static Future<void> _pruneOldDatabaseBackups({required int keep, Directory? folder}) async {
    try {
      final dbFolder = folder ?? await _databaseDirectory();
      final backups =
          dbFolder.listSync().whereType<File>().where((f) {
              final name = p.basename(f.path);
              return name.startsWith('zestssh_backup_') && name.endsWith('.db');
            }).toList()
            // Filenames embed a millisecond timestamp, so lexical sort == chrono
            // sort; newest last, so drop everything before the final [keep].
            ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
      final Iterable<File> toDelete = keep <= 0
          ? backups
          : (backups.length > keep
                ? backups.take(backups.length - keep)
                : const <File>[]);
      for (final f in toDelete) {
        // (Its write-ahead file goes with it.)
        for (final file in [f, File('${f.path}-wal')]) {
          try {
            if (await file.exists()) await file.delete();
          } catch (_) {
            /* best-effort per-file */
          }
        }
      }
    } catch (_) {
      /* best-effort */
    }
  }

  /// Create a timestamped backup of the database file, with its write-ahead
  /// file beside it under the name SQLite opens it by (`<copy>-wal`) where
  /// there is one: the newest committed changes are often in that file alone
  /// (3.4.2 sweep, L6: the copy was the database file only).
  ///
  /// Returns the backup file, or `null` if the source doesn't exist.
  static Future<File?> backupDatabase([Directory? folder]) async {
    final dbFolder = folder ?? await _databaseDirectory();
    final source = File(p.join(dbFolder.path, 'zestssh.db'));
    if (!await source.exists()) return null;
    final ts = DateTime.now().millisecondsSinceEpoch;
    final backup = File(p.join(dbFolder.path, 'zestssh_backup_$ts.db'));
    final copy = await source.copy(backup.path);
    final wal = File('${source.path}-wal');
    if (await wal.exists() && await wal.length() > 0) await wal.copy('${backup.path}-wal');
    return copy;
  }

  /// Get the database file path (for diagnostics).
  static Future<String> get databasePath async {
    final dir = await _databaseDirectory();
    return p.join(dir.path, 'zestssh.db');
  }

  /// Returns the directory for the database file: the open profile's on a
  /// computer, and where it always was on a phone ([ProfilePaths]).
  static Future<Directory> _databaseDirectory() => ProfilePaths.databaseDirectory();

  /// Get or create the 64-character hex encryption key.
  ///
  /// SAFETY: If the database already exists but the key is missing from
  /// secure storage, this is a critical error (key was lost). We throw
  /// instead of silently creating a new key, which would make the existing
  /// database unreadable.
  static Future<String> _getOrCreateEncryptionKey({
    required bool dbExists,
  }) async {
    String? key;
    try {
      key = await _secureStorage.read(key: _dbEncryptionKeyId);
    } catch (e) {
      // FlutterSecureStorage itself failed to read (Keystore corruption,
      // Android wipe, etc.)
      if (dbExists) {
        throw StateError(
          'Cannot read encryption key from secure storage, but database '
          'file exists. The database cannot be decrypted.\n'
          'Secure storage error: $e\n\n'
          'This usually happens after an app reinstall or signing key change. '
          'Your data may be recoverable from a .zest backup file.',
        );
      }
      // No database exists yet - safe to generate a fresh key
      key = null;
    }

    if (key == null && dbExists) {
      // Key was lost but database exists - DO NOT generate a new key!
      // That would make the existing database permanently unreadable.
      throw StateError(
        'Encryption key not found in secure storage, but database file '
        'already exists. Generating a new key would make existing data '
        'permanently unreadable.\n\n'
        'This usually happens after:\n'
        '• App reinstall (debug signing key change)\n'
        '• flutter clean + flutter run\n'
        '• Device factory reset\n\n'
        'Your data may be recoverable from a .zest backup file.',
      );
    }

    if (key == null) {
      // First launch - generate and store a new key
      final random = Random.secure();
      final bytes = List.generate(32, (_) => random.nextInt(256));
      key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      await _secureStorage.write(key: _dbEncryptionKeyId, value: key);
    }

    return key;
  }
}
