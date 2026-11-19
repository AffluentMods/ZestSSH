/// Hosts from a CSV file (3.0), written into a space's database: the Tree's,
/// or an Orchard's, where each new host (and each group and key the file
/// makes) is placed in the chosen Crate before it is written, so the Crate's
/// own rules decide. Each host is written on its own: one the rules refuse is
/// reported and the rest still land.
library;

import 'package:drift/drift.dart' show Value;
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/orchards/record/local_record.dart' show latestRecordIn;
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/profiles/keychain.dart';

/// Where hosts from a file land.
class CsvImportTarget {
  const CsvImportTarget(
      {required this.db,
      this.crateId,
      required this.userKeyLabel,
      this.compatibilityMode = false,
      this.rdpGateway = false});

  /// The destination space's database.
  final AppDatabase db;

  /// In an Orchard: the Crate new hosts, groups and keys go into.
  final String? crateId;

  /// What a key made for a user the file names is called ("deploy
  /// (imported)"): one key for each user, found again by that name, so a
  /// second import makes none.
  final String Function(String user) userKeyLabel;

  /// Every new host with Compatibility mode on: asked for in the import,
  /// for a file of old servers that refuse modern SSH (such
  /// as 42 end-of-life hosts from SecureCRT, turned on one by
  /// one). Off unless asked.
  final bool compatibilityMode;

  /// This build offers RD Gateways (4.0): a Remote Desktop file's
  /// gateway comes into its host's options ([CsvHostRow.gateway]), signing
  /// in with the PC's account. Off: the host connects directly.
  final bool rdpGateway;
}

/// What an import did, for the result line and Copy details.
class CsvImportOutcome {
  int added = 0;
  int keysMade = 0;
  int groupsMade = 0;
  final failures = <({String name, String error})>[];
}

/// Why no key of the name a file gives can be used where its hosts go.
enum CsvKeyProblem {
  /// No key has that name.
  missing,

  /// Two keys have it, and neither is the one to take.
  twice,

  /// The only one is in another Crate whose sessions are watched: such a key
  /// signs in only to its own Crate's hosts.
  watched,
}

/// A key of a destination: its id, its name, whom it signs in as, and whether a
/// host given it would be sent a password that is yours: one saved with it, or
/// one it fetches from a password manager. A file names the key and the address
/// both, so such a key goes to a host of the file only with a tick for that host
/// (found in a security review: `host=evil,key=root`, with only the key's
/// name in the review, and the password went to that server on connect).
typedef CsvKey = ({String id, String label, String user, bool holdsPassword});

/// What a destination holds, as an import of a file reads it: the addresses
/// of its hosts, and its keys by their names.
class CsvPlace {
  CsvPlace._(this.addresses, this._keys, this._crateOfKey, this._watched, this._crateId);

  /// What [db] holds, for hosts that go into the Crate [crateId] there (in
  /// an Orchard).
  static Future<CsvPlace> of(AppDatabase db, {String? crateId}) async {
    final addresses = {for (final c in await db.connectionsDao.getAll()) csvAddressKey(c.host, c.port)};
    final keys = <String, List<CsvKey>>{};
    final secrets = IdentitySecretStore.forDatabase(db, appKeychain);
    for (final i in await db.identitiesDao.getAll()) {
      var holdsPassword = i.authMethod == 'passwordManager';
      if (!holdsPassword && (i.authMethod == 'password' || i.passwordAfterKey)) {
        try {
          holdsPassword = (await secrets.read(i.id, IdentitySecret.password))?.isNotEmpty ?? false;
        } catch (_) {
          // Cannot be told: as if it holds one.
          holdsPassword = true;
        }
      }
      keys.putIfAbsent(i.label.toLowerCase(), () => []).add((id: i.id, label: i.label, user: i.username, holdsPassword: holdsPassword));
    }
    final crateOfKey = <String, String?>{};
    final watched = <String>{};
    final crate = db.isOrchard ? crateId : null;
    if (crate != null) {
      final placement = CratePlacement(db);
      for (final list in keys.values) {
        for (final i in list) {
          crateOfKey[i.id] = await placement.crateOf('key', i.id);
        }
      }
      final record = await latestRecordIn(db);
      if (record != null) {
        for (final e in record.crates.entries) {
          if (e.value.watched) watched.add(e.key);
        }
      }
    }
    return CsvPlace._(addresses, keys, crateOfKey, watched, crate);
  }

  /// The addresses of the hosts here, as [csvRowStatus] compares them.
  final Set<String> addresses;
  final Map<String, List<CsvKey>> _keys;
  final Map<String, String?> _crateOfKey;
  final Set<String> _watched;
  final String? _crateId;

  /// The key called [name] (in any case) that a host going there signs in
  /// with: in an Orchard, the one in the Crate the hosts go into, else the
  /// only one of that name; never one of another Crate whose sessions are
  /// watched. Else why there is none.
  ({CsvKey? key, CsvKeyProblem? problem}) keyNamed(String name) {
    final all = _keys[name.toLowerCase()] ?? const <CsvKey>[];
    final crate = _crateId;
    final here = crate == null ? all : [for (final k in all) if (_crateOfKey[k.id] == crate) k];
    final pick = here.length == 1 ? here.single : (here.isEmpty && all.length == 1 ? all.single : null);
    if (pick == null) return (key: null, problem: all.isEmpty ? CsvKeyProblem.missing : CsvKeyProblem.twice);
    final keyCrate = _crateOfKey[pick.id];
    if (crate != null && keyCrate != crate && _watched.contains(keyCrate)) {
      return (key: null, problem: CsvKeyProblem.watched);
    }
    return (key: pick, problem: null);
  }

