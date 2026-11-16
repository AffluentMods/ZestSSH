import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/models/saved_tab_group.dart' show kSavedTabGroupsKey;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/guest_tables.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_list.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_move.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';

import 'profile_world.dart';

/// A keychain that fails where it is told to, holds a write back, or runs something
/// just as everything is read.
class _Wrap implements FlutterSecureStorage {
  _Wrap(this.real, {this.failOn, this.gateOn, this.gate, this.reached, this.atSweep});
  final FlutterSecureStorage real;
  final bool Function(String)? failOn;
  final bool Function(String)? gateOn;
  final Completer<void>? gate;
  final Completer<void>? reached;

  /// Run once, at the first reading of everything after a secret was written (the
  /// sweep at the end of a restore).
  Future<void> Function()? atSweep;
  var _wrote = false;

  @override
  dynamic noSuchMethod(Invocation i) {
    final key = i.namedArguments[#key] as String?;
    if (i.memberName == #write) {
      final value = i.namedArguments[#value] as String?;
      _wrote = true;
      if (failOn?.call(key!) ?? false) return Future<void>.error(Exception('the keychain would not take it'));
      if (gateOn?.call(key!) ?? false) {
        return () async {
          if (!reached!.isCompleted) reached!.complete();
          await gate!.future;
          await real.write(key: key!, value: value);
        }();
      }
      return real.write(key: key!, value: value);
    }
    if (i.memberName == #read) return real.read(key: key!);
    if (i.memberName == #delete) return real.delete(key: key!);
    if (i.memberName == #readAll) {
      final hook = atSweep;
      if (hook != null && _wrote) {
        atSweep = null;
        return hook().then((_) => real.readAll());
      }
      return real.readAll();
    }
    if (i.memberName == #containsKey) return real.containsKey(key: key!);
    return super.noSuchMethod(i);
  }
}

/// Sync, played: a cycle stays in flight until it is let go.
class _PlayedSync implements AutoSyncService {
  final log = <String>[];
  Completer<void>? cycle;

  @override
  bool get isSuspended => false;

  @override
  Future<void> suspend() async {
    log.add('suspend');
    await cycle?.future;
    log.add('ended');
  }

  @override
  void resume() => log.add('resume');

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// Guest data comes into an account, and the guest profile goes: all that goes with it
/// was the only copy, and there is no undo (a review, with its
/// proofs turned into these). What is here stays unless what comes was changed later;
/// every secret reads back through the account's seal before anything is removed; every
/// table has a fate someone chose; a sync that runs meanwhile takes nothing.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const uid = 'account-sam';

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  SyncDataService serviceWith(AppDatabase db, FlutterSecureStorage storage) => SyncDataService(
        database: db,
        connectionsDao: db.connectionsDao,
        identitiesDao: db.identitiesDao,
        groupsDao: db.connectionGroupsDao,
        knownHostsDao: db.knownHostsDao,
        snippetsDao: db.snippetsDao,
        snippetCategoriesDao: db.snippetCategoriesDao,
        portForwardRulesDao: db.portForwardRulesDao,
        networksDao: db.networksDao,
        connectionTagsDao: db.connectionTagsDao,
        secureStorage: storage,
        settingsService: SettingsService(world.rawPrefs),
      );
  SyncDataService serviceOf(AppDatabase db, ActiveProfile profile) => serviceWith(db, world.keychainOf(profile, db));

  Future<(ProfileManager, AppDatabase)> guestWithHosts() async {
    final manager = world.launch();
    await manager.start();
    final db = await manager.openCurrent();
    SecretSeal.openTree = db;
    await addHost(db, 'guest-host-1');
    await addHost(db, 'guest-host-2');
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'guest-key',
          label: 'a key',
          username: 'demo',
          authMethod: 'publicKey',
          createdAt: DateTime.utc(2026, 10, 30),
        ));
    await world.keychainOf(Profiles.current!, db).write(key: 'identity_key_guest-key', value: 'PRIVATE KEY OF THE GUEST');
    return (manager, db);
  }

  Future<AppDatabase> signIn(ProfileManager manager, AppDatabase from) async {
    final prepared = await manager.prepare(await manager.planForAccount(uid: uid, label: 'sam@example.com', bearer: 'b'));
    await from.close();
    await manager.commit(prepared);
    SecretSeal.openTree = prepared.db;
    await manager.settleLockedCopy(db: prepared.db, bearer: 'b');
    return prepared.db;
  }

  SecureStorageIdentitySecrets secretsOf(AppDatabase db, FlutterSecureStorage keychain) =>
      SecureStorageIdentitySecrets(keychain, sealedBy: db);

  group('two copies of one thing', () {
    /// One id in guest data and in the account, each with its own password.
    Future<(ProfileManager, AppDatabase, FlutterSecureStorage)> bothHold({required DateTime guestAt, required DateTime accountAt}) async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final created = DateTime.utc(2026, 1, 1);
      await guest.into(guest.connections).insert(ConnectionsCompanion.insert(
          id: 'same', label: 'GUEST COPY', host: 'guest.example.com', createdAt: created, updatedAt: guestAt));
      await guest.into(guest.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'guest key', username: 'g', authMethod: 'password', createdAt: created, updatedAt: Value(guestAt)));
      await secretsOf(guest, world.keychainOf(Profiles.current!, guest)).write('same-key', IdentitySecret.password, 'GUEST PASSWORD');
      final db = await signIn(manager, guest);
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'same', label: 'ACCOUNT COPY', host: 'account.example.com', createdAt: created, updatedAt: accountAt));
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'account key', username: 'a', authMethod: 'password', createdAt: created, updatedAt: Value(accountAt)));
      final mine = world.keychainOf(Profiles.current!, db);
      await secretsOf(db, mine).write('same-key', IdentitySecret.password, 'ACCOUNT PASSWORD');
      return (manager, db, mine);
    }

    test("the account's is newer: it stands, with its password, and the next pull sends nothing of the guest's", () async {
      final (manager, db, mine) = await bothHold(guestAt: DateTime.utc(2026, 1, 2), accountAt: DateTime.utc(2026, 10, 30));
      final svc = serviceOf(db, Profiles.current!);
      final before = await svc.gatherAll();
      const key = [1, 2, 3, 4];
      final base = SyncDataService.itemHashes(before, key);

      await manager.bringGuestInto(svc, db: db, keychain: mine);

      expect((await db.connectionsDao.getById('same'))!.label, 'ACCOUNT COPY');
      expect((await db.connectionsDao.getById('same'))!.host, 'account.example.com');
      expect((await db.identitiesDao.getById('same-key'))!.label, 'account key');
      expect(await secretsOf(db, mine).read('same-key', IdentitySecret.password), 'ACCOUNT PASSWORD');

      final store = Map<String, dynamic>.from(before)
        ..remove('settings')
        ..remove('account_keys');
      final pulled = await svc.restoreAll(store, merge: SyncMergeBase(key: key, base: base));
      expect(pulled.keptHere, 0, reason: 'kept here is what goes to every device');
      await db.close();
    });

    test("the guest's is newer: it comes, with its password", () async {
      final (manager, db, mine) = await bothHold(guestAt: DateTime.utc(2026, 10, 30), accountAt: DateTime.utc(2026, 1, 2));
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect((await db.connectionsDao.getById('same'))!.label, 'GUEST COPY');
      expect((await db.identitiesDao.getById('same-key'))!.label, 'guest key');
      expect(await secretsOf(db, mine).read('same-key', IdentitySecret.password), 'GUEST PASSWORD');
      await db.close();
    });

    test('files held, the person edits, it is tried again: what they did stands', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      final logs = Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', guestId));
      await logs.create(recursive: true);
      final log = File(p.join(logs.path, 'held.log'));
      await log.writeAsString('open in an editor');
      final held = await log.open(mode: FileMode.append);
      await expectLater(
        manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine),
        Platform.isWindows ? throwsA(isA<GuestFilesHeld>()) : completes,
      );
      if (!Platform.isWindows) {
        await held.close();
        return db.close();
      }

      final later = DateTime.now().add(const Duration(minutes: 5));
      await (db.update(db.connections)..where((t) => t.id.equals('guest-host-1')))
          .write(ConnectionsCompanion(label: const Value('EDITED IN THE ACCOUNT'), updatedAt: Value(later)));
      // A saved secret changes with no time on its key's row.
      await secretsOf(db, mine).write('guest-key', IdentitySecret.privateKey, 'ROTATED KEY');
      await held.close();
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);

      expect((await db.connectionsDao.getById('guest-host-1'))!.label, 'EDITED IN THE ACCOUNT');
      expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), 'ROTATED KEY');
      expect(manager.list.byId(guestId), isNull);
      await db.close();
    });

    test('the store count of a guest does not come: its next look at its own store is no store gone back', () async {
      final (manager, guest) = await guestWithHosts();
      await serviceOf(guest, Profiles.current!).noteStoreCount(900);
      final db = await signIn(manager, guest);
      final svc = serviceOf(db, Profiles.current!);
      await manager.bringGuestInto(svc, db: db, keychain: world.keychainOf(Profiles.current!, db));
      expect((await svc.storeCountSeen()).count, 0);
      final stand = await svc.compareStoreCount({
        SyncDataService.storeCountField: 5,
        SyncDataService.storeCountAtField: DateTime.now().toUtc().subtract(const Duration(days: 1)).millisecondsSinceEpoch,
      });
      expect(stand.older, isFalse);
      expect(stand.wentBack, isFalse);
      await db.close();
    });
  });

  group('every secret reads back before anything goes', () {
    test('a key the keychain will not take: it throws, nothing of the guest goes, and it comes when tried again', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      final refusing = _Wrap(mine, failOn: (k) => k.contains('guest-key'));

      await expectLater(
        manager.bringGuestInto(serviceWith(db, refusing), db: db, keychain: refusing),
        throwsA(isA<GuestSecretsNotBrought>()),
      );
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      expect(world.rawNames(guestId), isNotEmpty);
      expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), isNull);

      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), 'PRIVATE KEY OF THE GUEST');
      expect(manager.list.byId(guestId), isNull);
      expect(await LocalStateStore(db).read('guest.secrets_owed'), isNull);
      await db.close();
    });

    test("a later copy whose secret would not be taken, over the account's older one: tried again, it arrives", () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final created = DateTime.utc(2026, 1, 1);
      await guest.into(guest.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'guest key', username: 'g', authMethod: 'password', createdAt: created, updatedAt: Value(DateTime.utc(2026, 10, 30))));
      await secretsOf(guest, world.keychainOf(Profiles.current!, guest)).write('same-key', IdentitySecret.password, 'THE LATER ONE');
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'account key', username: 'a', authMethod: 'password', createdAt: created, updatedAt: Value(DateTime.utc(2026, 1, 2))));
      final mine = world.keychainOf(Profiles.current!, db);
      await secretsOf(db, mine).write('same-key', IdentitySecret.password, 'THE OLDER ONE');
      final refusing = _Wrap(mine, failOn: (k) => k.contains('same-key'));

      await expectLater(
        manager.bringGuestInto(serviceWith(db, refusing), db: db, keychain: refusing),
        throwsA(isA<GuestSecretsNotBrought>()),
      );
      expect(manager.list.byId(guestId), isNotNull);
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(await secretsOf(db, mine).read('same-key', IdentitySecret.password), 'THE LATER ONE');
      expect(manager.list.byId(guestId), isNull);
      await db.close();
    });

    test('stopped between the rows and the secrets: run again, the later secret is not taken for the account\'s own', () async {
      final manager = world.launch();
      await manager.start();
      final guest = await manager.openCurrent();
      SecretSeal.openTree = guest;
      final created = DateTime.utc(2026, 1, 1);
      await guest.into(guest.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'guest key', username: 'g', authMethod: 'password', createdAt: created, updatedAt: Value(DateTime.utc(2026, 10, 30))));
      await secretsOf(guest, world.keychainOf(Profiles.current!, guest)).write('same-key', IdentitySecret.password, 'THE LATER ONE');
      final db = await signIn(manager, guest);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'same-key', label: 'account key', username: 'a', authMethod: 'password', createdAt: created, updatedAt: Value(DateTime.utc(2026, 1, 2))));
      final mine = world.keychainOf(Profiles.current!, db);
      await secretsOf(db, mine).write('same-key', IdentitySecret.password, 'THE OLDER ONE');

      // The restore's writes fail, and so the app ends where the secrets were to come.
      final refusing = _Wrap(mine, failOn: (k) => k.contains('same-key'));
      world.stop = (at) {
        if (at == 'guest:tables') throw const PlayedStop('here');
      };
      await expectLater(manager.bringGuestInto(serviceWith(db, refusing), db: db, keychain: refusing), throwsA(isA<PlayedStop>()));
      world.stop = null;
      expect(await secretsOf(db, mine).read('same-key', IdentitySecret.password), 'THE OLDER ONE');

      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(await secretsOf(db, mine).read('same-key', IdentitySecret.password), 'THE LATER ONE');
      await db.close();
    });

    test('a saved password past what a restore takes from outside: it comes, as it is', () async {
      final (manager, guest) = await guestWithHosts();
      await secretsOf(guest, world.keychainOf(Profiles.current!, guest)).write('guest-key', IdentitySecret.password, 'x' * 5000);
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect((await secretsOf(db, mine).read('guest-key', IdentitySecret.password))?.length, 5000);
      expect(manager.list.byId(guestId), isNull);
      await db.close();
    });

    test('a sealed secret that will not open: nothing moves, and nothing goes', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final name = world.device.kept.keys.firstWhere((k) => k.contains('identity_key_guest-key') && k.contains(guestId));
      final v = world.device.kept[name]!;
      expect(SecretSeal.isSealed(v), isTrue);
      world.device.kept[name] = '${v.substring(0, v.length - 8)}AAAAAAA=';
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      await expectLater(
        manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine),
        throwsA(isA<GuestSecretsNotBrought>()),
      );
      expect(manager.list.byId(guestId)!.state, ProfileState.open);
      expect(world.rawNames(guestId), isNotEmpty);
      expect(await hostsOf(db), isEmpty);
      await db.close();
    });

    test('a key this account deleted since is not asked about: that deletion stands', () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      await db.tombstonesDao.mark('identities', 'guest-key', at: DateTime.now().add(const Duration(days: 1)));
      final mine = world.keychainOf(Profiles.current!, db);
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(await db.identitiesDao.getById('guest-key'), isNull);
      expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), isNull);
      expect(manager.list.byId(guestId), isNull);
      await db.close();
    });
  });

  group('every table has a fate', () {
    /// One row of every table something is to come of, as a person's use leaves them.
    Future<void> seedEverything(AppDatabase g) async {
      final at = DateTime.utc(2026, 6, 1);
      await g.into(g.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g1', name: 'Prod', createdAt: at));
      await g.into(g.identities).insert(IdentitiesCompanion.insert(
          id: 'k1', label: 'k1', username: 'u', authMethod: 'publicKey', createdAt: at, allowUnattended: const Value(true), agentSocketPath: const Value('/run/agent.sock')));
      await g.into(g.identities).insert(IdentitiesCompanion.insert(id: 'k2', label: 'k2', username: 'u', authMethod: 'password', createdAt: at));
      await g.into(g.snippets).insert(SnippetsCompanion.insert(id: 's1', label: 'up', command: 'uptime', createdAt: at, updatedAt: at));
      await g.into(g.snippetCategories).insert(SnippetCategoriesCompanion.insert(name: 'ops'));
      await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'jump', label: 'jump', host: 'jump.example.com', createdAt: at, updatedAt: at, identityId: const Value('k1'), groupId: const Value('g1')));
      await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'h1', label: 'h1', host: 'h1.example.com', createdAt: at, updatedAt: at, identityId: const Value('k1'), groupId: const Value('g1'), connectViaId: const Value('jump'), snippetId: const Value('s1'), lastConnected: Value(at), monitored: const Value(true)));
      await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'local1', label: 'my shell', host: 'localhost', createdAt: at, updatedAt: at, protocol: const Value('localShell'), port: const Value(0)));
      await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'serial1', label: 'console', host: '/dev/ttyUSB0', createdAt: at, updatedAt: at, protocol: const Value('serial'), port: const Value(115200)));
      await g.into(g.connectionTags).insert(ConnectionTagsCompanion.insert(connectionId: 'h1', tag: 'prod', createdAt: at));
      await g.into(g.connectionTags).insert(ConnectionTagsCompanion.insert(connectionId: 'local1', tag: 'here', createdAt: at));
      await g.into(g.hostAccounts).insert(HostAccountsCompanion.insert(connectionId: 'h1', identityId: 'k2', position: 0));
      await g.into(g.networks).insert(NetworksCompanion.insert(id: 'n1', name: 'Home', iconCodePoint: 1, createdAt: at));
      await g.into(g.hostNetworkOverrides).insert(HostNetworkOverridesCompanion.insert(id: 'o1', connectionId: 'h1', networkId: 'n1', createdAt: at, updatedAt: at));
      await g.into(g.portForwardRules).insert(PortForwardRulesCompanion.insert(id: 'r1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: '127.0.0.1', remotePort: 80, createdAt: at, autoStart: const Value(true), gatewayPorts: const Value(true), bindAddress: const Value('0.0.0.0')));
      await g.into(g.portForwardNetworkOverrides).insert(PortForwardNetworkOverridesCompanion.insert(id: 'po1', ruleId: 'r1', networkId: 'n1', createdAt: at, updatedAt: at));
      await g.into(g.terminalTriggers).insert(TerminalTriggersCompanion.insert(id: 't1', name: 'errors', pattern: 'error|fail', createdAt: at));
      await g.into(g.commandHistory).insert(CommandHistoryCompanion.insert(id: 'c1', command: 'uptime', createdAt: at, exitCode: const Value(1), cwd: const Value('/srv')));
      await g.into(g.knownHosts).insert(KnownHostsCompanion.insert(id: 'kh1', host: 'h1.example.com', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:demo', publicKeyBase64: 'AAAA', firstSeen: at, lastSeen: at));
      await g.into(g.knownHosts).insert(KnownHostsCompanion.insert(id: 'kh2', host: 'jump.example.com', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:demo2', publicKeyBase64: 'AAAB', firstSeen: at, lastSeen: at, recordedDevice: const Value('a laptop')));
      await g.into(g.workflows).insert(WorkflowsCompanion.insert(id: 'w1', name: 'nightly', createdAt: at));
      await g.into(g.scheduledTasks).insert(ScheduledTasksCompanion.insert(id: 'st1', name: 'backup', action: 'command', connectionId: 'h1', scheduleType: 'daily', apiKeyId: 'k1', createdAt: at));
      await g.into(g.automationHistory).insert(AutomationHistoryCompanion.insert(id: 'ah1', timestamp: at, action: 'execute', connectionId: 'h1', command: 'uptime', success: true, elapsedMs: 12));
      await g.into(g.monitorSamples).insert(MonitorSamplesCompanion.insert(connectionId: 'h1', capturedAt: at));
      await g.customStatement("INSERT INTO sftp_sync_manifest (host_id, remote_root, rel_path, local_size, local_mtime_s, uploaded_at) VALUES ('h1', '/srv', 'a.txt', 1, 2, 3)");
      await g.customStatement("INSERT INTO feedback_queue (nonce, payload, created_at) VALUES ('f1', '{}', 1)");
      await g.customStatement("INSERT INTO support_tickets (nonce, token, type, title, created_at) VALUES ('t1', '${'a' * 43}', 'bug', 'demo', 1)");
      await g.customStatement("INSERT INTO ticket_outbox (nonce, ticket_nonce, body, created_at) VALUES ('o1', 't1', 'hello', 1)");
    }

    /// Every row of every table, each by its own key, as it is held.
    Future<Map<String, Map<String, Map<String, Object?>>>> everything(AppDatabase db) async {
      final all = <String, Map<String, Map<String, Object?>>>{};
      for (final table in await personalTables(db)) {
        final info = await db.customSelect('PRAGMA table_info("$table")').get();
        final key = [for (final c in info) if (c.read<int>('pk') > 0) c.read<String>('name')];
        final rows = await db.customSelect('SELECT * FROM "$table"').get();
        // A row with a number or an id of its own in this database: by what it is.
        final by = switch (table) {
          'monitor_samples' => const ['connection_id'],
          'known_hosts' => const ['host', 'port', 'key_type'],
          _ => key,
        };
        all[table] = {for (final r in rows) by.map((c) => '${r.data[c]}').join('|'): r.data};
      }
      return all;
    }

    /// When a row was made, where nothing shows it, and what is kept out on purpose:
    /// what differs after a Bring and why.
    const mayDiffer = {
      'connection_tags': {'created_at'},
      'host_network_overrides': {'created_at'},
      'port_forward_network_overrides': {'created_at'},
      'known_hosts': {'id', 'locally_verified', 'recorded_device'},
      'monitor_samples': {'id'},
    };

    test('a new table fails here until someone decides what comes of it', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      expect(await personalTables(db), unorderedEquals(kGuestTables.keys));
      await db.close();
    });

    test('a personal database as it is made holds nothing of a team', () async {
      final manager = world.launch();
      await manager.start();
      final db = await manager.openCurrent();
      SecretSeal.openTree = db;
      await addHost(db, 'a-host');
      expect(await guestTablesThatStay(db), isEmpty);
      await db.close();
    });

    test('nothing vanishes: every row of every table that comes is in the account, and comes as it was', () async {
      final manager = world.launch();
      await manager.start();
      final g = await manager.openCurrent();
      SecretSeal.openTree = g;
      await seedEverything(g);
      await LocalStateStore(g).write(kSavedTabGroupsKey, jsonEncode([
        {'id': 'tg1', 'name': 'the guest\'s'},
      ]));
      final was = await everything(g);
      for (final entry in kGuestTables.entries) {
        if (entry.value == GuestTableFate.restored || entry.value == GuestTableFate.copied) {
          expect(was[entry.key], isNotEmpty, reason: 'seed ${entry.key} as well: what comes of it has to be seen');
        }
      }
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, g);
      await LocalStateStore(db).write(kSavedTabGroupsKey, jsonEncode([
        {'id': 'tg0', 'name': 'the account\'s'},
      ]));
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));

      final now = await everything(db);
      for (final entry in kGuestTables.entries) {
        if (entry.value != GuestTableFate.restored && entry.value != GuestTableFate.copied) continue;
        final table = entry.key;
        for (final MapEntry(key: id, value: row) in was[table]!.entries) {
          final there = now[table]![id];
          expect(there, isNotNull, reason: '$table/$id');
          for (final column in row.keys) {
            if (mayDiffer[table]?.contains(column) ?? false) continue;
            expect(there![column], row[column], reason: '$table/$id.$column');
          }
        }
      }
      expect(manager.list.byId(guestId), isNull);
      expect(ProfilePaths.ofProfile(world.base, guestId).existsSync(), isFalse);
      expect(
        [for (final g in jsonDecode((await LocalStateStore(db).read(kSavedTabGroupsKey))!) as List) g['id']],
        ['tg0', 'tg1'],
      );
      expect(await db.tombstonesDao.getAll(), isEmpty, reason: 'its deletions do not come');
      await db.close();
    });

    test("a pinned key that disagrees with the account's stays out, and the account's pin decides", () async {
      final (manager, guest) = await guestWithHosts();
      final at = DateTime.utc(2026, 6, 1);
      await guest.into(guest.knownHosts).insert(KnownHostsCompanion.insert(id: 'kh-g', host: 'h1.example.com', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:guest', publicKeyBase64: 'AAAA', firstSeen: at, lastSeen: at));
      final db = await signIn(manager, guest);
      await db.into(db.knownHosts).insert(KnownHostsCompanion.insert(id: 'kh-a', host: 'h1.example.com', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:account', publicKeyBase64: 'AAAB', firstSeen: at, lastSeen: at));
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      final pins = await db.customSelect('SELECT fingerprint FROM known_hosts').get();
      expect([for (final r in pins) r.read<String>('fingerprint')], ['SHA256:account']);
      await db.close();
    });

    test('run again it brings nothing twice', () async {
      final manager = world.launch();
      await manager.start();
      final g = await manager.openCurrent();
      SecretSeal.openTree = g;
      await seedEverything(g);
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, g);
      final logs = Directory(p.join(world.folders.documents.path, 'ZestSSH', 'session-logs', guestId));
      await logs.create(recursive: true);
      final log = File(p.join(logs.path, 'held.log'));
      await log.writeAsString('open in an editor');
      world.stop = (at) {
        if (at == 'guest:files') throw const PlayedStop('here');
      };
      final mine = world.keychainOf(Profiles.current!, db);
      await expectLater(manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine), throwsA(isA<PlayedStop>()));
      world.stop = null;
      await db.customStatement("UPDATE workflows SET name = 'edited in the account' WHERE id = 'w1'");
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect((await db.customSelect('SELECT COUNT(*) AS n FROM monitor_samples').getSingle()).read<int>('n'), 1);
      expect((await db.customSelect("SELECT name FROM workflows WHERE id = 'w1'").getSingle()).read<String>('name'), 'edited in the account');
      await db.close();
    });

    test('what shows the tables hears of it', () async {
      final (manager, guest) = await guestWithHosts();
      await guest.into(guest.workflows).insert(WorkflowsCompanion.insert(id: 'w1', name: 'nightly', createdAt: DateTime.utc(2026, 6, 1)));
      final db = await signIn(manager, guest);
      final heard = db.tableUpdates(const TableUpdateQuery.onTableName('workflows')).first;
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: world.keychainOf(Profiles.current!, db));
      await heard.timeout(const Duration(seconds: 5));
      await db.close();
    });

    for (final (what, statement) in const [
      ('a team\'s table', "INSERT INTO orchard_info (id, orchard_id, name, role, key_generation) VALUES (1, 'o', 'Acme', 'owner', 1)"),
      ('a table no one decided on', "CREATE TABLE a_new_kind (id TEXT PRIMARY KEY); INSERT INTO a_new_kind VALUES ('x')"),
    ]) {
      test('$what holding rows: its hosts come, the guest profile stays, and the person is told what stayed', () async {
        final (manager, guest) = await guestWithHosts();
        for (final one in statement.split('; ')) {
          await guest.customStatement(one);
        }
        final guestId = manager.currentEntry!.id;
        final db = await signIn(manager, guest);
        final mine = world.keychainOf(Profiles.current!, db);
        await expectLater(
          manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine),
          throwsA(isA<GuestKindsStayed>()),
        );
        expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
        expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), 'PRIVATE KEY OF THE GUEST');
        expect(manager.list.byId(guestId)!.state, ProfileState.open);
        expect(world.rawNames(guestId), isNotEmpty);
        await db.close();
      });
    }
  });

  test("a move's marker left behind: nothing comes and nothing goes, and the next start is the same as before", () async {
    final (manager, guest) = await guestWithHosts();
    final guestId = manager.currentEntry!.id;
    final db = await signIn(manager, guest);
    final file = File(p.join(ProfilePaths.root(world.base).path, 'move_v1.json'));
    file.writeAsStringSync(jsonEncode(MoveMarker(profile: guestId, stage: MoveStage.filesMoved).toJson()));
    final mine = world.keychainOf(Profiles.current!, db);
    await expectLater(manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine), throwsStateError);
    expect(manager.list.byId(guestId)!.state, ProfileState.open);
    expect(world.rawNames(guestId), isNotEmpty);
    expect(await hostsOf(db), isEmpty);
    await db.close();
  });

  group('a sync that runs meanwhile', () {
    test("a pull under way as it comes: the pull's sweep leaves the key that came", () async {
      final (manager, guest) = await guestWithHosts();
      final guestId = manager.currentEntry!.id;
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      final gate = Completer<void>();
      final reached = Completer<void>();
      final pullSvc = serviceWith(db, _Wrap(mine, gateOn: (k) => k.contains('pull-key'), gate: gate, reached: reached));
      final at = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch;
      final pull = pullSvc.restoreAll({
        'schema_version': 22,
        'identities': [
          {'id': 'pull-key', 'label': 'from the store', 'username': 'u', 'authMethod': 'password', 'createdAt': at, 'updatedAt': at},
        ],
        'secrets': {
          'pull-key': {'password': 'from the store'},
        },
      });
      await reached.future.timeout(const Duration(seconds: 20));

      // The pull read its keys before this one came, and sweeps after.
      await manager.bringGuestInto(serviceOf(db, Profiles.current!), db: db, keychain: mine);
      expect(manager.list.byId(guestId), isNull);
      gate.complete();
      expect((await pull).success, isTrue);

      expect(await secretsOf(db, mine).read('guest-key', IdentitySecret.privateKey), 'PRIVATE KEY OF THE GUEST');
      expect(await secretsOf(db, mine).read('pull-key', IdentitySecret.password), 'from the store');
      await db.close();
    });

    test('the sweep reads the secrets first and the keys after: a key written just before it stays, and a leftover goes', () async {
      final (manager, guest) = await guestWithHosts();
      final db = await signIn(manager, guest);
      final mine = world.keychainOf(Profiles.current!, db);
      await mine.write(key: 'identity_key_nobody-has-this', value: 'a leftover');
      final at = DateTime.utc(2026, 10, 1).millisecondsSinceEpoch;
      final wrap = _Wrap(mine, atSweep: () async {
        // Row first, then secret, as every writer does.
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
            id: 'just-came', label: 'x', username: 'u', authMethod: 'password', createdAt: DateTime.utc(2026, 10, 1)));
        await mine.write(key: 'identity_password_just-came', value: 'kept');
      });
      final done = await serviceWith(db, wrap).restoreAll({
        'schema_version': 22,
        'identities': [
          {'id': 'pull-key', 'label': 'from the store', 'username': 'u', 'authMethod': 'password', 'createdAt': at, 'updatedAt': at},
        ],
        'secrets': {
          'pull-key': {'password': 'from the store'},
        },
      });
      expect(done.success, isTrue);
      expect(await mine.read(key: 'identity_password_just-came'), 'kept');
      expect(await mine.read(key: 'identity_key_nobody-has-this'), isNull);
      await db.close();
    });

    test('a cycle in flight ends first, and sync starts again after, whether it came or not', () async {
      final (_, guest) = await guestWithHosts();
      final sync = _PlayedSync();
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
        secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
        autoSyncServiceProvider.overrideWithValue(sync),
      ]);
      c.read(databaseSessionProvider.notifier).seed(guest);
      addTearDown(c.dispose);
      final profiles = c.read(profileControllerProvider);
      await profiles.openForAccount(uid: uid, label: 'sam@example.com', bearer: 'b');
      final db = c.read(databaseSessionProvider)!;
      expect(await hostsOf(db), isEmpty);

      sync.log.clear();
      sync.cycle = Completer<void>();
      final bring = profiles.bringGuestData();
      await pumpEventQueue(times: 50);
      expect(await hostsOf(db), isEmpty, reason: 'not while a cycle runs');
      expect(sync.log, ['suspend']);
      sync.cycle!.complete();
      await bring;
      expect(await hostsOf(db), ['guest-host-1', 'guest-host-2']);
      expect(sync.log, ['suspend', 'ended', 'resume']);
      await db.close();
    });

    test('custom themes that came are read again: the next save does not write over them', () async {
      final (_, guest) = await guestWithHosts();
      SharedPreferences.setMockInitialValues(const {});
      final loose = await SharedPreferences.getInstance();
      await TerminalThemes.saveCustomTheme(prefs: loose, name: 'Mine', theme: TerminalThemes.builtIn[TerminalThemes.zestNight]!);
      final terminal = loose.getString('custom_terminal_themes')!;
      await loose.clear();
      await TerminalThemes.loadCustomThemes(loose);
      final scheme = BuiltInThemes.all.first.colorScheme.toJson();
      await ProfilePreferences.importInto(guest, {
        'custom_terminal_themes': terminal,
        'custom_app_themes_v1': jsonEncode([
          {...scheme, 'id': 'custom_app_1', 'name': 'Sunset'},
        ]),
      });
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
        secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
        autoSyncServiceProvider.overrideWithValue(_PlayedSync()),
      ]);
      c.read(databaseSessionProvider.notifier).seed(guest);
      addTearDown(c.dispose);
      final profiles = c.read(profileControllerProvider);
      await profiles.openForAccount(uid: uid, label: 'sam@example.com', bearer: 'b');
      final db = c.read(databaseSessionProvider)!;
      expect(c.read(customAppThemesProvider), isEmpty);
      expect(TerminalThemes.isCustomTheme('custom_1'), isFalse);

      await profiles.bringGuestData();
      expect(TerminalThemes.isCustomTheme('custom_1'), isTrue);
      expect(c.read(customAppThemesProvider).keys, ['custom_app_1']);
      expect(ProfilePreferences.instance!.getString('custom_terminal_themes'), contains('Mine'));
      await TerminalThemes.loadCustomThemes(loose);
      await db.close();
    });
  });
}
