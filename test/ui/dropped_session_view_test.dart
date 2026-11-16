import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart' show TerminalThemes;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zest_ssh_core/dartssh2.dart' show SSHDisconnectError;
import 'package:zestssh/services/ssh_service.dart'
    show
        endReasonOf,
        endedAtJumpHost,
        hostClosedConnection,
        hostDataDamaged,
        hostKeyFailedAtNewKeys,
        hostStoppedAnswering,
        sessionEndedCause;
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart' show closesByItself, staysToBeRead;
import 'package:zestssh/ui/screens/terminal/widgets/dropped_session_view.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';

/// A session whose connection dropped, on a phone (3.0): what the
/// last try of connecting again said, its report, and "Closing..." only while
/// the screen is closing.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final stopped = <String>[];

  @override
  void stopAutoReconnect(String sessionId) => stopped.add(sessionId);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const refused = 'SocketException: Connection refused (10.50.0.5)';

  SessionState dropped(
          {bool reconnecting = false, int attempt = 0, String? error, String? connectionId = 'h-web1', String? cause}) =>
      SessionState.disconnected(
        connectionId: connectionId,
        connectionLabel: 'web-01',
        host: '10.50.0.5',
        port: 22,
        errorMessage: error,
        connectionLog: error == null ? const [] : ['error: $error'],
        dropped: true,
        dropCause: cause,
      ).copyWith(isReconnecting: reconnecting, reconnectAttempt: attempt, maxRetries: 10);

  Future<_Sessions> open(WidgetTester tester, SessionState state,
      {bool closing = false, VoidCallback? onReconnect, bool recording = false}) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    Redactor.instance.enabled = recording;
    addTearDown(() => Redactor.instance.enabled = false);
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => recording),
      activeSessionsProvider.overrideWith(_Sessions.new),
    ]);
    addTearDown(container.dispose);
    // A tree of its own: nothing of the one before (an open details panel) stays.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: DroppedSessionView(
            sessionId: 's1',
            sessionState: state,
            theme: TerminalThemes.defaultTheme,
            closing: closing,
            onReconnect: onReconnect,
          ),
        ),
      ),
    ));
    // Not pumpAndSettle: while it connects again a spinner turns for good.
    await tester.pump(const Duration(milliseconds: 100));
    return container.read(activeSessionsProvider.notifier) as _Sessions;
  }

  testWidgets('connecting again: which try, what the last one said, and Cancel', (tester) async {
    final sessions = await open(tester, dropped(reconnecting: true, attempt: 4, error: refused));
    final why = ConnectionError.translate(refused, host: '10.50.0.5', port: 22);
    expect(find.text(en.terminalReconnectAttempt(4, 10)), findsOneWidget);
    expect(find.text(why.description), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-reconnect-cancel')));
    expect(sessions.stopped, ['s1']);
  });

  testWidgets('given up: why, how many tries, Reconnect, and the report with the address out', (tester) async {
    var reconnects = 0;
    await open(tester, dropped(attempt: 10, error: refused), onReconnect: () => reconnects++);
    final why = ConnectionError.translate(refused, host: '10.50.0.5', port: 22);
    expect(find.text(en.terminalDisconnected), findsOneWidget);
    expect(find.text(why.description), findsOneWidget);
    expect(find.text(en.terminalAutoReconnectFailed(10)), findsOneWidget);
    expect(find.text(en.terminalClosing), findsNothing);
    await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
    expect(reconnects, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Connection refused'));
    expect(report, contains('A connection that dropped'));
    expect(report, isNot(contains('10.50.0.5')));
  });

  testWidgets('"Closing..." only while the screen is closing; nothing to reconnect to, no Reconnect', (tester) async {
    await open(tester, dropped(), closing: true, onReconnect: () {});
    expect(find.text(en.terminalClosing), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-last-try')), findsNothing, reason: 'nothing was tried');
    expect(find.byKey(const ValueKey('error-details-toggle')), findsNothing);

    // After Cancel it stays, and does not say it is closing.
    await open(tester, dropped(attempt: 2), onReconnect: () {});
    expect(find.text(en.terminalClosing), findsNothing);
    expect(find.text(en.terminalAutoReconnectFailed(2)), findsNothing, reason: 'stopped, not given up');

    await open(tester, dropped(connectionId: null));
    expect(find.byKey(const ValueKey('terminal-reconnect')), findsNothing);
  });

  testWidgets('a session its host ended: that it did, how, the last the host printed, and it does not say that it '
      'is closing', (tester) async {
    const notice = 'Hi deploy! You have no shell here.';
    var reconnects = 0;
    await open(tester, dropped(cause: sessionEndedCause(exitCode: 1, said: notice)), onReconnect: () => reconnects++);
    expect(find.text(en.sessionEndedTitle), findsOneWidget);
    expect(find.text(en.terminalDisconnected), findsNothing, reason: 'no connection was lost');
    expect(find.text('web-01 ended the session (exit status 1).'), findsOneWidget);
    expect(find.text(en.sessionEndedLastWords), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('session-ended-last-words'))).data, notice);
    expect(find.text(en.terminalClosing), findsNothing);
    expect(find.byIcon(LucideIcons.terminal), findsOneWidget);
    expect(find.byIcon(LucideIcons.unlink), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('terminal-reconnect')));
    await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
    expect(reconnects, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: sessionEndedByHost'));
    expect(report, contains('A session its host ended'));
    expect(report, contains(en.sessionEndedTitle));

    // By a signal, with nothing printed: no words of the host's to set apart.
    await open(tester, dropped(cause: sessionEndedCause(signal: 'KILL')), onReconnect: () {});
    expect(find.text('web-01 ended the session (signal KILL).'), findsOneWidget);
    expect(find.text(en.sessionEndedLastWords), findsNothing);
    expect(find.byKey(const ValueKey('session-ended-last-words')), findsNothing);

    // While recording: the name, and the address in what the host printed.
    await open(tester, dropped(cause: sessionEndedCause(exitCode: 1, said: 'Last login from 10.50.0.5')),
        recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    final masked = tester.widget<SelectableText>(find.byKey(const ValueKey('session-ended-last-words'))).data!;
    expect(masked, startsWith('Last login from '));
    expect(masked, isNot(contains('10.50.0.5')));

    // Once a try of connecting again has said something, that is what is said.
    await open(tester, dropped(attempt: 10, error: refused, cause: sessionEndedCause(exitCode: 1, said: notice)),
        onReconnect: () {});
    expect(find.text(en.sessionEndedTitle), findsNothing);
    expect(find.text(en.terminalDisconnected), findsOneWidget);
    expect(find.byKey(const ValueKey('session-ended-last-words')), findsNothing);
  });

  test('a phone\'s screen closes by itself once its session is disconnected: not while it is connected again, and '
      'not where its host ended the session', () {
    final running = SessionState.connecting('h-web1', connectionLabel: 'web-01');
    // Disconnected, with nothing more to come: it closes.
    expect(closesByItself(running, dropped()), isTrue);
    expect(closesByItself(null, dropped()), isTrue);
    expect(closesByItself(running, dropped(cause: hostStoppedAnswering)), isTrue);
    // Being connected again: it stays for that.
    expect(closesByItself(running, dropped(reconnecting: true, attempt: 1)), isFalse);
    // Its host ended it: it stays, for what the host said to be read.
    expect(closesByItself(running, dropped(cause: sessionEndedCause(exitCode: 1, said: 'bye'))), isFalse);
    expect(closesByItself(running, dropped(cause: sessionEndedCause())), isFalse);
    // Ended over its host's key when new keys were taken: it stays, for that to be read.
    expect(closesByItself(running, dropped(cause: hostKeyFailedAtNewKeys)), isFalse);
    expect(closesByItself(null, dropped(cause: hostKeyFailedAtNewKeys)), isFalse);
    expect(staysToBeRead(dropped(cause: hostKeyFailedAtNewKeys)), isTrue);
    expect(staysToBeRead(dropped(cause: sessionEndedCause(exitCode: 1, said: 'bye'))), isTrue);
    expect(staysToBeRead(dropped(cause: sessionEndedCause())), isTrue);
    expect(staysToBeRead(dropped(cause: hostStoppedAnswering)), isFalse);
    // A packet that did not pass its check: a line that failed, as any other drop of a network.
    expect(staysToBeRead(dropped(cause: hostDataDamaged)), isFalse);
    expect(closesByItself(running, dropped(cause: hostDataDamaged)), isTrue);
    expect(staysToBeRead(dropped(cause: 'SSHSocketError(SocketException: Broken pipe)')), isFalse);
    expect(staysToBeRead(dropped()), isFalse);
    expect(staysToBeRead(null), isFalse);
    // Nothing new: it was disconnected before, or is not disconnected.
    expect(closesByItself(dropped(reconnecting: true, attempt: 1), dropped(attempt: 10)), isFalse);
    expect(closesByItself(dropped(), running), isFalse);
    expect(closesByItself(running, null), isFalse);
  });

  testWidgets('why it dropped is said before a try said anything, with its report', (tester) async {
    await open(tester, dropped(cause: 'SSHSocketError(SocketException: Broken pipe)'), onReconnect: () {});
    expect(find.text(en.connectionLostNetwork('web-01')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Broken pipe'));

    // The name masked while recording.
    await open(tester, dropped(cause: 'SSHSocketError(SocketException: Broken pipe)'), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.text(en.connectionLostNetwork(Redactable.host('web-01').display)), findsOneWidget);

    // Ended by the host itself, with a reason of its own.
    final idle = endReasonOf(SSHDisconnectError(11, 'Idle timeout', authentic: true));
    await open(tester, dropped(cause: idle), onReconnect: () {});
    expect(find.text('web-01 ended the connection. Its reason: Idle timeout'), findsOneWidget);

    // Given up because the host stopped answering.
    await open(tester, dropped(cause: hostStoppedAnswering), onReconnect: () {});
    expect(find.text('web-01 stopped answering, and the connection was given up.'), findsOneWidget);

    // Ended over a packet that did not pass its check.
    await open(tester, dropped(cause: hostDataDamaged), onReconnect: () {});
    expect(find.text('What came from web-01 did not pass its check, so nothing of it was used and the connection was '
        'ended.'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!,
        contains('Kind: packetCheckFailed'));

    // Ended over its host's key when new keys were taken: said as that, with Reconnect and its report.
    var reconnects = 0;
    await open(tester, dropped(cause: hostKeyFailedAtNewKeys), onReconnect: () => reconnects++);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsOneWidget);
    expect(find.text(en.terminalDisconnected), findsOneWidget);
    expect(find.text(en.terminalClosing), findsNothing);
    await tester.ensureVisible(find.byKey(const ValueKey('terminal-reconnect')));
    await tester.tap(find.byKey(const ValueKey('terminal-reconnect')));
    expect(reconnects, 1);
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final ofTheKey = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(ofTheKey, contains('Kind: hostKeyAtNewKeys'));
    expect(ofTheKey, contains(hostKeyFailedAtNewKeys));
  });

  testWidgets('it was the connection to a jump host that ended: said as that, with its report, and both names '
      'masked while recording', (tester) async {
    final closed = endedAtJumpHost('vpn-gateway', hostClosedConnection);
    await open(tester, dropped(cause: closed), onReconnect: () {});
    expect(
        find.text('The connection to web-01 goes through the jump host vpn-gateway, and it was the connection to '
            'that jump host that ended. vpn-gateway closed the connection.'),
        findsOneWidget);
    expect(find.text(en.connectionLostByHost('web-01')), findsNothing, reason: 'the host closed nothing');
    await tester.ensureVisible(find.byKey(const ValueKey('error-details-toggle')));
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: jumpHost.closedByHost'));

    // While recording: the name of the host, and the jump host's.
    await open(tester, dropped(cause: closed), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.textContaining('vpn-gateway'), findsNothing);
    final host = Redactable.host('web-01').display;
    final jump = Redactable.host('vpn-gateway').display;
    expect(find.text('${en.connectionLostAtJumpHost(host, jump)} ${en.connectionLostByHost(jump)}'), findsOneWidget);

    // Ended over the jump host's key: the session stays on a phone's screen for that to be read.
    final keyFailed = endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys);
    await open(tester, dropped(cause: keyFailed), onReconnect: () {});
    expect(find.textContaining(en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')), findsOneWidget);
    expect(staysToBeRead(dropped(cause: keyFailed)), isTrue);
    expect(staysToBeRead(dropped(cause: closed)), isFalse);
  });

  testWidgets('in every language, on a small phone: connecting again, given up and closing, nothing clipped',
      (tester) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final states = [
      (dropped(reconnecting: true, attempt: 3, error: refused), false),
      (dropped(attempt: 10, error: refused), false),
      (dropped(), true),
      // Ended over its host's key when new keys were taken: three sentences, and it stays.
      (dropped(cause: hostKeyFailedAtNewKeys), false),
      // Ended over a packet that did not pass its check.
      (dropped(cause: hostDataDamaged), true),
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      for (final (state, closing) in states) {
        final container = ProviderContainer(overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          activeSessionsProvider.overrideWith(_Sessions.new),
        ]);
        await tester.pumpWidget(UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            locale: locale,
            theme: ThemeData(fontFamily: 'GeistSans'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: DroppedSessionView(
                sessionId: 's1',
                sessionState: state,
                theme: TerminalThemes.defaultTheme,
                closing: closing,
                onReconnect: () {},
              ),
            ),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '$locale');
        if (state.dropCause == hostKeyFailedAtNewKeys) {
          expect(find.text(lookupAppLocalizations(locale).connHostKeyFailedAtNewKeys), findsOneWidget,
              reason: '$locale');
        }
        if (state.dropCause == hostDataDamaged) {
          expect(find.text(lookupAppLocalizations(locale).connectionLostDamaged('web-01')), findsOneWidget,
              reason: '$locale');
        }
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      }
    }
  });
}
