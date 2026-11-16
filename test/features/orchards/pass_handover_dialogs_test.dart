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
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart' show TeamPage;
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/team/team_words.dart' show offlineSpanWords;
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show NavSection, activeSidebarNavProvider;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/last_line.dart';
import '../../visual/shots_util.dart';
import 'fake_crate_server.dart';
import 'vaults_window_helper.dart';

/// An offline pass, on screen (3.0).
/// A member whose device is past a Crate's offline limit opens
/// "Offline pass from an owner" on the Crate's row: their request is there
/// as a code and as a text, with what their device is called. An owner
/// opens "Sign a request", is told who asks for what from which device,
/// chooses how long, signs, and hands the pass back the same two ways; the
/// member's device keeps it and the Crate is open. What is pasted wrong is
/// said as what it is, on both screens. Every language fits a phone.

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

/// One device's Orchard databases, each in a file of its own: an Orchard
/// that its offline limit closed is opened again with what it held, as on a
/// device.
class _FileStorage implements OrchardDatabaseStorage {
  _FileStorage(this._folder);

  final Directory _folder;

  /// Every database that was opened, for closing them at the end.
  final opened = <AppDatabase>[];
  final _ids = <String>{};

  File _file(String orchardId) => File('${_folder.path}/$orchardId.sqlite');

  @override
  Future<bool> exists(String orchardId) async => _ids.contains(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    _ids.add(orchardId);
    final db = AppDatabase.forTesting(NativeDatabase(_file(orchardId)), isOrchard: true);
    opened.add(db);
    return db;
  }

  @override
  Future<void> delete(String orchardId) async => _ids.remove(orchardId);

  @override
  Future<List<String>> list() async => _ids.toList();
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

/// A device: someone's account on a machine of its own.
class _Device {
  _Device(this.uid, this._serve, {Directory? folder, this.withKey = true})
      : storage = folder == null ? _MemoryStorage() : _FileStorage(folder) {
    service = onScreen();
  }

  final String uid;
  final OrchardService Function(_Device) _serve;

  /// In memory, or in files of [folder] where a test closes an Orchard and
  /// opens it again.
  final OrchardDatabaseStorage storage;

  /// Whether the device can keep a key of its own.
  final bool withKey;
  final keychain = _Keychain();

  /// The device's service for what a test does behind the screens.
  late final OrchardService service;

  /// When this device last reached ZestSSH Cloud (seconds).
  late int last;

  /// A service of its own for a screen: whatever shows a screen owns the
  /// service's databases, and closes them with it.
  OrchardService onScreen() => _serve(this);

  Future<String> get code async => deviceCode((await DeviceIdentityStore(keychain).forAccount(uid)).key);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late FakeCrateServer server;
  final storages = <OrchardDatabaseStorage>[];
  final keys = <String, AccountKeys>{};
  late _Device owner;
  late _Device alice;
  late String orchardId;
  late String production;

  /// Every device's clock, and the server's, in seconds.
  late int now;

