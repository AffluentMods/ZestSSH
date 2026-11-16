import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/identities_dao.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_import_service.dart' show publicKeyLineNamed, publicKeyLineOf;

// ── Identity search + list ───────────────────────────────────────

/// Search query for filtering identities.
final identitySearchQueryProvider = StateProvider<String>((ref) => '');

/// Which summary-chip filter the desktop Keys list is narrowed to.
/// [KeysSummaryFilter.all] means no filter (show every identity).
///
/// The `unused` / `duplicates` cases can't be resolved inside
/// [filteredIdentitiesProvider] (they need the connection usage counts and a
/// cross-identity fingerprint comparison, neither of which is in the identity
/// stream), so the summary filter is applied CLIENT-SIDE in the Keys list pane.
/// The stream provider below stays search-only.
enum KeysSummaryFilter { all, unattended, unused, duplicates, inAgent }

/// The active Keys summary-chip filter. Set by the summary chip row in the Keys
/// list header; applied in `KeysListPane`.
final keysSummaryFilterProvider =
    StateProvider<KeysSummaryFilter>((ref) => KeysSummaryFilter.all);

/// Reactive stream of all identities, filtered by the search query only.
final filteredIdentitiesProvider = StreamProvider<List<Identity>>((ref) {
  final query = ref.watch(identitySearchQueryProvider).toLowerCase();
  final stream = ref.watch(identitiesDaoProvider).watchAll();
  if (query.isEmpty) return stream;
  return stream.map((list) => list.where((i) {
        return i.label.toLowerCase().contains(query) ||
            i.username.toLowerCase().contains(query);
      }).toList());
});

/// Reactive stream of all identities (unfiltered).
final identitiesProvider = StreamProvider<List<Identity>>((ref) {
  return ref.watch(identitiesDaoProvider).watchAll();
});

/// Reactive map of identity ID → number of connections using it.
final identityUsageCountsProvider =
    StreamProvider<Map<String, int>>((ref) {
  return ref.watch(connectionsDaoProvider).watchIdentityUsageCounts();
});

/// Reactive map of identity ID → the connections that reference it, so the
/// Keys view can expand a key's "used by" count into the actual host list
/// too. Derived client-side from the connections stream - no new query.
final identityUsageHostsProvider =
    StreamProvider<Map<String, List<Connection>>>((ref) {
  return ref.watch(connectionsDaoProvider).watchAll().map((connections) {
    final map = <String, List<Connection>>{};
    for (final c in connections) {
      final id = c.identityId;
      if (id == null) continue;
      (map[id] ??= <Connection>[]).add(c);
    }
    // Stable, readable order within each identity's host list.
    for (final list in map.values) {
      list.sort((a, b) =>
          a.label.toLowerCase().compareTo(b.label.toLowerCase()));
    }
    return map;
  });
});

/// Reactive map of identity ID → most recent lastConnected date.
final identityLastUsedProvider =
    StreamProvider<Map<String, DateTime>>((ref) {
  return ref.watch(connectionsDaoProvider).watchIdentityLastUsed();
});

// ── CRUD notifier ────────────────────────────────────────────────

final identityCrudProvider = Provider<IdentityCrudNotifier>((ref) {
  return IdentityCrudNotifier(
    ref.watch(identitiesDaoProvider),
    ref.watch(identitySecretsProvider),
    ref.watch(connectionsDaoProvider),
  );
});

/// Whether the password saved for [identity] is one in use (3.0, accounts
/// per host): a password key's own, or one tried after a key. A password left
/// from before an identity became a key is not: it is neither shown, nor
/// shared, nor sent.
bool passwordInUseBy(Identity identity) =>
    identity.authMethod == AuthMethod.password.name ||
    (identity.passwordAfterKey && kKeysWithPasswordAfter.contains(identity.authMethod));

