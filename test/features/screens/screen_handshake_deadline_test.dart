// A remote screen's server that takes the connection and then says nothing
// (or stops half way): the connection is closed at the handshake deadline
// with ZS-1828, not waited on for ever; and a Disconnect while it is still
// connecting closes it at once, the engine and the socket with it. Played
// against a real socket on this device that accepts and never answers.
import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

class _Trust implements ScreenTrust {
  @override
  Future<String?> pinned() async => null;

  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => false;

  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

void main() {
  late ServerSocket server;
  late List<Socket> accepted;
  late List<Completer<void>> ended;

  setUp(() async {
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    accepted = [];
    ended = [];
    // Takes every connection and never says a word; notes when this device closed it.
    server.listen((s) {
      accepted.add(s);
      final end = Completer<void>();
      ended.add(end);
      s.listen((_) {}, onDone: () {
        if (!end.isCompleted) end.complete();
        s.destroy();
      }, onError: (Object _) {
        if (!end.isCompleted) end.complete();
      });
    });
  });

  tearDown(() async {
    for (final s in accepted) {
      s.destroy();
    }
    await server.close();
  });

  ScreenShellService shell(FakeScreenNative engine, {Duration deadline = kScreenHandshakeTimeout}) => ScreenShellService(
        target: DirectTlsTarget('127.0.0.1', server.port),
        trust: _Trust(),
        protocol: ScreenProtocol.rdp,
        username: 'me',
        password: 'account-password',
        native: engine,
        handshakeTimeout: deadline,
        openDirect: (host, port) => openDirectScreenSocket(host, port, const Duration(seconds: 5)),
      );

  Future<void> until(bool Function() done) async {
    final stop = DateTime.now().add(const Duration(seconds: 5));
    while (!done() && DateTime.now().isBefore(stop)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  test('a server that takes the connection and says nothing: closed at the deadline, with ZS-1828, its engine and '
      'socket with it', () async {
    // The engine never connects: it waits for the server, which never answers.
    final engine = FakeScreenNative();
    final started = DateTime.now();
    Object? failed;
    try {
      await shell(engine, deadline: const Duration(milliseconds: 300)).connect();
    } catch (e) {
      failed = e;
    }
    expect(failed, isA<ScreenFailure>().having((e) => e.kind, 'kind', ScreenFailureKind.handshakeTimeout));
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 10)));
    expect(engine.sessions.single.closed, isTrue, reason: 'the engine stops');
    await ended.single.future.timeout(const Duration(seconds: 5));
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(screenFailureText(l10n, failed! as ScreenFailure), allOf(contains('ZS-1828'), contains('60 seconds')));
  });

  test('Disconnect while it is still connecting closes it at once, engine and socket, long before the deadline',
      () async {
    final engine = FakeScreenNative();
    final s = shell(engine);
    Object? failed;
    final connecting = s.connect().then<void>((_) {}, onError: (Object e) => failed = e);
    await until(() => engine.sessions.isNotEmpty && accepted.isNotEmpty);
    expect(engine.sessions, hasLength(1), reason: 'the session is open and waiting for the server');
    final started = DateTime.now();
    await s.disconnect();
    expect(engine.sessions.single.closed, isTrue, reason: 'the engine stops at once');
    await ended.single.future.timeout(const Duration(seconds: 5));
    await connecting.timeout(const Duration(seconds: 5));
    expect(failed, isNotNull, reason: 'connect ends, without connecting');
    expect(s.session, isNull);
    expect(DateTime.now().difference(started), lessThan(const Duration(seconds: 5)));
  });
}
