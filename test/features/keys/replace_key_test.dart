import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/keys/authorized_keys_edit.dart';
import 'package:zestssh/features/keys/replace_key.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/key_generation_service.dart';

/// Replace on all hosts (3.0, Keys), its steps in order, on hosts played
/// here (each an authorized_keys file the commands read and write as sh
/// would): the old key's line goes only after the new key proved itself,
/// one host's failure never touches another, a host whose old key has
/// options is left before anything is added, a stop starts no new host,
/// and the old key is kept (named replaced) or deleted at the end. Against
/// real servers: replace_key_real_host_test.dart.
void main() {
  late String oldPem;
  late String oldLine;
  late String otherLine;
  late AppDatabase db;
  late ProviderContainer container;
  late Map<String, _PlayedHost> hosts;
  late Set<String> proofRefusedOn;
  late List<String> pointed;

  setUpAll(() async {
    final made = await KeyGenerationService().generateEd25519(comment: 'deploy');
    oldPem = made.privatePem;
    oldLine = made.publicOpenSSH.trim();
    otherLine = (await KeyGenerationService().generateEd25519(comment: 'ci')).publicOpenSSH.trim();
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-old': oldPem});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    hosts = {};
    proofRefusedOn = {};
    pointed = [];
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      replaceKeyRunWith(
        (ref) => ReplaceKeyDeps(
          openOld: (host) async {
            final h = hosts[host.id]!;
            if (h.refusesSignIn) throw StateError('Authentication failed');
            return h;
          },
          prove: (link, host, keys) async {
            if (proofRefusedOn.contains(host.id)) throw StateError('the new key was refused');
            // The new key is in the file by now.
            final line = '${keys.first.name} ${base64.encode(keys.first.toPublicKey().encode())}';
            expect(latin1.decode((link as _PlayedHost).file ?? Uint8List(0)), contains(line.split(' ')[1]));
          },
          skipBefore: (host, old) async => host.connectViaId != null ? ReplaceWhy.jumpHost : null,
          point: (host, {required oldId, required newId}) async {
            pointed.add(host.id);
            await pointHostAtNewKey(ref.read(databaseProvider), host, oldId: oldId, newId: newId);
          },
        ),
        atOnce: 1,
      ),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'id-old',
          label: 'deploy',
          username: 'ops',
          authMethod: 'publicKey',
          publicKeyData: Value(oldLine),
          createdAt: DateTime(2026, 10, 22),
        ));
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<Connection> host(String id, String file, {String? via, bool refuses = false}) async {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: '$id.example.invalid',
          identityId: const Value('id-old'),
          connectViaId: Value(via),
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        ));
    hosts[id] = _PlayedHost(file == '-' ? null : Uint8List.fromList(latin1.encode(file)), refusesSignIn: refuses);
    return (await db.connectionsDao.getById(id))!;
  }

  Future<ReplaceRun> run(List<Connection> on) async {
    final old = (await db.identitiesDao.getById('id-old'))!;
    await container.read(replaceKeyRunProvider.notifier).start(old, on, type: KeyType.ed25519, newLabel: 'deploy (new)');
    return container.read(replaceKeyRunProvider)!;
  }

  ReplaceHost of(ReplaceRun r, String id) => r.hosts.firstWhere((h) => h.host.id == id);

  test('done: the old line goes after the proof, the rest stays, the host points at the new key', () async {
    final a = await host('a', '# keys\n$otherLine\n$oldLine\n');
    final r = await run([a]);
    final newLine = (await db.identitiesDao.getById(r.newId!))!.publicKeyData!.trim();
    expect(of(r, 'a').step, ReplaceStep.done);
    expect(of(r, 'a').removed, 1);
    expect(latin1.decode(hosts['a']!.file!), '# keys\n$otherLine\n$newLine\n');
    expect(hosts['a']!.commands, ['read', 'add', 'read', 'write'], reason: 'read, add, (proof), read again, write');
    expect((await db.connectionsDao.getById('a'))!.identityId, r.newId);
    expect(r.allDone, isTrue);
  });

  test('the new key not proved: the old line stays, the host keeps the old key; the others go on', () async {
    final a = await host('a', '$oldLine\n');
    final b = await host('b', '$oldLine\n');
    proofRefusedOn.add('a');
    final r = await run([a, b]);
    expect(of(r, 'a').step, ReplaceStep.failed);
    expect(of(r, 'a').why, ReplaceWhy.proofFailed);
    expect(latin1.decode(hosts['a']!.file!), startsWith('$oldLine\n'), reason: 'the old key still lets it in');
    expect(hosts['a']!.commands, isNot(contains('write')));
    expect((await db.connectionsDao.getById('a'))!.identityId, 'id-old');
    expect(of(r, 'b').step, ReplaceStep.done);
    expect(pointed, ['b']);
  });

  test('the old key with options: skipped before anything is added', () async {
    final a = await host('a', 'from="10.1.0.0/16" $oldLine\n');
    final r = await run([a]);
    expect(of(r, 'a').step, ReplaceStep.skipped);
    expect(of(r, 'a').why, ReplaceWhy.oldWithOptions);
    expect(of(r, 'a').details, contains('line 1'));
    expect(hosts['a']!.commands, ['read']);
    expect(latin1.decode(hosts['a']!.file!), 'from="10.1.0.0/16" $oldLine\n');
  });

  test('a host that does not sign in, and one behind a jump host, are left; nothing is run on them', () async {
    final a = await host('a', '$oldLine\n', refuses: true);
    final b = await host('b', '$oldLine\n', via: 'a');
    final r = await run([a, b]);
    expect(of(r, 'a').why, ReplaceWhy.signInFailed);
    expect(of(r, 'a').details, contains('Authentication failed'));
    expect(of(r, 'b').why, ReplaceWhy.jumpHost);
    expect(hosts['a']!.commands, isEmpty);
    expect(hosts['b']!.commands, isEmpty);
  });

  test('a file changed between the read and the write is not written', () async {
    final a = await host('a', '$oldLine\n');
    hosts['a']!.changeBeforeWrite = '$otherLine\n';
    final r = await run([a]);
    expect(of(r, 'a').why, ReplaceWhy.changedMeanwhile);
    expect(latin1.decode(hosts['a']!.file!), contains(oldLine.split(' ')[1]));
    expect((await db.connectionsDao.getById('a'))!.identityId, 'id-old');
  });

  test('the old key not in the file: done, said, nothing written', () async {
    final a = await host('a', '-');
    final r = await run([a]);
    expect(of(r, 'a').step, ReplaceStep.done);
    expect(of(r, 'a').why, ReplaceWhy.oldNotFound);
    expect(hosts['a']!.commands, isNot(contains('write')));
  });

  test('run again: the same new key, and only the hosts not done', () async {
    final a = await host('a', '$oldLine\n');
    final b = await host('b', '$oldLine\n');
    proofRefusedOn.add('b');
    final first = await run([a, b]);
    proofRefusedOn.clear();
    hosts['a']!.commands.clear();
    await container.read(replaceKeyRunProvider.notifier).again();
    final second = container.read(replaceKeyRunProvider)!;
    expect(second.newId, first.newId);
    expect(of(second, 'b').step, ReplaceStep.done);
    expect(hosts['a']!.commands, isEmpty, reason: 'a done host is not run again');
    // Opened again later: the new key made the first time.
    container.read(replaceKeyRunProvider.notifier).clear();
    final c = await host('c', '$oldLine\n');
    final third = await run([c]);
    expect(third.newId, first.newId);
    expect(await db.identitiesDao.getAll(), hasLength(2));
  });

  test('finished: the old key kept, named replaced; or deleted', () async {
    final a = await host('a', '$oldLine\n');
    await run([a]);
    await container.read(replaceKeyRunProvider.notifier).finish(deleteOld: false, replacedLabel: 'deploy (replaced)');
    expect((await db.identitiesDao.getById('id-old'))!.label, 'deploy (replaced)');
    expect(container.read(replaceKeyRunProvider), isNull);

    final b = await host('b', '$oldLine\n');
    await run([b]);
    await container.read(replaceKeyRunProvider.notifier).finish(deleteOld: true, replacedLabel: 'x');
    expect(await db.identitiesDao.getById('id-old'), isNull);
    expect(await container.read(identityCrudProvider).getPrivateKey('id-old'), isNull);
  });

  test('a stop starts no host whose turn has not come', () async {
    final a = await host('a', '$oldLine\n');
    final b = await host('b', '$oldLine\n');
    hosts['a']!.onRead = () => container.read(replaceKeyRunProvider.notifier).stop();
    final r = await run([a, b]);
    expect(of(r, 'a').step, ReplaceStep.done, reason: 'a host going is never left halfway');
    expect(of(r, 'b').step, ReplaceStep.stopped);
    expect(hosts['b']!.commands, isEmpty);
    expect(r.running, isFalse);
  });

  test('the kind of new key matches the old one', () {
    Identity id(String? type) => Identity(
          id: 'x',
          label: 'x',
          username: 'x',
          authMethod: 'publicKey',
          keyType: type,
          usesAgent: false,
          colorIndex: 0,
          isDefault: false,
          allowUnattended: false,
          passwordAfterKey: false,
          createdAt: DateTime(2026),
        );
    expect(replacementTypeFor(id('ed25519')), KeyType.ed25519);
    expect(replacementTypeFor(id('ssh-ed25519')), KeyType.ed25519);
    expect(replacementTypeFor(id('rsa-sha2-256')), KeyType.rsa4096);
    expect(replacementTypeFor(id('rsa2048')), KeyType.rsa2048);
    expect(replacementTypeFor(id('ecdsa-sha2-nistp384')), KeyType.ecdsaP384);
    expect(replacementTypeFor(id(null)), KeyType.ed25519);
  });
}

