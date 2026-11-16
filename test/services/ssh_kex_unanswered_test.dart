import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// A host that sends its SSH version and then nothing of the key exchange,
/// as the SSH inspection of a SonicWall firewall did (3.2.6, 28 October
/// 2026): the app said "Sign-in timed out" after its full wait. It now says
/// in seconds what happened, where the Compatibility mode switch is, and
/// does not try again on its own.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));

  test('the sentence, word for word', () {
    expect(
      en.connKexUnanswered('Auth / Show advanced options'),
      'The host sent its SSH version and then stopped answering: its part of the key exchange never came, so no '
      'connection was made and nothing of a sign-in was sent. A firewall that inspects SSH (a SonicWall with DPI-SSH '
      'on, for example) does this when it does not take what this app offers. If Compatibility mode is off for this '
      'host, turning it on (under "Auth / Show advanced options") may get through: it adds older algorithms after the '
      'ones offered now. Otherwise, ask whoever runs the firewall to let SSH to this host through without inspection.',
    );
  });

  test('said by itself and as what ended a sign-in, with where the switch is, and not tried again', () {
    final quiet = SSHHandshakeError('no proposal', kexUnanswered: true);
    final said = saidByApp(en.connKexUnanswered(compatibilityModePlace(en)));
    for (final failure in <Object>[quiet, SSHAuthAbortError('Connection closed before authentication', quiet)]) {
      expect(connectionFailureText(failure), said);
      expect(reconnectCannotHelp(failure), isTrue);
    }
    final shown = ConnectionError.translate(said, host: 'web-01.example.com', port: 22, username: 'deploy');
    expect(shown.type, ConnectionErrorType.saidByApp);
    expect(shown.description, en.connKexUnanswered(compatibilityModePlace(en)));
    // Another handshake error is what it was.
    expect(connectionFailureText(SSHHandshakeError('Invalid version: HTTP/1.1')), isNot(said));
  });

  test("the app's own service on such a host: ended in about ten seconds, said as that", () async {
    final socket = _QuietHost();
    final ssh = SshService(
      host: 'fw-01.example.com',
      port: 22,
      username: 'deploy',
      password: 'not-a-real-one',
      keepAliveSeconds: 0,
      onHostKeyVerify: (_, _, _) async => true,
      tunnelSocket: socket,
    );
    addTearDown(ssh.disconnect);
    socket.say('SSH-2.0-libssh_0.9.0\r\n');
    final watch = Stopwatch()..start();
    Object? failure;
    await ssh.connect().timeout(const Duration(seconds: 30)).then<void>((_) {}, onError: (Object e) => failure = e);
    expect(failure, isNotNull);
    expect(watch.elapsed, lessThan(const Duration(seconds: 14)), reason: 'before the sign-in would have timed out');
    expect(connectionFailureText(failure!), saidByApp(en.connKexUnanswered(compatibilityModePlace(en))));
  }, timeout: const Timeout(Duration(seconds: 40)));
}

class _QuietHost implements SSHSocket {
  final _input = StreamController<Uint8List>();
  final _done = Completer<void>();

  void say(String text) => _input.add(Uint8List.fromList(latin1.encode(text)));

  @override
  Future<void> flush() async {}

  @override
  Stream<Uint8List> get stream => _input.stream;

  @override
  StreamSink<List<int>> get sink => _DroppingSink();

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
    await _input.close();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) _done.complete();
    unawaited(_input.close());
  }
}

class _DroppingSink implements StreamSink<List<int>> {
  @override
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.drain<void>();

  @override
  Future<void> close() async {}

  @override
  Future<void> get done async {}
}
