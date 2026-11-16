import 'package:drift/drift.dart' show Variable;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/services/secret_seal.dart';

/// The secrets an SSH identity can hold.
enum IdentitySecret {
  password('identity_password_', 'password'),
  privateKey('identity_key_', 'private_key'),
  passphrase('identity_passphrase_', 'passphrase'),
  certificate('identity_cert_', 'certificate');

  const IdentitySecret(this.storagePrefix, this.column);

  /// The OS secure storage key prefix, for your Tree's identities.
  final String storagePrefix;

  /// The `orchard_secrets` column, for an Orchard's identities.
  final String column;
}

/// Where an identity's secrets live (3.0).
///
/// Your Tree's identities keep them in the OS secure storage, as always. An
/// Orchard's identities keep them in the Orchard's own encrypted database
/// (`orchard_secrets`), so they sync with the Orchard's Crates as part of
/// the key, leave the device with the Orchard, and are never mistaken for
/// leftovers by the Tree's clean-up of secrets whose identity is gone.
abstract class IdentitySecretStore {
  /// The store for identities in [db].
  factory IdentitySecretStore.forDatabase(AppDatabase db, FlutterSecureStorage storage) =>
      db.isOrchard ? OrchardIdentitySecrets(db) : SecureStorageIdentitySecrets(storage, sealedBy: db);

  Future<String?> read(String identityId, IdentitySecret secret);

  /// Stores [value]; null removes it.
  Future<void> write(String identityId, IdentitySecret secret, String? value);

  /// Removes every secret of the identity.
  Future<void> deleteAll(String identityId);
}

/// Your Tree's identities: the OS secure storage, under
/// `identity_password_{id}`, `identity_key_{id}`, `identity_passphrase_{id}`
/// and `identity_cert_{id}`; sealed with [sealedBy]'s seal while the
/// encrypting lock is on ([SecretSeal]).
class SecureStorageIdentitySecrets implements IdentitySecretStore {
  const SecureStorageIdentitySecrets(this._storage, {this.sealedBy});

  final FlutterSecureStorage _storage;

  /// Your Tree's database, whose seal keeps these secrets while the
  /// encrypting lock is on. None in a test that keeps them as they are.
  final AppDatabase? sealedBy;

  static String keyFor(IdentitySecret secret, String identityId) =>
      '${secret.storagePrefix}$identityId';

  @override
  Future<String?> read(String identityId, IdentitySecret secret) async {
    final slot = keyFor(secret, identityId);
    return openKept(sealedBy, slot, await _storage.read(key: slot));
  }

  /// Whether [secret] of [identityId] is kept here, sealed, and does not open
  /// (its seal is another database's, or damaged). [read] answers none for
  /// it, as for a secret the key never had: whoever would send that answer on
  /// as the truth asks this first (found in a security audit).
  Future<bool> keptButUnread(String identityId, IdentitySecret secret) async {
    final slot = keyFor(secret, identityId);
    final stored = await _storage.read(key: slot);
    return SecretSeal.isSealed(stored) && await openKept(sealedBy, slot, stored) == null;
  }

  @override
  Future<void> write(String identityId, IdentitySecret secret, String? value) async {
    final slot = keyFor(secret, identityId);
    if (value == null) return _storage.delete(key: slot);
    await _storage.write(key: slot, value: await keepSealed(sealedBy, slot, value));
  }

  @override
  Future<void> deleteAll(String identityId) async {
    for (final secret in IdentitySecret.values) {
      await _storage.delete(key: keyFor(secret, identityId));
    }
  }
}

/// An Orchard's identities: its own database's `orchard_secrets` table.
/// Writes go through the Orchard's outbox like any change to the key.
class OrchardIdentitySecrets implements IdentitySecretStore {
  OrchardIdentitySecrets(this._db);

  final AppDatabase _db;

  @override
  Future<String?> read(String identityId, IdentitySecret secret) async {
    // A Crate that its own offline limit has closed on this device hands
    // out none of its secrets, to whoever asks (crate_offline.dart): this
    // is the one place every one of them is read. Thrown, never null: "no
    // secret" is an answer that could be saved or sent on as the truth. A
    // certificate is no secret, and of no use without the key it is for.
    if (secret != IdentitySecret.certificate) {
      final closed = await itemClosedIn(_db, 'key', identityId);
      if (closed != null) throw closed;
    }
    final row = await _db.customSelect(
      'SELECT "${secret.column}" AS v FROM orchard_secrets WHERE identity_id = ?',
      variables: [Variable(identityId)],
      readsFrom: {_db.orchardSecrets},
    ).getSingleOrNull();
    return row?.read<String?>('v');
  }

  @override
  Future<void> write(String identityId, IdentitySecret secret, String? value) =>
      _db.customInsert(
        'INSERT INTO orchard_secrets (identity_id, "${secret.column}") VALUES (?, ?) '
        'ON CONFLICT(identity_id) DO UPDATE SET "${secret.column}" = excluded."${secret.column}"',
        variables: [Variable(identityId), Variable(value)],
        updates: {_db.orchardSecrets},
      );

  @override
  Future<void> deleteAll(String identityId) => _db.customUpdate(
        'DELETE FROM orchard_secrets WHERE identity_id = ?',
        variables: [Variable(identityId)],
        updates: {_db.orchardSecrets},
      );
}
