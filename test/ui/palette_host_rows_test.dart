import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

import '../helpers/desktop_mouse.dart';
import '../helpers/monitor_table_fixture.dart';

/// The command palette's Connections rows:
/// the host's own icon, its name, user@address, the dot of an open session, when
/// it was last connected to.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {'s1': const SessionState(status: SessionStatus.connected, connectionId: 'db')};
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  desktopTest('its rows of hosts are the one row of a host, with an open dot, and never a server glyph', (tester) async {
    L10nGlobal.update(en);
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(fleet.database))!;
    final prefs = await fleet.preferences();
    late BuildContext at;
    late WidgetRef refAt;
    await tester.pumpWidget(fleet.app(
      [...fleet.overrides(db, prefs), activeSessionsProvider.overrideWith(_Sessions.new)],
      Consumer(builder: (context, ref, _) {
        at = context;
        refAt = ref;
        return const SizedBox.expand();
      }),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // (With actions of its own the palette needs no router here.)
    showCommandPalette(at, refAt, actions: const []).ignore();
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(find.byType(HostRow), findsWidgets);
    expect(find.byIcon(LucideIcons.server), findsNothing);
    final db1 = find.ancestor(of: find.text('db-primary'), matching: find.byType(HostRow));
    expect(find.descendant(of: db1, matching: find.byType(HostOpenDot)), findsOneWidget);
    expect(find.descendant(of: db1, matching: find.text('deploy@192.168.10.31')), findsOneWidget);
    final web = find.ancestor(of: find.text('web-01'), matching: find.byType(HostRow));
    expect(find.descendant(of: web, matching: find.byType(HostOpenDot)), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  });
}
