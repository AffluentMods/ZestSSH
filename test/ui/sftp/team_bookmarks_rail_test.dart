import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart' show decodePins;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_locations_rail.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';

import '../../helpers/orchard_db_fixture.dart';
import '../../helpers/played_sftp_host.dart';

/// A team host's shared SFTP bookmarks in the two-pane file screen's place
/// list (4.0: in a team, several people might go to
/// /opt/x/service, so these are shared). Under your own pins, a group
/// of the team's own; a member whose vault lets them edit the host adds the
/// folder shown, renames and removes; one who may only view sees them and
/// can change nothing; a personal host has no such group.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;

  @override
  Future<bool> hostAllows(String? connectionId, String what) async => true;
}

class _Ssh implements SshService {
  _Ssh(this.client, this.host);

  @override
  final SSHClient client;
  @override
  final String host;
  @override
  int get port => 22;
  @override
  String get username => 'deploy';
  @override
  bool get isEncryptedSsh => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not played: ${invocation.memberName}');
}

const _host = 'svc-host-1';
const _shared = '[{"label":"Service","path":"/opt/x/service"}]';
const _viewOnly = {CrateSwitches.connect, CrateSwitches.sftp};

SessionState _connected(String id, String label, PlayedConnection line, {required String connectionId}) => SessionState(
      status: SessionStatus.connected,
      connectionId: connectionId,
      connectionLabel: label,
      host: '$label.example.com',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: connectionId,
        terminal: Terminal(),
        shell: _Ssh(line.client, '$label.example.com'),
        startedAt: DateTime(2026, 11, 16),
      ),
    );

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  /// Lets the played hosts and the database answer, and the screen draw.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  /// The file screen with log-store (not a saved host) on the left and the
  /// saved host [_host], web-01, on the right; in a team whose vault gives
  /// [switches], or in your own space.
  Future<AppDatabase> pumpFiles(WidgetTester tester, {Set<String>? switches, String? shared = _shared}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final team = switches != null;
    final db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team);
    addTearDown(() => tester.runAsync(db.close));
    await tester.runAsync(() async {
      if (team) {
        await db.customStatement(
          'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
          "VALUES (1, ?, 'Platform team', 'member', 1, ?, '[]')",
          [kFixtureOrchardId, kFixtureCrateId],
        );
        await db.customStatement(
          'INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, ?, ?, ?, 1)',
          [kFixtureCrateId, 'Services', 'manage', jsonEncode(switches.toList()..sort())],
        );
        await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
      }
      await db.customStatement(
        'INSERT INTO connections (id, label, host, port, protocol, shared_pins, created_at, updated_at) '
        "VALUES (?, 'web-01', 'web-01.example.com', 22, 'ssh', ?, 0, 0)",
        [_host, shared],
      );
      if (team) {
        await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
        await db.customStatement(
          'INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision, edited_at) '
          "VALUES ('host', ?, ?, 2, 1)",
          [_host, kFixtureCrateId],
        );
      }
    });

    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(_Sessions.new),
      if (team) ...[
        activeSpaceProvider.overrideWith((ref) => const OrchardSpace(kFixtureOrchardId)),
        activeOrchardProvider.overrideWithValue(AsyncData(OrchardSummary(
          id: kFixtureOrchardId,
          name: 'Platform team',
          role: 'member',
          defaultCrateId: kFixtureCrateId,
          crates: [CrateSummary(id: kFixtureCrateId, name: 'Services', level: 'manage', switches: switches)],
        ))),
        itemCratesProvider.overrideWith(
            (ref, kind) => Stream.value(kind == 'host' ? const {_host: kFixtureCrateId} : const <String, String>{})),
      ],
    ]);
    addTearDown(container.dispose);

    final logs = PlayedSftpHost()..home = '/var/log';
    logs.files['/var/log/syslog'] = PlayedFile('x'.codeUnits);
    final web = PlayedSftpHost()..home = '/srv/app';
    web.files['/srv/app/notes.txt'] = PlayedFile('x'.codeUnits);
    web.files['/opt/x/service/app.conf'] = PlayedFile('x'.codeUnits);
    final logsLine = logs.connect();
    final webLine = web.connect();
    final left = SftpService(logsLine.client);
    final right = SftpService(webLine.client);
    await left.open();
    await right.open();
    (container.read(activeSessionsProvider.notifier) as _Sessions).set({
      's0': _connected('s0', 'log-store', logsLine, connectionId: 'c-s0'),
      's1': _connected('s1', 'web-01', webLine, connectionId: _host),
    });

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SftpDualPaneScreen(
            leftSftp: left,
            leftLabel: 'log-store',
            leftSessionId: 's0',
            sftp: right,
            connectionLabel: 'web-01',
            initialSessionId: 's1',
            embedded: true,
          ),
        ),
      ),
    ));
    await settle(tester);
    expect(find.text('notes.txt'), findsOneWidget);
    return db;
  }

  Finder inRail(String text) => find.descendant(of: find.byType(SftpLocationsRail), matching: find.text(text));
  SftpPaneState rightPane(WidgetTester tester) => tester.state<SftpPaneState>(find.byType(SftpPane).last);

  /// Right-clicks the empty place under the right pane's places.
  Future<void> rightClickEmptyRail(WidgetTester tester) async {
    final list = find.descendant(of: find.byType(SftpLocationsRail), matching: find.byType(ListView)).last;
    await tester.tapAt(tester.getBottomLeft(list) + const Offset(60, -12), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
  }

  Future<List<String>> sharedPaths(WidgetTester tester, AppDatabase db) async =>
      [for (final p in decodePins((await tester.runAsync(() => db.connectionsDao.getById(_host)))!.sharedPins)) p.path];

  testWidgets('a member who may edit the host: the group under their own pins, a click opens the folder, and they '
      'add, rename and remove', (tester) async {
    final db = await pumpFiles(tester, switches: {...CrateSwitches.all});

    // Your own pins, then the team's, then the filesystem's root.
    final caption = inRail(en.sftpTeamBookmarks);
    expect(caption, findsOneWidget);
    expect(inRail('Service'), findsOneWidget);
    expect(tester.getTopLeft(inRail('/tmp')).dy, lessThan(tester.getTopLeft(caption).dy));
    expect(tester.getTopLeft(caption).dy, lessThan(tester.getTopLeft(inRail('Service')).dy));
    expect(tester.getTopLeft(inRail('Service')).dy, lessThan(tester.getTopLeft(inRail('/').last).dy));
    expect(find.byTooltip(en.sftpTeamBookmarksViewOnly), findsNothing);

    await tester.tap(inRail('Service'));
    await settle(tester);
    expect(rightPane(tester).currentPath, '/opt/x/service');
    expect(find.text('app.conf'), findsOneWidget);

    // A folder already shared is not offered again.
    await rightClickEmptyRail(tester);
    expect(find.text(en.sftpAddTeamBookmark), findsOneWidget);
    await tester.tap(find.text(en.sftpAddTeamBookmark), warnIfMissed: false);
    await settle(tester);
    expect(await sharedPaths(tester, db), ['/opt/x/service']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // Another folder is.
    unawaited(rightPane(tester).navigateTo('/srv/app'));
    await settle(tester);
    await rightClickEmptyRail(tester);
    await tester.tap(find.text(en.sftpAddTeamBookmark));
    await settle(tester);
    expect(await sharedPaths(tester, db), ['/opt/x/service', '/srv/app']);
    expect(inRail('app'), findsOneWidget, reason: 'named after the folder');
    final queued = await tester.runAsync(() => db.customSelect('SELECT kind, item_key FROM crate_outbox').get());
    expect([for (final r in queued!) (r.read<String>('kind'), r.read<String>('item_key'))], [('host', _host)],
        reason: 'a change of the host, sent to the team');

    // Rename it.
    await tester.tap(inRail('app'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text(en.sftpRenameEllipsis));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text(en.sftpRenameTeamBookmark), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'App root');
    await tester.tap(find.text(en.sftpRename).last);
    await settle(tester);
    expect(inRail('App root'), findsOneWidget);

    // Remove one.
    await tester.tap(inRail('Service'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await tester.tap(find.text(en.sftpRemoveTeamBookmark));
    await settle(tester);
    expect(await sharedPaths(tester, db), ['/srv/app']);
    expect(inRail('Service'), findsNothing);
    await finish(tester);
  });

  testWidgets('a member who may only view the host sees the team bookmarks and can change none', (tester) async {
    await pumpFiles(tester, switches: _viewOnly);
    expect(inRail(en.sftpTeamBookmarks), findsOneWidget);
    expect(inRail('Service'), findsOneWidget);
    expect(find.byTooltip(en.sftpTeamBookmarksViewOnly), findsOneWidget);

    // A right click on one is a right click on the list (as on a drive's row).
    await tester.tap(inRail('Service'), buttons: kSecondaryMouseButton);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text(en.sftpRemoveTeamBookmark), findsNothing);
    expect(find.text(en.sftpRenameEllipsis), findsNothing);
    expect(find.text(en.sftpAddTeamBookmark), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    await rightClickEmptyRail(tester);
    expect(find.text(en.sftpBookmarkThisFolder), findsOneWidget, reason: 'their own pins are theirs');
    expect(find.text(en.sftpAddTeamBookmark), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));

    // A click still opens the folder.
    await tester.tap(inRail('Service'));
    await settle(tester);
    expect(rightPane(tester).currentPath, '/opt/x/service');
    await finish(tester);
  });

  testWidgets('a personal host has no shared group, and nothing offers one', (tester) async {
    await pumpFiles(tester);
    expect(inRail(en.sftpTeamBookmarks), findsNothing);
    expect(inRail('Service'), findsNothing, reason: 'a value left on a personal host is not shown');
    await rightClickEmptyRail(tester);
    expect(find.text(en.sftpBookmarkThisFolder), findsOneWidget);
    expect(find.text(en.sftpAddTeamBookmark), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    await finish(tester);
  });
}
