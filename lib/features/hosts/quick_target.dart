/// What a person types to connect to a host by its address (quick connect,
/// 3.0): `host`, `user@host`, `host:port` or `user@host:port`, with `ssh://`
/// before it or not, and an IPv6 address bare (`2001:db8::1`, port 22) or in
/// brackets (`[2001:db8::1]:2222`). One reading for every place it is typed
/// (the Quick connect dialog, the Hosts search boxes, the phone's bar),
/// where each read it its own way and an IPv6 address was cut at its first
/// colon.
library;

import 'package:zestssh/database/database.dart';

/// A host to connect to, as typed: the user, where one is typed.
class QuickTarget {
  const QuickTarget({this.user, required this.host, this.port = 22, this.portTyped = false});

  final String? user;
  final String host;
  final int port;

  /// Whether [port] was typed, not [parseQuickTarget]'s default. It is not
  /// part of what the target is: two of one user, host and port are equal.
  final bool portTyped;

  /// As it would be typed again: an IPv6 address in brackets, the port where
  /// one was typed or it is not 22. A 22 typed is kept: read again where
  /// Settings gives new connections another port, it is still 22 (it was
  /// dropped, and Quick connect reached the other port).
  String get typed {
    final address = host.contains(':') ? '[$host]' : host;
    return '${user == null ? '' : '$user@'}$address${port == 22 && !portTyped ? '' : ':$port'}';
  }

  @override
  bool operator ==(Object other) =>
      other is QuickTarget && other.user == user && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(user, host, port);

  @override
  String toString() => typed;
}

/// A name or an IPv4 address.
final _name = RegExp(r'^[a-zA-Z0-9._-]+$');

/// An IPv6 address (hex groups, `::`, an IPv4 tail).
final _ipv6 = RegExp(r'^[0-9a-fA-F:.]+$');

/// What may not be in a user.
final _notInUser = RegExp(r'[\s\x00-\x1f\x7f]');

/// [port] as typed, where it is a number from 1 to 65535.
int? _portOf(String port) {
  if (!RegExp(r'^[0-9]{1,5}$').hasMatch(port)) return null;
  final p = int.parse(port);
  return p >= 1 && p <= 65535 ? p : null;
}

/// [input] read as a host to connect to; null where it names no host, a host
/// that is no name or address, a port that is not a number from 1 to 65535,
/// or a user that is empty or holds a space or a control character. With no
/// port typed, [defaultPort]: the one Settings gives new connections, where
/// what is typed connects.
QuickTarget? parseQuickTarget(String input, {int defaultPort = 22}) {
  var s = input.trim();
  if (s.toLowerCase().startsWith('ssh://')) s = s.substring(6);
  if (s.endsWith('/')) s = s.substring(0, s.length - 1);
  String? user;
  final at = s.lastIndexOf('@');
  if (at >= 0) {
    user = s.substring(0, at);
    s = s.substring(at + 1);
    if (user.isEmpty || _notInUser.hasMatch(user)) return null;
  }
  var port = defaultPort;
  var portTyped = false;
  final String host;
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    host = s.substring(1, close);
    final rest = s.substring(close + 1);
    if (rest.isNotEmpty) {
      if (!rest.startsWith(':')) return null;
      final p = _portOf(rest.substring(1));
      if (p == null) return null;
      port = p;
      portTyped = true;
    }
    if (!host.contains(':') || !_ipv6.hasMatch(host)) return null;
  } else if (':'.allMatches(s).length > 1) {
    host = s;
    if (!_ipv6.hasMatch(host)) return null;
  } else {
    final colon = s.indexOf(':');
    host = colon < 0 ? s : s.substring(0, colon);
    if (colon >= 0) {
      final p = _portOf(s.substring(colon + 1));
      if (p == null) return null;
      port = p;
      portTyped = true;
    }
    if (!_name.hasMatch(host)) return null;
  }
  if (host.isEmpty || host.length > 253) return null;
  return QuickTarget(user: user, host: host, port: port, portTyped: portTyped);
}

/// A host for [target] that is not saved: what a session to an address
/// typed is opened with. Its id starts with `quick_`, which is how the rest
/// of the app knows it is not saved; it is named as typed.
Connection quickConnectionOf(QuickTarget target, {DateTime? now}) {
  final at = now ?? DateTime.now();
  final address = target.host.contains(':') ? '[${target.host}]' : target.host;
  return Connection(
    id: 'quick_${at.microsecondsSinceEpoch}',
    label: target.user == null ? address : '${target.user}@$address',
    host: target.host,
    port: target.port,
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: at,
    updatedAt: at,
  );
}
