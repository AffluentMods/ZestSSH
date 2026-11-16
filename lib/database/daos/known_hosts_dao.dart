import 'package:drift/drift.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/database/tables/known_hosts.dart';

part 'known_hosts_dao.g.dart';

@DriftAccessor(tables: [KnownHosts])
class KnownHostsDao extends DatabaseAccessor<AppDatabase>
    with _$KnownHostsDaoMixin {
  KnownHostsDao(super.db);

  /// NULL-safe `via_scope` predicate. A NULL [scope] matches only the
  /// direct-connection rows (`via_scope IS NULL`), so every pre-v32 pinned key
  /// keeps resolving; a non-null scope matches only that route.
  Expression<bool> _scopeMatch($KnownHostsTable t, String? scope) =>
      scope == null ? t.viaScope.isNull() : t.viaScope.equals(scope);

  /// Find a stored host key by host, port, key type, and route [viaScope]
  /// (NULL = direct). SQLite lets two direct (NULL-route) rows share host,
  /// port and key type, so a duplicate left by an older version is possible:
  /// the one checked on this device wins, then the oldest, instead of the
  /// lookup failing and taking every verify and every sync merge down with it.
  Future<KnownHost?> findHost(String host, int port, String keyType,
      {String? viaScope}) {
    return (select(knownHosts)
          ..where((t) =>
              t.host.equals(host) &
              t.port.equals(port) &
              t.keyType.equals(keyType) &
              _scopeMatch(t, viaScope))
          ..orderBy(_preferred)
          ..limit(1))
        .getSingleOrNull();
  }

  static final _preferred = <OrderClauseGenerator<$KnownHostsTable>>[
    (t) => OrderingTerm.desc(t.locallyVerified),
    (t) => OrderingTerm.asc(t.firstSeen),
    (t) => OrderingTerm.asc(t.id),
  ];

  /// The stored host key with this [id], whatever its route.
  Future<KnownHost?> getById(String id) =>
      (select(knownHosts)..where((t) => t.id.equals(id))).getSingleOrNull();

  /// Return ALL stored host keys for a host+port (optionally scoped to one
  /// route), regardless of key type.
  ///
  /// Used to detect key-type changes that could indicate MITM attacks. A
  /// deterministic, complete list (rather than an arbitrary `limit(1)` row)
  /// lets the caller evaluate every stored record together, so detection
  /// does not depend on which row the database happened to return.
  Future<List<KnownHost>> findAllForHostPort(String host, int port,
      {String? viaScope}) {
    return (select(knownHosts)
          ..where((t) =>
              t.host.equals(host) &
              t.port.equals(port) &
              _scopeMatch(t, viaScope))
          ..orderBy([(t) => OrderingTerm(expression: t.keyType)]))
        .get();
  }

  /// Whether any route (a jump host, not a direct connection) has a stored
  /// host key for host+port: the NULL-scope rows were copied to the first
  /// route already, or a route trusted one of its own (see
  /// KnownHostsService.verify).
  Future<bool> hasRoutedRows(String host, int port) async {
    final row = await (select(knownHosts)
          ..where((t) => t.host.equals(host) & t.port.equals(port) & t.viaScope.isNotNull())
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }

  /// Every stored host key for a host+port, on every route (direct, and
  /// through each jump host), whatever its key type: whether this device
  /// confirmed the endpoint itself anywhere (found in a
  /// code review).
  Future<List<KnownHost>> findAllForHostPortAnyRoute(String host, int port) {
    return (select(knownHosts)
          ..where((t) => t.host.equals(host) & t.port.equals(port))
          ..orderBy([(t) => OrderingTerm(expression: t.keyType), (t) => OrderingTerm(expression: t.id)]))
        .get();
  }

  /// Insert or update a host key entry.
  ///
  /// Resolves conflicts on the natural key (host + port + keyType + viaScope)
  /// rather than the primary key (id), so that synced entries with different
  /// IDs but the same natural key correctly update the existing row.
  Future<void> upsertHost(KnownHostsCompanion entry) async {
    // Serialize the select-then-insert so two concurrent upserts for the SAME
    // new host (e.g. a terminal + an SFTP session opening at once) can't both
    // find nothing and both insert. This matters because the natural-key UNIQUE
    // now includes the nullable via_scope, and SQLite treats each NULL as
    // distinct, so a direct-connection (via_scope NULL) duplicate would NOT be
    // rejected by the constraint - and two rows make findHost's getSingleOrNull
    // throw, bricking all future verifies for that host. drift runs
    // transactions one at a time, so this closes the race.
    await transaction(() async {
      final existing = await (select(knownHosts)
            ..where((t) =>
                t.host.equals(entry.host.value) &
                t.port.equals(entry.port.value) &
                t.keyType.equals(entry.keyType.value) &
                _scopeMatch(t, entry.viaScope.value))
            ..orderBy(_preferred)
            ..limit(1))
          .getSingleOrNull();

      if (existing != null) {
        // Whether this device confirmed the key, and with it which device
        // recorded it, is written when this device just did: a key trusted or
        // matched here. An update used to keep both as they were, so a key
        // adopted from a sync or a restore never counted as confirmed here
        // however often it matched, and its provenance notice showed at every
        // connect. Nothing else lowers them (found in a security
        // review).
        final confirmedHere = entry.locallyVerified.present && entry.locallyVerified.value;
        // Update existing entry, preserving its id
        await (update(knownHosts)..where((t) => t.id.equals(existing.id)))
            .write(KnownHostsCompanion(
          host: entry.host,
          port: entry.port,
          keyType: entry.keyType,
          fingerprint: entry.fingerprint,
          publicKeyBase64: entry.publicKeyBase64,
          firstSeen: const Value.absent(), // preserve original firstSeen
          lastSeen: entry.lastSeen,
          recordedDevice: confirmedHere ? entry.recordedDevice : const Value.absent(),
          locallyVerified: confirmedHere ? const Value(true) : const Value.absent(),
        ));
      } else {
        await into(knownHosts).insert(entry);
      }
    });
  }

  /// Migration compatibility: a copy of a NULL-scope known-host [row] (a
  /// direct connection's, or one pinned before v32) for the route [scope],
  /// under the new [id], so a bastion-reached target's pinned trust is
  /// preserved after the v32 upgrade instead of re-TOFU'ing, and the direct
  /// row stays for direct connections. See KnownHostsService.verify.
  ///
  /// (Up to 3.3 the row itself was moved to the route: a host trusted on a
  /// direct connection lost its pin the first time it was reached through a
  /// jump host.)
  Future<void> copyToScope(KnownHost row, String scope, {required String id}) {
    return into(knownHosts).insert(
      row.toCompanion(true).copyWith(id: Value(id), viaScope: Value(scope)),
      mode: InsertMode.insertOrIgnore,
    );
  }

  Future<void> deleteHost(String id) {
    return (delete(knownHosts)..where((t) => t.id.equals(id))).go();
  }

  /// Delete all entries for a specific host+port combination.
  Future<void> deleteByHostAndPort(String host, int port) {
    return (delete(knownHosts)
          ..where((t) => t.host.equals(host) & t.port.equals(port)))
        .go();
  }

  Stream<List<KnownHost>> watchAll() {
    return (select(knownHosts)
          ..orderBy([(t) => OrderingTerm(expression: t.host)]))
        .watch();
  }

  Future<List<KnownHost>> getAll() => select(knownHosts).get();

  /// Delete all known hosts.
  Future<void> deleteAll() => delete(knownHosts).go();
}
