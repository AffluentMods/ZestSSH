import 'package:flutter/foundation.dart';

/// Connectivity classes the detector can report.
///
/// Storage uses the enum's `name`. Don't rename existing entries - append
/// new ones at the end if needed.
enum ConnectivityKind { wifi, ethernet, cellular, vpn, none }

/// A condition that can match the device's current network state.
///
/// Multiple triggers on a single [Network] are OR'd: any match means the
/// network matches. The trigger types form a closed sealed hierarchy so
/// the engine can switch on them exhaustively.
@immutable
sealed class NetworkTrigger {
  const NetworkTrigger();

  /// JSON serialisation discriminator. Keep these strings stable -
  /// changing one is a breaking change for stored networks.
  String get type;

  Map<String, dynamic> toJson();

  static NetworkTrigger fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'subnet':
        return SubnetTrigger(json['cidr'] as String? ?? '');
      case 'ssid':
        return SsidTrigger(json['ssid'] as String? ?? '');
      case 'cellular':
        return const CellularTrigger();
      case 'connectivity':
        final raw = json['kind'] as String?;
        final kind = ConnectivityKind.values.firstWhere(
          (k) => k.name == raw,
          orElse: () => ConnectivityKind.none,
        );
        return ConnectivityTrigger(kind);
      case 'always':
        return const AlwaysTrigger();
      default:
        // Unknown trigger types are dropped on read, never crash. This
        // keeps a future-version network spec from bricking an older
        // build that doesn't recognise a new trigger kind.
        return const _UnknownTrigger();
    }
  }
}

/// Match if the device has any IP address inside the given CIDR.
///
/// Example: `192.168.10.0/24` matches anything on that LAN. The CIDR
/// is stored as text and parsed lazily by the engine - invalid CIDRs
/// are caught at editor save time, not at storage time.
class SubnetTrigger extends NetworkTrigger {
  const SubnetTrigger(this.cidr);
  final String cidr;

  @override
  String get type => 'subnet';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'cidr': cidr};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SubnetTrigger && other.cidr == cidr);

  @override
  int get hashCode => Object.hash(type, cidr);
}

/// Match if the connected wifi SSID equals this string.
///
/// Optional and permission-gated. iOS support requires the
/// `com.apple.developer.networking.wifi-info` entitlement plus a location
/// permission grant. Android requires `ACCESS_FINE_LOCATION`. If neither
/// is granted, the trigger silently fails to match (it does not crash).
class SsidTrigger extends NetworkTrigger {
  const SsidTrigger(this.ssid);
  final String ssid;

  @override
  String get type => 'ssid';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'ssid': ssid};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SsidTrigger && other.ssid == ssid);

  @override
  int get hashCode => Object.hash(type, ssid);
}

/// Match if the device is on cellular (no wifi, no ethernet).
class CellularTrigger extends NetworkTrigger {
  const CellularTrigger();

  @override
  String get type => 'cellular';

  @override
  Map<String, dynamic> toJson() => {'type': type};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is CellularTrigger;

  @override
  int get hashCode => type.hashCode;
}

/// Match if a specific connectivity type is active.
///
/// Slightly more general than [CellularTrigger]: lets a user write a
/// rule like "On wifi but not ethernet" by combining with other triggers.
class ConnectivityTrigger extends NetworkTrigger {
  const ConnectivityTrigger(this.kind);
  final ConnectivityKind kind;

  @override
  String get type => 'connectivity';

  @override
  Map<String, dynamic> toJson() => {'type': type, 'kind': kind.name};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectivityTrigger && other.kind == kind);

  @override
  int get hashCode => Object.hash(type, kind);
}

/// Always matches. Reserved for the Default fallback network.
///
/// Putting this trigger on a non-Default network is harmless but
/// semantically confusing - the editor blocks it.
class AlwaysTrigger extends NetworkTrigger {
  const AlwaysTrigger();

  @override
  String get type => 'always';

  @override
  Map<String, dynamic> toJson() => {'type': type};

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is AlwaysTrigger;

  @override
  int get hashCode => type.hashCode;
}

/// Sentinel used when reading a stored network whose trigger type the
/// current build doesn't recognise. Never matches.
///
/// Private - callers never construct this. It only exists so an old
/// build doesn't crash when it loads a network defined by a newer
/// version of the app.
class _UnknownTrigger extends NetworkTrigger {
  const _UnknownTrigger();

  @override
  String get type => 'unknown';

  @override
  Map<String, dynamic> toJson() => {'type': type};
}
