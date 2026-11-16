import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart';

/// Every plan name the app shows explains itself (4.0, as
/// designed): the plan beside the person on
/// Settings, Account (a computer's and a phone's, one panel) is the plan's
/// chip, which opens the plan popover, and says the Bundle where it said
/// Juiced for both; a tag a feature needs its plan by (Squeezed beside Custom
/// theme, Juiced beside ZestSSH Cloud) opens the same popover; a team's seat
/// is never shown a fruit name. On a phone the chip is 48 high to a thumb and
/// the popover opens under it, inside the window.

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

List<Override> _plan(AccountPlan plan) {
  final pro = plan == AccountPlan.squeezed || plan == AccountPlan.bundle || plan == AccountPlan.teamSeat;
  final cloud = plan == AccountPlan.juiced || plan == AccountPlan.bundle || plan == AccountPlan.teamSeat;
  return [
    isProProvider.overrideWith((_) => _Pro(pro)),
    isCloudSyncProvider.overrideWith((_) => _Cloud(cloud)),
    teamSeatProvider.overrideWith((_) => plan == AccountPlan.teamSeat),
  ];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  var fontsLoaded = false;

  tearDown(() => debugTouchLayout = null);

  Future<void> fonts(WidgetTester tester) async {
    if (fontsLoaded) return;
    await tester.runAsync(loadShotFonts);
    fontsLoaded = true;
  }

  Future<void> settle(WidgetTester tester, {int rounds = 6}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// Settings, Account as a computer embeds it (a phone shows the same
  /// panel), signed in, on [plan].
  Future<void> pumpAccount(WidgetTester tester, AccountPlan plan) async {
    await fonts(tester);
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith(
            (_) => const UserProfile(uid: 'u1', email: 'alex@example.com', displayName: 'Alex Rivera')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 25, 12))),
        ..._plan(plan),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans', brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: const Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  final chip = find.byKey(const ValueKey('account-plan-chip'));
  final popover = find.byKey(const ValueKey('plan-popover'));

  testWidgets("the Account page: the plan beside the person is the plan's chip, and a tap says what each plan is",
      (tester) async {
    await pumpAccount(tester, AccountPlan.juiced);
    expect(find.descendant(of: chip, matching: find.text(en.narrowSidebarTierJuiced)), findsOneWidget);
    // Beside the name, on the name's line.
    expect((tester.getCenter(chip).dy - tester.getCenter(find.text('Alex Rivera')).dy).abs(), lessThan(4));
    await tester.tap(chip);
    await settle(tester);
    expect(popover, findsOneWidget);
    expect(find.descendant(of: popover, matching: find.text(en.planPopoverTitle(en.narrowSidebarTierJuiced))),
        findsOneWidget);
    // Juiced lacks Squeezed: its buy button says so, with its price.
    expect(find.descendant(of: popover, matching: find.text(en.planGetWithPrice(en.narrowSidebarTierSqueezed, '\$9.99'))),
        findsOneWidget);
    // It stands beside the chip, on the screen.
    final box = tester.getRect(popover);
    expect(box.left, greaterThanOrEqualTo(tester.getRect(chip).right));
    expect(box.bottom, lessThanOrEqualTo(3000));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(popover, findsNothing);
    await close(tester);
  });

  testWidgets('the Account page says the Bundle for both (it said Juiced), nothing on Free, and a seat in words',
      (tester) async {
    await pumpAccount(tester, AccountPlan.bundle);
    expect(find.descendant(of: chip, matching: find.text(en.pricingTierBundle)), findsOneWidget);
    expect(find.descendant(of: chip, matching: find.text(en.narrowSidebarTierJuiced)), findsNothing);
    await close(tester);

    // Free: no paid plan to show beside the name (as before).
    await pumpAccount(tester, AccountPlan.free);
    expect(chip, findsNothing);
    await close(tester);

    // A team's seat: no fruit name, beside the name or in the popover.
    await pumpAccount(tester, AccountPlan.teamSeat);
    expect(find.descendant(of: chip, matching: find.text(en.planTeamSeat)), findsOneWidget);
    await tester.tap(chip);
    await settle(tester);
    expect(find.text(en.planTeamSeatBody), findsOneWidget);
    for (final fruit in [en.narrowSidebarTierSqueezed, en.narrowSidebarTierJuiced, en.pricingTierBundle]) {
      expect(find.textContaining(fruit), findsNothing, reason: fruit);
    }
    await close(tester);
  });

  /// [child] alone in a window [size], on [plan].
  Future<void> pumpAlone(WidgetTester tester, Widget child,
      {AccountPlan plan = AccountPlan.free, Size size = const Size(1200, 800), Alignment at = Alignment.center}) async {
    await fonts(tester);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ..._plan(plan),
        planPurchaseOpenerProvider.overrideWithValue((_) {}),
        planPageOpenerProvider.overrideWithValue((_) async {}),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans', brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Align(alignment: at, child: child)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets("a feature's tag names the plan it needs and opens the same popover, about this account's plan",
      (tester) async {
    await pumpAlone(tester, const PlanChip(plan: AccountPlan.squeezed));
    final tag = find.byKey(const ValueKey('plan-chip-squeezed'));
    expect(find.descendant(of: tag, matching: find.text(en.narrowSidebarTierSqueezed)), findsOneWidget);
    // To a screen reader: the plan's name, and what a tap does.
    final node = tester.getSemantics(find.byType(PlanChip));
    expect(node.label, en.narrowSidebarTierSqueezed);
    expect(node.hint, en.planChipTip);
    await tester.tap(tag);
    await tester.pumpAndSettle();
    expect(find.descendant(of: popover, matching: find.text(en.planPopoverTitle(en.narrowSidebarTierFree))),
        findsOneWidget);
    expect(find.byKey(const ValueKey('plan-row-squeezed')), findsOneWidget);
    await tester.tapAt(const Offset(4, 4));
    await tester.pumpAndSettle();
    expect(popover, findsNothing);

    await pumpAlone(tester, const PlanChip(plan: AccountPlan.juiced), plan: AccountPlan.squeezed);
    expect(find.text(en.narrowSidebarTierJuiced), findsOneWidget);
  });

  testWidgets("a team's seat is not shown a feature's plan tag", (tester) async {
    await pumpAlone(
        tester,
        const Row(mainAxisSize: MainAxisSize.min, children: [
          PlanChip(plan: AccountPlan.squeezed),
          PlanChip(plan: AccountPlan.juiced),
          PlanChip(),
        ]),
        plan: AccountPlan.teamSeat);
    expect(find.text(en.narrowSidebarTierSqueezed), findsNothing);
    expect(find.text(en.narrowSidebarTierJuiced), findsNothing);
    expect(find.text(en.planTeamSeat), findsOneWidget);
  });

  testWidgets('on a phone: the chip is 48 high to a thumb, and the popover opens under it inside the window',
      (tester) async {
    debugTouchLayout = true;
    await pumpAlone(tester, const PlanChip(), plan: AccountPlan.juiced, size: const Size(390, 844), at: const Alignment(0.6, -0.7));
    final hit = find.byKey(const ValueKey('plan-chip'));
    expect(tester.getSize(hit).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(hit).width, greaterThanOrEqualTo(48));
    await tester.tap(hit);
    await tester.pumpAndSettle();
    final box = tester.getRect(popover);
    expect(box.top, greaterThan(tester.getRect(hit).bottom));
    expect(box.left, greaterThanOrEqualTo(8));
    expect(box.right, lessThanOrEqualTo(390 - 8));
    expect(box.bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    // Near the window's foot, it opens over the chip.
    await pumpAlone(tester, const PlanChip(), plan: AccountPlan.juiced, size: const Size(390, 844), at: const Alignment(0, 0.9));
    await tester.tap(hit);
    await tester.pumpAndSettle();
    expect(tester.getRect(popover).bottom, lessThan(tester.getRect(hit).top));
    expect(tester.getRect(popover).top, greaterThanOrEqualTo(0));
  });
}
