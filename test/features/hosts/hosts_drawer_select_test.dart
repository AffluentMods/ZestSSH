import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/workspaces/models/workspace_view.dart';
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show hostPanelWidthProvider;
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/host_slide_out_panel.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The Hosts drawer (Ctrl+Shift+H): hosts can be
/// dragged from it into groups, and selected and bulk edited from
/// there too. The same selection as the
/// Hosts page, its keys, dragging into a group or out of one, and the bulk
/// actions at the drawer's foot.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;
  late List<String> connected;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 120));
    }
  }

  Future<void> pump(WidgetTester tester, {List<WorkspaceView> workspaces = const []}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final at = DateTime(2026, 10, 22);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'nodes', name: 'Nodes', createdAt: at));
    for (var i = 1; i <= 5; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: 'host-$i',
            host: '10.0.0.$i',
            groupId: Value(i <= 2 ? 'nodes' : null),
            sortOrder: Value(i),
            createdAt: at,
            updatedAt: at,
          ));
    }
    connected = [];
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      // Wide enough for its header in the test's font (every letter a square).
      hostPanelWidthProvider.overrideWith((ref) => 440),
      if (workspaces.isNotEmpty) workspacesProvider.overrideWithValue(workspaces),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Row(children: [
            HostSlideOutPanel(onConnectTo: (c) => connected.add(c.connection.id), onManageHosts: () {}, onClose: () {}),
            const Expanded(child: SizedBox()),
          ]),
        ),
      ),
    ));
    await settle(tester);
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder row(String id) => find.byKey(ValueKey('drawer-row-$id'));
  Finder header(String id) => find.byKey(ValueKey('drawer-group-$id'));
  Set<String> selected() => container.read(hostMultiSelectProvider).selected;
  Future<String?> groupOf(WidgetTester tester, String id) async =>
      (await tester.runAsync(() => db.connectionsDao.getById(id)))!.groupId;

  Future<void> clickWith(WidgetTester tester, Finder target, List<LogicalKeyboardKey> keys) async {
    for (final k in keys) {
      await tester.sendKeyDownEvent(k);
    }
    await tester.tap(target, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 200));
    for (final k in keys.reversed) {
      await tester.sendKeyUpEvent(k);
    }
    await tester.pump();
  }

  Future<void> drag(WidgetTester tester, Finder from, Finder to) async {
    final g = await tester.startGesture(tester.getCenter(from), kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(milliseconds: 50));
    await g.moveBy(const Offset(0, 12));
    await tester.pump();
    await g.moveTo(tester.getCenter(to));
    await tester.pump();
    await g.up();
    await settle(tester);
  }

  testWidgets("a workspace's name has its line to itself, its tabs and panes under it", (tester) async {
    await pump(tester, workspaces: const [
      WorkspaceView(
        id: 'w1',
        name: 'Database night',
        tabCount: 1,
        paneCount: 2,
        memberHosts: [],
        lastOpened: null,
        launchShortcutIndex: 0,
        panePreview: [],
      ),
    ]);
    final name = find.byKey(const ValueKey('workspace-drawer-name'));
    final counts = find.byKey(const ValueKey('workspace-drawer-counts'));
    expect(find.text('1 tab · 2 panes'), findsOneWidget);
    expect(tester.getRect(counts).top, greaterThanOrEqualTo(tester.getRect(name).bottom));
    // Whole: it was cut to "Databa…" by the counts beside it (found in a design
    // review).
    final drawn = tester.renderObject<RenderParagraph>(find.descendant(of: name, matching: find.byType(RichText)));
    expect(drawn.didExceedMaxLines, isFalse);
    await finish(tester);
  });

  testWidgets('a host dragged onto a group header goes into that group, onto Ungrouped out of it', (tester) async {
    await pump(tester);
    await drag(tester, row('h4'), header('nodes'));
    expect(await groupOf(tester, 'h4'), 'nodes');
    await drag(tester, row('h1'), header('__ungrouped__'));
    expect(await groupOf(tester, 'h1'), isNull);
    expect(connected, isEmpty, reason: 'a drag is not a click');
    await finish(tester);
  });

  testWidgets('dropped on a host of a group, it goes into that host\'s group', (tester) async {
    await pump(tester);
    await drag(tester, row('h5'), row('h2'));
    expect(await groupOf(tester, 'h5'), 'nodes');
    await finish(tester);
  });

  testWidgets('Ctrl-click and Shift-click select in the drawer\'s order, and do not connect; Escape ends it',
      (tester) async {
    await pump(tester);
    await clickWith(tester, row('h1'), [LogicalKeyboardKey.controlLeft]);
    expect(selected(), {'h1'});
    // The drawer's order: Nodes (h1, h2), then the hosts in none (h3..h5).
    await clickWith(tester, row('h4'), [LogicalKeyboardKey.shiftLeft]);
    expect(selected(), {'h1', 'h2', 'h3', 'h4'});
    await clickWith(tester, row('h2'), []);
    expect(selected(), {'h1', 'h3', 'h4'}, reason: 'a plain click in selection mode toggles');
    expect(connected, isEmpty);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(selected(), {'h1', 'h2', 'h3', 'h4', 'h5'});
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(container.read(hostMultiSelectProvider).active, isFalse);
    // Out of selection mode a plain click connects, as it always did.
    await clickWith(tester, row('h3'), []);
    expect(connected, ['h3']);
    await finish(tester);
  });

  testWidgets('a selected host dragged takes the selection with it, and says how many moved', (tester) async {
    await pump(tester);
    await clickWith(tester, row('h3'), [LogicalKeyboardKey.controlLeft]);
    await clickWith(tester, row('h5'), [LogicalKeyboardKey.controlLeft]);
    await drag(tester, row('h3'), header('nodes'));
    expect(await groupOf(tester, 'h3'), 'nodes');
    expect(await groupOf(tester, 'h5'), 'nodes');
    expect(await groupOf(tester, 'h4'), isNull);
    expect(find.text(l10n.hostsSelMovedToast(2, 'Nodes')), findsOneWidget);
    await finish(tester);
  });

  testWidgets('the foot offers the bulk actions while hosts are selected: Open, Move, Pin, and the rest in ⋯',
      (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('host-bulk-actions-compact')), findsNothing);
    await clickWith(tester, row('h3'), [LogicalKeyboardKey.controlLeft]);
    await clickWith(tester, row('h4'), [LogicalKeyboardKey.controlLeft]);
    await settle(tester);
    final bar = find.byKey(const ValueKey('host-bulk-actions-compact'));
    expect(bar, findsOneWidget);
    for (final t in [l10n.hostBulkActionSelectedCount(2), l10n.hostsSelOpen, l10n.hostBulkActionMoveToGroup, l10n.hostsHomeMenuPin]) {
      expect(find.descendant(of: bar, matching: find.text(t)), findsOneWidget, reason: t);
    }
    await tester.tap(find.descendant(of: bar, matching: find.byKey(const ValueKey('bulk-pin'))));
    await settle(tester);
    expect(container.read(pinnedHostsProvider), containsAll(['h3', 'h4']));
    await clickWith(tester, row('h1'), [LogicalKeyboardKey.controlLeft]);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('bulk-more')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    for (final t in [l10n.hostBulkActionAddTag, l10n.zestHostFieldColor, l10n.hostIconColorLabel, l10n.hostsSelSaveWorkspace, l10n.delete]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('one selection, one bar: a selection made on the Hosts page shows no bar in the drawer, one made in '
      'the drawer does', (tester) async {
    // Both showed a bar for the one selection.
    await pump(tester);
    container.read(hostSelectionPlaceProvider.notifier).state = HostSelectionPlace.page;
    container.read(hostMultiSelectProvider.notifier).enter('h3');
    await settle(tester);
    final bar = find.byKey(const ValueKey('host-bulk-actions-compact'));
    expect(bar, findsNothing, reason: "the page's bar is the one");
    await clickWith(tester, row('h4'), [LogicalKeyboardKey.controlLeft]);
    await settle(tester);
    expect(container.read(hostSelectionPlaceProvider), HostSelectionPlace.drawer);
    expect(bar, findsOneWidget, reason: 'a selection changed in the drawer shows its bar');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await finish(tester);
  });
}
