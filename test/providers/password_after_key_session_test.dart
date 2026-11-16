import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

/// A key's own password, tried after the key, through the app's own session
/// (3.0, accounts per host): a saved host signed in to with a key the host
/// does not take is signed in to with the password saved with the key, and
/// so is a jump host on the way to one; a password that is only left from
/// before the identity became a key is never sent.
///
/// The hosts are played on the loopback address, and their keys trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  const saved = 'correct-horse-battery';
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-deploy': keyPem,
      'identity_password_id-deploy': saved,
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];
  bool over(String id) =>
      stateOf(id)?.status == SessionStatus.error || stateOf(id)?.status == SessionStatus.disconnected;

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The key deploy-key, a password saved with it, and whether that is
  /// tried after the key ([afterKey]: false, a password left from before).
  Future<void> key({required bool afterKey}) => tree.into(tree.identities).insert(IdentitiesCompanion.insert(
        id: 'id-deploy',
        label: 'deploy-key',
        username: 'deploy',
        authMethod: 'publicKey',
        passwordAfterKey: Value(afterKey),
        createdAt: DateTime(2026, 10, 15),
      ));

  /// A host the test plays on the loopback address, saved as [id], whose
  /// key this device trusts.
  Future<({PlayedListener listener, PlayedHostKey shows})> playedHost(String id, {String? via}) async {
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await KnownHostsService(tree.knownHostsDao)
        .trustHost(listener.host, listener.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    final at = DateTime(2026, 10, 15);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: listener.host,
          port: Value(listener.port),
          identityId: const Value('id-deploy'),
          connectViaId: Value(via),
          createdAt: at,
          updatedAt: at,
        ));
    return (listener: listener, shows: shows);
  }

  test('a host that does not take the key: the password saved with it signs in, after the key', () async {
    await key(afterKey: true);
    final host = await playedHost('h-web');
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    await server.greet();
    final signIn = PlayedSignIn(ways: ['publickey', 'password'], password: saved);
    expect(await signIn.play(server, over: () => over(id)), isTrue, reason: '${stateOf(id)?.connectionLog}');
    await PlayedSignIn.openShell(server);
    await until(() => stateOf(id)?.status == SessionStatus.connected || over(id), 'the session');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    expect(signIn.seen, ['key?', 'password:$saved']);
    expect(
        stateOf(id)!.connectionLog,
        containsAllInOrder([
          'ssh_auth: Authenticating as deploy (publickey, then the password saved with the key)',
          'identity: The server asks for a password: the one saved with the key...',
          'identity: Password saved with the key loaded for deploy',
          'ssh_auth: The key was not taken; sending the password saved with it',
        ]));
    await sessions().endSession(id);
  });

  test('a password only left from before the identity became a key is never sent', () async {
    await key(afterKey: false);
    final host = await playedHost('h-web');
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    await server.greet();
    final signIn = PlayedSignIn(ways: ['publickey', 'password'], password: saved);
    expect(await signIn.play(server, over: () => over(id)), isFalse);
    await until(() => over(id), 'the sign-in to fail');
    expect(signIn.seen, ['key?']);
    expect(stateOf(id)!.connectionLog, contains('ssh_auth: Authenticating as deploy (publickey)'));
    await sessions().endSession(id);
  });

  /// A session to db-primary, saved behind the jump host bastion, which the
  /// test plays: dialled, up to the jump host's sign-in.
  Future<({String id, PlayedServer server})> throughBastion() async {
    final bastion = await playedHost('h-bastion');
    final at = DateTime(2026, 10, 15);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-db',
          label: 'db-primary',
          host: '192.168.20.11',
          identityId: const Value('id-deploy'),
          connectViaId: const Value('h-bastion'),
          createdAt: at,
          updatedAt: at,
        ));
    final id = sessions().startSession((await tree.connectionsDao.getById('h-db'))!)!;
    final server = PlayedServer(line: await bastion.listener.line(), hostKey: bastion.shows);
    await server.greet();
    return (id: id, server: server);
  }

  for (final asQuestion in [false, true]) {
    test('a jump host that does not take the key: the password saved with it signs in there too, '
        '${asQuestion ? 'as the answer to its password prompt' : 'as the way "password"'}', () async {
      await key(afterKey: true);
      final s = await throughBastion();
      final signIn = asQuestion
          ? PlayedSignIn(ways: ['publickey', 'keyboard-interactive'], password: saved, rounds: [
              [('Password: ', false)],
            ])
          : PlayedSignIn(ways: ['publickey', 'password'], password: saved);
      expect(await signIn.play(s.server, over: () => over(s.id)), isTrue, reason: '${stateOf(s.id)?.connectionLog}');
      expect(signIn.seen, asQuestion ? ['key?', 'questions', 'answers:$saved'] : ['key?', 'password:$saved']);
      await until(() => stateOf(s.id)!.connectionLog.contains('jump: Authenticated to h-bastion') || over(s.id),
          'the jump host to let the session in');
      expect(stateOf(s.id)!.connectionLog, contains('jump: Authenticated to h-bastion'));
      await sessions().endSession(s.id);
    });
  }

  test("none saved with the jump host's key, and its person cancels the prompt for it: a cancel, as at a host",
      () async {
    await key(afterKey: true);
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
    // The person cancels the prompt for the password.
    final asked = <String>[];
    container.listen(passwordPromptProvider, (_, request) {
      if (request == null) return;
      asked.add('${request.username}@${request.host}');
      request.completer.complete(null);
    });
    final s = await throughBastion();
    final signIn = PlayedSignIn(ways: ['publickey', 'password'], password: saved);
    expect(await signIn.play(s.server, over: () => stateOf(s.id) == null || over(s.id)), isFalse);
    expect(signIn.seen, ['key?']);
    expect(asked, ['deploy@127.0.0.1']);
    await until(() => stateOf(s.id) == null || over(s.id), 'the session to go');
    expect(stateOf(s.id), isNull, reason: 'cancelled, not failed: ${stateOf(s.id)?.errorMessage}');
  });

  test('which kinds of key try it: a key, a certificate key and an agent key; not a team certificate, whose '
      "Crate's authority decides how it signs in", () {
    expect(kKeysWithPasswordAfter, {'publicKey', 'certificate', 'hardwareToken'});
  });
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
