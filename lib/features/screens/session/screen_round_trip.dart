// Remote screens (4.0): the round trip time in a session's details.
// Neither engine measures one. A screen that goes through an SSH connection
// to the computer it is on has that connection's own: a keep-alive question,
// timed (ServerStatsService.roundTripMs), which costs the screen's stream
// nothing. A screen reached directly has none, and a screen on another
// computer behind its SSH host has none either: the time to the SSH host
// would be shown as the time to the screen, and it is not.
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/services/server_stats_service.dart';

/// Whether [target] is on the SSH host that carries it: a socket or a program
/// there, or a port of the host's own (its loopback address).
bool screenIsOnItsCarrier(ScreenTarget target) => switch (target) {
      UnixSocketTarget() || XProgramTarget() => true,
      TcpTarget(:final host) => isLoopbackHost(host),
      // (A console has no SSH connection to ask.)
      DirectTlsTarget() || ProxmoxConsoleTarget() => false,
    };

/// Whether [host] names the computer itself: localhost, or an address of the
/// loopback networks (127.0.0.0/8, ::1), with or without brackets.
bool isLoopbackHost(String host) {
  var h = host.trim().toLowerCase();
  if (h.startsWith('[') && h.endsWith(']')) h = h.substring(1, h.length - 1);
  if (h == 'localhost' || h == '::1' || h == '0:0:0:0:0:0:0:1') return true;
  final parts = h.split('.');
  if (parts.length != 4 || parts.first != '127') return false;
  return parts.every((p) {
    final n = p.length <= 3 ? int.tryParse(p) : null;
    return n != null && n >= 0 && n <= 255;
  });
}

/// What measures the round trip to the computer [shell]'s screen is on, in
/// milliseconds (null where no answer came in time); null where nothing can
/// measure it (see the top of this file).
Future<int?> Function()? screenRoundTripOf(ScreenShellService shell) {
  final carrier = shell.carrier;
  if (carrier == null || !screenIsOnItsCarrier(shell.target)) return null;
  return () async {
    try {
      // (A carrier that is gone has no client to ask: no time, not an error.)
      return await ServerStatsService.roundTripMs(carrier.client);
    } catch (_) {
      return null;
    }
  };
}