/// What a save of a key editor does with the password saved with a key
/// (3.0, accounts per host), where the identity saved is a key of [kind]
/// that may hold one ([kKeysWithPasswordAfter]): the field showed [shown]
/// when the editor opened the identity (empty where it showed none, also
/// for one left from before the identity became a key, which is not shown),
/// whose kind was then [openedKind] (null: a new identity), and shows [text]
/// now. A save changes nothing the person did not change: a field as it was
/// leaves the password and the switch as they were. Changed, what it shows
/// is what is tried after the key ([write], and [afterKey] true); emptied,
/// nothing is, and a password it had shown is taken off ([clear]).
({String? write, bool? afterKey, bool clear}) keyPasswordOnSave({
  required String kind,
  required String? openedKind,
  required String shown,
  required String text,
}) {
  final unchanged = openedKind != null && kind == openedKind && text == shown;
  if (unchanged) return (write: null, afterKey: null, clear: false);
  if (text.isNotEmpty) return (write: text, afterKey: true, clear: false);
  return (write: null, afterKey: false, clear: shown.isNotEmpty);
}

/// Handles identity CRUD + secure credential storage.
///
/// Secrets live in the space's [IdentitySecretStore]: the OS secure storage
/// for your Tree (`identity_password_{id}`, `identity_key_{id}`, ...), the
/// Orchard's own database for an Orchard. The Drift table only holds
/// non-sensitive metadata.
class IdentityCrudNotifier {
  final IdentitiesDao _dao;
  final IdentitySecretStore _secrets;
  final ConnectionsDao _connectionsDao;

  IdentityCrudNotifier(this._dao, this._secrets, this._connectionsDao);

  /// Create a new identity with optional password or key.
  Future<String> create({
    required String label,
    required String username,
    required String authMethod,
    String? keyType,
    String? publicKeyFingerprint,
    String? publicKeyData,
    String? password,
    String? privateKeyPem,
    String? keyPassphrase,
    int colorIndex = 0,
    int? colorValue,
    bool allowUnattended = false,
    String? passwordRef,
    String? agentSource,
    bool passwordAfterKey = false,
  }) async {
    final id = const Uuid().v4();

    await _dao.insertIdentity(IdentitiesCompanion(
      id: Value(id),
      label: Value(label),
      username: Value(username),
      authMethod: Value(authMethod),
      keyType: Value(keyType),
      publicKeyFingerprint: Value(publicKeyFingerprint),
      publicKeyData: Value(publicKeyData),
      colorIndex: Value(colorIndex),
      colorValue: Value(colorValue),
      isDefault: const Value(false),
      allowUnattended: Value(allowUnattended),
      passwordRef: Value(passwordRef),
      agentSource: Value(agentSource),
      passwordAfterKey: Value(passwordAfterKey),
      createdAt: Value(DateTime.now()),
    ));

    if (allowUnattended) {
      _auditUnattended(id, label, enabled: true);
    }

    // Store the secrets where this space keeps them
    if (password != null) {
      await _secrets.write(id, IdentitySecret.password, password);
    }
    if (privateKeyPem != null) {
      await _secrets.write(id, IdentitySecret.privateKey, privateKeyPem);
    }
    if (keyPassphrase != null) {
      await _secrets.write(id, IdentitySecret.passphrase, keyPassphrase);
    }

    return id;
  }

