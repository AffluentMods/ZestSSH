import 'package:drift/drift.dart';

/// Named environments (Home, Work, Cellular, Default, ...) with detection
/// rules. Evaluated top to bottom by [sortOrder]; first match wins. The
/// system Default network has `isFallback = true` and is pinned last.
///
/// `triggersJson` stores the list of triggers as a JSON-encoded array.
/// Each trigger entry has a `type` discriminator (`subnet`, `ssid`,
/// `cellular`, `connectivity`, `always`) plus its own kind-specific fields.
/// See `lib/features/networks/models/network_trigger.dart`.
///
/// The generated Drift row class is named `NetworkRow` rather than the
/// default `Network` to avoid colliding with our domain model
/// `lib/features/networks/models/network.dart`.
@DataClassName('NetworkRow')
class Networks extends Table {
  /// Stable id. The system Default network always uses `'system_default'`.
  TextColumn get id => text()();

  /// Display name. Editor caps to 32 chars.
  TextColumn get name => text().withLength(min: 1, max: 64)();

  /// Index into `GroupColor` enum.
  IntColumn get colorIndex => integer().withDefault(const Constant(0))();

  /// Optional custom accent colour (ARGB int). Overrides [colorIndex] when set;
  /// NULL = use the index. Additive + nullable.
  IntColumn get colorValue => integer().nullable()();

  /// IconData breakdown so we can reconstruct the exact icon. Lucide and
  /// Material both use IconData under the hood, just with different
  /// fontFamily / fontPackage tuples.
  IntColumn get iconCodePoint => integer()();
  TextColumn get iconFontFamily => text().nullable()();
  TextColumn get iconFontPackage => text().nullable()();

  /// JSON-encoded list of triggers.
  TextColumn get triggersJson => text().withDefault(const Constant('[]'))();

  /// True only for the single system Default network.
  BoolColumn get isFallback => boolean().withDefault(const Constant(false))();

  /// Optional connection id of a VPN host to bring up before connecting
  /// through this network. References `connections.id` but we don't FK it
  /// because the VPN host might be deleted later and we'd rather no-op
  /// than cascade.
  TextColumn get bringUpVpn => text().nullable()();

  /// Evaluation order. Lower values evaluated first. The Default network
  /// uses `sortOrder = 1<<30` (effectively pinned to the bottom).
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime()();

  /// Last-modified time - bumped on every edit; drives cloud-sync tombstone
  /// "newest wins". Nullable: pre-v29 rows are backfilled to createdAt in the
  /// migration; a row never edited on v29+ stays null (delete-wins).
  DateTimeColumn get updatedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Per-host overrides keyed by `(connectionId, networkId)`. Each row is a
/// "when I'm on this network, talk to this host like this" rule.
///
/// Most fields are nullable: a missing value means "fall through to the
/// base host config." `skipHost` short-circuits everything else.
@TableIndex(name: 'idx_host_net_overrides_conn',
    columns: {#connectionId})
@TableIndex(name: 'idx_host_net_overrides_net',
    columns: {#networkId})
@DataClassName('HostNetworkOverrideRow')
class HostNetworkOverrides extends Table {
  TextColumn get id => text()();

  /// FK-style reference to `connections.id`. Cleaned up by repository
  /// when the host is deleted.
  TextColumn get connectionId => text()();

  /// FK-style reference to `networks.id`. Cleaned up by repository
  /// when the network is deleted.
  TextColumn get networkId => text()();

  /// Override the hostname or IP. Null = inherit from base host.
  TextColumn get address => text().nullable()();

  /// Override the port. Null = inherit.
  IntColumn get port => integer().nullable()();

  /// Override the SSH username. Null = inherit.
  TextColumn get username => text().nullable()();

  /// Override the identity (key) id. Null = inherit.
  TextColumn get identityId => text().nullable()();

  /// Single jump host id, OR a JSON-encoded list of host ids for a chain.
  /// Mutually exclusive - only one populated at a time. An explicit empty
  /// list (`[]`) in `jumpChainJson` means "no jump host" (overrides base).
  TextColumn get jumpHostId => text().nullable()();
  TextColumn get jumpChainJson => text().nullable()();

  /// If true, this host is unreachable from this network. Connect attempts
  /// from this network show a friendly error instead of trying.
  BoolColumn get skipHost => boolean().nullable()();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
