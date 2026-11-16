import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/open_selected_hosts.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_bulk_action_bar.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/features/workspaces/widgets/workspace_save_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_theme.dart';

/// The bulk bar's actions, in
/// the bar as remade in 3.4: Open (in tabs, in
/// split panes, within the plan's and a tab's limits; past eight, asked how
/// first), Pin or Unpin and Save as workspace (behind its ⋯), the count's
/// menu, and the hints over the bar.

/// Sessions with no host behind them: one opens as asked, a host open
/// already is that session, and past [limit] new ones nothing opens (the free
/// plan).
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  int? limit;
  final opened = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false, String? usernameOverride, String? initialCommand, String? asAccount, bool unattended = false, Space? space}) {
    for (final e in state.entries) {
      if (e.value.connectionId == connection.id) return e.key;
    }
    if (limit != null && opened.length >= limit!) return null;
    final id = 's-${connection.id}';
    opened.add(id);
    state = {
      ...state,
      id: SessionState(
        status: SessionStatus.connecting,
        connectionId: connection.id,
        connectionLabel: connection.label,
        host: connection.host,
        port: 22,
        session: TerminalSession(
          id: id,
          connectionId: connection.id,
          terminal: Terminal(),
          shell: _Shell(),
          startedAt: DateTime(2026, 10, 22),
        ),
      ),
    };
    return id;
  }
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _loadGeistSans() async {
  final loader = FontLoader('GeistSans');
  for (final w in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
    final bytes = File('assets/fonts/GeistSans-$w.ttf').readAsBytesSync();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load().timeout(const Duration(seconds: 30));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  // The messages shown as on a phone, in the page, where a test finds them.
  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  late AppDatabase db;
  late ProviderContainer container;
  // The order the page shows the hosts in: not the order they were saved.
  const shown = ['h9', 'h3', 'h1', 'h2', 'h4', 'h5', 'h6', 'h7', 'h8', 'h10'];

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 200));
    }
  }

  Future<_Sessions> pump(
    WidgetTester tester, {
    required Set<String> selected,
    bool pro = true,
    double width = 1500,
    Set<String> pinned = const {},
  }) async {
    await tester.runAsync(_loadGeistSans);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    for (var i = 1; i <= 10; i++) {
      await db.connectionsDao.insertConnection(ConnectionsCompanion(
        id: Value('h$i'),
        label: Value('web-$i'),
        host: Value('192.168.10.$i'),
        port: const Value(22),
        protocol: const Value('ssh'),
        pinned: Value(pinned.contains('h$i')),
        createdAt: Value(DateTime.utc(2026)),
        updatedAt: Value(DateTime.utc(2026)),
      ));
    }
    tester.view.physicalSize = Size(width, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(_Sessions.new),
      isProProvider.overrideWith((ref) => _Pro(pro)),
    ]);
    addTearDown(container.dispose);
    container.read(workTabsProvider);
    final select = container.read(hostMultiSelectProvider.notifier)..enter();
    selected.forEach(select.toggle);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomCenter, child: HostBulkActionBar(groups: [], shownOrder: shown)),
        ),
      ),
    ));
    await settle(tester);
    final sessions = container.read(activeSessionsProvider.notifier) as _Sessions;
    if (!pro) sessions.limit = freeSessionLimit;
    return sessions;
  }

  /// Lets a toast close by itself (its timer would outlive the test).
  Future<void> finish(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 12));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  }

  /// Opens the bar's ⋯ and picks the action [key] there.
  Future<void> fromMore(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(const ValueKey('bulk-more')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('bulk-more-$key')));
    await settle(tester);
  }

  Future<void> open(WidgetTester tester, OpenSelectedAs how) async {
    await tester.tap(find.byKey(const ValueKey('bulk-open')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.hostsSelOpenInTabs), findsOneWidget);
    expect(find.text(l10n.hostsSelOpenInPanes), findsOneWidget);
    // The menu opens above the bar, inside the window.
    for (final k in ['bulk-open-tabs', 'bulk-open-panes']) {
      final r = tester.getRect(find.byKey(ValueKey(k)));
      expect(r.top, greaterThanOrEqualTo(0));
      expect(r.bottom, lessThanOrEqualTo(900));
    }
    await tester.tap(find.byKey(ValueKey(how == OpenSelectedAs.tabs ? 'bulk-open-tabs' : 'bulk-open-panes')));
    await settle(tester);
  }

  group('Open', () {
    testWidgets('in tabs: a tab for each host, in the order shown, the last one in front', (tester) async {
      final sessions = await pump(tester, selected: {'h1', 'h2', 'h3'});
      await open(tester, OpenSelectedAs.tabs);
      expect(sessions.opened, ['s-h3', 's-h1', 's-h2']);
      final tabs = container.read(workTabsProvider);
      expect(tabs.tabs, hasLength(3));
      expect([for (final t in tabs.tabs) t.sessionIds], [['s-h3'], ['s-h1'], ['s-h2']]);
      expect(tabs.activeTabId, tabs.tabs.last.id);
      expect(container.read(hostMultiSelectProvider).active, isFalse, reason: 'opened: the selection is done');
      await finish(tester);
    });

    testWidgets('in split panes: one tab, the hosts in its grid, in the order shown', (tester) async {
      final sessions = await pump(tester, selected: {'h4', 'h1', 'h3'});
      await open(tester, OpenSelectedAs.splitPanes);
      expect(sessions.opened, ['s-h3', 's-h1', 's-h4']);
      final tabs = container.read(workTabsProvider);
      expect(tabs.tabs, hasLength(1));
      final tree = tabs.tabs.single.paneTree;
      expect([for (final l in tree.allLeaves) l.sessionIds.single], ['s-h3', 's-h1', 's-h4']);
      expect(isTiled(tree), isTrue, reason: 'the grid a tab nobody arranged stands in');
      await finish(tester);
    });

    testWidgets('past eight it asks how first ("Open 10 sessions?"); in split panes, a tab of panes after another',
        (tester) async {
      final sessions = await pump(tester, selected: {...shown});
      await tester.tap(find.byKey(const ValueKey('bulk-open')));
      await settle(tester);
      expect(find.text(l10n.bulkOpenTitle(10)), findsOneWidget);
      expect(find.text(l10n.hostsSelOpenInTabs), findsNothing, reason: 'the question, not the small menu');
      await tester.tap(find.byKey(const ValueKey('bulk-open-many-panes')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bulk-open-many-go')));
      await settle(tester);
      expect(sessions.opened, hasLength(10), reason: 'every host, none kept back by a tab');
      final tabs = container.read(workTabsProvider).tabs;
      expect([for (final t in tabs) t.paneTree.allLeaves.length], [kHostsSplitMaxPanes, 2]);
      expect([for (final l in tabs.first.paneTree.allLeaves) l.sessionIds.single], [for (final id in shown.take(8)) 's-$id']);
      await finish(tester);
    });

    testWidgets('on the free plan: as many as it opens, and it says which were not opened and why', (tester) async {
      // Two more hosts than the plan opens, h9 left out: in the order shown
      // h3, h1, h2, h4, h5, h6, h7. With 5 on a computer, h3 to h5 open and
      // h6 and h7 do not.
      final picked = [for (final id in shown) if (id != 'h9') id].take(freeSessionLimit + 2).toList();
      final sessions = await pump(tester, selected: picked.toSet(), pro: false);
      await open(tester, OpenSelectedAs.tabs);
      expect(sessions.opened, hasLength(freeSessionLimit));
      expect(container.read(workTabsProvider).tabs, hasLength(freeSessionLimit));
      final keptBack = [for (final id in picked.skip(freeSessionLimit)) 'web-${id.substring(1)}'].join(', ');
      if (freeSessionLimit == 5) expect(keptBack, 'web-6, web-7');
      expect(find.text(l10n.hostsSelNotOpenedPlan(keptBack, freeSessionLimit)), findsOneWidget);
      await finish(tester);
    });
  });

  group('Pin', () {
    testWidgets('pins every selected host', (tester) async {
      await pump(tester, selected: {'h1', 'h2'}, pinned: {'h1'});
      await tester.tap(find.byKey(const ValueKey('bulk-more')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(l10n.hostsHomeMenuPin), findsOneWidget, reason: 'not all are pinned: Pin');
      await tester.tap(find.byKey(const ValueKey('bulk-more-bulk-pin')));
      await settle(tester);
      expect(container.read(pinnedHostsProvider), containsAll(['h1', 'h2']));
      expect(container.read(pinnedHostsProvider), isNot(contains('h3')));
      await finish(tester);
    });

    testWidgets('where all are pinned it is Unpin, and unpins them', (tester) async {
      await pump(tester, selected: {'h1', 'h2'}, pinned: {'h1', 'h2', 'h3'});
      await tester.tap(find.byKey(const ValueKey('bulk-more')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(l10n.hostsHomeMenuUnpin), findsOneWidget);
      expect(find.text(l10n.hostsHomeMenuPin), findsNothing);
      await tester.tap(find.byKey(const ValueKey('bulk-more-bulk-pin')));
      await settle(tester);
      expect(container.read(pinnedHostsProvider), {'h3'});
      await finish(tester);
    });
  });

  testWidgets('Save as workspace: the save dialog, the hosts side by side as its layout; named and saved', (tester) async {
    await pump(tester, selected: {'h2', 'h9', 'h1'});
    await fromMore(tester, 'bulk-save-workspace');
    expect(find.byType(WorkspaceSaveDialog), findsOneWidget);
    // The preview names the hosts, in the order shown, though nothing is open.
    for (final n in ['web-9', 'web-1', 'web-2']) {
      expect(find.descendant(of: find.byType(WorkspaceSaveDialog), matching: find.textContaining(n)), findsWidgets);
    }
    await tester.enterText(find.descendant(of: find.byType(WorkspaceSaveDialog), matching: find.byType(TextField)), 'Web pool');
    await tester.pump();
    await tester.tap(find.descendant(of: find.byType(WorkspaceSaveDialog), matching: find.text(l10n.save)));
    await settle(tester);
    final saved = container.read(savedTabGroupsProvider);
    expect(saved, hasLength(1));
    expect(saved.single.name, 'Web pool');
    final tree = saved.single.tabs.single.paneTreeOfConnIds;
    expect([for (final l in tree.allLeaves) l.sessionIds.single], ['h9', 'h1', 'h2']);
    expect(isTiled(tree), isTrue);
    expect(container.read(hostMultiSelectProvider).active, isFalse);
    await finish(tester);
  });

  group('The count', () {
    testWidgets('offers every host shown, or none', (tester) async {
      await pump(tester, selected: {'h1'});
      await tester.tap(find.byKey(const ValueKey('bulk-count')));
      await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(l10n.hostsSelSelectAll(shown.length)));
      await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(hostMultiSelectProvider).selected, shown.toSet());
      await tester.tap(find.byKey(const ValueKey('bulk-count')));
      await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(l10n.hostsSelSelectNone));
      await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
      expect(container.read(hostMultiSelectProvider).selected, isEmpty);
      expect(container.read(hostMultiSelectProvider).active, isTrue, reason: 'still selecting');
      await finish(tester);
    });
  });

  group('One row', () {
    testWidgets('in a wide window the design\'s actions are on one row, in its order, the hints over it', (tester) async {
      await pump(tester, selected: {'h1', 'h2'});
      final labels = [
        l10n.hostBulkActionSelectedCount(2),
        l10n.bulkOpen,
        l10n.bulkTags,
        l10n.hostBulkActionMoveToGroup,
        l10n.delete,
      ];
      final centres = [for (final t in labels) tester.getCenter(find.text(t))];
      expect({for (final c in centres) c.dy.round()}, hasLength(1), reason: 'one row');
      for (var i = 1; i < centres.length; i++) {
        expect(centres[i].dx, greaterThan(centres[i - 1].dx), reason: labels[i]);
      }
      final more = tester.getCenter(find.byKey(const ValueKey('bulk-more')));
      expect(more.dx, greaterThan(centres[3].dx), reason: 'its ⋯ after Move to group');
      expect(more.dx, lessThan(centres[4].dx), reason: 'and before Delete');
      expect(tester.getCenter(find.byKey(const ValueKey('bulk-done'))).dx, greaterThan(centres[4].dx), reason: 'the close last');
      final hint = tester.getRect(find.byKey(const ValueKey('host-bulk-hint')));
      expect(hint.bottom, lessThan(tester.getRect(find.byKey(const ValueKey('host-bulk-actions'))).top), reason: 'over the bar');
      for (final t in [l10n.bulkHintAdd, l10n.bulkHintRange, l10n.bulkHintAll, l10n.bulkHintClears]) {
        expect(find.text(t), findsOneWidget, reason: t);
      }
      expect(find.text(l10n.bulkHintFields), findsNothing, reason: 'no editor to open where none is given');
      await finish(tester);
    });

    testWidgets('in a narrow window still one row, and what is behind ⋯ works from there', (tester) async {
      await pump(tester, selected: {'h1', 'h2'}, width: 1000);
      final rowTops = {
        for (final t in [l10n.bulkOpen, l10n.hostBulkActionMoveToGroup, l10n.delete]) tester.getCenter(find.text(t)).dy.round(),
      };
      expect(rowTops, hasLength(1), reason: 'still one row');
      await tester.tap(find.byKey(const ValueKey('bulk-more')));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text(l10n.hostIconColorLabel));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Icon color of 2 hosts'), findsOneWidget, reason: 'the action runs from the menu');
      await finish(tester);
    });

    testWidgets('Delete and the close name their keys', (tester) async {
      await pump(tester, selected: {'h1'});
      expect(find.byTooltip('${l10n.delete} (Del)'), findsOneWidget);
      expect(find.byTooltip('${l10n.done} (Esc)'), findsOneWidget);
      await finish(tester);
    });
  });

  testWidgets('a workspace of more hosts than a tab holds goes on to a next tab', (tester) async {
    await pump(tester, selected: {...shown});
    final all = await tester.runAsync(() => container.read(connectionsWithDetailsProvider.future));
    final made = workspaceOfHosts(all!, shown)!;
    expect([for (final t in made.tabs) t.paneTreeOfConnIds.allLeaves.length], [kWorkspaceHostsPerTab, 2]);
    expect(made.hostNames['h9'], 'web-9');
    await finish(tester);
  });
}
