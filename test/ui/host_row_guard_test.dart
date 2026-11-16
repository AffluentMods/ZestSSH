import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// One row of a host, wherever hosts are listed (as a design review asked):
/// the host's own icon, its name,
/// user@address, the dot of an open session, and the row the identity's USED BY
/// list already had. A list that draws a bare server glyph for a host, or a
/// host's icon by itself, fails here: it goes on [HostRow] or [HostGlyph]. A new
/// use that is no host in a list (a menu's action, an empty state) goes on the
/// lists below, with why.

/// Where a bare server glyph is let be, how many times, and why. Not one is a
/// saved host in a list.
const _serverGlyph = <String, (int, String)>{
  'lib/features/groups/widgets/phone_group_sheets.dart': (1, 'the New host action of a menu'),
  'lib/features/hosts/pages/hosts_home_page.dart': (2, 'the New host action, and the page with no hosts'),
  'lib/features/hosts/phone/phone_host_selection.dart': (1, "the Host actions action of a phone's More"),
  'lib/features/onboarding/widgets/lan_scan_view.dart': (1, 'machines a scan found: not hosts yet'),
  'lib/features/onboarding/widgets/ssh_config_review.dart': (1, 'hosts of a file being read: not hosts yet'),
  'lib/features/orchards/move/move_copy_dialog.dart': (1, 'what kind a linked item is (Host), beside its name, in the Move to question'),
  'lib/features/orchards/widgets/crate_records_view.dart': (1, 'an item of a deleted kind in a trash: the host is gone'),
  'lib/features/orchards/widgets/orchard_crates.dart': (2, "a vault's Show hosts action"),
  'lib/features/orchards/widgets/vaults_page.dart': (1, "a vault's Show hosts action"),
  'lib/ui/screens/automation/automation_guide_screen.dart': (1, 'a section of a guide'),
  'lib/ui/screens/automation/automation_wizard_screen.dart': (2, 'the Batch kind of a task, and no hosts to choose'),
  'lib/ui/screens/command_history/desktop_history_page.dart': (1, 'the Run on… action of a menu'),
  'lib/ui/screens/desktop/desktop_shell.dart': (1, "the palette's Connections page"),
  'lib/ui/screens/desktop/widgets/keys_detail_pane.dart': (1, 'the Install on hosts action'),
  'lib/ui/screens/desktop/widgets/keys_inspector_pane.dart': (1, 'the Install on hosts action'),
  'lib/ui/screens/desktop/widgets/monitor_table_view.dart': (1, 'the Data source action of a menu'),
  'lib/ui/screens/desktop/widgets/narrow_sidebar.dart': (1, 'the Hosts page in the sidebar'),
  'lib/ui/screens/desktop/widgets/port_forward_detail_pane.dart': (1, "a tunnel's far end in its diagram"),
  'lib/ui/screens/desktop/widgets/snippets_library_view.dart': (1, 'the Run on… action of a menu'),
  'lib/ui/screens/desktop/widgets/theme_designer_view.dart': (1, "the Hosts page in the side rail of a theme's live preview"),
  'lib/ui/screens/home/home_screen.dart': (4, "a session of no host left; a phone's Hosts tab, twice; no hosts"),
  'lib/ui/screens/identity/identity_edit_screen.dart': (1, 'the Install on hosts action'),
  'lib/ui/screens/import/ssh_config_import_screen.dart': (1, 'hosts of a file being read: not hosts yet'),
  'lib/ui/screens/monitoring/monitor_manage_dialog.dart': (1, 'no hosts to choose'),
  'lib/ui/screens/monitoring/server_monitor_screen.dart': (1, 'the Data source action of a menu'),
  'lib/ui/screens/settings/settings_screen.dart': (1, 'a backup destination'),
  'lib/ui/screens/settings/sync_backend_screen.dart': (1, 'a kind of storage'),
  'lib/ui/screens/sftp/sftp_dual_pane_screen.dart': (1, "a pane's source, which may be no saved host"),
  'lib/ui/screens/sftp/widgets/sftp_source_picker.dart': (1, 'the fallback of a row, behind a host\'s own icon'),
  'lib/ui/screens/sync/stale_reconcile_dialog.dart': (1, 'a kind of data'),
  'lib/ui/screens/terminal/widgets/session_info_dialog.dart': (1, 'the Hostname line of a session\'s details'),
  'lib/ui/widgets/broadcast_dangerous_dialog.dart': (1, 'a session of no saved host, among those a typed command goes to'),
  'lib/ui/widgets/connection_picker_dialog.dart': (1, "the picker's own title"),
  'lib/ui/widgets/os_icon.dart': (1, "the fallback of a session's tab whose system is not known"),
  'lib/ui/widgets/tunnel_diagram.dart': (1, "a tunnel's far end in its diagram"),
  'lib/ui/widgets/zest_color_picker.dart': (1, 'a preview of a colour on a host-like tile'),
};

