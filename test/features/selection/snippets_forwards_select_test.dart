import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart' show redactionFleetRegistrar;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Selecting snippets and port forwards on a computer (3.4), as the hosts are
/// selected: Select on the page's line, a box on each, the keys that select,
/// and the bar at the list's foot: for snippets Move to category and Delete,
/// for port forwards Start and Stop (the forwards whose host has no session
/// asked about once, for all of them) and Delete.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;
  final at = DateTime(2026, 11, 1);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 25)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> pump(WidgetTester tester, Widget page, {Set<String> running = const {}}) async {
    tester.view.physicalSize = const Size(2000, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.runAsync(() async {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      for (final (id, label, category) in const [
        ('s1', 'Running containers', 'Docker'),
        ('s2', 'Container logs', 'Docker'),
        ('s3', 'Disk usage', 'Files'),
        ('s4', 'Free memory', 'Files'),
      ]) {
        await db.into(db.snippets).insert(SnippetsCompanion.insert(
            id: id, label: label, command: 'echo $id', category: Value(category), createdAt: at, updatedAt: at));
      }
      for (final (id, label) in const [('h1', 'monitoring'), ('h2', 'web-01')]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id, label: label, host: '10.50.0.2${id.substring(1)}', createdAt: at, updatedAt: at));
      }
      for (final (id, host, port) in const [('f1', 'h1', 9090), ('f2', 'h1', 3000), ('f3', 'h2', 8080)]) {
        await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: id,
            connectionId: host,
            type: 'local',
            bindPort: port,
            remoteHost: 'localhost',
            remotePort: port,
            label: Value('rule $port'),
            createdAt: at));
      }
    });
    addTearDown(() => db.close());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      redactionFleetRegistrar.overrideWith((ref) {}),
      activeForwardIdsProvider.overrideWith((ref) => running),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: page),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> click(WidgetTester tester, Finder f, {LogicalKeyboardKey? holding}) async {
    if (holding != null) await tester.sendKeyDownEvent(holding);
    await tester.tap(f, kind: PointerDeviceKind.mouse);
    if (holding != null) await tester.sendKeyUpEvent(holding);
    await settle(tester);
  }

  Future<Map<String, String?>> categories(WidgetTester tester) async =>
      {for (final s in (await tester.runAsync(() => db.select(db.snippets).get()))!) s.id: s.category};

  group('snippets', () {
    Finder row(String id) => find.byKey(ValueKey('snippet-row-$id'));
    Set<String> selected() => container.read(snippetSelectionProvider).selected;

    testWidgets('Select, the clicks and the keys, as the hosts\' (Shift, Ctrl, Ctrl+A, Esc)', (tester) async {
      await pump(tester, const SnippetsLibraryView());
      await click(tester, find.byKey(const ValueKey('snippets-select')));
      expect(find.byKey(const ValueKey('snippet-row-box-s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('snippet-selection-head')), findsOneWidget);
      await click(tester, row('s1'));
      expect(selected(), {'s1'});
      // The order shown: Docker's, then Files'.
      expect(container.read(shownItemIdsProvider('snippet')), ['s2', 's1', 's3', 's4']);
      await click(tester, row('s3'), holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(), {'s1', 's3'});
      await click(tester, row('s4'), holding: LogicalKeyboardKey.controlLeft);
      expect(selected(), {'s1', 's3', 's4'});
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(selected(), {'s1', 's2', 's3', 's4'});
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(container.read(snippetSelectionProvider).active, isFalse);
      await finish(tester);
    });

    testWidgets('Move to category: a new one named, the selected moved there; Delete asks once', (tester) async {
      await pump(tester, const SnippetsLibraryView());
      await click(tester, find.byKey(const ValueKey('snippets-select')));
      await click(tester, row('s1'));
      await click(tester, row('s3'));
      await click(tester, find.byKey(const ValueKey('bulk-category')));
      expect(find.text(l10n.selectCategoryTitle(l10n.transferWhatSnippets(2))), findsOneWidget);
      expect(find.byKey(const ValueKey('select-category-Docker')), findsOneWidget);
      expect(find.byKey(const ValueKey('select-category-none')), findsOneWidget);
      await click(tester, find.byKey(const ValueKey('select-category-new')));
      await tester.enterText(find.byType(TextField).last, 'Ops');
      await click(tester, find.text(l10n.selectCategoryMoveButton));
      expect(await categories(tester), {'s1': 'Ops', 's2': 'Docker', 's3': 'Ops', 's4': 'Files'});
      expect(container.read(snippetSelectionProvider).active, isFalse);

      // No category takes them out of theirs.
      await click(tester, row('s2'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, find.byKey(const ValueKey('bulk-category')));
      await click(tester, find.byKey(const ValueKey('select-category-none')));
      expect((await categories(tester))['s2'], isNull);

      await click(tester, row('s4'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, row('s1'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, find.byKey(const ValueKey('bulk-delete')));
      expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatSnippets(2))), findsOneWidget);
      expect(find.text(l10n.selectDeleteSnippetsBody(2)), findsOneWidget);
      await click(tester, find.byKey(const ValueKey('zest-dialog-primary')));
      expect((await categories(tester)).keys.toSet(), {'s2', 's3'});
      await finish(tester);
    });
  });

  group('port forwards', () {
    Finder card(String id) => find.byKey(ValueKey('pf-rule-$id'));
    Set<String> selected() => container.read(forwardSelectionProvider).selected;

    testWidgets('Select, the clicks and the keys; Start asks once to connect for the forwards with no session',
        (tester) async {
      await pump(tester, const PortForwardListView());
      await click(tester, find.byKey(const ValueKey('forwards-select')));
      expect(find.byKey(const ValueKey('pf-rule-box-f1')), findsOneWidget);
      expect(find.byKey(const ValueKey('forward-selection-head')), findsOneWidget);
      await click(tester, card('f1'));
      await click(tester, card('f3'), holding: LogicalKeyboardKey.shiftLeft);
      expect(selected(), {'f1', 'f2', 'f3'});
      expect(find.byKey(const ValueKey('bulk-stop')), findsOneWidget);
      await click(tester, find.byKey(const ValueKey('bulk-start')));
      // Three forwards on two hosts with no session: one question.
      expect(find.text(l10n.selectForwardsConnectTitle(2)), findsOneWidget);
      expect(find.text(l10n.selectForwardsConnectBody(3)), findsOneWidget);
      await click(tester, find.byKey(const ValueKey('zest-dialog-secondary')));
      expect(find.text(l10n.selectForwardsConnectTitle(2)), findsNothing);
      expect(container.read(forwardSelectionProvider).active, isFalse);
      await finish(tester);
    });

    testWidgets('Stop stops the running ones; Delete asks once for the batch', (tester) async {
      await pump(tester, const PortForwardListView(), running: {'f1', 'f2'});
      await click(tester, card('f1'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, card('f2'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, find.byKey(const ValueKey('bulk-stop')));
      expect(find.text(l10n.selectForwardsStopped(l10n.transferWhatForwards(2))), findsOneWidget);
      expect(container.read(forwardSelectionProvider).active, isFalse);
      await tester.pump(const Duration(seconds: 5));

      await click(tester, card('f2'), holding: LogicalKeyboardKey.controlLeft);
      await click(tester, card('f3'), holding: LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await settle(tester);
      expect(find.text(l10n.selectDeleteTitle(l10n.transferWhatForwards(2))), findsOneWidget);
      await click(tester, find.byKey(const ValueKey('zest-dialog-primary')));
      expect([for (final r in (await tester.runAsync(() => db.select(db.portForwardRules).get()))!) r.id], ['f1']);
      await finish(tester);
    });
  });
}
