import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

import '../../helpers/desktop_mouse.dart';
import '../../helpers/monitor_table_fixture.dart';

/// Broadcast to hosts, as redesigned:
/// the one row of a host, a group's box with how many of it are ticked,
/// chips that tick what the Server monitor already found, Active first, and the
/// foot in sight however long the list.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'db'),
      's2': const SessionState(status: SessionStatus.connected, connectionId: 'web1'),
    };
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<AppDatabase> pump(WidgetTester tester, Widget Function() child, {Size size = const Size(1400, 1000)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    await tester.pumpWidget(fleet.app(
      [...fleet.overrides(db, prefs), activeSessionsProvider.overrideWith(_Sessions.new)],
      Consumer(builder: (context, ref, _) => child()),
    ));
    await settle(tester);
    return db;
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  Finder quick(String name) => find.byKey(ValueKey('broadcast-quick-$name'));

  String chipCount(WidgetTester tester, String name) =>
      tester.widgetList<Text>(find.descendant(of: quick(name), matching: find.byType(Text))).last.data!;

  desktopTest('the chips say how many hosts each has, from what the monitor found, and tick them', (tester) async {
    final db = await pump(tester, () => const BroadcastToHostsDialog());
    // The fleet: web-02 asks for a restart and, with log-store, has updates;
    // hypervisor-a is over a limit; two sessions are open.
    expect(chipCount(tester, 'reboot'), '1');
    expect(chipCount(tester, 'updates'), '2');
    expect(chipCount(tester, 'warnings'), '1');
    expect(chipCount(tester, 'open'), '2');

    await tester.tap(quick('updates'));
    await settle(tester);
    expect(find.text(en.broadcastToHostsOpen(2)), findsOneWidget);
    await tester.tap(quick('warnings'));
    await settle(tester);
    expect(find.text(en.broadcastToHostsOpen(3)), findsOneWidget);
    // All its hosts ticked, a chip unticks them.
    await tester.tap(quick('updates'));
    await settle(tester);
    expect(find.text(en.broadcastToHostsOpen(1)), findsOneWidget);
    await finish(tester, db);
  });

  desktopTest('it opens with what it is handed ticked', (tester) async {
    final db = await pump(tester, () => const BroadcastToHostsDialog(preselected: {'web2', 'logs'}));
    expect(find.text(en.broadcastToHostsOpen(2)), findsOneWidget);
    await finish(tester, db);
  });

  desktopTest('each row is the one row of a host; Active first sets the open ones apart, and the switch puts them back',
      (tester) async {
    final db = await pump(tester, () => const BroadcastToHostsDialog());
    final row = find.byKey(const ValueKey('broadcast-host-web1'));
    expect(find.descendant(of: row, matching: find.byType(HostGlyph)), findsOneWidget);
    expect(find.descendant(of: row, matching: find.byType(HostOpenDot)), findsOneWidget);

    expect(find.text(en.hostsSectionActive.toUpperCase()), findsOneWidget);
    expect(find.text(en.hostsSectionInactive.toUpperCase()), findsOneWidget);
    final active = tester.getTopLeft(row).dy;
    final rest = tester.getTopLeft(find.byKey(const ValueKey('broadcast-host-hva'))).dy;
    expect(active, lessThan(rest));

    await tester.tap(find.byKey(const ValueKey('active-first-broadcast')));
    await settle(tester);
    expect(find.text(en.hostsSectionActive.toUpperCase()), findsNothing);
    await finish(tester, db);
  });

  desktopTest("a group's heading says how many of it are ticked", (tester) async {
    final db = await pump(tester, () => const BroadcastToHostsDialog());
    // (This fleet's hosts are in no group: the one heading among the inactive ones.)
    expect(find.text('0/10'), findsOneWidget);
    expect(find.text('0/2'), findsOneWidget, reason: 'the active ones');
    await tester.tap(find.byKey(const ValueKey('broadcast-active-group-none')));
    await settle(tester);
    expect(find.text('2/2'), findsOneWidget);
    await finish(tester, db);
  });

  desktopTest('in a short window the foot stays in sight, and the hosts scroll under the search', (tester) async {
    final db = await pump(tester, () => const BroadcastToHostsDialog(), size: const Size(1400, 480));
    final foot = find.text(en.broadcastToHostsOpen(0));
    expect(foot, findsOneWidget);
    expect(tester.getBottomLeft(foot).dy, lessThan(480));
    final search = tester.getTopLeft(find.byKey(const ValueKey('broadcast-hosts-search'))).dy;
    await tester.drag(find.byKey(const ValueKey('broadcast-hosts-list')), const Offset(0, -200));
    await settle(tester);
    expect(tester.getTopLeft(find.byKey(const ValueKey('broadcast-hosts-search'))).dy, search);
    expect(tester.getBottomLeft(foot).dy, lessThan(480));
    expect(tester.takeException(), isNull);
    await finish(tester, db);
  });

  desktopTest('the checklist in a page that scrolls is as tall as its hosts', (tester) async {
    final db = await pump(tester, () {
      return SingleChildScrollView(
        child: HostChecklist(picked: const {}, onChanged: (_) {}, keyPrefix: 'run', autofocus: false),
      );
    });
    expect(find.byKey(const ValueKey('run-hosts-list')), findsNothing);
    expect(find.byKey(const ValueKey('run-host-web1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await finish(tester, db);
  });

  test('Active first is on by itself for a broadcast', () {
    expect(HostListPlace.broadcast.activeFirstByDefault, isTrue);
  });
}