  /// The key [row] would sign in with by the file's words, where that key would
  /// send it a password that is yours: the one it names, else the one made for
  /// the user it names ([userKeyLabel]). Null where it would send none.
  CsvKey? passwordKeyOf(CsvHostRow row, {required String Function(String user) userKeyLabel}) {
    final named = row.key;
    final found = named == null ? null : keyNamed(named).key;
    final user = row.user;
    final key = found ?? (user == null ? null : keyNamed(userKeyLabel(user)).key);
    return key != null && key.holdsPassword ? key : null;
  }

  /// Notes [key], made in the Crate the hosts go into.
  void _made(CsvKey key) {
    _keys.putIfAbsent(key.label.toLowerCase(), () => []).add(key);
    _crateOfKey[key.id] = _crateId;
  }
}

/// The options a remote screen comes in with: the ones a new one has in the
/// editor, with what its file said that takes nothing from its safety: the
/// clipboard off where the file had it off, and the displays it picked.
String importedScreenOptions(CsvHostRow row, {bool gateway = false}) {
  final through = gateway ? row.gateway : null;
  // A new host's options, as the editor and Add a screen start from: this
  // device's clipboard goes to the remote only on a paste.
  if (!row.clipboardOff && row.displays <= 1 && through == null) return ScreenOptions.forNewHost.encode();
  return ScreenOptions.forNewHost
      .copyWith(
          clipboard: row.clipboardOff ? false : null,
          displays: row.displays > 1 ? row.displays : null,
          gateway: through == null ? null : ScreenGateway(host: through, port: row.gatewayPort))
      .encode();
}

/// Writes [rows] (those the person kept): each host with its group (found by
/// name, in any case, else made), its tags, and how it signs in: the key the
/// file names, found by its name as [CsvPlace.keyNamed] finds it; else, for
/// a user the file names, a key of its own that asks for the password when
/// connecting ([CsvImportTarget.userKeyLabel]), found the same way where it
/// is here; else none (asked when connecting). A key that would send the host a
/// password that is yours ([CsvKey.holdsPassword]) goes to a host only where its
/// line is in [passwordsAllowed] (the person's tick for that line); otherwise the
/// host has no key, and asks when connecting.
Future<CsvImportOutcome> applyCsvImport(
  CsvImportTarget target,
  Iterable<CsvHostRow> rows, {
  Set<int> passwordsAllowed = const {},
  DateTime Function() now = DateTime.now,
  String Function() newId = _uuid,
}) async {
  final db = target.db;
  final outcome = CsvImportOutcome();
  final crate = db.isOrchard ? target.crateId : null;
  final placement = crate == null ? null : CratePlacement(db);
  final place = await CsvPlace.of(db, crateId: crate);
  final groups = <String, String>{
    for (final g in await db.connectionGroupsDao.getAll()) g.name.toLowerCase(): g.id,
  };

  Future<String?> groupOf(String? name) async {
    if (name == null) return null;
    final known = groups[name.toLowerCase()];
    if (known != null) return known;
    final id = newId();
    await db.transaction(() async {
      await placement?.place('group', id, crate!);
      await db.connectionGroupsDao.insertGroup(ConnectionGroupsCompanion(
        id: Value(id),
        name: Value(name),
        isExpanded: const Value(true),
        createdAt: Value(now()),
      ));
    });
    outcome.groupsMade++;
    return groups[name.toLowerCase()] = id;
  }

  Future<String?> keyOf(CsvHostRow row) async {
    if (place.passwordKeyOf(row, userKeyLabel: target.userKeyLabel) != null && !passwordsAllowed.contains(row.line)) {
      return null;
    }
    final named = row.key;
    if (named != null) {
      final found = place.keyNamed(named).key;
      if (found != null) return found.id;
    }
    final user = row.user;
    if (user == null) return null;
    final label = target.userKeyLabel(user);
    final known = place.keyNamed(label).key;
    if (known != null) return known.id;
    final id = newId();
    final at = now();
    await db.transaction(() async {
      await placement?.place('key', id, crate!);
      await db.identitiesDao.insertIdentity(IdentitiesCompanion(
        id: Value(id),
        label: Value(label),
        username: Value(user),
        authMethod: const Value('password'),
        createdAt: Value(at),
        updatedAt: Value(at),
      ));
    });
    outcome.keysMade++;
    place._made((id: id, label: label, user: user, holdsPassword: false));
    return id;
  }

  for (final row in rows) {
    if (row.problem != null || row.host.isEmpty) continue;
    try {
      final groupId = await groupOf(row.group);
      final identityId = await keyOf(row);
      final id = newId();
      await db.transaction(() async {
        await placement?.place('host', id, crate!);
        await db.connectionsDao.insertConnection(ConnectionsCompanion(
          id: Value(id),
          label: Value(row.name.isEmpty ? row.host : row.name),
          host: Value(row.host),
          port: Value(row.port),
          identityId: Value(identityId),
          groupId: Value(groupId),
          protocol: Value(row.protocol),
          screenOptions:
              csvIsScreen(row.protocol) ? Value(importedScreenOptions(row, gateway: target.rdpGateway)) : const Value.absent(),
          note: Value(row.note),
          compatibilityMode: Value(target.compatibilityMode),
          createdAt: Value(now()),
          updatedAt: Value(now()),
        ));
        if (row.tags.isNotEmpty) await db.connectionTagsDao.setTagsForConnection(id, row.tags);
      });
      outcome.added++;
    } catch (e) {
      outcome.failures.add((name: row.name.isEmpty ? row.host : row.name, error: '$e'));
    }
  }
  return outcome;
}

String _uuid() => const Uuid().v4();
