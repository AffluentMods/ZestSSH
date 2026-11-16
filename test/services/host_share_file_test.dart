// A host shared as a `.zest` file (found while comparing the
// five versions): a phone's Share wrote one, and nothing in the app read one
// back. What reads one takes its address and its user as they are or not at
// all, as a share link's are, and keeps its names without what a name may
// not hold; a backup, a `.zest` file as well, is told from it. A host added
// from one goes into your Tree, its user a key of its own, its forwards
// saved and never started on their own, all of it or none.

import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/models/enums.dart' show KeyType;
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/backup_service.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';

/// The type and the key of a public line, without what is said after them.
String _bare(String line) => line.split(' ').take(2).join(' ');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late Directory temp;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    temp = Directory.systemTemp.createTempSync('zest_host_share_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    try {
      temp.deleteSync(recursive: true);
    } catch (_) {}
  });

  final now = DateTime.utc(2026, 10, 16);

  /// A sender's host web 01 (port 2222, its colour, compression and
  /// keep-alive), with the key deploy key (user deploy, a password key whose
  /// password is saved) and a forward started on its own there.
  Future<({Connection host, Identity key, List<PortForwardRule> forwards, IdentityCrudNotifier crud})> sender(
      AppDatabase db) async {
    final crud = IdentityCrudNotifier(
        db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
    final keyId =
        await crud.create(label: 'deploy key', username: 'deploy', authMethod: 'password', password: 'hunter2-hunter2');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c1',
          label: 'web 01',
          host: 'web-01.example.com',
          port: const Value(2222),
          identityId: Value(keyId),
          colorIndex: const Value(3),
          zlibCompression: const Value(true),
          keepAliveSeconds: const Value(30),
          createdAt: now,
          updatedAt: now,
        ));
    await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
      id: 'f1',
      connectionId: 'c1',
      type: 'local',
      bindAddress: const Value('127.0.0.1'),
      bindPort: 8080,
      remoteHost: 'db.internal',
      remotePort: 80,
      autoStart: const Value(true),
      label: const Value('web'),
      createdAt: now,
    ));
    return (
      host: (await db.connectionsDao.getById('c1'))!,
      key: (await db.identitiesDao.getById(keyId))!,
      forwards: await db.portForwardRulesDao.getByConnection('c1'),
      crud: crud,
    );
  }

  /// A file holding [json], as someone may send one.
  String file(Object json, {String name = 'host.zest'}) {
    final f = File('${temp.path}${Platform.pathSeparator}$name')..writeAsStringSync(jsonEncode(json));
    return f.path;
  }

  /// A host file's JSON, plain, with [connection] and [identity] over its
  /// defaults.
  Map<String, Object?> plain({Map<String, Object?> connection = const {}, Map<String, Object?>? identity, List<Object?>? forwards}) => {
        'version': 1,
        'type': 'zestssh_connection',
        'connection': {'label': 'web 01', 'host': 'web-01.example.com', 'port': 22, 'protocol': 'ssh', ...connection},
        'identity': ?identity,
        'portForwards': ?forwards,
      };

  group('what a file is', () {
    test('one a host was shared into is a shared host, sealed where it carries a secret; a backup and anything else '
        'are not', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final s = await sender(db);
      final plainPath = await ConnectionShareService.exportConnection(
          connection: s.host, identity: s.key, portForwardRules: s.forwards);
      final plainBytes = File(plainPath).readAsBytesSync();
      expect(ConnectionShareService.isShareFile(plainBytes), isTrue);
      expect(ConnectionShareService.isSealedShare(plainBytes), isFalse);
      expect(BackupService.isBackupFile(plainBytes), isFalse);

      final sealedPath = await ConnectionShareService.exportConnection(
          connection: s.host,
          identity: s.key,
          portForwardRules: s.forwards,
          password: 'hunter2-hunter2',
          encryptionPassword: 'a long enough password');
      final sealedBytes = File(sealedPath).readAsBytesSync();
      expect(ConnectionShareService.isShareFile(sealedBytes), isTrue);
      expect(ConnectionShareService.isSealedShare(sealedBytes), isTrue);
      expect(utf8.decode(sealedBytes), isNot(contains('hunter2')), reason: 'sealed');

      // A backup of any version starts ZEST and a version.
      for (final version in [1, 2, 3]) {
        final backup = [...utf8.encode('ZEST'), version, ...utf8.encode('{"type":"zestssh_connection"}')];
        expect(ConnectionShareService.isShareFile(backup), isFalse);
        expect(BackupService.isBackupFile(backup), isTrue);
      }
      for (final other in [
        utf8.encode('ZEST,host\nweb,web1.example.com\n'),
        utf8.encode('ZESTY notes\n'),
        utf8.encode('{}'),
        utf8.encode('{"type":"zestssh_backup"}'),
        utf8.encode('[1, 2]'),
        utf8.encode('not json'),
        const <int>[0xff, 0xfe, 0x00],
        const <int>[],
        utf8.encode(jsonEncode({'type': 'zestssh_connection', 'pad': 'x' * ConnectionShareService.maxFileBytes})),
      ]) {
        expect(ConnectionShareService.isShareFile(other), isFalse, reason: utf8.decode(other.take(30).toList(), allowMalformed: true));
        expect(BackupService.isBackupFile(other), isFalse);
      }
    });

    test('a host read back is the host shared, and what was sealed with it comes only with its password', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final s = await sender(db);
      final path = await ConnectionShareService.exportConnection(
          connection: s.host,
          identity: s.key,
          portForwardRules: s.forwards,
          password: await s.crud.getPassword(s.key.id),
          encryptionPassword: 'a long enough password');
      await expectLater(ConnectionShareService.importConnection(path), throwsFormatException);
      expect(await ConnectionShareService.importConnection(path, decryptionPassword: 'not the password'), isNull);
      final read = (await ConnectionShareService.importConnection(path, decryptionPassword: 'a long enough password'))!;
      expect((read.label, read.host, read.port, read.protocol), ('web 01', 'web-01.example.com', 2222, 'ssh'));
      expect((read.colorIndex, read.zlibCompression, read.keepAliveSeconds), (3, true, 30));
      expect((read.username, read.identityLabel, read.password), ('deploy', 'deploy key', 'hunter2-hunter2'));
      expect(read.privateKeyPem, isNull);
      expect(read.isEncrypted, isTrue);
      expect(read.portForwards, hasLength(1));
      final f = read.portForwards.single;
      expect((f.type, f.bindAddress, f.bindPort, f.remoteHost, f.remotePort, f.label), ('local', '127.0.0.1', 8080, 'db.internal', 80, 'web'));
    });
  });

  group('a file someone sent', () {
    Future<ZestImportData> read(Map<String, Object?> json) async =>
        (await ConnectionShareService.importConnection(file(json)))!;

    test('an address or a user that is not plain is refused, as in a share link', () async {
      for (final (why, json) in [
        ('no address', plain(connection: {'host': ''})),
        ('an address that reads backwards', plain(connection: {'host': 'moc.elpmaxe\u202E.web'})),
        ('an address with a line in it', plain(connection: {'host': 'web-01\u0085.example.com'})),
        ('a user over two lines', plain(identity: {'username': 'ops\nroot'})),
        ('a user with a character that is not there', plain(identity: {'username': 'o\u200Bps'})),
        ('more forwards than run at once', plain(forwards: [
          for (var i = 0; i <= ConnectionShareService.maxForwards; i++)
            {'type': 'local', 'bindAddress': '127.0.0.1', 'bindPort': 8000 + i, 'remoteHost': 'db', 'remotePort': 80},
        ])),
      ]) {
        await expectLater(ConnectionShareService.importConnection(file(json)), throwsFormatException, reason: why);
      }
      // Nor a file larger than any shared host.
      final big = file({...plain(), 'pad': 'x' * ConnectionShareService.maxFileBytes});
      await expectLater(ConnectionShareService.importConnection(big), throwsFormatException);
    });

    test('its names keep what a name may hold, and no more than a name may be', () async {
      final read1 = await read(plain(
        connection: {'label': '\u202Eweb 10\n'},
        identity: {'username': 'deploy', 'label': '\u2066admin\u2069 key'},
      ));
      expect(read1.label, 'web 10');
      expect(read1.identityLabel, 'admin key');
      expect((await read(plain(connection: {'label': 'x' * 300}))).label, hasLength(255));
      // Clipped where a character of two halves would be cut: the whole one or none.
      final astral = await read(plain(connection: {'label': '${'x' * 254}\u{1F34B}'}));
      expect(astral.label, 'x' * 254);
      expect((await read(plain(connection: {'label': '\u202E\n'}))).label, 'web-01.example.com', reason: 'nothing left');
      expect((await read({...plain(), 'connection': {'host': 'web-01.example.com'}})).label, 'web-01.example.com');
      expect((await read(plain(identity: {'username': ''}))).username, isNull);
    });

    test("a keep-alive no person set is none, or a day's", () async {
      expect((await read(plain(connection: {'keepAliveSeconds': -5}))).keepAliveSeconds, 0);
      expect((await read(plain(connection: {'keepAliveSeconds': 999999999999}))).keepAliveSeconds, 86400);
      expect((await read(plain(connection: {'keepAliveSeconds': 45}))).keepAliveSeconds, 45);
    });

    test('a forward whose address is not plain is left out; its name keeps what a name may hold', () async {
      final read1 = await read(plain(forwards: [
        {'type': 'local', 'bindAddress': '127.0.0.1\u202E', 'bindPort': 8080, 'remoteHost': 'db', 'remotePort': 80},
        {'type': 'dynamic', 'bindAddress': '127.0.0.1', 'bindPort': 1080, 'remoteHost': '', 'remotePort': 0, 'label': 'socks\u200F'},
      ]));
      expect(read1.portForwards, hasLength(1));
      expect((read1.portForwards.single.type, read1.portForwards.single.label), ('dynamic', 'socks'));
    });
  });

  group('added', () {
    ZestImportData shared(
            {String? username = 'deploy',
            String? password,
            String? pem,
            String? keyType,
            String label = 'web 01',
            List<ZestPortForward>? forwards}) =>
        ZestImportData(
          label: label,
          host: 'web-01.example.com',
          port: 2222,
          protocol: 'ssh',
          colorIndex: 3,
          zlibCompression: true,
          keepAliveSeconds: 30,
          identityLabel: 'deploy key',
          username: username,
          keyType: keyType,
          password: password,
          privateKeyPem: pem,
          portForwards: forwards ??
              const [
                ZestPortForward(
                    type: 'local', bindAddress: '127.0.0.1', bindPort: 8080, remoteHost: 'db.internal', remotePort: 80, autoStart: true, label: 'web'),
              ],
        );

    test('a forward shared bound to every address is bound to this device alone here; one bound here is kept as it '
        'came (before, it opened its port to the network once started)', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final id = await addSharedHost(db, const FlutterSecureStorage(), shared(forwards: const [
        ZestPortForward(type: 'local', bindAddress: '0.0.0.0', bindPort: 8080, remoteHost: 'db.internal', remotePort: 80, autoStart: true),
        ZestPortForward(type: 'dynamic', bindAddress: '::', bindPort: 1080, remoteHost: '', remotePort: 0, autoStart: false),
        ZestPortForward(type: 'local', bindAddress: '192.168.10.5', bindPort: 8081, remoteHost: 'db.internal', remotePort: 81, autoStart: false),
        ZestPortForward(type: 'local', bindAddress: '::1', bindPort: 8082, remoteHost: 'db.internal', remotePort: 82, autoStart: false),
        ZestPortForward(type: 'local', bindAddress: 'localhost', bindPort: 8083, remoteHost: 'db.internal', remotePort: 83, autoStart: false),
      ]));
      final forwards = await db.portForwardRulesDao.getByConnection(id);
      expect({for (final f in forwards) f.bindPort: f.bindAddress},
          {8080: '127.0.0.1', 1080: '127.0.0.1', 8081: '127.0.0.1', 8082: '::1', 8083: 'localhost'});
      expect(forwards.where((f) => f.autoStart || f.gatewayPorts), isEmpty);
    });

    test('into your Tree, its user a key of its own with the key and the password that came, the password tried '
        'after the key; its forwards saved, not started', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final made = await KeyGenerationService().generate(KeyType.ed25519);
      final id = await addSharedHost(db, const FlutterSecureStorage(), shared(password: 'hunter2-hunter2', pem: made.privatePem));
      final host = (await db.connectionsDao.getById(id))!;
      expect((host.label, host.host, host.port, host.protocol), ('web 01', 'web-01.example.com', 2222, 'ssh'));
      expect((host.colorIndex, host.zlibCompression, host.keepAliveSeconds), (3, true, 30));
      final key = (await db.identitiesDao.getById(host.identityId!))!;
      expect((key.label, key.username, key.authMethod, key.passwordAfterKey), ('deploy key', 'deploy', 'publicKey', true));
      // Its fingerprint as importing the key anywhere in the app gives it.
      expect((key.keyType, key.publicKeyFingerprint), ('ssh-ed25519', KeyImportService().importOpenSSHKey(made.privatePem).fingerprint));
      expect(key.publicKeyFingerprint, startsWith(made.fingerprint));
      expect(key.publicKeyData, '${_bare(made.publicOpenSSH)} deploy key');
      final crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
      expect(await crud.getPrivateKey(key.id), made.privatePem);
      expect(await crud.getPassword(key.id), 'hunter2-hunter2');
      final forwards = await db.portForwardRulesDao.getByConnection(id);
      expect([for (final f in forwards) (f.type, f.bindAddress, f.bindPort, f.remoteHost, f.remotePort, f.label, f.autoStart)],
          [('local', '127.0.0.1', 8080, 'db.internal', 80, 'web', false)]);
    });

    test('a user with nothing sealed becomes a key that asks for its password; no user, no key; a key sealed under '
        'a passphrase the file does not carry is kept as it came', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final crud = IdentityCrudNotifier(
          db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);

      final asks = (await db.connectionsDao.getById(await addSharedHost(db, const FlutterSecureStorage(), shared())))!;
      final asking = (await db.identitiesDao.getById(asks.identityId!))!;
      expect((asking.username, asking.authMethod, asking.passwordAfterKey), ('deploy', 'password', false));
      expect(await crud.getPassword(asking.id), isNull);

      final alone = (await db.connectionsDao.getById(await addSharedHost(db, const FlutterSecureStorage(), shared(username: null))))!;
      expect(alone.identityId, isNull);

      final pem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/id_ed25519')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      final kept = (await db.connectionsDao.getById(
          await addSharedHost(db, const FlutterSecureStorage(), shared(pem: pem, keyType: 'ssh-ed25519'))))!;
      final sealed = (await db.identitiesDao.getById(kept.identityId!))!;
      expect((sealed.authMethod, sealed.keyType, sealed.publicKeyFingerprint, sealed.publicKeyData),
          ('publicKey', 'ssh-ed25519', null, null));
      expect(await crud.getPrivateKey(sealed.id), pem);
      expect(await db.identitiesDao.getAll(), hasLength(2), reason: 'the host with no user made none');
    });

    test('all of it or none: a host that cannot be saved leaves no key behind', () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      // (A name longer than a saved name may be, as no file read gives.)
      await expectLater(addSharedHost(db, const FlutterSecureStorage(), shared(password: 'hunter2-hunter2', label: 'x' * 300)),
          throwsA(anything));
      expect(await db.identitiesDao.getAll(), isEmpty);
      expect(await db.connectionsDao.getAll(), isEmpty);
    });
  });
}
