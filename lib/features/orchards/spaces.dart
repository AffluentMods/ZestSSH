import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/sync/item_store.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/profiles/active_profile.dart';

/// Orchards are built behind this switch until 3.0 ships:
/// `--dart-define=ZEST_ORCHARDS=true`.
const bool kOrchardsEnabled = bool.fromEnvironment('ZEST_ORCHARDS');

/// Where the app is looking (3.0): your Tree, or one of
/// your Orchards. Picking a space in the upper left switches the whole app,
/// because every screen reads the space's own database.
@immutable
sealed class Space {
  const Space();
}

/// Your personal space: today's database, synced as one blob, free.
final class TreeSpace extends Space {
  const TreeSpace();

  @override
  bool operator ==(Object other) => other is TreeSpace;

  @override
  int get hashCode => 0;

  @override
  String toString() => 'TreeSpace';
}

/// A team space, with its own database on this device.
final class OrchardSpace extends Space {
  const OrchardSpace(this.orchardId);

  final String orchardId;

  @override
  bool operator ==(Object other) =>
      other is OrchardSpace && other.orchardId == orchardId;

  @override
  int get hashCode => orchardId.hashCode;

  @override
  String toString() => 'OrchardSpace($orchardId)';
}

/// The key of each Orchard's database: random, one per Orchard, in the OS
/// secure storage. Deleting it (with the file) is how an Orchard leaves this
/// device.
class OrchardDatabaseKeys {
  OrchardDatabaseKeys(this._storage, {AppDatabase? Function()? tree, Future<String?> Function(String orchardId)? held})
      : _tree = tree,
        _held = held;

  final FlutterSecureStorage _storage;

  /// The key of a team that waits for its owner and is used where it lies.
  final Future<String?> Function(String orchardId)? _held;

  /// Your Tree's database, whose seal keeps the keys while the encrypting
  /// lock is on ([SecretSeal]); null while it is closed.
  final AppDatabase? Function()? _tree;

  static String storageKey(String orchardId) => 'orchard_db_key_$orchardId';

  static final _hex64 = RegExp(r'^[0-9a-f]{64}$');

  Future<String?> read(String orchardId) async => (await readOrClosed(orchardId)).key;

  /// [orchardId]'s key, and whether none was read only because it is kept
  /// sealed and there was nothing to open it with (your Tree's database was
  /// closed: the app had just locked). The key is not lost then: it reads
  /// again once the database is open, so nothing may be deleted or made again
  /// on that answer (found in a security review). Both come from one look
  /// at the database and one read of the storage: asked as a second question
  /// after the read, "is it closed?" answered no where the app was unlocked
  /// in between, and the key was taken for lost after all.
  Future<({String? key, bool sealedWhileClosed})> readOrClosed(String orchardId) async {
    if (Profiles.on && Profiles.provisionalTeams.contains(orchardId)) {
      return (key: await _held?.call(orchardId), sealedWhileClosed: false);
    }
    final slot = storageKey(orchardId);
    final tree = _tree?.call();
    final stored = await _storage.read(key: slot);
    final value = await openKept(tree, slot, stored);
    final key = value != null && _hex64.hasMatch(value) ? value : null;
    return (key: key, sealedWhileClosed: key == null && tree == null && SecretSeal.isSealed(stored));
  }

  Future<String> create(String orchardId) async {
    final rng = Random.secure();
    final hex = List<int>.generate(32, (_) => rng.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final slot = storageKey(orchardId);
    await _storage.write(key: slot, value: await keepSealed(_tree?.call(), slot, hex));
    return hex;
  }

  Future<void> delete(String orchardId) =>
      _storage.delete(key: storageKey(orchardId));
}

/// Where Orchard databases live, so tests can keep them in memory.
abstract class OrchardDatabaseStorage {
  Future<bool> exists(String orchardId);

  Future<AppDatabase> open(String orchardId, String keyHex);

  /// Deletes the database file (and its WAL/SHM companions).
  Future<void> delete(String orchardId);

  /// The Orchards that have a database on this device.
  Future<List<String>> list();
}

/// A storage that can put a database aside instead of deleting it.
abstract interface class SetsTeamsAside {
  /// Moves the database of [orchardId] and its side files out of the way.
  Future<void> setAside(String orchardId);
}

/// [OrchardDatabaseStorage] on disk: `orchards/<id>.db` beside the Tree's.
class FileOrchardDatabaseStorage implements OrchardDatabaseStorage, SetsTeamsAside {
  const FileOrchardDatabaseStorage();

  static final _id = RegExp(
      r'^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.db$');

