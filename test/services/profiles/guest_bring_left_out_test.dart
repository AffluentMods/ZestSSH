import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/saved_tab_group.dart' show kSavedTabGroupsKey;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/guest_tables.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/ui/screens/profile/widgets/guest_data_question.dart';

import 'profile_world.dart';

/// A Bring run for real, on a guest with everything on the list (found in a final
/// review). It deleted what no table carries (automation API keys, custom themes,
/// backup destinations) and said only that the guest data was empty; a key the account had
/// deleted stayed deleted, its only private key copy going unsaid; a host kept a group
/// that was gone, and a deleted host's forward arrived with no host. Custom themes come,
/// the question names what does not, and what points at nothing is cleared.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const uid = 'account-sam';
  final en = lookupAppLocalizations(const Locale('en'));

  late ProfileWorld world;
  setUp(() async => world = await ProfileWorld.create());
  tearDown(() => world.dispose());

  SyncDataService serviceOf(AppDatabase db, ActiveProfile profile) => SyncDataService(
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
        secureStorage: world.keychainOf(profile, db),
        settingsService: SettingsService(world.rawPrefs),
      );

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

  final at = DateTime.utc(2026, 6, 1);
  final deleted = DateTime.utc(2026, 10, 1);

  /// A guest with everything on the list. With [apiKey], an automation API key too.
  Future<void> seed(AppDatabase g, FlutterSecureStorage gk, {bool apiKey = true}) async {
    await g.into(g.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g1', name: 'Prod', createdAt: at, updatedAt: Value(at)));
    await g.into(g.identities).insert(IdentitiesCompanion.insert(
        id: 'k1', label: 'work', username: 'u', authMethod: 'publicKey', createdAt: at, updatedAt: Value(at), isDefault: const Value(true)));
    await g.into(g.identities).insert(IdentitiesCompanion.insert(id: 'k2', label: 'pw', username: 'u', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await secretsOf(g, gk).write('k1', IdentitySecret.privateKey, 'GUEST PEM');
    await secretsOf(g, gk).write('k1', IdentitySecret.passphrase, 'GUEST PASSPHRASE');
    await secretsOf(g, gk).write('k2', IdentitySecret.password, 'GUEST PASSWORD');
    await g.into(g.snippets).insert(SnippetsCompanion.insert(id: 's1', label: 'up', command: 'uptime', createdAt: at, updatedAt: at));
    await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'jump', label: 'jump', host: 'jump.example.com', createdAt: at, updatedAt: at, identityId: const Value('k1')));
    await g.into(g.connections).insert(ConnectionsCompanion.insert(
        id: 'h1', label: 'h1', host: 'h1.example.com', createdAt: at, updatedAt: at, identityId: const Value('k1'), groupId: const Value('g1'), connectViaId: const Value('jump'), snippetId: const Value('s1')));
    await g.into(g.connections).insert(ConnectionsCompanion.insert(id: 'local1', label: 'my shell', host: 'localhost', createdAt: at, updatedAt: at, protocol: const Value('localShell'), port: const Value(0)));
    await g.into(g.connectionTags).insert(ConnectionTagsCompanion.insert(connectionId: 'h1', tag: 'prod', createdAt: at));
    await g.into(g.hostAccounts).insert(HostAccountsCompanion.insert(connectionId: 'h1', identityId: 'k2', position: 0));
    await g.into(g.portForwardRules).insert(PortForwardRulesCompanion.insert(
        id: 'r1', connectionId: 'h1', type: 'local', bindPort: 8080, remoteHost: '127.0.0.1', remotePort: 80, createdAt: at, autoStart: const Value(true), bindAddress: const Value('0.0.0.0')));
    await g.into(g.workflows).insert(WorkflowsCompanion.insert(
        id: 'w1', name: 'nightly', createdAt: at, stepsJson: Value(jsonEncode([{'type': 'command', 'hostId': 'h1', 'snippetId': 's1'}]))));
    await g.into(g.scheduledTasks).insert(ScheduledTasksCompanion.insert(
        id: 'st1', name: 'backup', action: 'workflow', connectionId: 'h1', workflowId: const Value('w1'), scheduleType: 'daily', apiKeyId: 'ak1', createdAt: at));
    await LocalStateStore(g).write(kSavedTabGroupsKey, jsonEncode([
      {'id': 'tg1', 'name': 'the guest\'s', 'hosts': ['h1', 'jump']},
    ]));
    if (apiKey) await gk.write(key: 'automation_api_keys', value: jsonEncode([{'id': 'ak1', 'name': 'my script', 'key': 'zk_demo'}]));
  }

  /// Up to the account on screen, with a guest beside it.
  Future<({ProfileManager manager, String guestId, AppDatabase db, FlutterSecureStorage mine})> ready(
      {bool apiKey = true, Future<void> Function(AppDatabase g)? alsoInGuest}) async {
    final manager = world.launch();
    await manager.start();
    final g = await manager.openCurrent();
    SecretSeal.openTree = g;
    await seed(g, world.keychainOf(Profiles.current!, g), apiKey: apiKey);
    await alsoInGuest?.call(g);
    final guestId = manager.currentEntry!.id;
    final db = await signIn(manager, g);
    return (manager: manager, guestId: guestId, db: db, mine: world.keychainOf(Profiles.current!, db));
  }

  Future<void> bring(({ProfileManager manager, String guestId, AppDatabase db, FlutterSecureStorage mine}) w) =>
      w.manager.bringGuestInto(serviceOf(w.db, Profiles.current!), db: w.db, keychain: w.mine);

  Future<int> count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT COUNT(*) AS n FROM "$table"').getSingle()).read<int>('n');

  test('a realistic guest, a key whose name is taken: all of it comes, and the API key is said to stay out', () async {
    final w = await ready();
    final db = w.db;
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'acc-work', label: 'work', username: 'a', authMethod: 'publicKey', createdAt: at, updatedAt: Value(DateTime.utc(2026, 10, 2)), isDefault: const Value(true)));
    await secretsOf(db, w.mine).write('acc-work', IdentitySecret.privateKey, 'ACCOUNT PEM');

    final summary = (await w.manager.lookAtGuest(into: db))!;
    expect(summary.staysOut.apiKeys, 1);
    final words = guestDataWords(en, summary, 'sam@example.com');
    expect(words, contains(en.guestDataGoesLead));
    expect(words, contains(en.guestDataGoesApiKeys(1)));
    expect(guestDataBroughtWords(en, summary), en.guestDataBroughtSome);

    await bring(w);
    expect(w.manager.list.byId(w.guestId), isNull, reason: 'the guest profile has gone');
    final h1 = (await db.connectionsDao.getById('h1'))!;
    expect((h1.identityId, h1.connectViaId, h1.groupId, h1.snippetId), ('k1', 'jump', 'g1', 's1'));
    expect((await db.connectionsDao.getById('local1'))!.protocol, 'localShell');
    expect(await secretsOf(db, w.mine).read('k1', IdentitySecret.privateKey), 'GUEST PEM');
    expect(await secretsOf(db, w.mine).read('k1', IdentitySecret.passphrase), 'GUEST PASSPHRASE');
    expect(await secretsOf(db, w.mine).read('k2', IdentitySecret.password), 'GUEST PASSWORD');
    expect(await secretsOf(db, w.mine).read('acc-work', IdentitySecret.privateKey), 'ACCOUNT PEM');
    expect(await count(db, 'workflows'), 1);
    expect((await db.customSelect('SELECT connection_id, bind_address, auto_start FROM port_forward_rules').getSingle()).data,
        {'connection_id': 'h1', 'bind_address': '0.0.0.0', 'auto_start': 1});
    expect((await count(db, 'connection_tags'), await count(db, 'host_accounts')), (1, 1));
    expect(await LocalStateStore(db).read(kSavedTabGroupsKey), contains('tg1'));

    // The task came naming a key that did not: said in the question, and it shows.
    expect((await db.customSelect('SELECT api_key_id FROM scheduled_tasks').getSingle()).read<String>('api_key_id'), 'ak1');
    expect(await w.mine.read(key: 'automation_api_keys'), isNull);
    expect((await world.device.readAll()).keys.where((k) => k.contains(w.guestId)), isEmpty, reason: 'its keychain has gone');
    await db.close();
  });

  test('a guest with nothing that stays out: the question and the result are as they were', () async {
    final w = await ready(apiKey: false);
    final summary = (await w.manager.lookAtGuest(into: w.db))!;
    expect(summary.staysOut.any, isFalse);
    expect(guestDataWords(en, summary, 'sam@example.com'), en.guestDataQuestion(3, 'sam@example.com'));
    expect(guestDataBroughtWords(en, summary), en.guestDataBrought);
    await w.db.close();
  });

  test('backup destinations and what else a person set up: named before they go', () async {
    final w = await ready(
      apiKey: false,
      alsoInGuest: (g) => ProfilePreferences.importInto(g, {
        'backup_destinations': jsonEncode([{'id': 'd1'}, {'id': 'd2'}]),
        'password_managers_v1': jsonEncode([{'id': 'pm1'}]),
      }),
    );
    final summary = (await w.manager.lookAtGuest(into: w.db))!;
    expect(summary.staysOut.backupDestinations, 2);
    expect(summary.staysOut.others, isTrue);
    final words = guestDataWords(en, summary, 'sam@example.com');
    expect(words, contains(en.guestDataGoesBackups(2)));
    expect(words, contains(en.guestDataGoesOthers));
    expect(guestDataBroughtWords(en, summary), en.guestDataBroughtSome);
    await bring(w);
    final kept = await ProfilePreferences.readStored(w.db);
    expect(kept['backup_destinations'], isNull, reason: 'they did not come, as was said');
    await w.db.close();
  });

  group('custom themes', () {
    Map<String, Object?> theme(String id, String name, {String colour = '#111111'}) => {'id': id, 'name': name, 'background': colour};

    List<Map<String, dynamic>> themesIn(Map<String, Object> kept, String key) =>
        (jsonDecode(kept[key]! as String) as List).cast<Map<String, dynamic>>();

    test('they come, and one the account has by that name stays as it is', () async {
      final w = await ready(
        apiKey: false,
        alsoInGuest: (g) => ProfilePreferences.importInto(g, {
          'custom_terminal_themes': jsonEncode([
            theme('custom_1', 'Mine'),
            theme('custom_2', 'Both', colour: '#GUEST'),
            theme('custom_3', 'Same'),
          ]),
          'custom_app_themes_v1': jsonEncode([theme('custom_app_1', 'Sunset')]),
        }),
      );
      await ProfilePreferences.importInto(w.db, {
        'custom_terminal_themes': jsonEncode([
          theme('custom_1', 'Theirs'),
          theme('custom_2', 'Both', colour: '#ACCOUNT'),
          theme('custom_7', 'Same'),
        ]),
      });

      final summary = (await w.manager.lookAtGuest(into: w.db))!;
      expect(summary.staysOut.themes, 1, reason: 'one with other colours; the one just the same loses nothing');
      expect(guestDataWords(en, summary, 'sam@example.com'), contains(en.guestDataGoesThemes(1)));

      await bring(w);
      final kept = await ProfilePreferences.readStored(w.db);
      final terminal = themesIn(kept, 'custom_terminal_themes');
      expect([for (final t in terminal) t['name']], ['Theirs', 'Both', 'Same', 'Mine']);
      expect(terminal.firstWhere((t) => t['name'] == 'Theirs')['id'], 'custom_1');
      expect(terminal.firstWhere((t) => t['name'] == 'Both')['background'], '#ACCOUNT');
      expect(terminal.firstWhere((t) => t['name'] == 'Mine')['id'], 'custom_3', reason: 'custom_1 is the account\'s: a free number');
      expect(themesIn(kept, 'custom_app_themes_v1').single['name'], 'Sunset');
      await w.db.close();
    });

    test('run again it brings none twice', () async {
      final from = AppDatabase.forTesting(NativeDatabase.memory());
      final into = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(from.close);
      addTearDown(into.close);
      await ProfilePreferences.importInto(from, {'custom_terminal_themes': jsonEncode([theme('custom_1', 'Mine')])});
      await ProfilePreferences.importInto(into, {'custom_terminal_themes': jsonEncode([theme('custom_1', 'Theirs')])});
      await carryGuestTables(from: from, into: into, taken: const {});
      await carryGuestTables(from: from, into: into, taken: const {});
      expect([for (final t in themesIn(await ProfilePreferences.readStored(into), 'custom_terminal_themes')) t['name']], ['Theirs', 'Mine']);
    });
  });

  test('a key the account deleted stays deleted, and how many is said before its copy goes', () async {
    final w = await ready(apiKey: false);
    await w.db.tombstonesDao.mark('identities', 'k1', at: deleted);
    final summary = (await w.manager.lookAtGuest(into: w.db))!;
    expect(summary.staysOut.keys, 1);
    expect(guestDataWords(en, summary, 'sam@example.com'), contains(en.guestDataGoesDeletedKeys(1)));
    expect(guestDataBroughtWords(en, summary), en.guestDataBroughtSome);

    await bring(w);
    expect(w.manager.list.byId(w.guestId), isNull);
    expect(await w.db.identitiesDao.getById('k1'), isNull);
    expect(await secretsOf(w.db, w.mine).read('k1', IdentitySecret.privateKey), isNull);
    expect((await w.db.connectionsDao.getById('jump'))!.identityId, isNull, reason: 'the restore lets go of a key that is not there');
    await w.db.close();
  });

  test('a key changed after the account deleted it comes back, and nothing is said of it', () async {
    final w = await ready(
      apiKey: false,
      alsoInGuest: (g) => g.customStatement("UPDATE identities SET updated_at = ? WHERE id = 'k2'", [DateTime.utc(2026, 10, 20).millisecondsSinceEpoch ~/ 1000]),
    );
    await w.db.tombstonesDao.mark('identities', 'k2', at: deleted);
    final summary = (await w.manager.lookAtGuest(into: w.db))!;
    expect(summary.staysOut.keys, 0);
    await bring(w);
    expect((await w.db.identitiesDao.getById('k2'))?.id, 'k2');
    expect(await secretsOf(w.db, w.mine).read('k2', IdentitySecret.password), 'GUEST PASSWORD');
    await w.db.close();
  });

  test('a group the account deleted: its hosts come in no group, where they show', () async {
    final w = await ready(apiKey: false);
    await w.db.tombstonesDao.mark('connection_groups', 'g1', at: deleted);
    await bring(w);
    expect(await count(w.db, 'connection_groups'), 0);
    expect((await w.db.connectionsDao.getById('h1'))!.groupId, isNull);
    await w.db.close();
  });

  test('a host the account deleted: its forward does not come with no host', () async {
    final w = await ready(apiKey: false);
    await w.db.tombstonesDao.mark('connections', 'h1', at: deleted);
    await bring(w);
    expect(await w.db.connectionsDao.getById('h1'), isNull);
    expect(await count(w.db, 'port_forward_rules'), 0);
    expect((await count(w.db, 'connection_tags'), await count(w.db, 'host_accounts')), (0, 0));
    expect((await w.db.connectionsDao.getById('jump'))?.id, 'jump');
    await w.db.close();
  });

  for (final (name, type, id) in const [
    ('snippet', 'snippets', 's1'),
    ('jump host', 'connections', 'jump'),
  ]) {
    test('the account deleted the $name: it stays deleted, and the guest still goes', () async {
      final w = await ready(apiKey: false);
      await w.db.tombstonesDao.mark(type, id, at: deleted);
      await bring(w);
      expect(w.manager.list.byId(w.guestId), isNull);
      expect(await count(w.db, 'port_forward_rules'), 1);
      expect((await w.db.connectionsDao.getById('h1'))!.groupId, 'g1');
      await w.db.close();
    });
  }
}
