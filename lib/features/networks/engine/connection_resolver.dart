import 'package:flutter/foundation.dart';
import 'package:zestssh/utils/type_name.dart';

import '../../../database/daos/connections_dao.dart';
import '../../../database/daos/identities_dao.dart';
import '../../../database/database.dart';
import '../../hosts/data/host_network_overrides_repository.dart';
import '../../hosts/models/host_network_override.dart';
import '../data/network_repository.dart';
import '../models/network.dart';
import 'network_detector.dart';

/// Effective connection config for a host on a specific network.
///
/// Built by [ConnectionResolver.resolve]. Carries the merged result of
/// the base host config + any matching per-host network override + the
/// network's own settings (e.g. VPN auto-up). The connect flow consumes
/// this and never re-reads the underlying host record itself.
@immutable
class ResolvedConnection {
  const ResolvedConnection({
    required this.hostId,
    required this.network,
    required this.address,
    required this.port,
    required this.username,
    required this.identityKeyId,
    required this.jumpChain,
    required this.bringUpVpnHostId,
  });

  /// Stable id of the originating host (Connection row id).
  final String hostId;

  /// The network this resolution is scoped to. The connect flow uses this
  /// for telemetry and the "connected via Home" labels.
  final Network network;

  /// Hostname or IP to connect to. Override wins, else base host.
  final String address;

  final int port;

  /// SSH username. Override wins; else inherited from the identity (which
  /// is the project's source of truth for the username - the Connection
  /// row doesn't carry one of its own).
  final String username;

  /// Identity (key/credential) row id, or null if the host has no
  /// identity attached. Override wins.
  final String? identityKeyId;

  /// Ordered jump-host chain. Empty list = direct connection. Never null.
  /// If the override sets an explicit empty list, that wins over the
  /// base host's `connectViaId` - the user is saying "skip the jump on
  /// this network."
  final List<String> jumpChain;

  /// If the matching network has a VPN host configured, the connect flow
  /// should bring that host up before attempting the target connection.
  /// Null = no VPN auto-up.
  final String? bringUpVpnHostId;
}

/// Per-network resolution status for a host - the 3 states Doc-3 A1 wants
/// on each network row.
enum HostNetworkStatus {
  /// No override (or an empty one): the network uses the base host config.
  inherits,

  /// An override supplies at least one field that differs from the base.
  overrides,

  /// The override marks the host as skipped/unreachable on this network.
  unreachable,
}

/// A host's computed resolution against ONE network - its [status] and, for
/// reachable networks, the effective [preview] connection. Feeds the A1
/// per-network rows (collapsed rows show the resolved address/port/route,
/// not "use base") without touching the live connect flow.
@immutable
class HostNetworkResolution {
  const HostNetworkResolution({
    required this.network,
    required this.status,
    this.preview,
  });

  final Network network;
  final HostNetworkStatus status;

  /// The effective connection for this network. Null only when [status] is
  /// [HostNetworkStatus.unreachable].
  final ResolvedConnection? preview;
}

/// Thrown by [ConnectionResolver.resolve] when the matching override has
/// `skipHost: true`. The connect flow should catch this and surface a
/// localized toast - not a crash.
class HostUnreachableException implements Exception, HasTypeName {
  HostUnreachableException(this.hostName, this.networkName);

  final String hostName;
  final String networkName;

  @override
  String toString() =>
      'HostUnreachableException: "$hostName" is marked unreachable on '
      'network "$networkName"';

  @override
  String get typeName => 'HostUnreachableException';
}

