import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/session/screen_trust.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A remote screen (4.0) against real servers, on the path the app
/// takes (ActiveSessionsNotifier._createScreenShell): a ScreenShellService
/// over an SshService signed in with no terminal (connectForScreen), the
/// channel to the VNC server through it (direct-streamlocal to a socket,
/// direct-tcpip to an address), the Rust engine, and the certificate rule
/// over the known hosts (KnownHostsScreenTrust, ScreenRouteTrust).
///
/// Runs only when ZESTSSH_TEST_VNC_HOST names the WSL servers that
/// `wsl -d Ubuntu -u root bash tool/remote_screens_test_servers.sh start vencrypt`
/// starts (WSL's own address, `wsl hostname -I`, not 127.0.0.1), with the
/// test account's passwords from /etc/zestscreens/env in
/// ZESTSSH_TEST_VNC_SSH_PASSWORD (ZS_PASSWORD) and ZESTSSH_TEST_VNC_PASSWORD
/// (ZS_VNC_PASSWORD). Read them into the environment without printing them:
///
///   eval "$(wsl -d Ubuntu -u root cat /etc/zestscreens/env)"
///   ZESTSSH_TEST_VNC_HOST=$(wsl hostname -I | cut -d' ' -f1) \
///   ZESTSSH_TEST_VNC_SSH_PASSWORD="$ZS_PASSWORD" ZESTSSH_TEST_VNC_PASSWORD="$ZS_VNC_PASSWORD" \
///   flutter test test/native/vnc_integration_test.dart
///
/// Optional: ZESTSSH_TEST_VNC_USER (alex), ZESTSSH_TEST_VNC_SSH_PORT (2240),
/// ZESTSSH_TEST_VNC_PORT (15931), ZESTSSH_TEST_VNC_SOCKET
/// (/run/zestscreens/vnc.sock), ZESTSSH_TEST_VNC_TLS_PORT (15932), and
/// ZESTSSH_TEST_VNC_RESTART, a shell command that restarts the VNC server
/// (on Windows, by default, the script's restart-vnc through wsl; elsewhere
/// the restart test skips without it).
///
/// TigerVNC turns an address away for a while after 5 refused passwords
/// (BlacklistThreshold): the wrong password test sends one per run.
void main() {
  final env = Platform.environment;
  final host = env['ZESTSSH_TEST_VNC_HOST'];
  final user = env['ZESTSSH_TEST_VNC_USER'] ?? 'alex';
  final sshPassword = env['ZESTSSH_TEST_VNC_SSH_PASSWORD'];
  final vncPassword = env['ZESTSSH_TEST_VNC_PASSWORD'];
  final sshPort = int.tryParse(env['ZESTSSH_TEST_VNC_SSH_PORT'] ?? '') ?? 2240;
  final vncPort = int.tryParse(env['ZESTSSH_TEST_VNC_PORT'] ?? '') ?? 15931;
  final tlsPort = int.tryParse(env['ZESTSSH_TEST_VNC_TLS_PORT'] ?? '') ?? 15932;
  final socket = env['ZESTSSH_TEST_VNC_SOCKET'] ?? '/run/zestscreens/vnc.sock';
  final skip = host == null
      ? 'ZESTSSH_TEST_VNC_HOST is not set (tool/remote_screens_test_servers.sh)'
      : (sshPassword == null || vncPassword == null)
          ? 'ZESTSSH_TEST_VNC_SSH_PASSWORD and ZESTSSH_TEST_VNC_PASSWORD are not set'
          : null;
  final restartCommand = env['ZESTSSH_TEST_VNC_RESTART'];
  final Future<ProcessResult> Function()? restart = restartCommand != null
      ? () => Process.run(Platform.isWindows ? 'cmd' : 'sh', [Platform.isWindows ? '/c' : '-c', restartCommand])
      : Platform.isWindows
          ? () => Process.run('wsl', [
                ...['-d', 'Ubuntu', '-u', 'root', '--cd', Directory.current.path],
                ...['bash', 'tool/remote_screens_test_servers.sh', 'restart-vnc'],
              ])
          : null;

  late AppDatabase db;
  late KnownHostsService known;
  late List<String> log;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    known = KnownHostsService(db.knownHostsDao);
    log = [];
  });

  tearDown(() async {
    // Nothing a session said may hold a password.
    for (final line in log) {
      expect(line, isNot(contains(vncPassword!)), reason: 'the VNC password in the log');
      expect(line, isNot(contains(sshPassword!)), reason: 'the SSH password in the log');
    }
    await db.close();
  });

  SshService carrier() => SshService(
        host: host!,
        port: sshPort,
        username: user,
        password: sshPassword,
        onHostKeyVerify: (_, _, _) async => true,
        onLog: log.add,
      );

  // The certificate questions put to the person, and the answer given.
  var asked = <({String? previous, String sha256})>[];
  var answer = true;
  ScreenRouteTrust routeTrust(String screenHost, int screenPort, {String? viaScope}) {
    asked = [];
    return ScreenRouteTrust(
      KnownHostsScreenTrust(known, ({
        required host,
        required port,
        required certificate,
        viaScope,
        previous,
        previousTrustedAt,
        teamPin,
      }) async {
        asked.add((previous: previous, sha256: certificate.sha256));
        return answer;
      }, viaScope: viaScope),
      host: screenHost,
      port: screenPort,
    );
  }

  ScreenShellService through(ScreenTarget target,
          {String? password, ScreenPasswordAsker? askPassword, ScreenRouteTrust? trust}) =>
      ScreenShellService(
        target: target,
        trust: trust ?? routeTrust('localhost', vncPort, viaScope: screenViaScope(carrierHost: host, carrierPort: sshPort)),
        carrier: carrier(),
        carrierLabel: 'wsl-test',
        password: password ?? vncPassword,
        askPassword: askPassword,
        onLog: log.add,
      );

  /// The first picture: tiles covering the whole screen, with pixels in them.
  Future<ScreenFrame> firstFrame(ScreenSession s, {Duration within = const Duration(seconds: 10)}) async {
    final sw = Stopwatch()..start();
    while (sw.elapsed < within) {
      final f = s.takeFrame();
      if (f != null) return f;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('no picture within $within');
  }

  void expectWholeScreen(ScreenFrame f, int w, int h) {
    expect((f.width, f.height), (w, h));
    final area = f.tiles.fold<int>(0, (n, t) => n + t.width * t.height);
    expect(area, greaterThanOrEqualTo(w * h), reason: 'the first picture covers the screen');
    expect(f.tiles.every((t) => t.pixels.length == t.width * t.height * 4), isTrue);
    expect(f.tiles.any((t) => t.pixels.any((b) => b != 0)), isTrue, reason: 'not all black');
  }

  Future<void> ended(ScreenShellService shell) async {
    await shell.disconnect();
    expect(shell.session!.isClosed, isTrue);
    expect(shell.carrier!.isConnected, isFalse);
  }

  test('the Unix socket through SSH: VNC authentication, the whole screen, no port opened', () async {
    final shell = through(UnixSocketTarget(socket));
    final sw = Stopwatch()..start();
    await shell.connect();
    final connectMs = sw.elapsedMilliseconds;
    final info = shell.connectedInfo!;
    expect(info.security, 'VncAuth');
    expect((info.width, info.height), (1280, 800));
    expect(info.tls, isNull);
    expect(shell.isConnected, isTrue);
    expect(shell.isEncryptedSsh, isTrue);
    final frame = await firstFrame(shell.session!);
    final firstMs = sw.elapsedMilliseconds;
    expectWholeScreen(frame, 1280, 800);
    frame.free();
    expect(log, contains('ssh_session: Signed in to reach a remote screen: no terminal or shell is asked for'));
    expect(log, contains('screen: Opening the screen at unix:$socket'));
    expect(log.any((l) => l.startsWith('screen: Connected (VncAuth), 1280x800, through SSH')), isTrue, reason: '$log');
    await ended(shell);
    expect(shell.closedWith?.reason ?? ScreenCloseReason.local, ScreenCloseReason.local);
    // ignore: avoid_print
    print('vnc socket via ssh: connected in $connectMs ms, first picture at $firstMs ms');
  }, skip: skip);

  test('an address and port through SSH (direct-tcpip)', () async {
    final shell = through(TcpTarget('127.0.0.1', vncPort));
    final sw = Stopwatch()..start();
    await shell.connect();
    final connectMs = sw.elapsedMilliseconds;
    expect(shell.connectedInfo!.security, 'VncAuth');
    final frame = await firstFrame(shell.session!);
    expectWholeScreen(frame, 1280, 800);
    frame.free();
    expect(log, contains('screen: Opening the screen at 127.0.0.1:$vncPort'));
    await ended(shell);
    // ignore: avoid_print
    print('vnc tcp via ssh: connected in $connectMs ms, first picture at ${sw.elapsedMilliseconds} ms');
  }, skip: skip);

  test('no socket at the path (ZS-1806) and nothing at the port (ZS-1801) through SSH', () async {
    final missing = through(const UnixSocketTarget('/run/zestscreens/not-there.sock'));
    final e1 = await missing.connect().then<Object?>((_) => null, onError: (Object e) => e);
    expect(e1, isA<ScreenFailure>().having((f) => f.kind, 'kind', ScreenFailureKind.socketMissing));
    expect((e1 as ScreenFailure).code?.code, 'ZS-1806');
    expect(missing.carrier!.isConnected, isFalse, reason: 'the carrier is closed with the failure');

    final closed = through(const TcpTarget('127.0.0.1', 15999));
    final e2 = await closed.connect().then<Object?>((_) => null, onError: (Object e) => e);
    expect(e2, isA<ScreenFailure>().having((f) => f.kind, 'kind', ScreenFailureKind.nothingAnswers));
    expect((e2 as ScreenFailure).code?.code, 'ZS-1801');
  }, skip: skip);

  test('a wrong VNC password: ZS-1803 with nobody to ask; asked again, the right one connects', () async {
    final alone = through(UnixSocketTarget(socket), password: 'wrong-pw');
    final e = await alone.connect().then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<ScreenFailure>().having((f) => f.kind, 'kind', ScreenFailureKind.passwordRefused));
    expect((e as ScreenFailure).code?.code, 'ZS-1803');
    expect(e.reconnectCannotHelp, isTrue);
    expect(alone.carrier!.isConnected, isFalse);

    // No password saved: asked once, and the server takes it.
    final asks = <bool>[];
    var accepted = 0;
    final shell = ScreenShellService(
      target: UnixSocketTarget(socket),
      trust: routeTrust('localhost', 0),
      carrier: carrier(),
      askPassword: ({required again}) async {
        asks.add(again);
        return vncPassword!;
      },
      onPasswordAccepted: () async => accepted++,
      onLog: log.add,
    );
    await shell.connect();
    expect(asks, [false]);
    expect(accepted, 1);
    expect(log, contains('screen: The VNC server asks for its password'));
    await ended(shell);
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('VeNCrypt reached directly: the certificate asked about once, kept, then pinned; X509Vnc and X509Plain', () async {
    final target = DirectTlsTarget(host!, tlsPort);
    ScreenShellService direct({String? username, String? password}) => ScreenShellService(
          target: target,
          trust: routeTrust(host, tlsPort),
          username: username,
          password: password ?? vncPassword,
          onTlsConnected: (_) {},
          onLog: log.add,
        );

    // Unpinned: the engine stops at the certificate, the person is asked, it is kept, and the
    // second connection is pinned to exactly it.
    answer = true;
    final first = direct();
    await first.connect();
    expect(asked, hasLength(1));
    expect(asked.single.previous, isNull, reason: 'a first certificate');
    final pinned = await known.pinnedCertificate(host, tlsPort);
    expect(pinned, asked.single.sha256);
    final info = first.connectedInfo!;
    expect(info.security, 'VeNCrypt');
    expect(info.tls?['subtype'], 'X509Vnc');
    expect(info.tls?['cert_sha256'], pinned);
    expect(info.tls?['protocol'], isA<String>());
    expect((info.width, info.height), (1024, 768));
    final frame = await firstFrame(first.session!);
    expectWholeScreen(frame, 1024, 768);
    frame.free();
    expect(first.isEncryptedSsh, isFalse);
    await first.disconnect();
    expect(log.any((l) => l.startsWith('screen: Connected (VeNCrypt, TLS') && l.contains('certificate pinned')), isTrue,
        reason: '$log');

    // Pinned: no question.
    final again = direct();
    await again.connect();
    expect(asked, isEmpty);
    expect(again.connectedInfo!.tls?['cert_sha256'], pinned);
    await again.disconnect();

    // X509Plain: the account's name and password, inside TLS.
    final plain = direct(username: user, password: sshPassword);
    await plain.connect();
    expect(asked, isEmpty);
    expect(plain.connectedInfo!.tls?['subtype'], 'X509Plain');
    await plain.disconnect();
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('VeNCrypt: another certificate pinned is asked about loudly; a no stops before any password', () async {
    final target = DirectTlsTarget(host!, tlsPort);
    // A certificate kept before that is not the server's.
    await known.trustCertificate(host, tlsPort, sha256Hex: 'ab' * 32, der: const [1, 2, 3]);
    answer = false;
    final shell = ScreenShellService(
      target: target,
      trust: routeTrust(host, tlsPort),
      password: vncPassword,
      onLog: log.add,
    );
    final e = await shell.connect().then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<HostKeyNotAccepted>());
    expect(asked, hasLength(1));
    expect(asked.single.previous, isNotNull, reason: 'a changed certificate names the one kept');
    expect(await known.pinnedCertificate(host, tlsPort), 'ab' * 32, reason: 'a no keeps the old one');
    answer = true;
  }, skip: skip);

  test('VeNCrypt through SSH: the certificate is kept for that route only', () async {
    final via = screenViaScope(carrierHost: host, carrierPort: sshPort);
    answer = true;
    final shell = through(TcpTarget('127.0.0.1', tlsPort), trust: routeTrust('127.0.0.1', tlsPort, viaScope: via));
    await shell.connect();
    expect(asked, hasLength(1));
    expect(shell.connectedInfo!.security, 'VeNCrypt');
    expect(await known.pinnedCertificate('127.0.0.1', tlsPort, viaScope: via), asked.single.sha256);
    expect(await known.pinnedCertificate('127.0.0.1', tlsPort), isNull, reason: 'not for a direct route');
    await ended(shell);
  }, skip: skip);

  test('paused, the server sends nothing: zero bytes while the pointer moves; resumed, the picture comes again', () async {
    final shell = through(UnixSocketTarget(socket));
    await shell.connect();
    final s = shell.session!;
    (await firstFrame(s)).free();

    // xeyes follows the pointer: moving it draws, so updates flow while not paused.
    Future<void> wiggle(Duration d) async {
      final sw = Stopwatch()..start();
      var i = 0;
      while (sw.elapsed < d) {
        s.pointer(200 + (i * 37) % 900, 100 + (i * 53) % 600, 0);
        i++;
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
    }

    var before = s.bytesIn;
    await wiggle(const Duration(seconds: 2));
    final live = s.bytesIn - before;
    expect(live, greaterThan(0), reason: 'the pointer moving draws (xeyes)');

    final infos = <Map<String, Object?>>[];
    final sub = s.events.listen((e) {
      if (e is ScreenInfo) infos.add(e.info);
    });
    s.pause();
    // What was on its way when the pause went out arrives, then nothing.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    for (var f = s.takeFrame(); f != null; f = s.takeFrame()) {
      f.free();
    }
    before = s.bytesIn;
    final outBefore = s.bytesOut;
    await wiggle(const Duration(seconds: 3));
    final paused = s.bytesIn - before;
    expect(paused, 0, reason: 'nothing from the server while paused');
    expect(s.bytesOut, greaterThan(outBefore), reason: 'input still goes');
    expect(infos.any((i) => i['paused'] == true), isTrue, reason: '$infos');

    s.resume();
    final f = await firstFrame(s, within: const Duration(seconds: 5));
    expect(f.width, 1280);
    f.free();
    expect(s.bytesIn, greaterThan(before));
    await sub.cancel();
    await ended(shell);
    // ignore: avoid_print
    print('pause: $live bytes in over 2 s live, $paused bytes in over 3 s paused');
  }, skip: skip, timeout: const Timeout(Duration(minutes: 1)));

  test('the server restarted under the viewer: server_closed, not a drop; connecting again works', () async {
    final shell = through(UnixSocketTarget(socket));
    await shell.connect();
    (await firstFrame(shell.session!)).free();
    final states = <bool>[];
    final sub = shell.connectionState.listen(states.add);

    final r = await restart!();
    expect(r.exitCode, 0, reason: '${r.stdout}${r.stderr}');

    final why = await shell.endReason.timeout(const Duration(seconds: 15));
    expect(why, isNull, reason: 'the server ending it is no drop');
    expect(shell.closedWith?.reason, ScreenCloseReason.serverClosed, reason: shell.closedWith?.message);
    expect(shell.exitedCleanly, isTrue, reason: 'not connected again by itself');
    expect(shell.isConnected, isFalse);
    // The state stream is delivered on its own turn, which may come after endReason's.
    for (var i = 0; i < 20 && states.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(states, [false]);
    expect(log.any((l) => l.startsWith('screen: Ended (serverClosed')), isTrue, reason: '$log');
    // The carrier goes with it.
    for (var i = 0; i < 50 && shell.carrier!.isConnected; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(shell.carrier!.isConnected, isFalse);
    await sub.cancel();

    // The server is back: Reconnect connects.
    final again = through(UnixSocketTarget(socket));
    await again.connect();
    (await firstFrame(again.session!)).free();
    await ended(again);
  }, skip: skip ?? (restart == null ? 'ZESTSSH_TEST_VNC_RESTART is not set' : null),
      timeout: const Timeout(Duration(minutes: 1)));
}
