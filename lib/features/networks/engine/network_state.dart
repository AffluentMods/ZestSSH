import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:network_info_plus/network_info_plus.dart';

import '../../../utils/logger.dart';
import '../models/network_trigger.dart';

/// Whether this device reads the name of the Wi-Fi it is on: on a computer,
/// never on a phone. Android and iOS give it only to an app with location
/// access, which ZestSSH does not ask for (it tracks nobody), so a Wi-Fi
/// name rule could never match there (before, the phone's editor
/// offered it and said to grant a permission the app never declares). A
/// phone's network is told by its subnet, cellular or the connection type.
/// Nor on a Mac: recent macOS gives the Wi-Fi name only to an app with
/// Location Services, which ZestSSH does not declare, so the rule was offered
/// there and never matched, with nothing said.
bool get wifiNamesReadHere => debugWifiNamesReadHere ?? wifiNamesReadOn(Platform.operatingSystem);

/// Whether the system [os] (Platform.operatingSystem) gives ZestSSH the Wi-Fi
/// name: Windows and Linux.
bool wifiNamesReadOn(String os) => os == 'windows' || os == 'linux';

/// Stands in for the platform in tests.
@visibleForTesting
bool? debugWifiNamesReadHere;

/// Snapshot of the device's current network state. Pure data - produced
/// by [readCurrentNetworkState] and consumed by [NetworkDetector].
@immutable
class NetworkState {
  const NetworkState({
    required this.localAddresses,
    required this.connectivityKind,
    this.ssid,
    this.vpnUp = false,
  });

  /// All non-loopback IPv4/IPv6 addresses currently bound on the device.
  /// On desktop this typically includes both v4 and v6 addresses on the
  /// active interface; on mobile it's usually just the active network.
  final List<String> localAddresses;

  /// Best-effort classification of the current connectivity. Maps from
  /// `connectivity_plus`'s [ConnectivityResult] enum.
  final ConnectivityKind connectivityKind;

  /// Current SSID if available and permitted. Null on iOS without
  /// entitlement, null on Android without `ACCESS_FINE_LOCATION` granted,
  /// null when not requested. Trim quotes - on Android the system
  /// sometimes returns SSIDs wrapped in `"..."`.
  final String? ssid;

  /// Whether a VPN is up beside the connection [connectivityKind] names (a
  /// VPN over Wi-Fi reads as Wi-Fi there): a "VPN is up" rule matches on it
  /// (before, it matched only where the VPN was all there was).
  final bool vpnUp;

  /// Empty state used as a safe fallback if state collection fails.
  static const NetworkState empty = NetworkState(
    localAddresses: [],
    connectivityKind: ConnectivityKind.none,
  );
}