/// Resolves a host id + the device's current network into a single
/// [ResolvedConnection]. Pure pipeline:
///
///   1. Determine the effective network: manual override (if set) wins;
///      otherwise ask the detector.
///   2. Look up the per-(host, network) override row, if any.
///   3. If `skipHost == true`, throw [HostUnreachableException].
///   4. Merge base host fields with the override fields.
///   5. Look up the identity for the username when not overridden.
///   6. Compute the jump chain with the explicit-empty-list semantics
///      (see [ResolvedConnection.jumpChain]).
///
/// This class doesn't cache. Each call hits the DAOs. Connection flows
/// already happen sub-second-rare, and caching would complicate the
/// network-change rebind story for negligible win.
class ConnectionResolver {
  ConnectionResolver({
    required ConnectionsDao connections,
    required IdentitiesDao identities,
    required HostNetworkOverridesRepository overrides,
    required NetworkRepository networks,
    required NetworkDetector detector,
    required ValueListenable<String?> manualOverride,
  })  : _connections = connections,
        _identities = identities,
        _overrides = overrides,
        _networks = networks,
        _detector = detector,
        _manualOverride = manualOverride;

  final ConnectionsDao _connections;
  final IdentitiesDao _identities;
  final HostNetworkOverridesRepository _overrides;
  final NetworkRepository _networks;
  final NetworkDetector _detector;

  /// Reactive value driven by the manual override picker (Section 8).
  /// Null means "use auto-detection." When non-null and the referenced
  /// network still exists, it beats the detector. If the id no longer
  /// resolves to a network (e.g. the user deleted it after setting the
  /// override) we silently fall back to detection.
  final ValueListenable<String?> _manualOverride;

  /// Resolve the connection config for [hostId] right now.
  ///
  /// Throws [StateError] if [hostId] is unknown - caller violated the
  /// contract by passing a deleted host id.
  ///
  /// Throws [HostUnreachableException] if the matching override marks
  /// this host as unreachable on the current network.
  Future<ResolvedConnection> resolve(String hostId) => _resolve(hostId, null);

  /// [resolve] on a [network] that was looked up already ([currentNetwork]),
  /// for whoever resolves several hosts in one go: finding the network asks
  /// the system (its interfaces, the name of its Wi-Fi), once is enough.
  Future<ResolvedConnection> resolveOn(Network network, String hostId) => _resolve(hostId, network);

  Future<ResolvedConnection> _resolve(String hostId, Network? known) async {
    final host = await _connections.getById(hostId);
    if (host == null) {
      throw StateError('No connection found with id "$hostId"');
    }

    var network = known ?? await currentNetwork();
    // A "Reach via" host that was deleted is none, as its field shows it:
    // the hosts connect as they would without it.
    final via = network.bringUpVpn;
    if (via != null && via != hostId && await _connections.getById(via) == null) {
      network = network.copyWith(bringUpVpn: null);
    }

    final override = await _overrides.getForHostAndNetwork(
      hostId: hostId,
      networkId: network.id,
    );

    return mergeFromInputs(
      host: host,
      identity: await _resolveIdentity(host, override),
      override: override,
      network: network,
    );
  }

  /// Decide which network to evaluate against. Manual override wins when
  /// it points at a network that still exists; otherwise the detector
  /// runs. The detector is also the safety net when the manual override's
  /// referenced network has been deleted.
  Future<Network> currentNetwork() async {
    final manual = _manualOverride.value;
    if (manual != null) {
      final picked = await _networks.get(manual);
      if (picked != null) return picked;
      // Manual id stale (network was deleted). Fall through to detection.
    }
    return _detector.detect(useSsid: true);
  }

  /// Look up only the identity we actually need to read the username from.
  /// Skipped entirely when the override sets a username (no read needed).
  Future<Identity?> _resolveIdentity(
    Connection host,
    HostNetworkOverride? override,
  ) async {
    if (override?.username != null) return null;
    final id = override?.identityKeyId ?? host.identityId;
    if (id == null) return null;
    return _identities.getById(id);
  }

