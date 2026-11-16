import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/network_repository.dart';
import '../models/network.dart';
import '../models/network_trigger.dart';
import 'cidr.dart';
import 'network_state.dart';

/// The result of network detection: the matched [network] plus the
/// [reason] - the specific trigger that caused it to match - so the UI can
/// explain WHY a network is active (Doc-3 A1 row labels + A2 banner). For
/// the Default fallback the reason is its [AlwaysTrigger].
@immutable
class NetworkMatch {
  const NetworkMatch({required this.network, this.reason});

  final Network network;

  /// The winning trigger, or null only when nothing was resolvable. For the
  /// Default fallback this is an [AlwaysTrigger].
  final NetworkTrigger? reason;
}

/// Resolves the device's current state to a single [Network] by walking
/// the user-defined list in evaluation order and returning the first
/// trigger match. The Default fallback always matches if nothing else
/// does (it has [AlwaysTrigger]).
class NetworkDetector {
  NetworkDetector(this._repo);

  final NetworkRepository _repo;

  /// Returns the first matching [Network] for the current state.
  ///
  /// [useSsid] flips the cost: when true we ask the OS for the WiFi SSID
  /// (permission-gated), when false we skip it entirely. Default is false
  /// because the hot path (e.g. when the user opens the picker) doesn't
  /// always need it; only `SsidTrigger`-bearing networks justify the cost.
  Future<Network> detect({bool useSsid = false}) async {
    final state = await readCurrentNetworkState(requestSsid: useSsid);
    return detectFromState(state);
  }

  /// Like [detect] but also reports WHICH trigger matched (the winning
  /// [NetworkTrigger]). See [NetworkMatch].
  Future<NetworkMatch> detectMatch({bool useSsid = false}) async {
    final state = await readCurrentNetworkState(requestSsid: useSsid);
    return detectMatchFromState(state);
  }

  /// Same as [detect] but with the state already collected. Useful in
  /// tests and when listening to a stream of states.
  Future<Network> detectFromState(NetworkState state) async {
    return (await detectMatchFromState(state)).network;
  }

  /// Same as [detectMatch] but with the state already collected - the core
  /// walk that all detection funnels through.
  Future<NetworkMatch> detectMatchFromState(NetworkState state) async {
    final networks = await _repo.list();
    for (final net in networks) {
      final trigger = matchingTrigger(net, state);
      if (trigger != null) {
        return NetworkMatch(network: net, reason: trigger);
      }
    }
    // Should be unreachable: ensureDefaultExists() always seeds Default.
    // If we somehow got here, synthesize an in-memory fallback so the
    // resolver doesn't crash an actual user.
    return NetworkMatch(
      network: Network.systemDefault(),
      reason: const AlwaysTrigger(),
    );
  }

  /// True if any of [net]'s triggers matches [state].
  ///
  /// `@visibleForTesting` to keep tests honest (they exercise the same
  /// matching logic that production uses).
  @visibleForTesting
  bool matches(Network net, NetworkState state) =>
      matchingTrigger(net, state) != null;

  /// The FIRST trigger of [net] that matches [state], or null if none do.
  /// Drives both [matches] and the why-matched [NetworkMatch.reason].
  @visibleForTesting
  NetworkTrigger? matchingTrigger(Network net, NetworkState state) {
    for (final t in net.triggers) {
      if (_triggerMatches(t, state)) return t;
    }
    return null;
  }

  bool _triggerMatches(NetworkTrigger trigger, NetworkState state) {
    return switch (trigger) {
      AlwaysTrigger() => true,
      SubnetTrigger(:final cidr) => _matchesSubnet(cidr, state),
      SsidTrigger(:final ssid) =>
        state.ssid != null && state.ssid == ssid,
      CellularTrigger() =>
        state.connectivityKind == ConnectivityKind.cellular,
      // A VPN is up whatever the connection under it is.
      ConnectivityTrigger(:final kind) =>
        state.connectivityKind == kind || (kind == ConnectivityKind.vpn && state.vpnUp),
      // The internal _UnknownTrigger never matches by design (we hit it
      // when reading a network created by a newer build).
      _ => false,
    };
  }

