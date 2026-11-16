/// An address with its port, the way URLs and OpenSSH write one (3.0, 17
/// October 2026): an IPv6 address between brackets, so that its own colons
/// are not read as the port's ("[2001:db8::1]:22"); and back to a host to
/// connect to, which takes no brackets.
library;

/// Whether [host] is an IPv6 address written bare: more than one colon, and
/// no brackets around it.
bool isBareIpv6(String host) => ':'.allMatches(host).length > 1 && !host.startsWith('[');

/// [host] between brackets when it is an IPv6 address written bare, as it is
/// written before a port or in a URL; anything else as it is.
String bracketIpv6(String host) => isBareIpv6(host) ? '[$host]' : host;

/// [host] without the brackets an IPv6 address may be written in: what a
/// connection is made to (a name between brackets is looked up as it is, and
/// found nowhere).
String unbracketHost(String host) {
  final h = host.trim();
  return h.length > 2 && h.startsWith('[') && h.endsWith(']') ? h.substring(1, h.length - 1) : h;
}

/// [host] and [port] as one, as a person reads them and a URL takes them.
String hostWithPort(String host, int port) => '${bracketIpv6(host)}:$port';

/// The host of [text] and the port written after it, if one is: "host",
/// "host:port", "[2001:db8::1]", "[2001:db8::1]:port", or an IPv6 address
/// written bare, whose last group is never taken for a port. The host comes
/// back without brackets. Null where a port is written but is no port
/// (1 to 65535), or the brackets do not close.
({String host, int? port})? splitHostPort(String text) {
  final s = text.trim();
  if (s.startsWith('[')) {
    final close = s.indexOf(']');
    if (close < 0) return null;
    final host = s.substring(1, close);
    final rest = s.substring(close + 1);
    if (rest.isEmpty) return (host: host, port: null);
    if (!rest.startsWith(':')) return null;
    final port = int.tryParse(rest.substring(1));
    if (port == null || port < 1 || port > 65535) return null;
    return (host: host, port: port);
  }
  if (isBareIpv6(s)) return (host: s, port: null);
  final colon = s.indexOf(':');
  if (colon < 0) return (host: s, port: null);
  final port = int.tryParse(s.substring(colon + 1));
  if (port == null || port < 1 || port > 65535) return null;
  return (host: s.substring(0, colon), port: port);
}
