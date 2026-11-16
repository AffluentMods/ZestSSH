import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;
import 'package:zestssh/utils/error_translator.dart' show saidByApp;

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/played_sign_in.dart';

/// A session opened by a run with nobody there (automation's "open": a link,
/// another app, a schedule; 3.0): it signs in only with keys allowed for
/// unattended runs, and asks nothing. Its host's own key alone was checked,
/// so the key the host takes on a network, and a jump host's, signed in
/// whether or not they were allowed; and a question (a password, a key's
/// passphrase) waited for nobody. Now each of them stops the session before
/// anything is dialled, and says why; a session a person opens asks as
/// before. So do a host's key that this device does not trust yet, and a
/// server's own question at sign-in (a code): nobody is asked.
///
/// The hosts are played on the loopback address, and their keys trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  final lockedPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519-passphrase/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late ProviderContainer container;
  late _OnNetwork resolver;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-deploy': keyPem,
      'identity_key_id-other': keyPem,
      'identity_key_id-jump': keyPem,
      'identity_key_id-locked': lockedPem,
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    resolver = _OnNetwork();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(resolver),
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

  /// The key [id] (called [label], of the user deploy), allowed for
  /// unattended runs where [allowed].
  Future<void> key(String id, String label, {required bool allowed}) =>
      tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: label,
            username: 'deploy',
            authMethod: 'publicKey',
            allowUnattended: Value(allowed),
            createdAt: DateTime(2026, 10, 16),
          ));

  /// A host the test plays on the loopback address, saved as [id] with the
  /// key [keyId], whose key this device trusts.
  Future<({PlayedListener listener, PlayedHostKey shows})> playedHost(String id,
      {String? keyId, String? via, bool trusted = true, String protocol = 'ssh'}) async {
    final listener = await PlayedListener.bind();
    addTearDown(listener.close);
    final shows = PlayedHostKey.ed25519();
    if (trusted) {
      await KnownHostsService(tree.knownHostsDao)
          .trustHost(listener.host, listener.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    }
    final at = DateTime(2026, 10, 16);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: listener.host,
          port: Value(listener.port),
          identityId: Value(keyId),
          connectViaId: Value(via),
          protocol: Value(protocol),
          createdAt: at,
          updatedAt: at,
        ));
    return (listener: listener, shows: shows);
  }

  Future<String> opened(String hostId, {bool unattended = true}) async =>
      sessions().startSession((await tree.connectionsDao.getById(hostId))!, unattended: unattended)!;

  /// Nothing reached [listener] in the time a session takes to dial it.
  Future<void> nothingDialled(PlayedListener listener) async {
    await expectLater(listener.line().timeout(const Duration(milliseconds: 400)), throwsA(isA<TimeoutException>()));
  }

  test('a key allowed for unattended runs signs in', () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    final host = await playedHost('h-web', keyId: 'id-deploy');
    final id = await opened('h-web');
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    await server.greet();
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: true);
    expect(await signIn.play(server, over: () => over(id)), isTrue, reason: '${stateOf(id)?.connectionLog}');
    await PlayedSignIn.openShell(server);
    await until(() => stateOf(id)?.status == SessionStatus.connected || over(id), 'the session');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    await sessions().endSession(id);
  });

  test("its host's own key, not allowed: stopped before anything is dialled, and said", () async {
    await key('id-deploy', 'deploy-key', allowed: false);
    final host = await playedHost('h-web', keyId: 'id-deploy');
    final id = await opened('h-web');
    await until(() => over(id), 'the refusal');
    expect(stateOf(id)?.errorMessage, contains(en.unattendedKeyNotAllowed('deploy-key')));
    await nothingDialled(host.listener);
  });

  test('the key this host takes on this network, not allowed: stopped, though its own is allowed', () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    await key('id-other', 'office-key', allowed: false);
    final host = await playedHost('h-web', keyId: 'id-deploy');
    resolver.answers['h-web'] = resolver.onOffice('h-web', host.listener.host, host.listener.port, 'id-other');
    final id = await opened('h-web');
    await until(() => over(id), 'the refusal');
    expect(stateOf(id)?.errorMessage, contains(en.unattendedKeyNotAllowed('office-key')));
    await nothingDialled(host.listener);
  });

  test("a jump host's key, not allowed: stopped before the jump host is dialled", () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    await key('id-jump', 'jump-key', allowed: false);
    final jump = await playedHost('h-jump', keyId: 'id-jump');
    final host = await playedHost('h-web', keyId: 'id-deploy', via: 'h-jump');
    final id = await opened('h-web');
    await until(() => over(id), 'the refusal');
    expect(stateOf(id)?.errorMessage, contains(en.unattendedKeyNotAllowed('jump-key')));
    await nothingDialled(jump.listener);
    await nothingDialled(host.listener);
  });

  test('a jump host this network gives the host, its key not allowed: stopped before it is dialled', () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    await key('id-jump', 'jump-key', allowed: false);
    final jump = await playedHost('h-jump', keyId: 'id-jump');
    final host = await playedHost('h-web', keyId: 'id-deploy');
    resolver.answers['h-web'] =
        resolver.onOffice('h-web', host.listener.host, host.listener.port, 'id-deploy', jumpChain: ['h-jump']);
    final id = await opened('h-web');
    await until(() => over(id), 'the refusal');
    expect(stateOf(id)?.errorMessage, contains(en.unattendedKeyNotAllowed('jump-key')));
    await nothingDialled(jump.listener);
    await nothingDialled(host.listener);
  });

  test("a host whose key this device does not trust yet: stopped, and nobody asked; a person's session asks",
      () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    final host = await playedHost('h-web', keyId: 'id-deploy', trusted: false);
    final other = await playedHost('h-two', keyId: 'id-deploy', trusted: false);
    final questions = <String>[];
    container.listen(hostKeyVerificationQueueProvider, (_, next) {
      if (next.isNotEmpty) questions.add(next.first.host);
    });

    final id = await opened('h-web');
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    unawaited(server.greet().catchError((Object _) {}));
    await until(() => over(id), 'the refusal');
    expect(stateOf(id)?.errorMessage, contains(en.automationSvcHostKeyUnknown));
    expect(questions, isEmpty);
    expect((await tree.knownHostsDao.getAll()).where((k) => k.port == host.listener.port), isEmpty,
        reason: 'not trusted by itself either');

    // A console server reached over SSH: the same.
    final console = await playedHost('h-console', keyId: 'id-deploy', trusted: false, protocol: 'serial');
    final serial = await opened('h-console');
    final third = PlayedServer(line: await console.listener.line(), hostKey: console.shows);
    unawaited(third.greet().catchError((Object _) {}));
    await until(() => over(serial), 'the console server refused');
    expect(stateOf(serial)?.errorMessage, contains(en.automationSvcHostKeyUnknown));
    expect(questions, isEmpty);

    // Opened by a person: asked, as before.
    final mine = await opened('h-two', unattended: false);
    final second = PlayedServer(line: await other.listener.line(), hostKey: other.shows);
    unawaited(second.greet().catchError((Object _) {}));
    await until(() => questions.isNotEmpty, 'the question');
    container.read(hostKeyVerificationQueueProvider).first.completer.complete(false);
    await until(() => stateOf(mine) == null || over(mine), 'the session given up');
  });

  test("a server's own question at sign-in: stopped, nobody asked (the host's, a jump host's, a console server's); "
      "a person's session is asked", () async {
    await key('id-deploy', 'deploy-key', allowed: true);
    final asked = <ServerQuestionRequest>[];
    container.listen(serverQuestionQueueProvider, (_, next) {
      for (final q in next) {
        if (!asked.contains(q)) asked.add(q);
      }
    });
    PlayedSignIn asksACode() => PlayedSignIn(ways: [
          'keyboard-interactive'
        ], rounds: [
          [('Verification code: ', false)]
        ]);
    // The session [id] signs in to [host], which asks for a code: it stops.
    Future<void> stopsAtTheCode(({PlayedListener listener, PlayedHostKey shows}) host, String id) async {
      final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
      await server.greet();
      expect(await asksACode().play(server, over: () => over(id)), isFalse);
      // The app's own words, not the SSH library's error around them.
      expect(stateOf(id)?.errorMessage, saidByApp(en.unattendedHostAsked), reason: '${stateOf(id)?.connectionLog}');
      expect(asked, isEmpty);
    }

    final host = await playedHost('h-web', keyId: 'id-deploy');
    await stopsAtTheCode(host, await opened('h-web'));

    // A jump host on the way that asks: the same, and the host behind it is not dialled.
    final jump = await playedHost('h-jump', keyId: 'id-deploy');
    final behind = await playedHost('h-behind', keyId: 'id-deploy', via: 'h-jump');
    final viaJump = await opened('h-behind');
    final jumpServer = PlayedServer(line: await jump.listener.line(), hostKey: jump.shows);
    await jumpServer.greet();
    expect(await asksACode().play(jumpServer, over: () => over(viaJump)), isFalse);
    expect(stateOf(viaJump)?.errorMessage, contains(en.unattendedHostAsked));
    expect(asked, isEmpty);
    await nothingDialled(behind.listener);

    // A console server reached over SSH: the same.
    final console = await playedHost('h-console', keyId: 'id-deploy', protocol: 'serial');
    await stopsAtTheCode(console, await opened('h-console'));

    // Opened by a person: the question is put to them, as before.
    final two = await playedHost('h-two', keyId: 'id-deploy');
    final mine = await opened('h-two', unattended: false);
    final server = PlayedServer(line: await two.listener.line(), hostKey: two.shows);
    await server.greet();
    final playing = asksACode().play(server, over: () => stateOf(mine) == null || over(mine));
    await until(() => asked.isNotEmpty, 'the question');
    expect(asked.single.question.prompts.single.text, 'Verification code:');
    asked.single.cancel();
    expect(await playing, isFalse);
    await until(() => stateOf(mine) == null || over(mine), 'the session given up');
  });

  test("nothing is asked: a key whose passphrase is not saved, a host with no key; a person's session asks as "
      'before', () async {
    await key('id-locked', 'locked-key', allowed: true);
    final locked = await playedHost('h-locked', keyId: 'id-locked');
    final bare = await playedHost('h-bare');
    final asked = <String>[];
    container.listen(passphrasePromptProvider, (_, next) {
      if (next != null) asked.add('passphrase');
    });
    container.listen(passwordPromptProvider, (_, next) {
      if (next != null) asked.add('password');
    });

    final first = await opened('h-locked');
    await until(() => over(first), 'the refusal');
    expect(stateOf(first)?.errorMessage, contains(en.unattendedNobodyToAsk));
    final second = await opened('h-bare');
    await until(() => over(second), 'the refusal');
    expect(stateOf(second)?.errorMessage, contains(en.unattendedNobodyToAsk));
    expect(asked, isEmpty);
    await nothingDialled(locked.listener);

    // Opened by a person: the password is asked for, as before.
    final mine = await opened('h-bare', unattended: false);
    await until(() => asked.isNotEmpty, 'the question');
    expect(asked, ['password']);
    container.read(passwordPromptProvider)!.completer.complete(null);
    await until(() => stateOf(mine) == null || over(mine), 'the session given up');
    await nothingDialled(bare.listener);
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

/// Each host as it is saved, but those given here, which are as the Office
/// network has them.
class _OnNetwork implements ConnectionResolver {
  final answers = <String, ResolvedConnection>{};

  ResolvedConnection onOffice(String hostId, String address, int port, String keyId,
          {List<String> jumpChain = const []}) =>
      ResolvedConnection(
        hostId: hostId,
        network: const Network(
          id: 'n-office',
          name: 'Office',
          color: GroupColor.blue,
          icon: LucideIcons.globe,
          triggers: [AlwaysTrigger()],
          isFallback: false,
        ),
        address: address,
        port: port,
        username: 'deploy',
        identityKeyId: keyId,
        jumpChain: jumpChain,
        bringUpVpnHostId: null,
      );

  @override
  Future<ResolvedConnection> resolve(String hostId) async =>
      answers[hostId] ?? (throw StateError('no network for $hostId'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
