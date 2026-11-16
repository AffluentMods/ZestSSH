import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart';
import 'package:zestssh/providers/monitoring_providers.dart';
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/ui/screens/desktop/widgets/monitor_table_view.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

import '../helpers/desktop_mouse.dart';

/// Server Monitor says why a host cannot be checked where a check of it
/// failed (3.0, the SSH core's audit), on the real screens: the status of a
/// computer's table, and the card of a phone's list. The check's failure
/// was shown nowhere: a host was "not responding to ping or SSH", or had
/// "failed SSH authentication" with a link to its sign-in details, whatever
/// the check had failed with.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  const notThere = JumpChainBroken(
      'The jump host that db-primary is set to connect through is no longer there. Open db-primary and pick another '
      'under Connect Via, or None.');

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({'agentless_monitor_enabled': true});
    prefs = await SharedPreferences.getInstance();
  });

  /// What was copied, once something was.
  String? copied;
  setUp(() {
    copied = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  /// A database with one monitored host, db-primary at port 2222, signed in to as deploy.
  Future<AppDatabase> seeded() async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final now = DateTime(2026, 1, 1);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'key-deploy', label: 'deploy key', username: 'deploy', authMethod: 'password', createdAt: now));
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'db',
          label: 'db-primary',
          host: '192.168.10.31',
          port: const Value(2222),
          identityId: const Value('key-deploy'),
          monitored: const Value(true),
          createdAt: now,
          updatedAt: now,
        ));
    return db;
  }

  /// [screen] with the host's check having failed with [failedWith].
  Widget shown(
    AppDatabase db,
    Widget screen,
    Object failedWith, {
    bool signInRefused = false,
    bool notTriedAgain = false,
    required Size size,
  }) =>
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          serverStatsProvider.overrideWith((ref) => _NoStats(ref)),
          agentlessMonitorPollerProvider.overrideWith((ref) => _Poller({
                'db': MonitorHostStatus(MonitorHostState.error,
                    failedWith: failedWith,
                    signInRefused: signInRefused,
                    notTriedAgain: notTriedAgain,
                    updatedAt: DateTime.now()),
              })),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: SizedBox(width: size.width, height: size.height, child: screen)),
        ),
      );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<void> finish(WidgetTester tester, AppDatabase db) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await db.close();
  }

  desktopTest('on a computer, the status of a host whose check failed says what it failed with, and has it to copy',
      (tester) async {
    final db = await seeded();
    const size = Size(1400, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shown(db, const MonitorTableView(), notThere, size: size));
    await settle(tester);

    // Its status, and under the mouse why.
    final pill = find.byKey(const ValueKey('monitor-status-db'));
    expect(find.text(notThere.message), findsNothing);
    await TestMouse(tester).moveOver(pill);
    await tester.pump();
    expect(find.text(en.zestMonitorTipCheckFailed), findsOneWidget);
    expect(find.text(notThere.message), findsOneWidget);
    // No link to the host's sign-in details: that is not what failed.
    expect(find.text(en.monitorTableFixLogin), findsNothing);

    // What is copied: what was said and what the check failed with, with the host's name taken out, as from
    // every report.
    await TestMouse(tester).click(find.byType(CopyDetailsButton));
    await tester.pump();
    expect(copied, contains('What: ${en.zestMonitorTipCheckFailed} The jump host that '));
    expect(copied, contains('is set to connect through is no longer there.'));
    expect(copied, contains('Where: Server Monitor: a check of a host'));
    expect(copied, isNot(contains('db-primary')));
    await tester.pump(const Duration(seconds: 3));
    await finish(tester, db);
  });

  desktopTest('on a computer, what a check failed with on the way to the host is said of that host, by its name and '
      'its port', (tester) async {
    final db = await seeded();
    const size = Size(1400, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const refused = SocketException('Connection refused', osError: OSError('Connection refused', 111));
    await tester.pumpWidget(shown(db, const MonitorTableView(), refused, size: size));
    await settle(tester);

    await TestMouse(tester).moveOver(find.byKey(const ValueKey('monitor-status-db')));
    await tester.pump();
    expect(find.text(en.zestMonitorTipNotReached), findsOneWidget);
    expect(find.text('db-primary is not accepting connections on port 2222.'), findsOneWidget);
    expect(find.text(en.monitorTableFixLogin), findsNothing);
    await finish(tester, db);
  });

  desktopTest('on a computer, a sign-in the host refused keeps its link to the sign-in details, behind who was '
      'refused and what the check failed with', (tester) async {
    final db = await seeded();
    const size = Size(1400, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ended = SSHAuthAbortError('Connection closed before authentication',
        SSHDisconnectError(2, 'Too many authentication failures', authentic: true));
    await tester.pumpWidget(shown(db, const MonitorTableView(), ended, signInRefused: true, size: size));
    await settle(tester);
    // The row's own line offers it.
    expect(find.text(en.monitorTableFixLogin), findsOneWidget);

    await TestMouse(tester).moveOver(find.byKey(const ValueKey('monitor-status-db')));
    await tester.pump();
    expect(find.text(en.zestMonitorTipSignInRefused), findsOneWidget);
    expect(find.textContaining(en.zestMonitorTipAuthUser('deploy')), findsOneWidget);
    expect(find.textContaining('Its reason: Too many authentication failures'), findsOneWidget);
    // And what the mouse shows, by the same name (it said Fix credentials
    // beside the row's Fix the login, as a design review found).
    expect(find.text(en.monitorTableFixLogin), findsNWidgets(2));
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    await finish(tester, db);
  });

  desktopTest('on a computer, a host that no timer tries again says so under why its check failed', (tester) async {
    final db = await seeded();
    const size = Size(1400, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final tooShort = SSHAuthAbortError('Connection closed before authentication',
        SSHKexGroupError('of 1024 bits', bits: 1024, shortestTaken: 2048));
    await tester.pumpWidget(shown(db, const MonitorTableView(), tooShort, notTriedAgain: true, size: size));
    await settle(tester);

    await TestMouse(tester).moveOver(find.byKey(const ValueKey('monitor-status-db')));
    await tester.pump();
    expect(find.text(en.zestMonitorTipCheckFailed), findsOneWidget);
    expect(find.textContaining('This host offers only an outdated key exchange (a group of 1024 bits'), findsOneWidget);
    expect(find.textContaining(en.zestMonitorTipNotTriedAgain), findsOneWidget);
    // It is no sign-in to mend in the host's sign-in details.
    expect(find.text(en.monitorTableFixLogin), findsNothing);
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    await finish(tester, db);

    // One that is tried again says nothing of it.
    final again = await seeded();
    await tester.pumpWidget(shown(again, const MonitorTableView(), tooShort, size: size));
    await settle(tester);
    await TestMouse(tester).moveOver(find.byKey(const ValueKey('monitor-status-db')));
    await tester.pump();
    expect(find.textContaining('This host offers only an outdated key exchange (a group of 1024 bits'), findsOneWidget);
    expect(find.textContaining(en.zestMonitorTipNotTriedAgain), findsNothing);
    await finish(tester, again);
  });

  testWidgets('on a phone, the card of a host that no timer tries again says so, and its status says it too',
      (tester) async {
    final db = await seeded();
    const size = Size(420, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shown(db, const ServerMonitorScreen(), SSHAuthFailError('All authentication methods failed'),
        signInRefused: true, notTriedAgain: true, size: size));
    await settle(tester);

    final said = '${en.zestMonitorTipSignInRefused}\n${en.zestMonitorTipAuthUser('deploy')}\n'
        '${en.zestMonitorTipNotTriedAgain}';
    expect(find.text(said), findsOneWidget);
    final tips = tester.widgetList<Tooltip>(find.byType(Tooltip)).map((tip) => tip.message);
    expect(tips, contains(said));
    expect(find.text(en.monitorTableFixLogin), findsOneWidget);
    await finish(tester, db);
  });

  testWidgets('on a phone, the card of a host whose check failed says what it failed with, and has it to copy',
      (tester) async {
    final db = await seeded();
    const size = Size(420, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(shown(db, const ServerMonitorScreen(), notThere, size: size));
    await settle(tester);

    expect(find.textContaining(en.zestMonitorTipCheckFailed), findsWidgets);
    expect(find.textContaining(notThere.message), findsWidgets);
    expect(find.text(en.monitorTableFixLogin), findsNothing);
    // A check ran and failed: not "never checked" under why (as a design
    // review found).
    expect(find.byKey(const ValueKey('monitor-card-never-checked')), findsNothing);
    // What is said takes the width of the card, and what can be done about it stands under it.
    final said = tester.getRect(find.textContaining(notThere.message).first);
    final copy = tester.getRect(find.byType(CopyDetailsButton));
    expect(copy.top, greaterThanOrEqualTo(said.bottom));

    await tester.tap(find.byType(CopyDetailsButton));
    await tester.pump();
    expect(copied, contains('What: ${en.zestMonitorTipCheckFailed} The jump host that '));
    expect(copied, contains('Where: Server Monitor: a check of a host'));
    expect(copied, isNot(contains('db-primary')));
    await tester.pump(const Duration(seconds: 3));
    await finish(tester, db);
  });

  testWidgets('on a phone, what a check failed with on the way to the host is said of that host, on its card and '
      'by its status; a sign-in the host refused keeps its link', (tester) async {
    final db = await seeded();
    const size = Size(420, 900);
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const refused = SocketException('Connection refused', osError: OSError('Connection refused', 111));
    await tester.pumpWidget(shown(db, const ServerMonitorScreen(), refused, size: size));
    await settle(tester);

    const said = 'db-primary is not accepting connections on port 2222.';
    expect(find.text('${en.zestMonitorTipNotReached}\n$said'), findsOneWidget);
    // And what its status says to whoever holds a finger on it, or has the screen read out.
    final tips = tester.widgetList<Tooltip>(find.byType(Tooltip)).map((tip) => tip.message);
    expect(tips, contains('${en.zestMonitorTipNotReached}\n$said'));
    expect(find.text(en.monitorTableFixLogin), findsNothing);
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    await finish(tester, db);

    // A sign-in the host refused: who was refused, the link to the sign-in details, and the report to copy.
    final again = await seeded();
    await tester.pumpWidget(shown(again, const ServerMonitorScreen(), SSHAuthFailError('All authentication methods failed'),
        signInRefused: true, size: size));
    await settle(tester);
    expect(find.text('${en.zestMonitorTipSignInRefused}\n${en.zestMonitorTipAuthUser('deploy')}'), findsOneWidget);
    expect(find.text(en.monitorTableFixLogin), findsOneWidget);
    expect(find.byType(CopyDetailsButton), findsOneWidget);
    await finish(tester, again);
  });
}

/// A stats notifier that never polls: the screens only have to paint the
/// host they are given.
class _NoStats extends ServerStatsNotifier {
  _NoStats(super.ref);

  @override
  Future<void> refreshAll() async {}

  @override
  Future<void> refreshOne(String connectionId) async {}

  @override
  void startAutoRefresh(int intervalSeconds) {}
}

/// Server Monitor's own connections as the test says they stand: nothing is
/// dialled.
class _Poller extends StateNotifier<Map<String, MonitorHostStatus>> implements AgentlessMonitorPoller {
  _Poller(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
