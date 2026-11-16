/// Paste a list (3.0, the import cleanup): hosts typed or
/// copied one per line, for an app that has no export (JuiceSSH and the
/// like).
library;

/// One host read from a pasted line.
class PastedHost {
  const PastedHost({this.user, required this.host, required this.port, required this.line});

  /// Everything before the last `@`, where there is one.
  final String? user;
  final String host;

  /// 22 where the line names none.
  final int port;

  /// Its line in what was pasted, from 1.
  final int line;
}

/// A line that is no host, with its line number from 1.
class PasteError {
  const PasteError({required this.line, required this.text});

  final int line;
  final String text;
}

/// The hosts of [input], one per line: `host`, `user@host`, `host:port`,
/// `user@host:port`, an IPv6 address in brackets with or without a port
/// (`[2001:db8::1]:2222`), or a bare IPv6 address (no port). Blank lines and
/// lines starting with `#` are left out; any other line that is none of these
/// is an error, with its line number.
({List<PastedHost> hosts, List<PasteError> errors}) parsePasteList(String input) {
  final hosts = <PastedHost>[];
  final errors = <PasteError>[];
  final lines = input.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final text = lines[i].trim();
    if (text.isEmpty || text.startsWith('#')) continue;
    final parsed = _parseLine(text, i + 1);
    if (parsed == null) {
      errors.add(PasteError(line: i + 1, text: text));
    } else {
      hosts.add(parsed);
    }
  }
  return (hosts: hosts, errors: errors);
}

PastedHost? _parseLine(String text, int line) {
  // No spaces inside a host line.
  if (RegExp(r'\s').hasMatch(text)) return null;
  String? user;
  var rest = text;
  final at = text.lastIndexOf('@');
  if (at >= 0) {
    user = text.substring(0, at);
    rest = text.substring(at + 1);
    if (!_looksLikeUser(user)) return null;
  }
  if (rest.isEmpty) return null;

  String host;
  var port = 22;
  if (rest.startsWith('[')) {
    // [ipv6] or [ipv6]:port
    final close = rest.indexOf(']');
    if (close < 0) return null;
    host = rest.substring(1, close);
    final after = rest.substring(close + 1);
    if (after.isNotEmpty) {
      if (!after.startsWith(':')) return null;
      final p = _port(after.substring(1));
      if (p == null) return null;
      port = p;
    }
    if (!host.contains(':')) return null;
  } else {
    final colons = ':'.allMatches(rest).length;
    if (colons == 1) {
      final i = rest.indexOf(':');
      host = rest.substring(0, i);
      final p = _port(rest.substring(i + 1));
      if (p == null) return null;
      port = p;
    } else {
      // No port, or a bare IPv6 address (which takes none).
      host = rest;
    }
  }
  if (host.isEmpty || !_looksLikeHost(host)) return null;
  return PastedHost(user: user, host: host, port: port, line: line);
}

/// A user name as SSH takes one: not empty, no colon (it would read as a
/// port or a password), no control or direction character, and never a
/// leading dash (it would read as an option wherever it is passed later).
/// An `@` is fine: a domain account is `name@domain`.
bool _looksLikeUser(String user) =>
    user.isNotEmpty &&
    user.length <= 255 &&
    !user.startsWith('-') &&
    !user.contains(':') &&
    !RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]').hasMatch(user);

int? _port(String s) {
  if (!RegExp(r'^\d{1,5}$').hasMatch(s)) return null;
  final p = int.parse(s);
  return p >= 1 && p <= 65535 ? p : null;
}

/// A name, an IPv4 address or an IPv6 address: letters, digits, dots,
/// dashes, underscores, and colons only in an IPv6 address.
bool _looksLikeHost(String host) {
  if (host.length > 253) return false;
  if (host.contains(':')) {
    return RegExp(r'^[0-9A-Fa-f:.]+(%[A-Za-z0-9]+)?$').hasMatch(host) && ':'.allMatches(host).length >= 2;
  }
  // Never a leading dash: a name that reads as an option (-oProxyCommand)
  // is no host, wherever it is passed later.
  return RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(host) &&
      !host.startsWith('.') &&
      !host.startsWith('-') &&
      !host.endsWith('.');
}
