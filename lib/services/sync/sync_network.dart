import 'package:zestssh/features/networks/engine/network_state.dart' show watchConnectivityChanges;
import 'package:zestssh/features/networks/models/network_trigger.dart' show ConnectivityKind;

/// The device's network changing, as background sync hears of it: whether
/// there is a network now ([AutoSyncService.networkUp]). The app gives it to
/// the service as it starts; a screen under test never asks the platform
/// how its network stands.
Stream<bool> syncNetworkUp() => networkUpOf(watchConnectivityChanges());

/// [changes] as whether there is a network: every kind of one counts (a
/// cable, Wi-Fi, a phone's data, a VPN), and only none at all does not.
Stream<bool> networkUpOf(Stream<ConnectivityKind> changes) => changes.map((kind) => kind != ConnectivityKind.none);