  @override
  Future<bool> exists(String orchardId) async =>
      (await AppDatabase.orchardDatabaseFile(orchardId)).exists();

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    final db = await AppDatabase.openOrchard(orchardId, keyHex: keyHex);
    // Opens the file and runs onCreate / migrations now, so a failure shows
    // here and not on the first screen that reads it.
    await db.customSelect('SELECT 1').get();
    return db;
  }

  @override
  Future<void> delete(String orchardId) async {
    final file = await AppDatabase.orchardDatabaseFile(orchardId);
    for (final path in [file.path, '${file.path}-wal', '${file.path}-shm']) {
      final f = File(path);
      if (await f.exists()) await f.delete();
    }
  }

  @override
  Future<List<String>> list() async {
    final dir = (await AppDatabase.orchardDatabaseFile(
            '00000000-0000-0000-0000-000000000000'))
        .parent;
    if (!await dir.exists()) return const [];
    final ids = <String>[];
    await for (final entity in dir.list()) {
      final m = _id.firstMatch(entity.uri.pathSegments.last);
      if (entity is File && m != null) ids.add(m.group(1)!);
    }
    // Those that wait for their owner and are used where they lie.
    if (Profiles.on) ids.addAll(Profiles.provisionalTeams);
    return ids;
  }

  @override
  Future<void> setAside(String orchardId) async {
    final file = await AppDatabase.orchardDatabaseFile(orchardId);
    final aside = Directory('${file.parent.path}${Platform.pathSeparator}$kTeamsSetAsideFolder');
    await aside.create(recursive: true);
    final stamp = DateTime.now().millisecondsSinceEpoch;
    for (final suffix in ['-shm', '-wal', '-journal', '']) {
      final f = File('${file.path}$suffix');
      if (await f.exists()) {
        await f.rename('${aside.path}${Platform.pathSeparator}$orchardId.$stamp.db$suffix');
      }
    }
  }
}

/// Where a team set aside waits, inside a profile's teams, for thirty days.
const kTeamsSetAsideFolder = 'set_aside';

/// An Orchard closed on this device by its offline limit (3.0): it
/// opens again once this device reaches ZestSSH Cloud.
class OrchardClosedOffline implements Exception, HasTypeName {
  const OrchardClosedOffline(this.orchardId);

  final String orchardId;

  @override
  String toString() => 'Orchards: closed until this device reaches ZestSSH Cloud';

  @override
  String get typeName => 'OrchardClosedOffline';
}

/// Which account each Orchard on this device belongs to, by Orchard id: the
/// account signed in when its database was first opened. An Orchard is
/// listed and opened only for that account; for any other it stays on the
/// device, encrypted, and out of sight. (Every Orchard on the device was
/// listed for whoever signed in, and a team showed, with errors, to an
/// account that was not in it.) A database
/// from before this was kept is claimed by the first account that opens it.
class OrchardOwners {
  OrchardOwners(this._storage);

  final FlutterSecureStorage _storage;

  static const storageKey = 'orchard_owners_v1';

  /// The owners kept: none where nothing is kept, or what is kept is no map. A
  /// keychain that could not be read throws (3.3.2: on a Mac, macOS did not let
  /// ZestSSH read it), and is never taken for none: an Orchard would then be
  /// claimed for whoever opened it, and [set] would write that one owner over
  /// every other.
  Future<Map<String, String>> read() async {
    final raw = await _storage.read(key: storageKey);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String) e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> set(String orchardId, String uid) async {
    final all = await read();
    if (all[orchardId] == uid) return;
    await _storage.write(key: storageKey, value: jsonEncode({...all, orchardId: uid}));
  }

  Future<void> remove(String orchardId) async {
    final all = await read();
    if (!all.containsKey(orchardId)) return;
    await _storage.write(key: storageKey, value: jsonEncode({...all}..remove(orchardId)));
  }
}

/// An Orchard on this device that belongs to another account than the one
/// signed in ([OrchardOwners]): it is not opened.
class OrchardOfAnotherAccount implements Exception, HasTypeName {
  const OrchardOfAnotherAccount(this.orchardId);

  final String orchardId;

  @override
  String toString() => 'Orchards: this team belongs to another account on this device';

  @override
  String get typeName => 'OrchardOfAnotherAccount';
}