  /// Update identity metadata and optionally rotate credentials.
  Future<void> update({
    required String id,
    String? label,
    String? username,
    String? authMethod,
    String? keyType,
    String? publicKeyFingerprint,
    String? publicKeyData,
    String? password,
    String? privateKeyPem,
    String? keyPassphrase,
    int? colorIndex,
    int? colorValue,
    bool clearColorValue = false,
    bool? allowUnattended,
    String? passwordRef,
    bool clearPasswordRef = false,
    bool? passwordAfterKey,
    bool clearPassword = false,
  }) async {
    // Audit an unattended-runs change (only when it actually flips), reading the
    // stored row so a no-op save never logs a spurious security event.
    if (allowUnattended != null) {
      final current = await _dao.getById(id);
      if (current != null && current.allowUnattended != allowUnattended) {
        _auditUnattended(id, label ?? current.label, enabled: allowUnattended);
      }
    }

    final companion = IdentitiesCompanion(
      id: Value(id),
      label: label != null ? Value(label) : const Value.absent(),
      username: username != null ? Value(username) : const Value.absent(),
      authMethod:
          authMethod != null ? Value(authMethod) : const Value.absent(),
      keyType: keyType != null ? Value(keyType) : const Value.absent(),
      publicKeyFingerprint: publicKeyFingerprint != null
          ? Value(publicKeyFingerprint)
          : const Value.absent(),
      publicKeyData: publicKeyData != null
          ? Value(publicKeyData)
          : const Value.absent(),
      colorIndex:
          colorIndex != null ? Value(colorIndex) : const Value.absent(),
      // Custom colour overrides the palette index; the editor sets
      // clearColorValue when the user picked a preset / no colour so any prior
      // custom value is removed.
      colorValue: clearColorValue
          ? const Value(null)
          : colorValue != null
              ? Value(colorValue)
              : const Value.absent(),
      allowUnattended: allowUnattended != null
          ? Value(allowUnattended)
          : const Value.absent(),
      // Where a password manager keeps its password (3.0); cleared
      // when the key stops using one.
      passwordRef: clearPasswordRef
          ? const Value(null)
          : passwordRef != null
              ? Value(passwordRef)
              : const Value.absent(),
      // Whether the password saved with a key is tried after it (3.0,
      // accounts per host).
      passwordAfterKey: passwordAfterKey != null ? Value(passwordAfterKey) : const Value.absent(),
    );

    await _dao.updateIdentity(companion);

    // Update secrets if provided; [clearPassword] removes the one saved (a
    // key's own password taken off it).
    if (password != null) {
      await _secrets.write(id, IdentitySecret.password, password);
    } else if (clearPassword) {
      await _secrets.write(id, IdentitySecret.password, null);
    }
    if (privateKeyPem != null) {
      await _secrets.write(id, IdentitySecret.privateKey, privateKeyPem);
    }
    if (keyPassphrase != null) {
      await _secrets.write(id, IdentitySecret.passphrase, keyPassphrase);
    }
  }

  /// Removes every secret of the identity [id], keeping the identity: a key
  /// that became a team certificate (3.0) keeps nothing secret.
  Future<void> clearSecrets(String id) => _secrets.deleteAll(id);

  /// Whether a copy can be made of [identity]: the kinds whose whole content
  /// [create] writes. A hardware or agent key is not held here, an OpenSSH
  /// certificate key has a certificate [create] does not write, and a team
  /// certificate belongs to its Crate's authority.
  static bool canDuplicate(Identity identity) =>
      !identity.usesAgent &&
      const {'password', 'publicKey', 'passwordManager'}.contains(identity.authMethod);

  /// A copy of [source] named [label], with what it signs in with (its
  /// password, or its private key and passphrase, or where its password is in
  /// a password manager), so the copy works by itself: the same key with
  /// another username is one copy and one edit. Unattended runs stay off for
  /// the copy (they are turned on for one key on one device). In a team's
  /// space the copy goes into its source's Crate where this account can add
  /// there ([CratePlacement.placeCopy]; it went where new items go). Returns
  /// the copy's id.
  Future<String> duplicate(Identity source, {required String label}) async {
    if (!canDuplicate(source)) {
      throw StateError('An identity of this kind cannot be duplicated');
    }
    final method = source.authMethod;
    // A key's own password goes with it where it is tried after the key
    // (3.0, accounts per host); a password left from before it was a key
    // does not.
    final afterKey = source.passwordAfterKey && kKeysWithPasswordAfter.contains(method);
    final password = method == 'password' || afterKey ? await getPassword(source.id) : null;
    final privateKeyPem = method == 'publicKey' ? await getPrivateKey(source.id) : null;
    final keyPassphrase = method == 'publicKey' ? await getKeyPassphrase(source.id) : null;
    final db = _dao.attachedDatabase;
    // Written whole or not at all: the copy, and the Crate it is in.
    return db.transaction(() async {
      final id = await create(
        label: label,
        username: source.username,
        authMethod: method,
        keyType: source.keyType,
        publicKeyFingerprint: source.publicKeyFingerprint,
        publicKeyData: source.publicKeyData,
        password: password,
        passwordAfterKey: afterKey,
        privateKeyPem: privateKeyPem,
        keyPassphrase: keyPassphrase,
        colorIndex: source.colorIndex,
        colorValue: source.colorValue,
        passwordRef: method == 'passwordManager' ? source.passwordRef : null,
      );
      if (db.isOrchard) await CratePlacement(db).placeCopy('key', source.id, id);
      return id;
    });
  }

