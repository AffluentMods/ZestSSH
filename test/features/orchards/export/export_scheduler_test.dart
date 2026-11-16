import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

import '../fake_crate_server.dart';
import '../fake_stream_server.dart';

/// Event export (3.0) in a running app: the device that sends
/// looks for what is new after each sync and, in between, once a minute;
/// its pages hear when where it stands changed; a stopped app sends
/// nothing. A real service, a real sync and the real scheduler against the
/// (fake) server; a member's device acts on its own.

const _owner = 'owner-1';
const _alice = 'alice';

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

class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

/// An exporter that notes what it is asked to send now, and for which
/// account (which it asks the service, as a round does).
class _Asked extends OrchardEventExporter {
  _Asked(this.asked, {required super.service, required super.settings, required super.post});

  final List<(String, Set<String>?)> asked;

  @override
  Future<void> flush(String orchardId) async => asked.add((orchardId, service.listedFor(_owner)));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer crates;
  late FakeStreamServer server;
  late StreamController<ConnectivityKind> network;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late _MemoryStorage hers;
  late _Keychain keychain;
  late ProviderContainer container;
  late OrchardService alice;
  final taken = <Map<String, dynamic>>[];
  var requests = 0;

  /// How often the exporter asked for the account's Orchards: once at least
  /// each time it looks.
  var looks = 0;
  final tick = OrchardSyncScheduler.exportTick;

  setUpAll(() async {
    for (final uid in [_owner, _alice]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    crates = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice]) {
      await crates.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
    server = await FakeStreamServer.start();
    network = StreamController<ConnectivityKind>.broadcast();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    hers = _MemoryStorage();
    keychain = _Keychain();
    taken.clear();
    requests = 0;
    looks = 0;
    alice = OrchardService(
      server: crates.as(_alice, device: 'alice-laptop'),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: hers),
      author: () async => CrateAuthor(uid: _alice, keys: keys[_alice]!),
    );
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      orchardNetworkChangesProvider.overrideWithValue(() => network.stream),
      orchardStreamProvider.overrideWith((ref) {
        final line = OrchardStream(
          url: server.url,
          connect: (url) => WebSocket.connect(url.toString()),
          token: ({bool fresh = false}) async => 'token',
          session: () => null,
          retryDelay: (_, _) => const Duration(milliseconds: 10),
        );
        ref.onDispose(() => unawaited(line.dispose()));
        return line;
      }),
      orchardServiceProvider.overrideWith((ref) => OrchardService(
            server: crates.as(_owner, device: 'laptop'),
            databases: ref.read(orchardDatabasesProvider.notifier),
            author: () async => CrateAuthor(uid: _owner, keys: keys[_owner]!),
            deviceKeys: DeviceIdentityStore(keychain),
          )),
      orchardSyncProvider.overrideWith((ref) => OrchardSyncCoordinator(
            service: ref.read(orchardServiceProvider),
            server: crates.as(_owner, device: 'laptop'),
            databases: ref.read(orchardDatabasesProvider.notifier),
          )),
      // The app's own exporter, wired as the app wires it, with a receiver
      // in place of the network.
      orchardEventExporterProvider.overrideWith((ref) => OrchardEventExporter(
            service: () {
              looks++;
              return ref.read(orchardServiceProvider);
            },
            settings: ExportSettingsStore(keychain),
            post: (to, body) async {
              requests++;
              taken.addAll([
                for (final line in body.split('\n'))
                  if (line.isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
              ]);
              return const ExportDelivery.delivered(200);
            },
            onChanged: () => ref.read(exportVersionProvider.notifier).state++,
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    OrchardSyncScheduler.exportTick = tick;
    container.dispose();
    await network.close();
    await server.close();
    for (final db in [...storage.dbs.values, ...hers.dbs.values]) {
      await db.close();
    }
    await tree.close();
  });

  OrchardService mine() => container.read(orchardServiceProvider);
  OrchardSyncScheduler scheduler() => container.read(orchardSyncSchedulerProvider);
  OrchardEventExporter exporter() => container.read(orchardEventExporterProvider);

  /// An Orchard of the owner's app with alice in it, which records activity
  /// and sends its events on from this app.
  Future<({String id, String crate})> sending() async {
    final id = await mine().createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final role = crates.recordOf(id).roles.values.single;
    await mine().invite(id, email: 'alice@example.com', role: role.id);
    crates.acceptAs(id, (await mine().invites(id)).single.id, _alice);
    await mine().confirmInvite(id, (await mine().invites(id)).single);
    await mine().setTracking(id, const RecordTracking(activity: true));
    await alice.refresh();
    await exporter().setUp(id, ExportDestination.of('https://logs.example.com/in', ExportFormat.lines)!,
        await exporter().newKey());
    return (id: id, crate: role.crates.keys.single);
  }

  Future<void> reveals(String id, String crate, String name) async {
    await alice.recordActivity(id, ActivityKind.reveal, crateId: crate, itemKind: 'key', itemKey: 'k-$name', name: name);
    expect(await alice.activityRound(id), 1);
  }

  test('each sync sends on what is new, and the pages hear that it went', () async {
    final o = await sending();
    expect([for (final e in taken) e['change']], ['export_on']);
    final version = container.read(exportVersionProvider);

    // A member does something; nothing goes by itself.
    await reveals(o.id, o.crate, 'deploy key');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(taken, hasLength(1));
    // The sync: it goes, and what stands on a page is read again.
    await scheduler().syncAll();
    expect([for (final e in taken) e['id']], ['record-${crates.entriesOf(o.id).last.seq}', 'activity-1']);
    expect(container.read(exportVersionProvider), greaterThan(version));
    final standing = await container.read(exportStandingProvider(o.id).future);
    expect((standing.sendsHere, standing.status.sent), (true, 2));
    // A sync with nothing new sends nothing.
    final sent = requests;
    await scheduler().syncAll();
    expect(requests, sent);

    // Stopped (the app is locked, or gone): nothing is sent, whatever waits.
    await reveals(o.id, o.crate, 'db password');
    scheduler().stop();
    await scheduler().exportRounds();
    await scheduler().syncAll();
    expect(requests, sent);
    // Started again, the first sync sends it.
    scheduler().start();
    await eventually(() => taken.length == 3);
    expect(taken.last['message'], 'alice@example.com opened the secrets of db password');
    scheduler().stop();
  }, skip: !kOrchardsEnabled);

  test('the app\'s own service asks the app\'s exporter for what is left, before a change made here ends the '
      'sending', () async {
    final asked = <(String, Set<String>?)>[];
    final prefs = await SharedPreferences.getInstance();
    final app = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(keychain),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      currentUserProvider.overrideWithValue(const UserProfile(uid: _owner, email: 'owner-1@example.com')),
      orchardEventExporterProvider.overrideWith((ref) => _Asked(
            asked,
            service: () => ref.read(orchardServiceProvider),
            settings: ExportSettingsStore(keychain),
            post: (_, _) async => const ExportDelivery.delivered(200),
          )),
    ]);
    addTearDown(app.dispose);
    final flush = app.read(orchardServiceProvider).flushEvents;
    expect(flush, isNotNull);
    await flush!('an-orchard');
    expect(asked, [('an-orchard', null)]);
    // The exporter is the app's own, made once for the account.
    expect(identical(app.read(orchardEventExporterProvider), app.read(orchardEventExporterProvider)), isTrue);
  });

