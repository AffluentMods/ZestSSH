import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';

import '../visual/shots_util.dart';
import '../a11y/a11y_checks.dart';

/// A plan name that explains itself (4.0, as
/// designed): the plan's chip opens what this
/// account has ("Your plan: Juiced", paid once), a line for each of
/// Squeezed, Juiced and the Bundle with what the account has checked and
/// marked Yours, that sync itself is free with storage of one's own,
/// Compare plans and a quiet button for what is missing. A team's seat is
/// said in plain words, with no fruit name anywhere.

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

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late List<Uri> opened;
  late int bought;

  setUp(() {
    opened = [];
    bought = 0;
  });

  /// The chip at the bottom left of a computer's window, for an account on
  /// [plan].
  Future<void> pump(WidgetTester tester, AccountPlan plan) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final pro = plan == AccountPlan.squeezed || plan == AccountPlan.bundle || plan == AccountPlan.teamSeat;
    final cloud = plan == AccountPlan.juiced || plan == AccountPlan.bundle || plan == AccountPlan.teamSeat;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isProProvider.overrideWith((_) => _Pro(pro)),
        isCloudSyncProvider.overrideWith((_) => _Cloud(cloud)),
        teamSeatProvider.overrideWith((_) => plan == AccountPlan.teamSeat),
        planPageOpenerProvider.overrideWithValue((page) async => opened.add(page)),
        planPurchaseOpenerProvider.overrideWithValue((_) => bought++),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans', brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: Padding(padding: EdgeInsets.fromLTRB(60, 0, 0, 30), child: PlanChip()),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('plan-chip')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-popover')), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'nothing runs over');
  }

  Finder yoursIn(String row) =>
      find.descendant(of: find.byKey(ValueKey('plan-row-$row')), matching: find.text(en.planYours));

  Finder buy() => find.byKey(const ValueKey('plan-buy'));

  testWidgets('Juiced: the chip says it, and the popover marks Juiced as yours and offers Squeezed at its price',
      (tester) async {
    await pump(tester, AccountPlan.juiced);
    expect(find.text('Juiced'), findsOneWidget, reason: 'the chip');
    expect(find.bySemanticsLabel(en.planPopoverTitle('Juiced')), findsOneWidget, reason: "the chip's label");
    await open(tester);
    expect(find.text(en.planPopoverTitle('Juiced')), findsOneWidget);
    expect(find.text(en.planPaidOnce), findsOneWidget);
    expect(yoursIn('juiced'), findsOneWidget);
    expect(yoursIn('squeezed'), findsNothing);
    expect(yoursIn('bundle'), findsNothing);
    // What each is, and what completes the Bundle.
    expect(find.text(en.planSqueezedLine), findsOneWidget);
    expect(find.text(en.planJuicedLine), findsOneWidget);
    expect(find.text(en.planBundleHasJuiced), findsOneWidget);
    expect(find.text(en.planSyncFreeNote), findsOneWidget, reason: 'sync itself is free');
    expect(find.descendant(of: buy(), matching: find.text('Get Squeezed, \$9.99')), findsOneWidget);
    // A check against a dash, beside a word: not by colour alone.
    Finder icon(String row, IconData data) =>
        find.descendant(of: find.byKey(ValueKey('plan-row-$row')), matching: find.byIcon(data));
    expect(icon('juiced', LucideIcons.check), findsOneWidget);
    expect(icon('squeezed', LucideIcons.minus), findsOneWidget);
    expect(icon('bundle', LucideIcons.minus), findsOneWidget);
  });

  testWidgets('Squeezed: Squeezed is yours, and Juiced is offered', (tester) async {
    await pump(tester, AccountPlan.squeezed);
    expect(find.text('Squeezed'), findsOneWidget);
    await open(tester);
    expect(find.text(en.planPopoverTitle('Squeezed')), findsOneWidget);
    expect(yoursIn('squeezed'), findsOneWidget);
    expect(yoursIn('juiced'), findsNothing);
    expect(find.text(en.planBundleHasSqueezed), findsOneWidget);
    expect(find.descendant(of: buy(), matching: find.text('Get Juiced, \$24.99')), findsOneWidget);
  });

  testWidgets('the Bundle: all three are yours, and nothing is offered', (tester) async {
    await pump(tester, AccountPlan.bundle);
    expect(find.text(en.pricingTierBundle), findsOneWidget);
    await open(tester);
    expect(find.text(en.planPopoverTitle(en.pricingTierBundle)), findsOneWidget);
    for (final row in ['squeezed', 'juiced', 'bundle']) {
      expect(yoursIn(row), findsOneWidget, reason: row);
    }
    expect(find.text(en.planBundleLine), findsOneWidget);
    expect(buy(), findsNothing);
    expect(find.byKey(const ValueKey('plan-compare')), findsOneWidget);
  });

  testWidgets('Free: the plan is Free, nothing is marked, and Upgrade opens the purchase page', (tester) async {
    await pump(tester, AccountPlan.free);
    expect(find.text(en.narrowSidebarTierFree), findsOneWidget);
    await open(tester);
    expect(find.text(en.planPopoverTitle(en.narrowSidebarTierFree)), findsOneWidget);
    expect(find.text(en.planFreeNote), findsOneWidget);
    expect(find.text(en.planYours), findsNothing);
    expect(find.text(en.planBundleLine), findsOneWidget);
    await tester.tap(buy());
    await tester.pumpAndSettle();
    expect(bought, 1, reason: "the app's own purchase page");
    expect(find.byKey(const ValueKey('plan-popover')), findsNothing, reason: 'the popover closes first');
  });

  testWidgets('a team seat: plain words, and no fruit name anywhere', (tester) async {
    await pump(tester, AccountPlan.teamSeat);
    expect(find.text(en.planTeamSeat), findsOneWidget, reason: 'the chip');
    await open(tester);
    expect(find.text(en.planPopoverTitle(en.planTeamSeat)), findsOneWidget);
    expect(find.text(en.planTeamSeatBody), findsOneWidget);
    for (final fruit in ['Squeezed', 'Juiced', 'Bundle']) {
      expect(find.textContaining(fruit), findsNothing, reason: fruit);
    }
    expect(buy(), findsNothing);
    expect(find.byKey(const ValueKey('plan-compare')), findsNothing);
  });

  testWidgets('Compare plans opens the plans page in the browser and closes the popover', (tester) async {
    await pump(tester, AccountPlan.juiced);
    await open(tester);
    await tester.tap(find.byKey(const ValueKey('plan-compare')));
    await tester.pumpAndSettle();
    expect(opened, [Uri.parse('https://zestssh.com/pricing/plans')]);
    expect(find.byKey(const ValueKey('plan-popover')), findsNothing);
  });

  testWidgets('Get Squeezed opens the purchase page', (tester) async {
    await pump(tester, AccountPlan.juiced);
    await open(tester);
    await tester.tap(buy());
    await tester.pumpAndSettle();
    expect(bought, 1);
    expect(opened, isEmpty);
  });

  testWidgets('beside the chip, pointing at it, inside the window; Escape and a click beside it close it',
      (tester) async {
    await pump(tester, AccountPlan.juiced);
    await open(tester);
    final chip = tester.getRect(find.byKey(const ValueKey('plan-chip')));
    final popover = tester.getRect(find.byKey(const ValueKey('plan-popover')));
    expect(popover.left, greaterThan(chip.right), reason: 'to its right');
    expect(popover.bottom, lessThanOrEqualTo(900 - 8), reason: 'inside the window');
    expect(popover.top, lessThan(chip.center.dy));
    expect(popover.bottom, greaterThan(chip.center.dy), reason: 'beside it');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-popover')), findsNothing, reason: 'Escape');
    await open(tester);
    await tester.tapAt(const Offset(1300, 100));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('plan-popover')), findsNothing, reason: 'a click beside it');
  });

  testWidgets('in German, as long as its words are, nothing runs over', (tester) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final de = lookupAppLocalizations(const Locale('de'));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isProProvider.overrideWith((_) => _Pro(false)),
        isCloudSyncProvider.overrideWith((_) => _Cloud(true)),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('de'),
        home: const Scaffold(body: Align(alignment: Alignment.bottomLeft, child: PlanChip())),
      ),
    ));
    await tester.pumpAndSettle();
    await open(tester);
    expect(find.text(de.planPopoverTitle('Juiced')), findsOneWidget);
    expect(find.text(de.planBundleHasJuiced), findsOneWidget);
  });

  group("the account's plan", () {
    AccountPlan planOf({required bool pro, required bool cloud, bool seat = false}) {
      final c = ProviderContainer(overrides: [
        isProProvider.overrideWith((_) => _Pro(pro)),
        isCloudSyncProvider.overrideWith((_) => _Cloud(cloud)),
        teamSeatProvider.overrideWith((_) => seat),
      ]);
      addTearDown(c.dispose);
      return c.read(accountPlanProvider);
    }

    test('from what the app gates by: Squeezed, Juiced, both the Bundle, a seat said apart', () {
      expect(planOf(pro: false, cloud: false), AccountPlan.free);
      expect(planOf(pro: true, cloud: false), AccountPlan.squeezed);
      expect(planOf(pro: false, cloud: true), AccountPlan.juiced);
      expect(planOf(pro: true, cloud: true), AccountPlan.bundle, reason: 'both is the Bundle, not Juiced');
      expect(planOf(pro: true, cloud: true, seat: true), AccountPlan.teamSeat);
      expect(planOf(pro: false, cloud: false, seat: true), AccountPlan.free,
          reason: 'a seat heard of that gives nothing yet is not said');
    });

    test('each plan has a name in every language, and the fruit names are the same in all of them', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l10n = lookupAppLocalizations(locale);
        for (final plan in AccountPlan.values) {
          expect(plan.nameIn(l10n).trim(), isNotEmpty, reason: '${locale.languageCode} $plan');
        }
        expect(AccountPlan.squeezed.nameIn(l10n), 'Squeezed');
        expect(AccountPlan.juiced.nameIn(l10n), 'Juiced');
      }
    });
  });

  // The 4.0 accessibility pass: the plan chip and its
  // popover hold to the checks every screen of the pass does.
  testWidgets('the plan chip and its popover: names, targets, contrast (the 4.0 accessibility pass)', (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final failures = <String>[];
      for (final plan in [AccountPlan.free, AccountPlan.juiced, AccountPlan.bundle]) {
        await pump(tester, plan);
        await open(tester);
        failures.addAll(await a11yCheck(tester, computer: true, where: 'plan popover, ${plan.name}'));
        // Taken down, so the next plan's app starts with no popover open.
        await tester.pumpWidget(const SizedBox());
      }
      expect(failures, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
  });

  // A build made without ZEST_OFFICIAL=true has no plans: no chip anywhere, and the upgrade page,
  // where every "unlock" in the app leads, says so and offers nothing.
  group('a community build', () {
    setUp(() {
      debugZestOfficial = false;
      addTearDown(() => debugZestOfficial = true);
    });
    tearDown(() => UpgradeScreen.debugDesktop = null);

    testWidgets('the plan chip is not drawn', (tester) async {
      await pump(tester, AccountPlan.free);
      expect(find.byKey(const ValueKey('plan-chip')), findsNothing);
      expect(find.text(en.narrowSidebarTierFree), findsNothing);
    });

    for (final desktop in const [true, false]) {
      testWidgets('the upgrade page on a ${desktop ? 'computer' : 'phone'} says there are no plans to buy here',
          (tester) async {
        UpgradeScreen.debugDesktop = desktop;
        await tester.pumpWidget(const ProviderScope(
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: Locale('en'),
            home: UpgradeScreen(),
          ),
        ));
        await tester.pump();
        expect(find.byKey(const ValueKey('no-plans-here')), findsOneWidget);
        expect(find.text(en.noPlansTitle), findsOneWidget);
        expect(find.text(en.noPlansBody), findsOneWidget);
        expect(find.byType(FilledButton), findsNothing);
        expect(tester.takeException(), isNull);
      });
    }
  });
}
