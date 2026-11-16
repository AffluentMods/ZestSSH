import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/orchard_directory_view.dart';
import 'package:zestssh/features/teams/account_key_service.dart';

import '../../helpers/contract_run.dart';

/// Directory sync against the REAL server routes (ZestSSH Cloud's
/// routes/orchards.js and routes/scim.js) on a real Postgres (3.0):
/// an owner turns it on once a domain is proven and gets the token
/// once; the "directory" (this test, over SCIM) deactivates a member, who is
/// held back at once, and adds a group; the owner maps the group to a role,
/// acts on the removal with the usual signed change, and sets it aside; the
/// token can be replaced; turning it off lets everyone back. Start the
/// contract server first:
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
  _Account(this.uid, this.domain, this.server, this.service, this.directory, this.domains);

  final String uid;
  final String domain;
  final OrchardsApi server;
  final OrchardService service;
  final OrchardDirectoryApi directory;
  final OrchardDomainsApi domains;

  String get email => '$uid@$domain';
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

  Future<_Account> account(String name, String domain) async {
    final uid = 'dir-$name-$contractRun-${made++}';
    Future<String> token() async => 'fb:$uid:${now()}:${now()}::$domain';
    final keyService = AccountKeyService(
      api: AccountKeysApi(client: client, baseUrl: base, bearer: token),
      store: AccountKeyStore(const FlutterSecureStorage()),
      onKeysChanged: () {},
    );
    expect(await keyService.ensureKeys(), AccountKeyStatus.ready);
    final storage = _MemoryStorage();
    opened.add(storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: token);
    final service = OrchardService(
      server: server,
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async {
        final ready = await keyService.readyKeys();
        return ready == null ? null : CrateAuthor(uid: ready.uid, keys: ready.keys);
      },
    );
    return _Account(uid, domain, server, service, OrchardDirectoryApi(client: client, baseUrl: base, bearer: token),
        OrchardDomainsApi(client: client, baseUrl: base, bearer: token));
  }

  Future<void> prove(_Account owner, String orchardId, String domain) async {
    final claim = await owner.domains.claim(orchardId, domain);
    final r = await client.put(Uri.parse('$root/test/dns/$domain'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'records': [claim.txt],
        }));
    expect(r.statusCode, 200);
    expect((await owner.domains.verify(orchardId, domain)).verified, isTrue);
  }

  /// A call as the company's directory.
  Future<Map<String, dynamic>> scim(String url, String token, String method, String path, Object body) async {
    final request = http.Request(method, Uri.parse('$url$path'))
      ..headers.addAll({'Authorization': 'Bearer $token', 'Content-Type': 'application/scim+json'})
      ..body = jsonEncode(body);
    final r = await http.Response.fromStream(await client.send(request));
    expect(r.statusCode, anyOf(200, 201), reason: r.body);
    return jsonDecode(r.body) as Map<String, dynamic>;
  }

  Matcher refused(String code) => throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', code));

  test('on once a domain is proven; a removal held at once, acted on and set aside; a group mapped; off again',
      () async {
    if (!serverUp) return markTestSkipped('app contract server not running at $base');
    final domain = 'dir${now()}${made++}.example';
    final owner = await account('owner', domain);
    final alice = await account('alice', domain);
    final orchard = await owner.service.createOrchard('Directory', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = (await owner.service.roles(orchard)).single.id;
    await owner.service.invite(orchard, email: alice.email, role: member);
    await alice.service.acceptInvite((await alice.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchard, (await owner.service.invites(orchard)).single);

    expect((await owner.directory.get(orchard)).enabled, isFalse);
    await expectLater(owner.directory.enable(orchard), refused('domain-required'));
    await prove(owner, orchard, domain);
    final on = await owner.directory.enable(orchard);
    expect(on.scimUrl, '$root/scim/v2/$orchard');
    expect(on.token, isNotEmpty);
    await expectLater(owner.directory.enable(orchard), refused('directory-on'));
    await expectLater(alice.directory.get(orchard), refused('forbidden'));

    // The directory turns Alice off and sends a group.
    await scim(on.scimUrl, on.token, 'POST', '/Users', {
      'schemas': ['urn:ietf:params:scim:schemas:core:2.0:User'],
      'userName': alice.email,
      'active': false,
      'emails': [
        {'primary': true, 'value': alice.email},
      ],
    });
    final group = await scim(on.scimUrl, on.token, 'POST', '/Groups', {
      'schemas': ['urn:ietf:params:scim:schemas:core:2.0:Group'],
      'displayName': 'Engineering',
      'members': const [],
    });
    var seen = await owner.directory.get(orchard);
    expect(seen.enabled, isTrue);
    expect(seen.lastContact, isNotNull);
    expect(seen.groups.single.name, 'Engineering');
    final removal = seen.pending.single;
    expect((removal.kind, removal.email, removal.uid), (DirectoryChangeKind.remove, alice.email, alice.uid));
    expect(seen.held.map((h) => h.uid), [alice.uid], reason: 'held back at once, before anyone acts');
    await expectLater(alice.server.record(orchard, after: 0), refused('directory-removed'));
    // Her list says so of this Orchard, and reads (it threw, and every
    // Orchard of hers stopped refreshing).
    expect((await alice.server.orchards()).singleWhere((o) => o.id == orchard).status, 'directory-removed');

    // The group gives the Member role.
    final mapped = await owner.directory.mapGroup(orchard, group['id'] as String, member);
    expect(mapped.role, member);
    await expectLater(owner.directory.mapGroup(orchard, group['id'] as String, 'owner'), refused('invalid-request'));

    // The removal still needs doing by the signed record; doing it, then
    // setting it aside.
    await owner.service.refresh();
    var people = await owner.service.people(orchard);
    expect(directoryChangeStillNeeded(removal, people.record), isTrue);
    await owner.service.removeMember(orchard, alice.uid);
    people = await owner.service.people(orchard);
    expect(people.record.members[alice.uid]!.status, MemberStatus.removed);
    expect(directoryChangeStillNeeded(removal, people.record), isFalse);
    await owner.directory.dismiss(orchard, removal.id);
    await owner.directory.dismiss(orchard, removal.id); // gone already: fine
    seen = await owner.directory.get(orchard);
    expect(seen.pending, isEmpty);

    // A new token; the old one stops.
    final next = await owner.directory.newToken(orchard);
    expect(next.token, isNot(on.token));
    final stale = await client.get(Uri.parse('${on.scimUrl}/Users'), headers: {'Authorization': 'Bearer ${on.token}'});
    expect(stale.statusCode, 401);

    await owner.directory.disable(orchard);
    expect((await owner.directory.get(orchard)).enabled, isFalse);
    await expectLater(owner.directory.disable(orchard), refused('directory-off'));
  });
}
