import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

import '../helpers/orchard_db_fixture.dart';

/// The password saved with a key, fetched when a server did not take the
/// key and asks for a password (3.0, accounts per host), by the rules a
/// password key's own password goes by: in your Tree it is simply read; an
/// Orchard password this account may not see goes only to a host it cannot
/// change; one from a Crate that asks again goes to a host it may
/// change only once the person confirms it is them, once for each address.
/// Where none is saved, or none can be read, it is asked for, and
/// saved with the key where they say so and the key may be changed here.
const _keysConnect = '12121212-1212-4212-8212-121212121212';
const _keysAsk = '56565656-5656-4565-8565-565656565656';
const _hostsConnect = '34343434-3434-4434-8434-343434343434';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  const saved = 'correct-horse-battery';
  late AppDatabase tree;
  late AppDatabase orchard;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(orchard); // where new items go: everything
    Future<void> crate(String id, CrateLevel level, {bool asksAgain = false}) => orchard.customStatement(
        'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation, confirm_reveal) '
        "VALUES (?, 'c', ?, ?, 1, ?)",
        [id, level.name, jsonEncode(switchList(levelSwitches(level))), asksAgain ? 1 : 0]);
    await crate(_keysConnect, CrateLevel.connect);
    await crate(_keysAsk, CrateLevel.use, asksAgain: true);
    await crate(_hostsConnect, CrateLevel.connect);
  });

  tearDown(() async {
    await tree.close();
    await orchard.close();
  });

  IdentityCrudNotifier crudOf(AppDatabase db, {IdentitySecretStore? secrets}) => IdentityCrudNotifier(
      db.identitiesDao, secrets ?? IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);

  /// A key in [db] with [password] saved with it (none: nothing saved),
  /// tried after it, and two hosts it signs in to: h-mine, which this
  /// account may change (in an Orchard, the Crate new items go to), and
  /// h-team, in a Crate it may only connect from. In an Orchard the key is
  /// put in [keyCrate], as the sync engine leaves it.
  Future<Identity> key(AppDatabase db, {String? password = saved, String? keyCrate}) async {
    final id = await crudOf(db).create(label: 'deploy key', username: 'deploy', authMethod: 'publicKey', password: password);
    await (db.update(db.identities)..where((i) => i.id.equals(id)))
        .write(const IdentitiesCompanion(passwordAfterKey: Value(true)));
    final at = DateTime(2026, 10, 15);
    for (final host in ['h-mine', 'h-team']) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: host, label: host, host: '$host.example.com', identityId: Value(id), createdAt: at, updatedAt: at));
    }
    if (db.isOrchard) {
      await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      await db.customStatement(
          'INSERT OR REPLACE INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES '
          "('key', ?, ?, 1), ('host', 'h-mine', ?, 1), ('host', 'h-team', ?, 1)",
          [id, keyCrate ?? kFixtureCrateId, kFixtureCrateId, _hostsConnect]);
      await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
    }
    return (await db.identitiesDao.getById(id))!;
  }

  /// The fetch for [identity] in [db], to the host [hostId], with the
  /// person's answers: whether it is them ([itIsYou]; null: never asked)
  /// and the password they type ([typed]; null: they cancel). What they
  /// were asked is kept in [asked].
  Future<String> fetch(
    AppDatabase db,
    Identity identity,
    String hostId, {
    bool? itIsYou,
    PasswordPromptResult? typed,
    List<String>? asked,
    List<String>? log,
    IdentitySecretStore? secrets,
    ScreenCarrierRoute? carrier,
  }) =>
      passwordAfterKeyIn(
        db,
        identity,
        connectionId: hostId,
        host: '$hostId.example.com',
        port: 22,
        username: 'deploy',
        crud: crudOf(db, secrets: secrets),
        askItIsYou: (destination) async {
          asked?.add('it is you, for $destination');
          if (itIsYou == null) fail('asked whether it is the person');
          return itIsYou;
        },
        askForIt: (why) async {
          asked?.add('the password${why == null ? '' : ': $why'}');
          return typed;
        },
        onLog: log?.add,
        carrier: carrier,
      );

  Matcher refusedWith(String message) =>
      throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', message));

  test('your Tree: the password saved with the key, read, and nothing asked', () async {
    final asked = <String>[];
    final log = <String>[];
    final identity = await key(tree);
    expect(await fetch(tree, identity, 'h-mine', asked: asked, log: log), saved);
    expect(asked, isEmpty);
    expect(log, [
      'identity: The server asks for a password: the one saved with the key...',
      'identity: Password saved with the key loaded for deploy',
    ]);
  });

  test('an Orchard password this account may not see goes only to a host it cannot change', () async {
    final identity = await key(orchard, keyCrate: _keysConnect);
    final asked = <String>[];
    await expectLater(fetch(orchard, identity, 'h-mine', asked: asked), refusedWith(en.orchardPasswordWrongHost));
    expect(asked, isEmpty, reason: 'nothing asked, and nothing read');
    expect(await fetch(orchard, identity, 'h-team', asked: asked), saved);
    expect(asked, isEmpty);
  });

  test('one from a Crate that asks again goes to a host this account may change once the person confirms it is '
      'them, once for each address', () async {
    final identity = await key(orchard, keyCrate: _keysAsk);
    final asked = <String>[];
    await expectLater(
        fetch(orchard, identity, 'h-mine', itIsYou: false, asked: asked), refusedWith(en.orchardPasswordNotConfirmed));
    expect(asked, ['it is you, for h-mine.example.com:22']);
    asked.clear();
    expect(await fetch(orchard, identity, 'h-mine', itIsYou: true, asked: asked), saved);
    expect(asked, ['it is you, for h-mine.example.com:22']);
    asked.clear();
    expect(await fetch(orchard, identity, 'h-mine', asked: asked), saved, reason: 'confirmed for this address');
    expect(await fetch(orchard, identity, 'h-team', asked: asked), saved, reason: 'a host someone else keeps');
    expect(asked, isEmpty);
  });

  // Found in a security review: a remote screen's carrier
  // decides where its password goes as surely as the screen does.
  test('a remote screen through a carrier this account may change: a hidden password is refused, and one that asks '
      'again asks for the route', () async {
    const carrier = (id: 'h-mine', via: 'h-mine.example.com:22');
    final hidden = await key(orchard, keyCrate: _keysConnect);
    final asked = <String>[];
    expect(await fetch(orchard, hidden, 'h-team', asked: asked), saved, reason: 'straight to a host someone else keeps');
    await expectLater(fetch(orchard, hidden, 'h-team', asked: asked, carrier: carrier),
        refusedWith(en.orchardPasswordWrongHost));
    expect(asked, isEmpty, reason: 'nothing asked, and nothing read');
  });

  test('a remote screen whose key asks again: asked for its address through its carrier, and again through another',
      () async {
    final identity = await key(orchard, keyCrate: _keysAsk);
    final asked = <String>[];
    expect(await fetch(orchard, identity, 'h-team', asked: asked, itIsYou: true,
        carrier: (id: 'h-mine', via: 'h-mine.example.com:22')), saved);
    expect(asked, ['it is you, for h-mine.example.com:22 \u2192 h-team.example.com:22']);
    asked.clear();
    expect(await fetch(orchard, identity, 'h-team', asked: asked, carrier: (id: 'h-mine', via: 'h-mine.example.com:22')),
        saved, reason: 'confirmed for this route');
    expect(asked, isEmpty);
    // The same screen through another carrier (or the carrier re-pointed): asked again.
    expect(await fetch(orchard, identity, 'h-team', asked: asked, itIsYou: true,
        carrier: (id: 'h-mine', via: 'evil.example.com:22')), saved);
    expect(asked, ['it is you, for evil.example.com:22 \u2192 h-team.example.com:22']);
  });

  test('none saved: it is asked for, and saved with the key where the person says so', () async {
    final identity = await key(tree, password: null);
    final asked = <String>[];
    final log = <String>[];
    expect(
        await fetch(tree, identity, 'h-mine',
            typed: const PasswordPromptResult(password: 'typed-once'), asked: asked, log: log),
        'typed-once');
    expect(asked, ['the password']);
    expect(log.last, 'identity: No password is saved with the key, asking for it...');
    expect(await crudOf(tree).getPassword(identity.id), isNull, reason: 'not to be saved');
    expect(
        await fetch(tree, identity, 'h-mine',
            typed: const PasswordPromptResult(password: 'typed-and-kept', saveToIdentity: true), log: log),
        'typed-and-kept');
    expect(await crudOf(tree).getPassword(identity.id), 'typed-and-kept');
    expect(log.last, 'identity: Password saved with the key');
  });

  test('cancelled where it is asked for: a cancel', () async {
    final identity = await key(tree, password: null);
    await expectLater(fetch(tree, identity, 'h-mine'), throwsA(isA<ConnectionCancelledException>()));
  });

  test('one that cannot be read is asked for, with why, and the log says what the storage said', () async {
    final identity = await key(tree);
    final asked = <String>[];
    final log = <String>[];
    expect(
        await fetch(tree, identity, 'h-mine',
            secrets: _Unreadable(), typed: const PasswordPromptResult(password: 'typed-once'), asked: asked, log: log),
        'typed-once');
    expect(asked, ['the password: ${en.connSavedPasswordUnreadable}']);
    expect(log.last,
        'identity: The password saved with the key could not be read (PlatformException: -25300: no such item), asking for it...');
  });

  test("a key's Crate that closed on this device meanwhile: nothing is asked in its place", () async {
    final identity = await key(tree);
    final asked = <String>[];
    await expectLater(
        fetch(tree, identity, 'h-mine', secrets: _Closed(), asked: asked), throwsA(isA<CrateClosedOffline>()));
    expect(asked, isEmpty);
  });

  test('a password typed for a key this account may not change is not saved with it', () async {
    // At Connect in the Orchard, to a host someone else keeps: it may go
    // there, and it may not be written back.
    final identity = await key(orchard, password: null, keyCrate: _keysConnect);
    final log = <String>[];
    expect(
        await fetch(orchard, identity, 'h-team',
            typed: const PasswordPromptResult(password: 'typed-and-kept', saveToIdentity: true), log: log),
        'typed-and-kept');
    expect(await crudOf(orchard).getPassword(identity.id), isNull);
    // Not tried and refused (which the log would call a failure to save):
    // not tried at all.
    expect(log.last, 'identity: No password is saved with the key, asking for it...');
  });
}

/// Secure storage that fails to read, as it does on a device that lost its
/// keychain entry.
class _Unreadable implements IdentitySecretStore {
  @override
  Future<String?> read(String identityId, IdentitySecret secret) async =>
      throw PlatformException(code: '-25300', message: 'no such item');

  @override
  Future<void> write(String identityId, IdentitySecret secret, String? value) async {}

  @override
  Future<void> deleteAll(String identityId) async {}
}

/// An Orchard's secrets of a Crate its offline limit closed meanwhile.
class _Closed implements IdentitySecretStore {
  @override
  Future<String?> read(String identityId, IdentitySecret secret) async =>
      throw const CrateClosedOffline(crateId: _keysConnect, hours: 24, message: 'closed on this device');

  @override
  Future<void> write(String identityId, IdentitySecret secret, String? value) async {}

  @override
  Future<void> deleteAll(String identityId) async {}
}
