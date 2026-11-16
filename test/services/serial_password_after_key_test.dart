import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/serial_service.dart';

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

/// A serial console server signed in to with a key it does not take, and
/// the password saved with the key (3.0, accounts per host): the password,
/// after the key, as a session's own host gets it; nothing where the key is
/// taken; and what stops the password from going ends the sign-in as that.
///
/// The console server is played on the loopback address.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const saved = 'correct-horse-battery';

  setUp(() => L10nGlobal.update(en));

  final key = SSHKeyPair.fromPem(
          File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync())
      .single;

  /// A serial console to a played console server that takes [ways], and the
  /// key where [takesKey]: how connecting ended (null: connected), what the
  /// server saw, and how often the password was fetched.
  Future<({Object? failure, List<String> seen, int fetched})> connect({
    required List<String> ways,
    bool takesKey = false,
    Future<String?> Function()? fetch,
  }) async {
    final listener = await PlayedListener.bind();
    var fetched = 0;
    var ended = false;
    final signIn = PlayedSignIn(ways: ways, takesKey: takesKey, password: saved);
    final played = () async {
      final server = PlayedServer(line: await listener.line());
      await server.greet();
      if (await signIn.play(server, over: () => ended)) await PlayedSignIn.openShell(server);
    }();
    final console = SerialOverSshService(
      host: listener.host,
      port: listener.port,
      username: 'deploy',
      keyPairs: [key],
      passwordAfterKey: () {
        fetched++;
        return (fetch ?? () async => saved)();
      },
      serialConfig: const SerialConfig(portName: 'ttyS0'),
      onHostKeyVerify: (_, _, _) async => true,
    );
    addTearDown(console.disconnect);
    Object? failure;
    try {
      await console.connect().timeout(const Duration(seconds: 15));
      expect(console.isConnected, isTrue);
    } catch (e) {
      failure = e;
    }
    ended = true;
    // What the played server waits for does not come where the console gave up on it.
    await played.timeout(const Duration(seconds: 10)).then((_) {}, onError: (Object _) {});
    return (failure: failure, seen: signIn.seen, fetched: fetched);
  }

  test('a console server that does not take the key: the password saved with it, after the key', () async {
    final outcome = await connect(ways: ['publickey', 'password']);
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'password:$saved']);
    expect(outcome.fetched, 1);
  });

  test('one that takes the key: no password is fetched', () async {
    final outcome = await connect(ways: ['publickey', 'password'], takesKey: true);
    expect(outcome.failure, isNull);
    expect(outcome.seen, ['key?', 'key!']);
    expect(outcome.fetched, 0);
  });

  test('what stops the password from going ends the sign-in as that', () async {
    final refused = OrchardAccessRefused(en.orchardPasswordWrongHost);
    final outcome = await connect(ways: ['publickey', 'password'], fetch: () async => throw refused);
    expect(outcome.failure, same(refused));
    expect(outcome.seen, ['key?']);
  });

  test("a saved console server is given the key's password as a session's host is (read from the files: no test "
      'opens a saved console through the session list)', () {
    final sessions = File('lib/providers/terminal_providers.dart').readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      sessions,
      contains('        password: credentials.password,\n'
          '        passwordAfterKey: credentials.passwordAfterKey,\n'
          '        keyPairs: credentials.keyPairs,\n'),
    );
  });
}
