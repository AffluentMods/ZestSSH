import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen_testing.dart';
// The messages a played server reads and says are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/record_commits.dart';

/// An X program in a screen tab (4.0) as the app keeps it: a screen
/// session of the SSH host itself, signed in to with no terminal (a server
/// played by the test, under the app's own SSH), the host script on one exec
/// channel, then direct-streamlocal to the socket it named, and the screen
/// engine played by FakeScreenNative. All made up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late FakeScreenNative engine;
  late PlayedServer server;
  late List<String> dialled;

  Future<void> start({bool isPro = true, bool team = false}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(isPro)),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    engine = FakeScreenNative();
    container.read(activeSessionsProvider.notifier).debugScreenNative = engine;
    server = PlayedServer();
    dialled = [];
    SshService.debugOpenSocket = (host, port, timeout) async {
      dialled.add('$host:$port');
      return server.socket;
    };
    // Every host key question is answered yes.
    container.listen<List<HostKeyVerification>>(hostKeyVerificationQueueProvider, (_, queue) {
      for (final v in queue) {
        scheduleMicrotask(() => container.read(hostKeyVerificationQueueProvider.notifier).resolve(v, true));
      }
    });
    // A watched vault's place for the host comes first, as a team's does.
    if (team) await _watch(tree, 'h-gw');
    final keyId = await IdentityCrudNotifier(
            tree.identitiesDao, IdentitySecretStore.forDatabase(tree, const FlutterSecureStorage()), tree.connectionsDao)
        .create(label: 'deploy', username: 'deploy', authMethod: 'password', password: 'ssh-pass');
    final at = DateTime(2026, 11, 9);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-gw',
          label: 'gw',
          host: 'gw.example.com',
          port: const Value(22),
          protocol: const Value('ssh'),
          identityId: Value(keyId),
          createdAt: at,
          updatedAt: at,
        ));
  }

  tearDown(() async {
    SshService.debugOpenSocket = null;
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];
  Future<Connection> gw() async => (await tree.connectionsDao.getById('h-gw'))!;

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  // (A session's id is its host's and the millisecond it opened in: one
  // opened a moment after another.)
  Future<String> openX({String program = "xterm -T 'secret title'"}) async {
    await Future<void>.delayed(const Duration(milliseconds: 3));
    return sessions().startXProgram(await gw(), XProgramTarget(program, 1024, 768))!;
  }

  /// The host script's exec channel, asked for and said yes to.
  Future<PlayedChannel> scriptAsked() async {
    final exec = await server.confirmChannel();
    final ask = await exec.nextRequest();
    expect(ask.requestType, 'exec');
    expect(ask.command, startsWith("exec sh -c 'eval "));
    expect(ask.command, isNot(contains("'secret")), reason: "the program's quotes travel as octal escapes");
    server.send([exec.success]);
    return exec;
  }

  test('an X program: its SSH host signed in to with no terminal, the script on one exec channel, then '
      'direct-streamlocal to the socket it named; no password and no TLS; a screen session, counted, called '
      '"xterm on gw"; closing the tab ends the script\'s input', () async {
    await start(isPro: false);
    engine.onOpen = (s) => s.connect(name: 'zestssh', width: 1024, height: 768);
    final id = await openX();
    expect((sessions().isScreen(id), sessions().isXProgram(id)), (true, true));
    expect(stateOf(id)!.connectionLabel, 'xterm on gw');
    await server.letIn();
    final exec = await scriptAsked();
    server.send([exec.data('ZSX {"socket":"/tmp/zestssh-x.Q1/vnc.sock","display":7}\n')]);
    final vnc = await server.confirmChannel();
    expect(vnc.asked.channelType, 'direct-streamlocal@openssh.com');
    expect(vnc.asked.socketPath, '/tmp/zestssh-x.Q1/vnc.sock');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the X program to show');
    expect(dialled, ['gw.example.com:22']);
    final request = engine.sessions.single.request;
    expect(request['password'], isNull);
    expect(request['require_tls'], isFalse);
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    expect(shell.isEncryptedSsh, isTrue);
    expect(shell.xProgram!.display, 7);
    expect(shell.exitCode, isNull, reason: 'it runs');
    expect(sessions().occupiedSessionSlots, 1);
    expect(stateOf(id)!.connectionLabel, 'xterm on gw');
    final log = stateOf(id)!.connectionLog.join('\n');
    expect(log, allOf(contains('Starting xterm'), contains('display :7'), isNot(contains('secret')),
        isNot(contains('ssh-pass'))));

    await sessions().endSession(id);
    await server.next(SSH_Message_Channel_EOF.messageId);
    expect(sessions().isXProgram(id), isFalse);
    expect(sessions().isScreen(id), isFalse);
  });

  test('the program ends: the tab stays, ended with its exit status, and nothing connects again by itself',
      () async {
    await start();
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(hours: 1);
    engine.onOpen = (s) => s.connect();
    final id = await openX(program: 'xclock');
    await server.letIn();
    final exec = await scriptAsked();
    server.send([exec.data('ZSX {"socket":"/tmp/zestssh-x.Q2/vnc.sock","display":2}\n')]);
    await server.confirmChannel();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the X program to show');
    // The script says the exit, then stops the Xvnc: the screen ends.
    server.send([exec.data('ZSX {"exited":0}\n')]);
    engine.sessions.single.closeWith('server_closed', 'the server closed the connection');
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the tab to end');
    expect(stateOf(id)!.dropCause, contains('(exit status 0)'));
    expect(stateOf(id)!.isReconnecting, isFalse);
    expect(stateOf(id)!.connectionLog.join('\n'), contains('xprogram: xclock ended (exit status 0)'));
    await sessions().endSession(id);
  });

  test('no Xvnc on the host: ZS-1809 with the install command, and no try by itself', () async {
    await start();
    final id = await openX();
    await server.letIn();
    final exec = await scriptAsked();
    server.send([exec.data('ZSX {"error":"no-xvnc","pm":"apt-get"}\n'), exec.exitStatus(1), exec.eof, exec.close]);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the X program to fail');
    expect(stateOf(id)!.errorMessage,
        allOf(contains('gw has no Xvnc'), contains('sudo apt install tigervnc-standalone-server xauth'),
            contains('ZS-1809')));
    expect(engine.sessions, isEmpty, reason: 'the engine is never started without a socket');
  });

  test('a program the host does not have: ZS-1811, said by its name', () async {
    await start();
    final id = await openX(program: 'xtrem -geometry 80x24');
    await server.letIn();
    final exec = await scriptAsked();
    server.send([exec.errorData('sh: 1: xtrem: not found\n'), exec.data('ZSX {"exited":127}\n'), exec.eof, exec.close]);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the X program to fail');
    expect(stateOf(id)!.errorMessage, allOf(contains('xtrem was not found on gw'), contains('ZS-1811')));
  });

  test('a program that ends as its screen opens is said as that, not as the socket that went with it', () async {
    await start();
    final id = await openX(program: 'firefox');
    await server.letIn();
    final exec = await scriptAsked();
    server.send([exec.data('ZSX {"socket":"/tmp/zestssh-x.Q3/vnc.sock","display":4}\n'), exec.data('ZSX {"exited":0}\n')]);
    // The script removed the folder: the socket is gone.
    final open = SSH_Message_Channel_Open.decode(await server.next(SSH_Message_Channel_Open.messageId));
    server.send([
      SSH_Message_Channel_Open_Failure(
              recipientChannel: open.senderChannel,
              reasonCode: SSH_Message_Channel_Open_Failure.codeConnectFailed,
              description: 'open failed')
          .encode(),
    ]);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the X program to fail');
    expect(stateOf(id)!.errorMessage,
        allOf(contains('firefox ended as it started (exit status 0)'), contains('ZS-1811')));
  });

  test('an SSH host in a watched vault: refused before anything is dialled (ZS-1807)', () async {
    await start(team: true);
    final id = await openX();
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the X program to be refused');
    expect(stateOf(id)!.errorMessage, contains('ZS-1807'));
    expect(dialled, isEmpty);
  });

  test('each X program is a tab of its own: the host\'s terminal is never reused for it, nor it for the '
      'terminal; each counts toward the free limit', () async {
    await start(isPro: false);
    sessions().debugShellFor = (_) => _SlowShell();
    final host = await gw();
    final x1 = await openX();
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final t1 = sessions().startSession(host)!;
    expect(t1, isNot(x1));
    expect(sessions().isXProgram(t1), isFalse);
    expect(sessions().startSession(host), t1, reason: 'the terminal itself is reused');
    final x2 = await openX();
    expect({x1, t1, x2}, hasLength(3));
    expect(stateOf(x2)!.connectionLabel, 'xterm on gw');
    while (sessions().occupiedSessionSlots < freeSessionLimit) {
      expect(await openX(), isNotNull);
    }
    expect(sessions().startXProgram(host, XProgramTarget('xterm', 800, 600)), isNull,
        reason: 'past the free limit');
    expect(sessions().startLike(x1, host), isNull, reason: 'a duplicate counts too');
    for (final id in container.read(activeSessionsProvider).keys.toList()) {
      await sessions().endSession(id);
    }
  });

  test("Duplicate and Open again of an X program open the same program again, never the host's terminal",
      () async {
    await start();
    sessions().debugShellFor = (_) => _SlowShell();
    final x1 = await openX(program: 'xclock -digital');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final copy = sessions().startLike(x1, await gw())!;
    expect(sessions().isXProgram(copy), isTrue);
    expect(stateOf(copy)!.connectionLabel, 'xclock on gw');
    await Future<void>.delayed(const Duration(milliseconds: 3));
    final again = (await sessions().openAgain(copy))!;
    expect(sessions().isXProgram(again), isTrue);
    expect(again, isNot(copy));
    for (final id in container.read(activeSessionsProvider).keys.toList()) {
      await sessions().endSession(id);
    }
  });

  test('a target refuses what is no program line', () {
    expect(() => XProgramTarget('xterm\nrm -rf ~', 800, 600), throwsArgumentError);
    expect(() => XProgramTarget('  ', 800, 600), throwsArgumentError);
    expect(() => XProgramTarget('xterm', 0, 600), throwsArgumentError);
    expect(XProgramTarget('/usr/bin/xterm -e top', 800, 600).describe(), 'X program xterm');
  });
}

