// A Crate that its own offline limit has closed on a device (3.0).
// An Orchard's owners say, Crate by Crate,
// how long a device may go without reaching ZestSSH Cloud before that Crate
// closes on it. Here: an Orchard on a device as the app holds it, with a
// clock and a contact the tests set, and a host on this machine (a TCP
// server, reached with the Telnet shell so no SSH server is needed). Which
// Crates are closed and when; what a closed Crate refuses, asked the way
// the app asks it (a session's switches, the screens' summary, the store of
// a key's secrets, the app's own session code, the monitor); that the Crate
// beside it is left alone; and that everything is back the moment the
// device is in contact again, with nothing lost.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/rules/offline_warnings.dart';
import 'package:zestssh/features/orchards/rules/orchard_contact.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardErrorMessage;
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/utils/error_translator.dart' as translator;

import '../../sharing/share_fakes.dart' show until;
import '../fake_crate_server.dart';

const _dana = 'uid-dana'; // owns the Orchard, and this is her device

const _hour = 3600;

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

/// A Squeezed account, without RevenueCat or the backend.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up in these tests: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The Orchards' sync as the scheduler asks for it, without a server: it
/// goes through, or cannot finish (the device is offline).
class _Sync extends OrchardSyncCoordinator {
  _Sync({required super.service, required super.server, required super.databases});

  var offline = false;
  var runs = 0;

  @override
  Future<Map<String, CrateSyncReport>> syncAll() async {
    runs++;
    if (offline) throw const SocketException('offline');
    return const {};
  }
}

