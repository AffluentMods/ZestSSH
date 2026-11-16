import 'package:drift/drift.dart';

/// The three states a saved port-forward rule can be in for ONE specific
/// network row. Persisted as the `state` TEXT column on
/// [PortForwardNetworkOverrides].
///
/// Kept lowercase + stable - the values are written to the database, so
/// don't rename a case without a migration.
enum PortForwardNetworkState {
  /// No per-network opinion. Falls through to the rule's own base
  /// semantics (its `autoStart` flag plus any `networkId` pin). This is the
  /// absence-of-a-row case - the pre-v1.6 behaviour for every existing rule.
  inherit,

  /// Force this forward ON for the network.
  on,

  /// Force this forward OFF for the network.
  off;

  /// The stored string form.
  String get dbValue => switch (this) {
        PortForwardNetworkState.inherit => 'inherit',
        PortForwardNetworkState.on => 'on',
        PortForwardNetworkState.off => 'off',
      };

  /// Parse a stored string; anything unknown or null maps to [inherit] - the
  /// safe default that preserves the rule's own base semantics.
  static PortForwardNetworkState fromDb(String? value) => switch (value) {
        'on' => PortForwardNetworkState.on,
        'off' => PortForwardNetworkState.off,
        _ => PortForwardNetworkState.inherit,
      };
}

/// Per-`(port-forward rule, network)` enable/disable state.
///
/// A single [PortForwardRules] row carries only base semantics: its
/// `autoStart` flag and an optional single `networkId` pin ("auto-start only
/// while on network X"). That can't express "this forward is on / off /
/// inherited PER network row". This table layers that per-network state on
/// top: one row per `(ruleId, networkId)` pair the user has an explicit
/// opinion about.
///
/// Absence of a row = [PortForwardNetworkState.inherit]: the rule keeps its
/// own base autoStart + networkId-pin semantics on that network. A row with
/// `state = 'on'` forces the forward active for the network; `'off'` forces
/// it disabled.
///
/// Neither [ruleId] nor [networkId] is a foreign key - mirroring the
/// deliberate NON-FK choice on [PortForwardRules.networkId]. Deleting a
/// Network (or the underlying rule) therefore never cascade-deletes user
/// data; a dangling override row is simply ignored.
@TableIndex(name: 'idx_pf_net_overrides_rule', columns: {#ruleId})
@TableIndex(name: 'idx_pf_net_overrides_net', columns: {#networkId})
@DataClassName('PortForwardNetworkOverrideRow')
class PortForwardNetworkOverrides extends Table {
  TextColumn get id => text()();

  /// NON-FK reference to `port_forward_rules.id`.
  TextColumn get ruleId => text()();

  /// NON-FK reference to `networks.id`.
  TextColumn get networkId => text()();

  /// Enum-as-string: `inherit` | `on` | `off`. See [PortForwardNetworkState].
  TextColumn get state =>
      text().withDefault(const Constant('inherit'))();

  DateTimeColumn get createdAt => dateTime()();
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};

  /// One state row per `(rule, network)` pair.
  @override
  List<Set<Column>> get uniqueKeys => [
        {ruleId, networkId},
      ];
}
