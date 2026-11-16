import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

import 'fake_crate_server.dart';
import 'fake_stream_server.dart';

/// Access on request (3.0) as a running app lives it: what the
/// live line and each sync make a device tell its person (someone asks, a
/// request was declined, access was given, ended early, or is over), and the
/// moment access ends, at which the device brings itself up to date without
/// waiting for the next round. A real service and a real sync against the
/// (fake) server; the other party acts from a device of its own.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';

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

/// Someone else's device: a service of its own, and nothing more.
class _Other {
  _Other(FakeCrateServer shared, this.uid, AccountKeys keys) {
    service = OrchardService(
      server: shared.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
  }

  final String uid;
  final storage = _MemoryStorage();
  late final OrchardService service;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final orchardName = orchardDisplayName('Acme', l10n);

  final keys = <String, AccountKeys>{};
  late FakeCrateServer crates;
  late FakeStreamServer server;
  late StreamController<ConnectivityKind> network;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late ProviderContainer container;
  final others = <_Other>[];

  var moved = Duration.zero;
  DateTime clock() => DateTime.now().add(moved);

  setUpAll(() async {
    // As the app has them once its first screen is up.
    await initializeDateFormatting();
    for (final uid in [_owner, _alice, _bob]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    HttpOverrides.global = null;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    moved = Duration.zero;
    OrchardService.debugNow = clock;
    crates = FakeCrateServer(accountUid: _owner)..clock = clock;
    for (final uid in [_owner, _alice, _bob]) {
      await crates.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
    server = await FakeStreamServer.start();
    network = StreamController<ConnectivityKind>.broadcast();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    container.dispose();
    await network.close();
    await server.close();
    for (final db in [...storage.dbs.values, for (final o in others) ...o.storage.dbs.values]) {
      await db.close();
    }
    others.clear();
    await tree.close();
  });

  /// The app of [me]: its scheduler, its service and its sync, for real.
  Future<void> app(String me) async {
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
            server: crates.as(me),
            databases: ref.read(orchardDatabasesProvider.notifier),
            author: () async => CrateAuthor(uid: me, keys: keys[me]!),
          )),
      orchardSyncProvider.overrideWith((ref) => OrchardSyncCoordinator(
            service: ref.read(orchardServiceProvider),
            server: crates.as(me),
            databases: ref.read(orchardDatabasesProvider.notifier),
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  }

  _Other other(String uid) {
    final o = _Other(crates, uid, keys[uid]!);
    others.add(o);
    return o;
  }

  OrchardService mine() => container.read(orchardServiceProvider);
  OrchardSyncScheduler scheduler() => container.read(orchardSyncSchedulerProvider);
  List<AppNotification> told() => container.read(notificationCenterProvider).history;
  List<(String, String?)> toldWords() => [for (final n in told().reversed) (n.title, n.body)];

  /// As the notification center writes it: every kind of space (a time has
  /// a narrow one before AM and PM) is a plain one.
  String plain(String words) => words.replaceAll(RegExp(r'\s+'), ' ');

  Future<FakeStreamConnection> connected() async {
    await scheduler().syncAll();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    return c;
  }

  /// [by] adds [person] to [orchardId] in [role], after they accepted.
  Future<void> join(OrchardService by, String person, String orchardId, String role) async {
    await by.invite(orchardId, email: '$person@example.com', role: role);
    final invite = (await by.invites(orchardId)).single;
    crates.acceptAs(orchardId, invite.id, person);
    await by.confirmInvite(orchardId, (await by.invites(orchardId)).single);
  }

  Future<List<String>> cratesHere(String orchardId) async => [
        for (final r in await (await mine().databases.open(orchardId))
            .customSelect('SELECT name FROM orchard_crates ORDER BY name')
            .get())
          r.read<String>('name'),
      ];

  test('someone asks: the device of whoever can answer says so, once, and whatever lists the requests reads again',
      () async {
    await app(_owner);
    final alice = other(_alice);
    final bob = other(_bob);
    final orchardId = await mine().createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(mine(), _alice, orchardId, member.id);
    await join(mine(), _bob, orchardId, member.id);
    final c = await connected();
    expect(told(), isEmpty);
    final version = container.read(accessRequestsVersionProvider);

    await alice.service.refresh();
    await alice.service
        .requestAccess(orchardId, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging');
    // The server says a request moved, and no more than that.
    c.send({'type': 'access'});
    await eventually(() => told().isNotEmpty);
    expect(container.read(accessRequestsVersionProvider), version + 1);
    expect(toldWords(), [(l10n.noticeAccessAskedTitle(orchardName), l10n.noticeAccessAskedBody('alice@example.com'))]);
    expect(told().single.severity, NotificationSeverity.warning, reason: 'it stays in the bell until read');

    // Told once: not again by the next sync, nor by word that changes nothing.
    await scheduler().syncAll();
    c.send({'type': 'access'});
    await eventually(() => container.read(accessRequestsVersionProvider) == version + 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(told(), hasLength(1));

    // Two more at once, from two people: one notice, with how many.
    await bob.service.refresh();
    await bob.service
        .requestAccess(orchardId, crateId: member.crates.keys.single, level: CrateLevel.edit, duration: const Duration(hours: 1));
    await alice.service
        .requestAccess(orchardId, crateId: member.crates.keys.single, level: CrateLevel.edit, duration: const Duration(hours: 1));
    await scheduler().syncAll();
    expect(toldWords().last, (l10n.noticeAccessAskedTitle(orchardName), l10n.noticeAccessAskedManyBody(2)));
    expect(told(), hasLength(2));
  });

  test('the member is told what happens to them: given, ended early, declined; nothing of what they did themselves',
      () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    final c = await connected();
    expect(await cratesHere(orchardId), ['Production']);
    expect(told(), isEmpty, reason: 'what came before this device joined is not news');

    // Given a Crate until a set time.
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 2));
    final until = crates.recordOf(orchardId).members[_alice]!.timed[staging]!.until;
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production', 'Staging']);
    expect(toldWords(), [
      (
        l10n.noticeAccessGivenTitle(orchardName),
        plain(l10n.noticeAccessGivenBody('owner-1@example.com', 'Staging', accessTimeText(until, l10n))),
      ),
    ]);

    // Ended early by the owner.
    await owner.service.endAccess(orchardId, uid: _alice, crateId: staging);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production']);
    expect(toldWords().last, (l10n.noticeAccessEndedTitle(orchardName), l10n.noticeAccessEndedBody('owner-1@example.com')));
    expect(told(), hasLength(2), reason: 'ended on purpose is not "your time is over"');

    // She asks; the owner declines.
    await mine().requestAccess(orchardId, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging again');
    await scheduler().syncAll();
    expect(told(), hasLength(2), reason: 'it waits');
    await owner.service.refresh();
    await owner.service
        .declineAccessRequest(orchardId, (await owner.service.accessRequests(orchardId)).waiting.single.id);
    c.send({'type': 'access'});
    await eventually(() => told().length == 3);
    expect(toldWords().last, (l10n.noticeAccessDeclinedTitle(orchardName), l10n.noticeAccessDeclinedBody));

    // What she does herself is not told back to her: asking and withdrawing,
    // and giving up what she was given.
    await mine().requestAccess(orchardId, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Once more');
    await mine().withdrawAccessRequest(orchardId, (await mine().accessRequests(orchardId)).mine.single.id);
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: const Duration(hours: 2));
    await scheduler().syncAll();
    expect(told(), hasLength(4));
    expect(toldWords().last.$1, l10n.noticeAccessGivenTitle(orchardName));
    await mine().endAccess(orchardId, uid: _alice, crateId: staging);
    await scheduler().syncAll();
    c.send({'type': 'access'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(told(), hasLength(4));

    // One that lapsed: seven days without an answer.
    await mine().requestAccess(orchardId, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Anyone?');
    await scheduler().syncAll();
    moved = const Duration(days: 7, seconds: 5);
    await scheduler().syncAll();
    expect(toldWords().last, (l10n.noticeAccessLapsedTitle(orchardName), l10n.noticeAccessLapsedBody));
    expect(told(), hasLength(5));
  });

  test('an answer with access: word of the request comes before the entry that gave it, and she is never told '
      '"declined"', () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    final c = await connected();
    await mine().requestAccess(orchardId, level: CrateLevel.use, duration: const Duration(hours: 1), note: 'Staging');
    await scheduler().syncAll();
    expect(told(), isEmpty);

    await owner.service.refresh();
    await owner.service.giveAccess(orchardId,
        uid: _alice,
        crateId: staging,
        level: CrateLevel.use,
        duration: const Duration(hours: 2),
        requestId: (await owner.service.accessRequests(orchardId)).waiting.single.id);
    // The server says both that a request moved and that her Orchards
    // changed. The first is acted on at once; the sync comes a second later.
    final version = container.read(accessRequestsVersionProvider);
    c.send({'type': 'access'});
    await eventually(() => container.read(accessRequestsVersionProvider) == version + 1);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(told(), isEmpty, reason: 'her request is gone, and her device read why before saying anything');
    expect(await cratesHere(orchardId), ['Production'], reason: 'not synced yet');

    c.send({'type': 'orchards'});
    await eventually(() => told().isNotEmpty);
    expect(toldWords().single.$1, l10n.noticeAccessGivenTitle(orchardName));
    expect(await cratesHere(orchardId), ['Production', 'Staging']);
    await scheduler().syncAll();
    expect(told(), hasLength(1));
  });

  test('at the moment access ends the device brings itself up to date: the Crate leaves, and its person is told',
      () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    await connected();

    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: kMinAccessDuration);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production', 'Staging']);
    expect(await mine().timeToNextAccessEnd(), isNotNull);
    expect(scheduler().watchesAccessEnd, isTrue, reason: 'five minutes away: the moment is set');
    final before = told().length;

    // A few seconds before its time (the clocks, moved on): the next sync
    // sets the moment anew, and nothing is asked of the scheduler after that.
    moved = kMinAccessDuration - const Duration(seconds: 4);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production', 'Staging'], reason: 'still hers');
    expect(await mine().timeToNextAccessEnd(), lessThanOrEqualTo(const Duration(seconds: 4)));
    expect(scheduler().watchesAccessEnd, isTrue);
    expect(told().length, before);

    await eventually(() => told().length > before, within: const Duration(seconds: 20));
    expect(toldWords().last, (l10n.noticeAccessOverTitle(orchardName), l10n.noticeAccessOverBody('Staging')));
    expect(await cratesHere(orchardId), ['Production']);
    expect(await mine().timeToNextAccessEnd(), isNull, reason: 'nothing else of hers ends');
    await eventually(() => !scheduler().watchesAccessEnd);
    // Told once.
    await scheduler().syncAll();
    expect(told().length, before + 1);
  });

  test('what ended is told even when the requests cannot be read; an Orchard they are suspended in is not asked',
      () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    await connected();
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: kMinAccessDuration);
    await scheduler().syncAll();
    final before = told().length;
    expect(await cratesHere(orchardId), ['Production', 'Staging']);

    // ZestSSH Cloud cannot list the requests just now. The end is on her
    // device, in the record: she is told all the same.
    crates.failAccessRequests = true;
    moved = kMinAccessDuration + const Duration(seconds: 5);
    await scheduler().syncAll();
    expect(toldWords().last, (l10n.noticeAccessOverTitle(orchardName), l10n.noticeAccessOverBody('Staging')));
    expect(told().length, before + 1);
    crates.failAccessRequests = false;

    // Each sync asks for the requests of an Orchard her membership counts in.
    var asked = crates.accessListCalls;
    await scheduler().syncAll();
    expect(crates.accessListCalls, asked + 1);
    // Suspended, there is nothing to ask and nothing to tell.
    await owner.service.suspendMember(orchardId, _alice);
    await scheduler().syncAll();
    asked = crates.accessListCalls;
    await scheduler().syncAll();
    expect(crates.accessListCalls, asked, reason: 'not asked while she is suspended');
    expect(told().length, before + 1);
  });

  test('more in a Crate they open ends without a word, and an end far away sets no timer', () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = crates.recordOf(orchardId).roles.values.single.crates.keys.single;
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    await connected();
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: production, level: CrateLevel.edit, duration: const Duration(days: 3));
    await scheduler().syncAll();
    final before = told().length;
    expect(before, 1, reason: 'given');
    expect(await mine().timeToNextAccessEnd(), greaterThan(OrchardSyncScheduler.accessEndHorizon));
    expect(scheduler().watchesAccessEnd, isFalse, reason: 'three days away: a later sync sets it');

    moved = const Duration(days: 3, seconds: 5);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production']);
    expect(
        (await (await mine().databases.open(orchardId)).customSelect('SELECT level FROM orchard_crates').getSingle())
            .read<String>('level'),
        'use');
    expect(told().length, before, reason: 'the Crate is still hers: nothing left');
  });

  test('ZestSSH Cloud away when access ends: a sync that does not get through ends it on the device by its clock, '
      'its person is told once, and the next end is waited for', () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final production = crates.recordOf(orchardId).roles.values.single.crates.keys.single;
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    await connected();
    // Staging for five minutes, and more in Production for ten.
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: kMinAccessDuration);
    await owner.service.giveAccess(orchardId,
        uid: _alice, crateId: production, level: CrateLevel.edit, duration: kMinAccessDuration * 2);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production', 'Staging']);
    final before = told().length;
    Future<String> levelOfProduction() async => (await (await mine().databases.open(orchardId))
            .customSelect("SELECT level FROM orchard_crates WHERE name = 'Production'")
            .getSingle())
        .read<String>('level');
    expect(await levelOfProduction(), 'edit');

    // The service is gone, and Staging's time comes.
    crates.down = true;
    moved = kMinAccessDuration + const Duration(seconds: 2);
    final asked = crates.askedWhileDown;
    await scheduler().syncAll();
    expect(crates.askedWhileDown, greaterThan(asked), reason: 'the sync was tried, and did not get through');
    expect(await cratesHere(orchardId), ['Production']);
    expect(toldWords().last, (l10n.noticeAccessOverTitle(orchardName), l10n.noticeAccessOverBody('Staging')));
    expect(told().length, before + 1);
    expect(await levelOfProduction(), 'edit', reason: 'its time has not come');
    expect(scheduler().watchesAccessEnd, isTrue, reason: 'the next end, five minutes on, is waited for');
    // Another sync that does not get through tells nothing again.
    await scheduler().syncAll();
    expect(told().length, before + 1);

    // What was added to Production ends as well: nothing leaves, nothing
    // is told, and nothing more is waited for.
    moved = kMinAccessDuration * 2 + const Duration(seconds: 2);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production']);
    expect(await levelOfProduction(), 'use');
    expect(told().length, before + 1);
    expect(scheduler().watchesAccessEnd, isFalse);

    // The service is back: the device syncs, and nothing changes.
    crates.down = false;
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production']);
    expect(told().length, before + 1);
  });

  test('ZestSSH Cloud away at the moment access ends, and nobody asking for a sync: the device ends it when the '
      'moment comes', () async {
    final owner = other(_owner);
    final orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final staging = await owner.service.createCrate(orchardId, 'Staging');
    final member = crates.recordOf(orchardId).roles.values.single;
    await join(owner.service, _alice, orchardId, member.id);
    await app(_alice);
    await connected();
    await owner.service
        .giveAccess(orchardId, uid: _alice, crateId: staging, level: CrateLevel.use, duration: kMinAccessDuration);
    await scheduler().syncAll();
    // A few seconds before its time the moment is set; then the service
    // goes away, and nothing is asked of the scheduler any more.
    moved = kMinAccessDuration - const Duration(seconds: 3);
    await scheduler().syncAll();
    expect(await cratesHere(orchardId), ['Production', 'Staging']);
    expect(scheduler().watchesAccessEnd, isTrue);
    final before = told().length;
    crates.down = true;

    await eventually(() => told().length > before, within: const Duration(seconds: 20));
    expect(toldWords().last, (l10n.noticeAccessOverTitle(orchardName), l10n.noticeAccessOverBody('Staging')));
    expect(await cratesHere(orchardId), ['Production']);
    await eventually(() => !scheduler().watchesAccessEnd);
  });
}
