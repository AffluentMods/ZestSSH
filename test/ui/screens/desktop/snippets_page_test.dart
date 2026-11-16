import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';

import '../../../helpers/desktop_mouse.dart';
import '../../sharing_ui_fakes.dart' show FakeSessions;

/// The computer's Snippets page as designed:
/// one header row; chips of All, each folder with its count, Has
/// variables and Asks first; the list as rows grouped by folder, Run on a
/// row's hover; and beside it a snippet's details, read-only (Edit opens the
/// editor), whose Run goes to the session you're in, the one way a snippet
/// runs (its variables asked, the dangerous-command check).
class _Shell extends ShellService {
  final written = <int>[];
  String get text => utf8.decode(written);

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) => written.addAll(data);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    await db.close();
  });

  final host = ConnectionWithDetails(
    connection: Connection(
      id: 'c1',
      label: 'web-01',
      host: '192.0.2.21',
      port: 22,
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
      createdAt: DateTime(2026, 10, 2),
      updatedAt: DateTime(2026, 10, 2),
    ),
  );

  Future<List<Snippet>> seed(WidgetTester tester) async {
    final now = DateTime(2026, 10, 2);
    final rows = await tester.runAsync(() async {
      for (final (id, label, command, folder, confirm) in [
        ('d1', 'Running Containers', 'docker ps', 'Docker', false),
        ('d2', 'Container Logs', r'docker logs ${CONTAINER:-web} --tail 50', 'Docker', false),
        ('d3', 'Prune Unused', 'docker system prune -f', 'Docker', true),
        ('f1', 'Disk Usage', 'du -sh *', 'Files', false),
        ('r1', 'Pull Release', 'set -e\ncd /srv/shop\ngit pull', 'Deploy', false),
      ]) {
        await db.snippetsDao.insertSnippet(SnippetsCompanion(
          id: Value(id),
          label: Value(label),
          command: Value(command),
          category: Value(folder),
          confirmBeforeRun: Value(confirm),
          metadata: Value(id == 'd2' ? '{"variables":{"CONTAINER":"Container name"}}' : null),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
      }
      return db.snippetsDao.getAll();
    });
    return rows!;
  }

  Future<ProviderContainer> pumpPage(WidgetTester tester, List<Snippet> snippets,
      {_Shell? open, _Shell? second, bool onThisPage = false}) async {
    tester.view.physicalSize = const Size(2000, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final scope = ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        snippetsProvider.overrideWith((ref) => Stream.value(snippets)),
        snippetCategoryMetaProvider.overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value([host])),
        connectionGroupsProvider.overrideWith((ref) => Stream.value(const <ConnectionGroup>[])),
        activeSessionsProvider.overrideWith((ref) => FakeSessions(ref)
          ..show({
            if (open != null)
              's1': SessionState(
                status: SessionStatus.connected,
                connectionId: 'c1',
                connectionLabel: 'web-01',
                host: '192.0.2.21',
                port: 22,
                session: TerminalSession(
                  id: 's1',
                  connectionId: 'c1',
                  terminal: Terminal(),
                  shell: open,
                  startedAt: DateTime(2026, 10, 2),
                ),
              ),
            if (second != null)
              's2': SessionState(
                status: SessionStatus.connected,
                connectionId: 'c1',
                connectionLabel: 'web-01',
                host: '192.0.2.21',
                port: 22,
                session: TerminalSession(
                  id: 's2',
                  connectionId: 'c1',
                  terminal: Terminal(),
                  shell: second,
                  startedAt: DateTime(2026, 10, 3),
                ),
              ),
          })),
        if (open != null && !onThisPage) v3ActiveSessionTabProvider.overrideWith((ref) => 's1'),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SnippetsLibraryView()),
      ),
    );
    await tester.pumpWidget(scope);
    await tester.pumpAndSettle();
    return ProviderScope.containerOf(tester.element(find.byType(SnippetsLibraryView)));
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));
  }

  Finder row(String id) => find.byKey(ValueKey('snippet-row-$id'));

  desktopTest('the header, the chips with their counts, and the rows grouped by folder', (tester) async {
    await pumpPage(tester, await seed(tester));
    expect(find.text(l10n.zestSnippetsTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('snippets-new')), findsOneWidget);
    expect(find.widgetWithText(TextField, l10n.snippetPageFilterHint), findsOneWidget);
    expect(find.text(l10n.snippetPageSortYourOrder), findsOneWidget);
    // All 5, Docker 3, Files 1, Deploy 1, then the two filters.
    expect(find.descendant(of: find.byKey(const ValueKey('snippets-chip-all')), matching: find.text('5')),
        findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('snippets-chip-folder-Docker')), matching: find.text('3')),
        findsOneWidget);
    expect(find.byKey(const ValueKey('snippets-chip-vars')), findsOneWidget);
    expect(find.byKey(const ValueKey('snippets-chip-asks')), findsOneWidget);
    // A row: its variable counted in words, a confirming one says it asks
    // first, a script shows its first line and says it is one.
    expect(find.descendant(of: row('d2'), matching: find.text(l10n.snippetPageVariableCount(1))), findsOneWidget);
    expect(l10n.snippetPageVariableCount(1), isNot(contains('1')), reason: 'one, in words');
    expect(find.descendant(of: row('d3'), matching: find.text(l10n.snippetPageAsksFirst)), findsOneWidget);
    expect(
        find.descendant(
            of: row('r1'), matching: find.textContaining(l10n.snippetPageScript, findRichText: true)),
        findsOneWidget);
    expect(find.byKey(const ValueKey('snippet-row-run')), findsNothing, reason: 'Run shows on hover');
    await closePage(tester);
  });

  desktopTest('a folder chip shows that folder; Has variables and Asks first narrow it', (tester) async {
    await pumpPage(tester, await seed(tester));
    await tester.tap(find.byKey(const ValueKey('snippets-chip-folder-Files')));
    await tester.pumpAndSettle();
    expect(row('f1'), findsOneWidget);
    expect(row('d1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippets-chip-all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('snippets-chip-vars')));
    await tester.pumpAndSettle();
    expect(row('d2'), findsOneWidget);
    expect(row('d1'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('snippets-chip-asks')));
    await tester.pumpAndSettle();
    expect(row('d3'), findsOneWidget);
    expect(row('d2'), findsNothing);
    await closePage(tester);
  });

  desktopTest('a snippet\'s details: its folder, never run, its variable, how it runs; with no session Run is off',
      (tester) async {
    await pumpPage(tester, await seed(tester));
    await TestMouse(tester).click(row('d2'));
    expect(find.byKey(const ValueKey('snippet-detail-name')), findsOneWidget);
    expect(find.text('Docker · ${l10n.snippetPageNeverRun}'), findsOneWidget);
    expect(find.text(l10n.snippetPageAsksFor('Container name')), findsOneWidget);
    expect(find.text('web'), findsOneWidget, reason: 'its default');
    expect(find.text(l10n.snippetPageSessionYoureIn), findsNothing, reason: 'no default host, and in no session');
    expect(find.text(l10n.snippetPageNone), findsNWidgets(2), reason: 'neither that, nor any workflow that uses it');
    expect(find.text(l10n.snippetPageNo), findsOneWidget, reason: 'it does not ask first');
    expect(find.byKey(const ValueKey('snippet-detail-no-session')), findsOneWidget);
    final run = tester.widget<ZestButton>(find.byKey(const ValueKey('snippet-detail-run')));
    expect(run.onPressed, isNull, reason: 'no session is open');
    // Edit opens the editor with its command.
    await tester.tap(find.byKey(const ValueKey('snippet-detail-edit')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, r'docker logs ${CONTAINER:-web} --tail 50'), findsOneWidget);
    await closePage(tester);
  });

  desktopTest('with a session open, Run says where and runs there, its variable filled in', (tester) async {
    final shell = _Shell();
    await pumpPage(tester, await seed(tester), open: shell);
    await TestMouse(tester).click(row('d2'));
    expect(find.text(l10n.docCheckSnippetRunOnHost('web-01')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-detail-run')));
    await tester.pumpAndSettle();
    expect(shell.text, "docker logs 'web' --tail 50\r");
    await closePage(tester);
  });

  // A screenshot showed "No session is open" with three
  // session tabs open, the Snippets page itself not being one of them.
  desktopTest('on this page with one session open, Run says where and runs there', (tester) async {
    final shell = _Shell();
    await pumpPage(tester, await seed(tester), open: shell, onThisPage: true);
    await TestMouse(tester).click(row('d2'));
    expect(find.byKey(const ValueKey('snippet-detail-no-session')), findsNothing);
    expect(find.text(l10n.docCheckSnippetRunOnHost('web-01')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('snippet-detail-run')));
    await tester.pumpAndSettle();
    expect(shell.text, "docker logs 'web' --tail 50\r");
    await closePage(tester);
  });

  desktopTest('on this page with several open, it says so, and Run asks which, the open ones first', (tester) async {
    await pumpPage(tester, await seed(tester), open: _Shell(), second: _Shell(), onThisPage: true);
    await TestMouse(tester).click(row('d2'));
    expect(find.text(l10n.snippetPageNotInSession(2)), findsOneWidget);
    expect(find.text(l10n.snippetPageNoSession), findsNothing);
    final run = tester.widget<ZestButton>(find.byKey(const ValueKey('snippet-detail-run')));
    expect(run.onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('snippet-detail-run')));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionPickerDialog), findsOneWidget);
    expect(find.text(l10n.hostsSectionActive.toUpperCase()), findsOneWidget, reason: 'Active first, as a run picker has it');
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    await closePage(tester);
  });

  desktopTest("a row's Run, on hover, runs it in the session you're in", (tester) async {
    final shell = _Shell();
    await pumpPage(tester, await seed(tester), open: shell);
    final mouse = TestMouse(tester);
    await mouse.moveOver(row('d1'));
    expect(find.byKey(const ValueKey('snippet-row-run')), findsOneWidget);
    await mouse.click(find.byKey(const ValueKey('snippet-row-run')));
    expect(shell.text, 'docker ps\r');
    await closePage(tester);
  });
}
