import 'package:flutter/foundation.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/scheduled_task_providers.dart' show ScheduledTasksHere;
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';
import 'package:zestssh/ui/screens/purchase/restore_purchases.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../visual/shots_util.dart';
import '../a11y/a11y_checks.dart';

/// A page of Squeezed's before it is bought (4.0, as
/// designed): the page in use, faded and out of reach, with
/// made-up demo data, behind a card: "Command history is part of Squeezed", three
/// true things it gives, Get Squeezed, $9.99 once (a computer's price), What
/// is Squeezed? (the plan popover) and Bought it already? Restore purchases
/// (the app's one restore). History (a computer's and a phone's), Workflows
/// and Scheduled tasks; each was a line and Upgrade, or no way on at all.
/// With Squeezed (a team's seat included) the page is the page.

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  var fontsLoaded = false;
  late int bought;
  late int restored;

  setUp(() {
    bought = 0;
    restored = 0;
  });

  tearDown(() {
    debugTouchLayout = null;
    ScheduledTasksScreen.debugHere = null;
  });

  final locked = find.byType(LockedFeatureView);
  Finder k(String key) => find.byKey(ValueKey(key));

  Future<void> pump(WidgetTester tester, Widget screen, {bool pro = false, Size size = const Size(1400, 900)}) async {
    if (!fontsLoaded) {
      await tester.runAsync(loadShotFonts);
      fontsLoaded = true;
    }
    SharedPreferences.setMockInitialValues({'command_history_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        redactionFleetRegistrar.overrideWith((ref) {}),
        isProProvider.overrideWith((ref) => _Pro(pro)),
        recentCommandHistoryProvider.overrideWith((ref) => Stream.value(const <CommandHistoryEntry>[])),
        planPurchaseOpenerProvider.overrideWithValue((_) => bought++),
        planPageOpenerProvider.overrideWithValue((_) async {}),
        purchaseRestorerProvider.overrideWithValue((_) async => restored++),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans', brightness: Brightness.dark),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: screen),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  testWidgets("a computer's History before Squeezed: the page in use, faded, behind what it gives and its price",
      (tester) async {
    await pump(tester, const HistoryView());
    expect(locked, findsOneWidget);
    expect(find.text(en.lockedHistoryTitle), findsOneWidget);
    // Three true things, the third as designed.
    for (final b in [en.lockedHistorySearch, en.lockedHistoryRunAgain, en.lockedHistorySecrets]) {
      expect(find.text(b), findsOneWidget, reason: b);
    }
    expect(en.lockedHistorySecrets,
        'Passwords are never recorded, and commands that look like they hold a secret are left out');
    expect(find.text(en.lockedGetPlanOnce('Squeezed', r'$9.99')), findsOneWidget);
    expect(en.lockedGetPlanOnce('Squeezed', r'$9.99'), r'Get Squeezed, $9.99 once');
    // The old line and Upgrade are gone.
    expect(find.text('Command history is a Squeezed feature'), findsNothing);
    expect(find.text('Upgrade to Squeezed'), findsNothing);

    // The preview is the page's own table with made-up commands, drawn
    // faded, and out of reach of the pointer and a screen reader.
    final preview = k('locked-preview');
    expect(find.descendant(of: preview, matching: find.text('qm list')), findsOneWidget);
    expect(find.descendant(of: preview, matching: find.text('web-01')), findsWidgets);
    expect(tester.widget<Opacity>(preview).opacity, lessThan(0.5));
    expect(find.ancestor(of: preview, matching: find.byType(IgnorePointer)), findsWidgets);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel(RegExp('qm list')), findsNothing);
    // The card's title is a heading.
    expect(tester.getSemantics(k('locked-title')).flagsCollection.isHeader, isTrue);
    semantics.dispose();
    // Centred on the page.
    final card = tester.getRect(k('locked-card'));
    final page = tester.getRect(locked);
    expect((card.center.dx - page.center.dx).abs(), lessThan(2));
    expect(card.width, lessThanOrEqualTo(468));

    // Get Squeezed opens the app's purchase page.
    await tester.tap(k('locked-buy'));
    await tester.pump();
    expect(bought, 1);
    // Restore purchases is the app's one restore.
    await tester.tap(k('locked-restore'));
    await tester.pump();
    expect(restored, 1);
    // What is Squeezed? and the Squeezed tag open the plan popover.
    await tester.tap(k('locked-what-is'));
    await tester.pumpAndSettle();
    expect(k('plan-popover'), findsOneWidget);
    expect(find.text(en.planPopoverTitle(en.narrowSidebarTierFree)), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await tester.tap(k('plan-chip-squeezed'));
    await tester.pumpAndSettle();
    expect(k('plan-popover'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await close(tester);
  });

  testWidgets('with Squeezed, History is the page itself', (tester) async {
    await pump(tester, const HistoryView(), pro: true);
    expect(locked, findsNothing);
    expect(find.text(en.cmdhNoHistoryTitle), findsOneWidget);
    await close(tester);
  });

  testWidgets("a phone's History before Squeezed: the same card over its list, its links 48 high to a thumb",
      (tester) async {
    debugTouchLayout = true;
    await pump(tester, const CommandHistoryScreen(), size: const Size(390, 844));
    expect(locked, findsOneWidget);
    expect(find.text(en.lockedHistoryTitle), findsOneWidget);
    expect(find.descendant(of: k('locked-preview'), matching: find.text('redis-cli info memory')), findsOneWidget);
    for (final key in ['locked-buy', 'locked-what-is', 'locked-restore', 'plan-chip-squeezed']) {
      expect(tester.getSize(k(key)).height, greaterThanOrEqualTo(48), reason: key);
    }
    // Nothing runs over at a phone's width.
    expect(tester.takeException(), isNull);
    final card = tester.getRect(k('locked-card'));
    expect(card.left, greaterThanOrEqualTo(16));
    expect(card.right, lessThanOrEqualTo(390 - 16));
    await tester.tap(k('locked-restore'));
    await tester.pump();
    expect(restored, 1);
    await close(tester);
  });

  testWidgets('Workflows before Squeezed: made-up workflows behind what they give, and no New workflow',
      (tester) async {
    await pump(tester, const WorkflowListScreen(), size: const Size(390, 844));
    expect(locked, findsOneWidget);
    expect(find.text(en.lockedWorkflowsTitle), findsOneWidget);
    for (final b in [en.lockedWorkflowsSteps, en.lockedWorkflowsFrom, en.lockedWorkflowsNotify]) {
      expect(find.text(b), findsOneWidget, reason: b);
    }
    expect(find.descendant(of: k('locked-preview'), matching: find.text('Restart a container')), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    expect(find.text('Workflows are a Squeezed feature'), findsNothing);
    await close(tester);

    await pump(tester, const WorkflowListScreen(), pro: true, size: const Size(390, 844));
    expect(locked, findsNothing);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await close(tester);
  });

  testWidgets("Android's Scheduled tasks before Squeezed: made-up tasks behind what they give", (tester) async {
    ScheduledTasksScreen.debugHere = ScheduledTasksHere.android;
    await pump(tester, const ScheduledTasksScreen(), size: const Size(390, 844));
    expect(locked, findsOneWidget);
    expect(find.text(en.lockedScheduledTitle), findsOneWidget);
    for (final b in [en.lockedScheduledTimer, en.lockedScheduledBackground, en.lockedScheduledLastRun]) {
      expect(find.text(b), findsOneWidget, reason: b);
    }
    expect(find.text(en.lockedScheduledComputer), findsNothing);
    expect(find.descendant(of: k('locked-preview'), matching: find.text('Nightly backup')), findsOneWidget);
    // Made-up tasks need no key.
    expect(find.text(en.schedTaskNeedsApiKey), findsNothing);
    expect(find.text('Squeezed required'), findsNothing);
    await close(tester);
  });

  testWidgets("a computer's Scheduled tasks before Squeezed: the same page, its tasks run while ZestSSH is open (4.0)",
      (tester) async {
    ScheduledTasksScreen.debugHere = ScheduledTasksHere.computer;
    await pump(tester, const ScheduledTasksScreen());
    expect(locked, findsOneWidget);
    expect(find.text(en.lockedScheduledTitle), findsOneWidget);
    for (final b in [en.lockedScheduledTimer, en.lockedScheduledComputer, en.lockedScheduledLastRun]) {
      expect(find.text(b), findsOneWidget, reason: b);
    }
    // Nothing of a phone's background, nor a way to make a task before it is bought.
    expect(find.text(en.lockedScheduledBackground), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    await close(tester);
  });

  testWidgets('every locked title and benefit is in every language, Squeezed kept as it is', (tester) async {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final title in [l.lockedHistoryTitle, l.lockedWorkflowsTitle, l.lockedScheduledTitle]) {
        expect(title, contains('Squeezed'), reason: '$locale');
      }
      expect(l.lockedGetPlanOnce('Squeezed', r'$9.99'), allOf(contains('Squeezed'), contains(r'$9.99')),
          reason: '$locale');
      for (final s in [
        l.lockedHistorySearch,
        l.lockedHistoryRunAgain,
        l.lockedHistorySecrets,
        l.lockedWorkflowsSteps,
        l.lockedWorkflowsFrom,
        l.lockedWorkflowsNotify,
        l.lockedScheduledTimer,
        l.lockedScheduledBackground,
        l.lockedScheduledLastRun,
        l.lockedBoughtAlready,
      ]) {
        expect(s, isNotEmpty, reason: '$locale');
        expect(s.contains('\u2014') || s.contains('\u2013'), isFalse, reason: '$locale: $s');
        if (locale.languageCode != 'en') expect(s, isNot(en.lockedHistorySearch), reason: '$locale');
      }
    }
  });

  // The 4.0 accessibility pass: a page locked to the
  // plan holds to the checks every screen of the pass does.
  testWidgets('a locked page: names, targets, contrast (the 4.0 accessibility pass)', (tester) async {
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final failures = <String>[];
      for (final (name, screen) in [('history', const HistoryView()), ('workflows', const WorkflowListScreen())]) {
        await pump(tester, screen);
        failures.addAll(await a11yCheck(tester, computer: true, where: 'locked $name'));
      }
      expect(failures, isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await close(tester);
  });

  // A build made without ZEST_OFFICIAL=true has no plans to buy: the locked page says so and
  // offers nothing (no price, no chip, no restore).
  testWidgets('a community build: the locked page says there are no plans to buy here, with nothing to press',
      (tester) async {
    debugZestOfficial = false;
    addTearDown(() => debugZestOfficial = true);
    final handle = tester.ensureSemantics();
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pump(tester, const HistoryView());
      expect(locked, findsOneWidget);
      expect(find.text(en.lockedHistoryTitle), findsOneWidget);
      expect(k('locked-no-plans'), findsOneWidget);
      expect(find.text(en.noPlansBody), findsOneWidget);
      for (final key in ['locked-buy', 'locked-what-is', 'locked-restore', 'plan-chip-squeezed']) {
        expect(k(key), findsNothing, reason: key);
      }
      expect(await a11yCheck(tester, computer: true, where: 'locked history, community'), isEmpty);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      handle.dispose();
    }
    await close(tester);
  });
}
