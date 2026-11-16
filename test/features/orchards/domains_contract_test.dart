import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// Proving a domain against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js and lib/orchard_domains.js) on a real Postgres (3.0):
/// an owner claims a domain, the check finds nothing until the
/// TXT record is there, then proves it; another Orchard cannot take it; a
/// member sees it without the record; dropping a proven one wants a recent
/// sign-in. The contract server's DNS is the test's (PUT /test/dns/...).
/// Start the server first:
///
///   node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

class _Account {
  _Account(this.uid, this.service, this.domains, this.signedInAt);

  final String uid;
  final OrchardService service;
  final OrchardDomainsApi domains;
  final Map<String, int> signedInAt;

  String get email => '$uid@example.com';
}

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.replaceFirst(RegExp(r'/v1$'), '');
  final client = http.Client();
  var serverUp = false;
  final opened = <_MemoryStorage>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/orchards')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  tearDown(() async {
    for (final s in opened) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    opened.clear();
  });

  var made = 0;

  Future<_Account> account(String name) async {
    final uid = 'domains-$name-$contractRun-${made++}';
    final signedInAt = <String, int>{};
    Future<String> token() async => 'fb:$uid:${signedInAt['at'] ?? now()}:${now()}';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: token),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final storage = _MemoryStorage();
    opened.add(storage);
    final service = OrchardService(
      server: OrchardsApi(client: client, baseUrl: base, bearer: token),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(uid, service, OrchardDomainsApi(client: client, baseUrl: base, bearer: token), signedInAt);
  }

  Future<void> publish(String domain, List<String> records) async {
    final r = await client.put(Uri.parse('$root/test/dns/$domain'),
        headers: {'Content-Type': 'application/json'}, body: jsonEncode({'records': records}));
    expect(r.statusCode, 200);
  }

  Matcher refused(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  test('claim, prove, keep it from others, show it to members, and drop it after a fresh sign-in', () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final owner = await account('owner');
    final alice = await account('alice');
    final other = await account('other');
    final orchard = await owner.service.createOrchard('Domains', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = (await owner.service.roles(orchard)).single.id;
    await owner.service.invite(orchard, email: alice.email, role: role);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);

    final domain = 'd${now()}${made++}.example';
    final claim = await owner.domains.claim(orchard, domain.toUpperCase());
    expect((claim.domain, claim.verified), (domain, false));
    final txt = claim.txt!;
    expect(txt, startsWith('zestssh-verify='));
    await expectLater(owner.domains.verify(orchard, domain),
        throwsA(isA<DomainNotProven>().having((e) => e.txt, 'txt', txt)));
    await publish(domain, ['v=spf1 -all', txt]);
    final proven = await owner.domains.verify(orchard, domain);
    expect(proven.verified, isTrue);

    final seen = (await alice.domains.list(orchard)).single;
    expect((seen.domain, seen.verified, seen.txt), (domain, true, null));
    await expectLater(alice.domains.claim(orchard, 'x${now()}.example'), refused('forbidden'));

    final theirs = await other.service.createOrchard('Other', firstCrateName: 'Main', memberRoleName: 'Member');
    await expectLater(other.domains.claim(theirs, domain), refused('domain-taken'));

    owner.signedInAt['at'] = now() - 3 * 3600;
    await expectLater(owner.domains.drop(orchard, domain), refused('recent-sign-in-required'));
    owner.signedInAt.remove('at');
    await owner.domains.drop(orchard, domain);
    expect(await owner.domains.list(orchard), isEmpty);
  });
}
