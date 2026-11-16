import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/daos/connection_groups_dao.dart';
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/port_forward_rules_dao.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/providers/core_providers.dart';

// ── Search filter ────────────────────────────────────────────────

/// Current search query for filtering the connection list.
final connectionSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Connection list ──────────────────────────────────────────────

/// Stream of all connections with joined identity + group data.
final connectionsWithDetailsProvider =
    StreamProvider<List<ConnectionWithDetails>>((ref) {
  final dao = ref.watch(connectionsDaoProvider);
  return dao.watchAllWithDetails();
});

/// Every saved connection, whatever the search box holds (the home screen
/// widget's list: it must not shrink to what someone typed in the search).
final allConnectionsProvider = StreamProvider<List<Connection>>((ref) {
  return ref.watch(connectionsDaoProvider).watchAll();
});

/// Filtered connections based on search query.
final filteredConnectionsProvider =
    StreamProvider<List<Connection>>((ref) {
  final dao = ref.watch(connectionsDaoProvider);
  final query = ref.watch(connectionSearchQueryProvider);

  if (query.isEmpty) {
    return dao.watchAll();
  }
  return dao.watchFiltered(query);
});

/// Live count of saved connections.
///
/// Used by the first-run onboarding gate (F1): the router only routes a
/// brand-new user to onboarding when this is known to be zero AND the
/// completed-flag is unset. Kept deliberately lightweight (a plain row
/// count) so subscribing it early in startup is cheap.
final connectionCountProvider = StreamProvider<int>((ref) {
  // While the app is locked (1.8 encrypting lock, DB not yet unlocked), the
  // database is inaccessible. Emit nothing so the router's onboarding gate sees
  // an unknown count rather than throwing on databaseProvider. Rebuilds and
  // subscribes the real stream once the DB opens.
  if (!ref.watch(dbReadyProvider)) {
    return const Stream<int>.empty();
  }
  final dao = ref.watch(connectionsDaoProvider);
  return dao.watchAll().map((rows) => rows.length);
});

// ── Connection groups ────────────────────────────────────────────

/// Stream of all connection groups.
final connectionGroupsProvider =
    StreamProvider<List<ConnectionGroup>>((ref) {
  final dao = ref.watch(connectionGroupsDaoProvider);
  return dao.watchAll();
});

// ── CRUD notifier ────────────────────────────────────────────────

/// Handles create, update, delete operations for connections.
final connectionCrudProvider =
    Provider<ConnectionCrudNotifier>((ref) {
  return ConnectionCrudNotifier(
    ref.watch(connectionsDaoProvider),
    ref.watch(portForwardRulesDaoProvider),
    ref.watch(connectionTagsDaoProvider),
  );
});

class ConnectionCrudNotifier {
  final ConnectionsDao _dao;
  final PortForwardRulesDao _portForwardRulesDao;
  final ConnectionTagsDao _tagsDao;

  ConnectionCrudNotifier(
      this._dao, this._portForwardRulesDao, this._tagsDao);

