import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/member_devices_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart' show ApprovalWords;
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// Trusted devices (3.0) on screen, on a real Orchard: a device
/// that asks shows under what needs the people who can approve it, who
/// compare three words and approve or decline; a device nobody approved
/// asks from the banner and is told when it is in; the Rules page says what
/// turning the rule on takes and does it; and a member's devices are listed
/// and removed. Each device has its own service, sign-in and key against
/// one (fake) server.

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

class _Device {
  _Device(this.shared, this.uid, this.keys, this.signIn, {_MemoryStorage? storage, _Keychain? keychain})
      : storage = storage ?? _MemoryStorage(),
        keychain = keychain ?? _Keychain() {
    databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: this.storage);
    service = OrchardService(
      server: shared.as(uid, device: signIn),
      databases: databases,
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(this.keychain),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;

  /// What the device is called in the test, which is also its sign-in.
  final String signIn;
  final _MemoryStorage storage;
  final _Keychain keychain;
  late final OrchardDatabasesNotifier databases;
  late final OrchardService service;

  /// The same device with a service and a databases notifier of its own, as
  /// after the app was started again: a scope disposes the notifier it is
  /// given, and this one stays.
  _Device again() => _Device(shared, uid, keys, signIn, storage: storage, keychain: keychain);

  Future<String> get key async => (await DeviceIdentityStore(keychain).forAccount(uid)).key;

  Future<String> get code async => deviceCode(await key);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
    if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// Lets the dialog on screen look at its request again (it does every two
/// seconds), and what that brings settle.
Future<void> look(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 2));
  for (var i = 0; i < 6; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 80)));
    await tester.pump();
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const rule = RecordRules(trustedDevices: true);

  /// The Orchard's name as the pages write it.
  final acme = orchardDisplayName('Acme', l10n);

  late FakeCrateServer server;
  late _Device laptop;
  late _Device phone;
  late _Device alice;
  late String orchardId;
  late String member;

  /// [asking] asks and [approver] approves, as two people who compared the
  /// words would.
  Future<void> approve(_Device asking, _Device approver) async {
    final asked = await asking.service.askDeviceApproval(orchardId);
    await approver.service.answerDeviceRequest(orchardId, asked.id);
    await asking.service.deviceAsk(orchardId);
    await approver.service.deviceRequests(orchardId);
    await approver.service.approveDevice(orchardId, asked.id);
    await asking.service.refresh();
  }

  /// An Orchard of the owner's (a laptop and a phone) with alice in it. With
  /// [approved], the owner's two devices are approved; with [ruleOn] the
  /// rule is on as well.
  Future<void> setUpOrchard(WidgetTester tester, {bool approved = true, bool ruleOn = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    await tester.runAsync(() async {
      final ownerKeys = await AccountKeys.generate();
      final aliceKeys = await AccountKeys.generate();
      await server.publish(_owner, ownerKeys, email: '$_owner@example.com');
      await server.publish(_alice, aliceKeys, email: '$_alice@example.com');
      laptop = _Device(server, _owner, ownerKeys, 'laptop');
      phone = _Device(server, _owner, ownerKeys, 'phone');
      alice = _Device(server, _alice, aliceKeys, 'alice-laptop');
      orchardId = await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      member = server.recordOf(orchardId).roles.values.single.id;
      await laptop.service.invite(orchardId, email: '$_alice@example.com', role: member);
      final invite = (await laptop.service.invites(orchardId)).single;
      server.acceptAs(orchardId, invite.id, _alice);
      await laptop.service.confirmInvite(orchardId, (await laptop.service.invites(orchardId)).single);
      await alice.service.refresh();
      await phone.service.refresh();
      if (approved) {
        await laptop.service.approveThisDevice(orchardId);
        await approve(phone, laptop);
      }
      if (ruleOn) await laptop.service.setRules(orchardId, rule);
      for (final d in [laptop, phone, alice]) {
        await d.service.refresh();
      }
    });
    addTearDown(() async {
      for (final d in [laptop, phone, alice]) {
        for (final db in d.storage.dbs.values) {
          try {
            await db.close();
          } catch (_) {}
        }
      }
    });
  }

  /// A page of [as]'s: the Team page on a computer by default, its Overview
  /// alone on a small phone ([phone]), the phone's list of Team pages
  /// ([phoneList]), or [body] (what a test wants on screen).
  Future<(ProviderContainer, _Device)> pumpPage(
    WidgetTester tester,
    _Device as, {
    bool phone = false,
    bool phoneList = false,
    Widget Function(OrchardSummary orchard)? body,
    Locale locale = const Locale('en'),
    ThemeData? theme,
  }) async {
    tester.view.physicalSize = phone || phoneList ? const Size(360, 640) : const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    Future<OrchardSummary> read() async =>
        readOrchardSummary(await view.databases.open(orchardId), orchardId);
    final first = (await tester.runAsync(() async {
      await view.service.refresh();
      return read();
    }))!;
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(view.service),
        orchardDatabasesProvider.overrideWith((ref) => view.databases),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          return [await read()];
        }),
        activeOrchardProvider.overrideWith(
            (ref) => ref.watch(orchardSummariesProvider).whenData((list) => list.firstOrNull)),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        orchardSsoProvider.overrideWith((ref, id) async => const OrchardSso(kind: SsoKind.saml, active: false)),
        currentUserProvider.overrideWithValue(UserProfile(uid: as.uid, email: '${as.uid}@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        activeSidebarNavProvider.overrideWith((ref) => NavSection.team),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: phoneList
            ? const TeamPhoneScreen()
            : Scaffold(
                body: body != null
                    ? SingleChildScrollView(padding: const EdgeInsets.all(16), child: body(first))
                    : phone
                        ? SingleChildScrollView(
                            padding: const EdgeInsets.all(16),
                            child: TeamOverview(orchard: first, onOpen: (_) {}),
                          )
                        : const TeamView(),
              ),
      ),
    ));
    await settle(tester);
    return (ProviderScope.containerOf(tester.element(find.byType(Scaffold).first)), view);
  }

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  bool toasted(ProviderContainer container, WidgetTester tester, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      container.read(notificationCenterProvider).history.any((n) => n.title == message || n.body == message);

  /// The three words on screen in the box keyed [key].
  List<String> wordsIn(WidgetTester tester, String key) => [
        for (final t in tester.widgetList<SelectableText>(
            find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(SelectableText))))
          t.data!,
      ];

  testWidgets('a device asks: it shows under what needs the owner, who compares the words and approves',
      (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    final asked = (await tester.runAsync(() => alice.service.askDeviceApproval(orchardId)))!;
    final (container, _) = await pumpPage(tester, laptop);
    final row = 'team-attn-device-${asked.id}';

    expect(inKey(row, find.text(l10n.deviceRequestTitle('alice@example.com'))), findsOneWidget);
    expect(inKey(row, find.text(l10n.deviceRequestRowBody)), findsOneWidget);
    // The badge counts what the section shows: the device and the row that
    // says the owner is the only one (it said 1 beside the section's 2, a
    // design review found).
    expect(inKey('team-nav-overview', find.text('2')), findsOneWidget, reason: 'counted with what needs the owner');
    expect(inKey('team-attention-title', find.text('2')), findsOneWidget, reason: 'and beside the section');
    expect(find.text(l10n.teamAttentionNone), findsNothing);

    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.deviceRequestTitle('alice@example.com')), findsNWidgets(2), reason: 'the row and the dialog');
    expect(find.text(l10n.deviceRequestIntro('alice@example.com')), findsOneWidget);
    expect(find.text(l10n.deviceRequestHow), findsOneWidget);
    expect(find.byType(ApprovalWords), findsNothing, reason: 'no words before both sides showed');

    // The owner goes on: answered, and waiting for her device to show its key.
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId).single.stage, 'responded');
    expect(find.text(l10n.deviceRequestWaitingDevice), findsOneWidget);

    // Her device sees the answer and shows; a moment later both have words.
    final hers = (await tester.runAsync(() => alice.service.deviceAsk(orchardId)))!;
    await look(tester);
    expect(find.text(l10n.deviceRequestCompare), findsOneWidget);
    expect(wordsIn(tester, 'device-request-words'), hers.words);
    final code = (await tester.runAsync(() => alice.code))!;
    expect(find.text(l10n.deviceTheirCode(code)), findsOneWidget);
    expect(server.recordOf(orchardId).devicesOf(_alice), isEmpty, reason: 'nothing is approved by showing words');

    // Approving changes who gets in: with a sign-in that is not recent the
    // owner is asked to confirm it is them, and nothing is approved yet.
    server.requireRecentSignIn = true;
    await tester.tap(find.text(l10n.deviceRequestApprove));
    await settle(tester);
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(find.text(l10n.stepUpApproveDevice('alice@example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-request-error')), findsNothing);
    expect(server.recordOf(orchardId).devicesOf(_alice), isEmpty);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(find.text(l10n.deviceRequestCompare), findsOneWidget, reason: 'back where it was');
    server.requireRecentSignIn = false;

    final drops = server.deviceDrops;
    await tester.tap(find.text(l10n.deviceRequestApprove));
    await settle(tester);
    expect(server.recordOf(orchardId).devicesOf(_alice), {(await tester.runAsync(() => alice.key))!});
    expect(server.deviceRequestsOf(orchardId), isEmpty);
    expect(server.deviceDrops, drops, reason: 'approved: nothing to decline when the dialog closes');
    expect(toasted(container, tester, l10n.deviceRequestApproved), isTrue);
    expect(find.text(l10n.deviceRequestCompare), findsNothing, reason: 'the dialog closed');
    expect(find.byKey(ValueKey(row)), findsNothing);
    expect(find.text(l10n.teamChangeDeviceApproved('alice@example.com')), findsOneWidget,
        reason: 'the newest change says so');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("another device of one's own asks: the words do not match, and nothing is approved; "
      'a request that was changed on the way is ended', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    final tablet = _Device(server, _owner, laptop.keys, 'tablet');
    addTearDown(() async {
      for (final db in tablet.storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    var asked = (await tester.runAsync(() async {
      await tablet.service.refresh();
      return tablet.service.askDeviceApproval(orchardId);
    }))!;
    final (container, _) = await pumpPage(tester, laptop);
    var row = 'team-attn-device-${asked.id}';
    expect(inKey(row, find.text(l10n.deviceRequestTitleOwn)), findsOneWidget);

    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.deviceRequestIntroOwn), findsOneWidget);
    expect(find.text(l10n.deviceRequestTitleOwn), findsNWidgets(2), reason: 'the row and the dialog');
    expect(find.text(l10n.deviceRequestTitle('owner-1@example.com')), findsNothing);
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    await tester.runAsync(() => tablet.service.deviceAsk(orchardId));
    await look(tester);
    expect(find.byKey(const ValueKey('device-request-words')), findsOneWidget);
    await tester.tap(find.text(l10n.deviceRequestDiffer));
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId), isEmpty);
    expect(server.recordOf(orchardId).devicesOf(_owner), hasLength(2));
    expect(toasted(container, tester, l10n.deviceRequestDiffered), isTrue);
    expect(find.byKey(ValueKey(row)), findsNothing);
    await tester.pump(const Duration(seconds: 11));

    // Asked again: this time what the device shows is swapped on the way.
    asked = (await tester.runAsync(() => tablet.service.askDeviceApproval(orchardId)))!;
    container.read(deviceRequestsVersionProvider.notifier).state++;
    await settle(tester);
    row = 'team-attn-device-${asked.id}';
    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    await tester.runAsync(() async {
      await tablet.service.deviceAsk(orchardId);
      final stranger = await DeviceIdentity.generate();
      server.spoilDeviceRequest(orchardId, asked.id,
          deviceKey: stranger.publicKey, nonce: Uint8List.fromList(List.filled(32, 7)));
    });
    await look(tester);
    expect(find.byKey(const ValueKey('device-request-changed')), findsOneWidget);
    expect(find.text(l10n.deviceRequestChanged), findsOneWidget);
    expect(find.byType(ApprovalWords), findsNothing);
    expect(find.text(l10n.deviceRequestApprove), findsNothing);
    expect(server.deviceRequestsOf(orchardId), isEmpty, reason: 'ended');
    final drops = server.deviceDrops;
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    expect(server.deviceDrops, drops, reason: 'already ended: closing declines nothing');
    expect(server.recordOf(orchardId).devicesOf(_owner), hasLength(2));
  });

  testWidgets('closing the dialog after answering declines; an answer from before the app was started again '
      'can only be declined', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    var asked = (await tester.runAsync(() => alice.service.askDeviceApproval(orchardId)))!;
    final (container, _) = await pumpPage(tester, laptop);
    var row = 'team-attn-device-${asked.id}';
    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    // Looked at and closed (the header's X; the footer has Decline and
    // Continue): the request waits on, for whoever answers it.
    expect(find.text(l10n.close), findsNothing);
    await tester.tap(find.byTooltip(l10n.close).last);
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId).single.stage, 'created');

    // Someone else answered first, on a server that still lists it here:
    // going on says so, in those words.
    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    await tester.runAsync(() => phone.service.answerDeviceRequest(orchardId, asked.id));
    server.listsDeviceRequestsToAll = true;
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    expect(find.byKey(const ValueKey('device-request-error')), findsOneWidget);
    expect(find.text(l10n.deviceRequestTaken), findsOneWidget);
    server.listsDeviceRequestsToAll = false;
    // Taken back by her device while the dialog is open: it says the
    // request is gone, and offers nothing more.
    await tester.runAsync(() => alice.service.withdrawDeviceAsk(orchardId));
    await look(tester);
    expect(find.byKey(const ValueKey('device-request-gone')), findsOneWidget);
    expect(find.text(l10n.profileContinue), findsNothing);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    asked = (await tester.runAsync(() => alice.service.askDeviceApproval(orchardId)))!;
    container.read(deviceRequestsVersionProvider.notifier).state++;
    await settle(tester);
    row = 'team-attn-device-${asked.id}';

    // Answered, then closed: declined, so her device does not wait for nothing.
    await tester.tap(inKey(row, find.text(l10n.teamReview)));
    await settle(tester);
    await tester.tap(find.text(l10n.profileContinue));
    await settle(tester);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId), isEmpty);

    // Answered on this device, and then the app was started again: the page
    // lists the request, and offers only to decline it.
    final again = (await tester.runAsync(() async {
      final a = await alice.service.askDeviceApproval(orchardId);
      await laptop.service.answerDeviceRequest(orchardId, a.id);
      return a;
    }))!;
    await pumpPage(tester, laptop);
    await tester.tap(inKey('team-attn-device-${again.id}', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.byKey(const ValueKey('device-request-cut-off')), findsOneWidget);
    expect(find.text(l10n.profileContinue), findsNothing);
    await tester.tap(find.text(l10n.deviceRequestDecline));
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId), isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a device asks: Decline stands apart from Continue, in the tertiary place, and declines', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    final asked = (await tester.runAsync(() => alice.service.askDeviceApproval(orchardId)))!;
    await pumpPage(tester, laptop);
    await tester.tap(inKey('team-attn-device-${asked.id}', find.text(l10n.teamReview)));
    await settle(tester);
    expect(find.text(l10n.deviceRequestIntro('alice@example.com')), findsOneWidget);
    // Not the secondary beside Continue (where a slip refused the device):
    // the tertiary, as answering a request for access has it.
    expect(find.byKey(const ValueKey('zest-dialog-secondary')), findsNothing);
    final decline = find.byKey(const ValueKey('device-request-decline'));
    expect(find.descendant(of: decline, matching: find.text(l10n.deviceRequestDecline)), findsOneWidget);
    final cont = find.ancestor(of: find.text(l10n.profileContinue), matching: find.byKey(const ValueKey('zest-dialog-primary')));
    expect(cont, findsOneWidget);
    expect(tester.getRect(decline).right, lessThan(tester.getRect(cont).left - 24),
        reason: 'apart from Continue, not beside it');
    await tester.tap(decline);
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId), isEmpty);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('held back as a device nobody approved: the banner asks, shows the words, and says when it is in',
      (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    final (_, view) = await pumpPage(tester, alice, body: (_) => const OrchardStatusBanner());
    expect(find.byKey(const ValueKey('orchard-banner-rules')), findsOneWidget);
    expect(find.text(l10n.orchardRulesBanner(acme)), findsOneWidget);
    expect(inKey('orchard-rule-trustedDevice', find.text(l10n.orchardRuleTrustedDeviceFix)), findsOneWidget);

    await tester.tap(find.text(l10n.deviceAskAction));
    await settle(tester);
    final asked = server.deviceRequestsOf(orchardId).single;
    expect(asked.uid, _alice);
    expect(find.text(l10n.deviceAskIntro), findsOneWidget);
    expect(find.text(l10n.deviceAskWaiting), findsOneWidget);
    final code = (await tester.runAsync(() => alice.code))!;
    expect(find.text(l10n.deviceThisCode(code)), findsOneWidget);

    // The owner answers on the phone: her screen shows the same words.
    await tester.runAsync(() => phone.service.answerDeviceRequest(orchardId, asked.id));
    await look(tester);
    expect(find.text(l10n.deviceAskWords), findsOneWidget);
    final theirs =
        (await tester.runAsync(() => phone.service.deviceRequests(orchardId)))!.single;
    expect(theirs.stage, DeviceRequestStage.compare);
    expect(wordsIn(tester, 'device-ask-words'), theirs.words);
    expect(find.text(l10n.deviceAskWaitingApproval), findsOneWidget);

    // Approved: the dialog says so, and the banner is gone.
    await tester.runAsync(() => phone.service.approveDevice(orchardId, asked.id));
    await look(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('device-ask-approved')), findsOneWidget);
    expect(find.text(l10n.deviceAskApproved(acme)), findsOneWidget);
    expect(find.text(l10n.teamAdminDeviceApproved), findsOneWidget);
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);
    expect(find.byKey(const ValueKey('orchard-banner-rules')), findsNothing);
    expect((await tester.runAsync(() => view.service.deviceStanding(orchardId)))!.approved, isTrue);

    // An owner's device nobody approved: held back like anyone's, asked to
    // be approved, and not offered the rules, which are closed to it.
    final tablet = _Device(server, _owner, laptop.keys, 'tablet');
    addTearDown(() async {
      for (final db in tablet.storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
    await pumpPage(tester, tablet, body: (_) => const OrchardStatusBanner());
    expect(find.byKey(const ValueKey('orchard-banner-rules')), findsOneWidget);
    expect(find.text(l10n.deviceAskAction), findsOneWidget);
    expect(find.byKey(const ValueKey('orchard-rules-change')), findsNothing);
  });

  testWidgets('asking: declined, it can be asked again; closed, the request is taken back; '
      'a sign-in that cannot be approved is told so', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    await pumpPage(tester, alice, body: (_) => const OrchardStatusBanner());
    await tester.tap(find.text(l10n.deviceAskAction));
    await settle(tester);
    var asked = server.deviceRequestsOf(orchardId).single;
    await tester.runAsync(() => laptop.service.declineDeviceRequest(orchardId, asked.id));
    await look(tester);
    await settle(tester);
    expect(find.byKey(const ValueKey('device-ask-gone')), findsOneWidget);
    expect(find.text(l10n.deviceAskGone), findsOneWidget);

    await tester.tap(find.text(l10n.deviceAskAgain));
    await settle(tester);
    asked = server.deviceRequestsOf(orchardId).single;
    expect(find.text(l10n.deviceAskWaiting), findsOneWidget);
    // Closed while it waits: taken back.
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.deviceRequestsOf(orchardId), isEmpty);

    // The key kept here was lost and made again: the sign-in names the old
    // one, and says what to do.
    await tester.runAsync(() => DeviceIdentityStore(alice.keychain).forget(_alice));
    await tester.tap(find.text(l10n.deviceAskAction));
    await settle(tester);
    expect(find.byKey(const ValueKey('device-ask-cannot')), findsOneWidget);
    expect(find.text(l10n.deviceAskCannot), findsOneWidget);
    expect(server.deviceRequestsOf(orchardId), isEmpty);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
  });

  testWidgets('a device that was removed says so, and that what it held is gone', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    await tester.runAsync(() async {
      await approve(alice, laptop);
      await laptop.service.removeDevice(orchardId, uid: _alice, deviceKey: await alice.key);
    });
    await pumpPage(tester, alice, body: (_) => const OrchardStatusBanner());
    expect(find.text(l10n.orchardDeviceRemovedBanner(acme)), findsOneWidget);
    expect(find.text(l10n.orchardRulesBanner(acme)), findsNothing);
    expect(inKey('orchard-rule-trustedDevice', find.text(l10n.orchardRuleTrustedDeviceRemoved)), findsOneWidget);
    expect(find.text(l10n.deviceAskAction), findsOneWidget);
  });

  testWidgets('the Rules page: what turning the rule on takes, said and done from its row', (tester) async {
    await setUpOrchard(tester, approved: false);
    Widget page(OrchardSummary o) => OrchardRulesView(orchardId: o.id, onSaved: () {});
    ZestSwitch toggle() => tester.widget<ZestSwitch>(find.byKey(const ValueKey('rule-devices-switch')));
    var (container, _) = await pumpPage(tester, laptop, body: page);
    expect(inKey('rule-devices', find.text(l10n.orchardRulesDevices)), findsOneWidget);
    expect(inKey('rule-devices', find.text(l10n.orchardRulesDevicesBody)), findsOneWidget);
    expect((toggle().value, toggle().onChanged), (false, null), reason: 'not before two owner devices');
    expect(inKey('rule-devices-needs', find.text(l10n.orchardRulesDevicesNeedThis)), findsOneWidget);
    // A member is not told what turning it on takes: it is not theirs to
    // turn on.
    await pumpPage(tester, alice, body: page);
    expect((toggle().value, toggle().onChanged), (false, null));
    expect(find.byKey(const ValueKey('rule-devices-needs')), findsNothing);
    (container, _) = await pumpPage(tester, laptop, body: page);

    // The owner's first device approves itself, from the row.
    await tester.tap(find.byKey(const ValueKey('rule-devices-action')));
    await settle(tester);
    expect(server.recordOf(orchardId).devicesOf(_owner), {(await tester.runAsync(() => laptop.key))!});
    expect(toasted(container, tester, l10n.deviceApprovedThis), isTrue);
    expect(inKey('rule-devices-needs', find.text(l10n.orchardRulesDevicesNeedSecond)), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-devices-action')), findsNothing);
    expect(toggle().onChanged, isNull);
    await tester.pump(const Duration(seconds: 5));

    // On the phone, which is not approved: it asks from the row.
    await pumpPage(tester, phone, body: page);
    expect(inKey('rule-devices-needs', find.text(l10n.orchardRulesDevicesNeedAsk)), findsOneWidget);
    expect(inKey('rule-devices-needs', find.text(l10n.deviceAskAction)), findsOneWidget);

    // The second device approved: the rule can go on, with a word about who
    // has no approved device yet and about losing every owner device.
    await tester.runAsync(() => approve(phone, laptop));
    (container, _) = await pumpPage(tester, laptop, body: page);
    expect(find.byKey(const ValueKey('rule-devices-needs')), findsNothing);
    expect(find.text(l10n.orchardRulesDevicesWithout(1)), findsOneWidget);
    expect(find.text(l10n.orchardRulesDevicesLossNote), findsNothing);
    expect(toggle().onChanged, isNotNull);
    await tester.tap(find.byKey(const ValueKey('rule-devices-switch')));
    await tester.pump();
    expect(find.text(l10n.orchardRulesDevicesLossNote), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('rules-save')));
    await tester.tap(find.byKey(const ValueKey('rules-save')));
    await settle(tester);
    expect(server.recordOf(orchardId).rules.trustedDevices, isTrue);
    expect(toasted(container, tester, l10n.orchardRulesSaved), isTrue);
    expect(toggle().value, isTrue);
    expect(find.text(l10n.orchardRulesDevicesLossNote), findsNothing, reason: 'said before, not after');
    expect(find.byKey(const ValueKey('rule-devices-without')), findsNothing);
    await tester.pump(const Duration(seconds: 5));

    // A member sees the rule, and changes nothing.
    await tester.runAsync(() async {
      await laptop.service.setRules(orchardId, RecordRules.none);
      await approve(alice, laptop);
      await laptop.service.setRules(orchardId, rule);
    });
    await pumpPage(tester, alice, body: page);
    expect((toggle().value, toggle().onChanged), (true, null));
    expect(find.byKey(const ValueKey('rule-devices-needs')), findsNothing);

    // On, with a single approved device left among the owners: turning it
    // on would take two, turning it off does not.
    await tester.runAsync(
        () async => laptop.service.removeDevice(orchardId, uid: _owner, deviceKey: await phone.key));
    await pumpPage(tester, laptop, body: page);
    expect((toggle().value, toggle().onChanged != null), (true, true));
  });

  testWidgets("a member's devices: listed by their codes, this one marked, removed after asking",
      (tester) async {
    await setUpOrchard(tester);
    await tester.runAsync(() => approve(alice, laptop));
    final aliceCode = (await tester.runAsync(() => alice.code))!;
    final laptopCode = (await tester.runAsync(() => laptop.code))!;
    final phoneCode = (await tester.runAsync(() => phone.code))!;
    Widget devices(OrchardSummary o, String uid) => MemberDevicesView(
        orchard: o, uid: uid, name: '$uid@example.com', isMe: uid == _owner);

    // The owner's own: this device first and marked; either may be removed.
    var (container, _) = await pumpPage(tester, laptop, body: (o) => devices(o, _owner));
    final first = tester.getTopLeft(find.byKey(ValueKey('member-device-$laptopCode'))).dy;
    final second = tester.getTopLeft(find.byKey(ValueKey('member-device-$phoneCode'))).dy;
    expect(first, lessThan(second));
    expect(inKey('member-device-$laptopCode', find.textContaining(l10n.memberDevicesThis)), findsOneWidget);
    expect(inKey('member-device-$phoneCode', find.textContaining(l10n.memberDevicesThis)), findsNothing);
    // Grey with a device, as Settings' devices show it: which one is in
    // hand, not a state.
    final mark = tester.widget<ZestStatusPill>(inKey('member-device-$laptopCode', find.byType(ZestStatusPill)));
    expect((mark.kind, mark.icon), (ZestStatusKind.neutral, LucideIcons.monitorCheck));
    expect(find.byKey(const ValueKey('member-devices-this')), findsNothing, reason: 'this device is approved');
    expect(find.text(l10n.memberDevicesHelp), findsOneWidget);

    // Alice's, as the owner sees them: removed after asking.
    (container, _) = await pumpPage(tester, laptop, body: (o) => devices(o, _alice));
    expect(find.byKey(ValueKey('member-device-$aliceCode')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('member-device-remove-$aliceCode')));
    await settle(tester);
    expect(find.text(l10n.memberDeviceRemoveTitle(aliceCode)), findsOneWidget);
    expect(find.text(l10n.memberDeviceRemoveBody('alice@example.com')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).devicesOf(_alice), hasLength(1), reason: 'Cancel removes nothing');
    await tester.tap(find.byKey(ValueKey('member-device-remove-$aliceCode')));
    await settle(tester);
    await tester.tap(find.text(l10n.memberDeviceRemove).last);
    await settle(tester);
    expect(server.recordOf(orchardId).devicesOf(_alice), isEmpty);
    expect(toasted(container, tester, l10n.memberDeviceRemoved), isTrue);
    expect(find.byKey(const ValueKey('member-devices-none')), findsOneWidget);
    expect(find.text(l10n.teamChangeDeviceRemoved('alice@example.com')), findsNothing, reason: 'not this page');
    await tester.pump(const Duration(seconds: 5));

    // Alice, on her device that is no longer approved: it says so, and asks.
    await pumpPage(tester, alice,
        body: (o) => MemberDevicesView(orchard: o, uid: _alice, name: 'alice@example.com', isMe: true));
    expect(inKey('member-devices-this', find.text(l10n.memberDevicesThisNot(aliceCode))), findsOneWidget);
    expect(inKey('member-devices-this', find.text(l10n.deviceAskAction)), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('member-devices-this-action')));
    await settle(tester);
    expect(find.text(l10n.deviceAskWaiting), findsOneWidget);
    expect(server.deviceRequestsOf(orchardId).single.uid, _alice);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // She sees the owner's devices, and may remove none of them.
    await pumpPage(tester, alice,
        body: (o) => MemberDevicesView(orchard: o, uid: _owner, name: 'owner-1@example.com', isMe: false));
    expect(find.byKey(ValueKey('member-device-$laptopCode')), findsOneWidget);
    expect(find.byTooltip(l10n.memberDeviceRemove), findsNothing);
    expect(find.byKey(const ValueKey('member-devices-this')), findsNothing, reason: 'not her own list');

    // The owners' last approved device stays while the rule is on.
    await tester.runAsync(() async {
      await laptop.service.setRules(orchardId, rule);
      await laptop.service.removeDevice(orchardId, uid: _owner, deviceKey: await phone.key);
    });
    (container, _) = await pumpPage(tester, laptop, body: (o) => devices(o, _owner));
    await tester.tap(find.byKey(ValueKey('member-device-remove-$laptopCode')));
    await settle(tester);
    expect(find.text(l10n.memberDeviceRemoveThisBody), findsOneWidget);
    await tester.tap(find.text(l10n.memberDeviceRemove).last);
    await settle(tester);
    expect(toasted(container, tester, l10n.deviceErrorLastOwner), isTrue);
    expect(server.recordOf(orchardId).devicesOf(_owner), hasLength(1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('an owner whose first device is not approved approves it from their own row', (tester) async {
    await setUpOrchard(tester, approved: false);
    final code = (await tester.runAsync(() => laptop.code))!;
    final (container, _) = await pumpPage(tester, laptop,
        body: (o) => MemberDevicesView(orchard: o, uid: _owner, name: 'owner-1@example.com', isMe: true));
    expect(find.byKey(const ValueKey('member-devices-none')), findsOneWidget);
    expect(inKey('member-devices-this', find.text(l10n.memberDevicesThisFirst(code))), findsOneWidget);
    await tester.tap(find.text(l10n.deviceApproveThis));
    await settle(tester);
    expect(server.recordOf(orchardId).devicesOf(_owner), hasLength(1));
    expect(toasted(container, tester, l10n.deviceApprovedThis), isTrue);
    expect(find.byKey(const ValueKey('member-devices-this')), findsNothing);
    expect(inKey('member-device-$code', find.textContaining(l10n.memberDevicesThis)), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('on a phone the list of Team pages counts a device that asks beside Overview', (tester) async {
    await setUpOrchard(tester, ruleOn: true);
    await tester.runAsync(() => alice.service.askDeviceApproval(orchardId));
    await pumpPage(tester, laptop, phoneList: true);
    expect(inKey('team-phone-overview', find.text('1')), findsOneWidget);
    // Someone who could not approve it is not shown it.
    await tester.runAsync(() async {
      await laptop.service.setRules(orchardId, RecordRules.none);
    });
    await pumpPage(tester, alice, phoneList: true);
    expect(inKey('team-phone-overview', find.text('1')), findsNothing);
  });

  testWidgets('in every language, on a computer and on a small phone: asking and approving, nothing clipped',
      (tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await setUpOrchard(tester, ruleOn: true);
    Future<void> open(Finder button, String what) async {
      await tester.ensureVisible(button);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(button);
      await settle(tester);
      expect(tester.takeException(), isNull, reason: what);
    }

    try {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        for (final small in [false, true]) {
          final where = '$locale ${small ? 'phone' : 'computer'}';
          // On a phone the dialogs are sheets, as on a real one.
          debugDefaultTargetPlatformOverride = small ? TargetPlatform.android : null;

          // Her device, held back: the banner, asking, and the words.
          await pumpPage(tester, alice,
              phone: small, locale: locale, theme: theme, body: (_) => const OrchardStatusBanner());
          expect(tester.takeException(), isNull, reason: '$where: the banner');
          await open(find.text(t.deviceAskAction), '$where: asking');
          expect(find.text(t.deviceAskWaiting), findsOneWidget, reason: where);
          final asked = server.deviceRequestsOf(orchardId).single;
          await tester.runAsync(() => phone.service.answerDeviceRequest(orchardId, asked.id));
          await look(tester);
          expect(tester.takeException(), isNull, reason: '$where: the words on the asking device');
          expect(find.byKey(const ValueKey('device-ask-words')), findsOneWidget, reason: where);
          await tester.tap(find.text(t.cancel).last);
          await settle(tester);
          expect(server.deviceRequestsOf(orchardId), isEmpty, reason: where);

          // The owner: the request under what needs them, and the dialog
          // through to the words.
          final again = (await tester.runAsync(() => alice.service.askDeviceApproval(orchardId)))!;
          await pumpPage(tester, laptop, phone: small, locale: locale, theme: theme);
          expect(tester.takeException(), isNull, reason: '$where: the owner page');
          await open(inKey('team-attn-device-${again.id}', find.text(t.teamReview)), '$where: reviewing');
          await open(find.text(t.profileContinue), '$where: answering');
          await tester.runAsync(() => alice.service.deviceAsk(orchardId));
          await look(tester);
          expect(tester.takeException(), isNull, reason: '$where: the words on the approving device');
          expect(find.byKey(const ValueKey('device-request-words')), findsOneWidget, reason: where);
          await tester.tap(find.text(t.deviceRequestDiffer));
          await settle(tester);
          expect(tester.takeException(), isNull, reason: '$where: declined');
          await tester.pump(const Duration(seconds: 11));

          // The Rules page's row and a member's devices.
          await pumpPage(tester, laptop,
              phone: small,
              locale: locale,
              theme: theme,
              body: (o) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      MemberDevicesView(orchard: o, uid: _owner, name: 'owner-1@example.com', isMe: true),
                      const SizedBox(height: 16),
                      OrchardRulesView(orchardId: o.id, onSaved: () {}),
                    ],
                  ));
          expect(tester.takeException(), isNull, reason: '$where: the rules and the devices');
          expect(find.text(t.orchardRulesDevices), findsOneWidget, reason: where);
          expect(find.text(t.memberDevicesHelp), findsOneWidget, reason: where);
        }
      }
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
