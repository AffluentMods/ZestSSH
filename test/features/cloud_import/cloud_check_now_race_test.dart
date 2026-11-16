import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/providers/core_providers.dart';

/// "Check now" on a kept cloud account ran beside the timed check (checkAll,
/// a minute after unlock and every 30 minutes): checkAll's guard covered only
/// checkAll, so both planned against the hosts as they were before either
/// wrote, and each added the new machines: every new machine became two hosts.
/// Checks now run one at a time, and "Check
/// now" on an account whose check is running waits for that one.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late List<Completer<void>> gates;
  late List<String> scanned;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    gates = [];
    scanned = [];
    container = ProviderContainer(overrides: [
      cloudAccountsProvider.overrideWith((ref) => CloudAccountsController(
            ref,
            ref.watch(cloudAccountStoreProvider),
            scan: (provider, fields) async {
              scanned.add(fields[CloudField.token]!);
              final gate = Completer<void>();
              gates.add(gate);
              await gate.future; // the provider's API, taking its time
              final n = fields[CloudField.token] == 'dop_v1_made-up-a1' ? 10 : 20;
              return [
                CloudMachine(provider: CloudProvider.digitalocean, id: '${n}1', name: 'web$n', publicAddress: '203.0.113.$n', user: 'root'),
                CloudMachine(provider: CloudProvider.digitalocean, id: '${n}2', name: 'db$n', publicAddress: '203.0.113.${n + 1}', user: 'root'),
              ];
            },
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<CloudAccountsController> keep(List<String> ids) async {
    final c = container.read(cloudAccountsProvider.notifier);
    for (final id in ids) {
      await c.keep(CloudAccount(
          id: id, provider: CloudProvider.digitalocean, label: 'DO $id', fields: {CloudField.token: 'dop_v1_made-up-$id'}));
    }
    return c;
  }

  Future<void> openGatesUntil(Future<void> done) async {
    var finished = false;
    unawaited(done.whenComplete(() => finished = true));
    for (var i = 0; i < 500 && !finished; i++) {
      for (final g in gates) {
        if (!g.isCompleted) g.complete();
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  test('Check now during the timed check does not add each new machine twice', () async {
    final c = await keep(['a1']);
    final timed = c.checkAll(); // the timer's check
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final now = c.checkOne('a1'); // the person's "Check now", meanwhile
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await openGatesUntil(Future.wait([timed, now]));

    final hosts = await db.connectionsDao.getAll();
    expect(hosts.map((h) => h.host).toList()..sort(), ['203.0.113.10', '203.0.113.11'], reason: 'one host per machine');
    expect(scanned, hasLength(1), reason: 'Check now waited for the check of the same account');
    expect((await now)?.added, 2, reason: 'it answers with what that check did');
  });

  test('Check now on another account while the timed check runs: one scan at a time, each machine once', () async {
    final c = await keep(['a1', 'a2']);
    final timed = c.checkAll();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final now = c.checkOne('a2');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(scanned, ['dop_v1_made-up-a1'], reason: 'the second waits for the first to finish');
    await openGatesUntil(Future.wait([timed, now]));

    final hosts = await db.connectionsDao.getAll();
    expect(hosts.map((h) => h.host).toList()..sort(), ['203.0.113.10', '203.0.113.11', '203.0.113.20', '203.0.113.21']);
  });

  test('a check that is over can be asked for again', () async {
    final c = await keep(['a1']);
    final first = c.checkOne('a1');
    await openGatesUntil(first);
    final second = c.checkOne('a1');
    await openGatesUntil(second);
    expect(scanned, hasLength(2));
    expect((await db.connectionsDao.getAll()), hasLength(2));
  });
}
