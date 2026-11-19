// The screen session's Dart side over a fake engine: the request it starts with, feeding and the
// high mark, how it ends (close reasons, the channel's end, the connection's error), the
// certificate pass of connectTrusting, the clipboard, pause and resume, frames and the cursor.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';

/// A channel the test plays the server's side of.
class FakeChannel {
  final input = StreamController<Uint8List>();
  final output = StreamController<List<int>>();
  final written = <int>[];
  final done = Completer<void>();
  late final StreamSubscription<List<int>> _sub = output.stream.listen(written.addAll);

  ScreenChannel channel({bool withConnection = true}) {
    _sub;
    return ScreenChannel(input.stream, output.sink, connectionDone: withConnection ? done.future : null);
  }
}

/// Lets scheduled events and stream callbacks run.
Future<void> settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

class FakeTrust implements ScreenTrust {
  FakeTrust({this.pin, this.answer = true});
  String? pin;
  bool answer;
  final asked = <(ScreenCertificate, String?)>[];
  final remembered = <ScreenCertificate>[];

  @override
  Future<String?> pinned() async => pin;

  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async {
    asked.add((presented, previous));
    return answer;
  }

  @override
  Future<void> remember(ScreenCertificate cert) async {
    remembered.add(cert);
    pin = cert.sha256;
  }
}

const sha = 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12';

Map<String, Object?> certificateClosed({String sha256 = sha}) => {
  'sha256': sha256,
  'der': base64.encode([0x30, 0x03, 0x02, 0x01, 0x01]),
  'subject': 'CN=vnc.example.test',
  'not_before': 1794086665,
  'not_after': 4950000000,
};

