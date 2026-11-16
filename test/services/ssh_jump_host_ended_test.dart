import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
// The messages a played server sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_disconnect.dart';
import 'package:zestssh/features/monitoring/monitor_evaluation.dart' show CantCheckReason, failedCheckReason;
import 'package:zestssh/features/monitoring/monitor_state_ui.dart' show failedCheckSaid;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/monitor_poll_providers.dart' show MonitorHostState, MonitorHostStatus;
import 'package:zestssh/providers/terminal_providers.dart'
    show SessionState, connectionFailureText, jumpHostEndedOnTheWayText, reconnectCannotHelp;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome, monitorExecFailure;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart' show staysToBeRead;
import 'package:zestssh/ui/widgets/connection_lost_view.dart' show dropKind, dropSaid;
import 'package:zestssh/utils/error_translator.dart' show ConnectionError, ConnectionErrorType, saidByApp;
import 'package:zestssh/utils/redactor.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_jump_host.dart';

/// A session that goes through a jump host, when it is the connection to
/// the jump host that ends (3.0; the SSH core's audit, the last of its
/// small findings).
///
/// The way from a jump host to the host is a channel of the jump host's
/// connection, and the host's own connection runs inside it. When the jump
/// host's connection ended, whatever ended it, the host's connection saw
/// its line close and nothing else, and the session said that the host had
/// closed the connection: also where the jump host had shown another key
/// when it asked for new keys, which is somebody who has got into the
/// connection to it, and the session was connected to again by itself.
///
/// With the app's own service on the real test server, through jump hosts
/// played by the test.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final port = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  late bool up;
  SSHKeyPair? key;

  setUpAll(() async {
    try {
      final s = await Socket.connect(host, port, timeout: const Duration(seconds: 2));
      s.destroy();
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (up) key = SSHKeyPair.fromPem(file.readAsStringSync()).single;
    } catch (_) {
      up = false;
    }
  });

  setUp(() => L10nGlobal.update(en));

  /// A client of the test's on a played jump host, signed in.
  Future<SSHClient> signedInTo(PlayedJumpHost jump, SSHSocket socket) async {
    final client = SSHClient(socket, username: 'deploy', algorithms: jump.server.speaks, keepAliveInterval: null);
    addTearDown(client.close);
    unawaited(jump.letIn());
    await client.authenticated.timeout(const Duration(seconds: 10));
    return client;
  }

  /// The way to the real server through played jump hosts: one
  /// ([outer]), or two, with [inner] behind [outer] and nearest the host.
  Future<({SSHSocket way, PlayedJumpHost outer, PlayedJumpHost? inner, List<SSHClient> clients})> theWay({
    bool two = false,
  }) async {
    final outer = PlayedJumpHost();
    addTearDown(outer.stop);
    final toOuter = await signedInTo(outer, outer.server.socket);
    PlayedJumpHost? inner;
    SSHClient? toInner;
    if (two) {
      final line = outer.carryToAPlayedServer();
      final behind = await toOuter.forwardLocal('192.168.10.23', 22).timeout(const Duration(seconds: 10));
      final second = inner = PlayedJumpHost(line: await line);
      addTearDown(second.stop);
      toInner = await signedInTo(second, behind);
    }
    final carried = (inner ?? outer).carryTo(host, port);
    final way = await (toInner ?? toOuter).forwardLocal(host, port).timeout(const Duration(seconds: 10));
    await carried;
    // Nearest the host first, as the app hands them to its service.
    return (way: way, outer: outer, inner: inner, clients: [?toInner, toOuter]);
  }

  /// A session of the app's own service on the real server, through played
  /// jump hosts that the app calls by [labels].
  Future<({SshService ssh, PlayedJumpHost outer, PlayedJumpHost? inner, List<String> log, List<SSHClient> clients})>
      throughJumpHosts({List<String>? labels = const ['vpn-gateway'], bool two = false}) async {
    final w = await theWay(two: two);
    final log = <String>[];
    final ssh = SshService(
      host: host,
      port: port,
      username: user,
      keyPairs: [key!],
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      onLog: log.add,
      tunnelSocket: w.way,
      jumpClients: w.clients,
      jumpLabels: labels,
    );
    addTearDown(ssh.disconnect);
    await ssh.connect().timeout(const Duration(seconds: 20));
    return (ssh: ssh, outer: w.outer, inner: w.inner, log: log, clients: w.clients);
  }

  /// What the log says of jump hosts whose connections ended.
  Iterable<String> endsOfJumpHosts(List<String> log) =>
      log.where((line) => line.startsWith('jump: The ') && (line.contains(' ended - ') || line.endsWith(' closed its connection')));

  group('a session through a jump host, when the connection to the jump host ends', () {
    test('the jump host shows another key when it asks for new keys: said as that, of the jump host', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      // Whoever has got into the connection to the jump host asks for new keys, with a key of their own.
      s.outer.quiet();
      unawaited(s.outer.server.rekey(hostKey: PlayedHostKey.ed25519()).then((_) {}, onError: (Object _) {}));
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      expect(reason, endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys));
      expect(jumpHostEnded(reason), (label: 'vpn-gateway', reason: hostKeyFailedAtNewKeys));
      expect(endReasonItself(reason), hostKeyFailedAtNewKeys);
      expect(endsOfJumpHosts(s.log), [
        'jump: The connection to the jump host vpn-gateway ended - '
            'ssh_hostkey: Host key REJECTED when new keys were taken - Host key changed during re-key',
      ]);
    });

    test('the jump host ends its connection and says why: its words, as the jump host\'s', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      s.outer.server.send([
        SSH_Message_Disconnect(reasonCode: 2, description: 'idle for too long', languageTag: '').encode(),
      ]);
      s.outer.server.hangUp();
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      final itsOwn = endReasonOf(SSHDisconnectError(2, 'idle for too long', authentic: true));
      expect(reason, endedAtJumpHost('vpn-gateway', itsOwn));
      expect(hostSaid(endReasonItself(reason)), 'idle for too long');
      expect(hostSaid(reason), isNull, reason: 'they are not the host\'s words');
      expect(endsOfJumpHosts(s.log), hasLength(1));
      expect(endsOfJumpHosts(s.log).single,
          startsWith('jump: The connection to the jump host vpn-gateway ended - ssh_session: '));
      expect(endsOfJumpHosts(s.log).single, contains('idle for too long'));
    });

    test('the connection to the jump host ends with nothing said: the jump host closed it, not the host', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      s.outer.server.hangUp();
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      expect(reason, endedAtJumpHost('vpn-gateway', hostClosedConnection));
      expect(reason, isNot(hostClosedConnection));
      expect(endsOfJumpHosts(s.log), ['jump: The jump host vpn-gateway closed its connection']);
    });

    test('the session is closed right after the jump host\'s connection ended: still said of the jump host',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      s.outer.server.hangUp();
      final clock = Stopwatch()..start();
      while (!s.clients.single.isClosed) {
        if (clock.elapsed > const Duration(seconds: 10)) fail('the jump host\'s connection did not end');
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      // Whoever holds the session lets go of it at once, which closes every connection it has.
      await s.ssh.disconnect();
      expect(await s.ssh.endReason.timeout(const Duration(seconds: 15)),
          endedAtJumpHost('vpn-gateway', hostClosedConnection));
    });

    test('the connection to the jump host goes and the session is closed in the same breath: it had ended by '
        'itself, and is said so', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      // Gone, with nothing heard of it yet when whoever holds the session lets go of it. (Closed from here, which
      // is not the session closing it.)
      s.clients.single.close();
      unawaited(s.ssh.disconnect());
      expect(await s.ssh.endReason.timeout(const Duration(seconds: 15)),
          endedAtJumpHost('vpn-gateway', hostClosedConnection));
      expect(endsOfJumpHosts(s.log), ['jump: The jump host vpn-gateway closed its connection']);
    });

    test('the jump host closes the way on a moment before it ends its connection: said of the jump host', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      s.outer.closeWay();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(s.clients.single.isClosed, isFalse, reason: 'its connection is still there');
      s.outer.server.hangUp();
      expect(await s.ssh.endReason.timeout(const Duration(seconds: 15)),
          endedAtJumpHost('vpn-gateway', hostClosedConnection));
    });
  });

  group('what is no end of a jump host\'s connection', () {
    test('the way on closes and the jump host\'s connection stays: the host\'s own end, said soon enough, and '
        'the connection to the jump host is closed with it', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      s.outer.closeWay();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(s.clients.single.isClosed, isFalse, reason: 'it is not closed before the end is told');
      // A session waits two seconds to hear why it dropped.
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 2));
      expect(reason, hostClosedConnection);
      expect(jumpHostEnded(reason), isNull);
      // Whoever held the connection lets go of it now: nothing else would close what it came through.
      expect(s.clients.single.isClosed, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(endsOfJumpHosts(s.log), isEmpty, reason: 'closing it is no end of its own');
    });

    test('its person closes the session: nothing is said of a jump host, whose connection is closed with it',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts();
      await s.ssh.disconnect();
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      expect(jumpHostEnded(reason), isNull);
      expect(reason, hostClosedConnection);
      expect(s.clients.single.isClosed, isTrue);
      // The end of the jump host's connection has been heard of by now.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(endsOfJumpHosts(s.log), isEmpty);
    });
  });

  group('which jump host it was', () {
    test('a jump host the app has no name for is called by its place on the way', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      for (final labels in <List<String>?>[null, const [], const ['  ']]) {
        final s = await throughJumpHosts(labels: labels);
        s.outer.server.hangUp();
        expect(await s.ssh.endReason.timeout(const Duration(seconds: 15)), endedAtJumpHost('1', hostClosedConnection),
            reason: '$labels');
        expect(endsOfJumpHosts(s.log), ['jump: The jump host 1 closed its connection']);
      }
    });

    test('of two on the way, the first one ends its connection: that one is named, not the one behind it',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts(labels: const ['inner-bastion', 'bastion'], two: true);
      s.outer.server.send([
        SSH_Message_Disconnect(reasonCode: 2, description: 'going down for maintenance', languageTag: '').encode(),
      ]);
      s.outer.server.hangUp();
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      expect(reason,
          endedAtJumpHost('bastion', endReasonOf(SSHDisconnectError(2, 'going down for maintenance', authentic: true))));
      // The one behind it went with it, and the log has both, each as what it was.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(endsOfJumpHosts(s.log), hasLength(2));
      expect(endsOfJumpHosts(s.log).where((line) => line.contains('going down for maintenance')).single,
          startsWith('jump: The connection to the jump host bastion ended - '));
      expect(endsOfJumpHosts(s.log).where((line) => line.contains('inner-bastion')), hasLength(1));
    });

    test('of two on the way, the one nearest the host ends its connection: that one is named', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final s = await throughJumpHosts(labels: const ['inner-bastion', 'bastion'], two: true);
      s.inner!.quiet();
      unawaited(s.inner!.server.rekey(hostKey: PlayedHostKey.ed25519()).then((_) {}, onError: (Object _) {}));
      final reason = await s.ssh.endReason.timeout(const Duration(seconds: 15));
      expect(reason, endedAtJumpHost('inner-bastion', hostKeyFailedAtNewKeys));
      // The first jump host's connection had not ended: it is closed with the session's, and that is no end of
      // its own.
      expect(s.clients.every((client) => client.isClosed), isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(endsOfJumpHosts(s.log), hasLength(1));
      expect(endsOfJumpHosts(s.log).single, startsWith('jump: The connection to the jump host inner-bastion ended - '));
    });
  });

  group('the reason as it is kept', () {
    test('a jump host\'s name comes back as it was, whatever is in it, and the reason with it', () {
      for (final label in ['vpn-gateway', 'a "quoted" name', 'bastion: the old one', r'back\slash', 'two\nlines', '']) {
        for (final reason in [
          hostClosedConnection,
          hostKeyFailedAtNewKeys,
          endReasonOf(SSHDisconnectError(2, 'bye: "now"', authentic: true)),
          'SocketException: Connection reset by peer\n(OS Error: 10054)',
        ]) {
          final kept = endedAtJumpHost(label, reason);
          expect(jumpHostEnded(kept), (label: label, reason: reason), reason: kept);
          expect(endReasonItself(kept), reason);
        }
      }
      // A jump host that is named like the start of such a reason.
      final odd = endedAtJumpHost('x": $hostKeyFailedAtNewKeys', hostClosedConnection);
      expect(jumpHostEnded(odd), (label: 'x": $hostKeyFailedAtNewKeys', reason: hostClosedConnection));
      expect(endReasonItself(odd), hostClosedConnection);
    });

    test('what is no such reason is the reason itself: a host\'s own end, and words a host chose', () {
      for (final reason in [
        hostClosedConnection,
        hostStoppedAnswering,
        hostKeyFailedAtNewKeys,
        hostDataDamaged,
        sessionEndedCause(exitCode: 1, said: 'bye'),
        'SocketException: Broken pipe',
        'At the jump host vpn-gateway: $hostKeyFailedAtNewKeys',
        'At the jump host "vpn-gateway" $hostKeyFailedAtNewKeys',
        'at the jump host "vpn-gateway": $hostKeyFailedAtNewKeys',
        ' At the jump host "vpn-gateway": $hostKeyFailedAtNewKeys',
        'At the jump host "vpn-gateway: $hostKeyFailedAtNewKeys',
      ]) {
        expect(jumpHostEnded(reason), isNull, reason: reason);
        expect(endReasonItself(reason), reason);
      }
      expect(jumpHostEnded(null), isNull);
      expect(endReasonItself(null), isNull);
      // A host that ends its connection saying what the app says of a jump host: its words, and no more.
      final forged = endReasonOf(
          SSHDisconnectError(2, endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys), authentic: true));
      expect(jumpHostEnded(forged), isNull);
      expect(endReasonItself(forged), forged);
      expect(hostSaid(forged), endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys));
      final unverified = endReasonOf(
          SSHDisconnectError(2, endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys), authentic: false));
      expect(jumpHostEnded(unverified), isNull);
    });
  });

  group('what the session says of it', () {
    SessionState dropped(String? cause) => SessionState.disconnected(
          connectionId: 'h-web',
          connectionLabel: 'web-01',
          host: 'web-01.example.com',
          port: 22,
          dropped: true,
          dropCause: cause,
        );
    final lead = en.connectionLostAtJumpHost('web-01', 'vpn-gateway');

    test('that it was the jump host\'s connection, and why, with the jump host\'s name', () {
      expect(lead, 'The connection to web-01 goes through the jump host vpn-gateway, and it was the connection to '
          'that jump host that ended.');
      String at(String reason) => endedAtJumpHost('vpn-gateway', reason);
      expect(dropSaid(en, dropped(at(hostClosedConnection)), 'web-01'),
          (sentence: '$lead vpn-gateway closed the connection.', tip: null, printed: null));
      expect(dropSaid(en, dropped(at(hostStoppedAnswering)), 'web-01'), (
        sentence: '$lead vpn-gateway stopped answering, and the connection was given up.',
        tip: en.connectionLostNoAnswerTip,
        printed: null,
      ));
      expect(dropSaid(en, dropped(at(hostDataDamaged)), 'web-01'), (
        sentence: '$lead ${en.connectionLostDamaged('vpn-gateway')}',
        tip: en.connectionLostDamagedTip,
        printed: null,
      ));
      expect(
          dropSaid(en, dropped(at(endReasonOf(SSHDisconnectError(2, 'idle for too long', authentic: true)))), 'web-01'),
          (sentence: '$lead vpn-gateway ended the connection. Its reason: idle for too long', tip: null, printed: null));
      final broke = dropSaid(en, dropped(at('SSHSocketError(SocketException: Broken pipe)')), 'web-01');
      expect(broke.sentence, '$lead The network connection to vpn-gateway broke.');
      expect(broke.tip, isNotNull);
      expect(dropSaid(en, dropped(at('something nobody has words for')), 'web-01'),
          (sentence: '$lead The connection to vpn-gateway ended.', tip: null, printed: null));
    });

    test('a jump host whose key failed when new keys were taken: said as that, with its name, and no word of '
        'the host\'s key', () {
      final said = dropSaid(en, dropped(endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys)), 'web-01');
      expect(said, (sentence: '$lead ${en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')}', tip: null, printed: null));
      expect(said.sentence, contains('The jump host vpn-gateway asked for new keys'));
      expect(said.sentence, contains('see which key vpn-gateway shows now'));
      expect(said.sentence, isNot(contains(en.connHostKeyFailedAtNewKeys)));
      // The host's own key: as it was.
      expect(dropSaid(en, dropped(hostKeyFailedAtNewKeys), 'web-01'),
          (sentence: en.connHostKeyFailedAtNewKeys, tip: null, printed: null));
      expect(dropSaid(en, dropped(hostClosedConnection), 'web-01'),
          (sentence: 'web-01 closed the connection.', tip: null, printed: null));
    });

    test('the jump host\'s name is masked in recording mode, as a host\'s is', () {
      Redactor.instance.enabled = true;
      addTearDown(() => Redactor.instance.enabled = false);
      final masked = Redactor.instance.apply('vpn-gateway', RedactKind.host);
      expect(masked, isNot('vpn-gateway'));
      for (final reason in [hostClosedConnection, hostKeyFailedAtNewKeys, hostStoppedAnswering]) {
        final said = dropSaid(en, dropped(endedAtJumpHost('vpn-gateway', reason)), 'host-07').sentence;
        expect(said, isNot(contains('vpn-gateway')), reason: reason);
        expect(said, contains(masked), reason: reason);
        expect(said, startsWith(en.connectionLostAtJumpHost('host-07', masked)));
      }
    });

    test('the kind a report names, and what acts on the reason', () {
      String at(String reason) => endedAtJumpHost('vpn-gateway', reason);
      expect(dropKind(at(hostClosedConnection)), 'jumpHost.closedByHost');
      expect(dropKind(at(hostStoppedAnswering)), 'jumpHost.stoppedAnswering');
      expect(dropKind(at(hostKeyFailedAtNewKeys)), 'jumpHost.hostKeyAtNewKeys');
      expect(dropKind(at(hostDataDamaged)), 'jumpHost.packetCheckFailed');
      expect(dropKind(at(endReasonOf(SSHDisconnectError(2, 'bye', authentic: true)))), 'jumpHost.endedByHost');
      expect(dropKind(at('SocketException: Broken pipe')), 'jumpHost.lost');
      // As they were.
      expect(dropKind(hostClosedConnection), 'closedByHost');
      expect(dropKind(hostKeyFailedAtNewKeys), 'hostKeyAtNewKeys');
      expect(dropKind(null), 'lost');
      // A phone keeps the session on screen for a key that failed, at the host or at a jump host, to be read.
      expect(staysToBeRead(dropped(at(hostKeyFailedAtNewKeys))), isTrue);
      expect(staysToBeRead(dropped(hostKeyFailedAtNewKeys)), isTrue);
      expect(staysToBeRead(dropped(at(hostClosedConnection))), isFalse);
      expect(staysToBeRead(dropped(at(hostDataDamaged))), isFalse);
    });

    test('every language has both sentences, with the names in them', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final led = l.connectionLostAtJumpHost('web-01', 'vpn-gateway');
        expect(led, contains('web-01'), reason: '$locale');
        expect(led, contains('vpn-gateway'), reason: '$locale');
        final keyFailed = l.connJumpHostKeyFailedAtNewKeys('vpn-gateway');
        expect('vpn-gateway'.allMatches(keyFailed), hasLength(2), reason: '$locale');
        if (locale.languageCode != 'en') {
          expect(led, isNot(en.connectionLostAtJumpHost('web-01', 'vpn-gateway')), reason: '$locale');
          expect(keyFailed, isNot(en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')), reason: '$locale');
        }
        final said = dropSaid(
            l, dropped(endedAtJumpHost('vpn-gateway', hostKeyFailedAtNewKeys)), 'web-01');
        expect(said.sentence, '$led $keyFailed', reason: '$locale');
      }
    });
  });

  group('a host behind a jump host, while it is being connected to', () {
    const lead = 'The connection to the jump host vpn-gateway ended while the host behind it was being connected to.';

    SshService service(
      ({SSHSocket way, PlayedJumpHost outer, PlayedJumpHost? inner, List<SSHClient> clients}) w, {
      String? password,
      void Function(String line)? onLog,
    }) =>
        SshService(
          host: host,
          port: port,
          username: user,
          password: password,
          keyPairs: password == null ? [key!] : null,
          keepAliveSeconds: 0,
          onHostKeyVerify: (_, _, _) async => true,
          onLog: onLog,
          tunnelSocket: w.way,
          jumpClients: w.clients,
          jumpLabels: const ['vpn-gateway'],
        );

    Future<Object?> failureOf(Future<void> connecting) =>
        connecting.then<Object?>((_) => null, onError: (Object e) => e).timeout(const Duration(seconds: 20));

    Future<void> closed(SSHClient client, String what) async {
      final clock = Stopwatch()..start();
      while (!client.isClosed) {
        if (clock.elapsed > const Duration(seconds: 5)) fail('$what is still open');
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    test('the host refuses the sign-in: the host\'s own failure, and the jump host\'s connection is closed with it',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      // A session, and the connection Server Monitor makes for itself.
      for (final shell in [true, false]) {
        final w = await theWay();
        final log = <String>[];
        final ssh = service(w, password: 'not-the-password', onLog: log.add);
        final failed = await failureOf(shell ? ssh.connect() : ssh.connectExec());
        expect(failed, isA<SSHAuthFailError>(), reason: 'shell: $shell');
        // Nobody holds the service of a connection that failed: what it came through is closed by itself.
        await closed(w.clients.single, 'the connection to the jump host');
        expect(endsOfJumpHosts(log), isEmpty, reason: 'it did not end by itself');
        expect(ssh.isConnected, isFalse);
        // And the service itself is closed: whoever listens to it is told that nothing more comes.
        expect(await ssh.connectionState.toList().timeout(const Duration(seconds: 2)), isEmpty,
            reason: 'shell: $shell');
      }
    });

    test('the jump host ends its connection and says why meanwhile: said of the jump host, with its words',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      for (final shell in [true, false]) {
        final w = await theWay();
        // Nothing comes back from the host: its sign-in waits.
        w.outer.quiet();
        final log = <String>[];
        final ssh = service(w, onLog: log.add);
        final connecting = failureOf(shell ? ssh.connect() : ssh.connectExec());
        await Future<void>.delayed(const Duration(milliseconds: 200));
        w.outer.server.send([
          SSH_Message_Disconnect(reasonCode: 2, description: 'idle for too long', languageTag: '').encode(),
        ]);
        w.outer.server.hangUp();
        final failed = await connecting;
        expect(failed, isA<JumpHostEndedOnTheWay>(), reason: 'shell: $shell');
        failed as JumpHostEndedOnTheWay;
        expect(failed.label, 'vpn-gateway');
        expect(failed.cause, isA<SSHDisconnectError>().having((e) => e.description, 'what it said', 'idle for too long'));
        expect(failed.during, isA<SSHAuthAbortError>(), reason: 'what the host\'s own connection saw of it');
        const said = '$lead vpn-gateway ended the connection. Its reason: idle for too long';
        expect(connectionFailureText(failed), saidByApp(said));
        final shown = ConnectionError.translate(connectionFailureText(failed), host: host, port: port);
        expect(shown.type, ConnectionErrorType.saidByApp);
        expect(shown.description, said);
        expect(reconnectCannotHelp(failed), isFalse, reason: 'the jump host may be there for the next try');
        expect(endsOfJumpHosts(log), hasLength(1));
        expect(endsOfJumpHosts(log).single, contains('idle for too long'));
      }
    });

    test('the connection to the jump host ends with nothing said meanwhile: the jump host closed it', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final w = await theWay();
      w.outer.quiet();
      final ssh = service(w);
      final connecting = failureOf(ssh.connect());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      w.outer.server.hangUp();
      final failed = await connecting;
      expect(failed, isA<JumpHostEndedOnTheWay>());
      failed as JumpHostEndedOnTheWay;
      expect(failed.cause, isNull);
      expect(connectionFailureText(failed), saidByApp('$lead vpn-gateway closed the connection.'));
      expect(reconnectCannotHelp(failed), isFalse);
      expect('$failed', contains('closed, with nothing said'));
      // What a report names it by, in a built app too.
      expect(failed.typeName, 'JumpHostEndedOnTheWay');
    });

    test('the jump host shows another key when it asks for new keys meanwhile: said as that, and not tried again '
        'by itself', () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final w = await theWay();
      w.outer.quiet();
      final ssh = service(w);
      final connecting = failureOf(ssh.connect());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      unawaited(w.outer.server.rekey(hostKey: PlayedHostKey.ed25519()).then((_) {}, onError: (Object _) {}));
      final failed = await connecting;
      expect(failed, isA<JumpHostEndedOnTheWay>());
      failed as JumpHostEndedOnTheWay;
      expect(failed.cause, isA<SSHHostkeyError>().having((e) => e.duringRekey, 'when new keys were taken', isTrue));
      expect(connectionFailureText(failed), saidByApp('$lead ${en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')}'));
      expect(reconnectCannotHelp(failed), isTrue);
      // Server Monitor holds such a host, and no timer tries it again.
      expect(monitorExecFailure(failed, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.endsTheSame);
    });

    test('signed in, and the jump host ends its connection as the session is asked for: said of the jump host',
        () async {
      if (!up) return markTestSkipped('no test sshd at $host:$port');
      final w = await theWay();
      final ssh = service(w, onLog: (line) {
        if (line.startsWith('ssh_auth: SSH_AUTH_SUCCESS')) w.outer.server.hangUp();
      });
      final failed = await failureOf(ssh.connect());
      expect(failed, isA<JumpHostEndedOnTheWay>());
      failed as JumpHostEndedOnTheWay;
      expect(failed.cause, isNull);
      expect(connectionFailureText(failed), saidByApp('$lead vpn-gateway closed the connection.'));
      expect(ssh.isConnected, isFalse);
    });

    test('what is said of it, in every language, and what Server Monitor makes of it', () {
      final during = SSHAuthAbortError('Connection closed before authentication');
      final away = JumpHostEndedOnTheWay(label: 'vpn-gateway', during: during);
      final noAnswer = JumpHostEndedOnTheWay(
          label: 'vpn-gateway', cause: SSHNoAnswerError(const Duration(seconds: 45), 3), during: during);
      final keyFailed = JumpHostEndedOnTheWay(
        label: 'vpn-gateway',
        cause: SSHHostkeyError('Host key changed during re-key', duringRekey: true),
        during: during,
      );
      expect(jumpHostEndedOnTheWayText(en, away), '$lead vpn-gateway closed the connection.');
      expect(jumpHostEndedOnTheWayText(en, noAnswer),
          '$lead vpn-gateway stopped answering, and the connection was given up.');
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        final led = l.jumpHostEndedOnTheWay('vpn-gateway');
        expect(led, contains('vpn-gateway'), reason: '$locale');
        if (locale.languageCode != 'en') expect(led, isNot(lead), reason: '$locale');
        expect(jumpHostEndedOnTheWayText(l, away), '$led ${l.connectionLostByHost('vpn-gateway')}', reason: '$locale');
        expect(jumpHostEndedOnTheWayText(l, keyFailed), '$led ${l.connJumpHostKeyFailedAtNewKeys('vpn-gateway')}',
            reason: '$locale');
      }
      // A host whose jump host went away was not reached, and is tried again by the timer.
      CantCheckReason filed(Object failedWith) => failedCheckReason(
          MonitorHostStatus(MonitorHostState.error, failedWith: failedWith, updatedAt: DateTime(2026, 10, 11, 12)));
      expect(filed(away), CantCheckReason.unreachable);
      expect(filed(noAnswer), CantCheckReason.unreachable);
      expect(monitorExecFailure(away, hostKeyNeedsReview: false).outcome, MonitorExecOutcome.error);
      expect(reconnectCannotHelp(away), isFalse);
      expect(reconnectCannotHelp(noAnswer), isFalse);
      // One whose jump host's key failed is a check that failed, with why, and is held.
      expect(filed(keyFailed), CantCheckReason.checkFailed);
      expect(reconnectCannotHelp(keyFailed), isTrue);
      expect(failedCheckSaid(keyFailed), '$lead ${en.connJumpHostKeyFailedAtNewKeys('vpn-gateway')}');
      // What the host's own connection failed with is not what decides it.
      expect(
          reconnectCannotHelp(JumpHostEndedOnTheWay(label: 'vpn-gateway', during: SSHAuthFailError('refused'))), isFalse);
    });
  });
}
