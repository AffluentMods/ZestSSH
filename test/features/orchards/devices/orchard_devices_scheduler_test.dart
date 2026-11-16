import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';

import '../fake_crate_server.dart';
import '../fake_stream_server.dart';

/// Trusted devices (3.0) as a running app lives them: what the live
/// line and each sync make a device tell its person (a device asks to be
/// approved, this device was removed), each once; the list of requests read
/// again when the line says one moved; and the line kept open by a device
/// that is held back, so that it hears when it is let in. A real service and
/// a real sync against the (fake) server; other devices act on their own.

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

/// One device's secure storage.
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

/// Another device: a service, a sign-in and a key of its own.
class _Other {
  _Other(FakeCrateServer shared, this.uid, AccountKeys keys, String signIn) {
    service = OrchardService(
      server: shared.as(uid, device: signIn),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(keychain),
    );
  }

  final String uid;
  final storage = _MemoryStorage();
  final keychain = _Keychain();
  late final OrchardService service;

  Future<String> get key async => (await DeviceIdentityStore(keychain).forAccount(uid)).key;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final orchardName = orchardDisplayName('Acme', l10n);
  const rule = RecordRules(trustedDevices: true);

  final keys = <String, AccountKeys>{};
  late FakeCrateServer crates;
  late FakeStreamServer server;
  late StreamController<ConnectivityKind> network;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late _Keychain keychain;
  late ProviderContainer container;
  final others = <_Other>[];

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
    keychain = _Keychain();
  });

  tearDown(() async {
    container.dispose();
    await network.close();
    await server.close();
    for (final db in [...storage.dbs.values, for (final o in others) ...o.storage.dbs.values]) {
      await db.close();
    }
    others.clear();
    await tree.close();
  });

  /// The app of [me], signed in as the device [signIn]: its scheduler, its
  /// service and its sync, for real.
  Future<void> app(String me, String signIn) async {
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
            server: crates.as(me, device: signIn),
            databases: ref.read(orchardDatabasesProvider.notifier),
            author: () async => CrateAuthor(uid: me, keys: keys[me]!),
            deviceKeys: DeviceIdentityStore(keychain),
          )),
      orchardSyncProvider.overrideWith((ref) => OrchardSyncCoordinator(
            service: ref.read(orchardServiceProvider),
            server: crates.as(me, device: signIn),
            databases: ref.read(orchardDatabasesProvider.notifier),
          )),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  }

  _Other other(String uid, String signIn) {
    final o = _Other(crates, uid, keys[uid]!, signIn);
    others.add(o);
    return o;
  }

  OrchardService mine() => container.read(orchardServiceProvider);
  OrchardSyncScheduler scheduler() => container.read(orchardSyncSchedulerProvider);
  List<AppNotification> told() => container.read(notificationCenterProvider).history;
  List<(String, String?)> toldWords() => [for (final n in told().reversed) (n.title, n.body)];

  Future<FakeStreamConnection> connected() async {
    await scheduler().syncAll();
    final c = await server.next();
    await c.signIn;
    c.ready();
    await eventually(() => container.read(orchardStreamProvider).isConnected);
    return c;
  }

  Future<void> join(OrchardService by, String person, String orchardId, String role) async {
    await by.invite(orchardId, email: '$person@example.com', role: role);
    final invite = (await by.invites(orchardId)).single;
    crates.acceptAs(orchardId, invite.id, person);
    await by.confirmInvite(orchardId, (await by.invites(orchardId)).single);
  }

  /// [asking] asks and [approver] approves, as two people who compared the
  /// words would.
  Future<void> approve(OrchardService asking, OrchardService approver, String orchardId) async {
    final asked = await asking.askDeviceApproval(orchardId);
    await approver.answerDeviceRequest(orchardId, asked.id);
    await asking.deviceAsk(orchardId);
    await approver.deviceRequests(orchardId);
    await approver.approveDevice(orchardId, asked.id);
  }

  test('a device asks: the device of whoever can approve it says so, once, and the list is read again',
      () async {
    await app(_owner, 'laptop');
    final orchardId = await mine().createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = crates.recordOf(orchardId).roles.values.single.id;
    await join(mine(), _alice, orchardId, member);
    await mine().approveThisDevice(orchardId);
    final c = await connected();
    expect(told(), isEmpty);
    final version = container.read(deviceRequestsVersionProvider);

    final hers = other(_alice, 'alice-laptop');
    await hers.service.refresh();
    final asked = await hers.service.askDeviceApproval(orchardId);
    // The server says a device request moved, and no more than that.
    c.send({'type': 'device'});
    await eventually(() => told().isNotEmpty);
    expect(container.read(deviceRequestsVersionProvider), version + 1);
    expect(toldWords(), [(l10n.noticeDeviceAskedTitle(orchardName), l10n.noticeDeviceAskedBody('alice@example.com'))]);
    expect(told().single.severity, NotificationSeverity.warning, reason: 'it stays in the bell until read');
    expect((await container.read(deviceRequestsProvider(orchardId).future)).single.id, asked.id);

    // Told once: not by the next sync, nor by word that changes nothing,
    // nor when the request moves on.
    await scheduler().syncAll();
    await mine().answerDeviceRequest(orchardId, asked.id);
    c.send({'type': 'device'});
    await eventually(() => container.read(deviceRequestsVersionProvider) == version + 2);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(told(), hasLength(1));
    await mine().declineDeviceRequest(orchardId, asked.id);

    // Another device of this account's own asks: said as such.
    final phone = other(_owner, 'phone');
    await phone.service.refresh();
    await phone.service.askDeviceApproval(orchardId);
    await scheduler().syncAll();
    expect(toldWords().last, (l10n.noticeDeviceAskedTitle(orchardName), l10n.noticeDeviceAskedOwnBody));

    // Two at once: one notice, with how many. (Asking again makes a new
    // request, which is news.)
    await phone.service.askDeviceApproval(orchardId);
    await hers.service.askDeviceApproval(orchardId);
    c.send({'type': 'device'});
    await eventually(() => told().length == 3);
    expect(toldWords().last, (l10n.noticeDeviceAskedTitle(orchardName), l10n.noticeDeviceAskedManyBody(2)));

    // Held back for something else (its second step), this approved device
    // does not ask for requests it would only be refused.
    crates.held[_owner] = ['second_factor'];
    await scheduler().syncAll();
    expect(mine().standing, {orchardId: 'rules'});
    final lists = crates.deviceLists;
    await scheduler().syncAll();
    c.send({'type': 'device'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(crates.deviceLists, lists);
    expect(told(), hasLength(3));
  });

  test('a device nobody approved tells nothing of requests it could not answer, and keeps the line open while '
      'it is held back', () async {
    final laptop = other(_owner, 'laptop');
    final phone = other(_owner, 'phone');
    final orchardId =
        await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = crates.recordOf(orchardId).roles.values.single.id;
    await join(laptop.service, _alice, orchardId, member);
    await laptop.service.approveThisDevice(orchardId);
    await phone.service.refresh();
    await approve(phone.service, laptop.service, orchardId);

    // Alice's app, in the Orchard with the rule off: another device of hers
    // asks, and this one (not approved itself) has nothing to say about it.
    await app(_alice, 'alice-laptop');
    final c = await connected();
    final second = other(_alice, 'alice-phone');
    await second.service.refresh();
    await second.service.askDeviceApproval(orchardId);
    c.send({'type': 'device'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(told(), isEmpty);
    expect(await container.read(deviceRequestsProvider(orchardId).future), isEmpty);
    await second.service.withdrawDeviceAsk(orchardId);

    // The rule goes on: her app is held back in its only Orchard, and the
    // line stays, so that it hears when it is let in.
    await laptop.service.setRules(orchardId, rule);
    await scheduler().syncAll();
    expect(mine().standing, {orchardId: 'rules'});
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(container.read(orchardStreamProvider).isConnected, isTrue);
    expect(told(), isEmpty);

    // Approved: word on the line that the Orchards changed brings it in.
    await approve(mine(), laptop.service, orchardId);
    c.send({'type': 'orchards'});
    await eventually(() => mine().standing[orchardId] == 'active');
    expect(told(), isEmpty, reason: 'being let in is seen, not announced');

    // Removed: told once, by the name the Orchard had here.
    await laptop.service.refresh();
    await laptop.service
        .removeDevice(orchardId, uid: _alice, deviceKey: (await DeviceIdentityStore(keychain).forAccount(_alice)).key);
    await scheduler().syncAll();
    expect(mine().standing, {orchardId: 'rules'});
    expect(toldWords(), [(l10n.noticeDeviceRemovedTitle(orchardName), l10n.noticeDeviceRemovedBody)]);
    await scheduler().syncAll();
    c.send({'type': 'device'});
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(told(), hasLength(1));
  });
}
