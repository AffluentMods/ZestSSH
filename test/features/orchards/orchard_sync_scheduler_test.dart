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
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_contact.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_approval_alerts.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/services/local_state_store.dart';

import 'fake_crate_server.dart';
import 'fake_stream_server.dart';
import '../../helpers/orchard_db_fixture.dart';

/// What the app does with the live line (3.0): it opens once a
/// sync finds the account in an Orchard, and closes when there is none or
/// the app locks; a Crate that changed elsewhere syncs the Orchard holding
/// it, unless this device already read that far; a Crate it does not have
/// yet, a changed list or a line back after a drop sync everything; a
/// sign-out from elsewhere signs this device out; the network coming back
/// sends what waited, while a new network opens the line afresh; and the
/// invitations to the account are read with each run, one accepted keeping
/// the line open so its confirmation arrives at once. An Orchard past
/// its offline limit closes, and so does one on a clock turned back.

const _orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
const _crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
const _otherCrate = '3f5b1d9b-8e4a-4a6d-8b7a-5d94f3b2eaa6';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  /// Called when the Orchards on the device are next listed, once.
  void Function()? onList;

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    final known = dbs[orchardId];
    if (known != null) return known;
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db, orchardId: orchardId);
    return dbs[orchardId] = db;
  }

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async {
    final then = onList;
    onList = null;
    then?.call();
    return dbs.keys.toList();
  }
}

/// Records what the scheduler asks to sync instead of syncing.
class _Recorder extends OrchardSyncCoordinator {
  _Recorder({required super.service, required super.server, required super.databases});

  var all = 0;
  final one = <String>[];
  var inOrchards = true;
  var offline = false;

  /// Each sync says the Orchard has more people than seats.
  var seatsShort = false;

  /// And that it is what its vaults hold, not how many people it has.
  var vaultsFull = false;

  CrateSyncReport get _report => CrateSyncReport()
    ..seatsNeeded = seatsShort
    ..vaultsFull = vaultsFull;

  @override
  Future<Map<String, CrateSyncReport>> syncAll() async {
    all++;
    if (offline) throw const SocketException('offline');
    return inOrchards ? {_orchard: _report} : {};
  }

