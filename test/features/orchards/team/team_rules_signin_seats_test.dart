import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull, Column;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/billing/orchard_billing.dart';
import 'package:zestssh/features/orchards/crypto/join_code_crypto.dart' show JoinOffer, JoinOfferVault;
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/directory/orchard_directory_api.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart'
    show CrateLevel, MemberStatus, RecordRules, RecordTypes, RoleCan, levelSwitches;
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardChangeErrorMessage;
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show rulesOn, rulesOnNames;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_seats.dart';
import 'package:zestssh/features/orchards/team/team_view.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show endOfDay;
import 'package:zestssh/features/orchards/widgets/orchard_directory_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_rules_view.dart'
    show orchardRulesDraftProvider, orchardRulesTypedDomainProvider;
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart' show signInRefresherProvider;
import 'package:zestssh/features/orchards/widgets/outside_domains.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/profile_providers.dart' show refreshPersonState;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart' show passkeyStepUpProvider;
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/redactor.dart';

import '../fake_crate_server.dart';

/// A team's Rules, Sign-in and Seats pages as designed,
/// on a real team record: the rules in two groups
/// by who checks them, a rule that cannot be turned on yet locked with the
/// way to what unlocks it; the Sign-in page as steps, each locked until
/// what it needs is there (a proven domain, Business) and saying which;
/// the Seats page's bar counting members, people invited and open seats,
/// who holds them with what can be done about each, and the prices ZestSSH
/// Cloud gives (the words only; the server asks Stripe for them).

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

/// ZestSSH Cloud's domain, company sign-in, directory and billing routes for
/// the one team.
class _Cloud {
  bool proven = false;
  String business = 'off';

  /// Company sign-in set up, tested and on.
  bool ssoOn = false;

  /// The prices it sends; none, as a server from before them.
  Map<String, Object?>? prices = const {'seat_cents': 10000, 'services_month_cents': 2000, 'services_year_cents': 20000};