/// A host played here: its authorized_keys file, and the commands of the
/// replacement as sh would run them on it.
class _PlayedHost implements ReplaceLink {
  _PlayedHost(this.file, {this.refusesSignIn = false});

  Uint8List? file;
  final bool refusesSignIn;
  final commands = <String>[];

  /// Added to the file after it is read the second time, before the write.
  String? changeBeforeWrite;

  void Function()? onRead;

  @override
  String get user => 'ops';

  @override
  String get address => 'played.example.invalid';

  @override
  int get port => 22;

  @override
  bool get throughJumpHost => false;

  @override
  Future<({int? exitCode, Uint8List out, String err})> run(String command, {List<int>? input}) async {
    Uint8List said(String s) => Uint8List.fromList(latin1.encode(s));
    if (command.contains(kAkBegin)) {
      commands.add('read');
      onRead?.call();
      final now = file;
      if (now == null) return (exitCode: 0, out: said('$kAkNone\n'), err: '');
      final out = Uint8List.fromList([...said('$kAkSum ${posixCksum(now)}\n$kAkBegin\n'), ...now]);
      if (commands.where((c) => c == 'read').length == 2 && changeBeforeWrite != null) {
        file = Uint8List.fromList([...now, ...latin1.encode(changeBeforeWrite!)]);
      }
      return (exitCode: 0, out: out, err: '');
    }
    if (command.contains('ZESTSSH_KEY_ADDED')) {
      commands.add('add');
      final line = utf8.decode(input!).trim();
      final now = latin1.decode(file ?? Uint8List(0));
      if (now.contains(line.split(' ').take(2).join(' '))) return (exitCode: 0, out: said('ZESTSSH_KEY_THERE\n'), err: '');
      file = Uint8List.fromList(latin1.encode('$now${now.isEmpty || now.endsWith('\n') ? '' : '\n'}$line\n'));
      return (exitCode: 0, out: said('ZESTSSH_KEY_ADDED\n'), err: '');
    }
    if (command.contains(kAkWritten)) {
      commands.add('write');
      final expected = RegExp(r'!= "([0-9]+ [0-9]+)"').firstMatch(command)!.group(1);
      if (posixCksum(file!) != expected) return (exitCode: 0, out: said('$kAkChanged\n'), err: '');
      file = Uint8List.fromList(input!);
      return (exitCode: 0, out: said('$kAkWritten ${posixCksum(file!)}\n'), err: '');
    }
    throw StateError('not a command of the replacement: $command');
  }

  @override
  Future<void> close() async {}
}