  Future<String> create({
    required String label,
    required String host,
    int port = 22,
    String? identityId,
    String? groupId,
    int colorIndex = 0,
    int? colorValue,
    String protocol = 'ssh',
    bool zlibCompression = false,
    String? startupCommand,
    String? snippetId,
    String? connectViaId,
    int keepAliveSeconds = 0,
    String? wolMacAddress,
    String? wolBroadcastAddress,
    int? wolPort,
    String envVars = '',
    bool forwardAgent = false,
    bool compatibilityMode = false,
    String? note,
    String? iconId,
    String? customIcon,
    int? iconColor,
    String? screenOptions,
  }) async {
    final id = const Uuid().v4();
    final now = DateTime.now();

    await _dao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value(label),
      host: Value(host),
      port: Value(port),
      identityId: Value(identityId),
      groupId: Value(groupId),
      colorIndex: Value(colorIndex),
      colorValue: Value(colorValue),
      protocol: Value(protocol),
      zlibCompression: Value(zlibCompression),
      startupCommand: Value(startupCommand),
      snippetId: Value(snippetId),
      connectViaId: Value(connectViaId),
      keepAliveSeconds: Value(keepAliveSeconds),
      wolMacAddress: Value(wolMacAddress),
      wolBroadcastAddress: Value(wolBroadcastAddress),
      wolPort: Value(wolPort),
      envVars: Value(envVars),
      forwardAgent: Value(forwardAgent),
      compatibilityMode: Value(compatibilityMode),
      note: Value(note),
      iconId: Value(iconId),
      customIcon: Value(customIcon),
      iconColor: Value(iconColor),
      screenOptions: Value(screenOptions),
      sortOrder: const Value(0),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));

    return id;
  }

  Future<void> update({
    required String id,
    String? label,
    String? host,
    int? port,
    String? identityId,
    String? groupId,
    int? colorIndex,
    int? colorValue,
    bool clearColorValue = false,
    String? protocol,
    bool? zlibCompression,
    String? startupCommand,
    String? snippetId,
    String? connectViaId,
    int? keepAliveSeconds,
    String? wolMacAddress,
    String? wolBroadcastAddress,
    int? wolPort,
    String? envVars,
    bool? forwardAgent,
    bool? compatibilityMode,
    String? note,
    bool clearNote = false,
    // Host-card icon override. Only written when [setIcon] is true, so the
    // many callers that update() for other reasons never clear a chosen icon.
    String? iconId,
    String? customIcon,
    bool setIcon = false,
    // What colours the icon (see `HostIconColor`; null is the icon's own
    // colour, so it cannot mean "leave it"). Only written when
    // [setIconColor] is true.
    int? iconColor,
    bool setIconColor = false,
    // A remote screen's options (ScreenOptions' JSON); null clears them, so
    // only written when [setScreenOptions] is true.
    String? screenOptions,
    bool setScreenOptions = false,
    bool clearIdentityId = false,
    bool clearGroupId = false,
    bool clearConnectViaId = false,
    bool clearStartupCommand = false,
    bool clearWolMacAddress = false,
    bool clearWolBroadcastAddress = false,
    bool clearWolPort = false,
    bool clearSnippetId = false,
  }) async {
    final companion = ConnectionsCompanion(
      id: Value(id),
      iconId: setIcon ? Value(iconId) : const Value.absent(),
      customIcon: setIcon ? Value(customIcon) : const Value.absent(),
      iconColor: setIconColor ? Value(iconColor) : const Value.absent(),
      screenOptions: setScreenOptions ? Value(screenOptions) : const Value.absent(),
      label: label != null ? Value(label) : const Value.absent(),
      host: host != null ? Value(host) : const Value.absent(),
      port: port != null ? Value(port) : const Value.absent(),
      identityId: clearIdentityId
          ? const Value(null)
          : identityId != null
              ? Value(identityId)
              : const Value.absent(),
      groupId: clearGroupId
          ? const Value(null)
          : groupId != null
              ? Value(groupId)
              : const Value.absent(),
      colorIndex:
          colorIndex != null ? Value(colorIndex) : const Value.absent(),
      // colorValue and colorIndex are alternatives (a custom colour overrides
      // the palette index). The editor always knows the full state: it passes
      // the custom value, or sets clearColorValue when the user picked a preset
      // / default so any previous custom colour is removed.
      colorValue: clearColorValue
          ? const Value(null)
          : colorValue != null
              ? Value(colorValue)
              : const Value.absent(),
      protocol: protocol != null ? Value(protocol) : const Value.absent(),
      zlibCompression: zlibCompression != null
          ? Value(zlibCompression)
          : const Value.absent(),
      startupCommand: clearStartupCommand
          ? const Value(null)
          : startupCommand != null
              ? Value(startupCommand)
              : const Value.absent(),
      snippetId: clearSnippetId
          ? const Value(null)
          : snippetId != null
              ? Value(snippetId)
              : const Value.absent(),
      connectViaId: clearConnectViaId
          ? const Value(null)
          : connectViaId != null
              ? Value(connectViaId)
              : const Value.absent(),
      keepAliveSeconds: keepAliveSeconds != null
          ? Value(keepAliveSeconds)
          : const Value.absent(),
      wolMacAddress: clearWolMacAddress
          ? const Value(null)
          : wolMacAddress != null
              ? Value(wolMacAddress)
              : const Value.absent(),
      wolBroadcastAddress: clearWolBroadcastAddress
          ? const Value(null)
          : wolBroadcastAddress != null
              ? Value(wolBroadcastAddress)
              : const Value.absent(),
      wolPort: clearWolPort
          ? const Value(null)
          : wolPort != null
              ? Value(wolPort)
              : const Value.absent(),
      envVars:
          envVars != null ? Value(envVars) : const Value.absent(),
      forwardAgent: forwardAgent != null
          ? Value(forwardAgent)
          : const Value.absent(),
      compatibilityMode: compatibilityMode != null
          ? Value(compatibilityMode)
          : const Value.absent(),
      note: clearNote
          ? const Value(null)
          : note != null
              ? Value(note)
              : const Value.absent(),
      updatedAt: Value(DateTime.now()),
    );
    await _dao.updateConnection(companion);
  }

  /// Deletes the host [id], whole or not at all: one transaction, so a team
  /// vault's write guard refusing the host itself (a role that may edit but
  /// not delete) leaves its tags, port forwards, other accounts, the hosts
  /// that jump through it and the tombstone as they were. They were written
  /// one by one before the host, and a refused delete still lost them.
  Future<void> delete(String id) {
    final db = _dao.attachedDatabase;
    return db.transaction(() => _delete(db, id));
  }

  Future<void> _delete(AppDatabase db, String id) async {
    // Record a delete-propagation tombstone FIRST, so a host deleted here is
    // removed on the user's OTHER devices instead of being re-added by the sync
    // union-merge (which only ever inserts/updates). Idempotent; the sync engine
    // (SyncDataService) emits + applies these. Only synced connection rows get a
    // tombstone - the port-forward rules / tags cleaned up below are device- or
    // parent-scoped and ride the connection's own removal.
    await db.tombstonesDao.mark('connections', id);
    // Clear connectVia references from connections using this as a jump host
    await _dao.clearConnectViaReferences(id);
    // Delete associated port forward rules
    await _portForwardRulesDao.deleteByConnection(id);
    // Drop any tags attached to this connection (no FK cascade).
    await _tagsDao.clearTagsForConnection(id);
    // And its other accounts (no FK cascade either).
    await db.hostAccountsDao.deleteForConnection(id);
    // And its settings for each network (no FK cascade): they were left
    // behind, as Move to... (item_transfer.dart) never left them.
    await db.networksDao.deleteOverridesForHost(id);
    // Delete the connection itself
    await _dao.deleteConnection(id);
    // Pinned-hosts state is in SharedPreferences (not Drift), so it
    // doesn't cascade automatically. Without this prune-call deleted
    // hosts would leak orphan entries in the pinned set forever.
    // Caller (the host home page) handles this - we record the
    // intent here so future maintainers see the dependency.
    // (See pinned_hosts_provider.pruneMissing - invoked from the
    // home-page connection-delete confirmation flow.)
  }

  /// A copy of [source] named [label] (the caller's words, in the app's
  /// language: `homeCopyLabelSuffix`; it was named in English in every
  /// language). In a team's space the copy goes into its source's Crate
  /// where this account can add there ([CratePlacement.placeCopy]), and the
  /// copy is written whole or not at all.
  Future<String> duplicate(Connection source, {required String label}) {
    final db = _dao.attachedDatabase;
    return db.transaction(() => _duplicate(db, source, label));
  }

  Future<String> _duplicate(AppDatabase db, Connection source, String label) async {
    final id = const Uuid().v4();
    final now = DateTime.now();
    if (db.isOrchard) await CratePlacement(db).placeCopy('host', source.id, id);

    await _dao.insertConnection(ConnectionsCompanion(
      id: Value(id),
      label: Value(label),
      host: Value(source.host),
      port: Value(source.port),
      identityId: Value(source.identityId),
      groupId: Value(source.groupId),
      colorIndex: Value(source.colorIndex),
      colorValue: Value(source.colorValue),
      protocol: Value(source.protocol),
      zlibCompression: Value(source.zlibCompression),
      startupCommand: Value(source.startupCommand),
      snippetId: Value(source.snippetId),
      connectViaId: Value(source.connectViaId),
      keepAliveSeconds: Value(source.keepAliveSeconds),
      wolMacAddress: Value(source.wolMacAddress),
      wolBroadcastAddress: Value(source.wolBroadcastAddress),
      wolPort: Value(source.wolPort),
      envVars: Value(source.envVars),
      forwardAgent: Value(source.forwardAgent),
      compatibilityMode: Value(source.compatibilityMode),
      // Carry the Part B visual attributes (tier + note) and the icon with
      // its colour - they belong to the host's presentation. `pinned` is
      // deliberately NOT copied: the copy is a new host and pinning is a
      // per-host user choice. Nor is `cloudSource`: the copy was not imported
      // from that machine, and two hosts linked to one machine would both
      // follow its address.
      sizeTier: Value(source.sizeTier),
      note: Value(source.note),
      iconId: Value(source.iconId),
      customIcon: Value(source.customIcon),
      iconColor: Value(source.iconColor),
      // A screen's options are the host's own, as its address is.
      screenOptions: Value(source.screenOptions),
      // So are a team's shared SFTP bookmarks: the copy is the same server
      // (none on a personal host).
      sharedPins: Value(source.sharedPins),
      sortOrder: const Value(0),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));

    // Duplicate port forward rules if any
    final rules = await _portForwardRulesDao.getByConnection(source.id);
    for (final rule in rules) {
      await _portForwardRulesDao.insertRule(PortForwardRulesCompanion(
        id: Value(const Uuid().v4()),
        connectionId: Value(id),
        label: Value(rule.label),
        type: Value(rule.type),
        bindAddress: Value(rule.bindAddress),
        bindPort: Value(rule.bindPort),
        remoteHost: Value(rule.remoteHost),
        remotePort: Value(rule.remotePort),
        autoStart: Value(rule.autoStart),
        createdAt: Value(now),
      ));
    }

    // Carry tags over to the duplicate so the user doesn't have to
    // re-tag every copy.
    final tags = await _tagsDao.getTagsForConnection(source.id);
    if (tags.isNotEmpty) {
      await _tagsDao.setTagsForConnection(id, tags);
    }

    // And its other accounts: the copy is signed in to as the original is.
    final accounts = _dao.attachedDatabase.hostAccountsDao;
    final others = await accounts.otherAccountsOf(source.id);
    if (others.isNotEmpty) await accounts.setOtherAccounts(id, others);

    return id;
  }

  Future<void> touchLastConnected(String id) =>
      _dao.touchLastConnected(id);

  Future<void> updateSortOrder(String id, int newOrder) =>
      _dao.updateSortOrder(id, newOrder);
}

