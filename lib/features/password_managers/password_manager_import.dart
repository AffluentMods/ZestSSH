import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/utils/host_address.dart';

// Adding keys and hosts from the person's password manager (3.0):
// each item picked becomes a key that keeps only a reference to it (no
// password is copied into ZestSSH), and one whose address is an SSH one
// also becomes a host that uses that key.

/// Host names as the app takes them: letters, digits, dots and dashes, or an
/// IPv6 address in brackets; not starting with a dash.
final RegExp _hostName = RegExp(r'^(?:[A-Za-z0-9](?:[A-Za-z0-9.-]{0,252})|\[[0-9A-Fa-f:.]{2,45}\])$');
final RegExp _userName = RegExp(r'^[A-Za-z0-9._][A-Za-z0-9._-]{0,63}$');

/// The SSH host an item's [address] names: `ssh://[user@]host[:port]`,
/// `user@host[:port]` or `host[:port]`; null for a web address, or
/// anything that does not read as a host.
({String host, int port, String? user})? sshTargetOf(String? address) {
  var a = address?.trim();
  if (a == null || a.isEmpty || a.length > 300) return null;
  final scheme = RegExp(r'^([A-Za-z][A-Za-z0-9+.-]*)://').firstMatch(a);
  if (scheme != null) {
    if (scheme.group(1)!.toLowerCase() != 'ssh') return null;
    a = a.substring(scheme.end);
  }
  // No path, query or fragment after the host.
  final end = a.indexOf(RegExp(r'[/?#]'));
  if (end >= 0) {
    if (end != a.length - 1 || a[end] != '/') return null;
    a = a.substring(0, end);
  }
  String? user;
  final at = a.lastIndexOf('@');
  if (at >= 0) {
    user = a.substring(0, at);
    a = a.substring(at + 1);
    if (!_userName.hasMatch(user)) return null;
  }
  var port = 22;
  String host = a;
  final bracket = a.startsWith('[') ? a.indexOf(']') : -1;
  final colon = bracket >= 0 ? a.indexOf(':', bracket) : a.lastIndexOf(':');
  if (colon >= 0 && (bracket >= 0 || a.indexOf(':') == colon)) {
    final p = int.tryParse(a.substring(colon + 1));
    if (p == null || p < 1 || p > 65535) return null;
    port = p;
    host = a.substring(0, colon);
  }
  if (!_hostName.hasMatch(host) || !host.contains(RegExp(r'[A-Za-z0-9]'))) return null;
  // A bare word with no dot is not taken as a host, unless it came with a
  // user or a port or as ssh:// (it would be a name, not an address).
  if (scheme == null && user == null && colon < 0 && !host.contains('.') && !host.startsWith('[')) return null;
  // The host to connect to: an IPv6 one without its brackets (with them,
  // the host made could not be connected to).
  return (host: unbracketHost(host), port: port, user: user);
}

/// What adding items made.
class PasswordManagerImport {
  const PasswordManagerImport({required this.keys, required this.hosts});

  final int keys;
  final int hosts;
}

/// Adds [items]: a key each, keeping only its reference, named as the item
/// and signing in as the item's user name (or the address's, or
/// [fallbackUser]); and a host for each whose address names an SSH one.
Future<PasswordManagerImport> addFromPasswordManager(
  List<PasswordManagerItem> items, {
  required Future<String> Function({required String label, required String username, required String passwordRef})
      createKey,
  required Future<String> Function({required String label, required String host, required int port, required String keyId})
      createHost,
  required String fallbackUser,
}) async {
  var keys = 0;
  var hosts = 0;
  for (final item in items) {
    final target = sshTargetOf(item.url);
    final user = [target?.user, item.username, fallbackUser]
        .whereType<String>()
        .map((u) => u.trim())
        .firstWhere((u) => u.isNotEmpty && u.length <= 255, orElse: () => 'root');
    final label = item.title.trim().isEmpty ? item.ref.target : item.title.trim();
    final keyId = await createKey(
        label: label.length > 255 ? label.substring(0, 255) : label, username: user, passwordRef: item.ref.encode());
    keys++;
    if (target != null) {
      await createHost(label: label, host: target.host, port: target.port, keyId: keyId);
      hosts++;
    }
  }
  return PasswordManagerImport(keys: keys, hosts: hosts);
}
