/// Cloud import (3.0): the machines a cloud or infrastructure account lists,
/// read straight from that provider's API on this device. Nothing here talks
/// to ZestSSH servers.
library;

import 'dart:io' show InternetAddress, InternetAddressType;

import 'package:zestssh/utils/type_name.dart';

/// Where machines are imported from.
enum CloudProvider { aws, digitalocean, hetzner, azure, tailscale, proxmox }

/// The kind of system a machine runs, as far as the provider says.
enum CloudOs { linux, windows, macos, mobile, other, unknown }

/// One machine a provider lists. Every text field has been cleaned (see
/// [cleanCloudText]) and every address checked ([cloudAddressOrNull]):
/// names, tags and addresses come from outside and end up in host names and
/// in `ssh` command lines.
class CloudMachine {
  const CloudMachine({
    required this.provider,
    required this.id,
    required this.name,
    this.publicAddress,
    this.privateAddress,
    this.where = '',
    this.tags = const [],
    this.os = CloudOs.unknown,
    this.running = true,
    this.user,
    this.kind,
    this.formerId,
  });

  final CloudProvider provider;

  /// The provider's own id for the machine (an EC2 instance id, a droplet
  /// id, an Azure resource id, a Tailscale node id; on Proxmox
  /// `host:port/node/vmid`, since guest ids repeat across clusters, and on
  /// Headscale `host:port/id`, since every server numbers its nodes from 1).
  /// Unique across accounts. A host imported from it keeps it, so a later
  /// check finds the same host.
  final String id;

  /// The id earlier versions kept for this machine, where it was not unique
  /// across accounts (a Headscale node's bare number), or null. A host linked
  /// by it is the same machine only for the account it was imported from.
  final String? formerId;

  final String name;

  /// An address reachable from the internet (on Tailscale: the tailnet
  /// address), or null.
  final String? publicAddress;

  /// An address inside the provider's private network, or null.
  final String? privateAddress;

  /// Region, location, node: where the provider runs it.
  final String where;

  /// The provider's tags or labels, as `key:value` where they have a value.
  final List<String> tags;

  final CloudOs os;

  /// False when the provider says it is stopped or off.
  final bool running;

  /// The sign-in name the provider states (Azure's admin user) or the one
  /// its images use (root on DigitalOcean and Hetzner), or null.
  final String? user;

  /// What sort of machine on providers with several (Proxmox: `qemu`, `lxc`,
  /// `node`).
  final String? kind;

  /// Whether this is likely to accept SSH: phones and tablets never do, and
  /// Windows seldom runs an SSH server, so both start unticked.
  bool get likelySsh => os != CloudOs.mobile && os != CloudOs.windows;

  /// The address to connect to: the private one when [preferPrivate] and
  /// there is one, else the public one, else whichever exists.
  String? addressFor({required bool preferPrivate}) =>
      preferPrivate ? (privateAddress ?? publicAddress) : (publicAddress ?? privateAddress);
}

/// Something about a provider's answer that is not what its API documents.
class CloudFormatException implements Exception, HasTypeName {
  CloudFormatException(this.what);
  final String what;
  @override
  String toString() => 'Unexpected answer: $what';

  @override
  String get typeName => 'CloudFormatException';
}

// Controls, zero-width marks and bidirectional overrides: text that would
// hide or reorder what is shown next to it.
final _unsafeChars = RegExp(r'[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]');

/// What a pattern's `\s` matches: the white space a run of is made one space.
final _space = RegExp(r'\s');

/// [raw] as safe display text: control and direction characters removed,
/// runs of spaces made one, at most [max] characters.
///
/// One pass, a character at a time, stopping at [max]: a pattern of `\s+` over
/// some millions of spaces (a hostile file's line) ran out of room to go back
/// over in Dart 3.14 ("Stack Overflow"), and the text past [max] is never shown.
String cleanCloudText(Object? raw, {int max = 80}) {
  if (raw == null) return '';
  final out = StringBuffer();
  var kept = 0;
  var gap = false;
  for (final rune in raw.toString().runes) {
    final c = String.fromCharCode(rune);
    if (_unsafeChars.hasMatch(c) || _space.hasMatch(c)) {
      gap = true;
      continue;
    }
    if (kept == max) break;
    if (gap && kept > 0) {
      out.write(' ');
      kept++;
      if (kept == max) break;
    }
    gap = false;
    out.writeCharCode(rune);
    kept++;
  }
  return out.toString().trimRight();
}

/// A provider's tags as a short clean list: `key:value`, or `key` alone when
/// the value is empty; at most [max] of them, duplicates dropped.
List<String> cleanCloudTags(Iterable<Object?> raw, {int max = 12}) {
  final out = <String>[];
  for (final t in raw) {
    final s = cleanCloudText(t, max: 48);
    if (s.isEmpty || out.contains(s)) continue;
    out.add(s);
    if (out.length == max) break;
  }
  return out;
}

/// [tags] (a key-value map) as `key:value` strings.
List<String> cloudTagsOfMap(Object? tags, {Set<String> skipKeys = const {}}) {
  if (tags is! Map) return const [];
  return cleanCloudTags([
    for (final e in tags.entries)
      if (!skipKeys.contains(e.key.toString()))
        (e.value == null || e.value.toString().isEmpty) ? e.key : '${e.key}:${e.value}',
  ]);
}

final _hostname = RegExp(r'^(?=.{1,253}$)[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?(?:\.[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*\.?$');

/// [raw] when it is an IP address or a host name and nothing else (no
/// spaces, no `user@`, no leading dash that `ssh` would read as an option),
/// else null. Loopback, link-local and unspecified addresses are no use from
/// here, so they are null too.
String? cloudAddressOrNull(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  if (s.isEmpty || s.length > 253) return null;
  final ip = InternetAddress.tryParse(s);
  if (ip != null) {
    if (ip.isLoopback || ip.isLinkLocal) return null;
    if (ip.type == InternetAddressType.IPv4 && s == '0.0.0.0') return null;
    if (ip.type == InternetAddressType.IPv6 && ip.rawAddress.every((b) => b == 0)) return null;
    return ip.address;
  }
  if (s.contains(':')) return null;
  return _hostname.hasMatch(s) ? s : null;
}

/// [raw] when it is an IP address (as [cloudAddressOrNull] allows), never a
/// name: what providers report as an address field.
String? cloudIpOrNull(Object? raw) {
  final a = cloudAddressOrNull(raw);
  return a != null && InternetAddress.tryParse(a) != null ? a : null;
}

final _user = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$');

/// [raw] when it is a plain sign-in name (letters, digits, `_ . -`, not
/// starting with a dash), else null.
String? cloudUserOrNull(Object? raw) {
  if (raw is! String) return null;
  final s = raw.trim();
  return _user.hasMatch(s) ? s : null;
}
