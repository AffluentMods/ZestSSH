import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';

import '../../helpers/played_sftp_host.dart';

/// "SFTP: sync with the terminal's folder" (4.0, a user's suggestion): the
/// SFTP dock beside a terminal opens the folder its terminal said it is in,
/// once ("Go to the terminal's folder") or each time it changes ("Follow the
/// terminal", kept on this computer). Where the terminal said none, it shows
/// how to make the shell say it; where the host has no such folder (the
/// terminal went on to another computer with ssh), it says so and stays.

class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;

  @override
  Future<bool> hostAllows(String? connectionId, String what) async => true;
}

class _Ssh implements SshService {
  _Ssh(this.client);

  @override
  final SSHClient client;
  @override
  String get host => 'web-01.example.com';
  @override
  int get port => 22;
  @override
  String get username => 'deploy';
  @override
  bool get isEncryptedSsh => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not played: ${invocation.memberName}');
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group("the dock's header", () {
    Future<ProviderContainer> pumpHeader(WidgetTester tester, {SftpDockSide side = SftpDockSide.bottom}) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: SizedBox(
                width: side == SftpDockSide.bottom ? 900 : 420,
                height: 400,
                child: SftpDockFrame(
                  sessionId: 's1',
                  sessionState: null,
                  side: side,
                  canMoveRight: true,
                  onClose: () {},
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      );
      return c;
    }

    final goButton = find.byKey(const ValueKey('sftp-dock-terminal-folder'));
    final followButton = find.byKey(const ValueKey('sftp-dock-follow-terminal'));
    TerminalFolderRequest? asked(ProviderContainer c) => c.read(terminalFolderRequestProvider('s1'));

    testWidgets('the terminal said nothing: the button says so, and shows the lines for bash and zsh to copy', (
      tester,
    ) async {
      final c = await pumpHeader(tester);
      expect(find.byTooltip(en.sftpTerminalFolderNoneTip), findsOneWidget);
      await tester.tap(goButton);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('terminal-folder-help')), findsOneWidget);
      expect(find.text(en.sftpTerminalFolderNoneTitle), findsOneWidget);
      expect(find.text(kTerminalFolderBashLine), findsOneWidget);
      expect(find.text(kTerminalFolderZshLine), findsOneWidget);
      expect(kTerminalFolderBashLine, contains(r'\e]7;file://'));
      expect(kTerminalFolderZshLine, contains('add-zsh-hook precmd'));
      expect(asked(c), isNull, reason: 'nothing to open');
      await tester.tap(find.text(en.close));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('terminal-folder-help')), findsNothing);
    });

    testWidgets('the terminal said its folder: the button names it and asks the files to open it, each time', (
      tester,
    ) async {
      final c = await pumpHeader(tester);
      c.read(terminalFolderProvider('s1').notifier).state = '/srv/app/conf';
      await tester.pump();
      expect(find.byTooltip(en.sftpTerminalFolderGoTip('/srv/app/conf')), findsOneWidget);
      await tester.tap(goButton);
      await tester.pump();
      final first = asked(c)!;
      expect(first.path, '/srv/app/conf');
      expect(first.following, isFalse);
      await tester.tap(goButton);
      await tester.pump();
      expect(asked(c), isNot(same(first)), reason: 'asked again, heard again');
      expect(find.byKey(const ValueKey('terminal-folder-help')), findsNothing);
    });

    testWidgets('Follow: kept on this computer, opens where the terminal is now and each folder it goes to, and '
        'stops when turned off', (tester) async {
      final c = await pumpHeader(tester);
      final folder = c.read(terminalFolderProvider('s1').notifier)..state = '/srv/app';
      await tester.pump();
      expect(find.text(en.sftpTerminalFolderFollow), findsOneWidget);

      await tester.tap(followButton);
      await tester.pump();
      expect(c.read(sftpDockPrefsProvider).followTerminal, isTrue);
      expect(c.read(sharedPreferencesProvider).getBool('sftp_dock_follow_terminal'), isTrue);
      expect(asked(c)!.path, '/srv/app');
      expect(asked(c)!.following, isTrue);

      folder.state = '/var/log';
      await tester.pump();
      expect(asked(c)!.path, '/var/log');
      expect(asked(c)!.following, isTrue);

      await tester.tap(followButton);
      await tester.pump();
      expect(c.read(sharedPreferencesProvider).getBool('sftp_dock_follow_terminal'), isFalse);
      final last = asked(c);
      folder.state = '/etc';
      await tester.pump();
      expect(asked(c), same(last), reason: 'not following: nothing asked');
    });

    testWidgets('Follow turned on before the terminal said anything shows how to make it say', (tester) async {
      final c = await pumpHeader(tester);
      await tester.tap(followButton);
      await tester.pumpAndSettle();
      expect(c.read(sftpDockPrefsProvider).followTerminal, isTrue);
      expect(find.byKey(const ValueKey('terminal-folder-help')), findsOneWidget);
      expect(asked(c), isNull);
      await tester.tap(find.text(en.close));
      await tester.pumpAndSettle();
      // Once the shell says one, the dock goes there.
      c.read(terminalFolderProvider('s1').notifier).state = '/home/deploy';
      await tester.pump();
      expect(asked(c)!.path, '/home/deploy');
    });

    testWidgets('on the right, Follow is its icon alone, and says what it is', (tester) async {
      await pumpHeader(tester, side: SftpDockSide.right);
      expect(find.text(en.sftpTerminalFolderFollow), findsNothing);
      expect(find.bySemanticsLabel(en.sftpTerminalFolderFollow), findsOneWidget);
      expect(tester.takeException(), isNull, reason: 'the header fits at its narrowest');
    });
  });

  group("the dock's files", () {
    Future<(ProviderContainer, PlayedSftpHost)> pumpFiles(WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      final c = ProviderContainer(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          databaseProvider.overrideWithValue(db),
          activeSessionsProvider.overrideWith(_Sessions.new),
        ],
      );
      addTearDown(c.dispose);
      final web = PlayedSftpHost()..home = '/srv/app';
      web.files['/srv/app/notes.txt'] = PlayedFile('x'.codeUnits);
      web.files['/srv/app/conf/site.conf'] = PlayedFile('x'.codeUnits);
      final line = web.connect();
      final sftp = SftpService(line.client);
      await sftp.open();
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({
        's1': SessionState(
          status: SessionStatus.connected,
          connectionId: 'c-s1',
          connectionLabel: 'web-01',
          host: 'web-01.example.com',
          port: 22,
          username: 'deploy',
          session: TerminalSession(
            id: 's1',
            connectionId: 'c-s1',
            terminal: Terminal(),
            shell: _Ssh(line.client),
            startedAt: DateTime(2026, 11, 15),
          ),
        ),
      });
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: c,
          child: MaterialApp(
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: const Locale('en'),
            home: Scaffold(
              body: SftpDualPaneScreen(
                sftp: sftp,
                connectionLabel: 'web-01',
                initialSessionId: 's1',
                embedded: true,
                docked: true,
              ),
            ),
          ),
        ),
      );
      await settle(tester);
      expect(find.text('notes.txt'), findsOneWidget);
      return (c, web);
    }

    SftpPaneState pane(WidgetTester tester) => tester.state<SftpPaneState>(find.byType(SftpPane).last);
    List<String> notices(ProviderContainer c) => [for (final n in c.read(notificationCenterProvider).history) n.title];
    void ask(ProviderContainer c, String path, {bool following = false}) =>
        c.read(terminalFolderRequestProvider('s1').notifier).state = TerminalFolderRequest(path, following: following);

    testWidgets("open the terminal's folder where the host has it", (tester) async {
      final (c, _) = await pumpFiles(tester);
      ask(c, '/srv/app/conf');
      await settle(tester);
      expect(pane(tester).currentPath, '/srv/app/conf');
      expect(find.text('site.conf'), findsOneWidget);
      expect(notices(c), isEmpty);
      await finish(tester);
    });

    testWidgets('a folder the host has not: said, with the host, and the pane stays where it was; while following, '
        'said once until a folder is found again', (tester) async {
      final (c, _) = await pumpFiles(tester);
      final missing = en.sftpTerminalFolderMissing('/home/me/elsewhere', 'web-01');
      ask(c, '/home/me/elsewhere');
      await settle(tester);
      expect(pane(tester).currentPath, '/srv/app');
      expect(find.text('notes.txt'), findsOneWidget);
      expect(notices(c), [missing]);

      // Following a terminal that is on another computer now: said once, not at every cd.
      ask(c, '/home/me/a', following: true);
      await settle(tester);
      ask(c, '/home/me/b', following: true);
      await settle(tester);
      expect(notices(c).length, 2);
      expect(notices(c).first, en.sftpTerminalFolderMissing('/home/me/a', 'web-01'));

      // Back on this host, it follows again; a later miss is said again.
      ask(c, '/srv/app/conf', following: true);
      await settle(tester);
      expect(pane(tester).currentPath, '/srv/app/conf');
      ask(c, '/home/me/c', following: true);
      await settle(tester);
      expect(notices(c).length, 3);
      expect(pane(tester).currentPath, '/srv/app/conf');
      await finish(tester);
    });

    testWidgets('a file, not a folder, is not opened', (tester) async {
      final (c, _) = await pumpFiles(tester);
      ask(c, '/srv/app/notes.txt');
      await settle(tester);
      expect(pane(tester).currentPath, '/srv/app');
      expect(notices(c), [en.sftpTerminalFolderMissing('/srv/app/notes.txt', 'web-01')]);
      await finish(tester);
    });
  });
}

/// Lets the played host answer and the screen draw what it said.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// Takes the screen down inside the test, its notices' timers run out.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(minutes: 1));
}
