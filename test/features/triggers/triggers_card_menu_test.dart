import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/triggers_view.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../../helpers/desktop_mouse.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';

/// The menus of a trigger card on a computer: the three dots that show while
/// the mouse is over the card, and the right click. The same three actions,
/// and each does what it says from either.
///
/// The three dots had the fault of the snippet cards (a bug in 2.2.1):
/// they left while their own menu was open, and with them went every pick.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late AppLocalizations l10n;
  late SharedPreferences prefs;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  tearDown(() async {
    await db.close();
  });

  Future<List<TerminalTrigger>> seed(WidgetTester tester) async {
    final rows = await tester.runAsync(() async {
      for (final (id, name, pattern) in [
        ('t1', 'Failures', 'error|failed'),
        ('t2', 'Out of disk', 'No space left on device'),
      ]) {
        await db.terminalTriggersDao.upsert(TerminalTriggersCompanion.insert(
          id: id,
          name: name,
          pattern: pattern,
          enabled: const Value(true),
          createdAt: DateTime(2026, 10, 2),
        ));
      }
      return db.terminalTriggersDao.getAll();
    });
    return rows!;
  }

  Future<void> pumpPage(
      WidgetTester tester, List<TerminalTrigger> triggers) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        triggerRuntimeProvider.overrideWith((ref) {
          final rt = TriggerRuntime.forTesting(ref);
          ref.onDispose(rt.dispose);
          return rt;
        }),
        // Held still: the test reads the database for what an action did.
        triggersProvider.overrideWith((ref) => Stream.value(triggers)),
        triggerScopeConnectionsProvider
            .overrideWith((ref) => Stream.value(const <Connection>[])),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: TriggersView()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  Finder dots() => find.byType(MenuDotsButton);
  Finder item(String label) => find.widgetWithText(PopupMenuItem<String>, label);
  Finder inConfirm(String label) => find.descendant(
      of: find.byType(ZestConfirmDialog), matching: find.text(label));
  const away = Offset(1390, 890);

  Future<TestMouse> openDots(WidgetTester tester, String card) async {
    final mouse = TestMouse(tester);
    expect(dots(), findsNothing, reason: 'the dots only show under the mouse');
    await mouse.moveOver(find.text(card));
    expect(dots(), findsOneWidget);
    await mouse.click(dots());
    expect(item(l10n.delete), findsOneWidget);
    return mouse;
  }

  Future<TestMouse> openRightClick(WidgetTester tester, String card) async {
    final mouse = TestMouse(tester);
    await mouse.rightClick(find.text(card));
    expect(item(l10n.delete), findsOneWidget);
    return mouse;
  }

  Future<Map<String, bool>> inDatabase(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.terminalTriggersDao.getAll());
    return {for (final t in rows!) t.name: t.enabled};
  }

  for (final (way, open) in [
    ('the three dots', openDots),
    ('a right click', openRightClick),
  ]) {
    group('From $way', () {
      desktopTest('Edit opens the trigger in the editor', (tester) async {
        await pumpPage(tester, await seed(tester));
        expect(find.widgetWithText(TextField, 'error|failed'), findsNothing);
        expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsOneWidget,
            reason: 'the editor starts on a new trigger');

        final mouse = await open(tester, 'Failures');
        await mouse.click(item(l10n.edit));

        expect(find.widgetWithText(TextField, 'error|failed'), findsOneWidget,
            reason: 'the editor holds the pattern of the trigger picked');
        expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsNothing);
        await closePage(tester);
      });

      desktopTest('Disable switches the trigger off', (tester) async {
        await pumpPage(tester, await seed(tester));

        final mouse = await open(tester, 'Failures');
        await mouse.click(item(l10n.commonDisable));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(await inDatabase(tester), {'Failures': false, 'Out of disk': true});
        await closePage(tester);
      });

      desktopTest('Delete asks first, and deletes when confirmed',
          (tester) async {
        await pumpPage(tester, await seed(tester));

        final mouse = await open(tester, 'Out of disk');
        await mouse.click(item(l10n.delete));

        expect(find.byType(ZestConfirmDialog), findsOneWidget,
            reason: 'Delete asks before it deletes');
        expect(find.text(l10n.trgDeleteConfirm('Out of disk')), findsOneWidget);
        expect(await inDatabase(tester), hasLength(2),
            reason: 'nothing is deleted before the answer');

        await tester.tap(inConfirm(l10n.delete));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(await inDatabase(tester), {'Failures': true});
        await closePage(tester);
      });

      desktopTest('Delete that is not confirmed deletes nothing',
          (tester) async {
        await pumpPage(tester, await seed(tester));

        final mouse = await open(tester, 'Out of disk');
        await mouse.click(item(l10n.delete));
        await tester.tap(inConfirm(l10n.cancel));
        await tester.pumpAndSettle();

        expect(find.byType(ZestConfirmDialog), findsNothing);
        expect(await inDatabase(tester), hasLength(2));
        await closePage(tester);
      });

      desktopTest('closing the menu without a pick does nothing',
          (tester) async {
        await pumpPage(tester, await seed(tester));

        final mouse = await open(tester, 'Failures');
        await mouse.clickAt(away);

        expect(item(l10n.delete), findsNothing);
        expect(find.byType(ZestConfirmDialog), findsNothing);
        expect(find.descendant(of: find.byType(ZestDetailScaffold), matching: find.text(l10n.trgNewTrigger)), findsOneWidget,
            reason: 'the editor is still on a new trigger');
        expect(await inDatabase(tester), {'Failures': true, 'Out of disk': true});
        await closePage(tester);
      });
    });
  }

  desktopTest('the three dots stay while their menu is open, and go after',
      (tester) async {
    await pumpPage(tester, await seed(tester));

    final mouse = await openDots(tester, 'Failures');
    expect(dots(), findsOneWidget,
        reason: 'the menu covers the card, the dots it came from stay');

    await mouse.clickAt(away);
    expect(item(l10n.delete), findsNothing);
    expect(dots(), findsNothing);
    await closePage(tester);
  });

  desktopTest('both menus hold the same actions in the same order',
      (tester) async {
    await pumpPage(tester, await seed(tester));

    List<String> shown() => [
          for (final e in tester.widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>)))
            e.value!,
        ];

    final mouse = await openDots(tester, 'Failures');
    final fromDots = shown();
    await mouse.clickAt(away);

    await openRightClick(tester, 'Failures');
    expect(fromDots, ['edit', 'toggle', 'delete']);
    expect(shown(), fromDots);
    await tester.tapAt(away);
    await tester.pumpAndSettle();
    await closePage(tester);
  });
}