void main() {
  group('options', () {
    test('the request carries what the engine reads, and toString never the password', () {
      const o = ScreenConnectOptions.vnc(password: 'hunter2', username: 'me', tlsPin: sha, shared: false, tileSize: 128);
      expect(o.toRequest(), {
        'kind': 'vnc',
        'username': 'me',
        'password': 'hunter2',
        'tls_pin': sha,
        'require_tls': false,
        'shared': false,
        'tile_size': 128,
      });
      expect(o.toString(), isNot(contains('hunter2')));
      expect(o.toString(), contains('password: set'));
      expect(const ScreenConnectOptions.vnc().toString(), contains('password: none'));
      expect(const ScreenConnectOptions.vnc().toRequest().containsKey('password'), isFalse);
    });

    test("an RDP session's gateway goes in the request, its password never in toString", () {
      const o = ScreenConnectOptions.rdp(
        username: 'alex',
        password: 'pc-password',
        tlsPin: sha,
        gateway: ScreenGatewayOptions(
          host: 'rdg.example.test',
          target: 'pc1.example.test',
          targetPort: 3390,
          username: 'gw-account',
          password: 'gateway-password',
          domain: 'EXAMPLE',
        ),
      );
      expect(o.toRequest()['rdp_gateway'], {
        'host': 'rdg.example.test',
        'port': 443,
        'username': 'gw-account',
        'password': 'gateway-password',
        'domain': 'EXAMPLE',
        'target': 'pc1.example.test',
        'target_port': 3390,
      });
      expect(o.toString(), contains('gateway: ScreenGatewayOptions(rdg.example.test:443 to pc1.example.test:3390'));
      expect(o.toString(), isNot(contains('gateway-password')));
      expect(o.toString(), isNot(contains('pc-password')));
      final pinned = o.copyWith(gatewayPin: 'ef56');
      expect((pinned.toRequest()['rdp_gateway'] as Map)['tls_pin'], 'ef56');
      expect(pinned.toRequest()['tls_pin'], sha, reason: "the PC's pin stays");
      expect(const ScreenConnectOptions.rdp().toRequest().containsKey('rdp_gateway'), isFalse);
    });

    test('an engine that refuses the request (no engine in this build) throws', () {
      expect(
        () => ScreenSession.open(const ScreenConnectOptions.vnc(), native: FakeScreenNative(refuse: true)),
        throwsArgumentError,
      );
    });
  });

  group('feeding', () {
    test('bytes go to the engine in order; above the high mark the channel pauses until DRAINED', () async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      final s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      final c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone);
      final f = native.sessions.single;
      ch.input.add(Uint8List.fromList([1, 2]));
      ch.input.add(Uint8List.fromList([3]));
      await settle();
      expect(f.fed.toBytes(), [1, 2, 3]);
      expect(s.bytesIn, 3);

      f.queued = ScreenSession.feedHighMark + 1;
      ch.input.add(Uint8List.fromList([4]));
      await settle();
      expect(ch.input.isPaused, isTrue);
      ch.input.add(Uint8List.fromList([5]));
      await settle();
      expect(f.fed.toBytes(), [1, 2, 3, 4], reason: 'nothing read while paused');

      f.queued = 0;
      f.emit(ScreenEventKind.drained, a: 1 << 20);
      await settle();
      expect(ch.input.isPaused, isFalse);
      expect(f.fed.toBytes(), [1, 2, 3, 4, 5]);

      // What the engine writes goes to the channel.
      f.send([9, 8, 7]);
      await settle();
      expect(ch.written, [9, 8, 7]);
      expect(s.bytesOut, 3);
      s.close();
    });
  });

  group('the end', () {
    test('close reasons and messages come from CLOSED, and connected fails when it ends first', () async {
      for (final (reason, want) in [
        ('server_closed', ScreenCloseReason.serverClosed),
        ('ssh', ScreenCloseReason.ssh),
        ('network', ScreenCloseReason.network),
        ('auth', ScreenCloseReason.auth),
        ('tls', ScreenCloseReason.tls),
        ('protocol', ScreenCloseReason.protocol),
        ('internal', ScreenCloseReason.internal),
        ('something new', ScreenCloseReason.internal),
      ]) {
        final native = FakeScreenNative();
        final s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
        final events = <ScreenEvent>[];
        s.events.listen(events.add);
        final connected = s.connected;
        native.sessions.single.closeWith(reason, 'why: $reason');
        await expectLater(
          connected,
          throwsA(isA<ScreenConnectException>().having((e) => e.reason, 'reason', want)),
        );
        final closed = events.whereType<ScreenClosed>().single;
        expect(closed.reason, want);
        expect(closed.error, 'why: $reason');
        expect(s.isClosed, isTrue);
        expect(s.closedWith, closed);
        expect(native.sessions.single.closed, isTrue, reason: 'the thread joined');
        expect(native.sessions.single.released, isTrue, reason: 'the callback released after CLOSED');
        expect(want.isDrop, reason == 'ssh' || reason == 'network');
      }
    });

    test('closing it ends with local, joins, and releases the callback only once CLOSED came', () async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      final s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      final c = ch.channel();
      s.attach(c.input, c.output);
      final events = <ScreenEvent>[];
      s.events.listen(events.add);
      final f = native.sessions.single..connect();
      await settle();
      expect(s.state, ScreenSessionState.connected);
      s.close();
      expect(events.last, isA<ScreenClosed>().having((e) => e.reason, 'reason', ScreenCloseReason.local));
      expect((events.last as ScreenClosed).error, isNull);
      expect(f.closed, isTrue);
      expect(f.released, isFalse);
      await settle();
      expect(f.released, isTrue);
      expect(ch.output.isClosed, isTrue);
      // Calls after the end are ignored.
      s
        ..pointer(1, 1, 1)
        ..key(0x61, down: true)
        ..sendClipboard('x')
        ..close();
      expect(f.pointers, isEmpty);
      expect(f.keys, isEmpty);
      expect(f.clipboard, isEmpty);
      expect(events.whereType<ScreenClosed>(), hasLength(1));
    });

    test('a channel error is the reason: a socket error is the network, the rest SSH', () async {
      for (final (error, network) in [
        (const SocketException('reset'), true),
        (TimeoutException('quiet'), true),
        (StateError('channel gone'), false),
      ]) {
        final native = FakeScreenNative();
        final ch = FakeChannel();
        final s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
        final c = ch.channel();
        s.attach(c.input, c.output, connectionDone: c.connectionDone);
        ch.input.addError(error);
        await settle();
        expect(native.sessions.single.failed?.network, network, reason: '$error');
        s.close();
      }
    });

    test("a clean channel end is the server's, unless the connection fails or closes with it", () async {
      // Clean, the connection still up: the server closed it.
      var native = FakeScreenNative();
      var ch = FakeChannel();
      var s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      var c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone, settle: const Duration(milliseconds: 30));
      await ch.input.close();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(native.sessions.single.ended, isTrue);
      expect(native.sessions.single.failed, isNull);
      s.close();

      // The connection fails just after the channel's end: that is the reason.
      native = FakeScreenNative();
      ch = FakeChannel();
      s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone, settle: const Duration(milliseconds: 200));
      await ch.input.close();
      ch.done.completeError(const SocketException('Software caused connection abort'));
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(native.sessions.single.ended, isFalse);
      expect(native.sessions.single.failed?.network, isTrue);
      expect(native.sessions.single.failed?.message, contains('connection abort'));
      s.close();

      // The connection closes with it: SSH.
      native = FakeScreenNative();
      ch = FakeChannel();
      s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone, settle: const Duration(milliseconds: 200));
      ch.done.complete();
      await ch.input.close();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(native.sessions.single.failed, (network: false, message: 'the SSH connection closed'));
      s.close();
    });
  });

  group('the certificate', () {
    test("CLOSED's certificate is read whole", () {
      final closed = ScreenClosed.fromJson({'reason': 'certificate', 'message': 'not trusted', ...certificateClosed()});
      final cert = closed.certificate!;
      expect(closed.sha256, sha);
      expect(cert.der, [0x30, 0x03, 0x02, 0x01, 0x01]);
      expect(cert.subject, 'CN=vnc.example.test');
      expect(cert.notBefore, DateTime.utc(2026, 11, 7, 21, 24, 25));
      expect(cert.notAfter!.year, 2126);
      expect(cert.fingerprint, startsWith('AB:12:AB:12:'));
      expect(cert.fingerprint.split(':'), hasLength(32));
      expect(ScreenClosed.fromJson({'reason': 'auth', 'message': 'no'}).certificate, isNull);
    });

    test('connectTrusting: pinned and shown connects at once, nothing asked', () async {
      final native = FakeScreenNative()..onOpen = (s) => s.connect(security: 'VeNCrypt');
      final trust = FakeTrust(pin: sha);
      final s = await ScreenSession.connectTrusting(
        const ScreenConnectOptions.vnc(password: 'p'),
        openChannel: () async => FakeChannel().channel(),
        trust: trust,
        native: native,
      );
      expect(s.state, ScreenSessionState.connected);
      expect(native.sessions.single.request['tls_pin'], sha);
      expect(trust.asked, isEmpty);
      s.close();
    });

    test('connectTrusting: a first certificate is asked about, kept on yes, and the connection made again pinned', () async {
      final native = FakeScreenNative()
        ..onOpen = (s) {
          if (s.request['tls_pin'] == sha) {
            s.connect(security: 'VeNCrypt');
          } else {
            s.closeWith('certificate', 'certificate not trusted: SHA-256 $sha', extra: certificateClosed());
          }
        };
      final trust = FakeTrust();
      var channels = 0;
      final s = await ScreenSession.connectTrusting(
        const ScreenConnectOptions.vnc(password: 'p'),
        openChannel: () async {
          channels++;
          return FakeChannel().channel();
        },
        trust: trust,
        native: native,
      );
      expect(s.state, ScreenSessionState.connected);
      expect(channels, 2);
      expect(native.sessions.map((x) => x.request['tls_pin']), [null, sha]);
      expect(trust.asked.single.$1.sha256, sha);
      expect(trust.asked.single.$2, isNull);
      expect(trust.remembered.single.subject, 'CN=vnc.example.test');
      s.close();
    });

    test('connectTrusting: a changed certificate is asked about with the old one; a no stops it, nothing kept', () async {
      const old = 'cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34cd34';
      final native = FakeScreenNative()
        ..onOpen = (s) => s.closeWith('certificate', 'certificate not trusted', extra: certificateClosed());
      final trust = FakeTrust(pin: old, answer: false);
      await expectLater(
        ScreenSession.connectTrusting(
          const ScreenConnectOptions.vnc(),
          openChannel: () async => FakeChannel().channel(),
          trust: trust,
          native: native,
        ),
        throwsA(isA<ScreenConnectException>().having((e) => e.reason, 'reason', ScreenCloseReason.certificate)),
      );
      expect(trust.asked.single.$2, old);
      expect(trust.remembered, isEmpty);
      expect(native.sessions, hasLength(1));
    });

    // RD Gateway (4.0): two certificates, each with its own question and its own pin.
    test('connectTrusting through a gateway: its certificate asked of its trust, then the PC\'s of the PC\'s, each '
        'once and kept apart', () async {
      const gwSha = 'ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56';
      final native = FakeScreenNative()
        ..onOpen = (s) {
          final gw = s.request['rdp_gateway'] as Map;
          if (gw['tls_pin'] != gwSha) {
            s.closeWith('certificate', 'certificate not trusted', extra: {...certificateClosed(sha256: gwSha), 'detail': 'gateway'});
          } else if (s.request['tls_pin'] != sha) {
            s.closeWith('certificate', 'certificate not trusted', extra: certificateClosed());
          } else {
            s.connect(security: 'TLS');
          }
        };
      final trust = FakeTrust();
      final gatewayTrust = FakeTrust();
      final s = await ScreenSession.connectTrusting(
        const ScreenConnectOptions.rdp(
          username: 'alex',
          password: 'p',
          gateway: ScreenGatewayOptions(host: 'rdg.example.test', target: 'pc1.example.test', username: 'alex', password: 'p'),
        ),
        openChannel: () async => FakeChannel().channel(),
        trust: trust,
        gatewayTrust: gatewayTrust,
        native: native,
      );
      expect(s.state, ScreenSessionState.connected);
      expect(gatewayTrust.asked.single.$1.sha256, gwSha);
      expect(trust.asked.single.$1.sha256, sha);
      expect(gatewayTrust.pin, gwSha);
      expect(trust.pin, sha);
      expect(native.sessions.map((x) => ((x.request['rdp_gateway'] as Map)['tls_pin'], x.request['tls_pin'])),
          [(null, null), (gwSha, null), (gwSha, sha)]);
      s.close();
    });

    test('connectTrusting through a gateway: no gateway trust, no question; a gateway certificate asked about twice '
        'is not asked again', () async {
      final native = FakeScreenNative()
        ..onOpen = (s) => s.closeWith('certificate', 'certificate not trusted', extra: {...certificateClosed(), 'detail': 'gateway'});
      const options = ScreenConnectOptions.rdp(gateway: ScreenGatewayOptions(host: 'rdg.example.test', target: 'pc1'));
      final trust = FakeTrust();
      await expectLater(
        ScreenSession.connectTrusting(options, openChannel: () async => FakeChannel().channel(), trust: trust, native: native),
        throwsA(isA<ScreenConnectException>()),
      );
      expect(trust.asked, isEmpty, reason: "the PC's trust is never asked about the gateway's certificate");
      final gatewayTrust = FakeTrust();
      await expectLater(
        ScreenSession.connectTrusting(options,
            openChannel: () async => FakeChannel().channel(), trust: trust, gatewayTrust: gatewayTrust, native: native),
        throwsA(isA<ScreenConnectException>()),
      );
      expect(gatewayTrust.asked, hasLength(1));
    });

    test('connectTrusting: a server that never finishes the handshake is closed at the deadline, its engine and '
        'channel with it', () async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      final trust = FakeTrust();
      final failed = ScreenSession.connectTrusting(
        const ScreenConnectOptions.rdp(),
        openChannel: () async => ch.channel(),
        trust: trust,
        native: native,
        handshakeTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        failed,
        throwsA(isA<ScreenConnectException>()
            .having((e) => e.reason, 'reason', ScreenCloseReason.network)
            .having((e) => e.closed.detail, 'detail', ScreenSession.handshakeTimedOut)),
      );
      expect(native.sessions.single.closed, isTrue, reason: 'the engine stops');
      expect(ch.output.isClosed, isTrue, reason: 'the channel closes');
      expect(trust.asked, isEmpty);
    });

    test('connectTrusting: the session is handed over as it opens, and closing it then ends the try at once', () async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      ScreenSession? opened;
      final failed = ScreenSession.connectTrusting(
        const ScreenConnectOptions.rdp(),
        openChannel: () async => ch.channel(),
        trust: FakeTrust(),
        native: native,
        handshakeTimeout: const Duration(minutes: 1),
        onSession: (s) => opened = s,
      );
      await settle();
      expect(opened, isNotNull);
      expect(opened!.state, isNot(ScreenSessionState.connected));
      opened!.close();
      await expectLater(
          failed, throwsA(isA<ScreenConnectException>().having((e) => e.reason, 'reason', ScreenCloseReason.local)));
      expect(native.sessions.single.closed, isTrue);
      expect(ch.output.isClosed, isTrue);
    });

    test('connectTrusting: other failures are not asked about', () async {
      final native = FakeScreenNative()..onOpen = (s) => s.closeWith('auth', 'the server refused the password');
      final trust = FakeTrust();
      await expectLater(
        ScreenSession.connectTrusting(
          const ScreenConnectOptions.vnc(password: 'wrong'),
          openChannel: () async => FakeChannel().channel(),
          trust: trust,
          native: native,
        ),
        throwsA(isA<ScreenConnectException>().having((e) => e.reason, 'reason', ScreenCloseReason.auth)),
      );
      expect(trust.asked, isEmpty);
    });
  });

  group('the session', () {
    late FakeScreenNative native;
    late ScreenSession s;
    late FakeScreenSession f;
    late List<ScreenEvent> events;

    setUp(() async {
      native = FakeScreenNative();
      s = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      events = [];
      s.events.listen(events.add);
      f = native.sessions.single..connect(name: 'desk', width: 1920, height: 1080);
      await s.connected;
    });

    tearDown(() => s.close());

    test('connected says the desktop', () {
      final c = events.whereType<ScreenConnected>().single;
      expect((c.name, c.width, c.height, c.security), ('desk', 1920, 1080, 'None'));
    });

    test('clipboard both ways, never in toString', () async {
      s.sendClipboard('café');
      expect(f.clipboard, ['café']);
      f.emit(ScreenEventKind.clipboard, data: utf8.encode('from the server'));
      await settle();
      final clip = events.whereType<ScreenClipboard>().single;
      expect(clip.text, 'from the server');
      expect(clip.toString(), isNot(contains('server')));
    });

    test('pause and resume go once each, input still goes while paused', () {
      s
        ..pause()
        ..pause();
      expect(s.isPaused, isTrue);
      s.key(0x61, down: true, scancode: 0x1e);
      s
        ..resume()
        ..resume();
      expect((f.pauses, f.resumes), (1, 1));
      expect(f.keys, [(0x61, 0x1e, true)]);
      expect(s.isPaused, isFalse);
    });

    test('pointer, resize and refresh pass through, negatives clamped', () {
      s
        ..pointer(-5, 7, 0x101)
        ..resize(0, 10)
        ..resize(800, 600)
        ..fullRefresh();
      expect(f.pointers, [(0, 7, 0x01)]);
      expect(f.resizes, [(800, 600)]);
      expect(f.fullRefreshes, 1);
    });

    test('frames, resizes, bell, info and the cursor arrive as events', () async {
      final frame = ScreenFrame(
        seq: 3,
        width: 4,
        height: 2,
        updates: 1,
        tiles: [ScreenTile(0, 0, 1, 1, Uint8List.fromList([1, 2, 3, 255]))],
      );
      f.frames.add(frame);
      f.emit(ScreenEventKind.frame, a: 3);
      f.emit(ScreenEventKind.resize, a: (1024 << 32) | 768);
      f.emit(ScreenEventKind.bell);
      f.emitJson(ScreenEventKind.info, {'continuous_updates': true});
      final cursor = BytesBuilder()
        ..add([2, 0, 1, 0, 1, 0, 0, 0])
        ..add([10, 20, 30, 255, 40, 50, 60, 0]);
      f.emit(ScreenEventKind.cursor, data: cursor.toBytes());
      f.emit(ScreenEventKind.cursor, data: Uint8List.fromList([5, 0, 5, 0, 0, 0, 0, 0, 1]));
      await settle();
      expect(events.whereType<ScreenFrameReady>().single.seq, 3);
      final taken = s.takeFrame()!;
      expect(taken.tiles.single.pixels, [1, 2, 3, 255]);
      expect(taken.bytes, 4);
      taken.free();
      expect(taken.isFreed, isTrue);
      expect(s.takeFrame(), isNull);
      final r = events.whereType<ScreenResized>().single;
      expect((r.width, r.height), (1024, 768));
      expect(events.whereType<ScreenBell>(), hasLength(1));
      expect(events.whereType<ScreenInfo>().single.info, {'continuous_updates': true});
      final cursors = events.whereType<ScreenCursor>().toList();
      expect((cursors[0].width, cursors[0].height, cursors[0].hotX, cursors[0].hotY), (2, 1, 1, 0));
      expect(cursors[0].rgba, [10, 20, 30, 255, 40, 50, 60, 0]);
      expect(cursors[1].hidden, isTrue, reason: 'pixels that do not match the size are not drawn');
    });
  });

  // From a security review: what the server chose reaches the app's words and its log.
  group("the server's words", () {
    test('control characters become spaces, hiding and bidirectional marks go, runs of spaces are one', () {
      expect(screenServerText('  desk\u0000top\t\u001b[31mred\u007f\u0085 '), 'desk top [31mred');
      expect(screenServerText('evil\u202egnp.exe\u200b\u2066x\ufeff'), 'evilgnp.exex');
      expect(screenServerText('Ubuntu Desktop :1'), 'Ubuntu Desktop :1', reason: 'what is fine stays');
      expect(screenServerText('x' * 201), '${'x' * 197}...');
      expect(screenServerText('x' * 200), 'x' * 200);
      expect(screenServerText('\u{1F600}' * 5, max: 4), '\u{1F600}...', reason: 'whole characters, never half of one');
    });

    test("the desktop's name, a closed session's message and a certificate's subject come through it", () {
      final connected = ScreenConnected({'name': 'desk\u202e\n${'n' * 300}', 'width': 1, 'height': 1});
      expect(connected.name, allOf(startsWith('desk n'), hasLength(200)));
      final closed = ScreenClosed.fromJson({
        'reason': 'auth',
        'message': 'the server refused the sign-in: \u001b[2Jfake ZS-0000\r\n${'r' * 600}',
        'sha256': 'ab',
        'subject': 'CN=\u202ehost\u0000',
      });
      expect(closed.message, allOf(startsWith('the server refused the sign-in: [2Jfake ZS-0000 r'), hasLength(400)));
      expect(closed.certificate!.subject, 'CN=host');
    });
  });

  // From a security review: the engine picks Apple Remote Desktop (type 30) by itself
  // whenever it has a user name and a password, and ARD gives the server both.
  group("Apple's sign-in", () {
    final greeting38 = ascii.encode('RFB 003.008\n');

    /// What the engine was fed once [chunks] came from the server, one by one.
    Future<List<int>> fedAfter(List<List<int>> chunks, {bool apple = false}) async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      final s = ScreenSession.open(
        ScreenConnectOptions.vnc(username: 'me', password: 'secret', allowAppleSignIn: apple),
        native: native,
      );
      final c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone);
      for (final chunk in chunks) {
        ch.input.add(Uint8List.fromList(chunk));
        await settle();
      }
      final fed = native.sessions.single.fed.toBytes();
      s.close();
      return fed;
    }

    test('is taken out of the offer unless the host chose it; the rest passes as it came', () async {
      // RFB 3.8 offering ARD and VNC authentication: the engine sees VNC authentication alone.
      expect(await fedAfter([greeting38, [2, 30, 2]]), [...greeting38, 1, 2]);
      // In the server's order, ARD anywhere in it, other types kept.
      expect(await fedAfter([greeting38, [3, 2, 30, 19, 0, 0]]), [...greeting38, 2, 2, 19, 0, 0]);
      // The host chose Apple's sign-in: nothing changed.
      expect(await fedAfter([greeting38, [2, 30, 2]], apple: true), [...greeting38, 2, 30, 2]);
      // No ARD: as it came.
      expect(await fedAfter([greeting38, [2, 19, 2, 1, 2, 3]]), [...greeting38, 2, 19, 2, 1, 2, 3]);
    });

    test('the greeting goes at once; only the offer waits until it is whole, byte by byte too', () async {
      final native = FakeScreenNative();
      final ch = FakeChannel();
      final s = ScreenSession.open(const ScreenConnectOptions.vnc(username: 'me', password: 'secret'), native: native);
      final c = ch.channel();
      s.attach(c.input, c.output, connectionDone: c.connectionDone);
      final f = native.sessions.single;
      for (final b in [...ascii.encode('RFB 003.007\n'), 3, 30, 2]) {
        ch.input.add(Uint8List.fromList([b]));
        await settle();
      }
      expect(f.fed.toBytes(), ascii.encode('RFB 003.007\n'), reason: 'the count and two types of three held');
      ch.input.add(Uint8List.fromList([1, 0, 0, 0, 0]));
      await settle();
      expect(f.fed.toBytes(), [...ascii.encode('RFB 003.007\n'), 2, 2, 1, 0, 0, 0, 0]);
      ch.input.add(Uint8List.fromList([7, 7]));
      await settle();
      expect(f.fed.toBytes().sublist(f.fed.length - 2), [7, 7], reason: 'after the offer, everything as it came');
      expect(s.bytesIn, 12 + 3 + 5 + 2);
      s.close();
    });

    test('a server that offers ARD alone is answered as one that offers nothing, and heard no more', () async {
      final fed = await fedAfter([greeting38, [1, 30], [0, 0, 0, 0, 1, 2, 3]]);
      expect(fed.sublist(0, 13), [...greeting38, 0], reason: 'no type: a reason follows');
      final length = ByteData.sublistView(Uint8List.fromList(fed), 13, 17).getUint32(0);
      expect(utf8.decode(fed.sublist(17)), VncSecurityOfferFilter.appleOnlyReason);
      expect(fed.length, 17 + length, reason: "nothing the server sent after its offer reached the engine");
      expect(VncSecurityOfferFilter.appleOnlyReason, contains('Apple Remote Desktop'));
    });

    test('RFB 3.3 (the server picks), a refusal with no type, and Apple-like greetings', () async {
      // 3.3: the server's U32 type, passed as it is (the engine takes only None and VNC auth there).
      final g33 = ascii.encode('RFB 003.003\n');
      expect(await fedAfter([g33, [0, 0, 0, 30]]), [...g33, 0, 0, 0, 30]);
      // A count of 0: the server's reason, for the engine.
      expect(await fedAfter([greeting38, [0, 0, 0, 0, 2, 104, 105]]), [...greeting38, 0, 0, 0, 0, 2, 104, 105]);
      // Apple's own version string (3.889) is read as 3.8, as the engine reads it.
      final apple = ascii.encode('RFB 003.889\n');
      expect(await fedAfter([apple, [2, 30, 2]]), [...apple, 1, 2]);
    });

    test('options: off unless asked, never in the engine\'s request, said by toString', () {
      const plain = ScreenConnectOptions.vnc(username: 'me', password: 'pw');
      expect(plain.allowAppleSignIn, isFalse);
      const apple = ScreenConnectOptions.vnc(username: 'me', password: 'pw', allowAppleSignIn: true);
      expect(apple.copyWith(tlsPin: 'ab').allowAppleSignIn, isTrue);
      expect(apple.toRequest().keys, isNot(contains(contains('apple'))));
      expect('$apple', contains('apple: true'));
      expect('$apple', isNot(contains('pw')));
    });
  });
}
