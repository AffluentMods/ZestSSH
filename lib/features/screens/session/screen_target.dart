// Where a remote screen's bytes go (4.0): through its carrier SSH host
// to an address and port, or to a Unix socket on that host, or, with no
// carrier, straight to the VNC server over TLS (VeNCrypt only).
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart' show ProxmoxGuest;
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/utils/host_address.dart';

sealed class ScreenTarget {
  const ScreenTarget();

  /// The target of the screen host [screen] with its [options]: through its
  /// carrier ([Connection.connectViaId]) when it has one, else direct.
  static ScreenTarget of(Connection screen, ScreenOptions options) {
    if (screen.connectViaId == null) return DirectTlsTarget(screen.host, screen.port);
    final socket = options.socket;
    if (options.target == ScreenTargetKind.unix && socket != null && socket.isNotEmpty) {
      return UnixSocketTarget(socket);
    }
    return TcpTarget(screen.host.isEmpty ? 'localhost' : screen.host, screen.port);
  }

  /// Whether the bytes go through an SSH host.
  bool get viaCarrier;

  /// What the connection log and Copy details say of it (no secret in it).
  String describe();
}

/// An address and port as the carrier sees it (SSH's direct-tcpip, `ssh -L`).
final class TcpTarget extends ScreenTarget {
  const TcpTarget(this.host, this.port);
  final String host;
  final int port;

  @override
  bool get viaCarrier => true;

  @override
  String describe() => hostWithPort(host, port);
}

/// A Unix socket on the carrier (OpenSSH's direct-streamlocal). A path that
/// starts with `~/` is in the home folder of the account the carrier signs in
/// as: read once from the carrier ([expandedWith]).
final class UnixSocketTarget extends ScreenTarget {
  const UnixSocketTarget(this.path);
  final String path;

  bool get needsHome => path == '~' || path.startsWith('~/');

  /// [path] with its leading `~` put as [home]; [path] itself where it has
  /// none, or [home] is empty.
  String expandedWith(String? home) {
    if (!needsHome || home == null || home.isEmpty) return path;
    final base = home.endsWith('/') ? home.substring(0, home.length - 1) : home;
    return path == '~' ? base : '$base${path.substring(1)}';
  }

  @override
  bool get viaCarrier => true;

  @override
  String describe() => 'unix:$path';
}

/// An X program (4.0): [program] run on the carrier, which is the SSH
/// host itself, in a private Xvnc of [width] by [height] that the host script
/// starts ([xProgramScript]); its VNC socket, in a 0700 folder, is opened
/// through the same connection once the script names it. VNC security None:
/// the socket's folder is the lock.
final class XProgramTarget extends ScreenTarget {
  XProgramTarget(this.program, this.width, this.height) {
    if (xProgramProblem(program) != null) throw ArgumentError('not a program line');
    if (width < 1 || height < 1) throw ArgumentError('no size');
  }

  /// The command line, as typed: never logged (its arguments may name
  /// anything); [name] is.
  final String program;
  final int width;
  final int height;

  /// The program's own name ([xProgramName]).
  String get name => xProgramName(program);

  @override
  bool get viaCarrier => true;

  @override
  String describe() => 'X program $name';
}

/// The VNC server itself, with no SSH host on the way: only VeNCrypt with a
/// certificate is taken ([ScreenConnectOptions.requireTls]).
final class DirectTlsTarget extends ScreenTarget {
  const DirectTlsTarget(this.host, this.port);
  final String host;
  final int port;

  @override
  bool get viaCarrier => false;

  @override
  String describe() => 'tls:${hostWithPort(host, port)}';
}

/// A Proxmox guest's console (4.0): VNC inside the Proxmox
/// API's own websocket, over HTTPS with the system's trust or the account's
/// pinned certificate (proxmox_console.dart). Not plain VNC over a network,
/// and not through an SSH host: the console is opened from the imported host
/// whose cloud link names the guest, with its account's API token.
final class ProxmoxConsoleTarget extends ScreenTarget {
  const ProxmoxConsoleTarget(this.guest);
  final ProxmoxGuest guest;

  @override
  bool get viaCarrier => false;

  @override
  String describe() => 'the Proxmox console of guest ${guest.vmid} on ${guest.node}';
}
