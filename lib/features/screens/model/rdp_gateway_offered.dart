// Remote screens (4.0): whether this build offers RDP hosts
// reached through an RD Gateway.
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A build made to try the gateway in the app: `--dart-define=ZEST_RDP_GATEWAY=true`.
/// No release is built with it.
const bool kRdpGatewayTryBuild = bool.fromEnvironment('ZEST_RDP_GATEWAY');

/// Off until the gateway has been seen working end to end in the app
/// against a real gateway,
/// except in a build made to try it ([kRdpGatewayTryBuild]). Off, the host's
/// editor offers no gateway, and a host whose settings name one (from a
/// newer version, a sync, a team) is refused with ZS-1827, never opened
/// without its gateway.
final rdpGatewayOfferedProvider = Provider<bool>((ref) => kRdpGatewayTryBuild);