  test('the app\'s own exporter: one for each account, over the system\'s secure storage and the account\'s '
      'service, and its pages hear of what it does', () async {
    final who = StateProvider<String>((ref) => _owner);
    final prefs = await SharedPreferences.getInstance();
    final app = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      secureStorageProvider.overrideWithValue(keychain),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      currentUserProvider
          .overrideWith((ref) => UserProfile(uid: ref.watch(who), email: '${ref.watch(who)}@example.com')),
    ]);
    addTearDown(app.dispose);
    final exporter = app.read(orchardEventExporterProvider);
    expect(identical(app.read(orchardEventExporterProvider), exporter), isTrue);
    expect(identical(exporter.service, app.read(orchardServiceProvider)), isTrue);
    await exporter.settings.writeSent(_owner, 'an-orchard', 'as far as this');
    expect(keychain.values['orchard_export_v1.$_owner.an-orchard.sent'], 'as far as this');
    final version = app.read(exportVersionProvider);
    exporter.onChanged!();
    expect(app.read(exportVersionProvider), version + 1);
    // Another account signs in: a new exporter, which holds nothing of the
    // first one's, over the service that is that account's.
    app.read(who.notifier).state = _alice;
    final next = app.read(orchardEventExporterProvider);
    expect(identical(next, exporter), isFalse);
    expect(identical(next.service, app.read(orchardServiceProvider)), isTrue);
    expect(identical(exporter.service, next.service), isTrue, reason: 'asked for at each use');
  });

  test('between syncs the device looks once a minute; locked, it does not', () async {
    final o = await sending();
    OrchardSyncScheduler.exportTick = const Duration(milliseconds: 60);
    scheduler().start();
    await eventually(() => crates.activityReads.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    final sent = requests;

    // No sync is asked for: the tick alone sends what a member did.
    await reveals(o.id, o.crate, 'deploy key');
    await eventually(() => taken.any((e) => e['id'] == 'activity-1'));
    expect(requests, sent + 1);

    // While it is open, every tick asks for the account's Orchards.
    final asked = looks;
    await eventually(() => looks > asked + 1);

    // The vault is locked: the databases are closed, and the tick sends
    // nothing. It does not even look: nothing of the account is asked for.
    await reveals(o.id, o.crate, 'db password');
    await container.read(databaseSessionProvider.notifier).close();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    final before = requests;
    final reads = crates.activityReads.length;
    final lookedAt = looks;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(requests, before);
    expect(crates.activityReads, hasLength(reads));
    expect(looks, lookedAt, reason: 'six ticks went by');
    scheduler().stop();
  }, skip: !kOrchardsEnabled);
}
