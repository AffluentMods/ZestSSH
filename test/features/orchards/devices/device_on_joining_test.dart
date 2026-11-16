import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/crypto/join_device.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// The device someone joins on, approved as they are let in (from a security UX
/// review). In a team that lets in approved devices only, the device
/// that accepts an invitation (to an address, or a code) offers itself with
/// the joining account's signature; whoever lets them in sees it ticked, with
/// its code and platform, where that signature checks out with the keys they
/// compare and they may approve that person's devices from here; letting them
/// in then adds the member.add and the device.trust in one step, and that
/// device gets in at once. Anything else (another key's signature, the rule
/// off, someone who approves no devices, a record that refuses it) lets them
/// in without it. The (fake) server checks what the real one does.

const _owner = 'owner-1';
const _alice = 'alice';
const _bob = 'bob';
const _carol = 'carol';

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

/// One device's secure storage: every device in a test has its own.
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
  _Device(this.shared, this.uid, this.keys, this.name) {
    service = OrchardService(
      server: shared.as(uid, device: name),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys),
      deviceKeys: DeviceIdentityStore(keychain),
    );
  }

  final FakeCrateServer shared;
  final String uid;
  final AccountKeys keys;

  /// What the device is called in the test, which is also its sign-in.
  final String name;
  final keychain = _Keychain();
  final storage = _MemoryStorage();
  late final OrchardService service;

  /// This device's key, as the record writes it.
  Future<String> get key async => (await DeviceIdentityStore(keychain).forAccount(uid)).key;

  Future<void> close() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  }
}

OrchardBilling _seats() => OrchardBilling.fromJson({
      'seats': {'bought': 5, 'included': 0, 'total': 5, 'used': 3, 'free': 2, 'over': false},
      'business_services': {'state': 'off'},
    });

