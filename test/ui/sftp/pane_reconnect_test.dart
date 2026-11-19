import 'dart:async';
import 'dart:io' show SocketException;

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
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
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/sftp/sftp_dual_pane_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/features/orchards/spaces.dart' show Space;

import '../../helpers/played_sftp_host.dart';

/// A file pane whose connection dropped and came back (3.0, the SSH core's
/// audit), on the real two-pane file screen with the hosts played by the
/// test and the sessions set by it.
///
/// A session that is connected again has a connection of its own, and the
/// pane went on asking the file service of the one that had dropped: every
/// listing said that the connection to the server was lost, Retry asked the
/// same service again, and picking the host anew handed the pane that same
/// service, since it still said that it was open. It stayed so until the
/// file screen was closed. And a pane whose session had been closed went on
/// showing what it had listed, of a host that nothing could be asked of any
/// more.
class PlayedSessions extends ActiveSessionsNotifier {
  PlayedSessions(super.ref);

  /// The saved hosts that were asked to be connected.
  final started = <String>[];

  void set(Map<String, SessionState> sessions) => state = sessions;

  @override
  Future<bool> hostAllows(String? connectionId, String what) async => true;

  /// A session for [connection] that is connecting, as the app's own makes
  /// one: 's3', 's4' and so on.
  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    started.add(connection.id);
    final id = 's${2 + started.length}';
    state = {
      ...state,
      id: SessionState.connecting(connection.id,
          connectionLabel: connection.label, host: connection.host, port: connection.port),
    };
    return id;
  }
}

/// The SSH service of a session, of which the file screen takes the
/// connection and how the host is named.
class _PlayedSsh implements SshService {
  _PlayedSsh(this.client, this.host);

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

/// A session that is connected, on [connection], to the saved host
/// [savedAs] (its own, where none is given).
SessionState connected(String id, String label, PlayedConnection connection, {String? savedAs}) => SessionState(
      status: SessionStatus.connected,
      connectionId: savedAs ?? 'c-$id',
      connectionLabel: label,
      host: '$label.example.com',
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: savedAs ?? 'c-$id',
        terminal: Terminal(),
        shell: _PlayedSsh(connection.client, '$label.example.com'),
        startedAt: DateTime(2026, 10, 10),
      ),
    );

/// A session whose connection dropped, and which is trying to connect
/// again.
SessionState dropped(String id, String label) => SessionState(
      status: SessionStatus.disconnected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: '$label.example.com',
      port: 22,
      username: 'deploy',
      dropped: true,
      dropCause: 'Connection reset by peer',
      isReconnecting: true,
      reconnectAttempt: 1,
    );

/// The file screen with a pane on each of two hosts: log-store on the left,
/// which nothing happens to, and web-01 on the right (or web-01 in both).
class Files {
  Files(this.tester, this.container, this.db, this.logs, this.web, this.logsLine, this.webLine, this.left, this.right);

  final WidgetTester tester;
  final ProviderContainer container;
  final AppDatabase db;
  final PlayedSftpHost logs;
  final PlayedSftpHost web;
  PlayedConnection logsLine;

  /// The connection the session of web-01 has now.
  PlayedConnection webLine;
  final SftpService left;

  /// The file service web-01's pane began with.
  final SftpService right;

  PlayedSessions get sessions => container.read(activeSessionsProvider.notifier) as PlayedSessions;

  /// What becomes of the session [id] (null: it is gone).
  void put(String id, SessionState? state) {
    final next = {...container.read(activeSessionsProvider)};
    if (state == null) {
      next.remove(id);
    } else {
      next[id] = state;
    }
    sessions.set(next);
  }

  /// The connection of web-01 drops, and its session tries to connect again.
  Future<void> drops() async {
    webLine.drop(SSHSocketError(const SocketException('Connection reset by peer')));
    put('s1', dropped('s1', 'web-01'));
    await settle();
  }

