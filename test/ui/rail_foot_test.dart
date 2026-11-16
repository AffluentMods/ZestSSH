import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart' show accountSetupNeedsAttentionProvider;
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';

import '../visual/shots_util.dart';

/// The foot of a computer's rail (4.0, as
/// designed): the avatar, the name and a plan chip that
/// explains itself when clicked (it was the plan's name in grey), and Join
/// Discord as a small icon with its name in a tooltip and to a screen reader
/// (it was a full-width row above the account).

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Cloud extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Cloud(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _alex = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex');

Finder _key(String k) => find.byKey(ValueKey(k));

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester,
      {UserProfile? user, bool pro = false, bool cloud = false, bool seat = false, bool collapsed = false}) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1280, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'desktop_sidebar_collapsed': collapsed});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      // A new container each time: the settings are read once per container.
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        authStateProvider.overrideWith((_) => const Stream.empty()),
        desktopSessionProvider.overrideWith((_) => user),
        isProProvider.overrideWith((_) => _Pro(pro)),
        isCloudSyncProvider.overrideWith((_) => _Cloud(cloud)),
        teamSeatProvider.overrideWith((_) => seat),
        accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans', brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Row(
            children: [
              NarrowSidebar(activeSection: NavSection.hosts, onSectionChanged: (_) {}),
              const Expanded(child: SizedBox()),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull, reason: 'nothing runs over');
  }

  testWidgets('signed in on Juiced: the name, a plan chip that says Juiced, and Discord as a small icon',
      (tester) async {
    final semantics = tester.ensureSemantics();
    await pump(tester, user: _alex, cloud: true);
    final profile = _key('rail-profile');
    expect(find.descendant(of: profile, matching: find.text('Alex')), findsOneWidget);
    final chip = find.descendant(of: profile, matching: find.byType(PlanChip));
    expect(chip, findsOneWidget, reason: 'under the name');
    expect(find.descendant(of: chip, matching: find.text('Juiced')), findsOneWidget);
    expect(find.bySemanticsLabel(en.planPopoverTitle('Juiced')), findsOneWidget);
    // Discord: an icon at the foot's end, named in a tooltip and to a screen
    // reader; the row of its own is gone.
    final discord = _key('rail-discord');
    expect(discord, findsOneWidget);
    expect(find.text(en.narrowSidebarJoinDiscord), findsNothing, reason: 'no full-width row');
    expect(find.byTooltip(en.narrowSidebarJoinDiscord), findsOneWidget);
    expect(find.bySemanticsLabel(en.narrowSidebarJoinDiscord), findsOneWidget);
    expect(tester.getCenter(discord).dy, closeTo(tester.getCenter(profile).dy, 4), reason: 'on the account\'s line');
    expect(tester.getRect(discord).left, greaterThan(tester.getRect(chip).right), reason: 'at its end');
    semantics.dispose();
  });

  testWidgets('the chip opens what the plan is, beside the rail', (tester) async {
    await pump(tester, user: _alex, cloud: true);
    await tester.tap(_key('plan-chip'));
    await tester.pumpAndSettle();
    expect(_key('plan-popover'), findsOneWidget);
    expect(find.text(en.planPopoverTitle('Juiced')), findsOneWidget);
    expect(tester.getRect(_key('plan-popover')).left, greaterThanOrEqualTo(tester.getRect(find.byType(NarrowSidebar)).right),
        reason: 'beside the rail, not over it');
  });

  testWidgets('the Bundle, Free and a team seat each say their plan', (tester) async {
    await pump(tester, user: _alex, pro: true, cloud: true);
    expect(find.descendant(of: _key('plan-chip'), matching: find.text(en.pricingTierBundle)), findsOneWidget,
        reason: 'both is the Bundle (it said Juiced)');
    await pump(tester, user: _alex);
    expect(find.descendant(of: _key('plan-chip'), matching: find.text(en.narrowSidebarTierFree)), findsOneWidget);
    expect(_key('rail-upgrade'), findsOneWidget, reason: 'Upgrade stays a row of its own');
    await pump(tester, user: _alex, pro: true, cloud: true, seat: true);
    expect(find.descendant(of: _key('plan-chip'), matching: find.text(en.planTeamSeat)), findsOneWidget);
    expect(find.text(en.pricingTierBundle), findsNothing, reason: 'no fruit name for a seat');
  });

  testWidgets('a guest: Guest, on this computer only, no chip; Discord still at the end', (tester) async {
    await pump(tester);
    expect(find.descendant(of: _key('rail-profile'), matching: find.text(en.narrowSidebarGuest)), findsOneWidget);
    expect(find.descendant(of: _key('rail-profile'), matching: find.text(en.railGuestLocal)), findsOneWidget);
    expect(find.byType(PlanChip), findsNothing);
    expect(_key('rail-discord'), findsOneWidget);
  });

  testWidgets('pushed in to icons: Discord an icon above the avatar, as before, and no chip', (tester) async {
    await pump(tester, user: _alex, cloud: true, collapsed: true);
    expect(find.byTooltip(en.narrowSidebarJoinDiscord), findsOneWidget);
    expect(find.byType(PlanChip), findsNothing);
  });
}