/// Lets the crypto and the fake server's work finish, then the frames.
Future<void> _work(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  const rule = RecordRules(trustedDevices: true);

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  final devices = <_Device>[];

  setUpAll(() async {
    for (final uid in [_owner, _alice, _bob, _carol]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: _owner);
    for (final uid in [_owner, _alice, _bob, _carol]) {
      await server.publish(uid, keys[uid]!, email: '$uid@example.com');
    }
  });

  tearDown(() async {
    for (final d in devices) {
      await d.close();
    }
    devices.clear();
  });

  _Device device(String uid, String name) {
    final d = _Device(server, uid, keys[uid]!, name);
    devices.add(d);
    return d;
  }

  /// The owner's laptop and phone, in an Orchard of theirs with one Crate
  /// that its first role (Member) uses, both devices approved (the laptop by
  /// itself, the phone after the words); with [ruleOn], the rule on too.
  Future<({String id, String member, _Device laptop, _Device phone})> team({bool ruleOn = true}) async {
    final laptop = device(_owner, 'laptop');
    final phone = device(_owner, 'phone');
    final id = await laptop.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(id).roles.values.single.id;
    await laptop.service.approveThisDevice(id);
    await phone.service.refresh();
    final asked = await phone.service.askDeviceApproval(id);
    await laptop.service.deviceRequests(id);
    await laptop.service.answerDeviceRequest(id, asked.id);
    await phone.service.deviceAsk(id);
    await laptop.service.deviceRequests(id);
    await laptop.service.approveDevice(id, asked.id);
    if (ruleOn) await laptop.service.setRules(id, rule);
    await phone.service.refresh();
    return (id: id, member: member, laptop: laptop, phone: phone);
  }

  /// [by] invites [person] as [role]; returns the invitation's id, which
  /// [person] now sees among their own.
  Future<String> inviteTo(_Device by, _Device person, String orchardId, String role) async {
    await by.service.invite(orchardId, email: '${person.uid}@example.com', role: role);
    final id = (await by.service.invites(orchardId)).singleWhere((i) => i.email == '${person.uid}@example.com').id;
    server.mine.add(MyInvite(
        id: id,
        orchardId: orchardId,
        role: role,
        crates: 1,
        expiresAt: DateTime.now().add(const Duration(days: 7)),
        accepted: false));
    return id;
  }

  /// [by] invites [person] as [role], and [person] accepts on their device,
  /// as the app does. Returns the invitation as [by] lists it.
  Future<OrchardInvite> invited(_Device by, _Device person, String orchardId, String role) async {
    final id = await inviteTo(by, person, orchardId, role);
    await person.service.acceptInvite(id, orchardId: orchardId);
    return (await by.service.invites(orchardId)).singleWhere((i) => i.id == id);
  }

  group('the service', () {
    test('with the rule on, the device they accepted on is offered; letting them in with it approves it in the same '
        'step, and that device gets in at once', () async {
      final t = await team();
      final alice = device(_alice, 'alice-laptop');
      final invite = await invited(t.laptop, alice, t.id, t.member);
      // What the server keeps and lists: her device and her account's word for it.
      final offered = invite.acceptedDevice!;
      expect(offered.keyText, await alice.key);
      expect(offered.platform, 'windows');
      expect(
          await verifyJoinDevice(
              signingKey: keys[_alice]!.signingPublicKey,
              orchardId: t.id,
              uid: _alice,
              deviceKey: offered.key,
              inviteId: invite.id,
              signature: offered.signature),
          isTrue);
      expect(await t.laptop.service.joinDeviceOffer(t.id, invite), await alice.key);
      expect(server.recordOf(t.id).members.containsKey(_alice), isFalse, reason: 'nobody is in by accepting');

      final before = server.entriesOf(t.id).length;
      expect(await t.laptop.service.confirmInvite(t.id, invite, approveDevice: await alice.key), isFalse,
          reason: 'nothing asked for was left out');
      final added = server.entriesOf(t.id).sublist(before);
      expect(added.map((e) => e.type), [RecordTypes.memberAdd, RecordTypes.deviceTrust]);
      // Approved on the laptop, signed by it, for her, as any approval is.
      expect((added.last.body['uid'], added.last.body['device'], added.last.body['via']),
          (_alice, await alice.key, await t.laptop.key));
      expect(server.confirmations.last.device, isNotNull, reason: 'one confirmation carried both');
      expect(server.recordOf(t.id).devicesOf(_alice), {await alice.key});
      // The laptop's own copy has both.
      expect([for (final d in await t.laptop.service.memberDevices(t.id, _alice)) d.key], [await alice.key]);

      // Her device: in at once, approved, with nothing to ask for.
      expect(await alice.service.refresh(), [t.id]);
      final standing = await alice.service.deviceStanding(t.id);
      expect((standing.ruleOn, standing.approved), (true, true));
      expect(server.namedDevices[FakeCrateServer.sessionOf(_alice, 'alice-laptop')], await alice.key);
    });

    test('an invite code used on a device offers it too', () async {
      final t = await team();
      final alice = device(_alice, 'alice-laptop');
      final made = await t.laptop.service.makeInviteCode(t.id,
          role: t.member,
          expiresIn: 3600,
          shown: const JoinOffer(team: 'Acme', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]));
      await alice.service.acceptInviteCode(await alice.service.previewInviteCode(made.code));
      final invite = (await t.laptop.service.invites(t.id)).singleWhere((i) => i.id == made.inviteId);
      expect(invite.acceptedDevice?.keyText, await alice.key);
      expect(await t.laptop.service.joinDeviceOffer(t.id, invite), await alice.key);
      await t.laptop.service.confirmInvite(t.id, invite, approveDevice: await alice.key);
      expect(server.recordOf(t.id).devicesOf(_alice), {await alice.key});
    });

    test('a device another key vouched for, or one vouched for in another team, is not offered, and not approved '
        'even when asked to', () async {
      final t = await team();
      final alice = device(_alice, 'alice-laptop');
      await t.laptop.service.invite(t.id, email: '$_alice@example.com', role: t.member);
      final id = (await t.laptop.service.invites(t.id)).single.id;
      final aliceDevice = deviceKeyBytes(await alice.key)!;
      final stranger = await AccountKeys.generate();
      for (final signature in [
        // Signed by someone else's key, as a server that makes one up would.
        await stranger.sign(joinDeviceMessage(orchardId: t.id, uid: _alice, deviceKey: aliceDevice, inviteId: id)),
        // Her own key, for another team.
        await keys[_alice]!
            .sign(joinDeviceMessage(orchardId: 'another-team', uid: _alice, deviceKey: aliceDevice, inviteId: id)),
        // Her own key, as someone else.
        await keys[_alice]!.sign(joinDeviceMessage(orchardId: t.id, uid: _bob, deviceKey: aliceDevice, inviteId: id)),
        // Her own key, with another invitation.
        await keys[_alice]!
            .sign(joinDeviceMessage(orchardId: t.id, uid: _alice, deviceKey: aliceDevice, inviteId: 'an-old-invitation')),
      ]) {
        server.acceptAs(t.id, id, _alice, device: JoinDevice(key: aliceDevice, signature: signature));
        final invite = (await t.laptop.service.invites(t.id)).single;
        expect(invite.acceptedDevice, isNotNull, reason: 'listed as the server has it');
        expect(await t.laptop.service.joinDeviceOffer(t.id, invite), isNull);
      }
      // Let in with it all the same (as a screen that was tampered with would
      // ask): she is in, and no device of hers is approved.
      await t.laptop.service.confirmInvite(t.id, (await t.laptop.service.invites(t.id)).single,
          approveDevice: await alice.key);
      expect(server.recordOf(t.id).members.containsKey(_alice), isTrue);
      expect(server.recordOf(t.id).devicesOf(_alice), isEmpty);
      expect(server.confirmations.last.device, isNull);
    });

    test('with the rule off nothing is offered; an approval the record would refuse is left out, and they are let in '
        'without it', () async {
      final t = await team(ruleOn: false);
      final alice = device(_alice, 'alice-laptop');
      final invite = await invited(t.laptop, alice, t.id, t.member);
      expect(invite.acceptedDevice?.keyText, await alice.key, reason: 'offered all the same');
      // From the owner's approved laptop: nothing waits on her device.
      expect((await t.laptop.service.deviceStanding(t.id)).approved, isTrue);
      expect(await t.laptop.service.joinDeviceOffer(t.id, invite), isNull, reason: 'nothing waits on it');
      // Asked to anyway, from the owner's tablet, which the record does not
      // list (with the rule off it gets in): the record refuses the approval
      // here, and she is let in without it.
      final tablet = device(_owner, 'tablet');
      expect(await tablet.service.refresh(), [t.id]);
      expect((await tablet.service.deviceStanding(t.id)).approved, isFalse);
      // Left out: confirmInvite says so, for its person to be told.
      expect(
          await tablet.service.confirmInvite(t.id, (await tablet.service.invites(t.id)).single,
              approveDevice: await alice.key),
          isTrue);
      expect(server.recordOf(t.id).members.containsKey(_alice), isTrue);
      expect(server.recordOf(t.id).devicesOf(_alice), isEmpty);
      expect(server.confirmations.last.device, isNull);
    });

    // Found in a security review: ZestSSH Cloud
    // replayed the statement of a device since lost and taken back when its
    // account was invited again.
    test('a device the record approved and took back for her before is never offered again, nor approved', () async {
      final t = await team();
      final laptop = device(_alice, 'alice-laptop');
      final first = await invited(t.laptop, laptop, t.id, t.member);
      await t.laptop.service.confirmInvite(t.id, first, approveDevice: await laptop.key);
      final lost = await laptop.key;
      expect(server.recordOf(t.id).devicesOf(_alice), {lost});
      // The laptop is lost: its approval is taken back, then she leaves the team.
      await t.laptop.service.removeDevice(t.id, uid: _alice, deviceKey: lost);
      await t.laptop.service.removeMember(t.id, _alice);

      // Invited again, she accepts on her phone; the server lists the lost
      // laptop instead, with a statement her account signed for it (as one
      // replayed with an invitation id the server chose would).
      final phone = device(_alice, 'alice-phone');
      final again = await inviteTo(t.laptop, phone, t.id, t.member);
      await phone.service.acceptInvite(again, orchardId: t.id);
      final lostKey = deviceKeyBytes(lost)!;
      server.acceptAs(t.id, again, _alice,
          device: JoinDevice(
              key: lostKey,
              signature: await keys[_alice]!
                  .sign(joinDeviceMessage(orchardId: t.id, uid: _alice, deviceKey: lostKey, inviteId: again))));
      final listed = (await t.laptop.service.invites(t.id)).singleWhere((i) => i.id == again);
      expect(listed.acceptedDevice?.keyText, lost);
      expect(await t.laptop.service.joinDeviceOffer(t.id, listed), isNull, reason: 'not offered');
      expect(await t.laptop.service.confirmInvite(t.id, listed, approveDevice: lost), isTrue,
          reason: 'asked for anyway, it is left out, and that is said');
      expect(server.recordOf(t.id).members[_alice]?.status, MemberStatus.active);
      expect(server.recordOf(t.id).devicesOf(_alice), isEmpty, reason: 'the lost laptop is not approved again');
    });

    test('someone who may let people in but approves no devices is not offered one', () async {
      final t = await team();
      // A Lead may invite, and so let in, those below (handing out no more
      // than the Lead has); only owners and admins approve someone else's
      // device.
      final lead = await t.laptop.service.saveRole(t.id, name: 'Lead', can: {RoleCan.invite}, crates: {
        for (final c in server.recordOf(t.id).roles[t.member]!.crates.entries) c.key: {...c.value},
      });
      await t.laptop.service.moveRole(t.id, lead, up: true);
      final bob = device(_bob, 'bob-laptop');
      final asLead = await invited(t.laptop, bob, t.id, lead);
      // (Bob gets in with his device, approved by the owner as he is let in.)
      await t.laptop.service.confirmInvite(t.id, asLead, approveDevice: await t.laptop.service.joinDeviceOffer(t.id, asLead));
      expect(await bob.service.refresh(), [t.id]);
      expect((await bob.service.deviceStanding(t.id)).approved, isTrue);

      final carol = device(_carol, 'carol-laptop');
      final invite = await invited(bob, carol, t.id, t.member);
      expect(invite.acceptedDevice?.keyText, await carol.key);
      expect(await bob.service.joinDeviceOffer(t.id, invite), isNull);
      expect(await t.laptop.service.joinDeviceOffer(t.id, invite), await carol.key, reason: 'an owner may');
      await bob.service.confirmInvite(t.id, invite);
      expect(server.recordOf(t.id).members.containsKey(_carol), isTrue);
      expect(server.recordOf(t.id).devicesOf(_carol), isEmpty);
    });

    test('an older app offers no device, and is let in as before', () async {
      final t = await team();
      final alice = device(_alice, 'alice-laptop');
      final id = await inviteTo(t.laptop, alice, t.id, t.member);
      // (No team id: the device is not offered, as from a version before it.)
      await alice.service.acceptInvite(id);
      final invite = (await t.laptop.service.invites(t.id)).single;
      expect(invite.acceptedDevice, isNull);
      expect(await t.laptop.service.joinDeviceOffer(t.id, invite), isNull);
      await t.laptop.service.confirmInvite(t.id, invite);
      expect(server.recordOf(t.id).members.containsKey(_alice), isTrue);
      expect(server.confirmations.last.device, isNull);
    });
  });

  group('on screen', () {
    /// A screen of [as]'s with a button that runs [action].
    Future<void> open(WidgetTester tester, _Device as, String orchardId,
        Future<void> Function(BuildContext, WidgetRef, OrchardSummary) action) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final orchard = (await tester.runAsync(
          () async => readOrchardSummary(await as.service.databases.open(orchardId), orchardId)))!;
      await tester.pumpWidget(ProviderScope(
        overrides: [
          orchardServiceProvider.overrideWithValue(as.service),
          orchardSummariesProvider.overrideWith((ref) async => [orchard]),
          orchardBillingProvider.overrideWith((ref, id) async => _seats()),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) =>
                  TextButton(onPressed: () => action(context, ref, orchard), child: const Text('open')),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await _work(tester);
    }

    Finder tick() => find.byKey(const ValueKey('review-approve-device'));
    bool ticked(WidgetTester tester) => tester.widget<CheckboxListTile>(tick()).value!;

    /// The Orchard with the rule on (unless not [ruleOn]), alice accepted on
    /// her laptop, and what the owner's laptop lists of her.
    Future<({String id, _Device laptop, _Device alice, InviteView view})> waiting(WidgetTester tester,
        {bool ruleOn = true}) async {
      return (await tester.runAsync(() async {
        final t = await team(ruleOn: ruleOn);
        final alice = device(_alice, 'alice-laptop');
        await invited(t.laptop, alice, t.id, t.member);
        final views = await checkedInvites(t.laptop.service, t.id, await t.laptop.service.invites(t.id));
        return (id: t.id, laptop: t.laptop, alice: alice, view: views.single);
      }))!;
    }

    testWidgets('the review offers her device ticked, with its code and platform; let in, both go in one step',
        (tester) async {
      final w = await waiting(tester);
      final key = (await tester.runAsync(() => w.alice.key))!;
      expect(w.view.deviceOffer, key);
      await open(tester, w.laptop, w.id, (context, ref, orchard) => showJoinReview(context, ref, orchard, w.view));
      expect(tick(), findsOneWidget);
      expect(ticked(tester), isTrue);
      expect(find.text(l10n.joinApproveDevice(deviceCode(key), l10n.platformWindows)), findsOneWidget);
      expect(find.text(l10n.joinApproveDeviceHint), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('review-let-in')));
      await _work(tester);
      // The fingerprint is compared, as for any invitation to an address; the
      // box is not asked a second time.
      expect(find.byKey(const ValueKey('invitee-fingerprint')), findsOneWidget);
      expect(tick(), findsOneWidget);
      await tester.tap(find.text(l10n.orchardInviteConfirmMatch));
      await _work(tester);
      expect(server.confirmations.last.device, isNotNull);
      expect(server.recordOf(w.id).devicesOf(_alice), {key});
      await tester.pump(const Duration(seconds: 5));
    });

    // Found in a security review: only the log
    // said a device asked for was left out.
    testWidgets('a device asked for that is left out after all: she is in, and the person is told', (tester) async {
      final w = await waiting(tester);
      await open(
          tester,
          w.laptop,
          w.id,
          (context, ref, orchard) =>
              letInvitedIn(context, ref, orchard, w.view.invite, compare: false, approveDevice: 'not-a-device-she-offered'));
      await _work(tester);
      expect(server.recordOf(w.id).members.containsKey(_alice), isTrue);
      expect(server.recordOf(w.id).devicesOf(_alice), isEmpty);
      final said = l10n.orchardInviteDeviceNotApproved('$_alice@example.com');
      final history = ProviderScope.containerOf(tester.element(find.text('open').first))
          .read(notificationCenterProvider)
          .history;
      // (A long message is told as its start and the rest.)
      expect(history.any((n) => n.title.isNotEmpty && said.startsWith(n.title.replaceAll('…', ''))), isTrue,
          reason: 'told, not only logged');
      expect(history.any((n) => n.title == l10n.orchardInviteConfirmed('$_alice@example.com')), isFalse);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('unticked, she is let in without it', (tester) async {
      final w = await waiting(tester);
      await open(tester, w.laptop, w.id, (context, ref, orchard) => showJoinReview(context, ref, orchard, w.view));
      await tester.tap(tick());
      await tester.pump();
      expect(ticked(tester), isFalse);
      await tester.tap(find.byKey(const ValueKey('review-let-in')));
      await _work(tester);
      await tester.tap(find.text(l10n.orchardInviteConfirmMatch));
      await _work(tester);
      expect(server.recordOf(w.id).members.containsKey(_alice), isTrue);
      expect(server.confirmations.last.device, isNull);
      expect(server.recordOf(w.id).devicesOf(_alice), isEmpty);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('with the rule off, or a device another key vouched for, there is no box', (tester) async {
      final off = await waiting(tester, ruleOn: false);
      expect(off.view.deviceOffer, isNull);
      await open(tester, off.laptop, off.id, (context, ref, orchard) => showJoinReview(context, ref, orchard, off.view));
      expect(find.byKey(const ValueKey('review-let-in')), findsOneWidget);
      expect(tick(), findsNothing);

      await tester.pumpWidget(const SizedBox());
      final forged = (await tester.runAsync(() async {
        for (final d in devices) {
          await d.close();
        }
        devices.clear();
        server = FakeCrateServer(accountUid: _owner);
        for (final uid in [_owner, _alice]) {
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        final t = await team();
        final alice = device(_alice, 'alice-laptop');
        await t.laptop.service.invite(t.id, email: '$_alice@example.com', role: t.member);
        final id = (await t.laptop.service.invites(t.id)).single.id;
        final aliceDevice = deviceKeyBytes(await alice.key)!;
        final signature =
            await (await AccountKeys.generate())
                .sign(joinDeviceMessage(orchardId: t.id, uid: _alice, deviceKey: aliceDevice, inviteId: id));
        server.acceptAs(t.id, id, _alice, device: JoinDevice(key: aliceDevice, signature: signature));
        final views = await checkedInvites(t.laptop.service, t.id, await t.laptop.service.invites(t.id));
        return (id: t.id, laptop: t.laptop, view: views.single);
      }))!;
      expect(forged.view.invite.acceptedDevice, isNotNull);
      expect(forged.view.deviceOffer, isNull);
      await open(
          tester, forged.laptop, forged.id, (context, ref, orchard) => showJoinReview(context, ref, orchard, forged.view));
      expect(find.byKey(const ValueKey('review-let-in')), findsOneWidget);
      expect(tick(), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('on a phone an invitation is let in from the fingerprint, with the box under it', (tester) async {
      final w = await waiting(tester);
      final key = (await tester.runAsync(() => w.alice.key))!;
      await open(
          tester,
          w.laptop,
          w.id,
          (context, ref, orchard) async =>
              letInvitedIn(context, ref, orchard, w.view.invite, compare: true, offerDevice: w.view.deviceOffer));
      expect(find.byKey(const ValueKey('invitee-fingerprint')), findsOneWidget);
      expect(tick(), findsOneWidget);
      expect(ticked(tester), isTrue);
      expect(find.text(l10n.joinApproveDevice(deviceCode(key), l10n.platformWindows)), findsOneWidget);
      await tester.tap(find.text(l10n.orchardInviteConfirmMatch));
      await _work(tester);
      expect(server.recordOf(w.id).devicesOf(_alice), {key});
      await tester.pump(const Duration(seconds: 5));
    });
  });
}