/// Where a host's icon is drawn by itself, and why: what is no row of a list.
const _hostIcon = <String, String>{
  'lib/core/widgets/os_icon.dart': 'what draws it',
  'lib/features/hosts/phone/phone_hosts_view.dart': "a phone's list: its large tile, a letter where there is no icon",
  'lib/features/hosts/widgets/host_card.dart': "the Hosts page's cards",
  'lib/features/hosts/widgets/host_grid_area.dart': 'a dragged card, from what the card holds',
  'lib/features/hosts/widgets/host_panel.dart': "a host's own panel, its head",
  'lib/features/hosts/widgets/hosts_table.dart': "the Hosts page's table, a column of its own",
  'lib/ui/screens/connection/connection_edit_screen.dart': "a host's own editor, its preview",
  'lib/ui/screens/connection/widgets/host_icon_picker.dart': 'the icons to pick from',
  'lib/ui/screens/desktop/widgets/monitor_detail_pane.dart': "a host's own panel, its head",
  'lib/ui/screens/desktop/widgets/session_slide_panel.dart': "a session's own panel, its head",
  'lib/ui/screens/terminal/widgets/session_info_dialog.dart': "a session's own details",
  'lib/ui/widgets/host_row.dart': 'the row itself',
  'lib/ui/widgets/mobile_session_tabs.dart': "a session's tab",
  'lib/ui/widgets/os_icon.dart': 'what draws a tab\'s',
  'lib/ui/widgets/terminal_tab_bar.dart': "a session's tab",
};

Iterable<File> _dartFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart') && !f.path.contains('generated'));

String _path(File f) => f.path.replaceAll(r'\', '/');

void main() {
  test('no list of hosts draws a bare server glyph: every use is listed, with why', () {
    final glyph = RegExp(r'LucideIcons\.server\b');
    final seen = <String, int>{};
    for (final f in _dartFiles()) {
      final path = _path(f);
      if (path.endsWith('lib/l10n/host_icon_names.dart') || path.endsWith('folder_icon_catalog.dart')) continue;
      final n = glyph.allMatches(f.readAsStringSync()).length;
      if (n > 0) seen[path] = n;
    }
    final bad = <String>[];
    seen.forEach((path, n) {
      final allowed = _serverGlyph[path]?.$1 ?? 0;
      if (n > allowed) {
        bad.add('$path draws $n, $allowed let be: a host in a list goes on HostRow or HostGlyph '
            '(lib/ui/widgets/host_row.dart); anything else is listed here with why');
      }
    });
    expect(bad, isEmpty, reason: bad.join('\n'));
    for (final e in _serverGlyph.entries) {
      if (e.value.$1 > 0) expect(e.value.$2, isNotEmpty, reason: 'why ${e.key} is let be');
    }
  });

  test("no list of hosts draws a host's icon by itself: every use is listed, with why", () {
    final icon = RegExp(r'\b(?:HostIcon|OsIconWidget|OsIcon)\(');
    final bad = <String>[];
    final drawing = <String>{};
    for (final f in _dartFiles()) {
      final path = _path(f);
      if (!icon.hasMatch(f.readAsStringSync())) continue;
      drawing.add(path);
      if (!_hostIcon.containsKey(path)) {
        bad.add("$path draws a host's icon by itself: use HostGlyph or HostRow (lib/ui/widgets/host_row.dart), "
            'or list it here with why');
      }
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
    // An entry that draws none any more is an open door for the next one
    // (found in a review): every entry is still needed.
    expect(_hostIcon.keys.where((p) => !drawing.contains(p)).toList(), isEmpty,
        reason: 'entries that no longer draw a host icon: take them off the list');
  });

  group('the row', () {
    Connection host({String label = 'web-01', int port = 22}) => Connection(
          id: 'h1',
          label: label,
          host: '192.0.2.10',
          port: port,
          colorIndex: 0,
          protocol: 'ssh',
          zlibCompression: false,
          keepAliveSeconds: 0,
          envVars: '',
          forwardAgent: false,
          compatibilityMode: false,
          sortOrder: 0,
          sizeTier: 1,
          pinned: false,
          monitored: false,
          createdAt: DateTime(2026, 10, 26),
          updatedAt: DateTime(2026, 10, 26),
        );

    Future<void> pump(WidgetTester tester, Widget child) async {
      SharedPreferences.setMockInitialValues({'os_kind_h1': 'ubuntu'});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: SizedBox(width: 600, child: child)),
        ),
      ));
      await tester.pump();
    }

    testWidgets("its icon is the host's own, never a server glyph; its words are its name and user@address",
        (tester) async {
      await pump(tester, HostRow(host: host(), user: 'deploy', onTap: () {}));
      expect(find.byType(HostGlyph), findsOneWidget);
      expect(find.byIcon(LucideIcons.server), findsNothing);
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('deploy@192.0.2.10'), findsOneWidget, reason: 'port 22 goes without saying');
    });

    testWidgets('another port is said, and no user is no @', (tester) async {
      await pump(tester, HostRow(host: host(port: 2222), onTap: () {}));
      expect(find.text('192.0.2.10:2222'), findsOneWidget);
    });

    testWidgets('an open session shows its dot; with no session none shows', (tester) async {
      await pump(tester, HostRow(host: host(), open: true, openLabel: 'Open', showOpenLabel: true));
      expect(find.byType(HostOpenDot), findsOneWidget);
      expect(find.text('Open'), findsOneWidget);
      await pump(tester, HostRow(host: host()));
      expect(find.byType(HostOpenDot), findsNothing);
    });

    testWidgets('one that cannot be picked says why, and a tap does nothing', (tester) async {
      var taps = 0;
      await pump(tester, HostRow(host: host(), unavailableReason: 'Why not', onTap: () => taps++));
      expect(find.text('Why not'), findsOneWidget);
      await tester.tap(find.text('web-01'));
      expect(taps, 0);
    });

    testWidgets('where the row is narrow the name stays, and the address goes', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 120, child: HostRow(host: host(), user: 'deploy')),
            ),
          ),
        ),
      ));
      await tester.pump();
      expect(find.text('web-01'), findsOneWidget);
      expect(find.text('deploy@192.0.2.10'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
