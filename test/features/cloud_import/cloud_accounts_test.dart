import 'dart:async';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_tls.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/core_providers.dart';

/// Cloud import (3.0), kept accounts: the token stays in this device's secure
/// storage; a check adds new machines, updates moved ones and marks gone
/// ones on its own, never links a look-alike or adds a phone; a failed check
/// says why without losing the last good one; forgetting deletes the token.

CloudAccount _account({String id = 'a1', Map<String, String> fields = const {CloudField.token: 'dop_v1_secret'}}) =>
    CloudAccount(id: id, provider: CloudProvider.digitalocean, label: 'DO main', fields: fields, groupName: 'DO main');

CloudMachine _d(String id, String name, String address, {CloudOs os = CloudOs.linux}) =>
    CloudMachine(provider: CloudProvider.digitalocean, id: id, name: name, publicAddress: address, os: os, user: 'root');

void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late List<CloudMachine> listed;
  late Object? failWith;
  var scans = 0;
  final at = DateTime.utc(2026, 9, 26, 9);

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    listed = [];
    failWith = null;
    scans = 0;
    container = ProviderContainer(overrides: [
      cloudAccountsProvider.overrideWith((ref) => CloudAccountsController(
            ref,
            ref.watch(cloudAccountStoreProvider),
            scan: (provider, fields) async {
              scans++;
              expect(fields[CloudField.token], 'dop_v1_secret');
              if (failWith != null) throw failWith!;
              return listed;
            },
            now: () => at,
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  CloudAccountsController controller() => container.read(cloudAccountsProvider.notifier);

  test('kept in secure storage only, read back as kept, and forgetting deletes it', () async {
    await controller().keep(_account());
    const storage = FlutterSecureStorage();
    final raw = await storage.read(key: CloudAccountStore.key);
    expect(raw, contains('dop_v1_secret'));
    expect(container.read(cloudAccountsProvider).single.label, 'DO main');
    final fresh = await CloudAccountStore(storage).load();
    expect(fresh.single.fields[CloudField.token], 'dop_v1_secret');
    await controller().forget('a1');
    expect(await storage.read(key: CloudAccountStore.key), isNull, reason: 'the token is gone from this device');
    expect(container.read(cloudAccountsProvider), isEmpty);
  });

  test('a check adds new machines, never phones or Windows or a look-alike, and records when and how many', () async {
    await db.connectionsDao.insertConnection(
        ConnectionsCompanion.insert(id: 'mine', label: 'mine', host: '9.9.9.9', createdAt: at, updatedAt: at));
    await controller().keep(_account());
    listed = [
      _d('1', 'web', '1.1.1.1'),
      _d('2', 'win', '2.2.2.2', os: CloudOs.windows),
      _d('3', 'looks like mine', '9.9.9.9'),
    ];
    final outcome = await controller().checkOne('a1');
    expect(outcome!.added, 1);
    expect(outcome.linked, 0);
    final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c};
    expect(hosts.keys.toSet(), {'mine', 'web'});
    expect(hosts['mine']!.cloudSource, isNull, reason: 'linking a look-alike is the person\'s call');
    final kept = container.read(cloudAccountsProvider).single;
    expect(kept.checkedAt, at);
    expect(kept.found, 3);
    expect(kept.problem, isNull);
  });

  test('later checks update moved machines and mark gone ones', () async {
    await controller().keep(_account());
    listed = [_d('1', 'web', '1.1.1.1'), _d('2', 'db', '2.2.2.2')];
    await controller().checkOne('a1');
    listed = [_d('1', 'web', '1.1.1.9')];
    final outcome = await controller().checkOne('a1');
    expect((outcome!.updated, outcome.gone, outcome.added), (1, 1, 0));
    final by = {for (final c in await db.connectionsDao.getAll()) c.label: c};
    expect(by['web']!.host, '1.1.1.9');
    expect(CloudLink.decode(by['db']!.cloudSource)!.gone, isTrue);
  });

  test('a failed check says why and keeps the last good check', () async {
    await controller().keep(_account());
    listed = [_d('1', 'web', '1.1.1.1')];
    await controller().checkOne('a1');
    failWith = CloudError(CloudErrorKind.signIn, status: 401, detail: 'GET https://api.digitalocean.com/v2/droplets -> 401');
    expect(await controller().checkOne('a1'), isNull);
    final kept = container.read(cloudAccountsProvider).single;
    expect(kept.problem, CloudErrorKind.signIn);
    expect(kept.problemDetail, contains('-> 401'));
    expect(kept.checkedAt, at, reason: 'the last good check');
    expect(kept.found, 1);
    // And a check that goes through again clears it.
    failWith = null;
    await controller().checkOne('a1');
    expect(container.read(cloudAccountsProvider).single.problem, isNull);
  });

  test('checking everything twice at once checks once; an account forgotten meanwhile is not brought back', () async {
    await controller().keep(_account());
    final gate = Completer<void>();
    container.dispose();
    container = ProviderContainer(overrides: [
      cloudAccountsProvider.overrideWith((ref) => CloudAccountsController(
            ref,
            ref.watch(cloudAccountStoreProvider),
            scan: (provider, fields) async {
              scans++;
              await gate.future;
              return [_d('1', 'web', '1.1.1.1')];
            },
            now: () => at,
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
    final c = container.read(cloudAccountsProvider.notifier);
    final one = c.checkAll();
    final two = c.checkAll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await c.forget('a1');
    gate.complete();
    await Future.wait([one, two]);
    expect(scans, 1);
    expect(await CloudAccountStore(const FlutterSecureStorage()).load(), isEmpty);
  });

  test("an account that brought hosts into a team goes with the team once it left this device, and the team's "
      'database is not made anew', () async {
    const team = '0f7c3a52-5a1e-4c2b-9d0e-3b8f6a1c2d4e';
    final storage = _NoTeams();
    container.dispose();
    container = ProviderContainer(overrides: [
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      cloudAccountsProvider.overrideWith((ref) => CloudAccountsController(
            ref,
            ref.watch(cloudAccountStoreProvider),
            scan: (provider, fields) async {
              scans++;
              return [_d('1', 'web', '1.1.1.1')];
            },
            now: () => at,
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
    final c = container.read(cloudAccountsProvider.notifier);
    await c.keep(const CloudAccount(
        id: 'a1',
        provider: CloudProvider.digitalocean,
        label: 'DO main',
        fields: {CloudField.token: 'dop_v1_secret'},
        groupName: 'DO main',
        spaceId: team));
    expect(await c.checkOne('a1'), isNull);
    expect(scans, 0, reason: 'nothing was asked of the cloud for a team that is gone');
    expect(storage.opened, isEmpty, reason: 'its database is not made again');
    expect(await CloudAccountStore(const FlutterSecureStorage()).load(), isEmpty, reason: 'the token went with it');
  }, skip: !kOrchardsEnabled);

  test('damaged storage reads as nothing kept, never a crash', () async {
    FlutterSecureStorage.setMockInitialValues({CloudAccountStore.key: 'not json'});
    expect(await CloudAccountStore(const FlutterSecureStorage()).load(), isEmpty);
    FlutterSecureStorage.setMockInitialValues({CloudAccountStore.key: '[{"id":"x","provider":"gcp","fields":{}}, 5]'});
    expect(await CloudAccountStore(const FlutterSecureStorage()).load(), isEmpty);
  });

  group('the scan for each provider', () {
    test('Proxmox: an address that is not https, or a token that is not one, stops before any request', () async {
      var made = 0;
      http.Client client(Uri? base, String? pin) {
        made++;
        return MockClient((req) async => http.Response('{}', 200));
      }

      await expectLater(
        scanCloud(CloudProvider.proxmox, {CloudField.url: 'http://pve', CloudField.token: 'root@pam!z=u'}, clientFor: client),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.notFound)),
      );
      await expectLater(
        scanCloud(CloudProvider.proxmox, {CloudField.url: 'pve', CloudField.token: 'password'}, clientFor: client),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.signIn)),
      );
      expect(made, 0);
    });

    test('Proxmox: the client is made for that address with the confirmed certificate', () async {
      Uri? base;
      String? pin;
      await scanCloud(
        CloudProvider.proxmox,
        {CloudField.url: '192.168.20.10', CloudField.token: 'root@pam!z=u', CloudField.pin: 'AB:CD'},
        clientFor: (b, p) {
          base = b;
          pin = p;
          return MockClient((req) async => http.Response('{"data":[]}', 200));
        },
      );
      expect(base, Uri.parse('https://192.168.20.10:8006'));
      expect(pin, 'AB:CD');
    });

    test('Proxmox: a confirmed certificate that no longer answers is said to have changed, with both fingerprints', () async {
      const pinned = 'AA:AA';
      Future<List<CloudMachine>> scan(String now) => scanCloud(
            CloudProvider.proxmox,
            {CloudField.url: '192.168.20.10', CloudField.token: 'root@pam!z=u', CloudField.pin: pinned},
            clientFor: (b, p) => MockClient((req) async => throw const HandshakeException('CERTIFICATE_VERIFY_FAILED')),
            probe: (base) async => CloudCertificate(sha256: now, subject: 'CN=pve', issuer: 'CN=pve'),
          );
      try {
        await scan('BB:BB');
        fail('no error');
      } on CloudError catch (e) {
        expect(e.kind, CloudErrorKind.certificateChanged);
        expect(e.detail, contains('AA:AA'));
        expect(e.detail, contains('BB:BB'));
      }
      // The same certificate: something else is wrong with it, not a change.
      await expectLater(scan(pinned), throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.certificate)));
    });

    test('AWS: regions that are not region names stop it', () async {
      await expectLater(
        scanCloud(CloudProvider.aws, {CloudField.keyId: 'AKIAIOSFODNN7EXAMPLE', CloudField.secret: 's', CloudField.regions: 'evil.example'},
            clientFor: (b, p) => MockClient((req) async => http.Response('', 200))),
        throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.notFound)),
      );
    });

    test('the token is blanked from what a failure says', () async {
      try {
        await scanCloud(CloudProvider.hetzner, {CloudField.token: 'hz-secret-token'},
            clientFor: (b, p) => MockClient((req) async => http.Response('token hz-secret-token is invalid', 401)));
        fail('no error');
      } on CloudError catch (e) {
        expect(e.detail, isNot(contains('hz-secret-token')));
      }
    });
  });

  test('unattended checks only add, update and mark', () {
    final rows = [
      for (final s in CloudRowStatus.values) CloudRow(status: s, selected: true),
    ];
    expect(unattendedRows(rows).map((r) => r.status).toSet(), {CloudRowStatus.fresh, CloudRowStatus.changed, CloudRowStatus.gone});
  });
}

/// A device that holds no team: whatever is opened is noted.
class _NoTeams implements OrchardDatabaseStorage {
  final opened = <String>[];

  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    opened.add(orchardId);
    return AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
  }

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}