/// Build a [NetworkState] snapshot for the current moment.
///
/// **Permissions**: the SSID is read on a computer only
/// ([wifiNamesReadHere]); the notes below are why.
/// - SSID lookup on iOS requires the
///   `com.apple.developer.networking.wifi-info` entitlement and a granted
///   location permission. Without those, `getWifiName()` returns null
///   silently.
/// - SSID lookup on Android requires `ACCESS_FINE_LOCATION` granted at
///   runtime. We don't request the permission here - caller is
///   responsible. If the permission is missing, the SSID comes back null.
///
/// The function never throws. Any unexpected failure logs a warning and
/// returns [NetworkState.empty].
Future<NetworkState> readCurrentNetworkState({
  bool requestSsid = false,
}) async {
  try {
    // ── Local addresses ─────────────────────────────────────────
    final addresses = <String>[];
    try {
      final ifaces = await NetworkInterface.list(
        includeLoopback: false,
        includeLinkLocal: false,
        type: InternetAddressType.any,
      );
      for (final iface in ifaces) {
        for (final addr in iface.addresses) {
          if (addr.isLoopback) continue;
          // Strip the IPv6 zone id (e.g. fe80::1%eth0) for cleaner
          // matching against CIDRs that don't include zones.
          final rawAddress = addr.address;
          final percent = rawAddress.indexOf('%');
          final clean = percent == -1
              ? rawAddress
              : rawAddress.substring(0, percent);
          addresses.add(clean);
        }
      }
    } catch (e) {
      AppLogger.warning('[networks] NetworkInterface.list failed: $e');
    }

    // ── Connectivity ───────────────────────────────────────────
    ConnectivityKind kind = ConnectivityKind.none;
    var vpnUp = false;
    try {
      final results = await Connectivity().checkConnectivity();
      kind = _mapConnectivityResults(results);
      vpnUp = results.contains(ConnectivityResult.vpn);
    } catch (e) {
      AppLogger.warning('[networks] checkConnectivity failed: $e');
    }

    // ── SSID (optional, permission-gated) ──────────────────────
    String? ssid;
    if (requestSsid && kind == ConnectivityKind.wifi && wifiNamesReadHere) {
      try {
        ssid = await NetworkInfo().getWifiName();
        // Some Android devices wrap the SSID in surrounding quotes.
        if (ssid != null) {
          if (ssid.startsWith('"') && ssid.endsWith('"') && ssid.length >= 2) {
            ssid = ssid.substring(1, ssid.length - 1);
          }
          if (ssid.isEmpty || ssid == '<unknown ssid>') ssid = null;
        }
      } catch (e) {
        // Permission missing or platform unsupported - fall through to null.
        AppLogger.warning('[networks] getWifiName failed: $e');
        ssid = null;
      }
    }

    return NetworkState(
      localAddresses: addresses,
      connectivityKind: kind,
      ssid: ssid,
      vpnUp: vpnUp,
    );
  } catch (e) {
    AppLogger.warning('[networks] readCurrentNetworkState failed: $e');
    return NetworkState.empty;
  }
}

/// Map `connectivity_plus`'s result list to our single classification.
///
/// `Connectivity().checkConnectivity()` returns a list because the device
/// might be on multiple interfaces simultaneously (e.g. wifi + ethernet
/// on a laptop in a dock). We pick a single classification using a
/// priority order that matches user intent: ethernet > wifi > vpn >
/// cellular > none.
ConnectivityKind _mapConnectivityResults(List<ConnectivityResult> results) {
  if (results.isEmpty) return ConnectivityKind.none;

  if (results.contains(ConnectivityResult.ethernet)) {
    return ConnectivityKind.ethernet;
  }
  if (results.contains(ConnectivityResult.wifi)) {
    return ConnectivityKind.wifi;
  }
  if (results.contains(ConnectivityResult.vpn)) {
    return ConnectivityKind.vpn;
  }
  if (results.contains(ConnectivityResult.mobile)) {
    return ConnectivityKind.cellular;
  }
  if (results.contains(ConnectivityResult.bluetooth)) {
    // Bluetooth tethering shows up as cellular-equivalent for our purposes.
    return ConnectivityKind.cellular;
  }
  return ConnectivityKind.none;
}

/// A debounced stream that fires whenever connectivity changes. Emits
/// the new connectivity kind. Wraps `connectivity_plus` so callers don't
/// need to map results themselves.
///
/// Debounced 1 second to avoid spam during interface flapping (a common
/// scenario when waking a laptop or roaming between APs).
///
/// With [vpnCounts], a VPN coming up or going down is a change too, though
/// the kind stays (a VPN over Wi-Fi is still Wi-Fi): what the network
/// detector needs, since a network can be matched by a VPN being up.
Stream<ConnectivityKind> watchConnectivityChanges({
  Duration debounce = const Duration(seconds: 1),
  bool vpnCounts = false,
}) async* {
  final controller = Connectivity().onConnectivityChanged;
  (ConnectivityKind, bool)? lastEmitted;
  DateTime lastEmitAt = DateTime.fromMillisecondsSinceEpoch(0);
  await for (final results in controller) {
    final kind = _mapConnectivityResults(results);
    final change = (kind, vpnCounts && results.contains(ConnectivityResult.vpn));
    if (change == lastEmitted) continue;
    final now = DateTime.now();
    if (now.difference(lastEmitAt) < debounce) {
      // Wait out the debounce window then re-check.
      await Future.delayed(debounce - now.difference(lastEmitAt));
    }
    lastEmitted = change;
    lastEmitAt = DateTime.now();
    yield kind;
  }
}
