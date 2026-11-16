import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/crate_authority_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

import 'fake_crate_server.dart';
import 'vaults_window_helper.dart';

/// A certificate handed over, on screen (3.0). With ZestSSH
/// Cloud away, a member opens "Certificate from an owner" in the Crate, and
/// their request is there as a code and as a text; an owner opens "Sign a
/// request", is told who asks for what and until when, and that it was
/// checked against what the device last had, signs, and hands the
/// certificate back the same two ways; the member's device keeps it. What is
/// pasted wrong is said as what it is. Every language fits a phone.

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

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  final storages = <_MemoryStorage>[];
  final keys = <String, AccountKeys>{};
  late OrchardService owner;
  late OrchardService alice;
  late String orchardId;
  late String production;
  late String member;

  /// What was last copied, and what a paste gives.
  String? clipboard;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    clipboard = null;
  });

  tearDown(() async {
    for (final s in storages) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    storages.clear();
  });

  OrchardService serviceFor(String uid) {
    final storage = _MemoryStorage();
    storages.add(storage);
    return OrchardService(
      server: server.as(uid),
      databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
      author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
    );
  }

  /// The owner's Orchard: Production with its authority on (members sign in
  /// as deploy, owners as root), the role Member (use of Production), alice
  /// a Member on a device of her own.
  Future<void> build(WidgetTester tester, {bool authority = true}) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        for (final uid in ['owner-1', 'owner-2', 'alice']) {
          keys[uid] = await AccountKeys.generate();
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = serviceFor('owner-1');
        orchardId = await owner.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        final first = server.recordOf(orchardId).roles.values.single;
        member = first.id;
        production = first.crates.keys.single;
        await owner.invite(orchardId, email: 'alice@example.com', role: member);
        server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'alice');
        await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
        if (authority) {
          final vault = await owner.createCrate(orchardId, 'Owner keys', ownersOnly: true);
          await owner.setAuthorityKey(orchardId, production,
              keyCrate: vault,
              ttlMinutes: 60,
              principals: {
                member: ['deploy'],
                FixedRoles.owner: ['root'],
              },
              keyLabel: 'Production certificate authority');
        }
        await owner.refresh();
        alice = serviceFor('alice');
        await alice.refresh();
      });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// Pumps the Crates screen of [service]'s device, opened.
  Future<void> openCrates(WidgetTester tester, OrchardService service,
      {Locale locale = const Locale('en'), ThemeData? theme, Size size = const Size(1200, 1600)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          return [await readOrchardSummary(await service.databases.open(orchardId), orchardId)];
        }),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(onPressed: () => showOrchardCrates(context, ref, orchardId), child: const Text('open')),
                Text('${ref.watch(orchardSummariesProvider).valueOrNull?.length}'),
              ],
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
    // Production's Certificates (4.0: one vault at a time, under tabs).
    await openVaultTab(tester, production, VaultTab.certificates);
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  Future<void> tapKey(WidgetTester tester, String k) async {
    await showInVaults(tester, key(k));
    await tester.ensureVisible(key(k));
    await tester.pumpAndSettle();
    await tester.tap(key(k));
    await settle(tester);
  }

  /// The text an owner's device hands back for the request [by]'s device makes.
  Future<String> signedFor(WidgetTester tester, OrchardService by) async => (await tester.runAsync(() async {
        final ask = (await by.handRequest(orchardId, production)).toText();
        return (await owner.signHandedRequest(await owner.reviewHandedRequest(ask))).toText();
      }))!;

  testWidgets('with the server away: from a member\'s request to the certificate on their device, by copy and paste',
      (tester) async {
    await build(tester);
    mockClipboard(tester);
    server.down = true;

    // The member: the Crate has the way in, and the request is there to show and to copy.
    await openCrates(tester, alice);
    expect(key('crate-certs-hand-$production'), findsOneWidget);
    expect(key('crate-certs-sign-$production'), findsNothing, reason: 'a member signs nothing');
    await tapKey(tester, 'crate-certs-hand-$production');
    expect(find.text(l10n.certHandIntro), findsOneWidget);
    expect(key('cert-hand-code'), findsOneWidget);
    expect(tester.widget<HandedCode>(key('cert-hand-code')).text, startsWith(kHandedRequestPrefix));
    await tapKey(tester, 'cert-hand-copy');
    final ask = clipboard!;
    expect(ask, tester.widget<HandedCode>(key('cert-hand-code')).text, reason: 'the text is what the code holds');
    expect(HandedRequest.fromText(ask)!.request.uid, 'alice');
    await tester.pump(const Duration(seconds: 5)); // the toast times out
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // The owner: reads it, is told who asks for what, signs, and has the answer to show and to copy.
    await openCrates(tester, owner);
    expect(key('crate-certs-sign-$production'), findsOneWidget);
    expect(key('crate-certs-hand-$production'), findsNothing, reason: 'this device signs for itself');
    await tapKey(tester, 'crate-certs-sign-$production');
    expect(find.text(l10n.certSignIntro), findsOneWidget);
    await tester.enterText(key('cert-sign-request'), ask);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(find.text(l10n.certSignWho('alice@example.com', 'Production')), findsOneWidget);
    expect(tester.widget<Text>(key('cert-sign-as')).data, 'deploy');
    expect(tester.widget<Text>(key('cert-sign-role')).data, 'Member');
    final until = tester.widget<Text>(key('cert-sign-until')).data!;
    final inAnHour = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
    expect([accessTimeText(inAnHour - 60, l10n), accessTimeText(inAnHour, l10n)], contains(until));
    expect(key('cert-sign-stale'), findsOneWidget, reason: 'the server could not be asked, and the owner is told');
    expect(find.text(l10n.orchardNamed('Acme')), findsOneWidget, reason: 'and which team it is for');
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    expect(find.text(l10n.certSignedIntro), findsOneWidget);
    expect(tester.widget<HandedCode>(key('cert-sign-code')).text, startsWith(kHandedCertificatePrefix));
    await tapKey(tester, 'cert-sign-copy');
    final give = clipboard!;
    expect(give, tester.widget<HandedCode>(key('cert-sign-code')).text);
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);

    // The member again: what the owner sent goes in, and the device holds a certificate.
    expect(await tester.runAsync(() => alice.heldCertificate(orchardId, production)), isNull);
    await openCrates(tester, alice);
    await tapKey(tester, 'crate-certs-hand-$production');
    clipboard = 'Here you go:\n$give\nGood for an hour.';
    await tapKey(tester, 'cert-hand-paste');
    expect(tester.widget<TextField>(find.descendant(of: key('cert-hand-answer'), matching: find.byType(TextField)))
        .controller!
        .text, contains(kHandedCertificatePrefix));
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    final held = (await tester.runAsync(() => alice.heldCertificate(orchardId, production)))!;
    expect(held.certificate.principals, ['deploy']);
    expect(find.text(l10n.certHandDone('Production', accessTimeText(held.validBefore, l10n))), findsOneWidget);
    expect(key('cert-hand-code'), findsNothing, reason: 'nothing more to show');
    // A result says Done (3.0 UI: Close is never the main button).
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);
    expect(server.askedWhileDown, greaterThanOrEqualTo(0));
    // What is handed over is copied as a secret is: past the 45
    // seconds it stays on the clipboard.
    await tester.pump(kSecretClipboardLife);
  });

  testWidgets('with the server answering, the owner is not told of an older copy; Sign another starts afresh',
      (tester) async {
    await build(tester);
    final ask = (await tester.runAsync(() async => (await alice.handRequest(orchardId, production)).toText()))!;
    await openCrates(tester, owner);
    await tapKey(tester, 'crate-certs-sign-$production');
    await tester.enterText(key('cert-sign-request'), ask);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(key('cert-sign-who'), findsOneWidget, reason: 'Enter reads it');
    expect(key('cert-sign-stale'), findsNothing);
    // Back, and it is still there to read again.
    await tester.tap(find.text(l10n.back).last);
    await settle(tester);
    expect(key('cert-sign-request'), findsOneWidget);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    expect(key('cert-sign-code'), findsOneWidget);
    await tester.tap(find.text(l10n.certSignAnother));
    await settle(tester);
    expect(key('cert-sign-code'), findsNothing);
    expect(tester.widget<TextField>(find.descendant(of: key('cert-sign-request'), matching: find.byType(TextField)))
        .controller!
        .text, isEmpty);
  });

  testWidgets('an owner is told what is wrong with what they are handed, and nothing is signed', (tester) async {
    await build(tester);
    final ask = (await tester.runAsync(() async => (await alice.handRequest(orchardId, production)).toText()))!;
    final give = await signedFor(tester, alice);
    // A second owner, on a device of their own: what changes the team
    // while the first owner's screen is up comes from there.
    late OrchardService owner2;
    await tester.runAsync(() async {
      await owner.invite(orchardId, email: 'owner-2@example.com', role: FixedRoles.owner);
      server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'owner-2');
      await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
      owner2 = serviceFor('owner-2');
      await owner2.refresh();
    });
    await openCrates(tester, owner);
    await tapKey(tester, 'crate-certs-sign-$production');
    Future<void> read(String text, String says) async {
      await tester.enterText(key('cert-sign-request'), text);
      await tester.tap(find.text(l10n.certSignRead));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(says));
      expect(key('cert-sign-who'), findsNothing);
    }

    // Nothing entered: nothing happens.
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(key('cert-sign-problem'), findsNothing);
    await read('hello', l10n.certSignNotARequest);
    await read(give, l10n.certSignIsCertificate);
    await read(ask.substring(0, ask.length - 12), l10n.certSignNotARequest);
    // Suspended since she asked.
    await tester.runAsync(() => owner2.suspendMember(orchardId, 'alice'));
    await read(ask, l10n.certSignNotMember);
    await tester.runAsync(() => owner2.resumeMember(orchardId, 'alice'));
    // Read while all was well, and suspended before the signing: said where the request is entered.
    await tester.enterText(key('cert-sign-request'), ask);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(key('cert-sign-who'), findsOneWidget);
    await tester.runAsync(() => owner2.suspendMember(orchardId, 'alice'));
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(l10n.certSignNotMember));
    expect(key('cert-sign-code'), findsNothing);
  });

  testWidgets('a member is told what is wrong with what they paste, and nothing is kept', (tester) async {
    await build(tester);
    final laptop = serviceFor('alice');
    await tester.runAsync(laptop.refresh);
    final forLaptop = await signedFor(tester, laptop);
    await openCrates(tester, alice);
    await tapKey(tester, 'crate-certs-hand-$production');
    final own = tester.widget<HandedCode>(key('cert-hand-code')).text;
    Future<void> take(String text, String says) async {
      await tester.enterText(key('cert-hand-answer'), text);
      await tester.pump();
      await tester.tap(find.text(l10n.certHandUse));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-hand-problem')).data, noOrphan(says));
      expect(key('cert-hand-done'), findsNothing);
    }

    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    expect(key('cert-hand-problem'), findsNothing, reason: 'nothing entered: nothing happens');
    await take('hello', l10n.certHandNotAnAnswer);
    await take(own, l10n.certHandIsRequest);
    await take(forLaptop, l10n.certHandNotForThisDevice);
    expect(await tester.runAsync(() => alice.heldCertificate(orchardId, production)), isNull);
    // A good one after all that: the problem goes, and it is kept.
    final forHer = await signedFor(tester, alice);
    await tester.enterText(key('cert-hand-answer'), forHer);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(key('cert-hand-problem'), findsNothing);
    expect(key('cert-hand-done'), findsOneWidget, reason: 'Enter takes it');
  });

  testWidgets('who is offered what: nothing without an authority, signing where the key is, asking where it is not',
      (tester) async {
    await build(tester, authority: false);
    await openCrates(tester, alice);
    expect(key('crate-certs-hand-$production'), findsNothing);
    await openCrates(tester, owner);
    expect(key('crate-certs-sign-$production'), findsNothing);
    expect(key('crate-certs-hand-$production'), findsNothing);

    // With an authority: a second owner whose device has not got its key
    // yet asks like anybody, and is not offered to sign.
    await build(tester);
    late OrchardService owner2;
    await tester.runAsync(() async {
      await owner.invite(orchardId, email: 'owner-2@example.com', role: FixedRoles.owner);
      server.acceptAs(orchardId, (await owner.invites(orchardId)).single.id, 'owner-2');
      await owner.confirmInvite(orchardId, (await owner.invites(orchardId)).single);
      owner2 = serviceFor('owner-2');
      await owner2.refresh();
    });
    await openCrates(tester, owner2);
    expect(key('crate-certs-hand-$production'), findsOneWidget);
    expect(key('crate-certs-sign-$production'), findsNothing);
    expect(key('crate-certs-settings-$production'), findsOneWidget, reason: 'an owner all the same');

    // A member whose role signs in as nobody has nothing to ask for.
    await tester.runAsync(() async {
      await owner.changeAuthority(orchardId, production, ttlMinutes: 60, principals: {
        FixedRoles.owner: ['root'],
      });
      await alice.refresh();
    });
    await openCrates(tester, alice);
    expect(key('crate-certs-hand-$production'), findsNothing);
  });

  testWidgets('a request nobody would sign is not shown: the member is told why', (tester) async {
    await build(tester);
    await openCrates(tester, alice);
    // The authority goes off after the screen was drawn.
    await tester.runAsync(() => owner.turnAuthorityOff(orchardId, production));
    await tapKey(tester, 'crate-certs-hand-$production');
    expect(tester.widget<Text>(key('cert-hand-cannot')).data, l10n.teamCertNoAuthority);
    expect(key('cert-hand-code'), findsNothing);
    expect(key('cert-hand-answer'), findsNothing);
  });

  testWidgets('a device the server turns away is shown no request: it is told that it is held back',
      (tester) async {
    await build(tester);
    await openCrates(tester, alice);
    // The server refuses this device after the screen was drawn.
    server.fault = 403;
    await tapKey(tester, 'crate-certs-hand-$production');
    expect(tester.widget<Text>(key('cert-hand-cannot')).data, l10n.teamCertHeldBack);
    expect(key('cert-hand-code'), findsNothing);
    // And a team that is held back on this device offers nothing to ask for.
    server.fault = null;
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      final db = await alice.databases.open(orchardId);
      await db.customStatement("UPDATE orchard_info SET status = 'rules' WHERE id = 1");
    });
    await openCrates(tester, alice);
    expect(key('crate-certs-hand-$production'), findsNothing);
  });

  testWidgets('who is offered to sign and who to ask, case by case', (tester) async {
    const crate = CrateSummary(id: 'c1', name: 'Production', level: 'use');
    Future<({bool sign, bool ask})> offered({
      required String role,
      String status = 'active',
      bool on = true,
      bool keyHere = false,
      List<String>? names = const ['deploy'],
    }) async {
      final orchard =
          OrchardSummary(id: 'o1', name: 'Acme', role: role, crates: const [crate], defaultCrateId: 'c1', status: status);
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          crateAuthoritiesProvider('o1').overrideWith((ref) async => {
                'c1': CrateAuthorityView(
                  crateId: 'c1',
                  on: on,
                  generation: 1,
                  ttlMinutes: 60,
                  principals: const {
                    'owner': ['root'],
                  },
                  keyCrate: 'vault',
                  publicKeys: {1: Uint8List(32)},
                  myUserNames: names,
                  keyHere: keyHere,
                ),
              }),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: CrateCertificatesLine(orchard: orchard, crate: crate)),
        ),
      ));
      await tester.pumpAndSettle();
      return (
        sign: key('crate-certs-sign-c1').evaluate().isNotEmpty,
        ask: key('crate-certs-hand-c1').evaluate().isNotEmpty,
      );
    }

    const nothing = (sign: false, ask: false);
    // An owner whose device holds the key signs, and needs nobody to sign for it.
    expect(await offered(role: 'owner', keyHere: true, names: ['root']), (sign: true, ask: false));
    // One whose device has not got it yet asks like anybody.
    expect(await offered(role: 'owner', names: ['root']), (sign: false, ask: true));
    // A member asks.
    expect(await offered(role: 'member-role'), (sign: false, ask: true));
    // Someone who is no owner any more, with the key still on the device: they ask, and are not offered to sign.
    expect(await offered(role: 'member-role', keyHere: true), (sign: false, ask: true));
    // The authority off: nothing to sign and nothing to ask for, key or no key.
    expect(await offered(role: 'owner', on: false, keyHere: true, names: ['root']), nothing);
    expect(await offered(role: 'member-role', on: false), nothing);
    // A role that signs in as nobody, and an account the record does not have.
    expect(await offered(role: 'member-role', names: const []), nothing);
    expect(await offered(role: 'member-role', names: null), nothing);
    // A team this device is held back from: neither, for a member and for an owner.
    expect(await offered(role: 'member-role', status: 'rules'), nothing);
    expect(await offered(role: 'owner', status: 'rules', keyHere: true, names: ['root']), nothing);
  });

  test('every reason has words of its own', () {
    final asked = <String>{
      for (final p in HandedRequestProblem.values)
        if (p != HandedRequestProblem.refused) handedRequestMessage(l10n, HandedRequestRefused(p)),
      for (final r in CertRequestRefusal.values)
        handedRequestMessage(l10n, HandedRequestRefused(HandedRequestProblem.refused, refusal: r)),
    };
    expect(asked, hasLength(HandedRequestProblem.values.length - 1 + CertRequestRefusal.values.length));
    expect(handedRequestMessage(l10n, const HandedRequestRefused(HandedRequestProblem.keyNotHere)),
        l10n.certSignKeyNotHere);
    expect(
        handedRequestMessage(
            l10n, const HandedRequestRefused(HandedRequestProblem.refused, refusal: CertRequestRefusal.notSignedByMember)),
        l10n.certSignBadSignature);
    final given = <String>{for (final p in HandedCertificateProblem.values) handedCertificateMessage(l10n, p)};
    expect(given, hasLength(HandedCertificateProblem.values.length));
    expect(handedCertificateMessage(l10n, HandedCertificateProblem.expired), l10n.certHandExpired);
    expect(handedCertificateMessage(l10n, HandedCertificateProblem.notForThisDevice), l10n.certHandNotForThisDevice);
  });

  test('a camera takes the other device\'s code and nothing else it sees', () {
    final ask = HandedRequest(
      orchardId: 'o',
      crateId: 'c',
      request: CertRequest(
        id: 'r',
        uid: 'u',
        keyVersion: 1,
        sshPublicKey: Uint8List(32),
        requestedAt: 1791504000,
        signature: Uint8List(64),
      ),
    ).toText();
    final give = HandedCertificate(orchardId: 'o', crateId: 'c', requestId: 'r', certificate: Uint8List(40)).toText();
    expect(handedTextAmong([null, 'https://example.com', give, ask], const {HandedKind.request}), ask);
    expect(handedTextAmong([null, 'https://example.com', give, ask], const {HandedKind.certificate}), give);
    expect(handedTextAmong([give], const {HandedKind.request}), isNull);
    expect(handedTextAmong([ask], const {HandedKind.certificate}), isNull);
    expect(handedTextAmong([ask.substring(0, 40)], const {HandedKind.request}), isNull, reason: 'half a code is none');
    expect(handedTextAmong(const [], const {HandedKind.request}), isNull);
    // A short text (a request): 240 on a computer, 280 on a phone; a long one
    // (a certificate, a pass) has more points to a side and is drawn at 340.
    expect(handedCodeSize(phone: false, length: 200), 240);
    expect(handedCodeSize(phone: true, length: 200), 280);
    expect(handedCodeSize(phone: false, length: handedCodeShortUpTo), 240);
    expect(handedCodeSize(phone: false, length: handedCodeShortUpTo + 1), 340);
    expect(handedCodeSize(phone: true, length: 900), 340);
  });

  testWidgets('in every language, on a phone: both screens at each step, nothing clipped', (tester) async {
    await tester.runAsync(() async {
      final loader = FontLoader('GeistSans');
      for (final f in ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']) {
        loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
      }
      await loader.load();
    });
    final theme = ThemeData(fontFamily: 'GeistSans');
    await build(tester);
    server.down = true;
    const phone = Size(390, 844);
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      // The member's screen, with a problem said.
      await openCrates(tester, alice, locale: locale, theme: theme, size: phone);
      await tapKey(tester, 'crate-certs-hand-$production');
      expect(key('cert-hand-code'), findsOneWidget, reason: '$locale');
      final ask = tester.widget<HandedCode>(key('cert-hand-code')).text;
      await tester.enterText(key('cert-hand-answer'), ask);
      await tester.pump();
      await tester.tap(find.text(t.certHandUse));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-hand-problem')).data, noOrphan(t.certHandIsRequest), reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the member\'s screen');

      // The owner's screen: a problem said, then the request read, then signed.
      await openCrates(tester, owner, locale: locale, theme: theme, size: phone);
      await tapKey(tester, 'crate-certs-sign-$production');
      await tester.enterText(key('cert-sign-request'), 'hello');
      await tester.tap(find.text(t.certSignRead));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(t.certSignNotARequest), reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the owner\'s screen, a problem');
      await tester.enterText(key('cert-sign-request'), ask);
      await tester.tap(find.text(t.certSignRead));
      await settle(tester);
      expect(key('cert-sign-stale'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the owner\'s screen, the request read');
      await tester.tap(find.text(t.certSignConfirm));
      await settle(tester);
      expect(key('cert-sign-code'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the owner\'s screen, signed');
      final give = tester.widget<HandedCode>(key('cert-sign-code')).text;
      // The code keeps its shape. A certificate is a long text: its code is
      // drawn larger than a request's, as large as the window lets it be, and
      // all of it (with its white edge) stays on the screen.
      final drawn = tester.getSize(find.descendant(of: key('cert-sign-code'), matching: find.byType(QrImageView)));
      expect(drawn.width, drawn.height, reason: '$locale: a code is square');
      expect(ask.length, lessThanOrEqualTo(handedCodeShortUpTo), reason: 'a request is a short text');
      expect(give.length, greaterThan(handedCodeShortUpTo), reason: 'a certificate is a long text');
      expect(drawn.width, greaterThan(handedCodeSize(phone: true, length: ask.length)),
          reason: '$locale: larger than a request\'s code');
      final whole = tester.getRect(key('cert-sign-code'));
      expect(whole.left, greaterThanOrEqualTo(0), reason: '$locale');
      expect(whole.right, lessThanOrEqualTo(phone.width), reason: '$locale: within the screen');
      final white = tester.getRect(find
          .descendant(of: key('cert-sign-code'), matching: find.byType(Container))
          .first);
      expect(white.left, greaterThanOrEqualTo(0), reason: '$locale: the white edge is on the screen');
      expect(white.right, lessThanOrEqualTo(phone.width), reason: '$locale: the white edge is on the screen');

      // The member's screen, done.
      await openCrates(tester, alice, locale: locale, theme: theme, size: phone);
      await tapKey(tester, 'crate-certs-hand-$production');
      await tester.enterText(key('cert-hand-answer'), give);
      await tester.pump();
      await tester.tap(find.text(t.certHandUse));
      await settle(tester);
      expect(key('cert-hand-done'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: '$locale: the member\'s screen, done');
    }
  });
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
