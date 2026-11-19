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
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Deleting a host from its editor (3.0: a plain dialog made the
/// app's own). The editor asks first; only Delete deletes.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late int closed;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The editor of the saved host web-01.
  Future<void> openEditor(WidgetTester tester) async {
    // A new editor each time: one that is on screen from before is taken down first.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 2));
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.utc(2026, 9, 24);
    for (final (id, label, host) in [('web', 'web-01', '192.168.10.21'), ('db', 'db-primary', '192.168.10.31')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: const Value(22),
            createdAt: now,
            updatedAt: now,
          ));
    }
    closed = 0;
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ConnectionEditScreen(
            inDialog: true,
            connectionId: 'web',
            onClose: () => closed++,
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<Set<String>> hosts(WidgetTester tester) async =>
      {for (final c in (await tester.runAsync(() => db.connectionsDao.getAll()))!) c.id};

  Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

  testWidgets('closing the editor with a change not saved asks in the dialog of the app: Cancel keeps the editor '
      'open, Discard closes it and saves nothing, Save saves and closes', (tester) async {
    Future<String> label() async =>
        (await tester.runAsync(() => db.connectionsDao.getAll()))!.singleWhere((c) => c.id == 'web').label;
    final shell = find.byType(ZestDialogShell);
    Finder inShell(String text) => find.descendant(of: shell, matching: find.text(text));

    await openEditor(tester);
    // Nothing changed: the editor closes with no question.
    await tester.tap(find.byTooltip(en.close));
    await settle(tester);
    expect(shell, findsNothing);
    expect(closed, 1);

    await openEditor(tester);
    final name = find.widgetWithText(TextField, 'web-01');
    expect(name, findsOneWidget);
    await tester.enterText(name, 'web-renamed');
    await settle(tester);
    await tester.tap(find.byTooltip(en.close));
    await settle(tester);
    expect(shell, findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inShell(en.zestDiscardTitle), findsOneWidget);
    expect(inShell(en.zestDiscardBody), findsOneWidget);

    // Cancel: the editor stays, with what was typed.
    await tester.tap(inShell(en.zestDiscardCancel));
    await settle(tester);
    expect(shell, findsNothing);
    expect(closed, 0);
    expect(find.widgetWithText(TextField, 'web-renamed'), findsOneWidget);
    expect(await label(), 'web-01');

    // Discard: closed, nothing saved.
    await tester.tap(find.byTooltip(en.close));
    await settle(tester);
    await tester.tap(inShell(en.zestDiscardDiscard));
    await settle(tester);
    expect(closed, 1);
    expect(await label(), 'web-01');

    // Save: saved and closed.
    await openEditor(tester);
    await tester.enterText(find.widgetWithText(TextField, 'web-01'), 'web-renamed');
    await settle(tester);
    await tester.tap(find.byTooltip(en.close));
    await settle(tester);
    await tester.tap(inShell(en.zestDiscardSave));
    await settle(tester);
    expect(shell, findsNothing);
    expect(await label(), 'web-renamed');
    expect(closed, 1);
    // (Saving starts timers of its own: a notice, the sync that follows a change.)
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 10));
  });

  testWidgets('the editor asks before it deletes a host, in the dialog of the app; Cancel deletes nothing and the '
      'editor stays, Delete deletes that host and no other and closes the editor', (tester) async {
    await openEditor(tester);
    expect(await hosts(tester), {'web', 'db'});
    // Delete is in Advanced, away from close.
    expect(find.byTooltip(en.delete), findsNothing);
    await tester.tap(find.text(en.connectionEditRailAdvanced).first);
    await settle(tester);
    final delete = find.byKey(const ValueKey('host-edit-delete'));
    await tester.ensureVisible(delete);
    await settle(tester);

    await tester.tap(delete);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inQuestion(en.connectionDeleteTitle), findsOneWidget);
    expect(inQuestion(en.connectionDeleteMsg), findsOneWidget);
    expect(tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog)).tone, ZestDialogTone.destructive);
    expect(await hosts(tester), {'web', 'db'}, reason: 'not before the answer');

    await tester.tap(inQuestion(en.cancel));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await hosts(tester), {'web', 'db'});
    expect(closed, 0, reason: 'the editor stays open');

    // A question that was left is no yes either.
    await tester.tap(delete);
    await settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await hosts(tester), {'web', 'db'});
    expect(closed, 0);

    await tester.tap(delete);
    await settle(tester);
    await tester.tap(inQuestion(en.delete));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(await hosts(tester), {'db'});
    expect(closed, 1, reason: 'the editor of a host that is gone closes');
  });
}
