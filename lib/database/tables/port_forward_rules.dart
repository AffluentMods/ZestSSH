import 'package:drift/drift.dart';
import 'package:zestssh/database/tables/connections.dart';

/// Saved port forwarding rules per connection.
///
/// Rules are persisted across app restarts and can be auto-activated
/// when a session connects. Each rule belongs to a specific connection.
class PortForwardRules extends Table {
  TextColumn get id => text()();

  /// The connection this rule belongs to.
  TextColumn get connectionId => text().references(Connections, #id)();

  /// Type of forward: 'local' (-L) or 'remote' (-R).
  TextColumn get type => text()(); // 'local' | 'remote'

  /// Local bind address (default 127.0.0.1).
  TextColumn get bindAddress =>
      text().withDefault(const Constant('127.0.0.1'))();

  /// Local bind port.
  IntColumn get bindPort => integer()();

  /// Remote destination host.
  TextColumn get remoteHost => text()();

  /// Remote destination port.
  IntColumn get remotePort => integer()();

  /// Whether to auto-start this forward when the session connects.
  BoolColumn get autoStart =>
      boolean().withDefault(const Constant(false))();

  /// Re-establish the forward automatically if the tunnel drops. On by default.
  BoolColumn get reconnect =>
      boolean().withDefault(const Constant(true))();

  /// Fail the SSH session if the forward can't be established
  /// (`ExitOnForwardFailure=yes`). On by default so a broken forward surfaces
  /// immediately instead of silently doing nothing.
  BoolColumn get exitOnFailure =>
      boolean().withDefault(const Constant(true))();

  /// Allow other devices on the local network to reach this forward
  /// (`ssh -g` / `GatewayPorts`). OFF by default - a security-sensitive LAN
  /// exposure that must be opted into, and is force-disabled on sync restore.
  BoolColumn get gatewayPorts =>
      boolean().withDefault(const Constant(false))();

  /// Extra raw SSH flags for anything the structured Options toggles don't
  /// cover. Surfaced in the command preview; the toggles above are primary.
  TextColumn get sshFlags => text().nullable()();

  /// Optional human-readable label for the rule (the Advanced "Name" field).
  TextColumn get label => text().nullable()();

  /// Optional Network filter (v1.5).
  ///
  /// When set, this rule only auto-starts while the device is on the
  /// matching Network (Home WiFi, Office subnet, etc.).  Null = "all
  /// networks", which matches the pre-v1.5 behaviour so existing
  /// rules don't change semantics on upgrade.
  ///
  /// Held as a TEXT id (not a foreign key) so deleting a Network
  /// doesn't cascade-delete the user's port-forward rules - the
  /// resolver simply treats an unknown id as "no longer pinned".
  TextColumn get networkId => text().nullable()();

  DateTimeColumn get createdAt => dateTime()();

  /// Last-modified time - bumped on every edit; drives cloud-sync tombstone
  /// "newest wins". Nullable: pre-v29 rows are backfilled to createdAt in the
  /// migration; a row never edited on v29+ stays null (delete-wins).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}