// ── Group CRUD ───────────────────────────────────────────────────

final groupCrudProvider = Provider<GroupCrudNotifier>((ref) {
  return GroupCrudNotifier(
    ref.watch(connectionGroupsDaoProvider),
    ref.watch(connectionsDaoProvider),
  );
});

class GroupCrudNotifier {
  final ConnectionGroupsDao _dao;
  final ConnectionsDao _connectionsDao;

  GroupCrudNotifier(this._dao, this._connectionsDao);

  /// Create a group. The optional accent + icon + [sortOrder] let the group
  /// editor's "New group" flow persist a fully-configured folder in one write
  /// and append it to the end of the ordering. All extras are additive: the
  /// legacy `create(name: ...)` call keeps its old behaviour (no colour/icon,
  /// sortOrder 0).
  Future<String> create({
    required String name,
    int? colorIndex,
    int? colorValue,
    int? iconCodePoint,
    int? sortOrder,
  }) async {
    final id = const Uuid().v4();
    await _dao.insertGroup(ConnectionGroupsCompanion(
      id: Value(id),
      name: Value(name),
      sortOrder: Value(sortOrder ?? 0),
      isExpanded: const Value(true),
      createdAt: Value(DateTime.now()),
      colorIndex: Value(colorIndex),
      colorValue: Value(colorValue),
      iconCodePoint: Value(iconCodePoint),
    ));
    return id;
  }