  /// The session of web-01 is connected again, on [line] or on a connection
  /// of its own that works.
  Future<void> comesBack([PlayedConnection? line]) async {
    webLine = line ?? web.connect();
    put('s1', connected('s1', 'web-01', webLine));
    await settle();
  }

  /// Lets the played hosts answer and the screen draw what they said.
  Future<void> settle() async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The same, with the database answering too, which it does in real time.
  Future<void> settleWithDatabase() async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The pane on the right.
  SftpPaneState get pane => tester.state<SftpPaneState>(find.byType(SftpPane).last);

  /// The file service that is registered for the session of web-01.
  SftpService? get registered => container.read(sftpSessionsProvider)['s1'];

  /// How often web-01 was asked for what is in [folder].
  int listed(String folder) => web.asked.where((request) => request == 'opendir $folder').length;
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final lost = SSHSocketError(const SocketException('Connection reset by peer'));

  PlayedSftpHost host(String home, List<String> paths) {
    final played = PlayedSftpHost()..home = home;
    for (final path in paths) {
      played.files[path] = PlayedFile('x'.codeUnits);
    }
    return played;
  }

  PlayedSftpHost webHost() => host('/srv/app', ['/srv/app/notes.txt', '/srv/app/conf/site.conf']);

  group('the file source of a pane', () {
    test('where the host ended only the file session, the next listing opens one again; where the connection is '
        'gone, it fails with what the connection ended with', () async {
      final web = webHost();
      final line = web.connect();
      final sftp = SftpService(line.client);
      addTearDown(sftp.close);
      await sftp.open();
      final source = RemotePaneFileSource(service: sftp, sourceId: 's1');
      expect((await source.list('/srv/app')).map((entry) => entry.name), ['conf', 'notes.txt']);

      line.endSessions();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(sftp.isOpen, isFalse);
      expect((await source.list('/srv/app')).map((entry) => entry.name), ['conf', 'notes.txt']);
      expect(sftp.isOpen, isTrue);
      expect(line.asked, 2, reason: 'opened once more, on the connection it has');
      // While it is open, a listing opens nothing.
      await source.list('/srv/app/conf');
      expect(line.asked, 2);

      line.drop(lost);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await expectLater(source.list('/srv/app'), throwsA(same(lost)));
      expect(sftp.isOpen, isFalse);
    });

    test('a file service that whoever else held it has closed is opened again by the next listing', () async {
      final web = webHost();
      final sftp = SftpService(web.connect().client);
      addTearDown(sftp.close);
      await sftp.open();
      final source = RemotePaneFileSource(service: sftp, sourceId: 's1');
      await sftp.close();
      expect((await source.list('/srv/app')).map((entry) => entry.name), ['conf', 'notes.txt']);
      expect(sftp.isOpen, isTrue);
    });
  });