/// The host: a TCP server on this machine that counts who reached it.
class _Host {
  late final ServerSocket _server;
  final sockets = <Socket>[];

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {}, onError: (Object _) {});
    });
  }

  int get port => _server.port;

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final l10n = lookupAppLocalizations(const Locale('en'));
  late AccountKeys keys;
  late FakeCrateServer server;
  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late _Host host;
  late OrchardService dana;
  late String orchardId;
  late String production;
  late String lab;

  /// This device's clock, in seconds since the epoch: the tests move it.
  late int clock;

  /// The Orchards' sync, and what ZestSSH Cloud answers when the app asks
  /// how it is (a status, or what is thrown).
  late _Sync sync;
  late CloudReachService reach;
  Object cloudAnswer = 200;

  setUpAll(() async {
    keys = await AccountKeys.generate();
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(l10n);
    clock = 1790000000;
    cloudAnswer = 200;
    host = _Host();
    await host.start();
    server = FakeCrateServer(accountUid: _dana);
    await server.publish(_dana, keys, email: 'dana@example.com');
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      orchardAuthorProvider
          .overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: _dana, keys: keys))),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      // When this device last reached ZestSSH Cloud, kept as the app keeps
      // it, by a clock the tests move.
      orchardContactProvider.overrideWith((ref) => OrchardContactNotifier(LocalStateStore(tree), now: () => clock)),
      // What the app knows of how ZestSSH Cloud stands: asked when a test
      // says so, never by itself.
      cloudReachProvider.overrideWith((ref) {
        reach = CloudReachService(
          check: () async {
            final a = cloudAnswer;
            if (a is int) return a;
            throw a;
          },
          timer: (wait, then) => Timer(const Duration(days: 1), () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
      orchardSyncProvider.overrideWith((ref) => sync = _Sync(service: dana, server: dana.server, databases: dana.databases)),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);

    // dana's Orchard on this device, with two Crates: Production and Lab.
    dana = OrchardService(
      server: server.as(_dana),
      databases: container.read(orchardDatabasesProvider.notifier),
      author: () async => CrateAuthor(uid: _dana, keys: keys),
    );
    orchardId = await dana.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    production = server.recordOf(orchardId).crates.keys.single;
    lab = await dana.createCrate(orchardId, 'Lab');
    await dana.refresh();
    await container.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
    // The device reached ZestSSH Cloud just now.
    await container.read(orchardContactProvider.notifier).reached();
  });

  tearDown(() async {
    currentCloudReach = null;
    container.dispose();
    await host.stop();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  AppDatabase orchardDb() => container.read(orchardDatabasesProvider)[orchardId]!;
  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String sessionId) => container.read(activeSessionsProvider)[sessionId];
  Future<void> reached() => container.read(orchardContactProvider.notifier).reached();
  Future<void> limit(String crate, int hours) => dana.setCrateOfflineLimit(orchardId, crate, hours);
  final closedProduction = l10n.crateClosedOfflineError('Production');

  /// A host on this machine, saved in [crate] of the Orchard.
  Future<Connection> addHost(String id, String crate,
      {String label = 'web-01', String protocol = 'telnet', String? key, String? via, bool place = true}) async {
    final db = orchardDb();
    final at = DateTime(2026, 10, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '127.0.0.1',
          port: Value(host.port),
          protocol: Value(protocol),
          identityId: Value(key),
          connectViaId: Value(via),
          createdAt: at,
          updatedAt: at,
        ));
    if (place) await CratePlacement(db).place('host', id, crate);
    return (await db.connectionsDao.getById(id))!;
  }

  /// A key with a password, saved in [crate] of the Orchard.
  Future<void> addKey(String id, String crate, {String password = 'made-up for this test'}) async {
    final db = orchardDb();
    final at = DateTime(2026, 10, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: id, label: id, username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await CratePlacement(db).place('key', id, crate);
    await OrchardIdentitySecrets(db).write(id, IdentitySecret.password, password);
  }

  Matcher closedCrate(String crateId, int hours, [String? message]) => isA<CrateClosedOffline>()
      .having((e) => e.crateId, 'crateId', crateId)
      .having((e) => e.hours, 'hours', hours)
      .having((e) => e.message, 'message', message ?? closedProduction)
      .having((e) => '$e', 'as text', message ?? closedProduction);

  test('which Crates are closed: none without a limit, each by its own, measured from when the device last reached '
      'ZestSSH Cloud, and open again the moment it does', () async {
    final db = orchardDb();
    expect(await closedCratesIn(tree), isEmpty, reason: 'your Tree has no Crates');
    expect(await closedCratesIn(db), isEmpty);
    // However long the device stays away, a Crate without a limit of its
    // own stays open.
    clock += 1000 * _hour;
    expect(await closedCratesIn(db), isEmpty);
    await reached();
    final last = clock;

    await limit(production, 24);
    expect(await closedCratesIn(db), isEmpty, reason: 'in contact a moment ago');
    clock = last + 24 * _hour;
    expect(await closedCratesIn(db), isEmpty, reason: 'at the limit, not past it');
    clock = last + 24 * _hour + 1;
    expect(await closedCratesIn(db), {production: 24});

    // Each Crate by its own limit.
    await limit(lab, 72);
    expect(await closedCratesIn(db), {production: 24});
    clock = last + 72 * _hour;
    expect(await closedCratesIn(db), {production: 24});
    clock = last + 72 * _hour + 1;
    expect(await closedCratesIn(db), {production: 24, lab: 72});

    // Back in contact: both are open, from that moment.
    await reached();
    expect(await closedCratesIn(db), isEmpty);
    clock += 25 * _hour;
    expect(await closedCratesIn(db), {production: 24});
    // A limit taken off opens what it had closed, and a longer one too.
    await limit(production, 0);
    expect(await closedCratesIn(db), isEmpty);
    await limit(production, 1);
    expect(await closedCratesIn(db), {production: 1});
    await limit(production, 26);
    expect(await closedCratesIn(db), isEmpty);
    // It is no rule of the Orchard: that stays open.
    expect(container.read(orchardDatabasesProvider.notifier).closedOffline, isEmpty);
    expect((await readOrchardSummary(db, orchardId)).rules.offlineHours, 0);
  });

  test('which Crates are about to close, and when: in the last quarter of their limit, and no longer once closed',
      () async {
    final db = orchardDb();
    await limit(production, 24);
    await limit(lab, 72);
    final last = clock;
    Future<Map<String, int>> closing() async => (await crateLimitsIn(db)).closing;
    Future<Map<String, int>> closed() async => (await crateLimitsIn(db)).closed;
    expect(await closing(), isEmpty);
    clock = last + 18 * _hour - 1;
    expect(await closing(), isEmpty, reason: 'six hours and a second before Production closes');
    clock = last + 18 * _hour;
    expect(await closing(), {production: last + 24 * _hour}, reason: 'with the last moment it is open');
    expect(await closed(), isEmpty);
    clock = last + 24 * _hour;
    expect(await closing(), {production: last + 24 * _hour});
    // Closed, it is no longer about to close; Lab is not near yet.
    clock = last + 24 * _hour + 1;
    expect(await closing(), isEmpty);
    expect(await closed(), {production: 24});
    clock = last + 54 * _hour;
    expect(await closing(), {lab: last + 72 * _hour});
    expect(await closed(), {production: 24});
    // Back in contact, nothing is about to close.
    await reached();
    expect(await closing(), isEmpty);
    expect(await closed(), isEmpty);
    // What cannot be measured is closed, not about to be.
    attachDeviceContact(db, null);
    expect(await closing(), isEmpty);
    expect(await closed(), {production: 24, lab: 72});
    // Your Tree has nothing of the kind.
    expect((await crateLimitsIn(tree)).closing, isEmpty);
    expect((await crateLimitsIn(tree)).closed, isEmpty);
  });

  test("the Orchard's own limit is about to close all of it: when, as its database can tell", () async {
    final db = orchardDb();
    final last = clock;
    expect(await orchardClosingAt(db, 0), isNull, reason: 'no limit');
    expect(await orchardClosingAt(db, 24), isNull, reason: 'in contact a moment ago');
    clock = last + 18 * _hour - 1;
    expect(await orchardClosingAt(db, 24), isNull);
    clock = last + 18 * _hour;
    expect(await orchardClosingAt(db, 24), last + 24 * _hour);
    expect(await orchardClosingAt(db, 168), isNull, reason: 'a week is far off');
    clock = last + 24 * _hour + 1;
    expect(await orchardClosingAt(db, 24), isNull, reason: 'past it: the scheduler closes it');
    // Read afresh when the app is unlocked anew.
    clock = last + 20 * _hour;
    container.invalidate(orchardContactProvider);
    expect(await orchardClosingAt(db, 24), last + 24 * _hour);
    // A database nobody told how the device stands says nothing.
    attachDeviceContact(db, null);
    expect(await orchardClosingAt(db, 24), isNull);

    // What was kept of the contact is read afresh at each unlock: an answer
    // waits for that, and goes by what was read. With no limit, nobody is
    // asked how the device stands.
    final read = Completer<void>();
    var kept = const OrchardContact();
    var asked = 0;
    attachDeviceContact(
        db,
        DeviceContact(
            read: () {
              asked++;
              return kept;
            },
            now: () => last + 20 * _hour,
            loaded: () {
              asked++;
              return read.future;
            }));
    expect(await orchardClosingAt(db, 0), isNull);
    expect(asked, 0);
    var answered = false;
    int? answer;
    unawaited(orchardClosingAt(db, 24).then((a) {
      answer = a;
      answered = true;
    }));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(answered, isFalse, reason: 'not answered from a contact that has not been read yet');
    kept = OrchardContact(lastContact: last, latest: last + 20 * _hour);
    read.complete();
    await until(() => answered, what: 'the answer');
    expect(answer, last + 24 * _hour);
  });

  test("an Orchard's summary says when by the rules this device is held to, where those are the stricter ones",
      () async {
    await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
    final db = orchardDb();
    final last = clock;
    Future<int?> closesAt() async => (await readOrchardSummary(db, orchardId)).closesAt;
    clock = last + 6 * _hour;
    expect(await closesAt(), isNull, reason: 'a quarter of the day it has');
    // ZestSSH Cloud holds this device to eight hours.
    await db.customStatement('UPDATE orchard_info SET held = ? WHERE id = 1', [
      jsonEncode({
        'unmet': const <String>[],
        'device_rules': {'offline_hours': 8},
      }),
    ]);
    expect(await closesAt(), last + 8 * _hour);
    clock = last + 6 * _hour - 1;
    expect(await closesAt(), isNull);
  });

  test('a limit that cannot be measured counts as reached; a proven outage of ours does not count towards it',
      () async {
    final db = orchardDb();
    await limit(production, 24);
    final t = clock;
    Future<Map<String, int>> with_(DeviceContact? contact) async {
      attachDeviceContact(db, contact);
      return closedCratesIn(db);
    }

    // Nobody told this database how the device stands: closed.
    expect(await with_(null), {production: 24});
    expect(await with_(null), isNot(contains(lab)), reason: 'a Crate with no limit of its own is never closed');
    // A device that has not reached ZestSSH Cloud since the limit was kept.
    expect(await with_(DeviceContact(read: () => const OrchardContact(), now: () => t)), {production: 24});
    // In contact an hour ago: open.
    expect(await with_(DeviceContact(read: () => OrchardContact(lastContact: t - _hour, latest: t), now: () => t)),
        isEmpty);
    // A clock turned back by more than a clock is ever corrected by: it
    // read two hours later than it does now.
    expect(
        await with_(DeviceContact(
            read: () => OrchardContact(lastContact: t - _hour, latest: t + 2 * _hour), now: () => t)),
        {production: 24});
    expect(
        await with_(DeviceContact(
            read: () => OrchardContact(lastContact: t - _hour, latest: t + kClockSlack.inSeconds), now: () => t)),
        isEmpty,
        reason: 'within what a clock is corrected by');
    // Away for thirty hours, seven of them an outage of ZestSSH Cloud's own
    // that its status service proved: twenty-three count.
    expect(
        await with_(DeviceContact(
            read: () => OrchardContact(lastContact: t - 30 * _hour, latest: t, excused: 7 * _hour), now: () => t)),
        isEmpty);
    expect(
        await with_(DeviceContact(
            read: () => OrchardContact(lastContact: t - 30 * _hour, latest: t, excused: 5 * _hour), now: () => t)),
        {production: 24});
    // No more than seven days of one stretch are ever excused, whatever
    // was kept.
    final long = 24 * _hour + 8 * 24 * _hour;
    expect(
        await with_(DeviceContact(
            read: () => OrchardContact(lastContact: t - long, latest: t, excused: 9 * 24 * _hour), now: () => t)),
        {production: 24});

    // What was kept of the contact is read afresh at each unlock: an answer
    // waits for that, and goes by what was read.
    final read = Completer<void>();
    var kept = const OrchardContact();
    attachDeviceContact(db, DeviceContact(read: () => kept, now: () => t, loaded: () => read.future));
    Map<String, int>? answer;
    unawaited(closedCratesIn(db).then((a) => answer = a));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(answer, isNull, reason: 'not answered from a contact that has not been read yet');
    kept = OrchardContact(lastContact: t - _hour, latest: t);
    read.complete();
    await until(() => answer != null, what: 'the answer');
    expect(answer, isEmpty);

    // Where no Crate has a limit, nobody is asked how the device stands.
    await limit(production, 0);
    var asked = 0;
    OrchardContact counted() {
      asked++;
      return const OrchardContact();
    }

    expect(
        await with_(DeviceContact(
            read: counted,
            now: () {
              asked++;
              return t;
            },
            loaded: () async => asked++)),
        isEmpty);
    expect(asked, 0);
    await limit(lab, 1);
    expect(await closedCratesIn(db), {lab: 1});
    expect(asked, 3, reason: 'with a limit to measure: what was kept, the contact, the clock');
  });

  test('started again, the app reads what it kept of the contact before a Crate is judged by it', () async {
    final db = orchardDb();
    await limit(production, 24);
    // The app is unlocked anew twenty-three hours after the device last
    // reached ZestSSH Cloud: what was kept says so, once it has been read.
    clock += 23 * _hour;
    container.invalidate(orchardContactProvider);
    expect(await closedCratesIn(db), isEmpty, reason: 'not judged by a contact that has not been read yet');
    expect(container.read(orchardContactProvider).lastContact, clock - 23 * _hour);
    // And two hours later it is past the day, by that same kept contact.
    clock += 2 * _hour;
    container.invalidate(orchardContactProvider);
    expect(await closedCratesIn(db), {production: 24});
    // The clock that is asked is the device's, as the app has it.
    clock -= 2 * _hour;
    expect(await closedCratesIn(db), isEmpty);
  });

  test('the items of a closed Crate allow nothing, in a session and on the screens; the Crate beside it and the '
      'placement of items are as they were', () async {
    final db = orchardDb();
    await addKey('k-prod', production);
    await addKey('k-lab', lab);
    await addHost('h-prod', production, key: 'k-prod');
    await addHost('h-lab', lab, key: 'k-lab', label: 'lab-01');
    await limit(production, 24);
    final placement = CratePlacement(db);
    final writable = await placement.writableCrates();
    final target = await placement.defaultCrate();
    final recordSwitches = await placement.switchesOf(production);
    expect(recordSwitches, containsAll([CrateSwitches.reveal, CrateSwitches.edit, CrateSwitches.sftp]));

    Future<void> asOpen() async {
      for (final (kind, key) in [('host', 'h-prod'), ('key', 'k-prod'), ('host', 'h-lab'), ('key', 'k-lab')]) {
        expect(await itemSwitchesIn(db, kind, key), recordSwitches, reason: '$kind $key');
      }
      expect(await hostAllowsIn(db, 'h-prod', CrateSwitches.sftp), isTrue);
      expect(await hostAllowsIn(db, 'h-prod', CrateSwitches.forward), isTrue);
      expect(await mayEditIn(db, 'host', 'h-prod'), isTrue);
      await requireRevealIn(db, 'k-prod', refusal: 'no');
      expect(await itemClosedIn(db, 'host', 'h-prod'), isNull);
      final summary = await readOrchardSummary(db, orchardId);
      for (final c in summary.crates) {
        expect((c.closedOffline, c.level), (false, 'manage'), reason: c.name);
        expect(c.switches, recordSwitches, reason: c.name);
        expect((c.canAdd, c.canWrite, c.allows(CrateSwitches.manage)), (true, true, true), reason: c.name);
      }
      expect({for (final c in summary.crates) c.name: c.offlineHours}, {'Production': 24, 'Lab': 0});
    }

    await asOpen();
    clock += 24 * _hour + 1;

    // In a session: no switch of any kind for what Production holds.
    expect(await itemSwitchesIn(db, 'host', 'h-prod'), isEmpty);
    expect(await itemSwitchesIn(db, 'key', 'k-prod'), isEmpty);
    expect(await hostAllowsIn(db, 'h-prod', CrateSwitches.sftp), isFalse);
    expect(await hostAllowsIn(db, 'h-prod', CrateSwitches.forward), isFalse);
    expect(await hostAllowsIn(db, 'h-prod', CrateSwitches.agent), isFalse);
    expect(await mayEditIn(db, 'host', 'h-prod'), isFalse);
    expect(await mayEditIn(db, 'key', 'k-prod'), isFalse);
    await expectLater(requireRevealIn(db, 'k-prod', refusal: 'not shown'),
        throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', 'not shown')));
    expect(await itemClosedIn(db, 'host', 'h-prod'), closedCrate(production, 24));
    expect(await itemClosedIn(db, 'key', 'k-prod'), closedCrate(production, 24));
    // What a screen asks before it wakes a host (Wake-on-LAN): the host of
    // the space on screen, answered in the Crate's own words.
    final onScreen = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),databaseProvider.overrideWithValue(db)]);
    addTearDown(onScreen.dispose);
    expect(await onScreen.read(hostClosedProvider)('h-prod'), closedCrate(production, 24));
    expect(await onScreen.read(hostClosedProvider)('h-lab'), isNull);
    // Lab is as it was.
    expect(await itemSwitchesIn(db, 'host', 'h-lab'), recordSwitches);
    expect(await itemSwitchesIn(db, 'key', 'k-lab'), recordSwitches);
    expect(await hostAllowsIn(db, 'h-lab', CrateSwitches.sftp), isTrue);
    expect(await mayEditIn(db, 'key', 'k-lab'), isTrue);
    await requireRevealIn(db, 'k-lab', refusal: 'no');
    expect(await itemClosedIn(db, 'host', 'h-lab'), isNull);
    expect(await itemClosedIn(db, 'key', 'k-lab'), isNull);
    // Your Tree's items are yours, as ever.
    expect(await itemSwitchesIn(tree, 'host', 'h-prod'), isNull);
    expect(await itemClosedIn(tree, 'host', 'h-prod'), isNull);

    // On the screens: closed, allowing nothing, and still what it is.
    final summary = await readOrchardSummary(db, orchardId);
    final prod = summary.crates.singleWhere((c) => c.id == production);
    expect((prod.closedOffline, prod.offlineHours), (true, 24));
    expect(prod.switches, isEmpty);
    expect((prod.name, prod.level, prod.ownersOnly), ('Production', 'manage', false));
    expect((prod.canAdd, prod.canWrite), (false, false));
    for (final what in CrateSwitches.all) {
      expect(prod.allows(what), isFalse, reason: what);
    }
    final other = summary.crates.singleWhere((c) => c.id == lab);
    expect((other.closedOffline, other.offlineHours), (false, 0));
    expect(other.switches, recordSwitches);
    expect(summary.active, isTrue, reason: 'the Orchard itself is open');
    expect(summary.closedOffline, isFalse);

    // Where items are kept is bookkeeping, and stays put: a Crate that is
    // closed for a while is still where its items are, and where new ones
    // made here would go.
    expect(await placement.writableCrates(), writable);
    expect(await placement.defaultCrate(), target);
    expect(await placement.switchesOf(production), recordSwitches);
    expect(await placement.crateOf('host', 'h-prod'), production);

    // Back in contact, everything is as it was.
    await reached();
    await asOpen();
  });

  test('a closed Crate hands out none of its secrets, to whoever asks, and has lost none of them when it opens',
      () async {
    final db = orchardDb();
    await addKey('k-prod', production, password: 'made-up one');
    await addKey('k-lab', lab, password: 'made-up two');
    final secrets = OrchardIdentitySecrets(db);
    await secrets.write('k-prod', IdentitySecret.privateKey, 'a made-up private key');
    await secrets.write('k-prod', IdentitySecret.passphrase, 'a made-up passphrase');
    await secrets.write('k-prod', IdentitySecret.certificate, 'a made-up certificate');
    await limit(production, 24);
    final all = {
      IdentitySecret.password: 'made-up one',
      IdentitySecret.privateKey: 'a made-up private key',
      IdentitySecret.passphrase: 'a made-up passphrase',
      IdentitySecret.certificate: 'a made-up certificate',
    };
    for (final e in all.entries) {
      expect(await secrets.read('k-prod', e.key), e.value, reason: e.key.name);
    }

    clock += 24 * _hour + 1;
    for (final secret in [IdentitySecret.password, IdentitySecret.privateKey, IdentitySecret.passphrase]) {
      await expectLater(secrets.read('k-prod', secret), throwsA(closedCrate(production, 24)), reason: secret.name);
    }
    // A certificate is no secret, and of no use without its key.
    expect(await secrets.read('k-prod', IdentitySecret.certificate), 'a made-up certificate');
    // The app's own reader of the keys of the space on screen says the same.
    final crud = container.read(identityCrudProvider);
    await expectLater(crud.getPassword('k-prod'), throwsA(closedCrate(production, 24)));
    await expectLater(crud.getPrivateKey('k-prod'), throwsA(closedCrate(production, 24)));
    await expectLater(crud.getKeyPassphrase('k-prod'), throwsA(closedCrate(production, 24)));
    // Whatever the store is made for: the one a session reads through.
    await expectLater(
        IdentitySecretStore.forDatabase(db, container.read(secureStorageProvider))
            .read('k-prod', IdentitySecret.password),
        throwsA(closedCrate(production, 24)));
    // The key in the Crate beside it is read as ever.
    expect(await secrets.read('k-lab', IdentitySecret.password), 'made-up two');
    expect(await crud.getPassword('k-lab'), 'made-up two');
    // A key of a closed Crate that has no such secret is refused all the
    // same: "it has none" is an answer too, and could be kept as the truth.
    await secrets.write('k-prod', IdentitySecret.passphrase, null);
    await expectLater(secrets.read('k-prod', IdentitySecret.passphrase), throwsA(closedCrate(production, 24)));
    await secrets.write('k-prod', IdentitySecret.passphrase, 'a made-up passphrase');

    await reached();
    for (final e in all.entries) {
      expect(await secrets.read('k-prod', e.key), e.value, reason: '${e.key.name}, after it opened again');
    }
    expect(await crud.getPassword('k-prod'), 'made-up one');
  });

  test('nothing signs in to a host, or with a key, of a closed Crate; an address typed for a quick connect uses '
      'nothing a Crate holds', () async {
    final db = orchardDb();
    await addKey('k-prod', production);
    await addKey('k-lab', lab);
    await addHost('h-prod', production);
    await addHost('h-lab', lab, label: 'lab-01');
    await limit(production, 24);
    // New items made on this device go into Production.
    await CratePlacement(db).setDefaultCrate(production);
    expect(await CratePlacement(db).defaultCrate(), production);
    await addHost('h-new', production, label: 'new-01', place: false);

    // Open: nothing is refused.
    await requireCratesOpenIn(db, hostId: 'h-prod', keyId: 'k-prod');
    clock += 24 * _hour + 1;

    await expectLater(requireCratesOpenIn(db, hostId: 'h-prod'), throwsA(closedCrate(production, 24)));
    await expectLater(requireCratesOpenIn(db, keyId: 'k-prod'), throwsA(closedCrate(production, 24)));
    await expectLater(requireCratesOpenIn(db, hostId: 'h-prod', keyId: 'k-lab'), throwsA(closedCrate(production, 24)));
    await expectLater(requireCratesOpenIn(db, hostId: 'h-lab', keyId: 'k-prod'), throwsA(closedCrate(production, 24)));
    // A host made here that has not synced yet is in the Crate new items go
    // into, which is the closed one.
    await expectLater(requireCratesOpenIn(db, hostId: 'h-new'), throwsA(closedCrate(production, 24)));
    // What is in Lab signs in as ever.
    await requireCratesOpenIn(db, hostId: 'h-lab');
    await requireCratesOpenIn(db, hostId: 'h-lab', keyId: 'k-lab');
    // An address typed for a quick connect is saved nowhere and uses
    // nothing of a Crate, unless it is given a key of one.
    await requireCratesOpenIn(db, hostId: 'quick_1790000000');
    await requireCratesOpenIn(db, hostId: 'quick_1790000000', keyId: 'k-lab');
    await requireCratesOpenIn(db);
    await expectLater(
        requireCratesOpenIn(db, hostId: 'quick_1790000000', keyId: 'k-prod'), throwsA(closedCrate(production, 24)));
    // Your Tree has no Crates to close.
    await requireCratesOpenIn(tree, hostId: 'h-prod', keyId: 'k-prod');

    // Back in contact, nothing is refused.
    await reached();
    await requireCratesOpenIn(db, hostId: 'h-prod', keyId: 'k-prod');
    await requireCratesOpenIn(db, hostId: 'h-new');
  });

  test('nothing leaves a closed Crate and nothing arrives in one: moved to a Crate that is open, an item would be '
      'open with it', () async {
    final db = orchardDb();
    await addHost('h-prod', production);
    await addHost('h-lab', lab, label: 'lab-01');
    // One that the server already has, and one made here that it has not.
    await OrchardSyncCoordinator(service: dana, server: dana.server, databases: dana.databases).syncAll();
    await addHost('h-prod-new', production, label: 'web-02');
    await limit(production, 24);
    final placement = CratePlacement(db);
    Future<Map<String, String?>> where() async => {
          for (final id in ['h-prod', 'h-prod-new', 'h-lab']) id: await placement.crateOf('host', id),
        };
    final asPlaced = {'h-prod': production, 'h-prod-new': production, 'h-lab': lab};
    Future<int> queued() async =>
        (await db.customSelect('SELECT COUNT(*) AS n FROM crate_outbox').getSingle()).read<int>('n');

    // Open: a host moves to the other Crate and back.
    await placement.moveItem('host', 'h-prod', lab);
    expect((await where())['h-prod'], lab);
    await placement.moveItem('host', 'h-prod', production);
    expect(await where(), asPlaced);
    final waiting = await queued();

    clock += 24 * _hour + 1;
    // Out of the closed Crate: neither what the server has, nor what was
    // made here; by a move, and by being placed.
    for (final id in ['h-prod', 'h-prod-new']) {
      await expectLater(placement.moveItem('host', id, lab), throwsA(closedCrate(production, 24)), reason: id);
      await expectLater(placement.place('host', id, lab), throwsA(closedCrate(production, 24)), reason: id);
    }
    // Into it.
    await expectLater(placement.moveItem('host', 'h-lab', production), throwsA(closedCrate(production, 24)));
    await expectLater(placement.place('host', 'h-lab', production), throwsA(closedCrate(production, 24)));
    expect(await where(), asPlaced, reason: 'everything is where it was');
    expect(await queued(), waiting, reason: 'and nothing waits to be sent');
    // A new item is not put into the closed Crate, and goes into the open
    // one as ever, wherever new items would have gone by themselves.
    await placement.setDefaultCrate(lab);
    await addHost('h-fresh', production, label: 'web-03', place: false);
    await expectLater(placement.place('host', 'h-fresh', production), throwsA(closedCrate(production, 24)));
    await placement.place('host', 'h-fresh', lab);
    expect(await placement.crateOf('host', 'h-fresh'), lab);
    // What a screen says of it: the Crate's own words.
    try {
      await placement.moveItem('host', 'h-prod', lab);
      fail('moved out of a closed Crate');
    } catch (e) {
      expect(orchardErrorMessage(e, l10n), closedProduction);
    }

    // Back in contact, a host moves as before.
    await reached();
    await placement.moveItem('host', 'h-prod', lab);
    expect((await where())['h-prod'], lab);
    await placement.place('host', 'h-prod-new', lab);
    expect((await where())['h-prod-new'], lab);
  });

  test('what is said of a closed Crate names it, follows what is known of the service, and is said in every language',
      () async {
    final db = orchardDb();
    await addHost('h-prod', production);
    await limit(production, 24);
    clock += 24 * _hour + 1;

    // Where ZestSSH Cloud is the one that cannot be reached, nobody is sent
    // looking for a fault of their own.
    for (final reach in CloudReach.values) {
      final ours = reach == CloudReach.down || reach == CloudReach.notResponding || reach == CloudReach.fault;
      expect(crateClosedOfflineText(l10n, 'Production', reach),
          ours ? l10n.crateClosedOfflineCloud('Production') : l10n.crateClosedOfflineError('Production'),
          reason: reach.name);
    }
    expect(crateClosedOfflineText(l10n, 'Production', null), l10n.crateClosedOfflineError('Production'));
    expect(l10n.crateClosedOfflineError('Production'), isNot(l10n.crateClosedOfflineCloud('Production')));

    // As the app knows it at that moment.
    expect((await itemClosedIn(db, 'host', 'h-prod'))!.message, l10n.crateClosedOfflineError('Production'));
    final reach = CloudReachService(
      check: () async => throw const SocketException('Connection refused'),
      timer: (wait, then) => Timer(const Duration(days: 1), () {}),
    );
    addTearDown(reach.dispose);
    await reach.checkNow();
    expect(reach.state.value.reach, CloudReach.notResponding);
    currentCloudReach = reach;
    expect((await itemClosedIn(db, 'host', 'h-prod'))!.message, l10n.crateClosedOfflineCloud('Production'));
    await expectLater(requireCratesOpenIn(db, hostId: 'h-prod'),
        throwsA(closedCrate(production, 24, l10n.crateClosedOfflineCloud('Production'))));
    currentCloudReach = null;

    // A Crate whose name has not opened on this device is still spoken of.
    await db.customStatement('UPDATE orchard_crates SET name = NULL WHERE crate_id = ?', [production]);
    expect((await itemClosedIn(db, 'host', 'h-prod'))!.message, l10n.crateClosedOfflineError(l10n.crateUnnamed));
    await db.customStatement("UPDATE orchard_crates SET name = '' WHERE crate_id = ?", [production]);
    expect((await itemClosedIn(db, 'host', 'h-prod'))!.message, l10n.crateClosedOfflineError(l10n.crateUnnamed));
    await db.customStatement("UPDATE orchard_crates SET name = 'Production' WHERE crate_id = ?", [production]);

    // Every language names the Crate, says the two cases differently, and
    // the refusal carries the words of the language the app is in.
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      L10nGlobal.update(words);
      final offline = words.crateClosedOfflineError('Production');
      final cloud = words.crateClosedOfflineCloud('Production');
      expect(offline, contains('Production'), reason: '$locale');
      expect(cloud, contains('Production'), reason: '$locale');
      expect(cloud, contains('ZestSSH Cloud'), reason: '$locale');
      expect(offline, isNot(cloud), reason: '$locale');
      expect((await itemClosedIn(db, 'host', 'h-prod'))!.message, offline, reason: '$locale');
    }
    L10nGlobal.update(l10n);
  });

  test('through the app\'s own session code: a host of a closed Crate is not dialled, and the failure says why in '
      'the app\'s own words; a session that is up stays up; back in contact, it connects again', () async {
    await addHost('h-prod', production);
    final other = await addHost('h-lab', lab, label: 'lab-01');
    await limit(production, 24);
    final db = orchardDb();
    Future<Connection> prod() async => (await db.connectionsDao.getById('h-prod'))!;

    // Open: it connects.
    final first = sessions().startSession(await prod())!;
    await until(() => stateOf(first)?.status == SessionStatus.connected, what: 'the session');
    await until(() => host.sockets.length == 1, what: 'the host\'s side of it');

    clock += 24 * _hour + 1;
    // What is up stays up: the limit keeps a device from starting anything.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(stateOf(first)!.status, SessionStatus.connected);

    // A new session to it: refused before anything is dialled.
    container.read(connectionErrorProvider.notifier).state = null;
    // (Asked for again, the app shows the session that is up; a second one
    // beside it is what "Duplicate session" starts.)
    expect(sessions().startSession(await prod()), first);
    final second = sessions().startSession(await prod(), allowDuplicate: true)!;
    expect(second, isNot(first));
    await until(() => stateOf(second)?.status == SessionStatus.error, what: 'the refusal');
    expect(host.sockets, hasLength(1), reason: 'nothing more reached the host');
    final failure = container.read(connectionErrorProvider)!;
    expect(failure.errorMessage, translator.saidByApp(closedProduction));
    expect(stateOf(second)!.errorMessage, translator.saidByApp(closedProduction));
    // As a screen shows it: the reason as the app wrote it, and no guess.
    final shown = translator.ConnectionError.translate(failure.errorMessage, host: '127.0.0.1', port: host.port);
    expect((shown.type, shown.description), (translator.ConnectionErrorType.saidByApp, closedProduction));
    expect(shown.tip, isNull);

    // A host of the Crate beside it connects as ever.
    final third = sessions().startSession(other)!;
    await until(() => stateOf(third)?.status == SessionStatus.connected, what: 'the session to the other Crate');
    await until(() => host.sockets.length == 2, what: 'its side of it');

    // Back in contact: the host of the Crate that was closed connects.
    await reached();
    final fourth = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(fourth)?.status == SessionStatus.connected, what: 'the session, once open again');
    await until(() => host.sockets.length == 3, what: 'the host\'s side of it');
  });

  test('a host of a Crate held until a set time that has come is refused in words that say so, and no offline '
      'pass is offered for it: none opens it', () async {
    await addHost('h-prod', production);
    final db = orchardDb();
    Future<Connection> prod() async => (await db.connectionsDao.getById('h-prod'))!;
    // As the Orchard's database keeps it once it was brought up to date:
    // held until a second ago.
    await LocalStateStore(db).write(kAccessUntilState, jsonEncode({production: clock - 1}));
    final over = l10n.crateAccessOverError('Production');
    final refusal = (await itemClosedIn(db, 'host', 'h-prod'))!;
    expect((refusal.accessOver, refusal.hours, refusal.orchardId, '$refusal'), (true, 0, orchardId, over));
    expect(orchardErrorMessage(refusal, l10n), over);

    final first = sessions().startSession(await prod())!;
    await until(() => stateOf(first)?.status == SessionStatus.error, what: 'the refusal');
    expect(host.sockets, isEmpty, reason: 'nothing reached the host');
    expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(over));
    expect(container.read(offlinePassOfferProvider), isEmpty, reason: 'a pass is not what it lacks');

    // An offline limit that is reached as well changes neither: the time
    // that is over is what is said, and no pass is offered.
    await limit(production, 24);
    clock += 24 * _hour + 1;
    await LocalStateStore(db).write(kAccessUntilState, jsonEncode({production: clock - 1}));
    final both = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(both)?.status == SessionStatus.error, what: 'the refusal, again');
    expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(over));
    expect(container.read(offlinePassOfferProvider), isEmpty);
    await reached();

    // Held for a minute more: it connects.
    await LocalStateStore(db).write(kAccessUntilState, jsonEncode({production: clock + 60}));
    final second = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(second)?.status == SessionStatus.connected, what: 'the session');
    await until(() => host.sockets.length == 1, what: 'its side of it');
  });

  test('a connection refused for a closed Crate offers an offline pass for that Crate, until the host connects '
      'or fails for another reason', () async {
    await addHost('h-prod', production);
    await limit(production, 24);
    final db = orchardDb();
    Future<Connection> prod() async => (await db.connectionsDao.getById('h-prod'))!;
    Map<String, ({String orchardId, String crateId})> offers() => container.read(offlinePassOfferProvider);
    expect(offers(), isEmpty);
    // (Whatever shows a failure watches this: told when it changes, only.)
    var told = 0;
    final watching = container.listen(offlinePassOfferProvider, (_, _) => told++);
    addTearDown(watching.close);

    clock += 24 * _hour + 1;
    // The refusal names its Orchard, for whatever shows it.
    expect((await itemClosedIn(db, 'host', 'h-prod'))!.orchardId, orchardId);
    final first = sessions().startSession(await prod())!;
    await until(() => stateOf(first)?.status == SessionStatus.error, what: 'the refusal');
    expect(offers(), {'h-prod': (orchardId: orchardId, crateId: production)});
    expect(told, 1);
    expect(container.read(certificateFromOwnerOfferProvider), isEmpty, reason: 'a certificate is not what it lacks');

    // It fails for another reason (the Crate is open again, and nothing
    // listens where the host was): there is nothing of the kind to offer.
    await reached();
    final gone = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final dead = gone.port;
    await gone.close();
    await db.customStatement('UPDATE connections SET port = ? WHERE id = ?', [dead, 'h-prod']);
    final second = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(second)?.status == SessionStatus.error, what: 'the failure');
    expect(offers(), isEmpty);
    expect(told, 2);
    // The same failure again: nothing was kept, and nobody is told anything.
    final again = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(again)?.status == SessionStatus.error, what: 'the failure, again');
    expect(offers(), isEmpty);
    expect(told, 2);

    // Offered again when it is closed again, and gone when the host connects.
    clock += 24 * _hour + 1;
    final third = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(third)?.status == SessionStatus.error, what: 'the refusal');
    expect(offers(), {'h-prod': (orchardId: orchardId, crateId: production)});
    await reached();
    await db.customStatement('UPDATE connections SET port = ? WHERE id = ?', [host.port, 'h-prod']);
    final fourth = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(fourth)?.status == SessionStatus.connected, what: 'the session');
    expect(offers(), isEmpty);
    expect(told, 4);
    // Connected once more: nothing was kept, and nobody is told anything.
    final fifth = sessions().startSession(await prod(), allowDuplicate: true)!;
    await until(() => stateOf(fifth)?.status == SessionStatus.connected, what: 'another session');
    expect(offers(), isEmpty);
    expect(told, 4);
  });

  test('a key of a closed Crate signs in nowhere, a host of one is no hop, and the app polls nothing of it by '
      'itself', () async {
    final db = orchardDb();
    await addKey('k-prod', production);
    await addKey('k-lab', lab);
    final prodHost = await addHost('h-prod', production, protocol: 'ssh', key: 'k-prod');
    final withProdKey = await addHost('h-lab-prodkey', lab, protocol: 'ssh', key: 'k-prod', label: 'lab-01');
    final labHost = await addHost('h-lab', lab, protocol: 'ssh', key: 'k-lab', label: 'lab-02');
    final behind = await addHost('h-behind', lab, protocol: 'ssh', key: 'k-lab', via: 'h-prod', label: 'lab-03');
    final serial = await addHost('h-serial', lab, protocol: 'serial', key: 'k-prod', label: 'console-01');
    // A key of Production that has nothing saved (its password is asked
    // for at each login), on a host of Lab.
    final at = DateTime(2026, 10, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-prod-ask',
        label: 'asks each time',
        username: 'deploy',
        authMethod: 'password',
        createdAt: at,
        updatedAt: Value(at)));
    await CratePlacement(db).place('key', 'k-prod-ask', production);
    final asksEachTime = await addHost('h-lab-ask', lab, protocol: 'ssh', key: 'k-prod-ask', label: 'lab-04');
    // Two hops: a host of Lab, reached through one of Production, reached
    // through another of Lab.
    await addHost('h-outer', lab, protocol: 'ssh', key: 'k-lab', label: 'lab-05');
    await addHost('h-middle', production, protocol: 'ssh', key: 'k-lab', via: 'h-outer', label: 'web-02');
    final far = await addHost('h-far', lab, protocol: 'ssh', key: 'k-lab', via: 'h-middle', label: 'lab-06');
    // A host of Production that signs in with a key of Lab, and a host of
    // Lab that signs in with a key pair of Production (made up here).
    final prodHostLabKey = await addHost('h-prod-labkey', production, protocol: 'ssh', key: 'k-lab', label: 'web-03');
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-prod-pair',
        label: 'a key pair',
        username: 'deploy',
        authMethod: 'publicKey',
        createdAt: at,
        updatedAt: Value(at)));
    await CratePlacement(db).place('key', 'k-prod-pair', production);
    await OrchardIdentitySecrets(db).write('k-prod-pair', IdentitySecret.privateKey,
        (await KeyGenerationService().generateEd25519(comment: 'made up for this test')).privatePem);
    final withProdPair = await addHost('h-lab-pair', lab, protocol: 'ssh', key: 'k-prod-pair', label: 'lab-07');
    await limit(production, 24);
    final factory = container.read(sshConnectionFactoryProvider);

    // Open: the keys resolve for the app's own polling.
    expect(await factory.resolveCredentialsSilently(prodHost), isNotNull);
    expect(await factory.resolveCredentialsSilently(withProdKey), isNotNull);
    expect(await factory.resolveCredentialsSilently(labHost), isNotNull);
    expect(await factory.resolveCredentialsSilently(prodHostLabKey), isNotNull);
    expect((await factory.resolveCredentialsSilently(withProdPair))!.keyPairs, hasLength(1));

    clock += 24 * _hour + 1;
    Future<void> refused(Connection connection, String what) async {
      container.read(connectionErrorProvider.notifier).state = null;
      final id = sessions().startSession(connection)!;
      await until(() => stateOf(id)?.status == SessionStatus.error, what: what);
      expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(closedProduction),
          reason: what);
    }

    // A host of the open Crate that signs in with a key of the closed one.
    await refused(withProdKey, 'a key of the closed Crate');
    // Whatever the host speaks.
    await refused(serial, 'a key of the closed Crate, for a serial console');
    // A key of the closed Crate that holds nothing to read: nobody is even
    // asked for its password.
    await refused(asksEachTime, 'a key of the closed Crate with nothing saved');
    // A host of the closed Crate as a hop on the way to one that is open.
    await refused(behind, 'a hop in the closed Crate');
    // Also with an open hop before it: refused before that one is dialled.
    await refused(far, 'a hop in the closed Crate, behind an open one');
    // And the host itself.
    await refused(prodHost, 'a host of the closed Crate');
    expect(host.sockets, isEmpty, reason: 'nothing was dialled for any of them');

    // The app polls nothing of it by itself (the monitor).
    final polled = await sessions().openExecClient(prodHost);
    expect((polled.outcome, polled.detail), (MonitorExecOutcome.notEligible, 'its Crate is closed on this device'));
    // Nor do the checks of whether hosts can be reached connect to it,
    // where its person has them on.
    expect(await container.read(Provider((ref) => ReachabilityTargets(ref))).of(prodHost), isNull);
    final polledKey = await sessions().openExecClient(withProdKey);
    expect(
        (polledKey.outcome, polledKey.detail), (MonitorExecOutcome.notEligible, 'its Crate is closed on this device'));
    expect(await factory.resolveCredentialsSilently(prodHost), isNull);
    expect(await factory.resolveCredentialsSilently(withProdKey), isNull);
    // The host alone in the closed Crate, its key in the open one; and the
    // key alone in the closed Crate, a key pair this time: asked about
    // before it is read, so nothing is thrown at whoever polls.
    expect(await factory.resolveCredentialsSilently(prodHostLabKey), isNull);
    expect(await factory.resolveCredentialsSilently(withProdPair), isNull);
    // What is in Lab resolves as ever.
    expect(await factory.resolveCredentialsSilently(labHost), isNotNull);
    expect(host.sockets, isEmpty);

    // Back in contact, the keys resolve again.
    await reached();
    expect(await factory.resolveCredentialsSilently(prodHost), isNotNull);
    expect(await factory.resolveCredentialsSilently(withProdKey), isNotNull);
    expect(await factory.resolveCredentialsSilently(prodHostLabKey), isNotNull);
    expect(await factory.resolveCredentialsSilently(withProdPair), isNotNull);
  });

  group('before a limit closes something, the device says so', () {
    /// What stands in the app's notices about this Orchard closing.
    List<AppNotification> said() => [
          for (final n in container.read(notificationCenterProvider).history)
            if (n.id == offlineClosingNoticeId(orchardId)) n,
        ];
    // A time is written with the narrow space its language asks for before
    // "AM"; the app's notices keep plain spaces only.
    String plain(String text) => text.replaceAll(RegExp(r'\s+'), ' ');
    String at(int seconds) => plain(accessTimeText(seconds, l10n));
    String item(String name, int end) => l10n.offlineClosingItem(name, at(end));

    /// A sync that cannot finish, as on a device that is offline.
    Future<void> syncFails() async {
      container.read(orchardSyncProvider);
      sync.offline = true;
      await container.read(orchardSyncSchedulerProvider).syncAll();
    }

    test('what is about to close and when, once for each stretch away, and not in the moment before the first sync',
        () async {
      await limit(production, 24);
      await limit(lab, 26);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      int version() => container.read(orchardListVersionProvider);

      // Nothing is near: nothing is said, whatever the sync does, and the
      // app's notices are left as they are.
      var touched = 0;
      final watching = container.listen(notificationCenterProvider, (_, _) => touched++);
      await syncFails();
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse);
      expect(touched, 0);
      watching.close();

      // Six hours before Production closes. (A device that has just been
      // started has not tried to sync yet: see the next test.)
      clock = last + 18 * _hour;
      var seen = version();
      await scheduler.checkOfflineLimits();
      expect(scheduler.closingSoonHere, isTrue);
      expect(version(), greaterThan(seen), reason: 'the lists show when');
      final first = said().single;
      expect(first.title, l10n.offlineClosingTitle('Acme'));
      expect(first.body, l10n.offlineClosingBody(item('Production', last + 24 * _hour), at(last)));
      // A computer's toast says it in two lines, the paragraph is the bell's
      // (a design review found it cut at "This devi…").
      expect(first.summary, [item('Production', last + 24 * _hour), l10n.offlineClosingSummary]);
      expect(first.severity, NotificationSeverity.warning);
      expect(first.dismissAfter, Duration.zero, reason: 'it stays until it is read');
      // On the screens: when.
      final shown = (await container.read(orchardSummariesProvider.future)).single;
      expect({for (final c in shown.crates) c.name: c.closesAt}, {'Production': last + 24 * _hour, 'Lab': null});
      expect(shown.closesAt, isNull, reason: 'the Orchard itself has no limit');

      // Read and put away, it is not said again at the next look.
      container.read(notificationCenterProvider.notifier).remove(first.id);
      seen = version();
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect(version(), seen, reason: 'and nothing changed for the lists');

      // Lab is near as well: said again, both, the sooner first.
      clock = last + 20 * _hour;
      await scheduler.checkOfflineLimits();
      expect(
          said().single.body,
          l10n.offlineClosingBody(
              [item('Production', last + 24 * _hour), item('Lab', last + 26 * _hour)].join(l10n.listSeparator),
              at(last)));
      // The sooner one first, "+1" for the other.
      expect(said().single.summary, ['${item('Production', last + 24 * _hour)} · +1', l10n.offlineClosingSummary]);

      // Production has closed: what is still to come is said without it.
      clock = last + 24 * _hour + 1;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item('Lab', last + 26 * _hour), at(last)));
      expect(scheduler.cratesClosedHere, isTrue);

      // Back in contact: nothing is about to close, and the notice goes
      // with what it said.
      await reached();
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse);
      expect((await container.read(orchardSummariesProvider.future)).single.crates.map((c) => c.closesAt),
          everyElement(isNull));

      // Away again: said again, for this stretch.
      final again = clock;
      clock = again + 19 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item('Production', again + 24 * _hour), at(again)));

      // A look that was missed between two stretches (the app was locked
      // while the device reached ZestSSH Cloud): what was said in the one
      // before does not count for this one.
      await reached();
      final third = clock;
      clock = third + 19 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item('Production', third + 24 * _hour), at(third)));
    }, skip: !kOrchardsEnabled);

    test('the notice offers an offline pass: for the one Crate that is about to close, for all of the Orchard '
        'where more is at stake, and for nothing once the scheduler is stopped', () async {
      await limit(production, 24);
      await limit(lab, 26);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      ({String orchardId, String crateId})? asked() => container.read(passAskRequestProvider);
      void taken() => container.read(passAskRequestProvider.notifier).state = null;
      AppNotification press() {
        final n = said().single;
        expect(n.actionLabel, l10n.passAskButton);
        n.onAction!();
        return n;
      }

      await syncFails();
      // Production alone is about to close.
      clock = last + 18 * _hour;
      await scheduler.checkOfflineLimits();
      expect(asked(), isNull, reason: 'nothing is asked for until someone presses');
      press();
      expect(asked(), (orchardId: orchardId, crateId: production));
      taken();
      // Lab as well: one pass for all of the Orchard holds both open.
      clock = last + 20 * _hour;
      await scheduler.checkOfflineLimits();
      press();
      expect(asked(), (orchardId: orchardId, crateId: kAllOfOrchard));
      taken();
      // Production has closed and Lab is still to come: a pass for Lab
      // would leave Production closed, so all of it again.
      clock = last + 24 * _hour + 1;
      await scheduler.checkOfflineLimits();
      expect(scheduler.cratesClosedHere, isTrue);
      final left = press();
      expect(asked(), (orchardId: orchardId, crateId: kAllOfOrchard));
      taken();
      // Stopped (the account signed out, the app closing): a notice that is
      // still on screen asks for nothing.
      scheduler.stop();
      left.onAction!();
      expect(asked(), isNull);
    }, skip: !kOrchardsEnabled);

    test("where the Orchard's own limit is what is about to close, the pass asked for is for all of it", () async {
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      await syncFails();
      clock += 20 * _hour;
      await scheduler.checkOfflineLimits();
      said().single.onAction!();
      expect(container.read(passAskRequestProvider), (orchardId: orchardId, crateId: kAllOfOrchard));
    }, skip: !kOrchardsEnabled);

    test('back in contact, the notice goes at once, without waiting for the next look', () async {
      await limit(production, 24);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      // Twenty hours away, and the sync cannot finish: said by the look
      // that follows it. (Waited for: no look is under way from here on,
      // so that what takes the notice down is the one contact asks for.)
      clock += 20 * _hour;
      await syncFails();
      await until(() => said().isNotEmpty, what: 'the notice');
      // Reaching ZestSSH Cloud, as the app's own team service does it.
      container.read(orchardServiceProvider).onContact!.call();
      await until(() => said().isEmpty, what: 'the notice gone', turns: 400);
      expect(scheduler.closingSoonHere, isFalse);
    }, skip: !kOrchardsEnabled);

    test('a device that has just been started says nothing before it has tried to reach ZestSSH Cloud', () async {
      await limit(production, 24);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      clock = last + 20 * _hour;
      // The look the app takes as it starts: Production is near, and
      // nothing has been tried yet.
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isTrue, reason: 'the screens show it meanwhile');
      // The sync cannot finish: said at once, without waiting for the next
      // look.
      await syncFails();
      await until(() => said().isNotEmpty, what: 'the notice');
      expect(said().single.body, l10n.offlineClosingBody(item('Production', last + 24 * _hour), at(last)));
      expect(sync.runs, 1);
    }, skip: !kOrchardsEnabled);

    test('where ZestSSH Cloud is the one that does not answer, nobody is sent looking for a fault of their own',
        () async {
      await limit(production, 24);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      cloudAnswer = const SocketException('Connection refused');
      await container.read(cloudReachProvider).checkNow();
      expect(reach.state.value.reach, CloudReach.notResponding);
      await syncFails();
      clock = last + 18 * _hour;
      await scheduler.checkOfflineLimits();
      final n = said().single;
      expect(n.body, l10n.offlineClosingBodyCloud(item('Production', last + 24 * _hour), at(last)));
      expect(n.body, isNot(contains('internet')));
      expect(n.summary, [item('Production', last + 24 * _hour), l10n.offlineClosingSummaryCloud]);
      expect(n.summary!.join(' '), isNot(contains('internet')));
      expect(l10n.offlineClosingBody('x', 'y'), contains('Connecting to the internet'));
    }, skip: !kOrchardsEnabled);

    test("while a proof of an outage of ZestSSH Cloud's own covers the moment the limits stand still: nothing is "
        'about to close, and nobody is told that it is, until it is believed no longer or no more is excused',
        () async {
      await limit(production, 24);
      await dana.setRules(orchardId, const RecordRules(offlineHours: 26));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      Future<OrchardSummary> shown() async => (await container.read(orchardSummariesProvider.future)).single;
      String both(int production, int all) =>
          [item('Production', production), item(l10n.offlineClosingAll, all)].join(l10n.listSeparator);

      // Twenty hours away, and a sync that cannot finish: for all the
      // device knows it is cut off itself.
      await syncFails();
      clock = last + 20 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(both(last + 24 * _hour, last + 26 * _hour), at(last)));
      expect((await shown()).closesAt, last + 26 * _hour);

      // The status service says, signed, that ZestSSH Cloud has been down
      // for ten minutes, and that this may be believed for a quarter of an
      // hour: those minutes do not count, nor do the ones that pass while
      // it is believed, and nothing is about to close. What was said is
      // taken down.
      await scheduler.outageProven(since: clock - 600, at: clock, until: clock + 900);
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse);
      var now = await shown();
      expect(now.closesAt, isNull);
      expect(now.crates.map((c) => c.closesAt), everyElement(isNull));
      expect((await crateLimitsIn(orchardDb())).closing, isEmpty);
      // Nothing closed either: the limits themselves are as they were.
      expect(now.crates.map((c) => c.closedOffline), everyElement(isFalse));
      // So it stays up to the last moment the proof is believed.
      clock = last + 20 * _hour + 900;
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect((await shown()).closesAt, isNull);

      // No proof since (the status service cannot be reached either), and
      // the last is believed no longer: the limits run again, later by the
      // ten minutes that were counted and the fifteen that passed, and
      // what is near is said again.
      clock = last + 21 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body,
          l10n.offlineClosingBody(both(last + 24 * _hour + 1500, last + 26 * _hour + 1500), at(last)));
      expect((await shown()).closesAt, last + 26 * _hour + 1500);

      // Down again, proven, for longer than is ever excused in one stretch:
      // with seven days excused no more is, the limits run although a proof
      // covers the moment, and what is near is said, as the service's
      // doing.
      clock = last + 7 * 24 * _hour + 20 * _hour;
      cloudAnswer = const SocketException('Connection refused');
      await container.read(cloudReachProvider).checkNow();
      expect(reach.state.value.reach, CloudReach.notResponding);
      await scheduler.outageProven(since: last + 19 * _hour, at: clock, until: clock + 900);
      expect(container.read(orchardContactProvider).excused, kOutageExcuseMax.inSeconds);
      final end = last + 8 * 24 * _hour;
      expect(said().single.body, l10n.offlineClosingBodyCloud(both(end, end + 2 * _hour), at(last)));
      now = await shown();
      expect(now.closesAt, end + 2 * _hour);
      expect(now.crates.firstWhere((c) => c.id == production).closesAt, end);
    }, skip: !kOrchardsEnabled);

    test("a Crate with minutes left when an outage of ZestSSH Cloud's own is proven does not close between one "
        'proof and the next, and has those minutes again once the outage is over', () async {
      const minute = 60;
      await limit(production, 1);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      Future<Map<String, int>> closed() async => (await crateLimitsIn(orchardDb())).closed;

      // Fifty-nine minutes away, the last two of them an outage: three
      // minutes left of the hour.
      clock = last + 59 * minute;
      await scheduler.outageProven(since: last + 57 * minute, at: clock, until: clock + 15 * minute);
      // Five minutes on with no word since (the app asks again every five
      // minutes at the most): counted up to the proof alone, the hour ran
      // out two minutes ago.
      clock = last + 64 * minute;
      await scheduler.checkOfflineLimits();
      expect(await closed(), isEmpty);
      expect(scheduler.cratesClosedHere, isFalse);
      // The next proof, and six minutes more.
      await scheduler.outageProven(since: last + 57 * minute, at: clock, until: clock + 15 * minute);
      clock = last + 70 * minute;
      await scheduler.checkOfflineLimits();
      expect(await closed(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse, reason: 'and nothing is about to: the limits stand still');
      final seen = container.read(orchardListVersionProvider);

      // ZestSSH Cloud is up again, says its status service, and this
      // device still cannot reach it: the proof is believed no further, and
      // the Crate has its three minutes.
      await scheduler.outageOver();
      final contact = container.read(orchardContactProvider);
      expect((contact.excused, contact.excusedThrough, contact.provenUntil),
          (13 * minute, last + 70 * minute, last + 70 * minute));
      // The lists are told at once that it is about to close, and when.
      expect(container.read(orchardListVersionProvider), greaterThan(seen));
      expect(scheduler.closingSoonHere, isTrue);
      final shown = (await container.read(orchardSummariesProvider.future)).single;
      expect(shown.crates.firstWhere((c) => c.id == production).closesAt, last + 73 * minute);
      clock = last + 73 * minute;
      await scheduler.checkOfflineLimits();
      expect(await closed(), isEmpty);
      clock = last + 73 * minute + 1;
      await scheduler.checkOfflineLimits();
      expect(await closed(), {production: 1});
      expect(scheduler.cratesClosedHere, isTrue);
      // Said over again, it changes nothing.
      final after = container.read(orchardContactProvider);
      await scheduler.outageOver();
      expect(identical(container.read(orchardContactProvider), after), isTrue);
    }, skip: !kOrchardsEnabled);

    test("the Orchard's own limit about to close all of it is said with the Crates, and gone once it has closed",
        () async {
      await limit(production, 8);
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final databases = container.read(orchardDatabasesProvider.notifier);
      final last = clock;
      await syncFails();

      clock = last + 18 * _hour;
      await scheduler.checkOfflineLimits();
      expect(databases.closedOffline, isEmpty);
      expect(said().single.body,
          l10n.offlineClosingBody(item(l10n.offlineClosingAll, last + 24 * _hour), at(last)),
          reason: 'Production closed ten hours ago: all of the Orchard is what is still to come');
      final shown = (await container.read(orchardSummariesProvider.future)).single;
      expect(shown.closesAt, last + 24 * _hour);

      // The Orchard closes: there is nothing left to say will close.
      clock = last + 24 * _hour + 1;
      await scheduler.checkOfflineLimits();
      expect(databases.closedOffline, {orchardId});
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse);
    }, skip: !kOrchardsEnabled);

    test('a Crate that would close no sooner than all of its Orchard is not named beside it, and its row says no '
        'later a time than the Orchard closes', () async {
      expect(closingSoon(null, const {}), isEmpty);
      expect(closingSoon(500, const {}), {'': 500});
      expect(closingSoon(null, const {'a': 400, 'b': 900}), {'a': 400, 'b': 900});
      expect(closingSoon(500, const {'a': 499, 'b': 500, 'c': 501}), {'': 500, 'a': 499});

      // Production closes after thirty hours away, Lab after twenty, and
      // all of the Orchard after twenty-four.
      await limit(production, 30);
      await limit(lab, 20);
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      await syncFails();
      clock = last + 19 * _hour;
      await scheduler.checkOfflineLimits();
      final lines = [item('Lab', last + 20 * _hour), item(l10n.offlineClosingAll, last + 24 * _hour)];
      expect(said().single.body, l10n.offlineClosingBody(lines.join(l10n.listSeparator), at(last)));
      // Production comes into the last quarter of its own limit: that is
      // no news, since the Orchard closes before it would.
      container.read(notificationCenterProvider.notifier).remove(said().single.id);
      final seen = container.read(orchardListVersionProvider);
      clock = last + 23 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item(l10n.offlineClosingAll, last + 24 * _hour), at(last)),
          reason: 'Lab has closed: what is still to come is said without it, and without Production');
      final shown = (await container.read(orchardSummariesProvider.future)).single;
      expect(shown.closesAt, last + 24 * _hour);
      expect({for (final c in shown.crates) c.name: c.closesAt}, {'Production': last + 24 * _hour, 'Lab': null});
      expect(container.read(orchardListVersionProvider), greaterThan(seen));
    }, skip: !kOrchardsEnabled);

    // An offline pass an owner signed for this device (rules/offline_pass.dart;
    // who signs what and what a device keeps is in
    // pass_handover_service_test.dart). Here: what the app does with one it
    // holds, kept as the service keeps it.
    Future<void> holds(String what, {required int until, required int madeAt}) => LocalStateStore(orchardDb())
        .write('$kOfflinePassState$what', HeldPass(until: until, madeAt: madeAt, by: _dana).toStored());

    test('all of an Orchard past its own limit stays open while a pass for all of it holds, says so before the '
        'pass ends, and closes when it has', () async {
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final databases = container.read(orchardDatabasesProvider.notifier);
      final last = clock;
      await syncFails();
      // Twenty hours away an owner signed a pass for all of it, good for
      // twenty-eight hours.
      clock = last + 20 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item(l10n.offlineClosingAll, last + 24 * _hour), at(last)));
      await holds(kAllOfOrchard, until: last + 48 * _hour, madeAt: clock);
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty, reason: 'the limit is no longer what ends it, and the pass is far from its end');

      // An hour past the limit: open.
      clock = last + 25 * _hour;
      await scheduler.checkOfflineLimits();
      expect(databases.closedOffline, isEmpty);
      expect(container.read(orchardDatabasesProvider).containsKey(orchardId), isTrue);
      var shown = (await container.read(orchardSummariesProvider.future)).single;
      expect((shown.closedOffline, shown.closesAt), (false, null));
      expect(said(), isEmpty);

      // The pass's last quarter (seven of its twenty-eight hours).
      clock = last + 41 * _hour - 1;
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      clock = last + 41 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said().single.body, l10n.offlineClosingBody(item(l10n.offlineClosingAll, last + 48 * _hour), at(last)));
      shown = (await container.read(orchardSummariesProvider.future)).single;
      expect(shown.closesAt, last + 48 * _hour);

      // Its last second, and one second on.
      clock = last + 48 * _hour;
      await scheduler.checkOfflineLimits();
      expect(databases.closedOffline, isEmpty);
      clock = last + 48 * _hour + 1;
      await scheduler.checkOfflineLimits();
      expect(databases.closedOffline, {orchardId});
      expect(said(), isEmpty);
      shown = (await container.read(orchardSummariesProvider.future)).single;
      expect(shown.closedOffline, isTrue);
    }, skip: !kOrchardsEnabled);

    test("a pass for one Crate does not hold the Orchard open past the Orchard's own limit", () async {
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final last = clock;
      await holds(production, until: last + 48 * _hour, madeAt: last);
      clock = last + 24 * _hour + 1;
      await scheduler.checkOfflineLimits();
      expect(container.read(orchardDatabasesProvider.notifier).closedOffline, {orchardId});
    }, skip: !kOrchardsEnabled);

    test("a Crate past its own limit is used as before while a pass for it holds, and the app's own service tells "
        'the lists and takes a look when a pass was handed to it', () async {
      await limit(production, 24);
      await addHost('h-prod', production);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      final db = orchardDb();
      final last = clock;
      clock = last + 25 * _hour;
      await scheduler.checkOfflineLimits();
      expect(scheduler.cratesClosedHere, isTrue);
      await expectLater(requireCratesOpenIn(db, hostId: 'h-prod'), throwsA(closedCrate(production, 24)));

      // A pass is kept, as the service keeps one it took in, and says so.
      await holds(production, until: clock + 8 * _hour, madeAt: clock);
      final seen = container.read(orchardListVersionProvider);
      container.read(orchardServiceProvider).onPass!.call();
      expect(container.read(orchardListVersionProvider), greaterThan(seen), reason: 'the lists are told at once');
      await until(() => !scheduler.cratesClosedHere, what: 'the look that follows');
      await requireCratesOpenIn(db, hostId: 'h-prod');
      expect(await itemClosedIn(db, 'host', 'h-prod'), isNull);
      final crate =
          (await container.read(orchardSummariesProvider.future)).single.crates.firstWhere((c) => c.id == production);
      expect((crate.closedOffline, crate.closesAt), (false, null));
      // When the pass has ended, it is closed as it was.
      clock += 8 * _hour + 1;
      await expectLater(requireCratesOpenIn(db, hostId: 'h-prod'), throwsA(closedCrate(production, 24)));
    }, skip: !kOrchardsEnabled);

    test('started again, the app judges a pass by the furthest its clock was seen to read, once it has read that',
        () async {
      await dana.setRules(orchardId, const RecordRules(offlineHours: 24));
      final db = orchardDb();
      final last = clock;
      await holds(kAllOfOrchard, until: last + 30 * _hour, madeAt: last);
      expect(await passesHoldingIn(db), {kAllOfOrchard: last + 30 * _hour});
      // The clock was seen to read two hours past the pass's end, and that
      // was kept.
      clock = last + 32 * _hour;
      await container.read(orchardContactProvider.notifier).sawTime();
      expect(await orchardPassHoldsIn(db), isFalse);
      expect(await passesHoldingIn(db), isEmpty);
      // Turned back by three hours, and the app started again: asked
      // before what was kept has been read, the answer waits for it.
      clock = last + 29 * _hour;
      container.invalidate(orchardContactProvider);
      expect(await orchardPassHoldsIn(db), isFalse, reason: 'a clock turned back does not bring a pass back');
      expect(container.read(orchardContactProvider).latest, last + 32 * _hour);
      // Started once more: the same for what a screen says holds.
      container.invalidate(orchardContactProvider);
      expect(await passesHoldingIn(db), isEmpty, reason: 'nor onto a screen');
    }, skip: !kOrchardsEnabled);

    test('an Orchard that is gone from this device takes what was said of it closing with it', () async {
      await limit(production, 24);
      final scheduler = container.read(orchardSyncSchedulerProvider);
      await syncFails();
      clock += 20 * _hour;
      await scheduler.checkOfflineLimits();
      expect(said(), hasLength(1));
      expect(scheduler.closingSoonHere, isTrue);

      // The account was removed from the Orchard, and the Orchard taken
      // off the device.
      await container.read(spaceControllerProvider).switchTo(const TreeSpace());
      await container.read(orchardDatabasesProvider.notifier).forget(orchardId);
      container.read(orchardListVersionProvider.notifier).state++;
      expect(await container.read(orchardSummariesProvider.future), isEmpty);
      await scheduler.checkOfflineLimits();
      expect(said(), isEmpty);
      expect(scheduler.closingSoonHere, isFalse);
    }, skip: !kOrchardsEnabled);

    test('the notice itself: soonest first, two of the same moment by name, in every language', () {
      // (A day that is not the one the tests are run on: a time of today
      // is written without its date.)
      final now = DateTime(2031, 10, 9, 8);
      int secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
      final nine = secs(DateTime(2031, 10, 9, 21));
      final tomorrow = secs(DateTime(2031, 10, 10, 6));
      final contact = secs(DateTime(2031, 10, 8, 21));
      AppNotification notice(AppLocalizations l, {CloudReach? reach, int? all}) => offlineClosingNotice(
            orchardId: 'o1',
            orchard: 'Acme Orchard',
            all: all,
            crates: [(name: 'Staging', end: tomorrow), (name: 'Production', end: nine), (name: 'Lab', end: nine)],
            lastContact: contact,
            reach: reach,
            l10n: l,
            now: now,
          );
      final n = notice(l10n, all: tomorrow);
      expect(n.id, offlineClosingNoticeId('o1'));
      expect(n.id, isNot(offlineClosingNoticeId('o2')), reason: 'one notice for each Orchard');
      expect(n.title, 'Acme Orchard: closing on this device soon');
      expect(
          plain(n.body!),
          'Lab: 9:00 PM, Production: 9:00 PM, All of it: Oct 10 6:00 AM, Staging: Oct 10 6:00 AM. '
          'Connecting to the internet before then keeps everything open. '
          'With no internet, an owner can sign an offline pass for this device. '
          'This device last reached ZestSSH Cloud: Oct 8 9:00 PM.');
      // Offered from the notice where the app gives it the way to open it,
      // and not otherwise.
      expect((n.actionLabel, n.onAction), (null, null));
      var pressed = 0;
      final offering = offlineClosingNotice(
          orchardId: 'o1',
          orchard: 'Acme Orchard',
          all: null,
          crates: [(name: 'Production', end: nine)],
          lastContact: contact,
          reach: null,
          l10n: l10n,
          onAskPass: () => pressed++,
          now: now);
      expect(offering.actionLabel, l10n.passAskButton);
      offering.onAction!();
      expect(pressed, 1);
      // What the pass is asked for: the one Crate where nothing else is at
      // stake, and all of the Orchard otherwise.
      expect(passToAskFor({'c1': nine}, const {}), 'c1');
      expect(passToAskFor({'c1': nine, 'c2': tomorrow}, const {}), kAllOfOrchard);
      expect(passToAskFor({'': tomorrow}, const {}), kAllOfOrchard, reason: "the Orchard's own limit");
      expect(passToAskFor({'': tomorrow, 'c1': nine}, const {}), kAllOfOrchard);
      expect(passToAskFor({'c1': nine}, const {'c2'}), kAllOfOrchard,
          reason: 'another Crate is closed already: a pass for one would leave it so');
      expect(passToAskFor({'c1': nine}, const {'c1'}), kAllOfOrchard);
      for (final ours in [CloudReach.down, CloudReach.notResponding, CloudReach.fault]) {
        expect(
            plain(notice(l10n, reach: ours).body!),
            'Lab: 9:00 PM, Production: 9:00 PM, Staging: Oct 10 6:00 AM. '
            'ZestSSH Cloud is not responding, so nothing needs doing on this device: if the service answers '
            'before then, everything stays open. To be sure of it, an owner can sign an offline pass for this '
            'device. This device last reached it: Oct 8 9:00 PM.',
            reason: '$ours');
      }
      for (final theirs in [CloudReach.deviceOffline, CloudReach.nothingReached, CloudReach.blocked, null]) {
        expect(notice(l10n, reach: theirs).body, contains('Connecting to the internet'), reason: '$theirs');
      }
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        for (final reach in [CloudReach.deviceOffline, CloudReach.down]) {
          final said = notice(l, reach: reach, all: tomorrow);
          expect(said.title, contains('Acme Orchard'), reason: '$locale');
          for (final part in ['Production', 'Staging', 'Lab', l.offlineClosingAll, 'ZestSSH Cloud']) {
            expect(said.body, contains(part), reason: '$locale $reach');
          }
        }
        expect(notice(l, reach: CloudReach.down).body, isNot(notice(l, reach: CloudReach.deviceOffline).body),
            reason: '$locale');
        // Since when the device is away is what the sentences end on: a
        // notice on a computer shows four lines, and what to do is in them.
        for (final body in [l.offlineClosingBody('ITEMS', 'SINCE'), l.offlineClosingBodyCloud('ITEMS', 'SINCE')]) {
          expect(body, startsWith('ITEMS'), reason: '$locale');
          expect(body.indexOf('SINCE'), greaterThan(body.length - 12), reason: '$locale: $body');
        }
        expect(l.crateClosesAt('21:00'), contains('21:00'), reason: '$locale');
        expect(l.offlineClosesShort('21:00'), contains('21:00'), reason: '$locale');
      }
    });
  });

  test('the screens are told when a Crate closes and when it opens again, and not when nothing changed', () async {
    await limit(production, 24);
    await limit(lab, 72);
    final scheduler = container.read(orchardSyncSchedulerProvider);
    int version() => container.read(orchardListVersionProvider);
    Future<Map<String, bool>> listed() async => {
          for (final c in (await container.read(orchardSummariesProvider.future)).single.crates)
            c.name!: c.closedOffline,
        };

    var seen = version();
    await scheduler.checkOfflineLimits();
    expect(version(), seen, reason: 'nothing is closed');
    expect(scheduler.cratesClosedHere, isFalse);
    expect(await listed(), {'Lab': false, 'Production': false});

    clock += 24 * _hour + 1;
    await scheduler.checkOfflineLimits();
    expect(version(), greaterThan(seen), reason: 'Production closed');
    expect(scheduler.cratesClosedHere, isTrue);
    expect(await listed(), {'Lab': false, 'Production': true});
    seen = version();
    await scheduler.checkOfflineLimits();
    expect(version(), seen, reason: 'still the same Crate closed');

    clock += 48 * _hour;
    await scheduler.checkOfflineLimits();
    expect(version(), greaterThan(seen), reason: 'Lab closed too');
    expect(await listed(), {'Lab': true, 'Production': true});
    seen = version();

    // The Orchard itself stays open throughout.
    expect(container.read(orchardDatabasesProvider.notifier).closedOffline, isEmpty);

    // Reaching ZestSSH Cloud, as the app's own team service does it: the
    // screens are told at once, without waiting for the next look.
    container.read(orchardServiceProvider).onContact!.call();
    await until(() => version() > seen, what: 'word that the Crates opened');
    expect(scheduler.cratesClosedHere, isFalse);
    expect(await listed(), {'Lab': false, 'Production': false});
    seen = version();
    // And with nothing closed, reaching it again tells the screens nothing.
    container.read(orchardServiceProvider).onContact!.call();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(version(), seen);
  }, skip: !kOrchardsEnabled);
}
