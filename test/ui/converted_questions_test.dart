import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Thirty yes/no questions became the app's own confirm dialog (3.0 UI, step
/// 12). Each kept its title, its sentence, its buttons and what a yes does.
/// Two of them are held here on their real screens, over a database in
/// memory: a question that removes one thing from a list, and one that
/// clears a list. (That none of the plain shape is left is held by
/// plain_questions_test.dart.)
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// [screen] on a computer's window (a question is a dialog there), over a
  /// database that [seed] filled.
  Future<void> pump(WidgetTester tester, Widget screen, Future<void> Function(AppDatabase db) seed) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await seed(db);
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      // Command history is a paid feature: its page has its menu for one who has it.
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: screen,
      ),
    ));
    await settle(tester);
  }

  /// Takes the screen down and lets the timers its providers started run out.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  }

  Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('Trusted host keys: removing one asks in the dialog of the app, naming the host; Cancel and a question '
      'that was left remove nothing, Remove removes that key and no other', (tester) async {
    final now = DateTime.utc(2026, 9, 24);
    await pump(tester, const KnownHostsScreen(), (db) async {
      for (final (id, host) in [('k1', '192.168.10.21'), ('k2', '192.168.10.31')]) {
        await db.knownHostsDao.upsertHost(KnownHostsCompanion.insert(
          id: id,
          host: host,
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:demoFingerprintOf$id',
          publicKeyBase64: 'AAAAC3NzaC1lZDI1NTE5AAAAIDemoKey$id',
          firstSeen: now,
          lastSeen: now,
        ));
      }
    });
    Future<Set<String>> keys() async =>
        {for (final k in (await tester.runAsync(() => db.select(db.knownHosts).get()))!) k.id};
    expect(await keys(), {'k1', 'k2'});
    final remove = find.byTooltip(en.knownHostsRemoveHostKeyTooltip);
    expect(remove, findsNWidgets(2));

    await tester.tap(remove.first);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inQuestion(en.knownHostsRemoveHostKeyTitle), findsOneWidget);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    final said = tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).body;
    expect(said, anyOf(contains('192.168.10.21'), contains('192.168.10.31')), reason: 'the host is named');
    final first = said.contains('192.168.10.21') ? 'k1' : 'k2';
    expect(await keys(), {'k1', 'k2'}, reason: 'not before the answer');

    await tester.tap(inQuestion(en.cancel));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await keys(), {'k1', 'k2'});

    await tester.tap(remove.first);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await keys(), {'k1', 'k2'});

    await tester.tap(remove.first);
    await settle(tester);
    await tester.tap(inQuestion(en.commonRemove));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await keys(), {'k1', 'k2'}.difference({first}));
    await unmount(tester);
  });

  testWidgets('Command history: Clear all asks in the dialog of the app; Cancel keeps the history, Clear all empties it',
      (tester) async {
    final at = DateTime.utc(2026, 9, 24, 10);
    await pump(tester, const CommandHistoryScreen(), (db) async {
      for (var i = 0; i < 3; i++) {
        await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(
              id: 'h$i',
              command: 'uptime $i',
              createdAt: at.add(Duration(minutes: i)),
            ));
      }
    });
    Future<int> count() async => (await tester.runAsync(() => db.select(db.commandHistory).get()))!.length;
    expect(await count(), 3);

    Future<void> askToClear() async {
      final menu = find.byType(PopupMenuButton<String>);
      if (menu.evaluate().isNotEmpty) {
        await tester.tap(menu.first);
        await settle(tester);
        await tester.tap(find.text(en.commonClearAll).last);
      } else {
        await tester.tap(find.byTooltip(en.commonClearAll).first);
      }
      await settle(tester);
    }

    await askToClear();
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inQuestion(en.cmdhClearDialogTitle), findsOneWidget);
    expect(inQuestion(en.cmdhClearDialogBody), findsOneWidget);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    await tester.tap(inQuestion(en.cancel));
    await settle(tester);
    expect(await count(), 3);

    await askToClear();
    await tester.tap(inQuestion(en.commonClearAll));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await count(), 0);
    await unmount(tester);
  });

  // (3.0: one of ten plain dialogs the first check could not
  // see, as its yes acted in its button.)
  testWidgets('Automation history: Clear all asks in the dialog of the app; Cancel keeps the runs, Clear all empties it',
      (tester) async {
    final at = DateTime.utc(2026, 10, 17, 1);
    await pump(tester, const AutomationHistoryScreen(), (db) async {
      for (var i = 0; i < 2; i++) {
        await db.into(db.automationHistory).insert(AutomationHistoryCompanion.insert(
              id: 'run$i',
              timestamp: at.add(Duration(minutes: i)),
              action: 'execute',
              connectionId: 'c$i',
              command: 'uptime',
              success: true,
              elapsedMs: 120,
            ));
      }
    });
    Future<int> count() async => (await tester.runAsync(() => db.select(db.automationHistory).get()))!.length;
    expect(await count(), 2);

    await tester.tap(find.byTooltip(en.commonClearAll));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inQuestion(en.automationHistoryClearDialogTitle), findsOneWidget);
    expect(inQuestion(en.automationHistoryClearDialogMessage), findsOneWidget);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    await tester.tap(inQuestion(en.cancel));
    await settle(tester);
    expect(await count(), 2);

    await tester.tap(find.byTooltip(en.commonClearAll));
    await settle(tester);
    await tester.tap(inQuestion(en.automationHistoryClearAllButton));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await count(), 0);
    await unmount(tester);
  });
}
