// Remote screens (4.0): whether this build offers RDP hosts
// reached through an RD Gateway.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/config/official_identity.dart' show kZestOfficialBuild;

/// Whether every build offers the gateway, official ones included. To take it out of a release
/// again, this is the one line to change: false.
const bool kRdpGatewayShipped = true;

/// A development build made to try the gateway while [kRdpGatewayShipped] is false:
/// `--dart-define=ZEST_RDP_GATEWAY=true`. An official build (ZEST_OFFICIAL) never takes it, whatever
/// its `.env` says.
const bool kRdpGatewayTryBuild = bool.fromEnvironment('ZEST_RDP_GATEWAY');

/// Whether this build offers the gateway. Where it does not, the host's editor offers none, and a
/// host whose settings name one (from a newer version, a sync, a team) is refused with ZS-1827,
/// never opened without its gateway.
final rdpGatewayOfferedProvider = Provider<bool>((ref) => rdpGatewayOffered(
      shipped: kRdpGatewayShipped,
      tryBuild: kRdpGatewayTryBuild,
      official: kZestOfficialBuild,
    ));

/// The rule, apart so a test can hold it: shipped, or a try build that is not an official one.
bool rdpGatewayOffered({required bool shipped, required bool tryBuild, required bool official}) =>
    shipped || (tryBuild && !official);
