import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalThemes;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/terminal/widgets/dropped_session_view.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart';

/// A normal SSH host whose server gives files only:
/// where its session is shown, a computer's and a phone's say so
/// plainly, show what the server said, and offer its files ("Open its
/// files") and to keep it so ("Make this host SFTP only"), with asking for a
/// terminal again under them. Where the host could not be changed, that is
/// said. A session its host ended for another reason is shown as before.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  TerminalRefusal? refusal;
  bool mayChange = true;
  final calls = <String>[];

  void seed(String id, SessionState s) => state = {...state, id: s};

  @override
  TerminalRefusal? terminalRefusalOf(String sessionId) => refusal;

  @override
  void openFilesInstead(String sessionId) => calls.add('files $sessionId');

  @override
  Future<bool> makeHostSftpOnly(String sessionId) async {
    calls.add('sftp-only $sessionId');
    return mayChange;
  }

  @override
  void reconnectNow(String sessionId) => calls.add('reconnect $sessionId');
}

SessionState _ended({String connectionId = 'h-files', String said = sftpOnlyServerWords, int exitCode = 1}) =>
    SessionState.disconnected(
      connectionId: connectionId,
      connectionLabel: 'files-01',
      host: '192.0.2.20',
      port: 22,
      dropped: true,
      dropCause: sessionEndedCause(exitCode: exitCode, said: said),
      connectionLog: const ['ready: Session established', 'ended: The host ended the session (exit status 1)'],
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late _Sessions sessions;
  late SharedPreferences prefs;

  Future<void> pump(WidgetTester tester, Widget Function(SessionState s) view, SessionState s,
      {TerminalRefusal? refusal, bool mayChange = true, List<String> turnedBack = const []}) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'sftp_only_turned_back': turnedBack});
    prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);
    sessions = container.read(activeSessionsProvider.notifier) as _Sessions
      ..refusal = refusal
      ..mayChange = mayChange
      ..seed('s1', s);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: view(s)),
      ),
    ));
    await tester.pump();
  }

  Widget computer(SessionState s) => ConnectionLostView(sessionId: 's1', sessionState: s);

  Widget phone(SessionState s) => DroppedSessionView(
        sessionId: 's1',
        sessionState: s,
        theme: TerminalThemes.defaultTheme,
        closing: false,
        onReconnect: () => sessions.calls.add('phone reconnect'),
      );

  for (final (where, view) in [('a computer', computer), ('a phone', phone)]) {
    testWidgets('$where: a server that allows SFTP only is said plainly, with its words and both offers', (tester) async {
      await pump(tester, view, _ended(), refusal: TerminalRefusal.sftpOnly);
      expect(find.text(en.sftpOnlyRefusalTitle), findsOneWidget);
      expect(find.text(en.sftpOnlyRefusalSaid('files-01')), findsOneWidget);
      expect(find.text(sftpOnlyServerWords), findsOneWidget, reason: 'what the server said, to read and copy');
      expect(find.text(en.sessionEndedTitle), findsNothing);

      await tester.tap(find.byKey(const ValueKey('terminal-refused-open-files')));
      await tester.pump();
      expect(sessions.calls, ['files s1']);

      await tester.tap(find.byKey(const ValueKey('terminal-refused-make-sftp')));
      await tester.pumpAndSettle();
      expect(sessions.calls, ['files s1', 'sftp-only s1']);
      expect(find.byKey(const ValueKey('terminal-refused-not-changed')), findsNothing);

      // Asking for a terminal again is there, under them.
      final reconnect = find.text(en.terminalReconnect);
      expect(reconnect, findsOneWidget);
      expect(tester.getTopLeft(reconnect).dy,
          greaterThan(tester.getTopLeft(find.byKey(const ValueKey('terminal-refused-open-files'))).dy));
    });

    testWidgets('$where: a host a device on an older version turned back says so, until it is SFTP only again',
        (tester) async {
      await pump(tester, view, _ended(), refusal: TerminalRefusal.sftpOnly, turnedBack: const ['h-files']);
      expect(find.text(en.sftpOnlyTurnedBack), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('terminal-refused-make-sftp')));
      await tester.pumpAndSettle();
      expect(sessions.calls, ['sftp-only s1']);
      expect(prefs.getStringList('sftp_only_turned_back'), isEmpty, reason: 'old news once it is SFTP only again');
    });

    testWidgets('$where: where the host could not be changed, the note stays; another host says nothing of it',
        (tester) async {
      await pump(tester, view, _ended(), refusal: TerminalRefusal.sftpOnly, mayChange: false, turnedBack: const ['h-files']);
      await tester.tap(find.byKey(const ValueKey('terminal-refused-make-sftp')));
      await tester.pumpAndSettle();
      expect(prefs.getStringList('sftp_only_turned_back'), ['h-files']);

      await pump(tester, view, _ended(), refusal: TerminalRefusal.sftpOnly, turnedBack: const ['another-host']);
      expect(find.text(en.sftpOnlyTurnedBack), findsNothing);
    });

    testWidgets('$where: a shell that closed as it opened is said with an if, and offers the same', (tester) async {
      await pump(tester, view, _ended(said: '', exitCode: 0), refusal: TerminalRefusal.closedAtOnce);
      expect(find.text(en.sftpOnlyRefusalAtOnce('files-01')), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-refused-open-files')), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-refused-make-sftp')), findsOneWidget);
    });

    testWidgets('$where: where the host could not be changed, that is said, and its files are still offered',
        (tester) async {
      await pump(tester, view, _ended(), refusal: TerminalRefusal.sftpOnly, mayChange: false);
      await tester.tap(find.byKey(const ValueKey('terminal-refused-make-sftp')));
      await tester.pumpAndSettle();
      expect(find.text(en.sftpOnlyMakeNotAllowed), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-refused-open-files')), findsOneWidget);
    });

    testWidgets("$where: a Quick connect's host is not saved, so only its files are offered", (tester) async {
      await pump(tester, view, _ended(connectionId: 'quick_192.0.2.20'), refusal: TerminalRefusal.sftpOnly);
      expect(find.byKey(const ValueKey('terminal-refused-open-files')), findsOneWidget);
      expect(find.byKey(const ValueKey('terminal-refused-make-sftp')), findsNothing);
    });

    testWidgets('$where: a session its host ended for another reason is shown as before', (tester) async {
      await pump(tester, view, _ended(said: 'logout', exitCode: 0));
      expect(find.text(en.sessionEndedTitle), findsOneWidget);
      expect(find.text(en.sftpOnlyRefusalTitle), findsNothing);
      expect(find.byKey(const ValueKey('terminal-refused-open-files')), findsNothing);
    });
  }
}
