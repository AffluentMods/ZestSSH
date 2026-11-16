import 'dart:convert';

import 'package:crypto/crypto.dart' show sha256;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/services/local_state_store.dart';

// Where a password from the person's password manager was allowed to go
// (3.0). In an Orchard, others may change a key's reference or a
// host's address: pointed at another item of theirs, or at a server of their
// own, the person's password manager would hand over a secret for someone
// else to catch. So the first time a reference's password goes to an address
// on this device, the person says yes, having seen what their password
// manager says the item is; a changed reference, user or address asks again.
// Kept in the Orchard's own database, on this device only (never synced), as
// hashes: nothing here names an item or a host. A Tree's keys are only ever
// changed by their owner, so they are not asked about.

/// How many allowed destinations one Orchard remembers on a device, newest
/// kept.
const kMaxPasswordRefApprovals = 500;

const _key = 'orchards.password_ref_approvals';

/// One allowed use: the key, the reference, and the user, address and port
/// the password goes to.
String passwordRefUseOf({
  required String identityId,
  required PasswordRef ref,
  required String username,
  required String host,
  required int port,
}) {
  final text = [
    'zestssh-password-ref-use-v1',
    identityId,
    ref.encode(),
    username,
    host.trim().toLowerCase(),
    '$port',
  ].join('|');
  return base64Url.encode(sha256.convert(utf8.encode(text)).bytes).replaceAll('=', '');
}

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

/// Whether [use] was allowed before in the Orchard database [db].
Future<bool> passwordRefUseAllowedIn(AppDatabase db, String use) async => (await _read(LocalStateStore(db))).contains(use);

/// Remembers that the person allowed [use] in the Orchard database [db].
Future<void> rememberPasswordRefUseIn(AppDatabase db, String use) async {
  final store = LocalStateStore(db);
  final list = [
    for (final d in await _read(store))
      if (d != use) d,
    use,
  ];
  final kept = list.length > kMaxPasswordRefApprovals ? list.sublist(list.length - kMaxPasswordRefApprovals) : list;
  await store.write(_key, jsonEncode(kept));
}

/// Whether the password [ref] points at may go to [username]@[host]:[port]
/// for the key [identityId] in [db]: at once in a Tree, or in an Orchard
/// when the person allowed that use on this device before; otherwise once
/// [ask] says yes, which is then remembered.
Future<bool> allowPasswordRefUse(
  AppDatabase db, {
  required String identityId,
  required PasswordRef ref,
  required String username,
  required String host,
  required int port,
  required Future<bool> Function() ask,
}) async {
  if (!db.isOrchard) return true;
  final use = passwordRefUseOf(identityId: identityId, ref: ref, username: username, host: host, port: port);
  if (await passwordRefUseAllowedIn(db, use)) return true;
  if (!await ask()) return false;
  await rememberPasswordRefUseIn(db, use);
  return true;
}
