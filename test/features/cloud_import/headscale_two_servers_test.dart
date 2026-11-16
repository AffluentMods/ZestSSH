import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/cloud_accounts.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';

/// Two kept Headscale accounts. Each server
/// numbers its nodes from 1, and the node's number was kept as the machine
/// id, so node 1 of the second server was taken for the host imported from
/// node 1 of the first: the unattended check rewrote that host's address and
/// name to the other server's machine, and the second server's node was never
/// added. A node is now known by its server and its number; a host an earlier
/// version linked by the bare number is still found, by its own account only.
void main() {
  late AppDatabase db;
  final at = DateTime.utc(2026, 11, 5, 9);

  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  CloudAccount headscale(String id, String label, String server) => CloudAccount(
        id: id,
        provider: CloudProvider.tailscale,
        label: label,
        fields: {CloudField.server: server, CloudField.token: 'hskey-made-up-$id'},
      );

  // Two separate Headscale servers, scanned as a kept account scans them:
  // /api/v1/node on each numbers its nodes from 1.
  Future<List<CloudMachine>> scanOf(String server, Map<String, Object?> node) => scanHeadscale(
        CloudHttp(MockClient((req) async => http.Response(jsonEncode({'nodes': [node]}), 200))),
        server,
        'hskey-made-up',
      );
  Future<List<CloudMachine>> homeNodes({String address = '100.64.0.1'}) => scanOf('https://hs.home.example', {
        'id': '1',
        'givenName': 'nas',
        'ipAddresses': [address],
        'online': true,
      });
  Future<List<CloudMachine>> workNodes() => scanOf('https://hs.work.example', {
        'id': '1',
        'givenName': 'build',
        'ipAddresses': ['100.64.0.7'],
        'online': true,
      });

  final home = headscale('a1', 'Home', 'https://hs.home.example');
  final work = headscale('a2', 'Work', 'https://hs.work.example');

  test('a second Headscale server adds its own node and leaves the first server\'s host alone', () async {
    await checkCloudAccount(home, db, scan: (_, _) => homeNodes(), now: () => at);
    final afterHome = await db.connectionsDao.getAll();
    expect(afterHome.map((c) => (c.label, c.host)), [('nas', '100.64.0.1')]);

    final result = await checkCloudAccount(work, db, scan: (_, _) => workNodes(), now: () => at);
    final hosts = {for (final c in await db.connectionsDao.getAll()) c.label: c};
    expect(result.outcome.updated, 0, reason: 'nothing of the Home server changed');
    expect(result.outcome.added, 1, reason: 'the Work server\'s node 1 is another machine');
    expect(hosts.keys.toSet(), {'nas', 'build'});
    expect(hosts['nas']?.host, '100.64.0.1');
    expect(CloudLink.decode(hosts['nas']?.cloudSource)?.label, 'Home');
    expect(CloudLink.decode(hosts['build']?.cloudSource)?.machineId, 'hs.work.example:443/1');

    // Checked again, each server keeps to its own host.
    final again = await checkCloudAccount(home, db, scan: (_, _) => homeNodes(), now: () => at);
    expect((again.outcome.added, again.outcome.updated), (0, 0));
  });

  group('a host an earlier version imported from a Headscale node (linked by its bare number)', () {
    Future<void> earlierImport() => db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-nas',
          label: 'nas',
          host: '100.64.0.1',
          createdAt: at,
          updatedAt: at,
          cloudSource: Value(const CloudLink(
            provider: CloudProvider.tailscale,
            machineId: '1',
            label: 'Home',
            address: '100.64.0.1',
            name: 'nas',
          ).encode()),
        ));

    test('is the same machine for its own account: not added again, not gone, and moved with the node', () async {
      await earlierImport();
      final unchanged = await checkCloudAccount(home, db, scan: (_, _) => homeNodes(), now: () => at);
      expect((unchanged.outcome.added, unchanged.outcome.updated), (0, 0));
      expect(await db.connectionsDao.getAll(), hasLength(1));
      expect(CloudLink.decode((await db.connectionsDao.getAll()).single.cloudSource)?.gone, isFalse);

      final moved = await checkCloudAccount(home, db, scan: (_, _) => homeNodes(address: '100.64.0.9'), now: () => at);
      expect(moved.outcome.updated, 1);
      final host = (await db.connectionsDao.getAll()).single;
      expect(host.host, '100.64.0.9');
      expect(CloudLink.decode(host.cloudSource)?.machineId, 'hs.home.example:443/1', reason: 'its link now names the server');
    });

    test('is not the other server\'s node 1', () async {
      await earlierImport();
      final result = await checkCloudAccount(work, db, scan: (_, _) => workNodes(), now: () => at);
      expect((result.outcome.added, result.outcome.updated), (1, 0));
      final nas = (await db.connectionsDao.getAll()).firstWhere((c) => c.id == 'h-nas');
      expect((nas.label, nas.host), ('nas', '100.64.0.1'));
    });
  });
}
