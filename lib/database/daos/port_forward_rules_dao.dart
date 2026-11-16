import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/port_forward_network_overrides.dart';
import 'package:zestssh/database/tables/port_forward_rules.dart';

part 'port_forward_rules_dao.g.dart';

@DriftAccessor(tables: [PortForwardRules, PortForwardNetworkOverrides])
class PortForwardRulesDao extends DatabaseAccessor<AppDatabase>
    with _$PortForwardRulesDaoMixin {
  PortForwardRulesDao(super.db);

  static const _uuid = Uuid();

  /// Watch all rules for a specific connection.
  Stream<List<PortForwardRule>> watchByConnection(String connectionId) {
    return (select(portForwardRules)
          ..where((t) => t.connectionId.equals(connectionId))
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  /// Get all rules for a specific connection.
  Future<List<PortForwardRule>> getByConnection(String connectionId) {
    return (select(portForwardRules)
          ..where((t) => t.connectionId.equals(connectionId)))
        .get();
  }

  /// Get all rules (for backup/sync).
  Future<List<PortForwardRule>> getAll() => select(portForwardRules).get();

  /// Watch all rules across all connections (for Manage tab).
  Stream<List<PortForwardRule>> watchAll() {
    return (select(portForwardRules)
          ..orderBy([(t) => OrderingTerm(expression: t.createdAt)]))
        .watch();
  }

  /// Get auto-start rules for a connection.
  Future<List<PortForwardRule>> getAutoStartRules(String connectionId) {
    return (select(portForwardRules)
          ..where((t) =>
              t.connectionId.equals(connectionId) &
              t.autoStart.equals(true)))
        .get();
  }

  /// Get auto-start rules for a connection that should fire on the
  /// currently-active [networkId].
  ///
  /// A rule with `networkId == null` is treated as "all networks" -
  /// it always matches and so the pre-v1.5 behaviour is preserved
  /// for every existing rule.  A rule with a non-null `networkId`
  /// only matches when [networkId] equals it; if the user is on a
  /// different network, the rule is skipped.
  ///
  /// On a network, a host's own choice for a forward there (the host
  /// editor's Inherit / On / Off for each network,
  /// [PortForwardNetworkOverrides]) goes over that: On starts it there
  /// whether or not it starts by itself or is pinned to another network,
  /// Off never starts it there, Inherit is as above (22 October 2026: the
  /// choice was saved and never read).
  Future<List<PortForwardRule>> getAutoStartRulesForNetwork(
    String connectionId,
    String? networkId,
  ) async {
    final query = select(portForwardRules)
      ..where((t) =>
          t.connectionId.equals(connectionId) & t.autoStart.equals(true));
    if (networkId == null) {
      // No active network resolved - only fire rules pinned to "all
      // networks" (networkId IS NULL).  Defensive: prevents an
      // un-pinned rule from accidentally running before the network
      // detector has had time to report a result.
      query.where((t) => t.networkId.isNull());
      return query.get();
    }
    query.where(
        (t) => t.networkId.isNull() | t.networkId.equals(networkId));
    final base = await query.get();

    final rules = await getByConnection(connectionId);
    if (rules.isEmpty) return base;
    final states = {
      for (final row in await (select(portForwardNetworkOverrides)
            ..where((t) =>
                t.networkId.equals(networkId) &
                t.ruleId.isIn(rules.map((r) => r.id))))
          .get())
        row.ruleId: PortForwardNetworkState.fromDb(row.state),
    };
    if (states.isEmpty) return base;
    final baseIds = base.map((r) => r.id).toSet();
    // In a team's space, "On" for a network travels in a teammate's record, and
    // whether a forward starts by itself is each device's own (auto_start, which
    // stays here): "On" started one nobody here asked for, a remote forward among
    // them, which lets that server reach whatever this device can (a security
    // audit). There it starts only where this device said so.
    final onStarts = !attachedDatabase.isOrchard;
    return [
      for (final rule in rules)
        if (switch (states[rule.id] ?? PortForwardNetworkState.inherit) {
          PortForwardNetworkState.on => onStarts || rule.autoStart,
          PortForwardNetworkState.off => false,
          PortForwardNetworkState.inherit => baseIds.contains(rule.id),
        })
          rule,
    ];
  }

  /// Insert a new rule.
  Future<void> insertRule(PortForwardRulesCompanion entry) {
    return into(portForwardRules).insert(entry);
  }

  /// Update an existing rule.
  Future<void> updateRule(PortForwardRulesCompanion entry) {
    return (update(portForwardRules)
          ..where((t) => t.id.equals(entry.id.value)))
        .write(entry);
  }

  /// Upsert a rule (insert or update).
  Future<void> upsertRule(PortForwardRulesCompanion entry) {
    return into(portForwardRules).insertOnConflictUpdate(entry);
  }

  /// Delete a rule by ID. Also removes any per-network state overrides for
  /// the rule so we don't leave orphan rows behind (they'd be harmless - the
  /// resolver ignores unknown ids - but there's no reason to keep them).
  ///
  /// One transaction: a delete a team vault refuses (a role that may edit but
  /// not delete) leaves the rule's per-network overrides and no tombstone.
  Future<void> deleteRule(String id) => transaction(() async {
        // Delete-propagation tombstone so the rule is removed on other
        // devices; the merge cascades its per-network overrides on the other
        // side.
        await attachedDatabase.tombstonesDao.mark('port_forward_rules', id);
        await deleteNetworkOverridesForRule(id);
        await (delete(portForwardRules)..where((t) => t.id.equals(id))).go();
      });

  /// Delete all rules for a connection, plus their per-network overrides, in
  /// one transaction (as [deleteRule]).
  Future<void> deleteByConnection(String connectionId) => transaction(() async {
        final rules = await getByConnection(connectionId);
        for (final rule in rules) {
          // Tombstone each rule so a host delete removes its forwards on other
          // devices too (they'd otherwise be re-added by the union-merge).
          await attachedDatabase.tombstonesDao.mark('port_forward_rules', rule.id);
          await deleteNetworkOverridesForRule(rule.id);
        }
        await (delete(portForwardRules)
              ..where((t) => t.connectionId.equals(connectionId)))
            .go();
      });

  // ── Per-(rule, network) state overrides (v1.6, schema v19) ───────
  //
  // A rule's own row carries only its base semantics (`autoStart` + the
  // optional single `networkId` pin). These methods layer a per-network
  // enable/disable state on top via [PortForwardNetworkOverrides]. Absence
  // of a row = inherit (the rule's base semantics are used unchanged), which
  // is why setting a pair back to `inherit` DELETES its row rather than
  // storing a no-op.

  /// All per-network state override rows for a single rule.
  Future<List<PortForwardNetworkOverrideRow>> getNetworkOverridesForRule(
    String ruleId,
  ) {
    return (select(portForwardNetworkOverrides)
          ..where((t) => t.ruleId.equals(ruleId)))
        .get();
  }

  /// Every per-network override row (across all rules) - used by the
  /// backup/sync dump (`SyncDataService.gatherAll`).
  Future<List<PortForwardNetworkOverrideRow>> getAllNetworkOverrides() =>
      select(portForwardNetworkOverrides).get();

  /// The override row (if any) for a `(rule, network)` pair. Used by sync
  /// restore to upsert on the logical `(ruleId, networkId)` unique key rather
  /// than blindly by surrogate `id`: two devices that independently created an
  /// override for the same pair would otherwise collide on the
  /// `(ruleId, networkId)` unique constraint and abort the restore.
  Future<PortForwardNetworkOverrideRow?> getNetworkOverrideByPair(
    String ruleId,
    String networkId,
  ) {
    return (select(portForwardNetworkOverrides)
          ..where((t) =>
              t.ruleId.equals(ruleId) & t.networkId.equals(networkId))
          ..limit(1))
        .getSingleOrNull();
  }

  /// Insert-or-update a per-network override by primary key. Callers that need
  /// `(ruleId, networkId)`-keyed semantics (sync restore) resolve the existing
  /// row's id via [getNetworkOverrideByPair] first so this updates in place.
  Future<void> upsertNetworkOverride(
    PortForwardNetworkOverridesCompanion entry,
  ) {
    return into(portForwardNetworkOverrides).insertOnConflictUpdate(entry);
  }

  /// Watch the per-network state override rows for a single rule (drives the
  /// live per-network port-forward controls in the host editor).
  Stream<List<PortForwardNetworkOverrideRow>> watchNetworkOverridesForRule(
    String ruleId,
  ) {
    return (select(portForwardNetworkOverrides)
          ..where((t) => t.ruleId.equals(ruleId)))
        .watch();
  }

  /// The effective per-network state for a `(rule, network)` pair. Defaults
  /// to [PortForwardNetworkState.inherit] when no override row exists - i.e.
  /// the rule keeps its own base autoStart + networkId-pin semantics.
  Future<PortForwardNetworkState> effectiveStateForNetwork(
    String ruleId,
    String networkId,
  ) async {
    final row = await (select(portForwardNetworkOverrides)
          ..where((t) =>
              t.ruleId.equals(ruleId) & t.networkId.equals(networkId)))
        .getSingleOrNull();
    return PortForwardNetworkState.fromDb(row?.state);
  }

  /// Single write path for a `(rule, network)` state. Setting
  /// [PortForwardNetworkState.inherit] DELETES the override row (absence ==
  /// inherit) so no-op rows never accumulate; `on`/`off` upserts in place by
  /// the `(ruleId, networkId)` pair, reusing the existing row's id so the
  /// unique key is respected and `createdAt` stays stable.
  Future<void> setNetworkOverrideState({
    required String ruleId,
    required String networkId,
    required PortForwardNetworkState state,
  }) async {
    if (state == PortForwardNetworkState.inherit) {
      await deleteNetworkOverride(ruleId: ruleId, networkId: networkId);
      return;
    }
    final existing = await (select(portForwardNetworkOverrides)
          ..where((t) =>
              t.ruleId.equals(ruleId) & t.networkId.equals(networkId)))
        .getSingleOrNull();
    final now = DateTime.now();
    if (existing == null) {
      await into(portForwardNetworkOverrides).insert(
        PortForwardNetworkOverridesCompanion.insert(
          id: _uuid.v4(),
          ruleId: ruleId,
          networkId: networkId,
          state: Value(state.dbValue),
          createdAt: now,
          updatedAt: now,
        ),
      );
    } else {
      await (update(portForwardNetworkOverrides)
            ..where((t) => t.id.equals(existing.id)))
          .write(PortForwardNetworkOverridesCompanion(
        state: Value(state.dbValue),
        updatedAt: Value(now),
      ));
    }
  }

  /// Delete the override for a single `(rule, network)` pair, reverting it to
  /// inherit.
  Future<void> deleteNetworkOverride({
    required String ruleId,
    required String networkId,
  }) {
    return (delete(portForwardNetworkOverrides)
          ..where((t) =>
              t.ruleId.equals(ruleId) & t.networkId.equals(networkId)))
        .go();
  }

  /// Delete every per-network override for a rule (used when the rule itself
  /// is deleted).
  Future<void> deleteNetworkOverridesForRule(String ruleId) {
    return (delete(portForwardNetworkOverrides)
          ..where((t) => t.ruleId.equals(ruleId)))
        .go();
  }

  /// Delete every rule's per-network override for [networkId] (used when the
  /// network itself is deleted: every rule falls back to its own semantics).
  Future<void> deleteNetworkOverridesForNetwork(String networkId) {
    return (delete(portForwardNetworkOverrides)
          ..where((t) => t.networkId.equals(networkId)))
        .go();
  }
}