/// The Orchard databases open right now, by Orchard id. They open only while
/// the Tree's is open (the app is unlocked) and close with it.
class OrchardDatabasesNotifier extends StateNotifier<Map<String, AppDatabase>> {
  OrchardDatabasesNotifier(this._keys,
      {OrchardDatabaseStorage storage = const FileOrchardDatabaseStorage(),
      DeviceContact? contact,
      OrchardOwners? owners,
      String? Function()? account,
      void Function(String orchardId)? onSetAside})
      : _storage = storage,
        _contact = contact,
        _owners = owners,
        _account = account,
        _onSetAside = onSetAside,
        super(const {});

  /// A team's database was set aside: the person is told.
  final void Function(String orchardId)? _onSetAside;

  /// Which account each Orchard belongs to, and who is signed in: with
  /// neither (tests), every Orchard on the device is this account's.
  final OrchardOwners? _owners;
  final String? Function()? _account;

  final OrchardDatabaseKeys _keys;
  final OrchardDatabaseStorage _storage;

  /// Teams from before owners were kept whose own record does not name the
  /// account (by account id), so they are not listed for it again in this
  /// run.
  final _notTheirs = <String, Set<String>>{};

  /// How this device stands with ZestSSH Cloud: given to every database
  /// this opens, so that a Crate's own offline limit can be measured by
  /// whoever holds the database (crate_offline.dart). Without one, a Crate
  /// that has a limit counts as closed.
  final DeviceContact? _contact;
  final _opening = <String, Future<AppDatabase>>{};
  final _closedOffline = <String>{};

  /// The Orchards closed by their offline limit.
  Set<String> get closedOffline => Set.unmodifiable(_closedOffline);

  /// Opens an Orchard's database, creating it (and its key) the first time.
  /// A database whose key is gone cannot be read by anyone: it is deleted and
  /// made again, and the Orchard's data comes back from the server. An
  /// Orchard closed by its offline limit does not open ([OrchardClosedOffline]).
  Future<AppDatabase> open(String orchardId) {
    if (_closedOffline.contains(orchardId)) return Future.error(OrchardClosedOffline(orchardId));
    final open = state[orchardId];
    if (open != null) return Future.value(open);
    // A block body: `remove` returns this very future, and whenComplete
    // would wait on it, forever.
    return _opening[orchardId] ??= _open(orchardId).whenComplete(() {
      _opening.remove(orchardId);
    });
  }

  /// The database of [orchardId] when it is open now, and null when it is
  /// not (never opened in this run, closed with the app's lock, or closed
  /// by the Orchard's offline limit): for whoever must not open it by
  /// asking for it.
  AppDatabase? opened(String orchardId) => state[orchardId];

  Future<AppDatabase> _open(String orchardId) async {
    // With the database closed a sealed key reads as none: never taken for one
    // that is lost.
    if (Profiles.on && SecretSeal.openTree == null) throw StateError('Orchard databases are closing');
    final owners = _owners;
    final account = _account;
    // The account an Orchard of no account yet becomes, and whether its own
    // record must name that account first.
    String? claim;
    var ifMember = false;
    if (owners != null && account != null) {
      final uid = account();
      final owner = (await owners.read())[orchardId];
      // An Orchard of an account opens for that account only, and none opens
      // while nobody is signed in. One of no account yet is the account's
      // that makes it; one already on the device from before owners were
      // kept, only an account its own record names as a member (it went to
      // whichever account opened it first).
      if (uid == null || (owner != null && owner != uid)) throw OrchardOfAnotherAccount(orchardId);
      if (owner == null) {
        claim = uid;
        ifMember = await _storage.exists(orchardId);
      }
    }
    final kept = await _keys.readOrClosed(orchardId);
    var key = kept.key;
    // A phone or tablet with the encrypting lock keeps the key sealed. While
    // your Tree's database is closed (the app locked as a team sync was on
    // its way) it reads as none, and the lines below took that for a lost
    // key: they deleted the team's database, with what it had not sent yet,
    // and wrote a new key over the sealed one. Refused instead, as a
    // computer's is above; it opens again once the app is unlocked.
    if (kept.sealedWhileClosed) throw StateError('Orchard databases are closing');
    if (key == null) {
      // One used where it lies may be another account's: it is not this
      // profile's to set aside or make again.
      if (Profiles.on && Profiles.provisionalTeams.contains(orchardId)) {
        throw StateError('A team waiting for its owner has no key here');
      }
      if (await _storage.exists(orchardId)) {
        final storage = _storage;
        if (Profiles.on && storage is SetsTeamsAside) {
          // A key that cannot be read never deletes a database on a computer:
          // it is set aside for thirty days, and the team is fetched again.
          // What was changed here and never reached ZestSSH Cloud is lost then,
          // and the notice says so.
          await (storage as SetsTeamsAside).setAside(orchardId);
          _onSetAside?.call(orchardId);
        } else {
          await storage.delete(orchardId);
        }
      }
      key = await _keys.create(orchardId);
      // Made again, empty: what comes back is what the server gives this
      // account.
      ifMember = false;
    }
    final db = await _storage.open(orchardId, key);
    if (ifMember && !await _namesMember(db, claim!)) {
      await db.close();
      throw OrchardOfAnotherAccount(orchardId);
    }
    if (claim != null) await owners!.set(orchardId, claim);
    // Before anything can ask what a Crate of it allows.
    if (_contact != null) attachDeviceContact(db, _contact);
    try {
      // What an older version of the app kept for this one, taken in before
      // anything reads or edits the Orchard.
      await OrchardItemStore(db).absorbKnownExtras();
    } catch (_) {/* still kept, and tried again on the next open */}
    if (!mounted) {
      await db.close();
      throw StateError('Orchard databases are closing');
    }
    state = {...state, orchardId: db};
    return db;
  }

