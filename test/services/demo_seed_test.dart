import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/services/demo_seed.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';

/// The debug-only demo data seed for marketing footage (lib/services/demo_seed.dart):
/// it fills an empty install with the made-up world, and never touches a
/// database that holds anything, nor runs in a build not asked for it.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late SharedPreferences prefs;
  late IdentitySecretStore secrets;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    secrets = IdentitySecretStore.forDatabase(db, const FlutterSecureStorage());
  });
  tearDown(() => db.close());

  DemoSeed seed() => DemoSeed(db: db, prefs: prefs, secrets: secrets);

  test('a build without the flag never seeds: kDemoSeed is false and seedDemoIfAsked writes nothing', () async {
    // The suite runs without --dart-define=ZEST_DEMO_SEED=true, as every
    // build does unless asked; a release or profile build has kDebugMode false.
    expect(kDemoSeed, isFalse);
    expect(await seedDemoIfAsked(db: db, prefs: prefs, secrets: secrets), isNull);
    expect(await db.connectionsDao.getAll(), isEmpty);
    expect(prefs.getKeys(), isEmpty);
    expect(await DemoSeed.isEmpty(db), isTrue);
  });

  test('an empty database is filled with the demo world', () async {
    final result = await seed().fillIfEmpty();
    expect(result, isNotNull);
    expect(result!.hosts, 12);
    expect(result.keys, 2);

    final hosts = await db.connectionsDao.getAll();
    expect(hosts.map((h) => h.label).toSet(), {
      'web-01', 'web-02', 'db-primary', 'cache-01', 'log-store', 'monitoring', //
      'build-runner', 'edge-router', 'hypervisor-a', 'hypervisor-b', 'mac-studio', 'vpn-gateway',
    });
    // Made-up private addresses only (demo_hosts.ssh_config), each host with
    // its system known and an account to sign in with.
    for (final h in hosts) {
      expect(h.host, matches(RegExp(r'^192\.168\.(10|20)\.\d+$')), reason: h.label);
      expect(prefs.getString('os_kind_${h.id}'), isNotNull, reason: h.label);
      expect(h.identityId, isNotNull, reason: h.label);
    }
    expect(prefs.getString('os_kind_demo-mac-studio'), 'macos');
    expect(prefs.getString('os_kind_demo-edge-router'), 'openwrt');

    final groups = await db.connectionGroupsDao.getAll();
    expect(groups.map((g) => g.name), containsAll(['Web', 'Databases', 'Hypervisors']));
    final web = groups.singleWhere((g) => g.name == 'Web');
    expect(hosts.where((h) => h.groupId == web.id).map((h) => h.label).toSet(), {'web-01', 'web-02'});
    final hv = groups.singleWhere((g) => g.name == 'Hypervisors');
    expect(hosts.where((h) => h.groupId == hv.id).map((h) => h.label).toSet(), {'hypervisor-a', 'hypervisor-b'});

    // Two Ed25519 keys, each with its private half in the app's secret
    // store, which opens as an SSH key whose public half is the one shown.
    final ids = await db.identitiesDao.getAll();
    final keys = ids.where((i) => i.authMethod == 'publicKey').toList();
    expect(keys.map((k) => k.label).toSet(), {'Ops laptop', 'Build key'});
    for (final k in keys) {
      expect(k.keyType, 'Ed25519');
      expect(k.publicKeyData, startsWith('ssh-ed25519 '));
      expect(k.publicKeyFingerprint, startsWith('SHA256:'));
      final pem = await secrets.read(k.id, IdentitySecret.privateKey);
      expect(pem, contains('BEGIN OPENSSH PRIVATE KEY'));
      final pair = SSHKeyPair.fromPem(pem!).single;
      expect(base64.encode(pair.toPublicKey().encode()), k.publicKeyData!.split(' ')[1]);
    }
    expect(keys[0].publicKeyData, isNot(keys[1].publicKeyData));
    // The two password accounts keep no password: it is asked for.
    for (final p in ids.where((i) => i.authMethod == 'password')) {
      expect(await secrets.read(p.id, IdentitySecret.password), isNull);
    }

    expect((await db.snippetsDao.getAll()).length, result.snippets);
    expect(result.snippets, greaterThan(5));
    final forwards = await db.select(db.portForwardRules).get();
    expect(forwards.map((f) => f.label), contains('Grafana'));
    expect(forwards.every((f) => hosts.any((h) => h.id == f.connectionId)), isTrue);
    final alerts = await db.select(db.terminalTriggers).get();
    expect(alerts, isNotEmpty);
    for (final a in alerts) {
      // As the Alerts page compiles a rule: `(?i)` is read as its flag.
      expect(triggerRegExp(a.pattern, caseSensitive: a.caseSensitive), isNotNull, reason: a.name);
    }
    expect(triggerRegExp(alerts.singleWhere((a) => a.name == 'Error').pattern, caseSensitive: false)!.hasMatch('Build FAILED'), isTrue);
    final history = await db.select(db.commandHistory).get();
    expect(history.length, greaterThan(5));
    expect(history.every((e) => hosts.any((h) => h.id == e.connectionId && h.label == e.hostLabel)), isTrue);

    // Three workspaces, every pane a demo host.
    final raw = await LocalStateStore(db).read(kSavedTabGroupsKey);
    final workspaces = [for (final m in jsonDecode(raw!) as List) SavedTabGroup.fromJson(m as Map<String, dynamic>)!];
    expect(workspaces.map((w) => w.name), ['Deploy', 'Database night', 'Morning check']);
    for (final w in workspaces) {
      for (final t in w.tabs) {
        for (final leaf in t.paneTreeOfConnIds.allLeaves) {
          for (final id in leaf.sessionIds) {
            expect(hosts.any((h) => h.id == id), isTrue, reason: '${w.name}: $id');
          }
        }
      }
    }

    // A guest past the first-run screens.
    expect(prefs.getBool('onboarding_complete'), isTrue);
    expect(await DemoSeed.isEmpty(db), isFalse);
  });

  test('the keys are made fresh on every install, never a stored key', () async {
    await seed().fillIfEmpty();
    final first = {for (final k in await db.identitiesDao.getAll()) if (k.publicKeyData != null) k.publicKeyData!};

    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    await DemoSeed(db: other, prefs: prefs, secrets: IdentitySecretStore.forDatabase(other, const FlutterSecureStorage()))
        .fillIfEmpty();
    final second = {for (final k in await other.identitiesDao.getAll()) if (k.publicKeyData != null) k.publicKeyData!};
    expect(first, hasLength(2));
    expect(second, hasLength(2));
    expect(first.intersection(second), isEmpty);
  });

  test('a database with a host of its own is left as it is', () async {
    final at = DateTime(2026, 11, 1);
    await db.connectionsDao.insertConnection(ConnectionsCompanion(
      id: const Value('mine'),
      label: const Value('my-server'),
      host: const Value('10.0.0.5'),
      createdAt: Value(at),
      updatedAt: Value(at),
    ));
    expect(await seed().fillIfEmpty(), isNull);
    expect((await db.connectionsDao.getAll()).map((h) => h.id), ['mine']);
    expect(await db.identitiesDao.getAll(), isEmpty);
    expect(await db.snippetsDao.getAll(), isEmpty);
    expect(await LocalStateStore(db).read(kSavedTabGroupsKey), isNull);
    expect(prefs.getKeys(), isEmpty);
  });

  test('any other data a person made also stops it: a snippet, a key, a workspace', () async {
    final at = DateTime(2026, 11, 1);
    await db.snippetsDao.insertSnippet(SnippetsCompanion(
      id: const Value('s'),
      label: const Value('uptime'),
      command: const Value('uptime'),
      createdAt: Value(at),
      updatedAt: Value(at),
    ));
    expect(await seed().fillIfEmpty(), isNull);
    expect(await db.connectionsDao.getAll(), isEmpty);

    final db2 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db2.close);
    await db2.into(db2.identities).insert(
        IdentitiesCompanion.insert(id: 'i', label: 'mine', username: 'me', authMethod: 'password', createdAt: at));
    expect(await DemoSeed.isEmpty(db2), isFalse);

    final db3 = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db3.close);
    await LocalStateStore(db3).write(kSavedTabGroupsKey, '[]');
    expect(await DemoSeed.isEmpty(db3), isFalse);
  });

  test('a seeded database is never seeded again, also once everything in it was deleted', () async {
    expect(await seed().fillIfEmpty(), isNotNull);
    expect(await seed().fillIfEmpty(), isNull);
    expect((await db.connectionsDao.getAll()).length, 12);

    await db.delete(db.portForwardRules).go();
    await db.delete(db.commandHistory).go();
    await db.delete(db.terminalTriggers).go();
    await db.delete(db.snippets).go();
    await db.delete(db.connectionTags).go();
    await db.delete(db.connections).go();
    await db.delete(db.connectionGroups).go();
    await db.delete(db.identities).go();
    await LocalStateStore(db).remove(kSavedTabGroupsKey);
    expect(await seed().fillIfEmpty(), isNull);
    expect(await db.connectionsDao.getAll(), isEmpty);
  });
}
