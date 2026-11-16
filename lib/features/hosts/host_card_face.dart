import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/l10n/l10n_global.dart';

// What a host's card shows of it, worked out in one place: the Hosts page's
// grid and the host editor's preview draw the same card from the same
// things (the editor once showed a terminal glyph for
// a host whose icon field said "Auto · Ubuntu").

/// The icon of the operating system seen on a host ([OsKind]), as the icon
/// set names it; null where the set has none for it.
String? osCatalogIdFor(OsKind kind) {
  return switch (kind) {
    OsKind.ubuntu => 'ubuntu',
    OsKind.debian => 'debian',
    OsKind.fedora => 'fedora',
    OsKind.centos => 'centos',
    OsKind.rhel => 'rhel',
    OsKind.arch => 'arch',
    OsKind.alpine => 'alpine',
    OsKind.nixos => 'nixos',
    OsKind.opensuse => 'opensuse',
    OsKind.gentoo => 'gentoo',
    OsKind.mint => 'mint',
    OsKind.pop => 'pop',
    OsKind.manjaro => 'manjaro',
    OsKind.kali => 'kali',
    OsKind.raspbian => 'raspberry_pi',
    OsKind.rocky => 'rocky',
    OsKind.alma => 'alma',
    OsKind.void_ => 'void',
    OsKind.slackware => null,
    // Appliances and router firmware have no brand mark in the set, but the
    // line icons say what they are.
    OsKind.freebsd => 'freebsd',
    OsKind.openbsd => 'openbsd',
    OsKind.netbsd => 'netbsd',
    OsKind.macos => 'macos',
    OsKind.windows => 'windows',
    OsKind.synology => 'nas',
    OsKind.unraid => 'unraid',
    OsKind.truenas => 'truenas',
    OsKind.openwrt => 'router',
    OsKind.ddwrt => 'router',
    OsKind.linux => 'unknown',
    OsKind.unknown => null,
  };
}

/// Display suffix for a connection's protocol, or `null` for SSH (the default,
/// which is NEVER shown on a card). Non-SSH transports surface a short label
/// after the `user@host` line, e.g. "root@host · Mosh".
String? hostProtocolSuffix(String protocol) {
  switch (protocol.toLowerCase()) {
    case 'ssh':
      return null;
    case 'sftp':
      // Files only: what such a session says where a terminal says its shell.
      return 'SFTP';
    case 'mosh':
      return 'Mosh';
    case 'et':
      return 'ET';
    case 'telnet':
      return 'Telnet';
    case 'localshell':
    case 'local':
      return gl10n.connectionEditProtocolLocalShort;
    case 'serial':
      return gl10n.connectionEditProtocolSerialShort;
    default:
      return protocol.toUpperCase();
  }
}

/// The line under a host's name on its card: `user@host`, and the protocol
/// after it where it is not SSH.
String hostCardSubtitle(String user, String host, String protocol) {
  final suffix = hostProtocolSuffix(protocol);
  return suffix == null ? '$user@$host' : '$user@$host · $suffix';
}

/// The line under a remote screen's name (4.0): where its server listens,
/// and the SSH host it is reached through, said with [via] ("localhost:5900
/// via web-01"). A screen is signed in to by no user of its own, so the
/// `user@host` of the other kinds said a "root" that is nowhere ("root@localhost
/// · VNC" before). [carrier] is the
/// name of that SSH host, null for a screen reached directly; [socket] the
/// Unix socket on it, where the screen is one.
String screenCardSubtitle({
  required String host,
  required int port,
  String? socket,
  String? carrier,
  required String Function(String carrier) via,
}) {
  final address = carrier != null && socket != null && socket.isNotEmpty
      ? socket
      : hostWithPort(host.isEmpty ? 'localhost' : host, port);
  return carrier == null || carrier.isEmpty ? address : '$address ${via(carrier)}';
}

/// [screenCardSubtitle] of the saved screen host [screen]; [labelOf] gives the
/// name of a host by its id (null where it is not on this device). An RDP host
/// (4.0) says its kind after it ("10.0.0.40:3389 · RDP",
/// "localhost:3389 via web-01 · RDP"): both kinds of screen draw the same
/// monitor, and a VNC host's line stays as it was. It has no socket, whatever
/// its options hold.
String screenCardSubtitleOf(
  Connection screen, {
  required String? Function(String id) labelOf,
  required String Function(String carrier) via,
}) {
  final viaId = screen.connectViaId;
  final options = ScreenOptions.decode(screen.screenOptions);
  final rdp = screen.protocol == ConnectionProtocol.rdp.name;
  final line = screenCardSubtitle(
    host: screen.host,
    port: screen.port,
    socket: !rdp && options.target == ScreenTargetKind.unix ? options.socket : null,
    carrier: viaId == null ? null : labelOf(viaId),
    via: via,
  );
  // Its kind as every card says a kind ([hostProtocolSuffix]).
  return rdp ? '$line \u00b7 ${hostProtocolSuffix(screen.protocol)}' : line;
}

/// Whether the icon of a system seen on a host is a real one: the set's
/// "unknown" stands in for a Linux whose kind was not told.
bool adoptableOsIcon(String? catalogId) => catalogId != null && catalogId != 'unknown';

/// The icons of the systems seen on hosts, to keep on the hosts themselves
/// (3.2): what a device sees on a host was its
/// own, so a phone that had not connected to a host drew a letter where the
/// computer drew the system's icon. Written into a host's icon, which syncs,
/// only where it has none of its own (picked or uploaded) and the icon is a
/// real one; by host id.
Map<String, String> detectedIconsToKeep(Iterable<Connection> hosts, Map<String, OsKind> seen) {
  final keep = <String, String>{};
  for (final host in hosts) {
    if ((host.iconId?.isNotEmpty ?? false) || (host.customIcon?.isNotEmpty ?? false)) continue;
    final kind = seen[host.id];
    final icon = kind == null ? null : osCatalogIdFor(kind);
    if (adoptableOsIcon(icon)) keep[host.id] = icon!;
  }
  return keep;
}