  @override
  Future<CrateSyncReport> syncOne(String orchardId, {CrateAuthor? me}) async {
    one.add(orchardId);
    if (offline) throw const SocketException('offline');
    return _report;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late FakeStreamServer server;
  late _Recorder recorder;
  late FakeCrateServer crates;
  late StreamController<ConnectivityKind> network;

  /// What the status service says when the app asks it (null: nothing).
  CloudStatement? statusSays;

  /// What ZestSSH Cloud answers when the app asks how it is (null: nothing
  /// answers).
  int? healthAnswers;

  setUp(() async {
    // The binding refuses real connections; the line goes to a local port.
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    server = await FakeStreamServer.start();
    network = StreamController<ConnectivityKind>.broadcast();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    statusSays = null;
    healthAnswers = null;
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      // The app's knowledge of how ZestSSH Cloud stands: here the service
      // does not answer unless a test says it does, and its status service
      // says what the test tells it.
      cloudReachProvider.overrideWith((ref) {
        final reach = CloudReachService(
          check: () async => healthAnswers ?? (throw const SocketException('Connection refused')),
          status: () async => statusSays,
          timer: (wait, then) => Timer(const Duration(days: 1), () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
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
      orchardSyncProvider.overrideWith((ref) {
        final databases = ref.read(orchardDatabasesProvider.notifier);
        crates = FakeCrateServer();
        return recorder = _Recorder(
          service: OrchardService(server: crates, databases: databases, author: () async => null),
          server: crates,
          databases: databases,
        );
      }),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    // One Orchard on this device, open, its one Crate read up to revision 5.
    final db = await container.read(orchardDatabasesProvider.notifier).open(_orchard);
    await db.customStatement(
      'INSERT INTO orchard_crates (crate_id, level, key_generation, last_revision) '
      "VALUES (?, 'manage', 1, 5)",
      [_crate],
    );
  });

  tearDown(() async {
    container.dispose();
    await network.close();
    await server.close();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  OrchardSyncScheduler scheduler() => container.read(orchardSyncSchedulerProvider);

  /// Syncs, then signs in the line that opens.
  Future<FakeStreamConnection> connected() async {
    await scheduler().syncAll();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    return c;
  }

  Duration afterSettle() => OrchardSyncScheduler.nudgeSettle + const Duration(milliseconds: 300);

  test('a Crate changed elsewhere syncs the Orchard holding it, once for a burst', () async {
    final c = await connected();
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 9});
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 10});
    await eventually(() => recorder.one.isNotEmpty);
    await Future<void>.delayed(afterSettle());
    expect(recorder.one, [_orchard]);
    expect(recorder.all, 1, reason: 'only the sync that opened the line');
  });

  test('an Orchard whose sync kept new items waiting for seats is noted, until one that did not', () async {
    container.read(orchardSyncProvider); // makes the recorder
    await scheduler().syncAll();
    expect(container.read(orchardSeatsShortProvider), isEmpty);
    recorder.seatsShort = true;
    await scheduler().syncAll();
    expect(container.read(orchardSeatsShortProvider), {_orchard});
    // A sync of this Orchard alone says so too.
    recorder.seatsShort = false;
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 9});
    await eventually(() => recorder.one.isNotEmpty);
    await eventually(() => container.read(orchardSeatsShortProvider).isEmpty);
  });

  test('its vaults being full is noted apart, by a sync of all and of this Orchard alone, until one that did not say so', () async {
    container.read(orchardSyncProvider); // makes the recorder
    await scheduler().syncAll();
    expect(container.read(orchardVaultsFullProvider), isEmpty);
    recorder
      ..seatsShort = true
      ..vaultsFull = true;
    await scheduler().syncAll();
    expect(container.read(orchardSeatsShortProvider), {_orchard});
    expect(container.read(orchardVaultsFullProvider), {_orchard});

    // Short of seats, and no longer full.
    recorder.vaultsFull = false;
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 9});
    await eventually(() => container.read(orchardVaultsFullProvider).isEmpty);
    expect(container.read(orchardSeatsShortProvider), {_orchard});

    // Full again, by the sync of this Orchard alone.
    recorder.vaultsFull = true;
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 10});
    await eventually(() => container.read(orchardVaultsFullProvider).isNotEmpty);
    expect(container.read(orchardVaultsFullProvider), {_orchard});
  });

  test('a revision this device already read is not fetched again', () async {
    final c = await connected();
    c.send({'type': 'crate', 'crate_id': _crate, 'revision': 5});
    await Future<void>.delayed(afterSettle());
    expect(recorder.one, isEmpty);
    expect(recorder.all, 1);
  });

  test('a Crate this device does not have yet, or a changed list, syncs everything', () async {
    final c = await connected();
    c.send({'type': 'crate', 'crate_id': _otherCrate, 'revision': 1});
    await eventually(() => recorder.all == 2);
    c.send({'type': 'orchards'});
    await eventually(() => recorder.all == 3);
    expect(recorder.one, isEmpty);
  });

  test('a line back after a drop syncs everything, for what it missed', () async {
    final first = await connected();
    await first.drop();
    final second = await server.next();
    await second.signIn;
    second.ready();
    await eventually(() => recorder.all == 2);
  });

  test('no Orchard, no line; and it closes once the account has none', () async {
    container.read(orchardSyncProvider); // makes the recorder
    recorder.inOrchards = false;
    await scheduler().syncAll();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, isEmpty);

    recorder.inOrchards = true;
    final c = await connected();
    recorder.inOrchards = false;
    await scheduler().syncAll();
    await c.closed;
    expect(c.closeCode, WebSocketStatus.normalClosure);
  });

  test('invitations are read with each run; one accepted keeps the line open until it is confirmed',
      () async {
    container.read(orchardSyncProvider); // makes the recorder and its server
    recorder.inOrchards = false;
    MyInvite invite({required bool accepted}) => MyInvite(
          id: 'invite-1',
          orchardId: _orchard,
          role: 'member',
          crates: 1,
          expiresAt: DateTime.now().add(const Duration(days: 3)),
          accepted: accepted,
          invitedBy: 'owner@example.com',
        );
    crates.mine.add(invite(accepted: false));
    await scheduler().syncAll();
    expect(container.read(myInvitesProvider).single.invitedBy, 'owner@example.com');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(server.connections, isEmpty, reason: 'nothing waits on a confirmation yet');

    crates.mine[0] = invite(accepted: true);
    final c = await connected();
    expect(container.read(myInvitesProvider).single.accepted, isTrue);

    // Confirmed: the invitation is gone and the account is in the Orchard.
    crates.mine.clear();
    recorder.inOrchards = true;
    await scheduler().syncAll();
    expect(container.read(myInvitesProvider), isEmpty);
    expect(container.read(orchardStreamProvider).isConnected, isTrue);

    // A list that cannot be read keeps the last one.
    recorder.inOrchards = false;
    crates.mine.add(invite(accepted: true));
    await scheduler().syncAll();
    crates.failInvites = true;
    await scheduler().syncAll();
    expect(container.read(myInvitesProvider).single.accepted, isTrue);
    expect(container.read(orchardStreamProvider).isConnected, isTrue,
        reason: 'still waiting on the confirmation');
    crates.failInvites = false;
    crates.mine.clear();
    await scheduler().syncAll();
    await c.closed;
  });

  test('signed out from elsewhere, this device signs out', () async {
    final before = sessionRevokedSignal.value;
    final c = await connected();
    await c.close(OrchardStream.closeSignedOut, 'signed out');
    await eventually(() => sessionRevokedSignal.value == before + 1);
  });

  test('word that a new device asks reaches the app', () async {
    final heard = <String>[];
    final sub = deviceApprovalNudges.stream.listen(heard.add);
    addTearDown(sub.cancel);
    final c = await connected();
    c.send({'type': 'device-approval', 'id': 'req-9'});
    await eventually(() => heard.isNotEmpty);
    expect(heard, ['req-9']);
  });

  test('an Orchard past its offline limit closes on the device; a clock turned back closes it too', () async {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final store = LocalStateStore(tree);
    Future<void> contactAt(int last, int latest) async {
      await store.writeInt(OrchardContactNotifier.lastKey, last);
      await store.writeInt(OrchardContactNotifier.latestKey, latest);
      container.invalidate(orchardContactProvider);
    }

    final databases = container.read(orchardDatabasesProvider.notifier);
    await storage.dbs[_orchard]!.customStatement(
        'UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(const RecordRules(offlineHours: 1).toBody())]);
    container.read(orchardListVersionProvider.notifier).state++;

    await contactAt(now - 59 * 60, now - 59 * 60);
    await scheduler().checkOfflineLimits();
    expect(databases.closedOffline, isEmpty, reason: 'within the hour');
    expect(container.read(orchardDatabasesProvider).containsKey(_orchard), isTrue);

    await contactAt(now - 2 * 3600, now - 2 * 3600);
    await scheduler().checkOfflineLimits();
    expect(databases.closedOffline, {_orchard});
    expect(container.read(orchardDatabasesProvider).containsKey(_orchard), isFalse, reason: 'its database closed');
    final listed = (await container.read(orchardSummariesProvider.future)).single;
    expect((listed.id, listed.closedOffline, listed.active), (_orchard, true, false));

    // Reached again and open; then a clock that reads an hour before the
    // furthest it read.
    databases.reopenOffline();
    // (An in-memory database is gone once closed: this one is made anew.)
    storage.dbs.remove(_orchard);
    await (await databases.open(_orchard)).customStatement(
        'UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(const RecordRules(offlineHours: 1).toBody())]);
    await contactAt(now, now + 3600);
    container.read(orchardListVersionProvider.notifier).state++;
    await scheduler().checkOfflineLimits();
    expect(databases.closedOffline, {_orchard}, reason: 'a clock turned back cannot measure the limit');
  }, skip: !kOrchardsEnabled);

  // An outage of ZestSSH Cloud's own must not be what closes a team's hosts
  // (3.0). Its status service proves the outage, signed.
  group('an outage of ZestSSH Cloud\'s own does not count towards an offline limit', () {
    late int now;
    late LocalStateStore store;

    Future<void> contactAt(int last) async {
      await store.writeInt(OrchardContactNotifier.lastKey, last);
      await store.writeInt(OrchardContactNotifier.latestKey, last);
      container.invalidate(orchardContactProvider);
    }

    /// The Orchard with a limit of an hour.
    Future<void> limitOfAnHour() async {
      await storage.dbs[_orchard]!.customStatement(
          'UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(const RecordRules(offlineHours: 1).toBody())]);
      container.read(orchardListVersionProvider.notifier).state++;
    }

    setUp(() {
      now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      store = LocalStateStore(tree);
    });

    test('an Orchard the limit closed opens again when the outage is proven', () async {
      // A device started in the middle of an outage: two hours since it
      // reached ZestSSH Cloud, an hour allowed.
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, {_orchard});

      // The status service says, signed: down for three hours now.
      final listVersion = container.read(orchardListVersionProvider);
      await scheduler().outageProven(since: now - 3 * 3600, at: now);
      expect(container.read(orchardListVersionProvider), greaterThan(listVersion),
          reason: 'whatever lists the Orchards is told to look again');
      expect(databases.closedOffline, isEmpty, reason: 'the two hours were ours, not this device\'s');
      // (An in-memory database is gone once closed: this one is made anew
      // before anything reads the Orchard again.)
      storage.dbs.remove(_orchard);
      await databases.open(_orchard);
      container.read(orchardListVersionProvider.notifier).state++;
      final contact = container.read(orchardContactProvider);
      expect(contact.excused, 2 * 3600, reason: 'what of the outage lies after the last contact');
      expect(contact.excusedThrough, now);
      expect(contact.lastContact, now - 2 * 3600, reason: 'an outage is not a contact');
      expect(await store.readInt(OrchardContactNotifier.excusedKey), 2 * 3600, reason: 'kept, for when the app is started again');
      expect(await store.readInt(OrchardContactNotifier.excusedThroughKey), now);
      final listed = (await container.read(orchardSummariesProvider.future)).single;
      expect((listed.id, listed.closedOffline), (_orchard, false));
    }, skip: !kOrchardsEnabled);

    test('an outage that does not account for the time away leaves it closed', () async {
      // Five hours away, of which the last two were an outage: three were its own.
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 5 * 3600);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, {_orchard});
      await scheduler().outageProven(since: now - 2 * 3600, at: now);
      expect(container.read(orchardContactProvider).excused, 2 * 3600);
      expect(databases.closedOffline, {_orchard});
    }, skip: !kOrchardsEnabled);

    test('while it is proven down an open Orchard does not close, and it has its own hour afterwards', () async {
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 50 * 60);
      await scheduler().outageProven(since: now - 40 * 60, at: now);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, isEmpty);
      // Ninety minutes since the contact, forty of them the outage: fifty of its own.
      await store.writeInt(OrchardContactNotifier.lastKey, now - 90 * 60);
      await store.writeInt(OrchardContactNotifier.latestKey, now - 90 * 60);
      await store.writeInt(OrchardContactNotifier.excusedKey, 40 * 60);
      await store.writeInt(OrchardContactNotifier.excusedThroughKey, now);
      container.invalidate(orchardContactProvider);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, isEmpty, reason: 'what was excused is read back when the app starts again');
      // A hundred and one minutes, forty excused: past the hour.
      await store.writeInt(OrchardContactNotifier.lastKey, now - 101 * 60);
      await store.writeInt(OrchardContactNotifier.latestKey, now - 101 * 60);
      container.invalidate(orchardContactProvider);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, {_orchard});
    }, skip: !kOrchardsEnabled);

    test('an Orchard closed before this run knew its rules stays closed, proof or none, until ZestSSH Cloud is reached',
        () async {
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      // Closed, and nothing here remembers under which rules.
      await databases.closeOffline(_orchard);
      container.read(orchardListVersionProvider.notifier).state++;
      await scheduler().outageProven(since: now - 3 * 3600, at: now);
      expect(databases.closedOffline, {_orchard}, reason: 'a limit that is not known is not taken for none');
      expect(databases.reopenOffline(), isTrue, reason: 'reaching ZestSSH Cloud opens it, as ever');
    }, skip: !kOrchardsEnabled);

    test('the same proof again changes nothing, and reaching ZestSSH Cloud starts the count afresh', () async {
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      final notifier = container.read(orchardContactProvider.notifier);
      expect(await notifier.excuse(since: now - 3600, at: now - 1800), isTrue);
      expect(await notifier.excuse(since: now - 3600, at: now - 1800), isFalse);
      expect(await notifier.excuse(since: now - 3600, at: now - 1700), isTrue);
      expect(container.read(orchardContactProvider).excused, 1900);
      await notifier.reached();
      final after = container.read(orchardContactProvider);
      expect((after.excused, after.excusedThrough, after.provenUntil), (0, 0, 0));
      expect(await store.readInt(OrchardContactNotifier.excusedKey), 0);
      expect(await store.readInt(OrchardContactNotifier.excusedThroughKey), 0);
      expect(await store.readInt(OrchardContactNotifier.provenUntilKey), 0);
      // And from a contact made after the outage, that outage excuses nothing.
      expect(await notifier.excuse(since: now - 3600, at: now - 1700), isFalse);
    }, skip: !kOrchardsEnabled);

    test('a look at the limits does not wait for someone else to read the Orchards, when whatever lists them is '
        'told to look again while the look reads them', () async {
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      // A sync that has just ended tells the lists to look again. Here that
      // happens in the middle of the look's own reading of the Orchards,
      // and nobody else reads them: no screen shows them.
      var told = false;
      storage.onList = () => scheduleMicrotask(() {
            told = true;
            container.read(orchardListVersionProvider.notifier).state++;
          });
      await scheduler().checkOfflineLimits().timeout(const Duration(seconds: 5));
      expect(told, isTrue, reason: 'the lists were told while they were being read');
      expect(databases.closedOffline, {_orchard}, reason: 'two hours away with an hour allowed');
      // It listens no longer than it reads: told again afterwards, the list
      // is not read for nobody.
      var readAgain = false;
      storage.onList = () => readAgain = true;
      container.read(orchardListVersionProvider.notifier).state++;
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(readAgain, isFalse);
    }, skip: !kOrchardsEnabled);

    test('while it runs it hears of a proven outage from what the app finds out, and no longer once stopped',
        () async {
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      scheduler().start();
      await eventually(() => databases.closedOffline.contains(_orchard));

      // The app asks ZestSSH Cloud how it is, gets no answer, asks the status
      // service, and is told, signed: down for three hours.
      statusSays = CloudStatement(down: true, at: now, until: now + 900, since: now - 3 * 3600, keyId: 'k1');
      final found = await container.read(cloudReachProvider).checkNow();
      expect(found.reach, CloudReach.down);
      await eventually(() => databases.closedOffline.isEmpty);
      expect(container.read(orchardContactProvider).excused, 2 * 3600);
      storage.dbs.remove(_orchard);

      // Stopped (the account signed out, the app is closing): a later proof
      // is not taken in, and nothing of this scheduler is left listening.
      expect(container.read(cloudReachProvider).hasOutageListeners, isTrue);
      scheduler().stop();
      expect(container.read(cloudReachProvider).hasOutageListeners, isFalse);
      statusSays = CloudStatement(down: true, at: now + 600, until: now + 1500, since: now - 3 * 3600, keyId: 'k1');
      await container.read(cloudReachProvider).checkNow();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(container.read(orchardContactProvider).excused, 2 * 3600);
    }, skip: !kOrchardsEnabled);

    test('an Orchard with minutes left does not close between one proof and the next', () async {
      final databases = container.read(orchardDatabasesProvider.notifier);
      await limitOfAnHour();
      // Sixty-three minutes since the contact. Down since five minutes ago,
      // said a proof three minutes ago that may be believed for a quarter
      // of an hour: counted up to the proof alone, the hour ran out a
      // minute ago.
      await store.writeInt(OrchardContactNotifier.lastKey, now - 63 * 60);
      await store.writeInt(OrchardContactNotifier.latestKey, now - 3 * 60);
      await store.writeInt(OrchardContactNotifier.excusedKey, 2 * 60);
      await store.writeInt(OrchardContactNotifier.excusedThroughKey, now - 3 * 60);
      await store.writeInt(OrchardContactNotifier.provenUntilKey, now + 12 * 60);
      container.invalidate(orchardContactProvider);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, isEmpty, reason: 'the minutes since the proof are excused as they pass');
      // The same with a proof that is believed no further than itself.
      await store.writeInt(OrchardContactNotifier.provenUntilKey, now - 3 * 60);
      container.invalidate(orchardContactProvider);
      await scheduler().checkOfflineLimits();
      expect(databases.closedOffline, {_orchard});
    }, skip: !kOrchardsEnabled);

    test('a proof is believed until the time it says, which is kept for when the app starts again, and no further '
        'once its status service says that ZestSSH Cloud is up', () async {
      await limitOfAnHour();
      await contactAt(now - 50 * 60);
      scheduler().start();
      OrchardContact contact() => container.read(orchardContactProvider);
      Future<void> kept(String key, int value) async {
        for (var i = 0; i < 300; i++) {
          if (await store.readInt(key) == value) return;
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        fail('$key was not kept as $value');
      }

      // Down for ten minutes, says the status service, to be believed for
      // a quarter of an hour.
      statusSays = CloudStatement(down: true, at: now, until: now + 900, since: now - 600, keyId: 'k1');
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.down);
      await eventually(() => contact().provenUntil == now + 900);
      expect((contact().excused, contact().excusedThrough), (600, now));
      await kept(OrchardContactNotifier.provenUntilKey, now + 900);

      // The app is started again: what it kept is all it knows.
      container.invalidate(orchardContactProvider);
      await container.read(orchardContactProvider.notifier).loaded;
      expect((contact().excused, contact().excusedThrough, contact().provenUntil), (600, now, now + 900));

      // Up again, says the status service, and this device still cannot
      // reach it: what passed since the proof is counted (moments, by this
      // test's clock), and the proof is believed no further.
      statusSays = CloudStatement(down: false, at: now + 5, until: now + 905, since: 0, keyId: 'k1');
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.blocked);
      await eventually(() => contact().provenUntil < now + 900);
      expect(contact().provenUntil, contact().excusedThrough);
      expect(contact().excusedThrough, inInclusiveRange(now, now + 60));
      expect(contact().excused, 600 + contact().excusedThrough - now);
      final ended = contact().provenUntil;
      await kept(OrchardContactNotifier.provenUntilKey, ended);
      expect(await store.readInt(OrchardContactNotifier.excusedThroughKey), ended);
    }, skip: !kOrchardsEnabled);

    test('a proof is believed no further once ZestSSH Cloud answers again', () async {
      await limitOfAnHour();
      await contactAt(now - 50 * 60);
      scheduler().start();
      statusSays = CloudStatement(down: true, at: now, until: now + 900, since: now - 600, keyId: 'k1');
      await container.read(cloudReachProvider).checkNow();
      await eventually(() => container.read(orchardContactProvider).provenUntil == now + 900);
      // It answers the app's own question of how it is. (Reaching it with
      // the Orchards, which starts the count afresh, comes after.)
      healthAnswers = 200;
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.answering);
      await eventually(() => container.read(orchardContactProvider).provenUntil < now + 900);
      final contact = container.read(orchardContactProvider);
      expect(contact.provenUntil, contact.excusedThrough);
      expect(contact.lastContact, now - 50 * 60, reason: 'an answer to that question is no contact of the Orchards');
    }, skip: !kOrchardsEnabled);

    test('how the service stands otherwise ends nothing, and stopped, it no longer hears that the service is up',
        () async {
      await limitOfAnHour();
      await contactAt(now - 50 * 60);
      scheduler().start();
      statusSays = CloudStatement(down: true, at: now, until: now + 900, since: now - 600, keyId: 'k1');
      await container.read(cloudReachProvider).checkNow();
      await eventually(() => container.read(orchardContactProvider).provenUntil == now + 900);
      final proven = container.read(orchardContactProvider);
      // The status service cannot be reached either: the proof stands for
      // as long as it says.
      statusSays = null;
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.nothingReached);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(identical(container.read(orchardContactProvider), proven), isTrue);
      // Stopped (the account signed out, the app is closing): word that it
      // is up changes nothing here any more.
      scheduler().stop();
      statusSays = CloudStatement(down: false, at: now + 5, until: now + 905, since: 0, keyId: 'k1');
      expect((await container.read(cloudReachProvider).checkNow()).reach, CloudReach.blocked);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(identical(container.read(orchardContactProvider), proven), isTrue);
      await scheduler().outageOver();
      expect(identical(container.read(orchardContactProvider), proven), isTrue, reason: 'nor asked directly');
    }, skip: !kOrchardsEnabled);

    test('what was counted is read back when the app starts again: the same proof is not counted twice', () async {
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      expect(await container.read(orchardContactProvider.notifier).excuse(since: now - 3600, at: now - 600), isTrue);
      expect(container.read(orchardContactProvider).excused, 3000);
      // The app is started again: what it kept is all it knows.
      container.invalidate(orchardContactProvider);
      final again = container.read(orchardContactProvider.notifier);
      expect(await again.excuse(since: now - 3600, at: now - 600), isFalse);
      final read = container.read(orchardContactProvider);
      expect((read.excused, read.excusedThrough), (3000, now - 600));
      expect(await again.excuse(since: now - 3600, at: now), isTrue);
      expect(container.read(orchardContactProvider).excused, 3600);
    }, skip: !kOrchardsEnabled);

    test('a scheduler that was stopped takes nothing in', () async {
      await limitOfAnHour();
      await contactAt(now - 2 * 3600);
      final stopped = scheduler()..stop();
      await stopped.outageProven(since: now - 3 * 3600, at: now);
      expect(container.read(orchardContactProvider).excused, 0);
      expect(await store.readInt(OrchardContactNotifier.excusedKey), isNull);
    }, skip: !kOrchardsEnabled);
  });

  test('locking the app closes the line', () async {
    scheduler().start();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    await container.read(databaseSessionProvider.notifier).close();
    await c.closed;
    expect(c.closeCode, WebSocketStatus.normalClosure);
  }, skip: !kOrchardsEnabled);

  group('the network', () {
    test('back after a sync that could not finish, what waited is sent and the line opens',
        () async {
      container.read(orchardSyncProvider); // makes the recorder
      recorder.offline = true;
      scheduler().start();
      await eventually(() => recorder.all == 1);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.connections, isEmpty);

      recorder.offline = false;
      network.add(ConnectivityKind.wifi);
      final c = await server.next();
      await c.signIn;
      expect(recorder.all, 2);
    });

    test('a new network opens the line afresh, and what it missed syncs', () async {
      scheduler().start();
      final first = await server.next();
      await first.signIn;
      first.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      // The first word only says what the network is.
      network.add(ConnectivityKind.wifi);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.connections, hasLength(1));

      network.add(ConnectivityKind.ethernet);
      await first.closed;
      final second = await server.next();
      await second.signIn;
      second.ready();
      await eventually(() => recorder.all == 2);
    });

    test('a change that could not be sent goes as soon as the network is back', () async {
      scheduler().start();
      final c = await server.next();
      await c.signIn;
      c.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      network.add(ConnectivityKind.wifi); // the first word
      recorder.offline = true;
      final db = storage.dbs[_orchard]!;
      await db.customStatement("INSERT INTO snippet_categories (name) VALUES ('Ops')");
      db.notifyOrchardItemsChanged();
      // Tried after the change settles, and it fails: offline.
      await eventually(() => recorder.one.isNotEmpty, within: const Duration(seconds: 8));
      recorder.offline = false;
      final before = recorder.all;
      network.add(ConnectivityKind.ethernet);
      await eventually(() => recorder.all > before);
    });

    // ZestSSH Cloud answering again is not the device's network changing:
    // the device may have had its network all along (3.0).
    test('ZestSSH Cloud answering again syncs the Orchards at once, whether or not a sync is known to have failed',
        () async {
      scheduler().start();
      final c = await server.next();
      await c.signIn;
      c.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      expect(recorder.all, 1);

      // Nothing failed here that the scheduler knows of, and the network of
      // the device did not change.
      scheduler().cloudIsBack();
      await eventually(() => recorder.all == 2);

      // And after a sync that could not finish, it is what sends what waited.
      recorder.offline = true;
      await scheduler().syncAll();
      final failed = recorder.all;
      recorder.offline = false;
      scheduler().cloudIsBack();
      await eventually(() => recorder.all == failed + 1);
    });

    test('asked for while a run is at its last steps, a sync runs once more after it (it was dropped)', () async {
      scheduler().start();
      final c = await server.next();
      await c.signIn;
      c.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      // A run, and three requests while it is under way: one more run, not three, and not none.
      final run = scheduler().syncAll();
      final before = recorder.all;
      unawaited(scheduler().syncAll());
      unawaited(scheduler().syncAll());
      scheduler().cloudIsBack();
      await run;
      await eventually(() => recorder.all == before + 1);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(recorder.all, before + 1);
    });

    test('once the scheduler has stopped, ZestSSH Cloud answering again starts nothing', () async {
      scheduler().start();
      final c = await server.next();
      await c.signIn;
      c.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      scheduler().stop();
      final before = recorder.all;
      scheduler().cloudIsBack();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(recorder.all, before);
    });

    test('going offline changes nothing by itself', () async {
      scheduler().start();
      final c = await server.next();
      await c.signIn;
      c.ready();
      await eventually(() => container.read(orchardStreamProvider).isConnected);
      network
        ..add(ConnectivityKind.wifi)
        ..add(ConnectivityKind.none);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(server.connections, hasLength(1));
      expect(recorder.all, 1);
    });
  }, skip: !kOrchardsEnabled);
}