  http.Response json(Object body) =>
      http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  Future<http.Response> answer(http.Request request) async {
    final path = request.url.path;
    final now = DateTime.now().toUtc();
    if (path.contains('/domains')) {
      return json({
        'domains': [
          {
            'domain': 'example.dev',
            'verified': proven,
            if (proven) 'verified_at': now.toIso8601String(),
            'checked_at': now.subtract(const Duration(minutes: 2)).toIso8601String(),
            'txt': 'zestssh-verify=0123456789abcdef',
          },
        ],
      });
    }
    if (path.contains('/sso')) {
      return json({
        'kind': ssoOn ? 'saml' : null,
        'active': ssoOn,
        if (ssoOn) 'display_name': 'Example SSO',
        'service': {
          'saml': {'acs_url': 'https://auth.test/__/auth/handler', 'entity_id': 'urn:zestssh:orchard:0123'},
          'oidc': {'redirect_uri': 'https://auth.test/__/auth/handler'},
        },
        'domains': [if (proven) 'example.dev'],
      });
    }
    if (path.contains('/directory')) {
      return json({'enabled': false, 'groups': [], 'pending': [], 'held': []});
    }
    if (path.contains('/billing')) {
      return json({
        'seats': {'bought': 4, 'included': 1, 'total': 5, 'used': 4, 'free': 1, 'over': false},
        'business_services': {
          'state': business,
          if (business == 'active') ...{
            'interval': 'year',
            'quantity': 5,
            'paid_through': '2027-01-15T12:00:00.000Z',
            'works_until': '2027-01-29T12:00:00.000Z',
          },
        },
        'prices': ?prices,
      });
    }
    return http.Response(jsonEncode({'code': 'not-found'}), 404);
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  late FakeCrateServer server;
  late OrchardService service;
  late OrchardDatabasesNotifier databases;
  late _MemoryStorage storage;
  late String orchardId;
  late _Cloud cloud;
  late List<Uri> opened;
  late AccountKeys samKeys;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
      if (i >= 4 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 300));
  }

  /// Acme: the owner (this device), jordan (a member), sam who accepted an
  /// invitation, and priya invited.
  Future<void> setUpTeam(WidgetTester tester, {String jordanEmail = 'jordan@example.com'}) async {
    FlutterSecureStorage.setMockInitialValues({});
    server = FakeCrateServer(accountUid: 'owner-1');
    storage = _MemoryStorage();
    cloud = _Cloud();
    opened = [];
    await tester.runAsync(() async {
      final ownerKeys = await AccountKeys.generate();
      final jordanKeys = await AccountKeys.generate();
      samKeys = await AccountKeys.generate();
      await server.publish('owner-1', ownerKeys, email: 'owner@example.com');
      await server.publish('uid-jordan', jordanKeys, email: jordanEmail);
      await server.publish('uid-sam', samKeys, email: 'sam@example.com');
      databases = OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
      service = OrchardService(
        server: server.as('owner-1', device: 'laptop'),
        databases: databases,
        author: () async => CrateAuthor(uid: 'owner-1', keys: ownerKeys),
        deviceKeys: DeviceIdentityStore(_Keychain()),
      );
      orchardId = await service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
      final member = server.recordOf(orchardId).roles.values.single;
      await service.invite(orchardId, email: jordanEmail, role: member.id);
      server.acceptAs(orchardId, (await service.invites(orchardId)).single.id, 'uid-jordan');
      await service.confirmInvite(orchardId, (await service.invites(orchardId)).single);
      await service.invite(orchardId, email: 'sam@example.com', role: member.id);
      server.acceptAs(orchardId, (await service.invites(orchardId)).single.id, 'uid-sam');
      await service.invite(orchardId, email: 'priya@example.com', role: member.id);
      await service.refresh();
    });
    addTearDown(() async {
      for (final db in storage.dbs.values) {
        try {
          await db.close();
        } catch (_) {}
      }
    });
  }

  Future<ProviderContainer> show(WidgetTester tester, TeamPage page) async {
    tester.view.physicalSize = const Size(1440, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<OrchardSummary> read() async => readOrchardSummary(await databases.open(orchardId), orchardId);
    final client = MockClient(cloud.answer);
    Future<String?> bearer() async => 'token';
    const base = 'https://api.test/v1';
    final container = ProviderContainer(overrides: [
      orchardServiceProvider.overrideWithValue(service),
      // A notifier of its own over the same databases: each page's scope
      // disposes the one it was given.
      orchardDatabasesProvider.overrideWith(
          (ref) => OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage)),
      orchardSummariesProvider.overrideWith((ref) async {
        ref.watch(orchardListVersionProvider);
        return [await read()];
      }),
      activeOrchardProvider.overrideWith((ref) => ref.watch(orchardSummariesProvider).whenData((list) => list.firstOrNull)),
      connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
      deviceLockProvider.overrideWith((ref) async => (on: true, minutes: 5)),
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'owner-1', email: 'owner@example.com')),
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      billingOnThisDeviceProvider.overrideWithValue(true),
      seatsPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
      passkeyStepUpProvider.overrideWithValue(null),
      signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
        server.requireRecentSignIn = false;
        return true;
      }),
      orchardDomainsApiProvider.overrideWithValue(OrchardDomainsApi(client: client, baseUrl: base, bearer: bearer)),
      orchardSsoApiProvider.overrideWithValue(OrchardSsoApi(client: client, baseUrl: base, bearer: bearer)),
      orchardDirectoryApiProvider.overrideWithValue(OrchardDirectoryApi(client: client, baseUrl: base, bearer: bearer)),
      orchardBillingApiProvider.overrideWithValue(OrchardBillingApi(client: client, baseUrl: base, bearer: bearer)),
    ]);
    addTearDown(container.dispose);
    container.read(activeSidebarNavProvider.notifier).state = NavSection.team;
    container.read(teamPageProvider.notifier).state = page;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: TeamView()),
      ),
    ));
    await settle(tester);
    return container;
  }

  Finder inKey(String key, Finder f) => find.descendant(of: find.byKey(ValueKey(key)), matching: f);

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
  }

  group('Rules', () {
    testWidgets('in two groups, each saying who checks it', (tester) async {
      await setUpTeam(tester);
      await show(tester, TeamPage.rules);
      for (final k in ['rule-two-step', 'rule-sso', 'rule-domains', 'rule-reauth']) {
        expect(inKey('rules-signing-in', find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      for (final k in ['rule-devices', 'rule-app-lock', 'rule-no-export', 'rule-offline']) {
        expect(inKey('rules-on-devices', find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      expect(inKey('rules-signing-in', find.text(l10n.orchardRulesCheckedByCloud)), findsOneWidget);
      expect(inKey('rules-on-devices', find.text(l10n.orchardRulesCheckedByDevice)), findsOneWidget);
      // And a third, for the team's remote screens (4.0), which each device checks too.
      for (final k in ['rule-screens-ssh-only', 'rule-screens-no-sharing']) {
        expect(inKey('rules-remote-screens', find.byKey(ValueKey(k))), findsOneWidget, reason: k);
      }
      expect(inKey('rules-remote-screens', find.text(l10n.settingsScreensSection)), findsOneWidget);
      expect(inKey('rules-remote-screens', find.text(l10n.orchardRulesCheckedByDevice)), findsOneWidget);
      await done(tester);
    });

    testWidgets('the two rules for remote screens: off to start with, each says what it does, switched on they say '
        'when they take hold and are marked not saved, and Save writes both into the record; one turned off again '
        'leaves the other on', (tester) async {
      await setUpTeam(tester);
      await show(tester, TeamPage.rules);
      Finder switchOf(String rule) => inKey(rule, find.byType(ZestSwitch));
      for (final rule in ['rule-screens-ssh-only', 'rule-screens-no-sharing']) {
        await tester.ensureVisible(switchOf(rule));
        await settle(tester);
        expect(tester.widget<ZestSwitch>(switchOf(rule)).value, isFalse, reason: rule);
      }
      expect(inKey('rule-screens-ssh-only', find.text(l10n.orchardRulesScreensSshOnly)), findsOneWidget);
      expect(inKey('rule-screens-ssh-only', find.text(l10n.orchardRulesScreensSshOnlyBody)), findsOneWidget);
      expect(inKey('rule-screens-no-sharing', find.text(l10n.orchardRulesScreensNoSharing)), findsOneWidget);
      expect(inKey('rule-screens-no-sharing', find.text(l10n.orchardRulesScreensNoSharingBody)), findsOneWidget);
      expect(find.text(l10n.orchardRulesScreensFromNextOpen), findsNothing);

      await tester.tap(switchOf('rule-screens-ssh-only'));
      await settle(tester);
      await tester.ensureVisible(switchOf('rule-screens-no-sharing'));
      await settle(tester);
      await tester.tap(switchOf('rule-screens-no-sharing'));
      await settle(tester);
      expect(find.text(l10n.orchardRulesScreensFromNextOpen), findsNWidgets(2));
      expect(inKey('rule-screens-ssh-only', find.byKey(const ValueKey('rule-not-saved'))), findsOneWidget);
      expect(inKey('rule-screens-no-sharing', find.byKey(const ValueKey('rule-not-saved'))), findsOneWidget);
      expect(inKey('rules-unsaved-bar', find.text(l10n.orchardRulesUnsaved(2))), findsOneWidget);
      expect(server.recordOf(orchardId).rules.isNone, isTrue, reason: 'nothing is written before Save');

      await tester.tap(find.byKey(const ValueKey('rules-save')));
      await settle(tester);
      final saved = server.recordOf(orchardId).rules;
      expect((saved.screensSshOnly, saved.screensLockRedirections), (true, true));
      expect(find.byKey(const ValueKey('rules-unsaved-bar')), findsNothing);
      expect(rulesOn(saved), 2);
      expect(rulesOnNames(saved, l10n), [l10n.orchardRulesScreensSshOnly, l10n.orchardRulesScreensNoSharing]);

      // One off again: said by name in the record, and the other stays.
      await tester.ensureVisible(switchOf('rule-screens-ssh-only'));
      await settle(tester);
      await tester.tap(switchOf('rule-screens-ssh-only'));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('rules-save')));
      await settle(tester);
      final after = server.recordOf(orchardId).rules;
      expect((after.screensSshOnly, after.screensLockRedirections), (false, true));
      await done(tester);
    });

    testWidgets('company sign-in required: locked, with the way to Sign-in, until company sign-in is on',
        (tester) async {
      await setUpTeam(tester);
      final container = await show(tester, TeamPage.rules);
      expect(tester.widget<ZestSwitch>(inKey('rule-sso', find.byType(ZestSwitch))).onChanged, isNull);
      // A lock beside the switch, and one before the words.
      expect(inKey('rule-sso', find.byIcon(LucideIcons.lock)), findsNWidgets(2));
      expect(inKey('rule-sso-off', find.text(l10n.orchardRulesRequireSsoOff)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rule-sso-open-sign-in')));
      await settle(tester);
      expect(container.read(teamPageProvider), TeamPage.signIn);

      // Company sign-in on: no lock, and the switch moves.
      cloud.ssoOn = true;
      cloud.proven = true;
      await show(tester, TeamPage.rules);
      expect(find.byKey(const ValueKey('rule-sso-off')), findsNothing);
      expect(inKey('rule-sso', find.byIcon(LucideIcons.lock)), findsNothing);
      expect(tester.widget<ZestSwitch>(inKey('rule-sso', find.byType(ZestSwitch))).onChanged, isNotNull);
      await done(tester);
    });

    testWidgets('approved devices only: locked until this device is approved, which it does from there',
        (tester) async {
      await setUpTeam(tester);
      await show(tester, TeamPage.rules);
      expect(tester.widget<ZestSwitch>(find.byKey(const ValueKey('rule-devices-switch'))).onChanged, isNull);
      expect(inKey('rule-devices', find.byIcon(LucideIcons.lock)), findsNWidgets(2));
      expect(inKey('rule-devices-needs', find.text(l10n.orchardRulesDevicesNeedThis)), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('rule-devices-action')));
      await settle(tester);
      // This device approved, one more of an owner's is needed: still locked,
      // and it says so, with nothing to press here.
      expect(inKey('rule-devices-needs', find.text(l10n.orchardRulesDevicesNeedSecond)), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-devices-action')), findsNothing);
      expect(tester.widget<ZestSwitch>(find.byKey(const ValueKey('rule-devices-switch'))).onChanged, isNull);
      await done(tester);
    });

    /// Acme with jordan outside the domain the rules are about to name: the
    /// Rules page, example.com added, Save rules pressed.
    Future<ProviderContainer> toOutside(WidgetTester tester) async {
      await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
      final container = await show(tester, TeamPage.rules);
      await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
      await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('rules-save')));
      await settle(tester);
      return container;
    }

    testWidgets('address domains that leave members out: who, and what happens to them, before saving; '
        'left as they are, saved, the Members list marks them', (tester) async {
      final container = await toOutside(tester);
      expect(find.text(l10n.orchardOutsideTitle(1, 'example.com')), findsOneWidget);
      expect(find.text('jordan@partner.test'), findsOneWidget);
      expect(find.text(l10n.orchardRulesOutsideBody), findsOneWidget);
      // Back out: nothing sent, the change still there to rethink.
      await tester.tap(find.byKey(const ValueKey('outside-back')));
      await settle(tester);
      expect(server.recordOf(orchardId).rules.emailDomains, isEmpty);
      expect(find.byKey(const ValueKey('rules-unsaved-bar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('rules-save')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      expect(server.recordOf(orchardId).rules.emailDomains, {'example.com'});
      container.read(teamPageProvider.notifier).state = TeamPage.members;
      await settle(tester);
      expect(find.text(l10n.orchardMemberOutsideDomains), findsWidgets);
      // And Members says who, with what is to become of them, to an owner.
      expect(find.byKey(const ValueKey('members-outside')), findsOneWidget);
      expect(find.text(l10n.orchardOutsideTitle(1, 'example.com')), findsOneWidget);
      await done(tester);
    });

    testWidgets('Do not change the domains: nothing is sent, and other changes stay to save', (tester) async {
      await toOutside(tester);
      await tester.tap(find.byKey(const ValueKey('outside-no-change')));
      await settle(tester);
      expect(server.recordOf(orchardId).rules.emailDomains, isEmpty);
      expect(find.byKey(const ValueKey('rule-domain-example.com')), findsNothing, reason: 'the list is as it was');
      expect(find.byKey(const ValueKey('outside-domains')), findsNothing);
      await done(tester);
    });

    testWidgets('keep as a guest: the rules and an end date in one step, and Members marks a guest, not one held back', (tester) async {
      final container = await toOutside(tester);
      final seq = server.recordOf(orchardId).seq;
      await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.guest}')).last);
      await settle(tester);
      // The date is said, thirty days on unless changed.
      final until = endOfDay(DateTime.now().add(const Duration(days: 30)));
      expect(find.byKey(const ValueKey('outside-until')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      final record = server.recordOf(orchardId);
      expect(record.rules.emailDomains, {'example.com'});
      expect(record.members['uid-jordan']!.endsAt, until);
      expect(record.seq, seq + 2, reason: 'the rules, then the end date');
      container.read(teamPageProvider.notifier).state = TeamPage.members;
      await settle(tester);
      expect(find.byKey(const ValueKey('members-outside')), findsNothing);
      expect(find.text(l10n.orchardMemberOutsideDomains), findsNothing);
      expect(find.textContaining(l10n.orchardMemberGuest), findsWidgets);
      await done(tester);
    });

    testWidgets('remove: asked first, then gone with the rules in one step', (tester) async {
      await toOutside(tester);
      await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.remove}')).last);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      expect(find.text(l10n.orchardOutsideRemoveTitle(1)), findsOneWidget);
      // Not yet: still choosing.
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(server.recordOf(orchardId).members['uid-jordan']!.status, MemberStatus.active);
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      await tester.tap(find.text(l10n.orchardRemoveConfirm).last);
      await settle(tester);
      final record = server.recordOf(orchardId);
      expect(record.rules.emailDomains, {'example.com'});
      expect(record.members['uid-jordan']!.status, MemberStatus.removed);
      await done(tester);
    });

    testWidgets('from Members, for a list that stands: Review keeps them as guests, through a recent sign-in', (tester) async {
      await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
      await tester.runAsync(() => service.setRules(orchardId, const RecordRules(emailDomains: {'example.com'})));
      await show(tester, TeamPage.members);
      await settle(tester);
      expect(find.byKey(const ValueKey('members-outside')), findsOneWidget);
      expect(find.text(l10n.orchardMemberOutsideDomains), findsWidgets);
      await tester.tap(find.byKey(const ValueKey('members-outside-review')));
      await settle(tester);
      expect(find.text('jordan@partner.test'), findsWidgets);
      // Nothing chosen, nothing to apply.
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      expect(find.byKey(const ValueKey('outside-domains')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
      await settle(tester);
      await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.guest}')).last);
      await settle(tester);
      server.requireRecentSignIn = true;
      await tester.tap(find.byKey(const ValueKey('outside-go')));
      await settle(tester);
      // The server wants a recent sign-in: what it is about is said first.
      expect(find.text(l10n.stepUpOutside), findsOneWidget);
      expect(find.textContaining(l10n.orchardOutsideEffectGuests(1, '').split(' until').first), findsWidgets);
      await tester.tap(find.text(l10n.devicesSignInAgainTitle).last);
      await settle(tester);
      expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt, isNotNull);
      expect(find.byKey(const ValueKey('members-outside')), findsNothing);
      await done(tester);
    });

    test('what an owner decided goes the rules first, then the members, in steps the server takes: '
        'someone briefly held back can be let in again, and someone removed cannot', () {
      final steps = outsideDomainSteps(
        rules: const RecordRules(emailDomains: {'example.com'}),
        guests: {for (var i = 0; i < 70; i++) 'guest-$i': 2000000000},
        clear: {'clear-0'},
        remove: {for (var i = 0; i < 59; i++) 'gone-$i'},
      );
      // The server takes 64 entries to a step (MAX_APPEND).
      expect([for (final s in steps) s.length], [60, 60, 11]);
      final all = steps.expand((s) => s).toList();
      expect(all.first.type, RecordTypes.rulesSet);
      expect(all.where((c) => c.type == RecordTypes.rulesSet), hasLength(1));
      expect(all.skip(1).take(71).map((c) => c.type).toSet(), {RecordTypes.memberSet});
      expect(all.skip(72).map((c) => c.type).toSet(), {RecordTypes.memberRemove});
      expect(all[1].body, {'uid': 'guest-0', 'ends_at': 2000000000});
      expect(all[71].body, {'uid': 'clear-0', 'ends_at': 0}, reason: 'as the record says none');
      expect(outsideDomainSteps(), isEmpty, reason: 'nothing decided, nothing sent');
    });

    group('an owner held back by the rules in force', () {
      test('the rules go in a step of their own, and the rest after', () {
        final steps = outsideDomainSteps(
          rules: const RecordRules(emailDomains: {'example.com'}),
          guests: {'guest-0': 2000000000},
          remove: {'gone-0'},
          rulesAlone: true,
        );
        expect([for (final s in steps) [for (final c in s) c.type]], [
          [RecordTypes.rulesSet],
          [RecordTypes.memberSet, RecordTypes.memberRemove],
        ]);
        // With nothing else to send, one step, as with no rules.
        expect(outsideDomainSteps(rules: const RecordRules(), rulesAlone: true), hasLength(1));
        expect(outsideDomainSteps(guests: {'guest-0': 2000000000}, rulesAlone: true), hasLength(1));
      });

      testWidgets('saved with decisions: the server takes the rules, they let this account in, and the decisions follow', (tester) async {
        await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
        server.held['owner-1'] = ['two_step'];
        // The rule that held them is what the rules take off.
        server.unmetBySender = (rules) {
          server.held.clear();
          return const [];
        };
        final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        await tester.runAsync(() async {
          await service.refresh();
          await service.settleOutsideDomains(orchardId,
              rules: const RecordRules(emailDomains: {'example.com'}), guests: {'uid-jordan': until});
        });
        expect(server.appends.reversed.take(2).toList().reversed, [
          [RecordTypes.rulesSet],
          [RecordTypes.memberSet],
        ]);
        expect(server.recordOf(orchardId).rules.emailDomains, {'example.com'});
        expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt, until);
      });

      testWidgets('not held back: all in one step', (tester) async {
        await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
        final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
        await tester.runAsync(() async {
          await service.refresh();
          await service.settleOutsideDomains(orchardId,
              rules: const RecordRules(emailDomains: {'example.com'}), guests: {'uid-jordan': until});
        });
        expect(server.appends.last, [RecordTypes.rulesSet, RecordTypes.memberSet]);
      });
    });

    group('someone outside the domains who has an end date', () {
      /// Acme with jordan outside the domain the rules are about to name, and
      /// the date [until] an owner gave them; the Rules page, Save rules pressed.
      Future<ProviderContainer> toDated(WidgetTester tester, int until) async {
        await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
        await tester.runAsync(() => service.setMemberEndsAt(orchardId, 'uid-jordan', until));
        final container = await show(tester, TeamPage.rules);
        await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
        await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('rules-save')));
        await settle(tester);
        return container;
      }

      late int until;
      setUp(() => until = endOfDay(DateTime.now().add(const Duration(days: 40))));

      testWidgets('alone: the dialog opens all the same, and names them and when they end, and what that means', (tester) async {
        await toDated(tester, until);
        expect(find.byKey(const ValueKey('outside-domains')), findsOneWidget);
        expect(find.text(l10n.orchardOutsideTitle(1, 'example.com')), findsOneWidget);
        expect(find.text('jordan@partner.test'), findsOneWidget);
        expect(find.byKey(const ValueKey('outside-ends-uid-jordan')), findsOneWidget);
        expect(find.text(l10n.orchardOutsideGuestsBody), findsOneWidget);
        expect(find.byKey(const ValueKey('outside-happens')), findsNothing, reason: 'nobody is held back');
        expect(find.byKey(const ValueKey('outside-guest-note')), findsOneWidget);
        await done(tester);
      });

      testWidgets('kept: the rules go in, and nothing more is signed for a date an owner gave', (tester) async {
        await toDated(tester, until);
        final before = server.entriesOf(orchardId).length;
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        expect([for (final e in server.entriesOf(orchardId).skip(before)) e.type], [RecordTypes.rulesSet]);
        expect(server.recordOf(orchardId).rules.emailDomains, {'example.com'});
        expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt, until);
        await done(tester);
      });

      testWidgets('another date: the picker, then that date goes in with the rules', (tester) async {
        await toDated(tester, until);
        await tester.tap(find.byKey(const ValueKey('outside-date-uid-jordan')));
        await settle(tester);
        // The day may turn while it runs: the end of either day is right (it
        // failed at midnight).
        final before = DateTime.now();
        await tester.tap(find.byKey(const ValueKey('end-quick-week')));
        await settle(tester);
        await tester.tap(find.text(l10n.save).last);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt,
            anyOf(endOfDay(before.add(const Duration(days: 7))), endOfDay(DateTime.now().add(const Duration(days: 7)))));
        expect(server.recordOf(orchardId).rules.emailDomains, {'example.com'});
        await done(tester);
      });

      testWidgets('left held back: the date goes, and Members marks them', (tester) async {
        final container = await toDated(tester, until);
        await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.hold}')).last);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        final record = server.recordOf(orchardId);
        expect(record.members['uid-jordan']!.endsAt, isNull);
        expect(record.rules.emailDomains, {'example.com'});
        container.read(teamPageProvider.notifier).state = TeamPage.members;
        await settle(tester);
        expect(find.byKey(const ValueKey('members-outside')), findsOneWidget);
        expect(find.text(l10n.orchardMemberOutsideDomains), findsWidgets);
        await done(tester);
      });

      testWidgets('removed: the question says who, and they go', (tester) async {
        await toDated(tester, until);
        await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.remove}')).last);
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        expect(find.text('jordan@partner.test. ${l10n.orchardRemoveBody}'), findsOneWidget);
        await tester.tap(find.text(l10n.orchardRemoveConfirm).last);
        await settle(tester);
        expect(server.recordOf(orchardId).members['uid-jordan']!.status, MemberStatus.removed);
        await done(tester);
      });
    });

    group('an end date no owner gave', () {
      /// Sam, whose role changes members, gives jordan (outside example.com) an
      /// end date; then the owner saves the domains. No dialog is in between.
      Future<int> samDatesJordan(WidgetTester tester) async {
        await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
        final until = endOfDay(DateTime.now().add(const Duration(days: 40)));
        await tester.runAsync(() async {
          final member = server.recordOf(orchardId).roles.values.single.id;
          final lead = await service.saveRole(orchardId, name: 'Lead', can: {RoleCan.changeRoles}, crates: {});
          await service.orderRoles(orchardId, [lead, member]);
          await service.confirmInvite(orchardId, (await service.invites(orchardId)).singleWhere((i) => i.email == 'sam@example.com'));
          await service.setMemberRole(orchardId, 'uid-sam', lead);
          final sam = OrchardService(
            server: server.as('uid-sam', device: 'phone'),
            databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: _MemoryStorage()),
            author: () async => CrateAuthor(uid: 'uid-sam', keys: samKeys),
            deviceKeys: DeviceIdentityStore(_Keychain()),
          );
          await sam.refresh();
          await sam.setMemberEndsAt(orchardId, 'uid-jordan', until);
          await service.setRules(orchardId, const RecordRules(emailDomains: {'example.com'}));
          await service.refresh();
        });
        return until;
      }

      testWidgets('Members says who, and what it does; kept as it is, the same date is an owner\'s, and nothing more is asked', (tester) async {
        final until = await samDatesJordan(tester);
        await show(tester, TeamPage.members);
        await settle(tester);
        expect(find.byKey(const ValueKey('members-outside')), findsOneWidget);
        expect(find.text(l10n.orchardOutsideTitle(1, 'example.com')), findsOneWidget);
        expect(find.textContaining(l10n.orchardOutsideUnseenBody), findsOneWidget);
        expect(find.textContaining('jordan@partner.test.'), findsOneWidget);
        expect(find.textContaining(l10n.orchardRulesOutsideBody), findsNothing, reason: 'nobody is held back');
        await tester.tap(find.byKey(const ValueKey('members-outside-review')));
        await settle(tester);
        expect(find.byKey(const ValueKey('outside-ends-uid-jordan')), findsOneWidget);
        final before = server.entriesOf(orchardId).length;
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        final entries = server.entriesOf(orchardId).skip(before).toList();
        expect([for (final e in entries) e.type], [RecordTypes.memberSet]);
        expect(entries.single.body, {'uid': 'uid-jordan', 'ends_at': until});
        expect(find.byKey(const ValueKey('members-outside')), findsNothing);
        await done(tester);
      });

      testWidgets('a date an owner gave is not asked about again', (tester) async {
        await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
        await tester.runAsync(() async {
          await service.setMemberEndsAt(orchardId, 'uid-jordan', endOfDay(DateTime.now().add(const Duration(days: 40))));
          await service.setRules(orchardId, const RecordRules(emailDomains: {'example.com'}));
        });
        await show(tester, TeamPage.members);
        await settle(tester);
        expect(find.byKey(const ValueKey('members-outside')), findsNothing);
        await done(tester);
      });
    });

    group('addresses this device has not heard', () {
      testWidgets('read before it says who is outside: someone who moved is listed', (tester) async {
        await setUpTeam(tester);
        server.emails['uid-jordan'] = 'jordan@partner.test';
        await show(tester, TeamPage.rules);
        await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
        await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('rules-save')));
        await settle(tester);
        expect(find.text('jordan@partner.test'), findsOneWidget);
        expect(find.text(l10n.orchardOutsideTitle(1, 'example.com')), findsOneWidget);
        await done(tester);
      });

      testWidgets('not known at all: listed, and said so; the server holds them back if they are outside', (tester) async {
        await setUpTeam(tester);
        await tester.runAsync(() async {
          server.emails.remove('uid-jordan');
          await (await databases.open(orchardId)).customStatement('UPDATE member_keys SET email = NULL WHERE uid = ?', ['uid-jordan']);
        });
        final people = await tester.runAsync(() => service.people(orchardId));
        final outside = outsideDomainsOf(people!, {'example.com'});
        expect([for (final p in outside.unknown) p.uid], ['uid-jordan']);
        expect(outside.held.map((p) => p.uid), isNot(contains('uid-jordan')));
        await show(tester, TeamPage.rules);
        await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
        await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('rules-save')));
        await settle(tester);
        expect(find.byKey(const ValueKey('outside-unknown-uid-jordan')), findsOneWidget);
        expect(find.text(l10n.orchardOutsideAddressUnknown), findsOneWidget);
        await done(tester);
      });
    });

    group('what stops part way', () {
      /// 61 people outside the domains, and a key they could all use: the rules
      /// and 59 of them fit the first step.
      Future<List<String>> setUpMany(WidgetTester tester) async {
        await setUpTeam(tester);
        final uids = <String>[];
        await tester.runAsync(() async {
          final member = server.recordOf(orchardId).roles.values.single.id;
          final crate = server.recordOf(orchardId).crates.keys.first;
          for (var i = 0; i < 61; i++) {
            final uid = 'uid-many-$i';
            final email = 'many$i@partner.test';
            uids.add(uid);
            await server.publish(uid, await AccountKeys.generate(), email: email);
            await service.invite(orchardId, email: email, role: member, grants: {crate: levelSwitches(CrateLevel.use)});
            final inv = (await service.invites(orchardId)).singleWhere((i) => i.email == email);
            server.acceptAs(orchardId, inv.id, uid);
            await service.confirmInvite(orchardId, (await service.invites(orchardId)).singleWhere((i) => i.email == email));
          }
          // A key they could use, kept to be changed next.
          final db = await databases.open(orchardId);
          final at = DateTime(2026, 10, 1);
          await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: 'key-1', label: 'deploy key', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
          await db.customStatement(
              "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('key', 'key-1', ?, 0)", [crate]);
          await service.refresh();
        });
        return uids;
      }

      testWidgets('the rules went first, how far it came is said, who went has their keys seen to, and the page reads it all again', (tester) async {
        final uids = await setUpMany(tester);
        final container = await show(tester, TeamPage.rules);
        final versionBefore = container.read(orchardListVersionProvider);
        await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
        await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('rules-save')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('outside-all-remove')));
        await settle(tester);
        const stopped = OrchardServerException(503, 'unavailable');
        server.failAppendAfter = 1;
        server.failNextAppend = stopped;
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        expect(find.textContaining(', and 58 more').evaluate().isNotEmpty || find.textContaining('and 58 more').evaluate().isNotEmpty, isTrue,
            reason: 'the question says who, the first few');
        await tester.tap(find.text(l10n.orchardRemoveConfirm).last);
        await settle(tester);
        await settle(tester);

        // The rules are in, 59 went, and 2 did not.
        final record = server.recordOf(orchardId);
        expect(record.rules.emailDomains, {'example.com'});
        final gone = [for (final u in uids) if (record.members[u]?.status == MemberStatus.removed) u];
        expect(gone, hasLength(59));
        // It says so, how far, and why, with the details, and what was saved is no draft.
        final why = orchardChangeErrorMessage(stopped, l10n);
        final said = container.read(notificationCenterProvider).history.where((n) => '${n.title} ${n.body ?? ''}' == l10n.orchardOutsideStopped(60, 62, why));
        expect(said, hasLength(1));
        expect(said.single.details, contains('60 of 62'));
        expect(container.read(orchardRulesDraftProvider(orchardId)), isNull);
        // Their keys: new ones, and what they could use is to be changed next.
        expect(server.rotations, isNotEmpty, reason: 'those removed still need their keys changed');
        final items = await tester.runAsync(() => service.changeNext(orchardId));
        expect({for (final i in items!) i.subjectUid}, gone.toSet());
        // What was done is read again, and Members has the rest to decide.
        expect(container.read(orchardListVersionProvider), greaterThan(versionBefore));
        await done(tester);
      });

      testWidgets('what stopped it stops the new keys too: what they could use is kept all the same', (tester) async {
        final uids = await setUpMany(tester);
        await show(tester, TeamPage.rules);
        await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.com');
        await tester.tap(find.byKey(const ValueKey('rule-domain-add')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('rules-save')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('outside-all-remove')));
        await settle(tester);
        server.failAppendAfter = 1;
        server.failAppendsStay = true;
        server.failNextAppend = const OrchardServerException(503, 'unavailable');
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        await tester.tap(find.text(l10n.orchardRemoveConfirm).last);
        await settle(tester);
        await settle(tester);
        final record = server.recordOf(orchardId);
        final gone = [for (final u in uids) if (record.members[u]?.status == MemberStatus.removed) u];
        expect(gone, hasLength(59));
        expect(server.rotations, isEmpty);
        final items = await tester.runAsync(() => service.changeNext(orchardId));
        expect({for (final i in items!) i.subjectUid}, gone.toSet());
        await done(tester);
      });

      testWidgets('what fails in the first step left nothing changed, and is said as what it is', (tester) async {
        await toOutside(tester);
        await tester.tap(find.byKey(const ValueKey('outside-choice-uid-jordan')));
        await settle(tester);
        await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.guest}')).last);
        await settle(tester);
        const stopped = OrchardServerException(503, 'unavailable');
        server.failNextAppend = stopped;
        await tester.tap(find.byKey(const ValueKey('outside-go')));
        await settle(tester);
        expect(find.text(orchardChangeErrorMessage(stopped, l10n)), findsOneWidget);
        expect(server.recordOf(orchardId).rules.emailDomains, isEmpty);
        expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt, isNull);
        await done(tester);
      });

      test('the words: how many, of how many, and why', () {
        const stop = OutsideSettleStopped(done: 60, total: 71, removed: {'a'}, cause: OrchardServerException(503, 'unavailable'));
        final said = orchardChangeErrorMessage(stop, l10n);
        expect(said, l10n.orchardOutsideStopped(60, 71, orchardChangeErrorMessage(stop.cause, l10n)));
        expect(said, contains('60'));
        expect(said, contains('71'));
        expect('$stop', contains('60 of 71'));
      });
    });

    testWidgets('a date further off than a date can say (a server from before the limit took any number): Members stands, and the panel with it', (tester) async {
      await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
      await tester.runAsync(() => service.setMemberEndsAt(orchardId, 'uid-jordan', 9007199254740991));
      await show(tester, TeamPage.members);
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('member-uid-jordan')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('member-uid-jordan')));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('member-panel-uid-jordan')), findsOneWidget);
      await done(tester);
    });

    testWidgets('in the record, as decided: the list, then the guest', (tester) async {
      await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
      final before = server.entriesOf(orchardId).length;
      final until = DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      await tester.runAsync(() => service.settleOutsideDomains(orchardId,
          rules: const RecordRules(emailDomains: {'example.com'}), guests: {'uid-jordan': until}));
      expect([for (final e in server.entriesOf(orchardId).skip(before)) e.type], [RecordTypes.rulesSet, RecordTypes.memberSet]);
      expect(server.recordOf(orchardId).members['uid-jordan']!.endsAt, until);
      expect(server.recordOf(orchardId).rules.emailDomains, {'example.com'});
    });

    testWidgets('who a list leaves out: this account never, nor anyone with an end date, who is counted as a guest', (tester) async {
      await setUpTeam(tester, jordanEmail: 'jordan@partner.test');
      var people = await tester.runAsync(() => service.people(orchardId));
      var outside = outsideDomainsOf(people!, {'example.com'});
      expect([for (final p in outside.held) p.uid], ['uid-jordan']);
      expect(outside.guests, isEmpty);
      expect(outsideDomainsOf(people, {}).held, isEmpty, reason: 'no list, nobody outside');
      expect(outsideDomainsOf(people, {'partner.test'}).held, isEmpty, reason: 'owner-1 is this account');
      await tester.runAsync(() => service.setMemberEndsAt(orchardId, 'uid-jordan', DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600));
      people = await tester.runAsync(() => service.people(orchardId));
      outside = outsideDomainsOf(people!, {'example.com'});
      expect(outside.held, isEmpty);
      expect([for (final p in outside.guests) p.uid], ['uid-jordan']);
      expect(outside.isEmpty, isFalse);
      // Their date passed: neither.
      outside = outsideDomainsOf(people, {'example.com'}, nowSeconds: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 7200);
      expect(outside.held, isEmpty);
      expect(outside.guests, isEmpty);
      expect(outside.isEmpty, isTrue);
    });

    testWidgets(
        'changed and not saved: a bar under the page says how many, the rows say which, the menu counts them, '
        'and leaving asks first', (tester) async {
      await setUpTeam(tester);
      final container = await show(tester, TeamPage.rules);
      expect(find.byKey(const ValueKey('rules-unsaved-bar')), findsNothing);
      await tester.tap(inKey('rule-two-step', find.byType(ZestSwitch)));
      await tester.ensureVisible(inKey('rule-no-export', find.byType(ZestSwitch)));
      await settle(tester);
      await tester.tap(inKey('rule-no-export', find.byType(ZestSwitch)));
      await settle(tester);
      expect(inKey('rules-unsaved-bar', find.text(l10n.orchardRulesUnsaved(2))), findsOneWidget);
      expect(inKey('rule-two-step', find.byKey(const ValueKey('rule-not-saved'))), findsOneWidget);
      expect(inKey('rule-no-export', find.byKey(const ValueKey('rule-not-saved'))), findsOneWidget);
      expect(inKey('rule-reauth', find.byKey(const ValueKey('rule-not-saved'))), findsNothing);
      expect(inKey('team-nav-rules', find.text('2')), findsOneWidget);
      // The bar stays in sight wherever the page is scrolled to.
      await tester.drag(find.byKey(const ValueKey('rules-on-devices')), const Offset(0, -2000));
      await settle(tester);
      expect(find.byKey(const ValueKey('rules-save')).hitTestable(), findsOneWidget);

      // Another page: asked first. Keep editing stays, with the changes.
      await tester.tap(find.byKey(const ValueKey('team-nav-members')));
      await settle(tester);
      expect(find.text(l10n.orchardRulesLeaveTitle), findsOneWidget);
      expect(find.text(l10n.orchardRulesLeaveBody(2)), findsOneWidget);
      await tester.tap(find.text(l10n.orchardRulesKeepEditing));
      await settle(tester);
      expect(container.read(teamPageProvider), TeamPage.rules);
      expect(tester.widget<ZestSwitch>(inKey('rule-two-step', find.byType(ZestSwitch))).value, isTrue);

      // Discard: the page goes, and the rules are as they were.
      await tester.tap(find.byKey(const ValueKey('team-nav-members')));
      await settle(tester);
      await tester.tap(find.text(l10n.zestCommonDiscard).last);
      await settle(tester);
      expect(container.read(teamPageProvider), TeamPage.members);
      expect(inKey('team-nav-rules', find.text('2')), findsNothing);
      container.read(teamPageProvider.notifier).state = TeamPage.rules;
      await settle(tester);
      expect(tester.widget<ZestSwitch>(inKey('rule-two-step', find.byType(ZestSwitch))).value, isFalse);
      expect(find.byKey(const ValueKey('rules-unsaved-bar')), findsNothing);

      // Changes kept when the page goes another way (nothing asked there):
      // back on Rules, still there, Discard in the bar drops them.
      await tester.tap(inKey('rule-two-step', find.byType(ZestSwitch)));
      await settle(tester);
      container.read(teamPageProvider.notifier).state = TeamPage.overview;
      await settle(tester);
      expect(inKey('team-nav-rules', find.text('1')), findsOneWidget);
      container.read(teamPageProvider.notifier).state = TeamPage.rules;
      await settle(tester);
      expect(tester.widget<ZestSwitch>(inKey('rule-two-step', find.byType(ZestSwitch))).value, isTrue);
      await tester.tap(find.byKey(const ValueKey('rules-discard')));
      await settle(tester);
      expect(tester.widget<ZestSwitch>(inKey('rule-two-step', find.byType(ZestSwitch))).value, isFalse);
      expect(find.byKey(const ValueKey('rules-unsaved-bar')), findsNothing);
      await done(tester);
    });
  });

  group('Rules kept while the page is away', () {
    testWidgets(
        'a terminal shown in its place and the page again: the Rules page, its changes and the domain typed, unsaved; '
        'a change of profile forgets them', (tester) async {
      await setUpTeam(tester);
      final container = await show(tester, TeamPage.rules);
      await tester.tap(inKey('rule-two-step', find.byType(ZestSwitch)));
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('rule-domain-field')), 'example.org');
      await settle(tester);
      expect(inKey('rules-unsaved-bar', find.text(l10n.orchardRulesUnsaved(1))), findsOneWidget);

      // The shell shows a terminal in the page's place: the page goes.
      Widget app(Widget body) => UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              locale: const Locale('en'),
              home: Scaffold(body: body),
            ),
          );
      await tester.pumpWidget(app(const Text('a terminal')));
      await settle(tester);
      expect(find.byType(TeamView), findsNothing);
      await tester.pumpWidget(app(const TeamView()));
      await settle(tester);

      expect(container.read(teamPageProvider), TeamPage.rules);
      expect(tester.widget<ZestSwitch>(inKey('rule-two-step', find.byType(ZestSwitch))).value, isTrue);
      expect(inKey('rules-unsaved-bar', find.text(l10n.orchardRulesUnsaved(1))), findsOneWidget);
      expect(
          tester
              .widget<EditableText>(find.descendant(
                  of: find.byKey(const ValueKey('rule-domain-field')), matching: find.byType(EditableText)))
              .controller
              .text,
          'example.org');

      // Gone again, and another profile: nothing of it is kept.
      await tester.pumpWidget(app(const Text('a terminal')));
      await settle(tester);
      expect(container.read(orchardRulesTypedDomainProvider).isEmpty, isFalse);
      refreshPersonState(container);
      expect(container.read(orchardRulesTypedDomainProvider).isEmpty, isTrue);
      expect(container.read(orchardRulesDraftProvider(orchardId)), isNull);
      await done(tester);
    });
  });

  group('Sign-in', () {
    testWidgets('a domain waiting for its record: its TXT record to copy, and the later steps locked naming it',
        (tester) async {
      await setUpTeam(tester);
      final container = await show(tester, TeamPage.signIn);
      expect(inKey('signin-step-domains', find.text(l10n.orchardDomainPublishFor('example.dev'))), findsOneWidget);
      expect(find.byKey(const ValueKey('domain-txt-example.dev')), findsOneWidget);
      expect(inKey('signin-step-domains', find.text('TXT')), findsOneWidget);
      expect(find.byKey(const ValueKey('domain-checked-example.dev')), findsOneWidget);
      // Neither later step opens: a proven domain and Business are missing,
      // and each says both.
      final waits = '${l10n.teamSignInUnlocksWhenProven('example.dev')} ${l10n.teamSignInBusinessOff}';
      expect(inKey('signin-sso-locked', find.text(waits)), findsOneWidget);
      expect(inKey('signin-directory-locked', find.text(waits)), findsOneWidget);
      expect(find.byType(OrchardSsoView), findsNothing);
      expect(find.byType(OrchardDirectoryView), findsNothing);
      expect(find.text(l10n.teamSignInNeedsBusiness), findsNWidgets(2));
      // See Business opens the Seats page, where Business is.
      await tester.tap(inKey('signin-sso-locked', find.byKey(const ValueKey('signin-see-business'))));
      await settle(tester);
      expect(container.read(teamPageProvider), TeamPage.seats);
      await done(tester);
    });

    testWidgets('proven, without Business: the steps wait for Business alone', (tester) async {
      await setUpTeam(tester);
      cloud.proven = true;
      await show(tester, TeamPage.signIn);
      expect(find.byKey(const ValueKey('signin-step-1-done')), findsOneWidget);
      expect(inKey('signin-sso-locked', find.text(l10n.teamSignInBusinessOff)), findsOneWidget);
      expect(inKey('signin-directory-locked', find.text(l10n.teamSignInBusinessOff)), findsOneWidget);
      expect(find.byType(OrchardSsoView), findsNothing);
      await done(tester);
    });

    testWidgets('proven, with Business: company sign-in and directory sync open, as they were', (tester) async {
      await setUpTeam(tester);
      cloud.proven = true;
      cloud.business = 'active';
      await show(tester, TeamPage.signIn);
      expect(find.byKey(const ValueKey('signin-sso-locked')), findsNothing);
      expect(find.byKey(const ValueKey('signin-directory-locked')), findsNothing);
      expect(find.byType(OrchardSsoView), findsOneWidget);
      expect(find.byType(OrchardDirectoryView), findsOneWidget);
      expect(find.byKey(const ValueKey('directory-on')), findsOneWidget);
      expect(find.text(l10n.teamSignInNeedsBusiness), findsNothing);
      await done(tester);
    });
  });

  group('Seats', () {
    testWidgets('the bar counts members, people invited and open seats; who holds them, and the prices',
        (tester) async {
      await setUpTeam(tester);
      final container = await show(tester, TeamPage.seats);
      expect(find.text(l10n.teamSeatsInUse(4, 5)), findsOneWidget);
      expect(find.text(l10n.teamSeatsOpenCount(1)), findsOneWidget);
      String legend(String k) => tester
          .widgetList<Text>(inKey('team-seats-legend-$k', find.byType(Text)))
          .map((t) => t.data)
          .join(' ');
      expect(legend('members'), '${l10n.orchardMembers} 2');
      expect(legend('waiting'), '${l10n.teamSeatsLegendWaiting} 2');
      expect(legend('open'), '${l10n.teamSeatsLegendOpen} 1');
      int flex(String k) => tester.widget<Expanded>(find.byKey(ValueKey('team-seats-bar-$k'))).flex;
      expect([flex('members'), flex('waiting'), flex('open')], [2, 2, 1]);

      // The prices ZestSSH Cloud gives, for the words.
      expect(find.text(l10n.teamSeatsBuyHint(r'$100')), findsOneWidget);
      expect(find.text(l10n.teamServicesPrice(r'$20', r'$200')), findsOneWidget);
      expect(find.text(l10n.teamServicesStateOff), findsOneWidget);
      // Buy seats and Redeem a code once each, in the header.
      expect(find.byKey(const ValueKey('team-seats-buy')), findsOneWidget);
      expect(find.byKey(const ValueKey('team-seats-redeem')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('team-services-see')));
      await settle(tester);
      expect(find.byKey(const ValueKey('seats-sheet-business')), findsOneWidget);
      expect(opened, isEmpty, reason: 'bought from inside the app');
      await tester.tap(find.text(l10n.close).last);
      await settle(tester);

      // Who holds them: the owner (this account), jordan, sam who accepted
      // and waits for this account, and priya invited.
      expect(find.byKey(const ValueKey('team-seat-member-owner-1')), findsOneWidget);
      expect(inKey('team-seat-member-owner-1', find.text(l10n.teamYou)), findsOneWidget);
      expect(find.byKey(const ValueKey('team-seat-member-uid-jordan')), findsOneWidget);
      expect(inKey('team-seat-member-uid-jordan', find.byType(TeamInitials)), findsOneWidget,
          reason: 'two letters, as on the Members page');
      // The roles outlined as the Members page has them (they were filled
      // before a design review), You with them.
      expect(inKey('team-seat-member-uid-jordan', find.byType(TeamRolePill)), findsOneWidget);
      expect(inKey('team-seat-member-owner-1', find.byType(TeamRolePill)), findsNWidgets(2));
      expect(
          tester
              .widgetList<TeamRolePill>(inKey('team-seat-member-owner-1', find.byType(TeamRolePill)))
              .map((p) => p.accent),
          [false, true],
          reason: 'the Owner role in the accent');
      final invites = await tester.runAsync(() => service.invites(orchardId));
      final sam = invites!.firstWhere((i) => i.email == 'sam@example.com');
      final priya = invites.firstWhere((i) => i.email == 'priya@example.com');
      expect(inKey('team-seat-invite-${sam.id}', find.text(l10n.teamSeatsWaitingForYou)), findsOneWidget);
      expect(inKey('team-seat-invite-${priya.id}', find.text(l10n.teamSeatsInvitedBadge)), findsOneWidget);

      // Review opens Members at sam's review, beside the list (it once
      // opened the page alone, and he had to be found there).
      await tester.tap(find.byKey(ValueKey('team-seat-review-${sam.id}')));
      await settle(tester);
      expect(container.read(teamPageProvider), TeamPage.members);
      expect(container.read(teamReviewPanelProvider(orchardId)), sam.id);
      await done(tester);
    });

    testWidgets('withdrawing an invitation from Seats takes it away on the server', (tester) async {
      await setUpTeam(tester);
      await show(tester, TeamPage.seats);
      final priya = (await tester.runAsync(() => service.invites(orchardId)))!
          .firstWhere((i) => i.email == 'priya@example.com');
      final withdraw = find.byKey(ValueKey('team-seat-withdraw-${priya.id}'));
      await tester.ensureVisible(withdraw);
      await tester.tap(withdraw);
      await settle(tester);
      final left = await tester.runAsync(() => service.invites(orchardId));
      expect(left!.map((i) => i.email), isNot(contains('priya@example.com')));
      expect(find.byKey(ValueKey('team-seat-invite-${priya.id}')), findsNothing);
      await done(tester);
    });

    // An invite code nobody used yet holds a seat and has no address: its
    // row was one with no name (found in a docs check). It is
    // named as the Members page names it, with the role it offers and what
    // it waits for, and Cancel code takes it away.
    testWidgets('an invite code nobody used: named, with its role, waiting, and cancelled as a code', (tester) async {
      await setUpTeam(tester);
      final made = (await tester.runAsync(() => service.makeInviteCode(orchardId,
          role: server.recordOf(orchardId).roles.values.single.id,
          expiresIn: 3600,
          shown: const JoinOffer(team: 'Acme', role: 'Member', vaults: [JoinOfferVault('Production', 'use')]))))!;
      await show(tester, TeamPage.seats);
      final row = 'team-seat-invite-${made.inviteId}';
      expect(find.byKey(ValueKey(row)), findsOneWidget);
      expect(inKey(row, find.text(l10n.inviteCodeLabel)), findsOneWidget);
      expect(inKey(row, find.text('Member')), findsOneWidget);
      expect(inKey(row, find.text(l10n.inviteCodeWaitingTitle)), findsOneWidget);
      expect(inKey(row, find.byIcon(LucideIcons.qrCode)), findsOneWidget);
      final texts = tester.widgetList<Text>(inKey(row, find.byType(Text))).map((t) => t.data ?? '').toList();
      expect(texts.where((t) => t.trim().isEmpty), isEmpty, reason: 'no row without words: $texts');
      final cancel = find.byKey(ValueKey('team-seat-withdraw-${made.inviteId}'));
      expect(inKey(row, find.text(l10n.inviteCodeCancel)), findsOneWidget);
      await tester.ensureVisible(cancel);
      await tester.tap(cancel);
      await settle(tester);
      final left = await tester.runAsync(() => service.invites(orchardId));
      expect(left!.map((i) => i.id), isNot(contains(made.inviteId)));
      expect(find.byKey(ValueKey(row)), findsNothing);
      await done(tester);
    });

    testWidgets('a server that sends no prices: the words say the prices of 27 October 2026', (tester) async {
      await setUpTeam(tester);
      cloud.prices = null;
      await show(tester, TeamPage.seats);
      expect(find.text(l10n.teamSeatsBuyHint(r'$100')), findsOneWidget);
      expect(find.text(l10n.teamServicesPrice(r'$15', r'$150')), findsOneWidget);
      await done(tester);
    });
  });

  test('the bar adds up to what the service counts, whatever is known of the invitations', () {
    const seats = OrchardSeats(bought: 4, included: 1, total: 5, used: 4, free: 1, over: false);
    expect(seatShares(seats, waiting: 2), (members: 2, waiting: 2, open: 1));
    expect(seatShares(seats), (members: 4, waiting: 0, open: 1));
    // More invitations than the service counts (one lapsed since): never
    // more than are in use.
    expect(seatShares(seats, waiting: 9), (members: 0, waiting: 4, open: 1));
  });
}
