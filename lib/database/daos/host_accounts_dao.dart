import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/connections.dart';
import 'package:zestssh/database/tables/host_accounts.dart';

part 'host_accounts_dao.g.dart';

/// The other accounts of hosts (3.0, accounts per host): identities a host
/// can also be signed in to with, beside its default (`connections.identity_id`).
@DriftAccessor(tables: [HostAccounts, Connections])
class HostAccountsDao extends DatabaseAccessor<AppDatabase> with _$HostAccountsDaoMixin {
  HostAccountsDao(super.db);

  /// The other accounts of [connectionId], in their order.
  Future<List<String>> otherAccountsOf(String connectionId) async {
    final rows = await (select(hostAccounts)
          ..where((a) => a.connectionId.equals(connectionId))
          ..orderBy([(a) => OrderingTerm(expression: a.position), (a) => OrderingTerm(expression: a.identityId)]))
        .get();
    return [for (final r in rows) r.identityId];
  }

  /// Every host's other accounts, in their order: what sync carries.
  Future<Map<String, List<String>>> getAllAssignments() async {
    final rows = await (select(hostAccounts)
          ..orderBy([
            (a) => OrderingTerm(expression: a.connectionId),
            (a) => OrderingTerm(expression: a.position),
            (a) => OrderingTerm(expression: a.identityId),
          ]))
        .get();
    final all = <String, List<String>>{};
    for (final r in rows) {
      (all[r.connectionId] ??= []).add(r.identityId);
    }
    return all;
  }

  /// Makes [identityIds] the other accounts of [connectionId], in that
  /// order: each once, and never the host's default.
  Future<void> setOtherAccounts(String connectionId, List<String> identityIds) => transaction(() async {
        final host = await (select(connections)..where((c) => c.id.equals(connectionId))).getSingleOrNull();
        final keep = <String>[];
        for (final id in identityIds) {
          if (id != host?.identityId && !keep.contains(id)) keep.add(id);
        }
        final now = await otherAccountsOf(connectionId);
        if (_same(now, keep)) return;
        await (delete(hostAccounts)..where((a) => a.connectionId.equals(connectionId))).go();
        for (var i = 0; i < keep.length; i++) {
          await into(hostAccounts).insert(HostAccountsCompanion.insert(
            connectionId: connectionId,
            identityId: keep[i],
            position: i,
          ));
        }
      });

  /// Forgets the other accounts of [connectionId] (it is being deleted).
  Future<void> deleteForConnection(String connectionId) =>
      (delete(hostAccounts)..where((a) => a.connectionId.equals(connectionId))).go();

  /// [identityId] is being deleted: it leaves every host. A host whose default
  /// it was is signed in to with its first other account from now on, or
  /// with none where it has none.
  Future<void> removeIdentity(String identityId) => transaction(() async {
        final hosts = await (select(connections)..where((c) => c.identityId.equals(identityId))).get();
        for (final host in hosts) {
          final others = (await otherAccountsOf(host.id)).where((id) => id != identityId).toList();
          final next = others.isEmpty ? null : others.first;
          await (update(connections)..where((c) => c.id.equals(host.id)))
              .write(ConnectionsCompanion(identityId: Value(next)));
          if (next != null) {
            await (delete(hostAccounts)
                  ..where((a) => a.connectionId.equals(host.id) & a.identityId.equals(next)))
                .go();
          }
        }
        await (delete(hostAccounts)..where((a) => a.identityId.equals(identityId))).go();
        // Nor does a network's settings for a host name it any more: the
        // host signs in there as it does elsewhere. (It kept naming a key
        // that was gone, and signed in with nothing.)
        await (update(db.hostNetworkOverrides)..where((o) => o.identityId.equals(identityId)))
            .write(const HostNetworkOverridesCompanion(identityId: Value(null)));
      });

  /// Every place that names a key no longer here (one deleted on another
  /// device, or by a restore, whose hosts this device kept): as [removeIdentity]
  /// leaves them. For your Tree's database only: a team space's hosts can
  /// name keys of Crates this device cannot see, which stay named.
  Future<void> forgetMissingIdentities() async {
    final here = {for (final i in await select(db.identities).get()) i.id};
    final named = <String>{
      for (final c in await select(connections).get()) ?c.identityId,
      for (final a in await select(hostAccounts).get()) a.identityId,
      for (final o in await select(db.hostNetworkOverrides).get()) ?o.identityId,
    };
    for (final gone in named.difference(here)) {
      await removeIdentity(gone);
    }
  }

  static bool _same(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