/// A shell that stays connecting (the sessions' bookkeeping only).
class _SlowShell extends ShellService {
  final _state = StreamController<bool>.broadcast();
  @override
  Future<void> connect() => Completer<void>().future;
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => false;
  @override
  Stream<bool> get connectionState => _state.stream;
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

/// The host [hostId] of [db] in a vault whose sessions are watched.
Future<void> _watch(AppDatabase db, String hostId) async {
  const orchard = '0c2f8a6e-5b1d-4d3a-9f47-2a61c0e9b7d3';
  const crate = '2e4a0c8a-7d3f-4f5c-9a69-4c83e2a1d9f5';
  const owner = 'owner-1';
  final keys = await AccountKeys.generate();
  final chain = <RecordEntry>[];
  Future<void> add(String type, Map<String, Object?> body) async => chain.add(await signRecordEntry(keys,
      orchardId: orchard,
      seq: chain.length + 1,
      prev: chain.isEmpty ? const [] : chain.last.hash(orchard),
      type: type,
      body: body,
      by: owner));
  await add(RecordTypes.create, {
    'owner': {...recordKeysBody(await keys.publish(owner)), 'uid': owner},
    'key_commit': testCommit('orchard'),
    'crate': {'id': crate, 'owners_only': false, 'allow': ['forward', 'sftp'], 'key_commit': testCommit(crate)},
    'roles': const <Object>[],
  });
  await add(RecordTypes.crateSet, {'id': crate, 'watched': true, 'allow': <String>[]});
  await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [orchard, crate]);
  await LocalRecord.empty(orchard).extend(db, chain);
  await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
      [crate, jsonEncode(switchList(CrateSwitches.all))]);
  await CratePlacement(db).place('host', hostId, crate);
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.pro);

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