  /// Pure merge over already-fetched inputs. Public because two production
  /// paths use it: [resolve] (the live connect flow) and the per-network
  /// resolution preview (`hostNetworkResolutionsProvider`), plus unit tests
  /// that exercise every merge branch without a database.
  static ResolvedConnection mergeFromInputs({
    required Connection host,
    required Identity? identity,
    required HostNetworkOverride? override,
    required Network network,
  }) {
    if (override?.skipHost == true) {
      throw HostUnreachableException(host.label, network.name);
    }

    final username = override?.username ?? identity?.username ?? '';
    final identityKeyId = override?.identityKeyId ?? host.identityId;
    final jumpChain = _resolveJumpChain(override: override, host: host, reachVia: network.bringUpVpn);

    return ResolvedConnection(
      hostId: host.id,
      network: network,
      address: override?.address ?? host.host,
      port: override?.port ?? host.port,
      username: username,
      identityKeyId: identityKeyId,
      jumpChain: jumpChain,
      bringUpVpnHostId: network.bringUpVpn,
    );
  }

  /// Jump-chain resolution with the spec's explicit-empty-list semantics:
  ///
  /// 1. `override.jumpHostChain` takes precedence when present, even if
  ///    it's an empty list. That's the "no jump on this network" override.
  /// 2. Otherwise `override.jumpHostId` (single-hop override) is wrapped.
  /// 3. Otherwise the base host's `connectViaId` is wrapped (legacy
  ///    pre-Networks single-jump model).
  /// 4. Otherwise the network's "Reach via" host ([reachVia], the network's
  ///    `bringUpVpn`): the host is connected to through it, as through a jump
  ///    host (before, it was saved and read into the route, and
  ///    nothing used it). Not for the "Reach via" host itself, and not for a
  ///    host that has a way of its own (an override, or Connect via): that
  ///    way stands.
  /// 5. Otherwise an empty list (direct connection).
  static List<String> _resolveJumpChain({
    required HostNetworkOverride? override,
    required Connection host,
    String? reachVia,
  }) {
    if (override?.jumpHostChain != null) {
      // Defensive copy so callers can't mutate the override's storage list.
      return List<String>.unmodifiable(override!.jumpHostChain!);
    }
    if (override?.jumpHostId != null) {
      return List<String>.unmodifiable([override!.jumpHostId!]);
    }
    if (host.connectViaId != null) {
      return List<String>.unmodifiable([host.connectViaId!]);
    }
    if (reachVia != null && reachVia.isNotEmpty && reachVia != host.id) {
      return List<String>.unmodifiable([reachVia]);
    }
    return const [];
  }

  /// The Free-tier jump gate, as a pure decision the connect path applies at
  /// the one place a chain is dialed.
  ///
  /// Jump-host routing is a Squeezed feature, for the base host's Connect Via
  /// chain and for a per-network override chain alike (the plans page, the
  /// Upgrade screen and the base field's editor lock all say so). Before this
  /// gate only the editor was locked, so an override chain, or a connectViaId
  /// that arrived by sync or import, still routed for a free user.
  ///
  /// Returns null when the chain may be dialed: the user is Squeezed, or no
  /// chain would apply. [overrideChangedJump] is the connect path's "the
  /// override changed the jump routing" test and [overrideChain] the override's
  /// chain; an override that explicitly CLEARED the jump (empty chain) is a
  /// direct connection and is never gated. Otherwise returns why the chain is
  /// skipped, for the one-time notice.
  static JumpGateSkip? jumpGateSkip({
    required bool isPro,
    required bool baseHasConnectVia,
    required bool overrideChangedJump,
    required List<String> overrideChain,
    String? networkName,
  }) {
    if (isPro) return null;
    if (overrideChangedJump) {
      if (overrideChain.isEmpty) return null;
      return JumpGateSkip(fromOverride: true, networkName: networkName);
    }
    if (baseHasConnectVia) return const JumpGateSkip(fromOverride: false);
    return null;
  }
}

/// Why a jump chain was not dialed for a Free-tier user. See
/// [ConnectionResolver.jumpGateSkip].
class JumpGateSkip {
  const JumpGateSkip({required this.fromOverride, this.networkName});

  /// True when the chain came from a per-network override; false when it was
  /// the base host's Connect Via.
  final bool fromOverride;

  /// The network whose override set the chain; null for the base chain.
  final String? networkName;
}
