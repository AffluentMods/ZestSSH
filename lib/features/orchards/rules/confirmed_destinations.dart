import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/host_address.dart';

// Where a password from a Crate that asks again was confirmed to go (3.0).
// Asking is about one danger: a member who may change a host
// pointing it at a server of their own to catch the password there. Once
// the person confirmed it is them for a key's password going to a host's
// address, the same key to the same address is not asked about again on
// this device; a new address is. Kept in the Orchard's own database, on
// this device only (never synced), as hashes: nothing here names a host.

/// How many destinations one Orchard remembers on a device, newest kept.
const kMaxConfirmedDestinations = 500;

const _key = 'orchards.confirmed_destinations';

/// The destination a key's password goes to: the key, and the host's
/// address and port as the connection reaches them. [via] is the route to
/// that address where it is only an address as another host sees it: a
/// remote screen's carrier (its screenViaScope, `bastion:22`), so the same
/// `localhost:5900` through another SSH host is a new destination (found in a
/// security review). Without it, the destination is what it was.
String destinationOf({required String identityId, required String host, required int port, String? via}) {
  final text = [
    'zestssh-confirmed-destination-v1',
    identityId,
    host.trim().toLowerCase(),
    '$port',
    if (via != null) 'via=${via.trim().toLowerCase()}',
  ].join('|');
  return base64Url.encode(sha256.convert(utf8.encode(text)).bytes).replaceAll('=', '');
}

/// The destinations confirmed in [store], oldest first.
Future<List<String>> _read(LocalStateStore store) async {
  try {
    final raw = await store.read(_key);
    final list = raw == null ? null : jsonDecode(raw);
    return [
      if (list is List)
        for (final d in list)
          if (d is String) d,
    ];
  } catch (_) {
    return const [];
  }
}

/// Whether [destination] was confirmed before in the Orchard database [db].
Future<bool> destinationConfirmedIn(AppDatabase db, String destination) async =>
    (await _read(LocalStateStore(db))).contains(destination);

/// Remembers that the person confirmed [destination] in the Orchard database [db].
Future<void> rememberDestinationIn(AppDatabase db, String destination) async {
  final store = LocalStateStore(db);
  final list = [
    for (final d in await _read(store))
      if (d != destination) d,
    destination,
  ];
  final kept = list.length > kMaxConfirmedDestinations ? list.sublist(list.length - kMaxConfirmedDestinations) : list;
  await store.write(_key, jsonEncode(kept));
}

/// Whether the password of the key [identityId] may go to [host]:[port]
/// from the Orchard database [db], for a key whose Crate asks again:
/// at once when the person confirmed that destination on this device
/// before; otherwise once [ask] (given "host:port", or "carrier → host:port"
/// with [via]) says they confirmed it, which is then remembered. False when
/// they do not.
Future<bool> confirmPasswordDestination(
  AppDatabase db, {
  required String identityId,
  required String host,
  required int port,
  String? via,
  required Future<bool> Function(String destination) ask,
}) async {
  final destination = destinationOf(identityId: identityId, host: host, port: port, via: via);
  if (await destinationConfirmedIn(db, destination)) return true;
  if (!await ask(via == null ? hostWithPort(host, port) : '$via \u2192 ${hostWithPort(host, port)}')) return false;
  await rememberDestinationIn(db, destination);
  return true;
}