  /// Persist a full group ordering (left-to-right on the Hosts screen) from the
  /// group editor's "All groups" reorder tab. [orderedIds] is the new order;
  /// each group's `sortOrder` becomes its index. See
  /// [ConnectionGroupsDao.setSortOrders].
  Future<void> reorderGroups(List<String> orderedIds) =>
      _dao.setSortOrders(orderedIds);

  Future<void> rename(String id, String newName) {
    return _dao.updateGroup(ConnectionGroupsCompanion(
      id: Value(id),
      name: Value(newName),
    ));
  }

  /// Deletes the group [id] and takes its hosts out of it, in one
  /// transaction: a team vault refusing the group leaves its hosts in it.
  Future<void> delete(String id) => _dao.transaction(() async {
        // Clear group reference from connections that use this group
        await _connectionsDao.clearGroupReferences(id);
        await _dao.deleteGroup(id);
      });

  Future<void> toggleExpanded(String id, bool expanded) =>
      _dao.toggleExpanded(id, expanded);

  /// Set the group's accent color (index into AppColors.v3GroupColors),
  /// or null to revert to the legacy name-hash-derived color. A non-null
  /// [colorValue] (ARGB int) persists an arbitrary custom colour that wins over
  /// the index.
  Future<void> setColor(String id, int? colorIndex, {int? colorValue}) =>
      _dao.setColor(id, colorIndex, colorValue: colorValue);

  /// Update a folder's name, accent color and icon in a single write.
  ///
  /// [colorIndex] indexes into AppColors.v3GroupColors (null reverts to the
  /// legacy name-hash color); [iconCodePoint] is the codePoint of a const
  /// IconData from `folder_icon_catalog.dart` (null reverts to the default
  /// folder glyph). Backs the unified folder editor.
  Future<void> updateFolder({
    required String id,
    required String name,
    required int? colorIndex,
    required int? iconCodePoint,
    int? colorValue,
  }) {
    return _dao.updateGroup(ConnectionGroupsCompanion(
      id: Value(id),
      name: Value(name),
      colorIndex: Value(colorIndex),
      // Custom colour overrides the palette index; always written so picking a
      // preset / default clears any previous custom colour.
      colorValue: Value(colorValue),
      iconCodePoint: Value(iconCodePoint),
    ));
  }
}
