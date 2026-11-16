import 'dart:io';
import 'dart:convert';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/local_terminal.dart' show debugLocalTerminalOnThisDevice;
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/widgets/menu_dots_button.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

import '../../../helpers/desktop_mouse.dart';
import '../../sharing_ui_fakes.dart' show FakeSessions;

/// An open SSH session's shell, keeping what is written to it.
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

/// An open SSH session's shell that also reads a host's list of
/// containers: web and db.
class _ListShell extends _Shell implements ShellOneOff {
  @override
  Future<String?> runOnce(String command, {Duration timeout = const Duration(seconds: 10)}) async =>
      command.startsWith('docker ps') ? 'web\ndb\n' : null;
}

/// Sessions for the page: those [show]n, and each a Run opened to a host
/// with none ([opened]; nothing really connects).
class _Sessions extends FakeSessions {
  _Sessions(super.ref);

  final opened = <String>[];

  @override
  String? startSession(Connection connection,
      {bool allowDuplicate = false,
      String? usernameOverride,
      String? initialCommand,
      String? asAccount,
      bool unattended = false,
      Space? space}) {
    opened.add(connection.id);
    return 'opened-${connection.id}';
  }
}

/// The menus of a snippet on a computer: the three dots that show while the
/// mouse is over a card (the cards view), and the right click (a row of the
/// list, or a card). Both hold the same five
/// actions, and every one of them does what it says from either.
///
/// The three dots are only drawn while the mouse is over their card, and the
/// menu they open covers the card, so the mouse is no longer over it: in
/// 2.2.1 Delete from the three dots did nothing at all, while
/// Delete from the right click worked.
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
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
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
      for (final (id, label, command) in [
        ('s1', 'Disk space', 'df -h'),
        ('s2', 'Restart web', 'sudo systemctl restart nginx'),
      ]) {
        await db.snippetsDao.insertSnippet(SnippetsCompanion(
          id: Value(id),
          label: Value(label),
          command: Value(command),
          category: const Value('Northwind'),
          // The first has a description, as one written in the editor has.
          metadata: Value(id == 's1' ? '{"description":"How full the disks are"}' : null),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
      }
      return db.snippetsDao.getAll();
    });
    return rows!;
  }

  late _Sessions sessions;

  /// With [open], a session to the host of the page's host picker is open.
  Future<void> pumpPage(WidgetTester tester, List<Snippet> snippets,
      {ShellService? open}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        // What the page shows is held still: the test reads the database for
        // what a menu action did, and a live watch would leave its timers
        // behind when the page closes.
        snippetsProvider.overrideWith((ref) => Stream.value(snippets)),
        snippetCategoryMetaProvider
            .overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
        connectionsWithDetailsProvider
            .overrideWith((ref) => Stream.value([host])),
        connectionGroupsProvider
            .overrideWith((ref) => Stream.value(const <ConnectionGroup>[])),
        activeSessionsProvider.overrideWith((ref) => sessions = _Sessions(ref)
            ..show({
              if (open != null)
              's1': SessionState(
                status: SessionStatus.connected,
                connectionId: 'c1',
                connectionLabel: 'web-01',
                host: '192.0.2.21',
                port: 22,
                username: 'deploy',
                session: TerminalSession(
                  id: 's1',
                  connectionId: 'c1',
                  terminal: Terminal(),
                  shell: open,
                  startedAt: DateTime(2026, 10, 2),
                ),
              ),
            })),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SnippetsLibraryView()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// Lets a notice run out and closes the page, so nothing is left waiting.
  Future<void> closePage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  Finder dots() => find.byType(MenuDotsButton);
  Finder item(String label) => find.widgetWithText(PopupMenuItem<String>, label);
  const away = Offset(1390, 890);

  /// Opens the card's three dots menu with the mouse, as a person does:
  /// the cards view, move over the card, the dots show, click them.
  Future<TestMouse> openDots(WidgetTester tester, String card) async {
    if (find.byKey(const ValueKey('snippets-view-grid')).evaluate().isNotEmpty &&
        find.byType(MenuDotsButton).evaluate().isEmpty) {
      await TestMouse(tester).click(find.byKey(const ValueKey('snippets-view-grid')));
    }
    final mouse = TestMouse(tester);
    expect(dots(), findsNothing, reason: 'the dots only show under the mouse');
    await mouse.moveOver(find.text(card));
    expect(dots(), findsOneWidget);
    await mouse.click(dots());
    expect(item(l10n.zestSnippetsDelete), findsOneWidget);
    return mouse;
  }

  /// Opens the same menu with the right button.
  Future<TestMouse> openRightClick(WidgetTester tester, String card) async {
    final mouse = TestMouse(tester);
    await mouse.rightClick(find.text(card));
    expect(item(l10n.zestSnippetsDelete), findsOneWidget);
    return mouse;
  }

  Future<List<String>> labelsInDatabase(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.snippetsDao.getAll());
    return [for (final s in rows!) s.label]..sort();
  }

  Finder inConfirm(String label) => find.descendant(
      of: find.byType(ZestConfirmDialog), matching: find.text(label));

  for (final (way, open) in [
    ('the three dots', openDots),
    ('a right click', openRightClick),
  ]) {
    group('From $way', () {
      desktopTest('Delete asks first, and deletes when confirmed',
          (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsDelete));

        expect(find.text(l10n.snippetsLibraryDeleteConfirmTitle('Disk space')),
            findsOneWidget,
            reason: 'Delete asks before it deletes');
        expect(await labelsInDatabase(tester), ['Disk space', 'Restart web'],
            reason: 'nothing is deleted before the answer');

        await tester.tap(inConfirm(l10n.snippetsLibraryDeleteConfirmAction));
        await tester.pumpAndSettle();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        expect(await labelsInDatabase(tester), ['Restart web']);
        await closePage(tester);
      });

      desktopTest('Delete that is not confirmed deletes nothing',
          (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsDelete));
        expect(find.byType(ZestConfirmDialog), findsOneWidget);
        await tester.tap(inConfirm(l10n.cancel));
        await tester.pumpAndSettle();

        expect(find.byType(ZestConfirmDialog), findsNothing);
        expect(await labelsInDatabase(tester), ['Disk space', 'Restart web']);
        await closePage(tester);
      });

      desktopTest('Copy puts the command on the clipboard', (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Restart web');
        await mouse.click(item(l10n.zestSnippetsCopy));

        expect(copied, ['sudo systemctl restart nginx']);
        await closePage(tester);
      });

      desktopTest('Duplicate makes a second snippet with the same command',
          (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsDuplicate));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));

        final rows = await tester.runAsync(() => db.snippetsDao.getAll());
        expect(rows!.where((s) => s.command == 'df -h'), hasLength(2));
        expect([for (final s in rows) s.label],
            contains(l10n.snippetsLibraryDuplicateLabel('Disk space')));
        // Its description and notes come along (the copy had none of them).
        final copy = rows.singleWhere((s) => s.label == l10n.snippetsLibraryDuplicateLabel('Disk space'));
        expect(copy.metadata, '{"description":"How full the disks are"}');
        // The copy is said, with its name.
        await tester.pump();
        final said = ProviderScope.containerOf(tester.element(find.byType(SnippetsLibraryView)))
            .read(notificationCenterProvider)
            .history;
        expect([for (final n in said) n.title],
            [l10n.snippetAddedToast(l10n.snippetsLibraryDuplicateLabel('Disk space'))]);
        // A phone's Duplicate makes the same copy.
        final phone = File('lib/ui/screens/snippets/snippets_screen.dart').readAsStringSync();
        final at = phone.indexOf('Future<void> _duplicateSnippet(');
        expect(phone.substring(at, phone.indexOf('Future<void> _confirmDelete(', at)),
            contains('metadata: snippet.metadata,'));
        await closePage(tester);
      });

      desktopTest('Run on hosts opens it with the snippet\'s command', (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Restart web');
        await mouse.click(item(l10n.runOnHostsMenu));

        expect(find.byType(RunOnHostsDialog), findsOneWidget);
        expect(
            find.descendant(
                of: find.byType(RunOnHostsDialog),
                matching: find.widgetWithText(TextField, 'sudo systemctl restart nginx')),
            findsOneWidget);
        await tester.tap(find.descendant(of: find.byType(RunOnHostsDialog), matching: find.text(l10n.cancel)));
        await tester.pumpAndSettle();
        expect(find.byType(RunOnHostsDialog), findsNothing);
        await closePage(tester);
      });

      desktopTest('Edit opens the snippet in the editor', (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);
        expect(find.widgetWithText(TextField, 'df -h'), findsNothing);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsEdit));

        expect(find.widgetWithText(TextField, 'df -h'), findsOneWidget,
            reason: 'the editor holds the command of the snippet picked');
        await closePage(tester);
      });

      desktopTest('Run on asks which host, and hands it the command',
          (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsRunOn));

        expect(find.text(l10n.zestSnippetsRunOnTitle), findsOneWidget,
            reason: 'the host picker opens');
        await tester.tap(find.text('web-01'));
        await tester.pumpAndSettle();

        // No session is open to that host: one is opened, and the command is
        // entered there once it connects (it was copied, and nothing ran).
        expect(sessions.opened, ['c1']);
        expect(copied, isEmpty);
        await closePage(tester);
      });

      desktopTest("Run on's first choice is Local terminal: picked, a terminal on this device opens",
          (tester) async {
        debugLocalTerminalOnThisDevice = true;
        addTearDown(() => debugLocalTerminalOnThisDevice = null);
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        final mouse = await open(tester, 'Disk space');
        await mouse.click(item(l10n.zestSnippetsRunOn));

        final local = find.byKey(const ValueKey('host-picker-local-terminal'));
        expect(local, findsOneWidget);
        expect(tester.getTopLeft(local).dy,
            lessThan(tester.getTopLeft(find.byKey(const ValueKey('host-picker-c1'))).dy),
            reason: 'above the hosts');
        await tester.tap(local);
        await tester.pumpAndSettle();

        expect(sessions.opened, [startsWith('local_')], reason: 'a host made for the moment, never saved');
        expect(copied, isEmpty);
        // The page's sessions are held still, so the new one never connects
        // and that is said: its notice runs out first.
        await tester.pump(const Duration(seconds: 8));
        await closePage(tester);
      });

      desktopTest('closing the menu without a pick does nothing',
          (tester) async {
        final snippets = await seed(tester);
        await pumpPage(tester, snippets);

        await open(tester, 'Disk space');
        await tester.tapAt(away);
        await tester.pumpAndSettle();

        expect(item(l10n.zestSnippetsDelete), findsNothing);
        expect(find.byType(Dialog), findsNothing);
        expect(copied, isEmpty);
        expect(await labelsInDatabase(tester), ['Disk space', 'Restart web']);
        await closePage(tester);
      });
    });
  }

  desktopTest('the three dots stay while their menu is open, and go after',
      (tester) async {
    final snippets = await seed(tester);
    await pumpPage(tester, snippets);

    final mouse = await openDots(tester, 'Disk space');

    expect(dots(), findsOneWidget,
        reason: 'the menu covers the card, the dots it came from stay');

    // The menu closes with the mouse somewhere else: the dots go.
    await mouse.clickAt(away);
    expect(item(l10n.zestSnippetsDelete), findsNothing);
    expect(dots(), findsNothing);
    await closePage(tester);
  });

  desktopTest('the dots of one card act on that card', (tester) async {
    final snippets = await seed(tester);
    await pumpPage(tester, snippets);

    final mouse = await openDots(tester, 'Restart web');
    await mouse.click(item(l10n.zestSnippetsDelete));

    expect(find.text(l10n.snippetsLibraryDeleteConfirmTitle('Restart web')),
        findsOneWidget);
    await tester.tap(inConfirm(l10n.snippetsLibraryDeleteConfirmAction));
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(await labelsInDatabase(tester), ['Disk space']);
    await closePage(tester);
  });

  desktopTest('the menus hold the same actions in the same order',
      (tester) async {
    final snippets = await seed(tester);
    await pumpPage(tester, snippets);

    List<String> shown() => [
          for (final e in tester.widgetList<PopupMenuItem<String>>(
              find.byType(PopupMenuItem<String>)))
            e.value!,
        ];

    await openDots(tester, 'Disk space');
    final fromDots = shown();
    await tester.tapAt(away);
    await tester.pumpAndSettle();

    await openRightClick(tester, 'Disk space');
    final fromRightClick = shown();

    expect(fromDots, ['edit', 'copy', 'duplicate', 'run', 'run-hosts', 'delete']);
    expect(fromRightClick, fromDots);
    await tester.tapAt(away);
    await tester.pumpAndSettle();
    await closePage(tester);
  });
  group('Run on, with a session open to the host', () {
    Future<List<Snippet>> seedOne(WidgetTester tester, String command) async {
      final now = DateTime(2026, 10, 2);
      final rows = await tester.runAsync(() async {
        // Put there as another device or an older version left it: the line
        // ends of the machine it was written on.
        await db.snippetsDao.insertSnippet(SnippetsCompanion(
          id: const Value('s9'),
          label: const Value('Deploy'),
          command: Value(command),
          createdAt: Value(now),
          updatedAt: Value(now),
        ));
        return db.snippetsDao.getAll();
      });
      return rows!;
    }

    Future<void> runOn(WidgetTester tester) async {
      final mouse = await openRightClick(tester, 'Deploy');
      await mouse.click(item(l10n.zestSnippetsRunOn));
      await tester.tap(find.text('web-01'));
      await tester.pumpAndSettle();
    }

    desktopTest('a snippet of one line is typed and entered', (tester) async {
      final shell = _Shell();
      await pumpPage(tester, await seedOne(tester, 'uptime'), open: shell);

      await runOn(tester);

      expect(shell.text, 'uptime\r');
      expect(copied, isEmpty, reason: 'it went to the session, not the clipboard');
      await closePage(tester);
    });

    desktopTest('a snippet written on Windows gets one Enter per line',
        (tester) async {
      final shell = _Shell();
      await pumpPage(
          tester,
          await seedOne(tester, '(\r\nset -e\r\ncd /srv/app\r\nnpm ci\r\n)'),
          open: shell);

      await runOn(tester);

      expect(shell.text, '(\rset -e\rcd /srv/app\rnpm ci\r)\r',
          reason: 'each line once: no empty line after every line');
      await closePage(tester);
    });

    desktopTest('Run in the editor types what the editor holds, the same way',
        (tester) async {
      final shell = _Shell();
      await pumpPage(
          tester, await seedOne(tester, 'cd /srv/app\r\nnpm ci\r\n'),
          open: shell);

      final mouse = TestMouse(tester);
      await mouse.click(find.text('Deploy'));
      // Its details show; Edit opens the editor.
      await tester.tap(find.byKey(const ValueKey('snippet-detail-edit')));
      await tester.pumpAndSettle();
      // The editor's own Run, in its header.
      await tester.tap(find.text(l10n.zestSnippetsRunButton).first);
      await tester.pumpAndSettle();
      expect(find.text(l10n.zestSnippetsRunOnTitle), findsOneWidget);
      await tester.tap(find.text('web-01'));
      await tester.pumpAndSettle();

      expect(shell.text, 'cd /srv/app\rnpm ci\r');
      await closePage(tester);
    });

    desktopTest('a snippet that ends with a line end is entered once',
        (tester) async {
      final shell = _Shell();
      await pumpPage(tester, await seedOne(tester, 'df -h\n'), open: shell);

      await runOn(tester);

      expect(shell.text, 'df -h\r');
      await closePage(tester);
    });

    // Found while comparing the five versions: Run on sent a
    // snippet as written, ${VAR} and all, with no dangerous-command check.
    desktopTest('its variables are asked for and filled in; one with a default takes it', (tester) async {
      final shell = _Shell();
      await pumpPage(tester, await seedOne(tester, r'echo ${GREETING:-hi} ${NAME}'), open: shell);

      await runOn(tester);
      expect(shell.text, isEmpty, reason: 'not before its variable is filled in');
      await tester.enterText(find.widgetWithText(TextField, l10n.snippetVarEnterHint('name')), 'world');
      await tester.pump();
      // The question's own button, in its footer, which says Run.
      expect(find.descendant(of: find.byKey(const ValueKey('snippet-variable-next')), matching: find.text(l10n.zestSnippetsRunButton)),
          findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('snippet-variable-next')));
      await tester.pumpAndSettle();

      expect(shell.text, "echo 'hi' 'world'\r", reason: r'it was sent as written: echo ${GREETING:-hi} ${NAME}');
      await closePage(tester);
    });

    // Found while comparing the five versions: a list of the
    // host's own ($[DOCKER]) said there was no session.
    desktopTest("a list of the host's own is read on the session it goes to, and what is picked is sent", (tester) async {
      final shell = _ListShell();
      await pumpPage(tester, await seedOne(tester, r'docker logs $[DOCKER]'), open: shell);

      await runOn(tester);
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pumpAndSettle();
      expect(find.text('web'), findsOneWidget);
      await tester.tap(find.text('db'));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('snippet-variable-next')));
      await tester.pumpAndSettle();

      expect(shell.text, "docker logs 'db'\r");
      await closePage(tester);
    });

    desktopTest('a dangerous command is asked about first: Cancel sends nothing, Run anyway sends it', (tester) async {
      final shell = _Shell();
      await pumpPage(tester, await seedOne(tester, 'rm -rf /var/www'), open: shell);

      await runOn(tester);
      expect(find.text(l10n.dangerCommandTitle), findsOneWidget, reason: 'it was sent with no question');
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(shell.text, isEmpty);

      await runOn(tester);
      await tester.tap(find.text(l10n.dangerRunAnyway));
      await tester.pumpAndSettle();
      expect(shell.text, 'rm -rf /var/www\r');
      await closePage(tester);
    });
  });
}