  /// Delete identity and its associated secrets.
  ///
  /// It leaves every host first, so no host names an identity that is gone:
  /// a host whose default it was is signed in to with its first other
  /// account from then on (3.0, accounts per host), or with none.
  ///
  /// Whole or not at all: a team vault refusing the key itself (a role that
  /// may edit but not delete) leaves its hosts signing in with it, and its
  /// secrets. Those were changed first, and a refused delete still lost them.
  Future<void> delete(String id) async {
    final db = _connectionsDao.attachedDatabase;
    // A team's secrets are rows of its database; your own are in this
    // device's secure storage, which no transaction takes back: cleared only
    // once the key is gone.
    final secretsInDatabase = _secrets is OrchardIdentitySecrets;
    await db.transaction(() async {
      await db.hostAccountsDao.removeIdentity(id);
      await _dao.deleteIdentity(id);
      if (secretsInDatabase) await _secrets.deleteAll(id);
    });
    if (!secretsInDatabase) await _secrets.deleteAll(id);
  }

  /// Set an identity as the default.
  Future<void> setDefault(String id) => _dao.setDefault(id);

  /// Append a security-audit line for an unattended-runs change. Uses the same
  /// [AppLogger] channel the app already uses for security events (PIN
  /// lockouts, host-key rejections). The label is newline-stripped so a
  /// credential named with an embedded `\n` can't forge extra log lines.
  void _auditUnattended(String id, String label, {required bool enabled}) {
    final safeLabel =
        label.replaceAll('\n', ' ').replaceAll('\r', ' ').trim();
    AppLogger.warning(
        'SECURITY: unattended runs ${enabled ? 'ENABLED' : 'DISABLED'} for '
        'credential "$safeLabel" (id=$id)');
  }

  /// Read the stored password for an identity.
  Future<String?> getPassword(String id) =>
      _secrets.read(id, IdentitySecret.password);

  /// Save a password with an identity's secrets.
  Future<void> setPassword(String id, String password) =>
      _secrets.write(id, IdentitySecret.password, password);

  /// Read the stored private key PEM for an identity.
  Future<String?> getPrivateKey(String id) =>
      _secrets.read(id, IdentitySecret.privateKey);

  /// Read the stored key passphrase for an identity.
  Future<String?> getKeyPassphrase(String id) =>
      _secrets.read(id, IdentitySecret.passphrase);

  /// Save a key passphrase with an identity's secrets.
  Future<void> setKeyPassphrase(String id, String passphrase) =>
      _secrets.write(id, IdentitySecret.passphrase, passphrase);

  /// The OpenSSH public key line of [key], what an authorized_keys file
  /// takes: the one kept with it, else made from its private key, read where
  /// this space keeps its secrets (a key made in the app kept none, so it
  /// could not be installed on hosts, shared, or exported but as its
  /// fingerprint). Null where it is no key, or its private key cannot be
  /// read.
  Future<String?> publicLineOf(Identity key) async {
    final kept = key.publicKeyData?.trim();
    if (kept != null && kept.isNotEmpty) return publicKeyLineNamed(kept);
    if (key.authMethod != 'publicKey') return null;
    final pem = await getPrivateKey(key.id);
    if (pem == null || pem.isEmpty) return null;
    return publicKeyLineOf(pem, passphrase: await getKeyPassphrase(key.id), comment: key.label);
  }
}
