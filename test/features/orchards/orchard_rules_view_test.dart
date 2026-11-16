import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_crates.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_status_banner.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/utils/redactor.dart';

import 'fake_crate_server.dart';

/// An Orchard's rules on screen (3.0): owners set them on the Rules
/// screen, which checks first that the owner's own address stays allowed
/// and warns when this device would fall short; the server's refusals and
/// its request for a recent sign-in are shown; everyone else sees them
/// read-only. The banner names each rule this account or device falls short
/// of, with what to do about it. Whoever manages a Crate sets whether it
/// asks again before its secrets are shown.

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

  late _MemoryStorage storage;
  late FakeCrateServer server;
  late OrchardService service;
  late String orchardId;
  late String production;
  var lockOn = true;

  /// Whether the Orchard's company sign-in is on.
  var ssoOn = false;

  /// Whether this build is set up for the status service, which can prove
  /// an outage of ZestSSH Cloud's own to the app.
  var statusSet = false;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    storage = _MemoryStorage();
    lockOn = true;
    ssoOn = false;
    statusSet = false;
  });

  tearDown(() async {
    for (final db in storage.dbs.values) {
      await db.close();
    }
  });

  /// The owner's Orchard, Production its first Crate.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        server = FakeCrateServer(accountUid: 'owner-1');
        final keys = await AccountKeys.generate();
        await server.publish('owner-1', keys, email: 'owner-1@example.com');
        service = OrchardService(
          server: server,
          databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
          author: () async => CrateAuthor(uid: 'owner-1', keys: keys),
        );
        orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
        production = server.recordOf(orchardId).roles.values.single.crates.keys.single;
      });

  Future<OrchardSummary> read(WidgetTester tester) async {
    late OrchardSummary s;
    await tester.runAsync(() async => s = await readOrchardSummary(await service.databases.open(orchardId), orchardId));
    return s;
  }

  List<Override> overrides({OrchardSummary Function(OrchardSummary)? as}) => [
        orchardServiceProvider.overrideWithValue(service),
        orchardSummariesProvider.overrideWith((ref) async {
          ref.watch(orchardListVersionProvider);
          final s = await readOrchardSummary(await service.databases.open(orchardId), orchardId);
          return [as == null ? s : as(s)];
        }),
        deviceLockProvider.overrideWith((ref) async => (on: lockOn, minutes: 10)),
        orchardSsoProvider.overrideWith((ref, id) async => OrchardSso(kind: SsoKind.saml, active: ssoOn)),
        if (statusSet)
          cloudStatusConfigProvider.overrideWithValue(CloudStatusConfig(
            url: 'https://status.zestssh.com/v1/now',
            service: 'api.zestssh.com',
            keys: {'k1': List<int>.filled(32, 7)},
          )),
        currentUserProvider.overrideWithValue(const UserProfile(uid: 'owner-1', email: 'owner-1@example.com')),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ];

  /// Pumps a button that runs [open] and taps it.
  Future<void> openWith(WidgetTester tester, void Function(BuildContext, WidgetRef) open,
      {OrchardSummary Function(OrchardSummary)? as}) async {
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: overrides(as: as),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => Column(
              children: [
                TextButton(onPressed: () => open(context, ref), child: const Text('open')),
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
  }

  Finder inRule(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  Future<void> addDomain(WidgetTester tester, String domain) async {
    await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), domain);
    await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
    await tester.pump();
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.byKey(const ValueKey('rules-save')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rules-save')));
    await settle(tester);
  }

  testWidgets('an owner sets the rules: two-step sign-in and an address domain go into the record', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    expect(find.text(l10n.orchardRules), findsOneWidget);
    expect(find.byKey(const ValueKey('rules-save')), findsNothing, reason: 'nothing changed yet: no Save');

    await tester.tap(inRule('rule-two-step', find.byType(ZestSwitch)));
    await tester.pump();
    await addDomain(tester, 'nope');
    expect(find.text(l10n.orchardRulesDomainInvalid), findsOneWidget);
    await addDomain(tester, ' Example.COM ');
    expect(find.byKey(const ValueKey('rule-domain-example.com')), findsOneWidget, reason: 'kept in lower case');
    expect(find.text(l10n.orchardRulesDomainInvalid), findsNothing);

    await save(tester);
    final rules = server.recordOf(orchardId).rules;
    expect(rules.require2fa, isTrue);
    expect(rules.emailDomains, {'example.com'});
    expect(toasted(tester, l10n.orchardRulesSaved), isTrue);
    expect(find.text(l10n.orchardRulesSubtitle), findsNothing, reason: 'the screen closed');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sign in again: below a day is kept in hours, whole days in days (as apps from before hours read them)',
      (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    Future<void> pick(String words) async {
      await tester.tap(inRule('rule-reauth', find.byType(ZestSelect<int>)));
      await settle(tester);
      await tester.tap(find.text(words).last);
      await settle(tester);
    }

    await pick(l10n.orchardRulesReauthHours(8));
    await save(tester);
    var rules = server.recordOf(orchardId).rules;
    expect((rules.reauthDays, rules.reauthHours), (0, 8));
    expect(rules.toBody()['reauth_hours'], 8);
    await tester.pump(const Duration(seconds: 5));

    // Opened again it shows them; a week goes in as 7 days, and no hours.
    await tester.tap(find.text('open'));
    await settle(tester);
    expect(inRule('rule-reauth', find.text(l10n.orchardRulesReauthHours(8))), findsOneWidget);
    await pick(l10n.orchardRulesReauthDays(5));
    await save(tester);
    rules = server.recordOf(orchardId).rules;
    expect((rules.reauthDays, rules.reauthHours), (5, 0));
    expect(rules.toBody().containsKey('reauth_hours'), isFalse);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('sign in again: Custom takes a number of hours or days, within what the record takes', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-reauth', find.byType(ZestSelect<int>)));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesReauthCustom).last);
    await settle(tester);
    // Days where nothing was set; 400 days is more than the record takes, and is said so.
    await tester.enterText(find.byKey(const ValueKey('rule-reauth-custom-number')), '400');
    await tester.tap(find.text(l10n.save).last);
    await settle(tester);
    expect(find.text(l10n.orchardRulesReauthCustomInvalid), findsOneWidget);
    // 12 hours.
    await tester.tap(find.byKey(const ValueKey('rule-reauth-custom-unit')));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesReauthUnitHours).last);
    await settle(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-reauth-custom-number')), '12');
    await tester.tap(find.text(l10n.save).last);
    await settle(tester);
    expect(inRule('rule-reauth', find.text(l10n.orchardRulesReauthHours(12))), findsOneWidget);
    await save(tester);
    final rules = server.recordOf(orchardId).rules;
    expect((rules.reauthDays, rules.reauthHours), (0, 12));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('closing with unsaved rules asks: Save rules saves them and closes', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-two-step', find.byType(ZestSwitch)));
    await settle(tester);
    expect(inRule('rule-two-step', find.byKey(const ValueKey('rule-not-saved'))), findsOneWidget);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);
    expect(find.text(l10n.orchardRulesLeaveBody(1)), findsOneWidget);
    await tester.tap(find.text(l10n.orchardRulesSave).last);
    await settle(tester);
    expect(server.recordOf(orchardId).rules.require2fa, isTrue);
    expect(find.text(l10n.orchardRulesSubtitle), findsNothing, reason: 'saved and closed');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("an owner's own address must stay allowed: said before anything is sent", (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await addDomain(tester, 'corp.example');
    final sent = server.appends.length;
    await save(tester);
    expect(find.byKey(const ValueKey('rules-error')), findsOneWidget);
    expect(find.text(l10n.orchardRulesOwnDomain('example.com')), findsOneWidget);
    expect(server.appends.length, sent);
  });

  testWidgets('rules this device does not meet yet: a warning first, and saved only when asked to', (tester) async {
    await build(tester);
    lockOn = false;
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-app-lock', find.byType(ZestSwitch)));
    await tester.pump();
    final sent = server.appends.length;
    await save(tester);
    expect(find.text(l10n.orchardRulesThisDeviceTitle), findsOneWidget);
    expect(find.text(l10n.orchardRulesThisDeviceLock), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.appends.length, sent);

    await save(tester);
    await tester.tap(find.text(l10n.orchardRulesSaveAnyway));
    await settle(tester);
    expect(server.recordOf(orchardId).rules.requireAppLock, isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("the server's word: rules the owner does not meet, and a recent sign-in first", (tester) async {
    await build(tester);
    server.unmetBySender = (rules) => rules.require2fa ? ['two_step'] : const [];
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-two-step', find.byType(ZestSwitch)));
    await tester.pump();
    await save(tester);
    expect(find.text(l10n.orchardRulesUnmetByYou(l10n.orchardRuleNameTwoStep)), findsOneWidget);
    expect(server.recordOf(orchardId).rules.isNone, isTrue);

    server.unmetBySender = null;
    server.requireRecentSignIn = true;
    // The button spins while the prompt waits: frames, not settling.
    await tester.ensureVisible(find.byKey(const ValueKey('rules-save')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('rules-save')));
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.descendant(of: find.byKey(const ValueKey('step-up-summary')), matching: find.text(l10n.stepUpRules)),
        findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.recordOf(orchardId).rules.isNone, isTrue, reason: 'declined: nothing changed');
    expect(find.text(l10n.orchardRulesSubtitle), findsOneWidget, reason: 'the screen stays open');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a longest auto-lock time says members' apps also lock while idle", (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    expect(find.text(l10n.orchardRulesLockIdleNote), findsNothing, reason: 'no lock asked for');
    await tester.tap(inRule('rule-app-lock', find.byType(ZestSwitch)));
    await tester.pump();
    expect(find.text(l10n.orchardRulesLockIdleNote), findsNothing, reason: 'the lock, at any time');
    await tester.tap(find.byKey(const ValueKey('rule-lock-minutes')));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesLockMinutes(15)).last);
    await settle(tester);
    expect(find.text(l10n.orchardRulesLockIdleNote), findsOneWidget);
  });

  testWidgets('an offline limit says that the time ZestSSH Cloud itself is down does not count, where that is so',
      (tester) async {
    final note = l10n.orchardRulesOfflineOutageNote(7);
    expect(note, contains('7 days'));
    statusSet = true;
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    expect(find.text(note), findsNothing, reason: 'no limit is set');
    await tester.tap(inRule('rule-offline', find.byType(ZestSelect<int>)));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesOfflineDays(3)).last);
    await settle(tester);
    expect(inRule('rule-offline', find.text(note)), findsOneWidget);
    expect(find.text(l10n.orchardRulesOfflineOutageCounts(7)), findsNothing);
    // Back to no limit: nothing to say of what does not count towards it.
    await tester.tap(inRule('rule-offline', find.byType(ZestSelect<int>)));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesOfflineOff).last);
    await settle(tester);
    expect(find.text(note), findsNothing);
  });

  testWidgets('in a build that can have no outage proven to it, an offline limit promises nothing of the kind',
      (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-offline', find.byType(ZestSelect<int>)));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesOfflineDays(3)).last);
    await settle(tester);
    expect(find.text(l10n.orchardRulesOfflineOutageNote(7)), findsNothing);
    // It says what is so there: the outage counts, and a pass is the way on
    // (found in a review).
    expect(inRule('rule-offline', find.text(l10n.orchardRulesOfflineOutageCounts(7))), findsOneWidget);
    await tester.tap(inRule('rule-offline', find.byType(ZestSelect<int>)));
    await settle(tester);
    await tester.tap(find.text(l10n.orchardRulesOfflineOff).last);
    await settle(tester);
    expect(find.text(l10n.orchardRulesOfflineOutageCounts(7)), findsNothing, reason: 'no limit: nothing to say');
  });

  test('every language says how many days in a row, in its own words', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      expect(l.orchardRulesOfflineOutageNote(7), contains('7'), reason: '$locale');
      expect(l.orchardRulesOfflineOutageNote(7), contains('ZestSSH Cloud'), reason: '$locale');
      if (locale.languageCode != 'en') {
        expect(l.orchardRulesOfflineOutageNote(7), isNot(l10n.orchardRulesOfflineOutageNote(7)), reason: '$locale');
      }
    }
  });

  testWidgets('Sign in with SSO: an owner turns it on only once company sign-in is on', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    expect(tester.widget<ZestSwitch>(inRule('rule-sso', find.byType(ZestSwitch))).onChanged, isNull,
        reason: 'company sign-in is off');
    expect(find.byKey(const ValueKey('rule-sso-off')), findsOneWidget);
    expect(find.text(l10n.orchardRulesRequireSsoOff), findsOneWidget);
    await tester.tap(find.text(l10n.close).last);
    await settle(tester);

    ssoOn = true;
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    expect(find.byKey(const ValueKey('rule-sso-off')), findsNothing);
    expect(find.text(l10n.orchardRulesRequireSsoOwners), findsOneWidget,
        reason: 'why company sign-in can never lock the team out');
    await tester.tap(inRule('rule-sso', find.byType(ZestSwitch)));
    await tester.pump();
    await save(tester);
    expect(server.recordOf(orchardId).rules.requireSso, isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("the server's word on Sign in with SSO: the owner signs in through it first", (tester) async {
    await build(tester);
    ssoOn = true;
    server.unmetBySender = (rules) => rules.requireSso ? ['sso'] : const [];
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId));
    await tester.tap(inRule('rule-sso', find.byType(ZestSwitch)));
    await tester.pump();
    await save(tester);
    expect(find.text(l10n.orchardRulesSsoUnmetByYou), findsOneWidget);
    expect(server.recordOf(orchardId).rules.requireSso, isFalse);
  });

  testWidgets('everyone else sees the rules and cannot change them', (tester) async {
    await build(tester);
    await tester.runAsync(() => service.setRules(orchardId, const RecordRules(noExport: true, offlineHours: 72)));
    await tester.runAsync(service.refresh);
    await openWith(tester, (context, ref) => showOrchardRules(context, ref, orchardId),
        as: (s) => OrchardSummary(
            id: s.id, name: s.name, role: 'member-role', crates: s.crates, defaultCrateId: null, rules: s.rules));
    expect(find.text(l10n.orchardRulesOwnersOnly), findsOneWidget);
    expect(find.text(l10n.orchardRulesRequireSsoOwners), findsNothing, reason: 'said to owners');
    expect(find.byKey(const ValueKey('rules-save')), findsNothing);
    expect(tester.widget<ZestSwitch>(inRule('rule-no-export', find.byType(ZestSwitch))).value, isTrue);
    expect(tester.widget<ZestSwitch>(inRule('rule-no-export', find.byType(ZestSwitch))).onChanged, isNull);
    expect(find.byKey(const ValueKey('rule-domain-field')), findsNothing);
    expect(inRule('rule-offline', find.text(l10n.orchardRulesOfflineDays(3))), findsOneWidget);
  });

  testWidgets('whoever manages a Crate makes it ask again before its secrets are shown', (tester) async {
    await build(tester);
    await openWith(tester, (context, ref) => showOrchardCrates(context, ref, orchardId));
    final chip = find.byKey(ValueKey('crate-confirm-reveal-$production'));
    expect(tester.widget<ZestSwitch>(chip).value, isFalse);
    await tester.tap(chip);
    await settle(tester);
    expect(server.recordOf(orchardId).crates[production]!.confirmReveal, isTrue);
    expect(tester.widget<ZestSwitch>(chip).value, isTrue);
    await tester.pump(const Duration(seconds: 5));
  });

  group('the banner', () {
    Future<void> show(WidgetTester tester, OrchardSummary summary, {List<Override> extra = const []}) async {
      await tester.pumpWidget(ProviderScope(
        key: UniqueKey(),
        overrides: [
          ...overrides(),
          activeOrchardProvider.overrideWithValue(AsyncData(summary)),
          ...extra,
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Column(children: [
              const OrchardStatusBanner(),
              Consumer(builder: (context, ref, _) => Text(orchardSubtitle(summary, ref, l10n))),
              const Text('open'),
            ]),
          ),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    OrchardSummary held(String role, List<String> unmet, {List<String> domains = const []}) => OrchardSummary(
        id: 'o',
        name: 'Acme',
        role: role,
        crates: const [],
        defaultCrateId: null,
        status: 'rules',
        rulesUnmet: unmet,
        ruleDomains: domains);

    testWidgets('held back by the server: each rule with what to do, and owners can change the rules', (tester) async {
      await build(tester);
      await show(tester, held(FixedRoles.owner, ['two_step', 'email_domain', 'reauth'], domains: ['corp.example']));
      expect(find.text(l10n.orchardRulesBanner(l10n.orchardNamed('Acme'))), findsOneWidget);
      expect(find.byKey(const ValueKey('orchard-rule-twoStep')), findsOneWidget);
      expect(find.text(l10n.orchardRuleTwoStepFix), findsOneWidget);
      expect(find.text(l10n.orchardRuleOpenAccount), findsOneWidget);
      expect(find.text(l10n.orchardRuleEmailDomainFix('corp.example')), findsOneWidget);
      expect(find.text(l10n.orchardRuleReauthFix), findsOneWidget);
      expect(find.text(l10n.orchardRuleSignInAgain), findsNWidgets(2), reason: 'for two-step and for signing in');
      expect(find.byKey(const ValueKey('orchard-rules-change')), findsOneWidget);
      expect(find.text(l10n.orchardTeamRole(l10n.orchardRulesNotMet)), findsOneWidget);
    });

    testWidgets('held back by Sign in with SSO: the way to sign in through the company', (tester) async {
      await build(tester);
      await show(tester, held('member-role', ['sso']));
      expect(find.byKey(const ValueKey('orchard-rule-sso')), findsOneWidget);
      expect(find.text(l10n.orchardRuleSsoFix), findsOneWidget);
      expect(find.text(l10n.orchardRuleSignInWithSso), findsOneWidget);
    });

    testWidgets('a member held back has nothing to change; an address outside unknown domains still says so',
        (tester) async {
      await build(tester);
      await show(tester, held('member-role', ['email_domain']));
      expect(find.text(l10n.orchardRuleEmailDomainFixUnknown), findsOneWidget);
      expect(find.byKey(const ValueKey('orchard-rules-change')), findsNothing);
      expect(find.byType(TextButton), findsNothing, reason: 'nothing the member can do about it');
    });

    testWidgets("this device's own rules: the app lock and its timeout, with the way to the setting", (tester) async {
      await build(tester);
      const rules = RecordRules(requireAppLock: true, maxLockMinutes: 5);
      const active = OrchardSummary(
          id: 'o', name: 'Acme', role: 'member-role', crates: [], defaultCrateId: null, rules: rules);
      lockOn = false;
      await show(tester, active);
      expect(find.text(l10n.orchardRuleAppLockFix), findsOneWidget);
      expect(find.text(l10n.orchardRuleOpenLockSettings), findsOneWidget);

      lockOn = true; // at 10 minutes, over the 5 allowed
      await show(tester, active);
      expect(find.text(l10n.orchardRuleLockTimeoutFix(5)), findsOneWidget);

      await show(tester, const OrchardSummary(
          id: 'o', name: 'Acme', role: 'member-role', crates: [], defaultCrateId: null,
          rules: RecordRules(requireAppLock: true, maxLockMinutes: 15)));
      expect(find.byKey(const ValueKey('orchard-banner-rules')), findsNothing, reason: 'met: no banner');
    });

    testWidgets("an owner's Change the rules opens the Team page's Rules on desktop", (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await build(tester);
      final summary = await read(tester);
      await show(
          tester,
          OrchardSummary(
              id: summary.id, name: summary.name, role: FixedRoles.owner, crates: summary.crates,
              defaultCrateId: null, status: 'rules', rulesUnmet: const ['reauth']),
          extra: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      await tester.tap(find.byKey(const ValueKey('orchard-rules-change')));
      await settle(tester);
      final container = ProviderScope.containerOf(tester.element(find.text('open')));
      expect(container.read(activeSidebarNavProvider), NavSection.team);
      expect(container.read(teamPageProvider), TeamPage.rules);
      // No dialog on desktop: the page is the Rules screen.
      expect(find.text(l10n.orchardRulesSubtitle), findsNothing);
    });
  });
}

bool toasted(WidgetTester tester, String message) {
  if (find.text(message).evaluate().isNotEmpty) return true;
  final container = ProviderScope.containerOf(tester.element(find.text('open')));
  return container
      .read(notificationCenterProvider)
      .history
      .any((n) => n.title == message || n.body == message);
}

/// Lets the database and crypto work finish, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
