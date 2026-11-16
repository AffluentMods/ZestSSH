// Remote screens (4.0): the RD Gateway an RDP session goes
// through, as the session is given it.
import 'package:zestssh/utils/host_address.dart';

/// The gateway's address and port, and its sign-in: the PC's own
/// ([sameSignIn], the account the session signs in to the PC with, asked for
/// with it where it is not saved) or a key of its own (its account here).
class ScreenGatewayRoute {
  const ScreenGatewayRoute({
    required this.host,
    this.port = 443,
    this.sameSignIn = true,
    this.username,
    this.password,
    this.domain,
  });

  final String host;
  final int port;
  final bool sameSignIn;

  /// The key's account, where [sameSignIn] is false.
  final String? username;
  final String? password;
  final String? domain;

  /// What the connection log says of it (no account, no password).
  String describe() => port == 443 ? bracketIpv6(host) : hostWithPort(host, port);

  @override
  String toString() => 'ScreenGatewayRoute(${describe()}, ${sameSignIn ? 'the PC\'s sign-in' : 'a key of its own'})';
}
