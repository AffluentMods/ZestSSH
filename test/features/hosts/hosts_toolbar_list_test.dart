import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/features/screens/session/screen_target.dart' show XProgramTarget;
import 'package:zestssh/features/screens/xprogram/x_program_recent.dart' show xProgramRecentProvider;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_health_summary.dart';
import 'package:zestssh/features/hosts/local_terminal.dart' show debugLocalTerminalOnThisDevice;
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/state/host_sort_mode.dart';
import 'package:zestssh/features/hosts/state/hosts_page_prefs.dart';
import 'package:zestssh/features/hosts/widgets/group_tiles.dart';
import 'package:zestssh/features/hosts/widgets/hosts_band.dart';
import 'package:zestssh/features/hosts/widgets/hosts_table.dart';
import 'package:zestssh/features/hosts/widgets/section_label.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart';
import 'package:zestssh/features/monitoring/monitor_thresholds.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/providers/desktop_providers.dart' show connectionEditorTargetProvider;
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';

/// A computer's Hosts page as designed: one
/// toolbar row (New host with its menu, Local terminal, the field, need
/// attention, Sort, Filter, the views), sections that fold away and stay
/// folded, and the list: its columns, each sorting with the toolbar's Sort in
/// step, the Health cell with the person's mute and snooze, and a row's ⋯.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late ProviderContainer container;
  late SharedPreferences prefs;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The page with six hosts, three in Web; four watched by Server monitor
  /// (h1's CPU over its line, h2's RAM over it but muted, h3 and h4 fine).
  Future<void> pump(
    WidgetTester tester, {
    Map<String, Object> values = const {},
    Size size = const Size(1500, 1100),
    bool keepPrefs = false,
    bool groups = true,
    void Function(ConnectionWithDetails item, XProgramTarget program)? onOpenXProgram,
    void Function(ConnectionWithDetails item)? onOpenConsole,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final at = DateTime.now().millisecondsSinceEpoch;
    Map<String, Object> st(double cpu, int ram, double disk) =>
        {'cpuPercent': cpu, 'ramUsedMB': ram, 'ramTotalMB': 8192, 'diskPercent': disk, 'collectedAt': at, 'source': 'ssh'};
    if (!keepPrefs) {
      SharedPreferences.setMockInitialValues({
        'cached_server_stats': jsonEncode({
          'h1': st(99, 1000, 30),
          'h2': st(10, 8000, 30),
          'h3': st(40, 1000, 30),
          'h4': st(5, 1000, 20),
        }),
        'monitor_host_alert_prefs_v1': jsonEncode({
          'h2': {
            'silences': {'ram': {'kind': 'mute'}},
          },
        }),
        ...values,
      });
    }
    prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final created = DateTime(2026, 10, 22);
    if (groups) {
      await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g-web', name: 'Web', createdAt: created));
    }
    const names = ['delta', 'alpha', 'foxtrot', 'charlie', 'echo', 'bravo'];
    for (var i = 1; i <= 6; i++) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'h$i',
            label: names[i - 1],
            host: '10.50.0.${10 - i}',
            groupId: Value(i <= 3 && groups ? 'g-web' : null),
            monitored: Value(i <= 4),
            lastConnected: Value(DateTime.now().subtract(Duration(hours: i * 5))),
            sortOrder: Value(i),
            createdAt: created,
            updatedAt: created,
          ));
    }
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
            body: HostsHomePage(onConnectTo: (_) {}, onOpenXProgram: onOpenXProgram, onOpenConsole: onOpenConsole)),
      ),
    ));
    await settle(tester);
    // The test font draws every glyph one em wide: some labels overflow here
    // that fit with the real one, which is not what this is about.
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  /// The rows of the list, top to bottom.
  List<String> rowOrder(WidgetTester tester) {
    final rows = find.byWidgetPredicate(
        (w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('hosts-row-'));
    final found = [
      for (final e in rows.evaluate())
        ((e.widget.key! as ValueKey<String>).value.substring('hosts-row-'.length), tester.getTopLeft(find.byWidget(e.widget)).dy),
    ]..sort((a, b) => a.$2.compareTo(b.$2));
    return [for (final r in found) r.$1];
  }

  String sortLabel(WidgetTester tester) => l10n.hostsHomeSortPrefix(container.read(hostSortModeProvider).nameIn(l10n));

  group('the toolbar', () {
    testWidgets('one row: New host, Local terminal, the field set apart, Sort, Filter and the three views; no title',
        (tester) async {
      await pump(tester);
      for (final k in [
        'hosts-new-host',
        'hosts-new-menu',
        'hosts-terminal',
        'hosts-quick-field',
        'hosts-sort',
        'hosts-filter',
        'hosts-view-list',
        'hosts-view-compact',
        'hosts-view-cards',
      ]) {
        expect(key(k), findsOneWidget, reason: k);
      }
      // Serial and Import moved into the New host menu.
      expect(key('hosts-serial'), findsNothing);
      expect(key('hosts-import'), findsNothing);
      // No big title and no count line: the Hosts tab says where one is.
      expect(find.text('0 open'), findsNothing);
      expect(find.text(l10n.hostsMetaHostCount(6)), findsNothing);
      // Everything on one line in a wide window.
      final y = tester.getCenter(key('hosts-new-host')).dy;
      for (final k in ['hosts-quick-field', 'hosts-sort', 'hosts-filter', 'hosts-view-cards']) {
        expect(tester.getCenter(key(k)).dy, closeTo(y, 1), reason: k);
      }
      expect(tester.getCenter(key('hosts-view-cards')).dx, greaterThan(tester.getCenter(key('hosts-filter')).dx));
      // How many need attention is not in the toolbar (each host
      // and the Server monitor say it), though h1 does.
      expect(key('hosts-attention-toggle'), findsNothing);
      // The field stands apart from Local terminal, more than the buttons do
      // from one another.
      final terminal = tester.getRect(key('hosts-terminal'));
      final field = tester.getRect(key('hosts-quick-field'));
      final newHost = tester.getRect(key('hosts-new-host'));
      expect(field.left - terminal.right, greaterThanOrEqualTo(24));
      expect(field.left - terminal.right, greaterThan(terminal.left - newHost.right));
      await finish(tester);
    });

    testWidgets("where the device has no shell of its own (an iPad in the computer's layout), Local terminal is not "
        'offered, whole or as its icon (it was, and could only fail)', (tester) async {
      debugLocalTerminalOnThisDevice = false;
      addTearDown(() => debugLocalTerminalOnThisDevice = null);
      for (final size in const [Size(1600, 1000), Size(1150, 1000)]) {
        await pump(tester, size: size);
        expect(key('hosts-terminal'), findsNothing, reason: '$size');
        expect(key('hosts-terminal-compact'), findsNothing, reason: '$size');
        expect(find.byTooltip(l10n.hostsToolbarTerminalTip), findsNothing);
        expect(key('hosts-new-host'), findsOneWidget);
        expect(tester.getCenter(key('hosts-quick-field')).dy, closeTo(tester.getCenter(key('hosts-new-host')).dy, 1));
        await finish(tester);
      }
    });

    testWidgets('in a narrow window it wraps into two rows, the views under the rest', (tester) async {
      await pump(tester, size: const Size(760, 1000));
      final first = tester.getCenter(key('hosts-new-host')).dy;
      expect(tester.getCenter(key('hosts-quick-field')).dy, closeTo(first, 1));
      expect(tester.getCenter(key('hosts-view-list')).dy, greaterThan(first + 20));
      // The views at the start of the second row, Filter at its end.
      expect(tester.getTopLeft(key('hosts-view-list')).dx, lessThan(tester.getTopLeft(key('hosts-filter')).dx));
      expect(tester.getRect(find.byKey(const ValueKey('hosts-toolbar'))).right, 760);
      await finish(tester);
    });

    testWidgets('with a side panel open, Local terminal gives way to its icon before the views leave the row',
        (tester) async {
      // The test font draws every glyph one em wide: at this width the words
      // of Local terminal would put the views on a second row.
      await pump(tester, size: const Size(1150, 1000));
      expect(key('hosts-terminal').hitTestable(), findsNothing);
      expect(key('hosts-terminal-compact').hitTestable(), findsOneWidget);
      expect(find.byTooltip(l10n.hostsToolbarTerminal), findsOneWidget);
      final y = tester.getCenter(key('hosts-new-host')).dy;
      for (final k in ['hosts-terminal-compact', 'hosts-quick-field', 'hosts-filter', 'hosts-view-cards']) {
        expect(tester.getCenter(key(k)).dy, closeTo(y, 1), reason: k);
      }
      expect(tester.getRect(key('hosts-view-cards')).right, closeTo(1150 - 24 - 2, 1));
      expect(tester.getSize(key('hosts-terminal-compact')).width, lessThan(40));
      await finish(tester);
    });

    testWidgets('the band: whole, then the last lead button compact, then the views at the end of a second row',
        (tester) async {
      Future<void> band(double width, {bool compact = true}) async {
        tester.view.physicalSize = Size(width + 48, 300);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        Widget box(String k, double w) =>
            ColoredBox(key: ValueKey(k), color: Colors.grey, child: SizedBox(width: w, height: 30));
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: width + 48,
                child: HostsBand(
                  lead: [box('head', 100), box('last', 200)],
                  leadCompact: compact ? box('compact', 34) : null,
                  field: const SizedBox(key: ValueKey('field'), height: 30),
                  trailing: [box('trailing', 300)],
                  toggles: box('toggles', 100),
                ),
              ),
            ),
          ),
        ));
      }

      double left(String k) => tester.getTopLeft(key(k)).dx - 24;
      double top(String k) => tester.getTopLeft(key(k)).dy;
      // Room for all of it.
      await band(1100);
      expect(key('last').hitTestable(), findsOneWidget);
      expect(key('compact').hitTestable(), findsNothing);
      expect(left('toggles'), 1000);
      expect(top('toggles'), top('head'));
      // Room only with the last button compact: one row still.
      await band(900);
      expect(key('last').hitTestable(), findsNothing);
      expect(key('compact').hitTestable(), findsOneWidget);
      expect(left('compact'), 108);
      expect(left('field'), 108 + 34 + 28);
      expect((left('toggles'), top('toggles')), (800, top('head')));
      // No compact form: the views go to a second row, at its end.
      await band(900, compact: false);
      expect(key('last').hitTestable(), findsOneWidget);
      expect(top('toggles'), greaterThan(top('head') + 20));
      expect(left('toggles'), 800);
    });

    testWidgets('the New host menu holds Serial, Import and Paste a share link', (tester) async {
      await pump(tester);
      await tester.tap(key('hosts-new-menu'));
      await settle(tester);
      for (final k in ['hosts-new-serial', 'hosts-new-import', 'hosts-new-share-link']) {
        expect(key(k), findsOneWidget, reason: k);
      }
      expect(find.text(l10n.hostsToolbarSerial), findsOneWidget);
      expect(find.text(l10n.hostsNewMenuImport), findsOneWidget);
      expect(find.text(l10n.shareLinkPasteTitle), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await finish(tester);
    });

    testWidgets('the compact grid is a view of its own, remembered', (tester) async {
      await pump(tester);
      await tester.tap(key('hosts-view-compact'));
      await settle(tester);
      expect(prefs.getString(HostsPagePrefs.viewKey), 'compact');
      expect(key('hosts-table'), findsNothing);
      await finish(tester);
      await pump(tester, keepPrefs: true);
      expect(HostsPagePrefs.view(prefs), HostsViewMode.compact);
      await finish(tester);
    });
  });

  group('folding sections', () {
    testWidgets('Groups and Hosts fold away with their chevron, and stay folded on this device', (tester) async {
      await pump(tester);
      expect(find.byType(GroupTiles), findsOneWidget);
      await tester.tap(key('hosts-fold-groups'));
      await settle(tester);
      expect(find.byType(GroupTiles), findsNothing);
      expect(find.text(l10n.hostsSectionGroups.toUpperCase()), findsOneWidget, reason: 'its head stays');
      expect(prefs.getStringList(HostsPagePrefs.foldedKey), ['groups']);
      // The page opened again: still folded.
      await finish(tester);
      await pump(tester, keepPrefs: true);
      expect(find.byType(GroupTiles), findsNothing);
      await tester.tap(key('hosts-fold-groups'));
      await settle(tester);
      expect(find.byType(GroupTiles), findsOneWidget);
      // Hosts fold too: Ctrl+A then selects nothing.
      await tester.tap(key('hosts-fold-hosts'));
      await settle(tester);
      expect(find.text('alpha'), findsNothing);
      await finish(tester);
    });

    testWidgets('no groups yet: the Groups head has no count over the Ungrouped tile', (tester) async {
      await pump(tester, groups: false);
      final head = find.ancestor(of: key('hosts-fold-groups'), matching: find.byType(SectionLabel));
      expect(head, findsOneWidget);
      expect(find.descendant(of: head, matching: find.text('0')), findsNothing);
      expect(find.text(l10n.hostPanelUngrouped), findsWidgets);
      await finish(tester);
      // With one: its count.
      await pump(tester);
      expect(
          find.descendant(
              of: find.ancestor(of: key('hosts-fold-groups'), matching: find.byType(SectionLabel)), matching: find.text('1')),
          findsOneWidget);
      await finish(tester);
    });

    test('the keys are settings Reset all puts back', () {
      for (final k in [HostsPagePrefs.viewKey, HostsPagePrefs.foldedKey, HostsPagePrefs.columnsKey]) {
        expect(SettingsService.resetKeys, contains(k));
      }
    });
  });

  group('the list', () {
    testWidgets('its columns, and each head sorts by its column, the toolbar Sort in step', (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      expect(key('hosts-table'), findsOneWidget);
      for (final c in ['host', 'address', 'group', 'health', 'status', 'lastUsed']) {
        expect(key('hosts-head-$c'), findsOneWidget, reason: c);
      }
      expect(key('hosts-head-tags'), findsNothing, reason: 'the tags only where chosen');
      expect(find.text(l10n.hostsListLastUsed.toUpperCase()), findsOneWidget);
      expect(find.descendant(of: key('hosts-table'), matching: find.text(l10n.hostPanelUngrouped)), findsNWidgets(3));

      final expected = {
        'host': (HostSortMode.alphabetical, ['h2', 'h6', 'h4', 'h1', 'h5', 'h3']),
        'address': (HostSortMode.ipAddress, ['h6', 'h5', 'h4', 'h3', 'h2', 'h1']),
        'health': (HostSortMode.health, ['h1', 'h3', 'h4', 'h2', 'h5', 'h6']),
        'lastUsed': (HostSortMode.recent, ['h1', 'h2', 'h3', 'h4', 'h5', 'h6']),
      };
      for (final e in expected.entries) {
        await tester.tap(key('hosts-head-${e.key}'));
        await settle(tester);
        expect(container.read(hostSortModeProvider), e.value.$1, reason: e.key);
        expect(find.text(sortLabel(tester)), findsOneWidget, reason: 'the toolbar says it: ${e.key}');
        expect(rowOrder(tester), e.value.$2, reason: e.key);
        expect(find.descendant(of: key('hosts-head-${e.key}'), matching: find.byIcon(LucideIcons.arrowDown)), findsOneWidget);
      }
      // Group and Status sort too.
      await tester.tap(key('hosts-head-group'));
      await settle(tester);
      expect(container.read(hostSortModeProvider), HostSortMode.groupColor);
      expect(rowOrder(tester).take(3).toSet(), {'h1', 'h2', 'h3'});
      await tester.tap(key('hosts-head-status'));
      await settle(tester);
      expect(container.read(hostSortModeProvider), HostSortMode.status);

      // A second click turns the order round, its arrow up.
      await tester.tap(key('hosts-head-host'));
      await settle(tester);
      await tester.tap(key('hosts-head-host'));
      await settle(tester);
      expect(container.read(hostSortReversedProvider), isTrue);
      expect(rowOrder(tester), ['h3', 'h5', 'h1', 'h4', 'h6', 'h2']);
      expect(find.descendant(of: key('hosts-head-host'), matching: find.byIcon(LucideIcons.arrowUp)), findsOneWidget);

      // The toolbar's Sort moves the list's arrow, and the right way round.
      await tester.tap(key('hosts-sort'));
      await settle(tester);
      await tester.tap(find.text(l10n.hostSortHealth).last);
      await settle(tester);
      expect(container.read(hostSortReversedProvider), isFalse);
      expect(find.descendant(of: key('hosts-head-health'), matching: find.byIcon(LucideIcons.arrowDown)), findsOneWidget);
      expect(rowOrder(tester).first, 'h1');
      await finish(tester);
    });

    testWidgets('the column picker chooses the columns, remembered', (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      await tester.tap(key('hosts-columns'));
      await settle(tester);
      await tester.tap(key('hosts-column-tags'));
      await settle(tester);
      await tester.tap(key('hosts-column-address'));
      await settle(tester);
      expect(key('hosts-head-tags'), findsOneWidget);
      expect(key('hosts-head-address'), findsNothing);
      expect(HostsPagePrefs.columns(prefs), {
        HostsListColumn.group,
        HostsListColumn.health,
        HostsListColumn.status,
        HostsListColumn.lastUsed,
        HostsListColumn.tags,
      });
      await finish(tester);
    });

    testWidgets('the Health cell: a chip over the line, the muted metric quiet with its bell off, plain readings',
        (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      Finder inRow(String id, Finder f) => find.descendant(of: key('hosts-row-$id'), matching: f);
      expect(inRow('h1', find.text('CPU 99%')), findsOneWidget);
      expect(inRow('h2', key('hosts-health-muted')), findsOneWidget);
      expect(inRow('h2', find.byIcon(LucideIcons.bellOff)), findsOneWidget);
      expect(inRow('h2', find.text('RAM 98%')), findsOneWidget);
      expect(inRow('h3', find.text('CPU 40%')), findsOneWidget);
      // A host Server monitor does not watch says nothing of its health.
      expect(inRow('h5', find.byType(HostHealthCell)), findsOneWidget);
      expect(inRow('h5', find.textContaining('%')), findsNothing);
      expect(inRow('h1', find.text(l10n.hostsListOpen)), findsNothing);
      expect(inRow('h1', find.text(l10n.hostsListClosed)), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a snoozed metric is quiet too, and comes back once the snooze is over', (tester) async {
      Map<String, Object> snoozed(Duration fromNow) => {
            HostsPagePrefs.viewKey: 'list',
            'monitor_host_alert_prefs_v1': jsonEncode({
              'h1': {
                'silences': {
                  'cpu': {'kind': 'until', 'until': DateTime.now().add(fromNow).millisecondsSinceEpoch},
                },
              },
              'h2': {
                'silences': {'ram': {'kind': 'mute'}},
              },
            }),
          };
      Finder inRow(String id, Finder f) => find.descendant(of: key('hosts-row-$id'), matching: f);
      await pump(tester, values: snoozed(const Duration(hours: 1)));
      expect(inRow('h1', key('hosts-health-muted')), findsOneWidget);
      await finish(tester);
      // The snooze ended an hour ago.
      await pump(tester, values: snoozed(const Duration(hours: -1)));
      expect(inRow('h1', key('hosts-health-muted')), findsNothing);
      expect(inRow('h1', find.text('CPU 99%')), findsOneWidget);
      await finish(tester);
    });

    testWidgets("a row's ⋯ opens the host's menu, as a right click does", (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      await tester.tap(key('host-row-menu-h3'));
      await settle(tester);
      expect(key('host-menu-edit'), findsOneWidget);
      expect(key('host-menu-connect'), findsOneWidget);
      // Closed by a click beside it: left of it, at its foot. (The test font
      // draws every item 48 high, so the menu of the ⋯ at the right reaches
      // the window's foot, and a click in the corner would land on Delete.)
      Offset beside() => Offset(tester.getRect(key('host-menu-edit')).left - 40, 1080);
      await tester.tapAt(beside());
      await settle(tester);
      expect(key('host-menu-edit'), findsNothing);
      await tester.tapAt(tester.getCenter(find.text('charlie')), buttons: kSecondaryButton);
      await settle(tester);
      expect(key('host-menu-edit'), findsOneWidget);
      await tester.tapAt(beside());
      await settle(tester);
      expect(container.read(hostMultiSelectProvider).active, isFalse);
      await finish(tester);
    });
  });

  group('Add a screen for this host', () {
    testWidgets("an SSH host's menu has it and opens the editor on a new screen reached through the host", (tester) async {
      ConnectionEditScreen.debugDesktopShell = true;
      addTearDown(() => ConnectionEditScreen.debugDesktopShell = null);
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      await tester.tap(key('host-row-menu-h3'));
      await settle(tester);
      // Under Tools (4.0: the menu grouped).
      await tester.tap(key('host-menu-tools'));
      await settle(tester);
      expect(find.text(l10n.hostMenuAddScreen), findsOneWidget);
      await tester.tap(key('host-menu-add_screen'));
      await settle(tester);
      // VNC or RDP is asked first (4.0).
      await tester.tap(key('host-screen-kind-vnc'));
      await settle(tester);
      final target = container.read(connectionEditorTargetProvider);
      expect(target, isNotNull);
      expect(target!.connectionId, isNull);
      expect(target.initialProtocol, ConnectionProtocol.vnc);
      expect(target.initialVia, 'h3');
      container.read(connectionEditorTargetProvider.notifier).state = null;
      await finish(tester);
    });

    testWidgets('a host that cannot carry a screen (Telnet, a screen itself) has none', (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      final db = container.read(databaseProvider);
      await (db.update(db.connections)..where((c) => c.id.equals('h3')))
          .write(const ConnectionsCompanion(protocol: Value('telnet')));
      await (db.update(db.connections)..where((c) => c.id.equals('h4')))
          .write(const ConnectionsCompanion(protocol: Value('vnc')));
      await settle(tester);
      for (final id in ['h3', 'h4']) {
        await tester.tap(key('host-row-menu-$id'));
        await settle(tester);
        expect(key('host-menu-edit'), findsOneWidget, reason: id);
        await tester.tap(key('host-menu-tools'));
        await settle(tester);
        expect(key('host-menu-add_screen'), findsNothing, reason: id);
        await tester.tapAt(Offset(tester.getRect(key('host-menu-edit')).left - 40, 1080));
        await settle(tester);
        expect(key('host-menu-edit'), findsNothing, reason: id);
      }
      await finish(tester);
    });
  });

  group('Open an X program (4.0)', () {
    testWidgets("an SSH host's menu asks for the program and opens it at the window's size; the program goes first "
        "in the host's recent list on this device", (tester) async {
      final opened = <(String, XProgramTarget)>[];
      await pump(tester,
          values: {HostsPagePrefs.viewKey: 'list'},
          onOpenXProgram: (item, program) => opened.add((item.connection.id, program)));
      await tester.tap(key('host-row-menu-h3'));
      await settle(tester);
      await tester.tap(key('host-menu-tools'));
      await settle(tester);
      expect(find.text(l10n.hostMenuOpenXProgram), findsOneWidget);
      await tester.tap(key('host-menu-x_program'));
      await settle(tester);
      expect(find.text(l10n.xProgramDialogTitle), findsOneWidget);
      await tester.enterText(key('x-program-field'), "xterm -T 'ops'");
      await settle(tester);
      await tester.tap(find.text(l10n.xProgramOpenButton));
      await settle(tester);
      expect(opened, hasLength(1));
      expect(opened.single.$1, 'h3');
      expect(opened.single.$2.program, "xterm -T 'ops'");
      expect((opened.single.$2.width, opened.single.$2.height), (1496, 1016),
          reason: "the page that asks, 1500x1100 here, less the tab's header and toolbar");
      expect(await container.read(xProgramRecentProvider).of('h3'), ["xterm -T 'ops'"]);
      await finish(tester);
    });

    testWidgets('a host that is no SSH host (Telnet, a screen) has none, nor a page that cannot open it',
        (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'}, onOpenXProgram: (_, _) {});
      final db = container.read(databaseProvider);
      await (db.update(db.connections)..where((c) => c.id.equals('h3')))
          .write(const ConnectionsCompanion(protocol: Value('telnet')));
      await (db.update(db.connections)..where((c) => c.id.equals('h4')))
          .write(const ConnectionsCompanion(protocol: Value('vnc')));
      await settle(tester);
      for (final id in ['h3', 'h4']) {
        await tester.tap(key('host-row-menu-$id'));
        await settle(tester);
        expect(key('host-menu-edit'), findsOneWidget, reason: id);
        await tester.tap(key('host-menu-tools'));
        await settle(tester);
        expect(key('host-menu-x_program'), findsNothing, reason: id);
        await tester.tapAt(Offset(tester.getRect(key('host-menu-edit')).left - 40, 1080));
        await settle(tester);
      }
      await finish(tester);
    });

    testWidgets("an SSH host's menu offers its file to share; a remote screen's and an FTPS host's do not (the "
        'file would be refused where it is imported)', (tester) async {
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'});
      final db = container.read(databaseProvider);
      await (db.update(db.connections)..where((c) => c.id.equals('h3')))
          .write(const ConnectionsCompanion(protocol: Value('vnc')));
      await (db.update(db.connections)..where((c) => c.id.equals('h4')))
          .write(const ConnectionsCompanion(protocol: Value('ftps')));
      await settle(tester);
      for (final (id, offered) in [('h1', true), ('h3', false), ('h4', false)]) {
        await tester.tap(key('host-row-menu-$id'));
        await settle(tester);
        await tester.tap(key('host-menu-organize'));
        await settle(tester);
        expect(key('host-menu-share_file'), offered ? findsOneWidget : findsNothing, reason: id);
        await tester.tapAt(Offset(tester.getRect(key('host-menu-edit')).left - 40, 1080));
        await settle(tester);
      }
      await finish(tester);
    });
  });

  group('Open console (4.0)', () {
    testWidgets("a host imported as a Proxmox guest has it in Tools, and it opens that host's console; a host that is "
        'none, or a node of the cluster, has none', (tester) async {
      final opened = <String>[];
      await pump(tester, values: {HostsPagePrefs.viewKey: 'list'}, onOpenConsole: (item) => opened.add(item.connection.id));
      final db = container.read(databaseProvider);
      await (db.update(db.connections)..where((c) => c.id.equals('h3'))).write(const ConnectionsCompanion(
          cloudSource: Value('{"v":1,"p":"proxmox","id":"pve.example.test:8006/pve/100","l":"Lab"}')));
      await (db.update(db.connections)..where((c) => c.id.equals('h4'))).write(const ConnectionsCompanion(
          cloudSource: Value('{"v":1,"p":"proxmox","id":"pve.example.test:8006/node/pve","l":"Lab"}')));
      await settle(tester);
      await tester.tap(key('host-row-menu-h3'));
      await settle(tester);
      await tester.tap(key('host-menu-tools'));
      await settle(tester);
      expect(find.text(l10n.hostMenuOpenConsole), findsOneWidget);
      await tester.tap(key('host-menu-console'));
      await settle(tester);
      expect(opened, ['h3']);
      for (final id in ['h4', 'h5']) {
        await tester.tap(key('host-row-menu-$id'));
        await settle(tester);
        await tester.tap(key('host-menu-tools'));
        await settle(tester);
        expect(key('host-menu-console'), findsNothing, reason: id);
        await tester.tapAt(Offset(tester.getRect(key('host-menu-edit')).left - 40, 1080));
        await settle(tester);
      }
      await finish(tester);
    });
  });

  group('what the cells say', () {
    test('Last used: now, hours, yesterday, days, the date', () {
      final now = DateTime(2026, 10, 22, 15);
      expect(hostLastUsedWords(l10n, now.subtract(const Duration(seconds: 20)), now: now), 'Now');
      expect(hostLastUsedWords(l10n, now.subtract(const Duration(hours: 2)), now: now), '2h ago');
      expect(hostLastUsedWords(l10n, DateTime(2026, 10, 21, 9), now: now), 'Yesterday');
      expect(hostLastUsedWords(l10n, DateTime(2026, 10, 16, 9), now: now), '6d ago');
      expect(hostLastUsedWords(l10n, DateTime(2026, 10, 8), now: now), 'Oct 8');
      expect(hostLastUsedWords(l10n, DateTime(2025, 3, 2), now: now), 'Mar 2, 2025');
    });

    MetricEval m(MonitorMetric metric, double v, MetricSeverity s, {bool silenced = false}) =>
        MetricEval(metric: metric, value: v, warn: 80, crit: 90, severity: s, silenced: silenced);

    test('Health: the worst metric, a muted one quiet, unreachable and a changed key worst of all', () {
      final warn = hostHealthSummary(
          MonitorHostView(bucket: MonitorBucket.warning, metrics: [
            m(MonitorMetric.cpu, 20, MetricSeverity.healthy),
            m(MonitorMetric.disk, 85, MetricSeverity.warning),
          ]),
          l10n);
      expect(warn.kind, HostHealthKind.warning);
      expect(warn.chip!.label, 'Disk 85%');
      final muted = hostHealthSummary(
          MonitorHostView(bucket: MonitorBucket.healthy, metrics: [
            m(MonitorMetric.cpu, 20, MetricSeverity.healthy),
            m(MonitorMetric.ram, 95, MetricSeverity.critical, silenced: true),
          ]),
          l10n);
      expect(muted.kind, HostHealthKind.muted);
      expect(muted.metric, MonitorMetric.ram);
      final plain = hostHealthSummary(
          MonitorHostView(bucket: MonitorBucket.healthy, metrics: [
            m(MonitorMetric.cpu, 20, MetricSeverity.healthy),
            m(MonitorMetric.ram, 60, MetricSeverity.healthy),
          ]),
          l10n);
      expect((plain.kind, plain.metric, plain.value), (HostHealthKind.plain, MonitorMetric.ram, 60));
      final down = hostHealthSummary(
          const MonitorHostView(bucket: MonitorBucket.cantCheck, metrics: [], cantCheckReason: CantCheckReason.unreachable),
          l10n);
      expect(down.kind, HostHealthKind.critical);
      expect(hostHealthSummary(null, l10n).kind, HostHealthKind.none);
      expect(hostHealthSummary(null, l10n, changedHostKey: true).chip!.label, l10n.hostKeyChangedTitle);
      // The Health order: worst first, a muted metric after the plain ones.
      final order = [plain, HostHealthSummary.none, muted, down, warn]..sort((a, b) => a.compareWorseFirst(b));
      expect(order, [down, warn, plain, muted, HostHealthSummary.none]);
    });
  });
}
