import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHKeyPair;
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_cert/ssh_cert_signer.dart';
import 'package:zestssh/services/ssh_cert/ssh_certificate.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

import '../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../packages/zest_ssh_core/test/src/played_server.dart';
import '../helpers/orchard_db_fixture.dart';
import '../helpers/played_sign_in.dart';

/// Automation's tasks (a command, a snippet, a batch, a workflow's step: from
/// a link, another app, a schedule, or its person's Run; 3.0) sign in to a
/// saved host as a session to it does: where the device is on a network, as
/// that network has the host; through the jump hosts on the way; with its
/// key's certificate; in your Tree whatever space is on screen. A run with
/// nobody there signs in only with keys allowed for unattended runs, and
/// asks nobody anything; a run its person started asks them what it needs.
/// A task dialled the address the host is saved with and signed in with the
/// host's own key alone: no network's settings, no jump host, no
/// certificate, and only that key was held to "Allow unattended runs".
///
/// The hosts are played on the loopback address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late String certificate;
  late AppDatabase tree;
  late AppDatabase orchard;
  late ProviderContainer container;
  late _OnNetwork resolver;

  setUpAll(() async {
    final authority = SSHKeyPair.fromPem((await KeyGenerationService().generateEd25519(comment: 'authority')).privatePem);
    certificate = base64.encode(SshCertSigner.issue(
      params: SshCertIssueParams(
        subjectPublicKeyBlob: SSHKeyPair.fromPem(keyPem).single.toPublicKey().encode(),
        subjectAlgorithm: SshCertAlgorithm.ed25519,
        serial: 1,
        type: SshCertType.user,
        keyId: 'deploy',
        principals: const ['deploy'],
        validAfter: DateTime.utc(2026, 9, 1),
        validBefore: DateTime.utc(2036, 9, 1),
      ),
      caKey: authority.single,
    ));
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-deploy': keyPem,
      'identity_key_id-other': keyPem,
      'identity_key_id-cert': keyPem,
      'identity_key_id-jump': keyPem,
      'identity_cert_id-cert': certificate,
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(orchard);
    resolver = _OnNetwork();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      orchardDatabasesProvider.overrideWith((ref) => _OneOrchard(orchard)),
      connectionResolverProvider.overrideWithValue(resolver),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final at = DateTime(2026, 10, 16);
    for (final (id, label, method, allowed) in [
      ('id-deploy', 'deploy-key', 'publicKey', true),
      ('id-other', 'office-key', 'publicKey', false),
      ('id-cert', 'cert-key', 'certificate', true),
      ('id-pass', 'deploy-password', 'password', false),
      ('id-jump', 'jump-key', 'publicKey', false),
    ]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: id,
          label: label,
          username: 'deploy',
          authMethod: method,
          allowUnattended: Value(allowed),
          createdAt: at));
    }
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
    await orchard.close();
  });

  AutomationService tasks() => container.read(automationServiceProvider);

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A host the test plays on the loopback address, saved in your Tree as
  /// [id] with the key [keyId] (and the jump host [via]), whose key this
  /// device trusts where [trusted]. It is saved at [savedPort] where that is
  /// given, else where it is played.
  Future<({PlayedListener listener, PlayedHostKey shows})> playedHost(String id,
      {String? keyId, String? via, bool trusted = true, int? savedPort, String protocol = 'ssh'}) async {
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
          port: Value(savedPort ?? listener.port),
          identityId: Value(keyId),
          connectViaId: Value(via),
          protocol: Value(protocol),
          createdAt: at,
          updatedAt: at,
        ));
    return (listener: listener, shows: shows);
  }

  /// Plays [host]: lets the task in as [signIn] says, and runs its command,
  /// which prints `done` and ends well. What the task asked to run, and the
  /// connection.
  Future<({String request, PlayedSocketLine line})> playsTheCommand(
      ({PlayedListener listener, PlayedHostKey shows}) host, PlayedSignIn signIn) async {
    final line = await host.listener.line();
    final server = PlayedServer(line: line, hostKey: host.shows);
    await server.greet();
    expect(await signIn.play(server), isTrue, reason: '${signIn.seen}');
    final channel = await server.confirmChannel();
    final request = await channel.nextRequest();
    server.send([channel.success, channel.data('done\n'), channel.exitStatus(0), channel.eof, channel.close]);
    return (request: request.requestType, line: line);
  }

  Future<String> runsTheCommand(({PlayedListener listener, PlayedHostKey shows}) host, PlayedSignIn signIn) async =>
      (await playsTheCommand(host, signIn)).request;

  /// Nothing reached [listener] in the time a task takes to dial it.
  Future<void> nothingDialled(PlayedListener listener) async {
    await expectLater(listener.line().timeout(const Duration(milliseconds: 400)), throwsA(isA<TimeoutException>()));
  }

  Future<DateTime?> lastUsed(String id) async => (await tree.connectionsDao.getById(id))!.lastConnected;

  test('a task runs on the host where the network the device is on has it, and is no use of the host by its person',
      () async {
    // Saved at a port where nothing answers; on the Office network it is where it is played.
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();
    final host = await playedHost('h-web', keyId: 'id-deploy', savedPort: deadPort);
    resolver.answers['h-web'] = resolver.onOffice('h-web', host.listener.host, host.listener.port, 'id-deploy');

    final result = tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    final played = await playsTheCommand(host, PlayedSignIn(ways: ['publickey'], takesKey: true));
    expect(played.request, 'exec');
    final done = await result;
    expect((done.success, done.output, done.exitCode, done.needsCredentials), (true, 'done\n', 0, false),
        reason: done.error);
    expect(await lastUsed('h-web'), isNull, reason: 'a run by itself is no use of the host by its person');
    await until(() => played.line.clientGone, 'the connection let go once the command ended');
  });

  test('a host that speaks mosh: a task runs over SSH, on the port saved for it', () async {
    final host = await playedHost('h-mosh', keyId: 'id-deploy', protocol: 'mosh');
    final result = tasks().executeCommand(connectionId: 'h-mosh', command: 'echo done', unattended: true);
    expect(await runsTheCommand(host, PlayedSignIn(ways: ['publickey'], takesKey: true)), 'exec');
    final done = await result;
    expect((done.success, done.output), (true, 'done\n'), reason: done.error);
  });

  test('through a jump host: the jump host is dialled first, not the host, and what stops it there is said under '
      'its name', () async {
    final jump = await playedHost('h-jump', keyId: 'id-deploy');
    final host = await playedHost('h-web', keyId: 'id-deploy', via: 'h-jump');
    var finished = false;
    final result = tasks()
        .executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true)
        .whenComplete(() => finished = true);
    final server = PlayedServer(line: await jump.listener.line(), hostKey: jump.shows);
    await server.greet();
    // The jump host takes no key.
    expect(await PlayedSignIn(ways: ['publickey']).play(server, over: () => finished), isFalse);
    final done = await result;
    expect((done.success, done.needsCredentials), (false, false));
    expect(done.error, contains('h-jump'));
    await nothingDialled(host.listener);
  });

  test('a run with nobody there, where the key this network gives the host is not allowed for it: it needs '
      'credentials, says which key, and nothing is dialled', () async {
    final host = await playedHost('h-web', keyId: 'id-deploy');
    resolver.answers['h-web'] = resolver.onOffice('h-web', host.listener.host, host.listener.port, 'id-other');
    final done = await tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    expect((done.success, done.needsCredentials, done.error), (false, true, en.unattendedKeyNotAllowed('office-key')));
    await nothingDialled(host.listener);
  });

  test("a run with nobody there, where a jump host's key is not allowed for it: it needs credentials, said under the "
      'jump host\'s name, and nothing is dialled', () async {
    final jump = await playedHost('h-jump', keyId: 'id-jump');
    final host = await playedHost('h-web', keyId: 'id-deploy', via: 'h-jump');
    final done = await tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    expect((done.success, done.needsCredentials), (false, true));
    expect(done.error, allOf(contains('h-jump'), contains(en.unattendedKeyNotAllowed('jump-key'))));
    await nothingDialled(jump.listener);
    await nothingDialled(host.listener);
  });

  test('a run with nobody there, on a host it would have to ask for a password: it needs credentials, nobody is '
      'asked, and nothing is dialled', () async {
    final host = await playedHost('h-bare');
    final done = await tasks().executeCommand(connectionId: 'h-bare', command: 'echo done', unattended: true);
    expect((done.success, done.needsCredentials, done.error), (false, true, en.unattendedNobodyToAsk));
    expect(container.read(passwordPromptProvider), isNull);
    await nothingDialled(host.listener);
  });

  test('a run with nobody there, on a host that asks its own question at sign-in: it needs credentials, and says so',
      () async {
    final host = await playedHost('h-web', keyId: 'id-deploy');
    var finished = false;
    final result = tasks()
        .executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true)
        .whenComplete(() => finished = true);
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    await server.greet();
    final asksACode = PlayedSignIn(ways: [
      'keyboard-interactive'
    ], rounds: [
      [('Verification code: ', false)]
    ]);
    expect(await asksACode.play(server, over: () => finished), isFalse);
    final done = await result;
    expect((done.success, done.needsCredentials, done.error), (false, true, en.unattendedHostAsked));
  });

  test('a key with a certificate signs in with its certificate', () async {
    final host = await playedHost('h-web', keyId: 'id-cert');
    final result = tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: true);
    expect(await runsTheCommand(host, signIn), 'exec');
    expect(signIn.offered, ['ssh-ed25519-cert-v01@openssh.com']);
    expect((await result).success, isTrue);
  });

  test('a run with nobody there and a host whose key this device does not trust: said as a task says it, and it '
      'needs no credentials', () async {
    final host = await playedHost('h-web', keyId: 'id-deploy', trusted: false);
    final result = tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    unawaited(server.greet().catchError((Object _) {}));
    final done = await result;
    expect((done.success, done.needsCredentials, done.error), (false, false, en.automationSvcHostKeyUnknown));
  });

  test('a run with nobody there whose time is up while it signs in: said as that', () async {
    final host = await playedHost('h-web', keyId: 'id-deploy');
    const allowed = Duration(seconds: 1);
    final clock = Stopwatch()..start();
    final result =
        tasks().executeCommand(connectionId: 'h-web', command: 'echo done', timeout: allowed, unattended: true);
    final server = PlayedServer(line: await host.listener.line(), hostKey: host.shows);
    // Greeted, and then the host says nothing more.
    await server.greet();
    final done = await result;
    expect((done.success, done.error), (false, timeUpBeforeItRan(en, TaskStage.signingIn, allowed)));
    // At its own time, and not at the end of the sign-in's (which says the same, 15 s on).
    expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
  });

  test("a run its person started: what it needs is asked of them, the command's time starts once it is signed in, "
      'and it is their use of the host', () async {
    final host = await playedHost('h-web', keyId: 'id-pass');
    final result = tasks()
        .executeCommand(connectionId: 'h-web', command: 'echo done', timeout: const Duration(seconds: 1));
    await until(() => container.read(passwordPromptProvider) != null, 'the question');
    // Answered after the time the task is given.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    container.read(passwordPromptProvider)!.completer.complete(const PasswordPromptResult(password: 'made-up-secret'));
    final signIn = PlayedSignIn(ways: ['password'], password: 'made-up-secret');
    expect(await runsTheCommand(host, signIn), 'exec');
    final done = await result;
    expect((done.success, done.output), (true, 'done\n'), reason: done.error);
    expect(signIn.seen, ['password:made-up-secret']);
    await until(() => container.read(activeSessionsProvider).isEmpty, 'nothing open');
    expect(await lastUsed('h-web'), isNotNull);
  });

  test("with a team space on screen: a task runs on your Tree's host, with your Tree's key", () async {
    final host = await playedHost('h-web', keyId: 'id-deploy');
    container.read(activeSpaceProvider.notifier).state = const OrchardSpace(kFixtureOrchardId);
    final result = tasks().executeCommand(connectionId: 'h-web', command: 'echo done', unattended: true);
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: true);
    expect(await runsTheCommand(host, signIn), 'exec');
    expect(signIn.seen, contains('key!'));
    final done = await result;
    expect(done.success, isTrue, reason: done.error);
  }, skip: !kOrchardsEnabled);
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

/// The team space of [db], open.
class _OneOrchard extends OrchardDatabasesNotifier {
  _OneOrchard(AppDatabase db) : super(OrchardDatabaseKeys(const FlutterSecureStorage())) {
    state = {kFixtureOrchardId: db};
  }
}

/// Each host as it is saved, but those given here, which are as the Office
/// network has them.
class _OnNetwork implements ConnectionResolver {
  final answers = <String, ResolvedConnection>{};

  ResolvedConnection onOffice(String hostId, String address, int port, String keyId) => ResolvedConnection(
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
        jumpChain: const [],
        bringUpVpnHostId: null,
      );

  @override
  Future<ResolvedConnection> resolve(String hostId) async =>
      answers[hostId] ?? (throw StateError('no network for $hostId'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
