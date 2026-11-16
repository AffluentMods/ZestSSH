import 'dart:async';
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
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

import '../../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/played_sign_in.dart';

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

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Run on hosts (3.0) through the app's own sign-in: a host is signed in to
/// as a session to it would be (its saved key and user, its host key
/// checked against what this device trusts), with no terminal and no
/// session counted; a host that is no SSH host is not run on; and two hosts
/// that ask their person for a password at once are asked one after the
/// other, each answered for itself.
///
/// The hosts are played on the loopback address, and their keys trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
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

  RunOnHostsNotifier runs() => container.read(runOnHostsProvider.notifier);
  HostsRun? run() => container.read(runOnHostsProvider);

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// The key [id] signs in as [user] with: a key (saved), or a password
  /// (none saved).
  Future<void> identity(String id, String user, {required String way}) =>
      tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: id,
            username: user,
            authMethod: way,
            createdAt: DateTime(2026, 10, 15),
          ));

  /// A host the test plays on the loopback address, saved as [id] with the
  /// key [key], whose host key this device trusts.
  Future<({PlayedListener listener, PlayedHostKey shows, Connection host})> playedHost(String id,
      {String? key, String protocol = 'ssh'}) async {
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
          protocol: Value(protocol),
          identityId: Value(key),
          createdAt: at,
          updatedAt: at,
        ));
    return (listener: listener, shows: shows, host: (await tree.connectionsDao.getById(id))!);
  }

  /// The host's part: the sign-in [signIn], then the command it is asked to
  /// run (what it was asked comes back), printing [output] and ending well.
  Future<String?> play(({PlayedListener listener, PlayedHostKey shows, Connection host}) h, PlayedSignIn signIn,
      {String output = ''}) async {
    final server = PlayedServer(line: await h.listener.line(), hostKey: h.shows);
    await server.greet();
    if (!await signIn.play(server)) return null;
    final channel = await server.confirmChannel();
    final request = await channel.nextRequest();
    server.send([
      channel.success,
      if (output.isNotEmpty) channel.data(output),
      channel.exitStatus(0),
      channel.eof,
      channel.close,
    ]);
    return request.command;
  }

  test('a host is signed in to as a session to it would be, with its saved key; the command runs with no terminal, '
      'no session is counted, and the host\'s last use is noted', () async {
    await identity('id-deploy', 'deploy', way: 'publicKey');
    final h = await playedHost('h-web', key: 'id-deploy');
    expect(h.host.lastConnected, isNull);
    final going = runs().run([h.host], 'uptime');
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: true);
    final asked = await play(h, signIn, output: 'up 3 days\n');
    await going;
    expect(signIn.seen, ['key?', 'key!']);
    expect(asked, 'uptime');
    final result = run()!.hosts.single;
    expect(result.succeeded, isTrue, reason: '${result.failure}');
    expect(result.output, 'up 3 days\n');
    expect(result.logged, isFalse, reason: 'a host of your Tree: nobody logs it');
    expect(container.read(activeSessionsProvider), isEmpty, reason: 'no session is opened, nor counted');
    // (Noted as the run goes on, not waited for.)
    Connection? row;
    for (var i = 0; i < 100 && row?.lastConnected == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      row = await tree.connectionsDao.getById('h-web');
    }
    expect(row!.lastConnected, isNotNull, reason: 'a run is a use of the host');
  });

  test('a host that is no SSH host is not run on, and says why; nothing is connected to it', () async {
    final h = await playedHost('h-console', protocol: 'telnet');
    var connected = false;
    unawaited(h.listener.line().then((_) => connected = true));
    await runs().run([h.host], 'uptime');
    final result = run()!.hosts.single;
    expect(result.state, HostRunState.failed);
    expect(hostRunFailureSaid(result, en).description, contains(en.runOnHostsSshOnly));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connected, isFalse);
  });

  test('two keys whose passphrase is asked for at once: one question at a time, each answered for its own',
      () async {
    final locked = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/id_ed25519').readAsStringSync();
    final passphrase =
        File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/passphrase').readAsStringSync().trim();
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-alex': locked, 'identity_key_id-robin': locked});
    await identity('id-alex', 'alex', way: 'publicKey');
    await identity('id-robin', 'robin', way: 'publicKey');
    final a = await playedHost('h-a', key: 'id-alex');
    final b = await playedHost('h-b', key: 'id-robin');
    final shown = <String>[];
    container.listen(passphrasePromptProvider, (_, next) {
      if (next != null) shown.add(next.username);
    }, fireImmediately: true);

    final going = runs().run([a.host, b.host], 'id -un');
    final hostsPlay = Future.wait([
      play(a, PlayedSignIn(ways: ['publickey'], takesKey: true), output: 'alex\n'),
      play(b, PlayedSignIn(ways: ['publickey'], takesKey: true), output: 'robin\n'),
    ]);
    await until(() => shown.isNotEmpty, 'the first question');
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(shown, hasLength(1), reason: 'the other waits its turn');
    void answer() => container.read(passphrasePromptProvider)!.completer.complete(PassphrasePromptResult(passphrase: passphrase));
    answer();
    await until(() => shown.length == 2, 'the second question');
    expect(shown.toSet(), {'alex', 'robin'});
    answer();
    await going;
    await hostsPlay;
    expect([for (final h in run()!.hosts) h.succeeded], [true, true],
        reason: '${[for (final h in run()!.hosts) h.failure]}');
  });

  test('two hosts that ask for a password at once: one question at a time, each answered for its own host',
      () async {
    await identity('id-alex', 'alex', way: 'password');
    await identity('id-robin', 'robin', way: 'password');
    final a = await playedHost('h-a', key: 'id-alex');
    final b = await playedHost('h-b', key: 'id-robin');
    final shown = <String>[];
    container.listen(passwordPromptProvider, (_, next) {
      if (next != null) shown.add(next.username);
    }, fireImmediately: true);

    final going = runs().run([a.host, b.host], 'id -un');
    final hostsPlay = Future.wait([
      play(a, PlayedSignIn(ways: ['password'], password: 'pw-alex'), output: 'alex\n'),
      play(b, PlayedSignIn(ways: ['password'], password: 'pw-robin'), output: 'robin\n'),
    ]);
    await until(() => shown.isNotEmpty, 'the first question');
    // The other host's question waits its turn: it does not take the
    // first one's place.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(shown, hasLength(1));
    void answer() {
      final asked = container.read(passwordPromptProvider)!;
      asked.completer.complete(PasswordPromptResult(password: 'pw-${asked.username}'));
    }

    answer();
    await until(() => shown.length == 2, 'the second question');
    expect(shown.toSet(), {'alex', 'robin'});
    answer();
    await going;
    await hostsPlay;
    expect([for (final h in run()!.hosts) h.succeeded], [true, true],
        reason: '${[for (final h in run()!.hosts) h.failure]}');
    expect([for (final h in run()!.hosts) h.output], ['alex\n', 'robin\n']);
  });
}