  bool _matchesSubnet(String cidr, NetworkState state) {
    final parsed = Cidr.tryParse(cidr);
    if (parsed == null) return false;
    return state.localAddresses.any(parsed.contains);
  }

  /// Stream that fires whenever the detected network changes. Internally
  /// listens to connectivity changes and re-detects, debouncing to avoid
  /// spam during interface flapping.
  ///
  /// Caller is responsible for cancelling the subscription.
  Stream<Network> watch({bool useSsid = false}) async* {
    // Emit current value immediately so subscribers don't see a gap.
    yield await detect(useSsid: useSsid);
    await for (final _ in watchConnectivityChanges(vpnCounts: true)) {
      try {
        yield await detect(useSsid: useSsid);
      } catch (_) {
        // Don't kill the stream on a transient detection error; just
        // skip this tick.
      }
    }
  }

  /// Like [watch] but emits the full [NetworkMatch] (network + why-matched).
  /// Used by the current-network banner so it can explain the match.
  Stream<NetworkMatch> watchMatch({bool useSsid = false}) async* {
    yield await detectMatch(useSsid: useSsid);
    await for (final _ in watchConnectivityChanges(vpnCounts: true)) {
      try {
        yield await detectMatch(useSsid: useSsid);
      } catch (_) {
        // Transient detection error - skip this tick, keep the stream alive.
      }
    }
  }
}

/// Ids of user networks that can NEVER match, computed purely from the
/// configuration (no device state, no match history). A network is dead when
/// either:
///
///  * it has no triggers at all (the editor blocks this, but a corrupt row
///    could carry it), or
///  * EVERY one of its triggers is already covered by a trigger on some
///    network positioned EARLIER in evaluation order. First-match-wins means
///    the earlier, broader rule always fires first, so this one is unreachable.
///
/// The system Default (an [AlwaysTrigger] pinned last) is never reported.
/// Drives the "Never matches" dead-config badge (Doc-3 §3.5). Pure so it is
/// directly unit-testable.
Set<String> shadowedNetworkIds(List<Network> networksInOrder) {
  final dead = <String>{};
  for (var i = 0; i < networksInOrder.length; i++) {
    final net = networksInOrder[i];
    if (net.isFallback) continue;
    if (net.triggers.isEmpty) {
      dead.add(net.id);
      continue;
    }
    final everyTriggerCovered = net.triggers.every(
      (t) => _triggerCoveredByEarlier(t, networksInOrder, i),
    );
    if (everyTriggerCovered) dead.add(net.id);
  }
  return dead;
}

/// True if [t] is covered by any trigger on a network positioned before
/// [uptoIndex] in evaluation order.
bool _triggerCoveredByEarlier(
  NetworkTrigger t,
  List<Network> networks,
  int uptoIndex,
) {
  for (var j = 0; j < uptoIndex; j++) {
    for (final earlier in networks[j].triggers) {
      if (_triggerCovers(earlier, t)) return true;
    }
  }
  return false;
}

/// Whether [broader] always fires for any state that would match [t] - i.e.
/// [t] is redundant behind [broader].
bool _triggerCovers(NetworkTrigger broader, NetworkTrigger t) {
  if (broader is AlwaysTrigger) return true;
  return switch (t) {
    SubnetTrigger(:final cidr) =>
      broader is SubnetTrigger && _cidrCovers(broader.cidr, cidr),
    SsidTrigger(:final ssid) => broader is SsidTrigger && broader.ssid == ssid,
    CellularTrigger() => broader is CellularTrigger ||
        (broader is ConnectivityTrigger &&
            broader.kind == ConnectivityKind.cellular),
    ConnectivityTrigger(:final kind) =>
      (broader is ConnectivityTrigger && broader.kind == kind) ||
          (kind == ConnectivityKind.cellular && broader is CellularTrigger),
    _ => false,
  };
}

/// True if the [broader] CIDR fully contains [inner]. Unparseable CIDRs never
/// cover (a malformed rule can't shadow anything).
bool _cidrCovers(String broader, String inner) {
  final b = Cidr.tryParse(broader);
  final i = Cidr.tryParse(inner);
  if (b == null || i == null) return false;
  return b.containsCidr(i);
}
