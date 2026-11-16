import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
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
import 'package:zestssh/ui/widgets/connection_lost_view.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/redactor.dart';

import '../visual/shots_util.dart';

/// A session whose connection dropped, in its own place (3.0):
/// connecting again by itself, given up, or ended with nothing known.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final stopped = <String>[];
  final reconnected = <String>[];

  @override
  void stopAutoReconnect(String sessionId) => stopped.add(sessionId);

  @override
  void reconnectNow(String sessionId) => reconnected.add(sessionId);
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  SessionState dropped({
    bool reconnecting = false,
    int attempt = 0,
    String? error,
    List<String> log = const [],
    String? username,
    String? cause,
  }) =>
      SessionState.disconnected(
        connectionId: 'h-web1',
        connectionLabel: 'web-01',
        host: '10.50.0.5',
        port: 22,
        errorMessage: error,
        connectionLog: log,
        username: username,
        dropped: true,
        dropCause: cause,
      ).copyWith(isReconnecting: reconnecting, reconnectAttempt: attempt, maxRetries: 10);

  Future<(_Sessions, String?)> open(WidgetTester tester, SessionState state, {bool recording = false}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    Redactor.instance.enabled = recording;
    addTearDown(() => Redactor.instance.enabled = false);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
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
        home: Scaffold(body: ConnectionLostView(sessionId: 's1', sessionState: state)),
      ),
    ));
    // Not pumpAndSettle: while it connects again a spinner turns for good.
    await tester.pump(const Duration(milliseconds: 100));
    return (container.read(activeSessionsProvider.notifier) as _Sessions, copied);
  }

  testWidgets('connecting again by itself: which try, what the last one said, and Cancel stops it', (tester) async {
    final (sessions, _) =
        await open(tester, dropped(reconnecting: true, attempt: 3, error: 'SocketException: Connection refused'));
    final why = ConnectionError.translate('SocketException: Connection refused', host: '10.50.0.5', port: 22);
    expect(find.text(en.terminalReconnecting), findsOneWidget);
    expect(find.text(en.terminalReconnectAttempt(3, 10)), findsOneWidget);
    expect(find.text(why.description), findsOneWidget);
    expect(find.text(en.terminalReconnect), findsNothing, reason: 'it is connecting already');
    await tester.tap(find.byKey(const ValueKey('connection-lost-cancel')));
    expect(sessions.stopped, ['s1']);
    expect(sessions.reconnected, isEmpty);
  });

  testWidgets('given up: lost, why, how many tries, Reconnect, and the details to copy with every address out',
      (tester) async {
    final (sessions, _) = await open(
      tester,
      dropped(attempt: 10, error: 'SocketException: No route to host (10.50.0.5)', log: [
        'Preparing connection to 10.50.0.5:22',
        'error: SocketException: No route to host (10.50.0.5)',
      ]),
    );
    final why = ConnectionError.translate('SocketException: No route to host (10.50.0.5)', host: '10.50.0.5', port: 22);
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    expect(find.text(why.description), findsOneWidget);
    expect(find.text(en.terminalAutoReconnectFailed(10)), findsOneWidget);
    expect(find.text(why.tip!), findsOneWidget);
    expect(find.byKey(const ValueKey('connection-lost-cancel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    expect(sessions.reconnected, ['s1']);

    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('No route to host'));
    expect(report, contains('Kind: ${why.type.name}'));
    expect(report, contains('A connection that dropped'));
    expect(report, contains('Preparing connection to'));
    expect(report, isNot(contains('10.50.0.5')), reason: 'every address taken out');
  });

  testWidgets('a drop with nothing known says the connection ended; no details, the name masked while recording',
      (tester) async {
    await open(tester, dropped());
    expect(find.text(en.connectionLostEnded('web-01')), findsOneWidget);
    expect(find.text(en.terminalAutoReconnectFailed(0)), findsNothing);
    expect(find.byKey(const ValueKey('error-details-toggle')), findsNothing);

    await open(tester, dropped(), recording: true);
    final masked = Redactable.host('web-01').display;
    expect(masked, isNot('web-01'));
    expect(find.text(en.connectionLostEnded(masked)), findsOneWidget);
    expect(find.textContaining('web-01'), findsNothing);

    // What the last try said names neither the address nor the user.
    await open(tester, dropped(attempt: 10, error: 'SocketException: Connection refused'), recording: true);
    expect(find.textContaining('10.50.0.5'), findsNothing);
    final refused = ConnectionError.translate('SocketException: Connection refused',
        host: Redactable.address('10.50.0.5').display, port: 22);
    expect(find.text(refused.description), findsOneWidget);
    await open(tester, dropped(attempt: 10, error: 'SSHAuthFailError: publickey authentication failed', username: 'demo-admin'),
        recording: true);
    expect(find.textContaining('demo-admin'), findsNothing);
  });

  testWidgets('why it dropped, before a try said anything: the host closed it, the network broke, or it ended; '
      'its report says it', (tester) async {
    await open(tester, dropped(cause: hostClosedConnection));
    expect(find.text(en.connectionLostByHost('web-01')), findsOneWidget);
    expect(find.text(en.errNetworkErrorTip), findsNothing, reason: 'nothing to try about a network');
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    var report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains(hostClosedConnection));
    expect(report, contains('Kind: closedByHost'));

    await open(tester, dropped(cause: 'SSHSocketError(SocketException: Connection reset by peer)'));
    expect(find.text(en.connectionLostNetwork('web-01')), findsOneWidget);
    expect(find.text(en.errNetworkErrorTip), findsOneWidget);

    // The host ended the connection itself and said why: its words, as its own.
    final idle = endReasonOf(SSHDisconnectError(11, 'Idle timeout:\r\nclosing the session', authentic: true));
    await open(tester, dropped(cause: idle));
    expect(find.text('web-01 ended the connection. Its reason: Idle timeout: closing the session'), findsOneWidget);
    expect(find.text(en.connectionLostEnded('web-01')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Idle timeout: closing the session'));
    expect(report, contains('Kind: endedByHost'));
    await open(tester, dropped(cause: idle), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.text(en.connectionLostHostSaid(Redactable.host('web-01').display, 'Idle timeout: closing the session')),
        findsOneWidget);
    // A host that ended it with no words is one that closed the connection.
    await open(tester, dropped(cause: endReasonOf(SSHDisconnectError(11, '', authentic: true))));
    expect(find.text(en.connectionLostByHost('web-01')), findsOneWidget);

    // Given up because the host stopped answering: said as that, with what it can mean.
    await open(tester, dropped(cause: hostStoppedAnswering));
    expect(find.text('web-01 stopped answering, and the connection was given up.'), findsOneWidget);
    expect(find.text(en.connectionLostNoAnswerTip), findsOneWidget);
    expect(find.text(en.connectionLostEnded('web-01')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains(hostStoppedAnswering));
    expect(report, contains('Kind: stoppedAnswering'));
    // The name masked while recording.
    await open(tester, dropped(cause: hostStoppedAnswering), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.text(en.connectionLostNoAnswer(Redactable.host('web-01').display)), findsOneWidget);

    await open(tester, dropped(cause: 'SSHPacketError: bad mac'));
    expect(find.text(en.connectionLostEnded('web-01')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('bad mac'));
    expect(report, contains('Kind: lost'));

    // While it connects again, before a try failed: why it dropped.
    await open(tester, dropped(reconnecting: true, attempt: 1, cause: hostClosedConnection));
    expect(find.text(en.connectionLostByHost('web-01')), findsOneWidget);
    // Once a try said something, that is what is said.
    await open(tester, dropped(attempt: 10, error: 'SocketException: Connection refused', cause: hostClosedConnection));
    expect(find.text(en.connectionLostByHost('web-01')), findsNothing);
    expect(find.text(ConnectionError.translate('SocketException: Connection refused', host: '10.50.0.5', port: 22).description),
        findsOneWidget);
  });

  testWidgets('a session its host ended: that it did, how, and the last the host printed, set apart from the '
      'app\'s words; its report says it', (tester) async {
    const notice = 'Hi deploy! You have successfully authenticated,\nbut this host gives no shell access.';
    final cause = sessionEndedCause(exitCode: 1, said: notice);
    final (sessions, _) = await open(tester, dropped(cause: cause, username: 'deploy'));
    expect(find.text(en.sessionEndedTitle), findsOneWidget);
    expect(find.text(en.connectionLostTitle), findsNothing, reason: 'no connection was lost');
    expect(find.text('web-01 ended the session (exit status 1).'), findsOneWidget);
    expect(find.text(en.sessionEndedLastWords), findsOneWidget);
    final printed = tester.widget<SelectableText>(find.byKey(const ValueKey('session-ended-last-words')));
    expect(printed.data, notice);
    expect(printed.style?.fontFamily, 'JetBrainsMono');
    expect(find.byIcon(LucideIcons.terminal), findsOneWidget);
    expect(find.byIcon(LucideIcons.unplug), findsNothing);
    // Its person may connect again; nothing does by itself.
    expect(find.text(en.terminalReconnecting), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    expect(sessions.reconnected, ['s1']);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: sessionEndedByHost'));
    expect(report, contains('A session its host ended'));
    expect(report, contains('exit status 1'));
    expect(report, contains(en.sessionEndedTitle));

    // Ended by a signal; with nothing said of how it ended; with nothing printed.
    await open(tester, dropped(cause: sessionEndedCause(signal: 'HUP', said: 'The system will reboot now!')));
    expect(find.text('web-01 ended the session (signal HUP).'), findsOneWidget);
    expect(tester.widget<SelectableText>(find.byKey(const ValueKey('session-ended-last-words'))).data,
        'The system will reboot now!');
    await open(tester, dropped(cause: sessionEndedCause(said: 'Connection closed.')));
    expect(find.text('web-01 ended the session.'), findsOneWidget);
    await open(tester, dropped(cause: sessionEndedCause(exitCode: 0)));
    expect(find.text('web-01 ended the session (exit status 0).'), findsOneWidget);
    expect(find.text(en.sessionEndedLastWords), findsNothing);
    expect(find.byKey(const ValueKey('session-ended-last-words')), findsNothing);

    // While recording, the host and the user are masked, in what the host printed too.
    await open(tester, dropped(cause: cause, username: 'deploy'), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    final masked = tester.widget<SelectableText>(find.byKey(const ValueKey('session-ended-last-words'))).data!;
    expect(masked, isNot(contains('deploy')));
    expect(masked, contains('You have successfully authenticated'));

    // While it is connected again (its person asked): that, and not the host's words under it.
    await open(tester, dropped(reconnecting: true, attempt: 1, cause: cause));
    expect(find.text(en.terminalReconnecting), findsOneWidget);
    expect(find.text(en.sessionEndedTitle), findsNothing);
    expect(find.byKey(const ValueKey('session-ended-last-words')), findsNothing);

    // Once a try of connecting again has said something, that is what is said, as of a connection lost.
    await open(tester, dropped(attempt: 10, error: 'SocketException: Connection refused', cause: cause));
    expect(find.text(en.sessionEndedTitle), findsNothing);
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('session-ended-last-words')), findsNothing);
  });

  testWidgets('ended over its host\'s key when new keys were taken: said as that, with Reconnect for its person '
      'and a report that has what the SSH core found', (tester) async {
    final (sessions, _) = await open(
      tester,
      dropped(cause: hostKeyFailedAtNewKeys, log: const [
        'ssh_hostkey: Host key REJECTED when new keys were taken - Host key changed during re-key',
        'dropped: $hostKeyFailedAtNewKeys',
      ]),
    );
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(find.text('web-01'), findsOneWidget);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsOneWidget);
    expect(find.text(en.connectionLostEnded('web-01')), findsNothing);
    expect(find.byIcon(LucideIcons.unplug), findsOneWidget);
    // Nothing connects again by itself; its person may.
    expect(find.text(en.terminalReconnecting), findsNothing);
    expect(find.byKey(const ValueKey('connection-lost-cancel')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    expect(sessions.reconnected, ['s1']);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: hostKeyAtNewKeys'));
    expect(report, contains(hostKeyFailedAtNewKeys));
    expect(report, contains('Host key changed during re-key'));
    expect(report, contains('A connection that dropped'));

    // The sentence names no host: while recording, its name is masked where it stands.
    await open(tester, dropped(cause: hostKeyFailedAtNewKeys), recording: true);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsOneWidget);
    expect(find.textContaining('web-01'), findsNothing);

    // Its person connected again and that try failed: what the try said.
    await open(tester, dropped(attempt: 1, error: 'SocketException: Connection refused', cause: hostKeyFailedAtNewKeys));
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsNothing);
    expect(find.text(ConnectionError.translate('SocketException: Connection refused', host: '10.50.0.5', port: 22).description),
        findsOneWidget);
  });

  testWidgets('it was the connection to a jump host that ended: said as that, with why, a report that names '
      'its kind, and both names masked while recording', (tester) async {
    final keyFailed = endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys);
    final (sessions, _) = await open(
      tester,
      dropped(cause: keyFailed, log: [
        'jump: The connection to the jump host vpn-gateway ended - '
            'ssh_hostkey: Host key REJECTED when new keys were taken - Host key changed during re-key',
        'dropped: $keyFailed',
      ]),
    );
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(
        find.text('The connection to web-01 goes through the jump host vpn-gateway, and it was the connection to '
            'that jump host that ended. ${en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')}'),
        findsOneWidget);
    expect(find.text(en.connHostKeyFailedAtNewKeys), findsNothing, reason: 'it was not the host\'s key');
    expect(find.text(en.connectionLostByHost('web-01')), findsNothing, reason: 'nor did the host close anything');
    // Nothing connects again by itself; its person may.
    expect(find.text(en.terminalReconnecting), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    expect(sessions.reconnected, ['s1']);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: jumpHost.hostKeyAtNewKeys'));
    expect(report, contains('Host key changed during re-key'));
    expect(report, contains('A connection that dropped'));

    // While recording: the name of the host, and the jump host's.
    await open(tester, dropped(cause: endedAtJumpHost('vpn-gateway', hostClosedConnection)), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.textContaining('vpn-gateway'), findsNothing);
    final host = Redactable.host('web-01').display;
    final jump = Redactable.host('vpn-gateway').display;
    expect(find.text('${en.connectionLostAtJumpHost(host, jump)} ${en.connectionLostByHost(jump)}'), findsOneWidget);

    // Its person connected again and that try failed: what the try said.
    await open(tester, dropped(attempt: 1, error: 'SocketException: Connection refused', cause: keyFailed));
    expect(find.textContaining('vpn-gateway'), findsNothing);
    expect(find.text(ConnectionError.translate('SocketException: Connection refused', host: '10.50.0.5', port: 22).description),
        findsOneWidget);
  });

  testWidgets('ended over a packet that did not pass its check: said as that, with what it can mean, and a report '
      'that has what the SSH core found', (tester) async {
    final (sessions, _) = await open(
      tester,
      dropped(cause: hostDataDamaged, log: const [
        'ssh_session: A packet from the other side did not pass its check: it was changed or damaged on the way, or the '
            'two sides do not protect their packets the same way',
        'dropped: $hostDataDamaged',
      ]),
    );
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(find.text(en.connectionLostDamaged('web-01')), findsOneWidget);
    expect(find.text(en.connectionLostDamagedTip), findsOneWidget);
    expect(find.text(en.connectionLostEnded('web-01')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    expect(sessions.reconnected, ['s1']);
    await tester.tap(find.byKey(const ValueKey('error-details-toggle')));
    await tester.pumpAndSettle();
    final report = tester.widget<SelectableText>(find.byKey(const ValueKey('error-details-text'))).data!;
    expect(report, contains('Kind: packetCheckFailed'));
    expect(report, contains(hostDataDamaged));
    expect(report, contains('did not pass its check: it was changed or damaged on the way, or the two sides do '
        'not protect their packets the same way'));

    // While it is connected to again by itself, before a try has said anything: why it dropped, and no tip yet.
    await open(tester, dropped(reconnecting: true, attempt: 1, cause: hostDataDamaged));
    expect(find.text(en.terminalReconnecting), findsOneWidget);
    expect(find.text(en.connectionLostDamaged('web-01')), findsOneWidget);
    expect(find.text(en.connectionLostDamagedTip), findsNothing);

    // The name masked while recording.
    await open(tester, dropped(cause: hostDataDamaged), recording: true);
    expect(find.textContaining('web-01'), findsNothing);
    expect(find.text(en.connectionLostDamaged(Redactable.host('web-01').display)), findsOneWidget);
  });

  test('the kind of end a report names, by why the session dropped', () {
    expect(dropKind(hostKeyFailedAtNewKeys), 'hostKeyAtNewKeys');
    expect(dropKind(hostDataDamaged), 'packetCheckFailed');
    expect(dropKind(sessionEndedCause(exitCode: 1, said: 'bye')), 'sessionEndedByHost');
    expect(dropKind(sessionEndedCause()), 'sessionEndedByHost');
    expect(dropKind(hostClosedConnection), 'closedByHost');
    expect(dropKind(hostStoppedAnswering), 'stoppedAnswering');
    expect(dropKind(endReasonOf(SSHDisconnectError(11, 'Idle timeout', authentic: true))), 'endedByHost');
    expect(dropKind('SSHPacketError: bad mac'), 'lost');
    expect(dropKind(null), 'lost');
  });

  testWidgets('in every language, in a small pane: connecting again, given up and ended, nothing clipped',
      (tester) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    // A pane a quarter of a small window.
    tester.view.physicalSize = const Size(420, 330);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    const error = 'SocketException: No route to host';
    final states = [
      dropped(reconnecting: true, attempt: 3, error: error),
      dropped(attempt: 10, error: error, log: const ['error: SocketException: No route to host']),
      dropped(),
      // Ended by the host with a reason of its own, as long as a reason is shown at the most.
      dropped(cause: endReasonOf(SSHDisconnectError(11, 'Maintenance window. ' * 20, authentic: true))),
      // Given up because the host stopped answering, with its tip.
      dropped(cause: hostStoppedAnswering),
      dropped(reconnecting: true, attempt: 1, cause: hostStoppedAnswering),
      // Its host ended the session, with as much printed last as is kept.
      dropped(cause: sessionEndedCause(exitCode: 255, said: [for (var i = 0; i < 6; i++) 'A row as long as a row is kept. ' * 7].join('\n'))),
      dropped(cause: sessionEndedCause(signal: 'HUP')),
      // Ended over its host's key when new keys were taken: three sentences.
      dropped(cause: hostKeyFailedAtNewKeys),
      // Ended over a packet that did not pass its check, with its tip, and while it is connected to again.
      dropped(cause: hostDataDamaged),
      dropped(reconnecting: true, attempt: 1, cause: hostDataDamaged),
    ];
    for (final locale in AppLocalizations.supportedLocales) {
      for (final state in states) {
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
            home: Scaffold(body: ConnectionLostView(sessionId: 's1', sessionState: state)),
          ),
        ));
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.takeException(), isNull, reason: '$locale ${state.isReconnecting ? 'connecting again' : state.errorMessage == null ? 'ended' : 'given up'}');
        if (dropKind(state.dropCause) == 'sessionEndedByHost') {
          final l10n = lookupAppLocalizations(locale);
          expect(find.text(l10n.sessionEndedTitle), findsOneWidget, reason: '$locale');
          final sentence = state.dropCause!.contains('signal')
              ? l10n.sessionEndedSignal('web-01', 'HUP')
              : l10n.sessionEndedStatus('web-01', 255);
          expect(find.text(sentence), findsOneWidget, reason: '$locale');
          if (locale.languageCode != 'en') {
            expect(l10n.sessionEndedTitle, isNot(en.sessionEndedTitle), reason: '$locale');
            expect(l10n.sessionEndedByHost('web-01'), isNot(en.sessionEndedByHost('web-01')), reason: '$locale');
            expect(l10n.sessionEndedStatus('web-01', 1), isNot(en.sessionEndedStatus('web-01', 1)), reason: '$locale');
            expect(l10n.sessionEndedSignal('web-01', 'HUP'), isNot(en.sessionEndedSignal('web-01', 'HUP')),
                reason: '$locale');
            expect(l10n.sessionEndedLastWords, isNot(en.sessionEndedLastWords), reason: '$locale');
          }
        }
        if (state.dropCause == hostKeyFailedAtNewKeys) {
          final l10n = lookupAppLocalizations(locale);
          expect(find.text(l10n.connHostKeyFailedAtNewKeys), findsOneWidget, reason: '$locale');
          if (locale.languageCode != 'en') {
            expect(l10n.connHostKeyFailedAtNewKeys, isNot(en.connHostKeyFailedAtNewKeys), reason: '$locale');
          }
        }
        if (state.dropCause == hostDataDamaged) {
          final l10n = lookupAppLocalizations(locale);
          expect(find.text(l10n.connectionLostDamaged('web-01')), findsOneWidget, reason: '$locale');
          expect(find.text(l10n.connectionLostDamagedTip), state.isReconnecting ? findsNothing : findsOneWidget,
              reason: '$locale');
        }
        if (state.dropCause == hostStoppedAnswering) {
          final l10n = lookupAppLocalizations(locale);
          expect(find.text(l10n.connectionLostNoAnswer('web-01')), findsOneWidget, reason: '$locale');
          // (What it can mean is said once it is no longer connecting again.)
          expect(find.text(l10n.connectionLostNoAnswerTip), state.isReconnecting ? findsNothing : findsOneWidget,
              reason: '$locale');
          if (locale.languageCode != 'en') {
            expect(l10n.connectionLostNoAnswer('web-01'), isNot(en.connectionLostNoAnswer('web-01')), reason: '$locale');
            expect(l10n.connectionLostNoAnswerTip, isNot(en.connectionLostNoAnswerTip), reason: '$locale');
          }
        }
        await tester.pumpWidget(const SizedBox());
        container.dispose();
      }
    }
  });
}
