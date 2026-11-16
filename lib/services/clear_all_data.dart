import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/identity_secret_store.dart';

/// Settings > Data > Clear all data, once "DELETE" was typed: this device's
/// data, and only this device's.
///
/// With sync set up here, [turnSyncOff] turns it off on this device first
/// (disconnectSyncOnThisDevice): what is cleared would otherwise come back at
/// the next sync from the person's other devices, and the deletes went nowhere
/// else either (found in a data review). Sending them as deletes
/// would clear every device of the account; this keeps everything on the
/// others and in the synced data, and the dialog says so. Turned off first, so
/// no sync starts on what is being cleared and sends an empty copy up.
///
/// Then every team's copy on this device ([forgetOrchards]; the teams stay in
/// their Crates), and your Tree's hosts, keys with what the system's secure
/// storage holds of them (private keys, passwords, passphrases, certificates:
/// they stayed there, though the dialog says they are deleted for good),
/// snippets and known hosts.
Future<void> clearAllDataOnThisDevice({
  required AppDatabase tree,
  required FlutterSecureStorage secureStorage,
  required Future<void> Function() forgetOrchards,
  Future<void> Function()? turnSyncOff,
}) async {
  if (turnSyncOff != null) await turnSyncOff();
  await forgetOrchards();
  final secrets = SecureStorageIdentitySecrets(secureStorage, sealedBy: tree);
  for (final identity in await tree.identitiesDao.getAll()) {
    await secrets.deleteAll(identity.id);
  }
  await tree.connectionsDao.deleteAll();
  await tree.identitiesDao.deleteAll();
  await tree.snippetsDao.deleteAll();
  await tree.knownHostsDao.deleteAll();
}
