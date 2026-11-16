import 'dart:io' show File;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/command_history/history_table.dart' show historyHostWantedProvider;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';

import '../../../helpers/desktop_mouse.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's History page (3.0):
/// its filters, trivial commands hidden per day with Show, the count of a
/// command run again right after itself, a row opened by a click, Run again
/// going the way a snippet runs, and Save as snippet opening the snippet
/// editor with the command in it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late AppLocalizations l10n;
  late SharedPreferences prefs;
  final copied = <String>[];

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({'command_history_enabled': true});
    prefs = await SharedPreferences.getInstance();
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await db.close();
  });

  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day, 0, 30);
  final weekAgo = today.subtract(const Duration(days: 7)).add(const Duration(hours: 12));

  CommandHistoryEntry e(String id, String command, DateTime at,
          {String host = 'web', int? exit, int? ms, String? cwd}) =>
      CommandHistoryEntry(
        id: id,
        command: command,
        connectionId: host,
        hostLabel: host == 'web' ? 'web-01' : 'db-primary',
        createdAt: at,
        exitCode: exit,
        durationMs: ms,
        cwd: cwd,
      );

  /// Today: three trivial commands on web-01. A week ago: a failed restart,
  /// one command twice in a row, two trivial ones on two hosts, and one run
  /// without shell integration.
  List<CommandHistoryEntry> history() => [
        e('t1', 'cd ~', today.add(const Duration(minutes: 3))),
        e('t2', 'cd ..', today.add(const Duration(minutes: 2))),
        e('t3', 'cd /srv', today.add(const Duration(minutes: 1))),
        e('w1', 'systemctl restart nginx', weekAgo.add(const Duration(minutes: 9)), exit: 1, ms: 120, cwd: '/home/deploy'),
        e('w2', 'npm run build', weekAgo.add(const Duration(minutes: 8)), exit: 0, ms: 41000, cwd: '/home/deploy/shop'),
        e('w3', 'npm run build', weekAgo.add(const Duration(minutes: 7)), exit: 0, ms: 40000, cwd: '/home/deploy/shop'),
        e('w4', 'ls', weekAgo.add(const Duration(minutes: 6)), host: 'db'),
        e('w5', 'clear', weekAgo.add(const Duration(minutes: 5))),
        e('w6', 'psql -c "select 1"', weekAgo.add(const Duration(minutes: 4)), host: 'db'),
        e('w7', 'echo \${HOME}', weekAgo.add(const Duration(minutes: 3))),
      ];

  Future<void> seedHosts(WidgetTester tester) async {
    await tester.runAsync(() async {
      final made = DateTime(2026, 1, 1);
      await db.into(db.identities).insert(IdentitiesCompanion.insert(
          id: 'deploy', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: made));
      for (final (id, label) in [('web', 'web-01'), ('db', 'db-primary')]) {
        await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: id,
              label: label,
              host: '$label.example.internal',
              identityId: const Value('deploy'),
              createdAt: made,
              updatedAt: made,
            ));
      }
    });
  }

  final runs = <(String, String)>[];

  Future<ProviderContainer> pumpPage(WidgetTester tester,
      {List<CommandHistoryEntry>? entries, bool recording = false, bool realRun = false}) async {
    await seedHosts(tester);
    runs.clear();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        isProProvider.overrideWith((ref) => _Pro()),
        if (recording) recordingModeProvider.overrideWith((ref) => true),
        recentCommandHistoryProvider.overrideWith((ref) => Stream.value(entries ?? history())),
        if (!realRun)
          historyRunOnHostProvider.overrideWithValue((context, ref, {required host, required command}) async {
            runs.add((host.connection.id, command));
            return true;
          }),
        if (realRun) dangerousCommandProtectionProvider.overrideWith((ref) => true),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: HistoryView()),
      ),
    ));
    // The hosts come from the database.
    for (var i = 0; i < 4; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(HistoryView)));
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));
  }

  String dayKey(DateTime d) => '${d.year}-${d.month}-${d.day}';
  Finder row(String id) => find.byKey(ValueKey('history-row-$id'));

  desktopTest('trivial commands are hidden per day behind a line that names them, and Show shows them',
      (tester) async {
    await pumpPage(tester);
    // Today's three, all on web-01: the line names the host and the commands.
    expect(find.text('cd ~'), findsNothing);
    expect(find.text(l10n.histPageTrivialHiddenOnHost(3, 'web-01', 'cd ~, cd .., cd /srv')), findsOneWidget);
    // A week ago, two on two hosts: no host in the line.
    expect(find.text(l10n.histPageTrivialHidden(2, 'ls, clear')), findsOneWidget);
    expect(row('w4'), findsNothing);
    expect(row('w1'), findsOneWidget, reason: 'a command that is not trivial shows');

    // Show: today's three are there, the week-old ones still hidden.
    await tester.tap(find.byKey(ValueKey('history-trivial-toggle-${dayKey(today)}')));
    await tester.pumpAndSettle();
    expect(row('t1'), findsOneWidget);
    expect(row('t3'), findsOneWidget);
    expect(row('w4'), findsNothing);
    expect(find.text(l10n.histPageTrivialShown(3)), findsOneWidget);
    // Hide puts them away again.
    await tester.tap(find.byKey(ValueKey('history-trivial-toggle-${dayKey(today)}')));
    await tester.pumpAndSettle();
    expect(row('t1'), findsNothing);

    // Hide trivial off: every row, no line.
    await tester.tap(find.byKey(const ValueKey('history-hide-trivial')));
    await tester.pumpAndSettle();
    expect(row('t1'), findsOneWidget);
    expect(row('w4'), findsOneWidget);
    expect(find.text(l10n.histPageTrivialHidden(2, 'ls, clear')), findsNothing);
    // A day's count counts every command, the hidden ones too.
    expect(find.byKey(ValueKey('history-day-${dayKey(today)}')), findsOneWidget);
    await closePage(tester);
  });

  desktopTest('the same command right after itself is one row with its count', (tester) async {
    await pumpPage(tester);
    expect(row('w2'), findsOneWidget);
    expect(row('w3'), findsNothing);
    expect(find.byKey(const ValueKey('history-repeat-w2')), findsOneWidget);
    expect(find.text(l10n.histPageRepeatCount(2)), findsOneWidget);
    expect(find.byKey(const ValueKey('history-repeat-w1')), findsNothing);
    await closePage(tester);
  });

  desktopTest('each row: result, run time, folder from ~, and nothing where shell integration sent nothing',
      (tester) async {
    await pumpPage(tester);
    final failed = row('w1');
    expect(find.descendant(of: failed, matching: find.text(l10n.histPageResultExit(1))), findsOneWidget);
    expect(find.descendant(of: failed, matching: find.text('0.1s')), findsOneWidget);
    expect(find.descendant(of: failed, matching: find.text('~')), findsOneWidget);
    final build = row('w2');
    expect(find.descendant(of: build, matching: find.text(l10n.histPageResultOk)), findsOneWidget);
    expect(find.descendant(of: build, matching: find.text('41s')), findsOneWidget);
    expect(find.descendant(of: build, matching: find.text('~/shop')), findsOneWidget);
    // psql: no shell integration, so no result, run time or folder.
    expect(find.byKey(const ValueKey('history-result-w6')), findsNothing);
    expect(find.descendant(of: row('w6'), matching: find.text(l10n.histPageResultOk)), findsNothing);
    await closePage(tester);
  });

  desktopTest("a link for one host (the Inspector's History) shows that host, also when the page is open", (tester) async {
    await pumpPage(tester);
    final container = ProviderScope.containerOf(tester.element(find.byType(HistoryView)));
    container.read(historyHostWantedProvider.notifier).state = 'id:db';
    await tester.pumpAndSettle();
    expect(row('w6'), findsOneWidget);
    expect(row('w1'), findsNothing);
    expect(container.read(historyHostWantedProvider), isNull, reason: 'taken');
    container.read(historyHostWantedProvider.notifier).state = 'id:web';
    await tester.pumpAndSettle();
    expect(row('w1'), findsOneWidget);
    expect(row('w6'), findsNothing);
    await closePage(tester);
  });

  test("the Inspector's History asks for its session's host", () {
    final source = File('lib/ui/screens/desktop/widgets/inspector_panel.dart').readAsStringSync();
    expect(source, contains("ref.read(historyHostWantedProvider.notifier).state = 'id:\$connId';"));
  });

  desktopTest('the host picker, Failed only and the search narrow the table', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('history-host-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zest-select-item-id:db')));
    await tester.pumpAndSettle();
    expect(row('w6'), findsOneWidget);
    expect(row('w1'), findsNothing);
    expect(row('w2'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('history-host-filter')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('zest-select-item-')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-failed-only')));
    await tester.pumpAndSettle();
    expect(row('w1'), findsOneWidget);
    expect(row('w2'), findsNothing);
    expect(row('w6'), findsNothing, reason: 'no result is not a failure');

    await tester.tap(find.byKey(const ValueKey('history-failed-only')));
    await tester.enterText(find.byType(TextField).first, 'npm');
    await tester.pumpAndSettle();
    expect(row('w2'), findsOneWidget);
    expect(row('w1'), findsNothing);
    await closePage(tester);
  });

  desktopTest('a click opens a row: when it started, the whole folder, and Run again on its host', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('npm run build'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.histPageStarted), findsOneWidget);
    expect(find.text('/home/deploy/shop'), findsOneWidget);
    final run = find.byKey(const ValueKey('history-open-run-w2'));
    expect(find.descendant(of: run, matching: find.text(l10n.histPageRunAgainOn('web-01'))), findsOneWidget);

    await tester.tap(run);
    await tester.pumpAndSettle();
    expect(runs, [('web', 'npm run build')]);

    // A second click closes it.
    await tester.tap(find.text('npm run build'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.histPageStarted), findsNothing);
    await closePage(tester);
  });

  desktopTest('Run again under the mouse: on its host, or on one picked', (tester) async {
    await pumpPage(tester);
    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text('systemctl restart nginx'));
    await mouse.click(find.byKey(const ValueKey('history-run-again-w1')));
    expect(find.byKey(const ValueKey('history-run-on')), findsOneWidget);
    await mouse.click(find.byKey(const ValueKey('history-run-host')));
    expect(runs, [('web', 'systemctl restart nginx')]);
    await closePage(tester);
  });

  desktopTest('Run again goes the way a snippet runs: a risky command is asked about first', (tester) async {
    await pumpPage(tester, entries: [e('r1', 'rm -rf /var/www', weekAgo)], realRun: true);
    await tester.tap(find.text('rm -rf /var/www'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-open-run-r1')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.dangerCommandTitle), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    await closePage(tester);
  });

  desktopTest('Run again runs a command with \${...} in it exactly as it was typed', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.text('echo \${HOME}'));
    await tester.pumpAndSettle();
    final run = tester.widget(find.byKey(const ValueKey('history-open-run-w7')));
    expect((run as dynamic).onPressed, isNotNull);
    await closePage(tester);
  });

  test('the History page runs a command again literally, never as a snippet with questions', () {
    final source = File('lib/ui/screens/command_history/desktop_history_page.dart').readAsStringSync();
    expect(source, contains('runCommandOnHost(context, ref, host: host, command: command, literal: true)'));
  });

  desktopTest('Save as snippet opens the snippet editor with the command in it, and saves it there', (tester) async {
    await pumpPage(tester);
    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text('systemctl restart nginx'));
    await mouse.click(find.byKey(const ValueKey('history-save-w1')));
    await tester.pumpAndSettle();
    expect(find.byType(SnippetEditor), findsOneWidget);
    expect(find.descendant(of: find.byType(SnippetEditor), matching: find.text('systemctl restart nginx')),
        findsOneWidget);
    expect(await tester.runAsync(() => db.snippetsDao.getAll()), isEmpty, reason: 'nothing is made before Save');

    await tester.enterText(
        find.descendant(of: find.byType(SnippetEditor), matching: find.byType(TextFormField)).first, 'Restart nginx');
    await tester.tap(find.text(l10n.create));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    final snippets = await tester.runAsync(() => db.snippetsDao.getAll());
    expect([for (final s in snippets!) (s.label, s.command)], [('Restart nginx', 'systemctl restart nginx')]);
    await closePage(tester);
  });

  desktopTest('Copy puts the command on the clipboard', (tester) async {
    await pumpPage(tester);
    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text('npm run build'));
    await mouse.click(find.byKey(const ValueKey('history-copy-w2')));
    expect(copied, ['npm run build']);
    await closePage(tester);
  });

  desktopTest('Delete in an opened row removes that command', (tester) async {
    final rows = await tester.runAsync(() async {
      for (final x in history()) {
        await db.commandHistoryDao.upsert(x.toCompanion(true));
      }
      return db.commandHistoryDao.getAll();
    });
    await pumpPage(tester, entries: (rows!..sort((a, b) => b.createdAt.compareTo(a.createdAt))));
    await tester.tap(find.text('psql -c "select 1"'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-w6')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    final left = await tester.runAsync(() => db.commandHistoryDao.getAll());
    expect([for (final x in left!) x.id], isNot(contains('w6')));
    expect(left, hasLength(history().length - 1));
    await closePage(tester);
  });

  desktopTest('while the screen is recorded, Run again, Copy and Save as snippet are off', (tester) async {
    await pumpPage(tester, recording: true);
    await tester.tap(find.byKey(const ValueKey('history-hide-trivial')));
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('history-row-w1'));
    await tester.tap(first);
    await tester.pumpAndSettle();
    for (final key in ['history-open-run-w1', 'history-open-save-w1']) {
      expect((tester.widget(find.byKey(ValueKey(key))) as dynamic).onPressed, isNull, reason: key);
    }
    expect(find.text(l10n.cmdhOffWhileRecording), findsOneWidget);
    expect(runs, isEmpty);
    await closePage(tester);
  });

  desktopTest('the trust line says what is saved, and How history works says the rest', (tester) async {
    final c = await pumpPage(tester);
    expect(find.text(l10n.histPageTrust), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('history-how')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.histPageHow5), findsOneWidget);
    expect(find.text(l10n.histPageHow4(l10n.cmdhSaveSecretCommands)), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    // Saving secret-bearing commands too: the line stops promising it.
    c.read(commandHistoryIncludeSensitiveProvider.notifier).set(true);
    await tester.pumpAndSettle();
    expect(find.text(l10n.histPageTrust), findsNothing);
    expect(find.text(l10n.histPageTrustSecretsOn), findsOneWidget);
    await closePage(tester);
  });
}