  Future<Files> pumpFiles(WidgetTester tester, {bool bothOnWeb = false}) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(() => tester.runAsync(db.close));
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      activeSessionsProvider.overrideWith(PlayedSessions.new),
    ]);
    addTearDown(container.dispose);

    final logs = host('/var/log', ['/var/log/syslog', '/var/log/auth.log']);
    final web = webHost();
    final logsLine = logs.connect();
    final webLine = web.connect();
    final left = SftpService(logsLine.client);
    final right = SftpService(webLine.client);
    await left.open();
    await right.open();
    container.read(sftpSessionsProvider.notifier)
      ..register('s0', left)
      ..register('s1', right);
    final files = Files(tester, container, db, logs, web, logsLine, webLine, left, right)
      ..put('s0', connected('s0', 'log-store', logsLine))
      ..put('s1', connected('s1', 'web-01', webLine));

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SftpDualPaneScreen(
            leftSftp: bothOnWeb ? right : left,
            leftLabel: bothOnWeb ? 'web-01' : 'log-store',
            leftSessionId: bothOnWeb ? 's1' : 's0',
            sftp: right,
            connectionLabel: 'web-01',
            initialSessionId: 's1',
            embedded: true,
          ),
        ),
      ),
    ));
    await files.settle();
    expect(find.text('notes.txt'), bothOnWeb ? findsNWidgets(2) : findsOneWidget);
    expect(find.text('syslog'), bothOnWeb ? findsNothing : findsOneWidget);
    return files;
  }

  /// Takes the screen down while the test still runs, so that what closes with it closes inside the test.
  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('a pane whose connection dropped says so when it is asked, and lists where it was, by itself, once '
      'its session is connected again', (tester) async {
    final files = await pumpFiles(tester);
    // (Not waited for by itself: the host answers while the test's clock is moved.)
    unawaited(files.pane.navigateTo('/srv/app/conf'));
    await files.settle();
    expect(find.text('site.conf'), findsOneWidget);

    await files.drops();
    expect(find.text('site.conf'), findsOneWidget, reason: 'what was listed stays');
    expect(find.text(en.sftpErrConnectionLost), findsNothing, reason: 'nothing was asked yet');

    // Asked while the connection is gone, it says so; and so does Retry, with nothing asked of the host.
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsOneWidget);
    await tester.tap(find.text(en.retry));
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsOneWidget);
    expect(files.listed('/srv/app/conf'), 1);

    // Meanwhile a file is put there. The session is connected again, on a connection of its own.
    files.web.files['/srv/app/conf/new.conf'] = PlayedFile('y'.codeUnits);
    await files.comesBack();
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(find.text('site.conf'), findsOneWidget);
    expect(find.text('new.conf'), findsOneWidget);
    expect(files.pane.currentPath, '/srv/app/conf');
    expect(find.text('syslog'), findsOneWidget, reason: 'the other pane is as it was');

    // The session has a file service that is open, and it is not the one whose connection dropped.
    final given = files.registered!;
    expect(given, isNot(same(files.right)));
    expect(given.isOpen, isTrue);
    expect(files.right.isOpen, isFalse);
    expect(files.webLine.asked, 1, reason: 'one file session on the connection it has now');

    // What the file screen opened is closed with it, and no longer the session's.
    await finish(tester);
    expect(files.registered, isNull);
    expect(given.isOpen, isFalse);
  });

  testWidgets('a pane that nobody touched while its connection was gone goes on when it is back: what it listed '
      'stays, and what it is asked next is asked on the connection the session has now', (tester) async {
    final files = await pumpFiles(tester);
    // While its file service goes on, a pane is left as it is, whatever the sessions do.
    final before = files.pane.widget.source;
    files.put('s1', files.container.read(activeSessionsProvider)['s1']!.withLog('a line'));
    await files.settle();
    expect(files.pane.widget.source, same(before));
    expect(files.webLine.asked, 1);

    await files.drops();
    await files.comesBack();
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(files.listed('/srv/app'), 1, reason: 'nothing was listed anew: nothing had failed');

    files.web.files['/srv/app/new.log'] = PlayedFile('y'.codeUnits);
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text('new.log'), findsOneWidget);
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    await finish(tester);
  });

  testWidgets('two panes on the same host are given the same file service when its session is connected again',
      (tester) async {
    final files = await pumpFiles(tester, bothOnWeb: true);
    await files.drops();
    await tester.tap(find.byTooltip(en.refresh).first);
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsNWidgets(2));

    files.web.files['/srv/app/new.log'] = PlayedFile('y'.codeUnits);
    // Connected again, with the sessions changing once more in the same moment.
    files.webLine = files.web.connect();
    files
      ..put('s1', connected('s1', 'web-01', files.webLine))
      ..put('s0', files.container.read(activeSessionsProvider)['s0']!.withLog('a line'));
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(find.text('new.log'), findsNWidgets(2));
    expect(files.webLine.asked, 1, reason: 'one file session for both, and not one each');
    expect(files.registered!.isOpen, isTrue);
    await finish(tester);
  });

  testWidgets('two hosts whose sessions are connected again one right after the other: both panes go on',
      (tester) async {
    final files = await pumpFiles(tester);
    files.logsLine.drop(lost);
    files.put('s0', dropped('s0', 'log-store'));
    await files.drops();
    await tester.tap(find.byTooltip(en.refresh).first);
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsNWidgets(2));

    // web-01 first, and log-store while the pane of web-01 is being given its file service.
    files
      ..webLine = files.web.connect()
      ..logsLine = files.logs.connect()
      ..put('s1', connected('s1', 'web-01', files.webLine))
      ..put('s0', connected('s0', 'log-store', files.logsLine));
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(find.text('syslog'), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a host that gives the connection it has now no file session: said once, and not again at every '
      'change of the sessions; a connection that gives one is taken', (tester) async {
    final files = await pumpFiles(tester);
    final first = files.webLine;
    await files.drops();
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text(en.sftpErrConnectionLost), findsOneWidget);
    final askedOfTheFirst = first.asked;

    final refusing = files.web.connect()..refuses = SSHChannelRequestError('The server refused the subsystem sftp');
    await files.comesBack(refusing);
    expect(refusing.asked, 1);
    expect(find.text(en.sftpErrConnectionLost), findsOneWidget, reason: 'the pane is as it was');
    expect(first.asked, askedOfTheFirst + 1,
        reason: 'the connection that dropped was asked once more, by the screen; the pane is handed nothing, and '
            'asks nothing again');
    // The sessions change, and this one is still on that connection: nothing more is asked of it.
    files.put('s1', files.container.read(activeSessionsProvider)['s1']!.withLog('a line'));
    await files.settle();
    files.put('s0', files.container.read(activeSessionsProvider)['s0']!.withLog('a line'));
    await files.settle();
    expect(refusing.asked, 1);

    // Connected once more, on a connection that gives it one.
    await files.drops();
    await files.comesBack();
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(find.text('notes.txt'), findsOneWidget);
    expect(files.webLine.asked, 1);
    await finish(tester);
  });

  testWidgets('where the host ended only the file session, Refresh opens one again on the same connection',
      (tester) async {
    final files = await pumpFiles(tester);
    files.webLine.endSessions();
    await files.settle();
    files.web.files['/srv/app/new.log'] = PlayedFile('y'.codeUnits);
    await tester.tap(find.byTooltip(en.refresh).last);
    await files.settle();
    expect(find.text('new.log'), findsOneWidget);
    expect(find.text(en.sftpErrConnectionLost), findsNothing);
    expect(files.registered, same(files.right));
    expect(files.right.isOpen, isTrue);
    expect(files.webLine.asked, 2);
    await finish(tester);
  });

  group('a pane whose session is gone', () {
    /// The tab of web-01 is closed: its file service is closed, and its session ended.
    Future<void> closeTab(Files files) async {
      files.container.read(sftpSessionsProvider.notifier).unregister('s1');
      await files.right.close();
      files.put('s1', null);
      await files.settle();
    }

    testWidgets('says that its host is disconnected, and Reconnect connects that host again and opens the pane where '
        'it was', (tester) async {
      final files = await pumpFiles(tester);
      final at = DateTime(2026, 10, 10);
      await tester.runAsync(() => files.db.into(files.db.connections).insert(ConnectionsCompanion.insert(
            id: 'c-s1',
            label: 'web-01',
            host: 'web-01.example.com',
            createdAt: at,
            updatedAt: at,
          )));
      unawaited(files.pane.navigateTo('/srv/app/conf'));
      await files.settle();

      await closeTab(files);
      expect(find.text(en.sftpDisconnectedMessage), findsOneWidget);
      expect(find.text('site.conf'), findsNothing);
      expect(find.text('syslog'), findsOneWidget, reason: 'the other pane is as it was');

      await tester.tap(find.text(en.sftpReconnect));
      await files.settleWithDatabase();
      expect(files.sessions.started, ['c-s1']);
      // The session it was given connects.
      files.webLine = files.web.connect();
      files.put('s3', connected('s3', 'web-01', files.webLine, savedAs: 'c-s1'));
      await files.settle();
      expect(find.text(en.sftpDisconnectedMessage), findsNothing);
      expect(find.text('site.conf'), findsOneWidget);
      expect(files.pane.currentPath, '/srv/app/conf');
      String? syncedAs() => (files.pane.widget.sourceDescriptor as RemotePaneSource).serverId;
      expect(syncedAs(), 'deploy@web-01.example.com:22');

      // The connection of that session drops and comes back: the pane is still what its files are synced as.
      files.webLine.drop(lost);
      files.put('s3', dropped('s3', 'web-01'));
      await files.settle();
      files.webLine = files.web.connect();
      files.put('s3', connected('s3', 'web-01', files.webLine, savedAs: 'c-s1'));
      await files.settle();
      expect(files.container.read(sftpSessionsProvider)['s3']!.isOpen, isTrue);
      expect(syncedAs(), 'deploy@web-01.example.com:22');

      // And that session, which came after the screen was opened, is gone in its turn.
      files.put('s3', null);
      await files.settle();
      expect(find.text(en.sftpDisconnectedMessage), findsOneWidget);
      await finish(tester);
    });

    testWidgets('and whose host is no longer saved: Reconnect offers the hosts to pick from', (tester) async {
      final files = await pumpFiles(tester);
      await closeTab(files);
      expect(find.text(en.sftpDisconnectedMessage), findsOneWidget);
      await tester.tap(find.text(en.sftpReconnect));
      await files.settleWithDatabase();
      expect(files.sessions.started, isEmpty);
      expect(find.text(en.sftpConnectToHost), findsOneWidget);
      await finish(tester);
    });

    testWidgets('and whose host is saved as Telnet now: Reconnect opens no session (unencrypted, with no SFTP) and '
        'says that SFTP needs SSH', (tester) async {
      // Reconnect goes the way a host picked in the Files host pickers goes.
      final files = await pumpFiles(tester);
      final at = DateTime(2026, 10, 10);
      await tester.runAsync(() => files.db.into(files.db.connections).insert(ConnectionsCompanion.insert(
            id: 'c-s1',
            label: 'web-01',
            host: 'web-01.example.com',
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          )));
      await closeTab(files);
      await tester.tap(find.text(en.sftpReconnect));
      await files.settleWithDatabase();
      expect(files.sessions.started, isEmpty);
      // (On a computer a toast is a notice in the notification center.)
      final said = files.container.read(notificationCenterProvider).history.map((n) => '${n.title} ${n.body ?? ''}');
      expect(said.where((n) => n.contains(en.desktopShellSftpRequiresSsh)), hasLength(1));
      await finish(tester);
    });

    testWidgets('a pane that was opened for no session of its own is left alone when the sessions change',
        (tester) async {
      // (The file screen is also opened with a file service alone, and names the pane's source itself.)
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        activeSessionsProvider.overrideWith(PlayedSessions.new),
      ]);
      addTearDown(container.dispose);
      final web = webHost();
      final line = web.connect();
      final sftp = SftpService(line.client);
      await sftp.open();
      final sessions = container.read(activeSessionsProvider.notifier) as PlayedSessions
        ..set({'s1': connected('s1', 'web-01', line)});
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: SftpDualPaneScreen(leftSftp: sftp, leftLabel: 'web-01', sftp: sftp, connectionLabel: 'web-01', embedded: true),
          ),
        ),
      ));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('notes.txt'), findsNWidgets(2));
      sessions.set({});
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text(en.sftpDisconnectedMessage), findsNothing);
      expect(find.text('notes.txt'), findsNWidgets(2));
      await finish(tester);
      await sftp.close();
    });
  });
}
