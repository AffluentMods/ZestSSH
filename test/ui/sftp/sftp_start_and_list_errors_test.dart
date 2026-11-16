import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/session_ready.dart';
import 'package:zestssh/ui/screens/sftp/sftp_browser_screen.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_translator.dart' as translator show ConnectionError, saidByApp;

/// SFTP that could not be started, a session that never became ready for a
/// file pane, and a phone's folder that could not be listed say why in the
/// app's language, with their details (3.0). They said
/// "SFTP error:" or "Failed to initialize SFTP:" and the raw error, English
/// made up on the spot ("Session vanished"), or a guess from words in the
/// raw error; and a phone's Retry after its home folder was not found listed
/// "/" instead.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  group('what a failure says', () {
    test('a dropped connection is said as lost, a time-out as one', () {
      for (final error in <Object>[
        const SocketException('Connection reset by peer'),
        SSHSocketError(const SocketException('Broken pipe')),
        SSHStateError('Transport is closed'),
        SSHStateError('Connection closed while waiting for channel open'),
      ]) {
        expect(sftpErrorMessage(error, name: 'reports', op: SftpOp.list), 'The connection to the server was lost.',
            reason: '$error');
      }
      expect(sftpErrorMessage(TimeoutException('no answer')),
          'Operation timed out. The server took too long to respond.');
      // (Another state of the connection says what it said.)
      expect(sftpErrorMessage(SSHStateError('Unexpected KEX_REPLY')), 'Unexpected KEX_REPLY');
    });

    test('what names what was thrown is left out of what it said', () {
      expect(sftpErrorMessage(Exception('No route to the folder')), 'No route to the folder');
      expect(sftpErrorMessage(StateError('SFTP not open')), 'SFTP not open');
      expect(sftpErrorMessage(SSHChannelRequestError('subsystem request failed')), 'subsystem request failed');
      expect(sftpErrorMessage(const FormatException('bad input')), 'bad input');
    });

    test('text where SFTP was to answer (a shell that prints when a session starts): said as that, with what to '
        'look at, in every language', () {
      final error = SftpNotSftpError('Welcome to web-01');
      const said = "The host sent text where SFTP was to answer. A startup file of the account's shell (.bashrc, "
          '.profile) most likely prints something; it must print nothing unless the session is a terminal.';
      expect(sftpErrorMessage(error, op: SftpOp.list), said);
      expect(sftpErrorMessage(error, name: 'reports', op: SftpOp.download), said);
      // What came is for the report, not for the sentence.
      expect(said, isNot(contains('Welcome')));
      expect('$error', contains('"Welcome to web-01"'));
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        final t = lookupAppLocalizations(locale);
        expect(sftpErrorMessage(error, l10n: t), isNot(said), reason: '$locale');
        expect(sftpErrorMessage(error, l10n: t), contains('.bashrc'), reason: '$locale');
      }
      // Another error of the SFTP session still says what it said.
      expect(sftpErrorMessage(SftpError('Empty SFTP packet')), 'Empty SFTP packet');
    });

    test('SFTP that could not start: the connection lost, or the host did not start it', () {
      expect(sftpStartFailure(const SocketException('Connection reset by peer')),
          'The connection to the server was lost.');
      expect(sftpStartFailure(SSHStateError('Transport is closed')), 'The connection to the server was lost.');
      const refused = 'The host did not start SFTP. Its server may not offer SFTP, or may allow no more sessions.';
      expect(sftpStartFailure(SSHChannelOpenError(1, 'administratively prohibited')), refused);
      expect(sftpStartFailure(SftpAbortError('Connection closed')), refused);
      expect(sftpStartFailure(StateError('anything else')), refused);
      // What the SSH core says since it waits for the host's answer: of
      // SFTP the host refuses, of a channel the host closed without
      // answering, and of a connection that ended while the answer was
      // waited for (closed, or broken under it).
      expect(sftpStartFailure(SSHChannelRequestError('The server refused the "sftp" subsystem')), refused);
      expect(sftpStartFailure(SSHChannelRequestError('The channel closed before the request was answered')), refused);
      expect(sftpStartFailure(SSHStateError('Connection closed before the request was answered')),
          'The connection to the server was lost.');
      expect(sftpStartFailure(SSHSocketError(const SocketException('Connection reset by peer'))),
          'The connection to the server was lost.');
      // And of a connection given up because the host stopped answering.
      final quiet = SSHNoAnswerError(const Duration(seconds: 45), 3);
      expect(sftpStartFailure(quiet), 'The connection to the server was lost.');
      expect(sftpErrorMessage(quiet, name: 'reports', op: SftpOp.download), 'The connection to the server was lost.');
      // And of one the host ended itself: why is the session's to say.
      final ended = SSHDisconnectError(11, 'Idle timeout', authentic: true);
      expect(sftpStartFailure(ended), 'The connection to the server was lost.');
      expect(sftpErrorMessage(ended, name: 'reports', op: SftpOp.download), 'The connection to the server was lost.');
    });

    test('in every language the app speaks', () {
      final errors = <Object>[
        const SocketException('Connection reset by peer'),
        TimeoutException('no answer'),
      ];
      final refused = SSHChannelOpenError(1, 'administratively prohibited');
      for (final locale in AppLocalizations.supportedLocales) {
        if (locale.languageCode == 'en') continue;
        final t = lookupAppLocalizations(locale);
        for (final error in errors) {
          expect(sftpErrorMessage(error, l10n: t), isNot(sftpErrorMessage(error, l10n: en)), reason: '$locale $error');
        }
        for (final error in [errors.first, refused]) {
          expect(sftpStartFailure(error, l10n: t), isNot(sftpStartFailure(error, l10n: en)), reason: '$locale $error');
        }
      }
    });
  });

  group('a session for a file pane', () {
    const connecting = SessionState(status: SessionStatus.connecting);
    const connected = SessionState(status: SessionStatus.connected, connectionLabel: 'web-01');

    Future<SessionNotReady> notReady(SessionState? Function() read, {Duration timeout = const Duration(seconds: 30)}) async {
      try {
        await waitForSessionReady(read, timeout: timeout, every: const Duration(milliseconds: 5));
      } on SessionNotReady catch (e) {
        return e;
      }
      fail('it became ready');
    }

    test('is waited for until it is connected', () async {
      var asked = 0;
      final state = await waitForSessionReady(() => ++asked < 3 ? connecting : connected,
          every: const Duration(milliseconds: 5));
      expect(state, same(connected));
      expect(asked, 3);
    });

    test('that is gone or disconnected says the connection closed first', () async {
      final gone = await notReady(() => null);
      expect(gone.said, 'The connection closed before its files could open.');
      expect(gone.happened, 'The session was closed while it connected');
      final dropped = await notReady(() => const SessionState(status: SessionStatus.disconnected));
      expect(dropped.said, 'The connection closed before its files could open.');
      expect(dropped.happened, 'The session disconnected before SFTP opened');
    });

    test('that failed for a reason the app itself wrote says that reason', () async {
      const said = 'Your certificate is waiting for an owner.';
      final failed = await notReady(() => SessionState(
          status: SessionStatus.error, errorMessage: translator.saidByApp(said), host: 'web-01', port: 22));
      expect(failed.said, said, reason: 'not only that the connection failed');
      expect(failed.happened, 'ZestSSH: $said');
    });

    test('that failed to connect says so as its failure is said, with what it said for the report', () async {
      const raw = 'SocketException: Connection refused (OS Error: Connection refused, errno = 111)';
      final failed = await notReady(
          () => const SessionState(status: SessionStatus.error, errorMessage: raw, host: 'web-01', port: 22));
      expect(failed.said, translator.ConnectionError.translate(raw, host: 'web-01', port: 22).title);
      expect(failed.said, isNot(raw));
      expect(failed.happened, raw);
      expect(failed.toString(), raw);
    });

    test('that is not connected in time says so', () async {
      final slow = await notReady(() => connecting, timeout: const Duration(milliseconds: 20));
      expect(slow.said, 'The host did not connect in time. Try again once it is connected.');
      expect(slow.happened, 'The session was not connected after 0 s');
    });

    test('in the app\'s language', () async {
      final de = lookupAppLocalizations(const Locale('de'));
      L10nGlobal.update(de);
      expect((await notReady(() => null)).said, de.sftpSessionClosedBeforeOpen);
      expect((await notReady(() => connecting, timeout: Duration.zero)).said, de.sftpSessionNotConnectedYet);
    });
  });

  group('a phone\'s folder', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    Future<void> open(WidgetTester tester, _Sftp sftp) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SftpBrowserScreen(key: ObjectKey(sftp), sftp: sftp, connectionLabel: 'web-01'),
        ),
      ));
      await tester.pump();
      await tester.pump();
    }

    String said(WidgetTester tester) =>
        tester.widget<Text>(find.byKey(const ValueKey('sftp-browser-error'))).data!;

    testWidgets('a home folder not found says why, and Retry looks for it again', (tester) async {
      final sftp = _Sftp()..homeErrors.add(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));
      await open(tester, sftp);
      expect(said(tester), "Permission denied: your account can't open \"Home\" on the server.");
      final report = tester.widget<ErrorDetailsPanel>(find.byType(ErrorDetailsPanel)).report;
      expect(report, contains('Where: Files: finding the home folder\n'));
      expect(report, contains('Error: '));
      expect(sftp.listed, isEmpty);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(sftp.homeAsked, 2);
      expect(sftp.listed, ['/home/demo']);
      expect(find.byKey(const ValueKey('sftp-browser-error')), findsNothing);
      expect(find.byType(ErrorDetailsPanel), findsNothing);
    });

    testWidgets('a folder not listed says why about it, with its report; Retry lists it again', (tester) async {
      final sftp = _Sftp()..listErrors.add(const SocketException('Connection reset by peer'));
      await open(tester, sftp);
      expect(said(tester), 'The connection to the server was lost.');
      final report = tester.widget<ErrorDetailsPanel>(find.byType(ErrorDetailsPanel)).report;
      expect(report, contains('What: The connection to the server was lost.\n'));
      expect(report, contains('Where: Files: listing a folder\n'));
      expect(report, isNot(contains('/home/demo')));

      final denied = _Sftp()..listErrors.add(SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'));
      await open(tester, denied);
      expect(said(tester), "Permission denied: your account can't open \"demo\" on the server.");
      final deniedReport = tester.widget<ErrorDetailsPanel>(find.byType(ErrorDetailsPanel)).report;
      expect(deniedReport, contains("What: Permission denied: your account can't open the item on the server.\n"));
      expect(deniedReport, isNot(contains('demo')));

      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump();
      expect(denied.homeAsked, 1);
      expect(denied.listed, ['/home/demo', '/home/demo']);
      expect(find.byKey(const ValueKey('sftp-browser-error')), findsNothing);
    });
  });
}

/// An SFTP connection whose home folder and listings fail as told, once each.
class _Sftp implements SftpService {
  final List<Object> homeErrors = [];
  final List<Object> listErrors = [];
  int homeAsked = 0;
  final List<String> listed = [];

  @override
  Future<String> getHomeDirectory() async {
    homeAsked++;
    if (homeErrors.isNotEmpty) throw homeErrors.removeAt(0);
    return '/home/demo';
  }

  @override
  Future<List<SftpEntry>> listDirectory(String path) async {
    listed.add(path);
    if (listErrors.isNotEmpty) throw listErrors.removeAt(0);
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}