  /// What was last copied, and what a paste gives.
  String? clipboard;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    clipboard = null;
    now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    OrchardService.debugNow = () => DateTime.fromMillisecondsSinceEpoch(now * 1000);
  });

  tearDown(() async {
    OrchardService.debugNow = DateTime.now;
    for (final s in storages) {
      for (final db in s is _FileStorage ? s.opened : (s as _MemoryStorage).dbs.values) {
        try {
          await db.close();
        } catch (_) {/* closed already, by its offline limit */}
      }
    }
    storages.clear();
  });

  _Device deviceFor(String uid, {Directory? folder, bool withKey = true}) {
    final device = _Device(
      uid,
      folder: folder,
      withKey: withKey,
      (d) => OrchardService(
        server: server.as(uid),
        databases: OrchardDatabasesNotifier(
          OrchardDatabaseKeys(const FlutterSecureStorage()),
          storage: d.storage,
          contact: DeviceContact(read: () => OrchardContact(lastContact: d.last, latest: now), now: () => now),
        ),
        author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
        deviceKeys: d.withKey ? DeviceIdentityStore(d.keychain) : null,
      ),
    )..last = now;
    storages.add(device.storage);
    return device;
  }

  /// The owner's Orchard: Production closes on a device after a day away;
  /// alice is a Member (use of Production) on a device of her own. Both
  /// devices reached ZestSSH Cloud a moment ago.
  Future<void> build(WidgetTester tester, {int orchardHours = 0}) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1')
          ..clock = () => DateTime.fromMillisecondsSinceEpoch(now * 1000);
        for (final uid in ['owner-1', 'owner-2', 'alice']) {
          keys[uid] = await AccountKeys.generate();
          await server.publish(uid, keys[uid]!, email: '$uid@example.com');
        }
        owner = deviceFor('owner-1');
        orchardId = await owner.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        final first = server.recordOf(orchardId).roles.values.single;
        production = first.crates.keys.single;
        await owner.service.invite(orchardId, email: 'alice@example.com', role: first.id);
        server.acceptAs(orchardId, (await owner.service.invites(orchardId)).single.id, 'alice');
        await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
        await owner.service.setCrateOfflineLimit(orchardId, production, 24);
        if (orchardHours > 0) await owner.service.setRules(orchardId, RecordRules(offlineHours: orchardHours));
        await owner.service.refresh();
        alice = deviceFor('alice');
        await alice.service.refresh();
        await OrchardSyncCoordinator(
                service: alice.service, server: alice.service.server, databases: alice.service.databases)
            .syncAll();
      });

  void mockClipboard(WidgetTester tester) {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String;
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
  }

  /// [page] on [device]'s screen, with the Orchard as that device has it
  /// now ([closed]: closed there by its own offline limit).
  Future<void> show(WidgetTester tester, _Device device, Widget Function(OrchardSummary) page,
      {Locale locale = const Locale('en'), ThemeData? theme, Size size = const Size(1200, 1800), bool closed = false}) async {
    late OrchardSummary summary;
    final service = device.onScreen();
    await tester.runAsync(() async {
      try {
        await service.refresh();
      } on SocketException {
        // The server is away: the device shows what it holds.
      }
      summary = await readOrchardSummary(await service.databases.open(orchardId), orchardId);
    });
    if (closed) summary = OrchardSummary.closedOffline(orchardId, last: summary);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        orchardServiceProvider.overrideWithValue(service),
        orchardDatabasesProvider.overrideWith((ref) => service.databases),
        orchardSummariesProvider.overrideWith((ref) async => [summary]),
        activeOrchardProvider.overrideWithValue(AsyncData(summary)),
        orchardAuthorProvider
            .overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: device.uid, keys: keys[device.uid]!))),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
        orchardSsoProvider.overrideWith((ref, id) async => const OrchardSso(kind: SsoKind.saml, active: false)),
        currentUserProvider.overrideWithValue(UserProfile(uid: device.uid, email: '${device.uid}@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        cloudReachStateProvider.overrideWith((ref) => Stream.value(const CloudReachState(CloudReach.deviceOffline))),
        cloudStatusConfigProvider
            .overrideWithValue(const CloudStatusConfig(url: '', service: 'api.example', keys: {})),
        activeSidebarNavProvider.overrideWith((ref) => NavSection.team),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(body: page(summary)),
      ),
    ));
    await settle(tester);
  }

  Widget crates(OrchardSummary o) => SingleChildScrollView(child: OrchardCratesView(orchardId: o.id));
  Finder key(String k) => find.byKey(ValueKey(k));

  Future<void> tapKey(WidgetTester tester, String k) async {
    await showInVaults(tester, key(k));
    await tester.ensureVisible(key(k));
    await tester.pumpAndSettle();
    await tester.tap(key(k));
    await settle(tester);
  }

  /// The request [by]'s device makes for [crateId], and the pass the
  /// owner's device signs for it.
  Future<({String ask, String give})> handed(WidgetTester tester, _Device by,
          {String? crateId, int hours = 24}) async =>
      (await tester.runAsync(() async {
        final ask = (await by.service.handPassRequest(orchardId, crateId: crateId ?? production)).toText();
        final give = (await owner.service.signPass(await owner.service.reviewPassRequest(ask), hours: hours)).toText();
        return (ask: ask, give: give);
      }))!;

  testWidgets("from a member's request to the pass on their device, by copy and paste", (tester) async {
    await build(tester);
    mockClipboard(tester);
    // A day and an hour away from ZestSSH Cloud: Production is closed on
    // alice's device, and its row has the way on.
    now += 25 * 3600;
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-closed-$production'), findsOneWidget);
    expect(key('crate-offline-sign-$production'), findsNothing, reason: 'a member signs nothing');
    await tapKey(tester, 'crate-offline-pass-$production');
    expect(find.text(l10n.passAskButton), findsWidgets);
    expect(find.text(l10n.passAskIntro), findsOneWidget);
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.text('Production')), findsOneWidget,
        reason: 'what the pass is for');
    final code = tester.widget<HandedCode>(key('pass-hand-code')).text;
    expect(code, startsWith(kHandedPassRequestPrefix));
    // This device's code stands as a code of its own, with what to do with it.
    expect(tester.widget<SelectableText>(key('pass-hand-device')).data, await tester.runAsync(() => alice.code));
    expect(find.text(l10n.vaultUiDeviceCodeLabel), findsOneWidget);
    expect(find.text(l10n.vaultUiDeviceCodeHelp), findsOneWidget);
    await tapKey(tester, 'pass-hand-copy');
    final ask = clipboard!;
    expect(ask, code, reason: 'the text is what the code holds');
    final asked = HandedPassRequest.fromText(ask)!;
    expect((asked.orchardId, asked.crateId, asked.request.uid), (orchardId, production, 'alice'));
    await tester.pump(const Duration(seconds: 5)); // the toast times out
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    // The owner, whose device is in contact: reads it, is told who asks
    // for what from which device, chooses three days, signs, and has the
    // pass to show and to copy.
    owner.last = now;
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-sign-$production');
    expect(find.text(l10n.certSignTitle), findsOneWidget);
    expect(find.text(l10n.certSignIntro), findsOneWidget);
    await tester.enterText(key('cert-sign-request'), ask);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(tester.widget<Text>(key('pass-sign-who')).data, l10n.passSignWho('alice@example.com', 'Production'));
    expect(tester.widget<Text>(key('pass-sign-device')).data, await tester.runAsync(() => alice.code));
    expect(tester.widget<Text>(key('pass-sign-role')).data, 'Member');
    expect(tester.widget<ZestSelect<int>>(key('pass-sign-lasts')).value, 24, reason: 'a day unless they choose');
    expect(find.text(l10n.passSignNote), findsOneWidget);
    expect(key('pass-sign-stale'), findsNothing, reason: 'the server answered');
    expect(key('cert-sign-who'), findsNothing, reason: 'this is no request for a certificate');
    expect(find.text(l10n.orchardNamed('Acme')), findsOneWidget, reason: 'and which team it is for');
    await tester.tap(key('pass-sign-lasts'));
    await settle(tester);
    expect([for (final h in kOfflinePassChoices) find.text(offlineSpanWords(l10n, h)).evaluate().isNotEmpty],
        everyElement(isTrue), reason: 'every length a pass may have is offered');
    await tester.tap(find.text(offlineSpanWords(l10n, 72)).last);
    await settle(tester);
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    expect(find.text(l10n.certSignedIntro), findsOneWidget);
    expect(tester.widget<HandedCode>(key('cert-sign-code')).text, startsWith(kHandedPassPrefix));
    await tapKey(tester, 'cert-sign-copy');
    final give = clipboard!;
    final pass = HandedPass.fromText(give)!.pass;
    expect((pass.uid, pass.by, pass.until - pass.madeAt), ('alice', 'owner-1', 72 * 3600));
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);

    // alice again: what the owner sent goes in, and Production is open.
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-pass-$production');
    clipboard = 'Here you go:\n$give\nGood for three days.';
    await tapKey(tester, 'pass-hand-paste');
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    expect(tester.widget<Text>(key('pass-hand-done')).data,
        noOrphan(l10n.passAskDone('Production', accessTimeText(pass.until, l10n))));
    expect(key('pass-hand-code'), findsNothing, reason: 'nothing more to show');
    // A result says Done (3.0 UI: Close is never the main button).
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);
    expect(await tester.runAsync(() async => closedCratesIn(await alice.service.databases.open(orchardId))), isEmpty);
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-closed-$production'), findsNothing);
    // And its row says what holds it open, and until when.
    expect(
        find.descendant(
            of: key('crate-pass-$production'), matching: find.text(l10n.cratePassHolds(accessTimeText(pass.until, l10n)))),
        findsOneWidget);
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-pass-$production'), findsNothing, reason: 'the pass is alice\'s device\'s, not this one\'s');
    // What is handed over is copied as a secret is: it leaves the
    // clipboard by itself, after both sides have pasted it.
    expect(SecretClipboard.holding, isTrue);
    await tester.pump(kSecretClipboardLife);
    expect(SecretClipboard.holding, isFalse);
  });

  testWidgets('for all of an Orchard: asked under its offline rule, and said as that on both screens',
      (tester) async {
    await build(tester, orchardHours: 48);
    Widget rules(OrchardSummary o) =>
        SingleChildScrollView(padding: const EdgeInsets.all(16), child: OrchardRulesView(orchardId: o.id, onSaved: () {}));
    await show(tester, alice, rules);
    expect(key('rule-offline-sign'), findsNothing, reason: 'a member signs nothing');
    await tapKey(tester, 'rule-offline-pass');
    expect(find.descendant(of: find.byType(ZestDialogShell), matching: find.text(l10n.orchardNamed('Acme'))),
        findsOneWidget, reason: 'what the pass is for: all of it');
    final ask = tester.widget<HandedCode>(key('pass-hand-code')).text;
    expect(HandedPassRequest.fromText(ask)!.crateId, kAllOfOrchard);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    await show(tester, owner, rules);
    await tapKey(tester, 'rule-offline-sign');
    await tester.enterText(key('cert-sign-request'), ask);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(tester.widget<Text>(key('pass-sign-who')).data,
        l10n.passSignWhoAll('alice@example.com', l10n.orchardNamed('Acme')));
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    final give = tester.widget<HandedCode>(key('cert-sign-code')).text;
    final pass = HandedPass.fromText(give)!;
    expect((pass.crateId, pass.pass.until - pass.pass.madeAt), (kAllOfOrchard, 24 * 3600));
    // "Sign another" starts afresh, for either kind of request.
    await tester.tap(find.text(l10n.certSignAnother));
    await settle(tester);
    expect(key('cert-sign-code'), findsNothing);
    expect(key('pass-sign-who'), findsNothing);
    expect(tester.widget<TextField>(find.descendant(of: key('cert-sign-request'), matching: find.byType(TextField)))
        .controller!
        .text, isEmpty);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);

    await show(tester, alice, rules);
    await tapKey(tester, 'rule-offline-pass');
    await tester.enterText(key('pass-hand-answer'), give);
    await tester.pump();
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    expect(tester.widget<Text>(key('pass-hand-done')).data,
        noOrphan(l10n.passAskDone(l10n.orchardNamed('Acme'), accessTimeText(pass.pass.until, l10n))));
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);
    // Under the rule, and on every Crate with a limit: what holds it open.
    await show(tester, alice, rules);
    expect(tester.widget<Text>(key('rule-offline-pass-holds')).data,
        l10n.cratePassHolds(accessTimeText(pass.pass.until, l10n)));
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-pass-$production'), findsOneWidget);
    await show(tester, owner, rules);
    expect(key('rule-offline-pass-holds'), findsNothing);
  });

  testWidgets('an owner is told what is wrong with what they are handed, and nothing is signed', (tester) async {
    await build(tester);
    final good = await handed(tester, alice);
    late _Device owner2;
    late String own;
    await tester.runAsync(() async {
      await owner.service.invite(orchardId, email: 'owner-2@example.com', role: FixedRoles.owner);
      server.acceptAs(orchardId, (await owner.service.invites(orchardId)).single.id, 'owner-2');
      await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
      owner2 = deviceFor('owner-2');
      await owner2.service.refresh();
      own = (await owner.service.handPassRequest(orchardId, crateId: production)).toText();
    });
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-sign-$production');
    Future<void> read(String text, String says) async {
      await tester.enterText(key('cert-sign-request'), text);
      await tester.tap(find.text(l10n.certSignRead));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(says));
      expect(key('pass-sign-who'), findsNothing);
      expect(key('cert-sign-who'), findsNothing);
    }

    await read('hello', l10n.certSignNotARequest);
    await read(good.give, l10n.passSignIsPass);
    await read(good.ask.substring(0, good.ask.length - 12), l10n.certSignNotARequest);
    await read(own, l10n.passSignOwnDevice);
    // Suspended since she asked.
    await tester.runAsync(() => owner2.service.suspendMember(orchardId, 'alice'));
    await read(good.ask, l10n.certSignNotMember);
    await tester.runAsync(() => owner2.service.resumeMember(orchardId, 'alice'));
    // Read while all was well, and suspended before the signing: said
    // where the request is entered.
    await tester.enterText(key('cert-sign-request'), good.ask);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(key('pass-sign-who'), findsOneWidget);
    await tester.runAsync(() => owner2.service.suspendMember(orchardId, 'alice'));
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(l10n.certSignNotMember));
    expect(key('cert-sign-code'), findsNothing);
    await tester.runAsync(() => owner2.service.resumeMember(orchardId, 'alice'));
    // This device has itself been away for longer than the limit allows.
    now += 25 * 3600;
    final late = await tester.runAsync(
        () async => (await alice.service.handPassRequest(orchardId, crateId: production)).toText());
    await read(late!, l10n.passSignClosedHere);
    // With the server away, the owner is told what the request was
    // checked against.
    owner.last = now;
    server.down = true;
    await tester.enterText(key('cert-sign-request'), late);
    await tester.tap(find.text(l10n.certSignRead));
    await settle(tester);
    expect(key('pass-sign-stale'), findsOneWidget);
    expect(tester.widget<Text>(key('pass-sign-stale')).data, l10n.certSignStaleNote);
  });

  testWidgets('a member is told what is wrong with what they paste, and nothing is kept', (tester) async {
    await build(tester);
    final good = await handed(tester, alice);
    late String forOwner;
    late String expired;
    await tester.runAsync(() async {
      final owner2 = deviceFor('owner-2');
      await owner.service.invite(orchardId, email: 'owner-2@example.com', role: FixedRoles.owner);
      server.acceptAs(orchardId, (await owner.service.invites(orchardId)).single.id, 'owner-2');
      await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
      await owner2.service.refresh();
      final ask = (await owner.service.handPassRequest(orchardId, crateId: production)).toText();
      forOwner = (await owner2.service.signPass(await owner2.service.reviewPassRequest(ask), hours: 8)).toText();
      expired = (await owner.service.signPass(await owner.service.reviewPassRequest(good.ask), hours: 8)).toText();
    });
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-pass-$production');
    Future<void> paste(String text, String says) async {
      await tester.enterText(key('pass-hand-answer'), text);
      await tester.pump();
      await tester.tap(find.text(l10n.certHandUse));
      await settle(tester);
      expect(tester.widget<Text>(key('pass-hand-problem')).data, noOrphan(says));
      expect(key('pass-hand-done'), findsNothing);
    }

    // Nothing entered: nothing happens.
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    expect(key('pass-hand-problem'), findsNothing);
    await paste('hello', l10n.certHandNotAnAnswer);
    await paste(good.ask, l10n.certHandIsRequest);
    await paste(forOwner, l10n.passTakeOtherAccount);
    // Nine hours on, the pass of eight hours has run out.
    now += 9 * 3600;
    await paste(expired, l10n.passTakeExpired);
    expect(await tester.runAsync(() async => heldPassIn(await alice.service.databases.open(orchardId), production)),
        isNull);
    // The one of a day is still good, and is kept.
    await tester.enterText(key('pass-hand-answer'), good.give);
    await tester.pump();
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    expect(key('pass-hand-done'), findsOneWidget);
    expect(key('pass-hand-problem'), findsNothing);
  });

  testWidgets('a device that can make no request says why, in words of its own', (tester) async {
    await build(tester);
    // Nowhere to keep a key of its own: a pass could not name the device.
    late _Device bare;
    await tester.runAsync(() async {
      bare = deviceFor('alice', withKey: false);
      await bare.service.refresh();
      await OrchardSyncCoordinator(service: bare.service, server: bare.service.server, databases: bare.service.databases)
          .syncAll();
    });
    await show(tester, bare, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-pass-$production');
    expect(tester.widget<Text>(key('pass-hand-cannot')).data, l10n.passAskNoDeviceKey);
    expect(key('pass-hand-code'), findsNothing);
    expect(find.text(l10n.certHandUse), findsNothing, reason: 'nothing to hand over, and nothing to take');
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);

    // The team went from the device while its page was open.
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    final shown =
        ProviderScope.containerOf(tester.element(key('crate-offline-pass-$production'))).read(orchardServiceProvider);
    await tester.runAsync(() => shown.databases.forget(orchardId));
    await tapKey(tester, 'crate-offline-pass-$production');
    expect(tester.widget<Text>(key('pass-hand-cannot')).data, l10n.passAskNoTeam);
    // Each has words of its own, in every language.
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect({for (final p in PassAskProblem.values) passAskMessage(t, p)}, hasLength(PassAskProblem.values.length),
          reason: '$locale');
    }
  });

  testWidgets('a pass for one Crate handed to a device whose Orchard is closed is kept for later, and said as that',
      (tester) async {
    await build(tester, orchardHours: 24);
    // (Her device keeps its Orchards in files here: one that its limit
    // closed is opened again with what it held, as on a device.)
    final folder = Directory.systemTemp.createTempSync('zest_pass_screen_');
    addTearDown(() {
      try {
        folder.deleteSync(recursive: true);
      } catch (_) {/* a file still held by the system: the folder is a temporary one */}
    });
    late _Device kit;
    await tester.runAsync(() async {
      kit = deviceFor('alice', folder: folder);
      await kit.service.refresh();
      await OrchardSyncCoordinator(service: kit.service, server: kit.service.server, databases: kit.service.databases)
          .syncAll();
    });
    // She asked for Production while the Orchard was open, and an owner
    // signed, for three days.
    final good = await handed(tester, kit, hours: 72);
    // A day and an hour away, all of the Orchard is closed on her device.
    // Its page says so, and offers the way on.
    now += 25 * 3600;
    await show(tester, kit, (_) => const TeamView(), closed: true);
    final shown = ProviderScope.containerOf(tester.element(key('team-closed-pass'))).read(orchardServiceProvider);
    await tester.runAsync(() => shown.databases.closeOffline(orchardId));
    await tapKey(tester, 'team-closed-pass');
    // What she has is the pass for Production: it goes in there.
    await tester.enterText(key('pass-hand-answer'), good.give);
    await tester.pump();
    await tester.tap(find.text(l10n.certHandUse));
    await settle(tester);
    final pass = HandedPass.fromText(good.give)!.pass;
    expect(tester.widget<Text>(key('pass-hand-done')).data,
        noOrphan(l10n.passAskDoneOrchardClosed('Production', accessTimeText(pass.until, l10n))),
        reason: 'the Crate by its name, though a closed Orchard lists none');
    expect(shown.databases.closedOffline, {orchardId}, reason: 'a pass for one Crate does not open the Orchard');
  });

  testWidgets('a pass asked for from a notice opens over whatever screen is up, each time it is asked',
      (tester) async {
    await build(tester);
    var screenUp = true;
    await show(
        tester,
        alice,
        (_) => Consumer(builder: (context, ref, _) {
              answerPassAskRequests(ref, () => screenUp ? context : null);
              return const Text('whatever is on screen');
            }));
    final app = ProviderScope.containerOf(tester.element(find.text('whatever is on screen')));
    void ask(String crateId) =>
        app.read(passAskRequestProvider.notifier).state = (orchardId: orchardId, crateId: crateId);
    String? asksFor() => HandedPassRequest.fromText(tester.widget<HandedCode>(key('pass-hand-code')).text)?.crateId;
    expect(key('pass-hand-code'), findsNothing, reason: 'nothing opens until something asks');

    ask(production);
    await settle(tester);
    expect(asksFor(), production);
    expect(app.read(passAskRequestProvider), isNull, reason: 'taken as it is answered');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    // The same asked again opens it again, and for all of an Orchard as asked.
    ask(production);
    await settle(tester);
    expect(asksFor(), production);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    ask(kAllOfOrchard);
    await settle(tester);
    expect(asksFor(), kAllOfOrchard);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    // With no screen to open it on, it is dropped, and not kept to open later.
    screenUp = false;
    ask(production);
    await settle(tester);
    expect(key('pass-hand-code'), findsNothing);
    expect(app.read(passAskRequestProvider), isNull);
    screenUp = true;
    await settle(tester);
    expect(key('pass-hand-code'), findsNothing);
    // The app's root is what answers (nothing shows the whole app in a
    // test, so this reads the file).
    expect(File('lib/app.dart').readAsStringSync(), contains('answerPassAskRequests(ref, () =>'));
  });

  testWidgets('who is offered what on a Crate, under the rule, and on a closed Orchard', (tester) async {
    await build(tester, orchardHours: 48);
    late String lab;
    await tester.runAsync(() async {
      lab = await owner.service.createCrate(orchardId, 'Lab');
      await owner.service.refresh();
    });
    // A Crate with a limit: a member may ask; an owner may ask and sign.
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-offline-pass-$production'), findsOneWidget);
    expect(key('crate-offline-sign-$production'), findsNothing);
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-offline-pass-$production'), findsOneWidget);
    expect(key('crate-offline-sign-$production'), findsOneWidget);
    // One without: neither.
    expect(key('crate-offline-pass-$lab'), findsNothing);
    expect(key('crate-offline-sign-$lab'), findsNothing);
    // Closed on the owner's own device: it asks, and signs nothing.
    now += 25 * 3600;
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-closed-$production'), findsOneWidget);
    expect(key('crate-offline-pass-$production'), findsOneWidget);
    expect(key('crate-offline-sign-$production'), findsNothing);
    owner.last = now;
    alice.last = now;

    // Under the Orchard's own rule.
    Widget rules(OrchardSummary o) =>
        SingleChildScrollView(padding: const EdgeInsets.all(16), child: OrchardRulesView(orchardId: o.id, onSaved: () {}));
    await show(tester, owner, rules);
    expect(key('rule-offline-pass'), findsOneWidget);
    expect(key('rule-offline-sign'), findsOneWidget);
    await show(tester, alice, rules);
    expect(key('rule-offline-pass'), findsOneWidget);
    // Someone suspended is told the limits and offered nothing: no owner's
    // device would sign for them.
    await tester.runAsync(() => owner.service.suspendMember(orchardId, 'alice'));
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-offline-note-$production'), findsOneWidget);
    expect(key('crate-offline-pass-$production'), findsNothing);
    await show(tester, alice, rules);
    expect(key('rule-offline-pass'), findsNothing);
    await tester.runAsync(() => owner.service.resumeMember(orchardId, 'alice'));
    await show(tester, alice, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    expect(key('crate-offline-pass-$production'), findsOneWidget);
    await tester.runAsync(() async {
      await owner.service.setRules(orchardId, RecordRules.none);
      await owner.service.refresh();
    });
    await show(tester, owner, rules);
    expect(key('rule-offline-pass'), findsNothing, reason: 'no limit, nothing to lift');
    expect(key('rule-offline-sign'), findsNothing);

    // A closed Orchard says so, and offers the way on: a pass for all of
    // it. On a computer and on a phone.
    await show(tester, alice, (_) => const TeamView(), closed: true);
    expect(key('team-closed-offline'), findsOneWidget);
    await tapKey(tester, 'team-closed-pass');
    expect(find.text(l10n.orchardNamed('Acme')), findsWidgets);
    expect(HandedPassRequest.fromText(tester.widget<HandedCode>(key('pass-hand-code')).text)!.crateId, kAllOfOrchard);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await show(tester, alice, (_) => const TeamPhoneScreen(), closed: true, size: const Size(390, 844));
    expect(key('team-phone-closed-offline'), findsOneWidget);
    await tapKey(tester, 'team-phone-closed-pass');
    expect(HandedPassRequest.fromText(tester.widget<HandedCode>(key('pass-hand-code')).text)!.crateId, kAllOfOrchard);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    // One of its pages, the same.
    await show(tester, alice, (_) => const TeamPhonePageScreen(page: TeamPage.members),
        closed: true, size: const Size(390, 844));
    expect(key('team-phone-closed-offline'), findsOneWidget);
    expect(key('team-phone-closed-pass'), findsOneWidget);
    // A page that is not this account's to see says that, and offers no
    // pass: nothing is closed.
    await show(tester, alice, (_) => const TeamPhonePageScreen(page: TeamPage.roles), size: const Size(390, 844));
    expect(find.text(l10n.teamPhoneNoOrchard), findsOneWidget);
    expect(key('team-phone-closed-offline'), findsNothing);
    expect(key('team-phone-closed-pass'), findsNothing);
  });

  testWidgets("the owner's screen reads whichever kind of request it is handed, each time afresh", (tester) async {
    await build(tester);
    // Production signs certificates, so alice's device can ask for one too.
    late String certAsk;
    final good = await handed(tester, alice);
    await tester.runAsync(() async {
      final vault = await owner.service.createCrate(orchardId, 'Owner keys', ownersOnly: true);
      await owner.service.setAuthorityKey(orchardId, production,
          keyCrate: vault,
          ttlMinutes: 60,
          principals: {
            server.recordOf(orchardId).roles.values.single.id: ['deploy'],
            FixedRoles.owner: ['root'],
          },
          keyLabel: 'Production certificate authority');
      await owner.service.refresh();
      await alice.service.refresh();
      certAsk = (await alice.service.handRequest(orchardId, production)).toText();
    });
    await show(tester, owner, crates);
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-sign-$production');
    Future<void> read(String text) async {
      await tester.enterText(key('cert-sign-request'), text);
      await tester.tap(find.text(l10n.certSignRead));
      await settle(tester);
    }

    // A request for a pass: three days are chosen, and then it is left.
    await read(good.ask);
    expect(key('pass-sign-who'), findsOneWidget);
    expect(key('cert-sign-who'), findsNothing);
    await tester.tap(key('pass-sign-lasts'));
    await settle(tester);
    await tester.tap(find.text(offlineSpanWords(l10n, 72)).last);
    await settle(tester);
    expect(tester.widget<ZestSelect<int>>(key('pass-sign-lasts')).value, 72);
    await tester.tap(find.text(l10n.back));
    await settle(tester);
    expect(key('pass-sign-who'), findsNothing);
    // A request for a certificate: read as that, with nothing of the pass.
    await read(certAsk);
    expect(key('cert-sign-who'), findsOneWidget);
    expect(key('pass-sign-who'), findsNothing);
    expect(key('pass-sign-lasts'), findsNothing);
    await tester.tap(find.text(l10n.back));
    await settle(tester);
    // The request for a pass again: a day unless they choose, as at first.
    await read(good.ask);
    expect(key('pass-sign-who'), findsOneWidget);
    expect(key('cert-sign-who'), findsNothing);
    expect(tester.widget<ZestSelect<int>>(key('pass-sign-lasts')).value, 24);
    await tester.tap(find.text(l10n.certSignConfirm));
    await settle(tester);
    final pass = HandedPass.fromText(tester.widget<HandedCode>(key('cert-sign-code')).text)!.pass;
    expect(pass.until - pass.madeAt, 24 * 3600);
  });

  test('every reason has words of its own', () {
    final asked = <String>{
      for (final p in HandedPassRequestProblem.values)
        if (p != HandedPassRequestProblem.refused) handedPassRequestMessage(l10n, HandedPassRequestRefused(p)),
      for (final r in PassRequestRefusal.values)
        handedPassRequestMessage(l10n, HandedPassRequestRefused(HandedPassRequestProblem.refused, refusal: r)),
    };
    expect(asked, hasLength(HandedPassRequestProblem.values.length - 1 + PassRequestRefusal.values.length));
    String ask(HandedPassRequestProblem p, [PassRequestRefusal? r]) =>
        handedPassRequestMessage(l10n, HandedPassRequestRefused(p, refusal: r));
    expect(ask(HandedPassRequestProblem.isAPass), l10n.passSignIsPass);
    expect(ask(HandedPassRequestProblem.notAnOwner), l10n.passSignNotOwner);
    expect(ask(HandedPassRequestProblem.closedHere), l10n.passSignClosedHere);
    expect(ask(HandedPassRequestProblem.ownDevice), l10n.passSignOwnDevice);
    expect(ask(HandedPassRequestProblem.notLetIn), l10n.certSignNotLetIn);
    expect(ask(HandedPassRequestProblem.otherOrchard), l10n.certSignOtherTeam);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.noSuchCrate), l10n.passSignNoCrate);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.noAccess), l10n.certSignNoAccess);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.notCurrentKeys), l10n.certSignOldKeys);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.notRecent), l10n.certSignTooOld);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.notSignedByMember), l10n.certSignBadSignature);
    expect(ask(HandedPassRequestProblem.refused, PassRequestRefusal.deviceNotApproved), l10n.certSignDeviceNotApproved);
    expect(ask(HandedPassRequestProblem.refused), l10n.certSignNotARequest, reason: 'refused, and nothing said of why');

    final given = <String>{
      for (final p in HandedPassProblem.values)
        if (p != HandedPassProblem.refused) handedPassMessage(l10n, HandedPassRefused(p)),
      for (final r in OfflinePassProblem.values)
        handedPassMessage(l10n, HandedPassRefused(HandedPassProblem.refused, refusal: r)),
    };
    expect(given, hasLength(HandedPassProblem.values.length - 1 + OfflinePassProblem.values.length));
    String take(HandedPassProblem p, [OfflinePassProblem? r]) => handedPassMessage(l10n, HandedPassRefused(p, refusal: r));
    expect(take(HandedPassProblem.notAPass), l10n.certHandNotAnAnswer);
    expect(take(HandedPassProblem.isARequest), l10n.certHandIsRequest);
    expect(take(HandedPassProblem.otherOrchard), l10n.passTakeOtherTeam);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.noSuchCrate), l10n.passTakeNoCrate);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.notForThisAccount), l10n.passTakeOtherAccount);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.notForThisDevice), l10n.passTakeOtherDevice);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.notAnOwner), l10n.passTakeNotOwner);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.notCurrentKeys), l10n.passTakeOldKeys);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.notSignedByOwner), l10n.passTakeBadSignature);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.expired), l10n.passTakeExpired);
    expect(take(HandedPassProblem.refused, OfflinePassProblem.tooLong), l10n.passTakeTooLong);
    expect(take(HandedPassProblem.refused), l10n.certHandNotAnAnswer, reason: 'refused, and nothing said of why');
    // Why no request could be made.
    expect(passAskMessage(l10n, PassAskProblem.otherOrchard), l10n.passAskNoTeam);
    expect(passAskMessage(l10n, PassAskProblem.noDeviceKey), l10n.passAskNoDeviceKey);
    // What a pass that was taken is for: all of the Orchard by its name,
    // a Crate by the name read with it, and one without a name as that.
    TakenPass taken(String crateId, [String? name]) =>
        TakenPass(orchardId: 'o', crateId: crateId, until: 1791590400, orchardClosed: false, crateName: name);
    expect(takenPassWhat(l10n, taken(kAllOfOrchard), orchard: 'Acme Orchard'), 'Acme Orchard');
    expect(takenPassWhat(l10n, taken('c', 'Lab'), orchard: 'Acme Orchard'), 'Lab');
    expect(takenPassWhat(l10n, taken('c'), orchard: 'Acme Orchard'), l10n.crateUnnamed);
    expect(takenPassWhat(l10n, taken('c', '  '), orchard: 'Acme Orchard'), l10n.crateUnnamed);
    // In every language each of them is there, and names what it is about.
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.passAskDone('Production', '9:00 PM'), allOf(contains('Production'), contains('9:00 PM')), reason: '$locale');
      expect(t.passAskDoneOrchardClosed('Production', '9:00 PM'), allOf(contains('Production'), contains('9:00 PM')),
          reason: '$locale');
      expect(t.passSignWho('alice@example.com', 'Production'), allOf(contains('alice@example.com'), contains('Production')),
          reason: '$locale');
      expect(t.passSignWhoAll('alice@example.com', 'Acme'), allOf(contains('alice@example.com'), contains('Acme')),
          reason: '$locale');
      expect(t.passSignWhoAll('a', 'b'), isNot(t.passSignWho('a', 'b')), reason: '$locale');
      expect(t.cratePassHolds('9:00 PM'), contains('9:00 PM'), reason: '$locale');
    }
  });

  test("a camera takes the other device's code and nothing else it sees", () {
    final ask = HandedPassRequest(
      orchardId: 'o',
      crateId: 'c',
      request: PassRequest(
          uid: 'u', keyVersion: 1, deviceKey: Uint8List(32), askedAt: 1791504000, signature: Uint8List(64)),
    ).toText();
    final give = HandedPass(
      orchardId: 'o',
      crateId: 'c',
      pass: OfflinePass(
          uid: 'u',
          deviceKey: Uint8List(32),
          until: 1791590400,
          madeAt: 1791504000,
          by: 'b',
          byKeyVersion: 1,
          signature: Uint8List(64)),
    ).toText();
    const certAsk = '${kHandedRequestPrefix}AAAA';
    // The owner's camera takes either kind of request, and no answer.
    const requests = {HandedKind.request, HandedKind.passRequest};
    expect(handedTextAmong([null, 'https://example.com', give, ask], requests), ask);
    expect(handedTextAmong([give], requests), isNull);
    expect(handedTextAmong([certAsk], requests), isNull, reason: 'half a code is none');
    // The member's takes the pass, and nothing else.
    expect(handedTextAmong([null, ask, give], const {HandedKind.pass}), give);
    expect(handedTextAmong([ask], const {HandedKind.pass}), isNull);
    expect(handedTextAmong([give], const {HandedKind.certificate}), isNull);
    expect(handedTextAmong(const [], const {HandedKind.pass}), isNull);
    expect(handedTextAmong([give], const <HandedKind>{}), isNull);
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
      await show(tester, alice, crates, locale: locale, theme: theme, size: phone);
      await openVaultTab(tester, production, VaultTab.offline);
      await tapKey(tester, 'crate-offline-pass-$production');
      expect(key('pass-hand-code'), findsOneWidget, reason: '$locale');
      expect(key('pass-hand-device'), findsOneWidget, reason: '$locale');
      final ask = tester.widget<HandedCode>(key('pass-hand-code')).text;
      await tester.enterText(key('pass-hand-answer'), ask);
      await tester.pump();
      await tester.ensureVisible(find.text(t.certHandUse));
      await tester.tap(find.text(t.certHandUse));
      await settle(tester);
      expect(tester.widget<Text>(key('pass-hand-problem')).data, noOrphan(t.certHandIsRequest), reason: '$locale');
      expect(tester.takeException(), isNull, reason: "$locale: the member's screen");

      // The owner's screen: a problem said, then the request read, then signed.
      await show(tester, owner, crates, locale: locale, theme: theme, size: phone);
      await openVaultTab(tester, production, VaultTab.offline);
      await tapKey(tester, 'crate-offline-sign-$production');
      await tester.enterText(key('cert-sign-request'), 'hello');
      await tester.tap(find.text(t.certSignRead));
      await settle(tester);
      expect(tester.widget<Text>(key('cert-sign-problem')).data, noOrphan(t.certSignNotARequest), reason: '$locale');
      expect(tester.takeException(), isNull, reason: "$locale: the owner's screen, a problem");
      await tester.enterText(key('cert-sign-request'), ask);
      await tester.tap(find.text(t.certSignRead));
      await settle(tester);
      expect(key('pass-sign-who'), findsOneWidget, reason: '$locale');
      expect(key('pass-sign-stale'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: "$locale: the owner's screen, the request read");
      await tester.ensureVisible(find.text(t.certSignConfirm));
      await tester.tap(find.text(t.certSignConfirm));
      await settle(tester);
      expect(key('cert-sign-code'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: "$locale: the owner's screen, signed");
      final give = tester.widget<HandedCode>(key('cert-sign-code')).text;
      final drawn = tester.getSize(find.descendant(of: key('cert-sign-code'), matching: find.byType(QrImageView)));
      expect(drawn.width, drawn.height, reason: '$locale: a code is square');

      // The member's screen, done.
      await show(tester, alice, crates, locale: locale, theme: theme, size: phone);
      await openVaultTab(tester, production, VaultTab.offline);
      await tapKey(tester, 'crate-offline-pass-$production');
      await tester.enterText(key('pass-hand-answer'), give);
      await tester.pump();
      await tester.ensureVisible(find.text(t.certHandUse));
      await tester.tap(find.text(t.certHandUse));
      await settle(tester);
      expect(key('pass-hand-done'), findsOneWidget, reason: '$locale');
      expect(tester.takeException(), isNull, reason: "$locale: the member's screen, done");
    }
  });

  // Last in this file: it loads the app's fonts, which every test after it
  // would measure with.
  testWidgets('the pass dialogs leave no word alone on a line: a request given back, and the pass taken',
      (tester) async {
    // ("back." under "gives you a different code" where the request itself
    // was given back as the answer, and "Cloud." under the pass taken: a
    // design review, at its pictures' size and time, a pass
    // until Nov 2 12:16 PM.)
    await tester.runAsync(loadShotFonts);
    now = DateTime(2026, 10, 31, 11, 16).millisecondsSinceEpoch ~/ 1000;
    await build(tester);
    final theme = BuiltInThemes.getById('default_light').toThemeData();
    // A day and an hour away: closed on alice's device, while the owner's
    // reached ZestSSH Cloud just now and signs.
    now += 25 * 3600;
    owner.last = now;
    final (:ask, :give) = await handed(tester, alice);
    await show(tester, alice, crates, theme: theme, size: const Size(1280, 900));
    await openVaultTab(tester, production, VaultTab.offline);
    await tapKey(tester, 'crate-offline-pass-$production');
    Future<void> use(String text) async {
      await tester.enterText(key('pass-hand-answer'), text);
      await tester.pump();
      await tester.ensureVisible(find.text(l10n.certHandUse));
      await tester.tap(find.text(l10n.certHandUse));
      await settle(tester);
    }

    await use(ask);
    expectNoOrphan(tester, key('pass-hand-problem'), reason: 'a request given back');
    await use(give);
    expectNoOrphan(tester, key('pass-hand-done'), reason: 'the pass taken');
    await tester.tap(find.text(l10n.done).last);
    await settle(tester);
    await tester.pumpWidget(const SizedBox());
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
