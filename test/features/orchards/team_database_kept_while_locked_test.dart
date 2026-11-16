// A team's database on a phone or tablet whose encrypting lock is on: its key
// is kept sealed, and reads as none while your Tree's database is closed (the
// app has just locked). A team opened in that moment (a sync round on its way)
// had its database deleted, with what it had not sent yet, and a new key
// written over the sealed one (found in a security review). It is refused
// now, and opens again with the same key once the app is unlocked.
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/services/secret_seal.dart';

class _Vault implements FlutterSecureStorage {
  final kept = <String, String>{};

  /// Run once, as the first read answers: what happens to the app between
  /// one read of the storage and the next.
  void Function()? afterFirstRead;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    switch (i.memberName) {
      case #read:
        final value = kept[key];
        final then = afterFirstRead;
        afterFirstRead = null;
        return Future<String?>.value(value).whenComplete(() => then?.call());
      case #write:
        final value = i.namedArguments[#value] as String?;
        value == null ? kept.remove(key) : kept[key!] = value;
        return Future<void>.value();
      case #delete:
        kept.remove(key);
        return Future<void>.value();
      case #readAll:
        return Future<Map<String, String>>.value(Map.of(kept));
      case #containsKey:
        return Future<bool>.value(kept.containsKey(key));
    }
    return super.noSuchMethod(i);
  }
}

/// Team databases "on disk": which exist, which were deleted, and the key
/// each was opened with.
class _Disk implements OrchardDatabaseStorage {
  final there = <String>{};
  final deleted = <String>[];
  final openedWith = <String>[];

  @override
  Future<bool> exists(String orchardId) async => there.contains(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    there.add(orchardId);
    openedWith.add(keyHex);
    return AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
  }

  @override
  Future<void> delete(String orchardId) async {
    there.remove(orchardId);
    deleted.add(orchardId);
  }

  @override
  Future<List<String>> list() async => there.toList();
}

void main() {
  const team = '11111111-1111-4111-8111-111111111111';
  final slot = OrchardDatabaseKeys.storageKey(team);
  final hex = 'ab' * 32;

  test('opened while the app is locked: refused, nothing deleted, the key left as it is; unlocked, it opens with that key', () async {
    final vault = _Vault();
    final disk = _Disk()..there.add(team);
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    // The team's key as the encrypting lock keeps it: sealed with your Tree's seal.
    await SecretSeal.setActive(tree, true);
    final sealed = await (await SecretSeal.of(tree)).seal(slot, hex);
    expect(SecretSeal.isSealed(sealed), isTrue);
    vault.kept[slot] = sealed;

    AppDatabase? open; // null: the app is locked, your Tree's database closed
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(vault, tree: () => open), storage: disk);
    addTearDown(databases.closeAll);

    await expectLater(databases.open(team), throwsStateError);
    expect(disk.deleted, isEmpty, reason: 'the team database is still there');
    expect(disk.there, {team});
    expect(vault.kept[slot], sealed, reason: 'and its key was not written over');
    expect(disk.openedWith, isEmpty);

    open = tree; // unlocked
    await databases.open(team);
    expect(disk.openedWith, [hex], reason: 'the same key opens it');
    expect(disk.deleted, isEmpty);
    expect(vault.kept[slot], sealed);
  });

  test('unlocked between the read of the key and the question whether it was only closed: still refused, nothing deleted', () async {
    final vault = _Vault();
    final disk = _Disk()..there.add(team);
    final tree = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(tree.close);
    await SecretSeal.setActive(tree, true);
    final sealed = await (await SecretSeal.of(tree)).seal(slot, hex);
    vault.kept[slot] = sealed;

    AppDatabase? open; // locked as the team's key is read
    vault.afterFirstRead = () => open = tree; // and unlocked right after that read
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(vault, tree: () => open), storage: disk);
    addTearDown(databases.closeAll);

    // Whether the key was lost or only closed is decided by the one look at
    // the database that the read itself took: asked again after the unlock,
    // "is it closed?" answered no, and the team's database was deleted.
    await expectLater(databases.open(team), throwsStateError);
    expect(disk.deleted, isEmpty, reason: 'the team database is still there');
    expect(vault.kept[slot], sealed, reason: 'and its key was not written over');

    await databases.open(team);
    expect(disk.openedWith, [hex], reason: 'the next open, unlocked, uses the same key');
    expect(disk.deleted, isEmpty);
  });

  test('a key that is not sealed is read as before, locked or not', () async {
    final vault = _Vault()..kept[slot] = hex;
    final disk = _Disk()..there.add(team);
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(vault, tree: () => null), storage: disk);
    addTearDown(databases.closeAll);
    await databases.open(team);
    expect(disk.openedWith, [hex]);
    expect(disk.deleted, isEmpty);
  });

  test('a team whose key is gone starts over, as before', () async {
    final vault = _Vault();
    final disk = _Disk()..there.add(team);
    final databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(vault, tree: () => null), storage: disk);
    addTearDown(databases.closeAll);
    await databases.open(team);
    expect(disk.deleted, [team]);
    expect(vault.kept[slot], isNotNull);
  });
}
