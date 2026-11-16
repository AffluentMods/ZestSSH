import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/daos/networks_dao.dart';
import '../database/database.dart';
import '../features/hosts/data/host_network_overrides_repository.dart';
import '../features/hosts/models/host_network_override.dart';
import '../features/networks/data/network_repository.dart';
import '../features/networks/engine/connection_resolver.dart';
import '../features/networks/engine/network_detector.dart';
import '../features/networks/engine/network_state.dart';
import '../features/networks/models/network.dart';
import 'core_providers.dart';

/// DAO accessor for the Networks tables.
final networksDaoProvider = Provider<NetworksDao>((ref) {
  return ref.watch(databaseProvider).networksDao;
});

/// Singleton repository for the v1.6 Networks feature. Wraps [NetworksDao]
/// with model conversion + invariants (Default always exists, reorder
/// keeps Default pinned last, deleting a network strips its overrides).
final networkRepositoryProvider = Provider<NetworkRepository>((ref) {
  return NetworkRepository(ref.watch(networksDaoProvider));
});

/// Live ordered list of all networks. Default is always last.
final allNetworksProvider = StreamProvider<List<Network>>((ref) {
  final repo = ref.watch(networkRepositoryProvider);
  return repo.watch();
});

/// Repository for per-host network overrides. Reuses the same DAO as
/// [networkRepositoryProvider] but exposes the overrides API surface.
final hostNetworkOverridesRepositoryProvider =
    Provider<HostNetworkOverridesRepository>((ref) {
  return HostNetworkOverridesRepository(ref.watch(networksDaoProvider));
});

/// Per-host overrides, fetched on demand. Returns the empty list when
/// the host has no overrides at all.
final hostNetworkOverridesProvider =
    FutureProvider.family<List<HostNetworkOverride>, String>(
  (ref, hostId) {
    return ref
        .watch(hostNetworkOverridesRepositoryProvider)
        .listForHost(hostId);
  },
);

/// Detector singleton - pure function over the repository. Cheap to
/// construct; doesn't itself hold any state.
final networkDetectorProvider = Provider<NetworkDetector>((ref) {
  return NetworkDetector(ref.watch(networkRepositoryProvider));
});

/// Snapshot of the device's current network state. Fires once and
/// completes - UI that needs reactivity should use [currentNetworkProvider].
final currentNetworkStateProvider = FutureProvider<NetworkState>((ref) {
  return readCurrentNetworkState(requestSsid: true);
});

/// The network the detector currently reports as a match. Live-updates
/// when connectivity changes (debounced inside `watchConnectivityChanges`).
///
/// Note: this does NOT consider the manual override; that lives in
/// section 8 and is composed in `effectiveNetworkProvider` below.
final detectedNetworkProvider = StreamProvider<Network>((ref) {
  final detector = ref.watch(networkDetectorProvider);
  return detector.watch(useSsid: true);
});

/// Like [detectedNetworkProvider] but also carries WHY the network matched
/// (the winning trigger) so the UI can explain it - Doc-3 A1 row labels and
/// the A2 current-network banner. Live-updates on connectivity change.
final detectedNetworkMatchProvider = StreamProvider<NetworkMatch>((ref) {
  final detector = ref.watch(networkDetectorProvider);
  return detector.watchMatch(useSsid: true);
});

/// Composed view: the network the resolver should actually use, taking
/// the manual override into account. Defined here so callers don't have
/// to touch both providers.
///
/// When a manual override is set AND still names an existing network, that
/// forced network wins; otherwise this falls through to
/// [detectedNetworkProvider]. (The resolver honors the override
/// independently - see [ConnectionResolver]; this composition is for the
/// UI's effective-network display and the current-network banner.)
final effectiveNetworkProvider = Provider<AsyncValue<Network>>((ref) {
  final overrideId = ref.watch(manualNetworkOverrideIdProvider);
  final detected = ref.watch(detectedNetworkProvider);
  if (overrideId != null) {
    final networks = ref.watch(allNetworksProvider).valueOrNull;
    if (networks != null) {
      for (final n in networks) {
        if (n.id == overrideId) return AsyncData(n);
      }
      // The override names a network that no longer exists (deleted after
      // it was set). Fall through to detection rather than stranding the
      // user on a dead id - mirrors ConnectionResolver's safety net.
    }
  }
  return detected;
});

/// Manual network override holder - persisted across restarts via
/// [SettingsService]. Seeded from the stored id when first read and writes
/// the new value back on every change.
///
/// Holding this as a Provider exposing a [ValueNotifier] (not a
/// StateProvider) is deliberate: the resolver wants the raw
/// [ValueListenable] so it can read the current value on demand without
/// binding itself to a Riverpod ref. UI that needs to REACT to changes
/// should watch [manualNetworkOverrideIdProvider] instead.
final manualNetworkOverrideProvider =
    Provider<ValueNotifier<String?>>((ref) {
  final settings = ref.watch(settingsServiceProvider);
  final notifier = ValueNotifier<String?>(settings.manualNetworkOverrideId);
  // Persist every change so a forced profile survives an app restart.
  void persist() => settings.setManualNetworkOverrideId(notifier.value);
  notifier.addListener(persist);
  ref.onDispose(() {
    notifier.removeListener(persist);
    notifier.dispose();
  });
  return notifier;
});

/// Reactive read side of [manualNetworkOverrideProvider]: the currently
/// forced network id, or null for "Auto". Rebuilds whenever the override
/// changes so the effective-network display and the banner update live.
/// The underlying [ValueNotifier] stays the single source of truth.
final manualNetworkOverrideIdProvider = Provider<String?>((ref) {
  final notifier = ref.watch(manualNetworkOverrideProvider);
  void listener() => ref.invalidateSelf();
  notifier.addListener(listener);
  ref.onDispose(() => notifier.removeListener(listener));
  return notifier.value;
});