  /// Closes an Orchard past its offline limit: it stays closed, its
  /// hosts with it, until [reopenOffline].
  Future<void> closeOffline(String orchardId) {
    _closedOffline.add(orchardId);
    return close(orchardId);
  }

  /// One Orchard closed by its offline limit may open again: the limit no
  /// longer counts as reached for it. Returns whether it was closed.
  bool reopenOne(String orchardId) => _closedOffline.remove(orchardId);

  /// This device reached ZestSSH Cloud: the Orchards closed by their offline
  /// limits may open again. Returns whether any was closed.
  bool reopenOffline() {
    final any = _closedOffline.isNotEmpty;
    _closedOffline.clear();
    return any;
  }

  Future<void> close(String orchardId) async {
    final db = state[orchardId];
    if (db == null) return;
    state = {...state}..remove(orchardId);
    try {
      await db.close();
    } catch (_) {/* best effort: closing under live streams may throw */}
  }

  Future<void> closeAll() async {
    for (final id in state.keys.toList()) {
      await close(id);
    }
  }

  /// The Orchards that have a database on this device, open or not, that
  /// belong to the account signed in ([OrchardOwners]). One of no account
  /// yet, from before that was kept, is opened to read whether its own
  /// record names the account: listed and the account's if so, and left on
  /// the device unlisted if not. While nobody is signed in, none.
  Future<List<String>> onDevice() async {
    final all = {...state.keys, ...await _storage.list()}.toList();
    final owners = _owners;
    final account = _account;
    if (owners == null || account == null) return all;
    final uid = account();
    if (uid == null) return const [];
    final known = await owners.read();
    final notTheirs = _notTheirs[uid] ??= {};
    final out = <String>[];
    for (final id in all) {
      final owner = known[id];
      if (owner == uid) {
        out.add(id);
      } else if (owner == null && !notTheirs.contains(id)) {
        try {
          await open(id);
          out.add(id);
        } on OrchardOfAnotherAccount {
          notTheirs.add(id);
        } catch (_) {
          // It did not open for another reason: listed, so that the
          // reason shows where it is listed, as before.
          out.add(id);
        }
      }
    }
    return out;
  }

  /// Whether the record kept in [db] names [uid] as a member (one who left
  /// is not).
  static Future<bool> namesMember(AppDatabase db, String uid) => _namesMember(db, uid);

  static Future<bool> _namesMember(AppDatabase db, String uid) async {
    try {
      final row = await db
          .customSelect("SELECT 1 FROM member_keys WHERE uid = ? AND status <> 'removed' LIMIT 1",
              variables: [Variable.withString(uid)])
          .getSingleOrNull();
      return row != null;
    } catch (_) {
      return false;
    }
  }

  /// Takes an Orchard off this device: closes it, then deletes its database
  /// and its key.
  Future<void> forget(String orchardId) async {
    _closedOffline.remove(orchardId);
    await close(orchardId);
    // One that waits for its owner was only used where it lies: it may be
    // another account's, and nothing of it goes.
    if (Profiles.on && Profiles.provisionalTeams.remove(orchardId)) return;
    await _storage.delete(orchardId);
    await _keys.delete(orchardId);
    await _owners?.remove(orchardId);
  }

  /// Whether [orchardId] has a database on this device, open or not,
  /// whichever account it is for.
  Future<bool> isHere(String orchardId) async => state.containsKey(orchardId) || await _storage.exists(orchardId);

  /// Every Orchard off this device (deleting all local data, or the account).
  Future<void> forgetAll() async {
    final ids = {...state.keys, ...await _storage.list()};
    for (final id in ids) {
      await forget(id);
    }
  }
}
