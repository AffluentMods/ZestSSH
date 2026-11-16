import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/screens/desktop/widgets/tree_selector.dart';

/// The 3.0 title bar: the broadcasting chip, and the space button's sync
/// glyph.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget child, {
    SyncHealthState? health,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      currentUserProvider.overrideWith((_) => null),
      if (health != null) syncHealthProvider.overrideWithValue(health),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Center(child: child)),
      ),
    ));
    await tester.pump();
    return container;
  }

  group('broadcasting chip', () {
    testWidgets('hidden until broadcast is on', (tester) async {
      await pump(tester, const BroadcastingChip());
      expect(find.byKey(const ValueKey('pill-broadcasting')), findsNothing);
    });

    /// A tab of [sessions], each in a pane of its own. It is the tab in front.
    String joined(ProviderContainer c, List<String> sessions) {
      final tabs = c.read(workTabsProvider.notifier);
      final first = tabs.createTab(sessions.first);
      for (final s in sessions.skip(1)) {
        tabs.mergeTabs(tabs.createTab(s), first);
      }
      tabs.setActiveTab(first);
      return first;
    }

    testWidgets('says how many terminals get the typing, and a click stops it',
        (tester) async {
      final c = await pump(tester, const BroadcastingChip());
      final tab = joined(c, ['a', 'b', 'c']);
      expect(c.read(broadcastModeProvider.notifier).startTab(tab), isTrue);
      await tester.pump();
      expect(find.text('Broadcasting to 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pill-broadcasting')));
      await tester.pump();
      expect(c.read(broadcastModeProvider).broadcasts(tab), isFalse);
      expect(find.text('Broadcasting to 3'), findsNothing);
    });

    testWidgets('counts the terminals that take part, not the ones left out',
        (tester) async {
      final c = await pump(tester, const BroadcastingChip());
      final tab = joined(c, ['a', 'b', 'c']);
      c.read(broadcastModeProvider.notifier)
        ..startTab(tab)
        ..setReceiving(tab, 'c', false);
      await tester.pump();
      expect(find.text('Broadcasting to 2'), findsOneWidget);
    });

    testWidgets('is about the tab in front: another tab that broadcasts does not show it, and a click stops only this one',
        (tester) async {
      final c = await pump(tester, const BroadcastingChip());
      final one = joined(c, ['a', 'b']);
      final two = joined(c, ['c', 'd', 'e']);
      final n = c.read(broadcastModeProvider.notifier);
      n.startTab(one);
      await tester.pump();
      expect(find.byKey(const ValueKey('pill-broadcasting')), findsNothing,
          reason: 'the tab in front does not broadcast');
      n.startTab(two);
      await tester.pump();
      expect(find.text('Broadcasting to 3'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pill-broadcasting')));
      await tester.pump();
      expect(c.read(broadcastModeProvider).broadcasts(two), isFalse);
      expect(c.read(broadcastModeProvider).broadcasts(one), isTrue);
      c.read(workTabsProvider.notifier).setActiveTab(one);
      await tester.pump();
      expect(find.text('Broadcasting to 2'), findsOneWidget);
    });
  });

  group('space sync glyph', () {
    testWidgets('a Tree that does not sync shows no glyph (a choice, not a fault)',
        (tester) async {
      await pump(tester, const TreeSelector(),
          health: const SyncHealthState(SyncHealth.off));
      expect(find.byKey(const ValueKey('space-sync-glyph')), findsNothing);
    });

    testWidgets('an up-to-date Tree shows a glyph that says so', (tester) async {
      await pump(tester, const TreeSelector(),
          health: SyncHealthState(SyncHealth.upToDate,
              confirmedAt: DateTime(2026, 9, 24, 21)));
      expect(find.byKey(const ValueKey('space-sync-glyph')), findsOneWidget);
      expect(find.byTooltip('Synced'), findsOneWidget);
    });

    testWidgets('a failing Tree says what went wrong', (tester) async {
      await pump(tester, const TreeSelector(),
          health: const SyncHealthState(SyncHealth.failing,
              problem: 'The server said no'));
      expect(find.byKey(const ValueKey('space-sync-glyph')), findsOneWidget);
      expect(find.byTooltip('The server said no'), findsOneWidget);
    });

    testWidgets('a failing Tree the app syncs again by itself says that too', (tester) async {
      await pump(tester, const TreeSelector(),
          health: const SyncHealthState(SyncHealth.failing,
              problem: 'The sync server refused the connection.', retrying: true));
      expect(
          find.byTooltip('The sync server refused the connection. ZestSSH keeps trying by itself.'), findsOneWidget);
    });

    testWidgets('a Tree whose person paused sync says so, in amber', (tester) async {
      await pump(tester, const TreeSelector(),
          health: const SyncHealthState(SyncHealth.paused, pause: SyncPause()));
      expect(find.byTooltip('Sync paused'), findsOneWidget);
      final glyph = tester.widget<Icon>(find.byKey(const ValueKey('space-sync-glyph')));
      expect(glyph.color, AppColors.v3Warning);
    });
  });

  test('desktop terminals start 8px from the pane edge', () async {
    SharedPreferences.setMockInitialValues({});
    final p = await SharedPreferences.getInstance();
    expect(SettingsService(p).terminalMargin, 8.0);
    await p.setDouble('terminal_margin', 0);
    expect(SettingsService(p).terminalMargin, 0.0,
        reason: 'a margin someone chose is kept');
  });
}