/// End-to-end connection resolver. Wraps the host record + matching
/// per-host override + the current effective network into a single
/// [ResolvedConnection] the connect flow can consume.
///
/// Holds no state of its own beyond the deps it forwards reads through;
/// the underlying daos, repos and detector own their state.
final connectionResolverProvider = Provider<ConnectionResolver>((ref) {
  return ConnectionResolver(
    connections: ref.watch(connectionsDaoProvider),
    identities: ref.watch(identitiesDaoProvider),
    overrides: ref.watch(hostNetworkOverridesRepositoryProvider),
    networks: ref.watch(networkRepositoryProvider),
    detector: ref.watch(networkDetectorProvider),
    manualOverride: ref.watch(manualNetworkOverrideProvider),
  );
});

/// [connectionResolverProvider] over [db]: for a host of a space that is not
/// the one on screen (a session works in its host's own space),
/// its overrides and networks as that space has them.
ConnectionResolver connectionResolverOver(Ref ref, AppDatabase db) => ConnectionResolver(
      connections: db.connectionsDao,
      identities: db.identitiesDao,
      overrides: HostNetworkOverridesRepository(db.networksDao),
      networks: NetworkRepository(db.networksDao),
      detector: ref.read(networkDetectorProvider),
      manualOverride: ref.read(manualNetworkOverrideProvider),
    );

/// The route the given host resolves to on the CURRENT effective network -
/// the "how did I get here" summary for the desktop session-details panel:
/// which network matched plus the effective address / port / jump chain.
///
/// Resolves live (re-runs when the effective network changes) so the panel
/// stays honest if the user roams while a session is open. Returns null on
/// ANY resolver failure - unknown host id, skip-host on the current network,
/// detector timeout - so the panel degrades gracefully instead of surfacing
/// an error. It never affects the live connect flow.
final sessionRouteProvider =
    FutureProvider.autoDispose.family<ResolvedConnection?, String>(
        (ref, hostId) async {
  // Re-resolve when the effective network changes.
  ref.watch(effectiveNetworkProvider);
  try {
    return await ref
        .read(connectionResolverProvider)
        .resolve(hostId)
        .timeout(const Duration(seconds: 5));
  } catch (_) {
    return null;
  }
});

/// Per-network resolution PREVIEW for a host (Doc-3 A1): for every network in
/// evaluation order (Default last), the computed status
/// (inherits / overrides / unreachable) and - for reachable networks - the
/// effective [ResolvedConnection] the host would use there. This is a pure
/// read over the existing engine (via [ConnectionResolver.mergeFromInputs]);
/// it does NOT run the live connect flow, so it's safe to render eagerly in
/// the host editor. Rebuilds when the networks list or the host's overrides
/// change.
final hostNetworkResolutionsProvider =
    FutureProvider.family<List<HostNetworkResolution>, String>(
        (ref, hostId) async {
  // Rebuild when the host's overrides are edited/saved.
  ref.watch(hostNetworkOverridesProvider(hostId));

  final connections = ref.watch(connectionsDaoProvider);
  final identities = ref.watch(identitiesDaoProvider);
  final overridesRepo = ref.watch(hostNetworkOverridesRepositoryProvider);
  final networksRepo = ref.watch(networkRepositoryProvider);

  final host = await connections.getById(hostId);
  if (host == null) return const <HostNetworkResolution>[];

  final networks = await networksRepo.list();
  final out = <HostNetworkResolution>[];
  for (final net in networks) {
    final override = await overridesRepo.getForHostAndNetwork(
      hostId: hostId,
      networkId: net.id,
    );

    // Check skip BEFORE isEmpty so a skip-only override is never mistaken
    // for "inherits".
    final HostNetworkStatus status;
    if (override != null && override.skipHost == true) {
      status = HostNetworkStatus.unreachable;
    } else if (override == null || override.isEmpty) {
      status = HostNetworkStatus.inherits;
    } else {
      status = HostNetworkStatus.overrides;
    }

    ResolvedConnection? preview;
    if (status != HostNetworkStatus.unreachable) {
      // Only look up the identity when we need it for the username (mirrors
      // ConnectionResolver._resolveIdentity so the preview matches connect).
      final idKeyId = override?.identityKeyId ?? host.identityId;
      final identity = (override?.username == null && idKeyId != null)
          ? await identities.getById(idKeyId)
          : null;
      preview = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: identity,
        override: override,
        network: net,
      );
    }

    out.add(HostNetworkResolution(
      network: net,
      status: status,
      preview: preview,
    ));
  }
  return out;
});

/// Live map of networkId → number of hosts that override on that network
/// (empty/no-op overrides excluded). Drives the networks-side "{n} host
/// overrides" badge (A3), per-profile counts (A2), and the delete-network
/// warning (A3).
final overrideCountsByNetworkProvider =
    StreamProvider<Map<String, int>>((ref) {
  return ref.watch(hostNetworkOverridesRepositoryProvider).watchCountsByNetwork();
});

/// The overrides for a single network across every host - the expandable
/// host list on a network row (A3). Each entry carries its `hostId`; the UI
/// resolves the host label.
final hostOverridesForNetworkProvider =
    FutureProvider.family<List<HostNetworkOverride>, String>(
        (ref, networkId) {
  // Rebuild when any override changes.
  ref.watch(overrideCountsByNetworkProvider);
  return ref
      .watch(hostNetworkOverridesRepositoryProvider)
      .listForNetwork(networkId);
});
