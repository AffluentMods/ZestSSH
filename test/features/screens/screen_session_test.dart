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
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/session/screen_clipboard.dart' show screenClipboardOn;
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_shell_service.dart';
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/broadcast_provider.dart';
import 'package:zestssh/providers/connection_providers.dart' show ConnectionCrudNotifier;
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/widgets/connection_lost_view.dart' show dropSaid;

import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/record_commits.dart';

/// A remote screen's session (4.0) as the app keeps it:
/// its carrier SSH host signed in to with no terminal (a server played by
/// the test, under the app's own SSH), the channel to the VNC server through
/// it (direct-tcpip, or direct-streamlocal with `~` read from the host), and
/// the screen engine played by FakeScreenNative.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late FakeScreenNative engine;
  late PlayedServer server;
  late List<String> dialled;
  late List<HostKeyVerification> asked;
  late bool pro;

  Future<void> start({bool isPro = true, bool team = false}) async {
    pro = isPro;
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: team);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(pro)),
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
    // Every key and certificate question is answered yes, and kept.
    asked = [];
    container.listen<List<HostKeyVerification>>(hostKeyVerificationQueueProvider, (_, queue) {
      for (final v in queue) {
        if (asked.contains(v)) continue;
        asked.add(v);
        scheduleMicrotask(() => container.read(hostKeyVerificationQueueProvider.notifier).resolve(v, true));
      }
    });
  }

  tearDown(() async {
    SshService.debugOpenSocket = null;
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<String> key(String label, {required String username, String? password}) =>
      IdentityCrudNotifier(tree.identitiesDao, IdentitySecretStore.forDatabase(tree, const FlutterSecureStorage()),
              tree.connectionsDao)
          .create(label: label, username: username, authMethod: 'password', password: password);

  final at = DateTime(2026, 11, 8);
  Future<void> host(String id, String label, String address,
      {String protocol = 'ssh', int port = 22, String? via, String? keyId, String? options}) async {
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: address,
          port: Value(port),
          protocol: Value(protocol),
          connectViaId: Value(via),
          identityId: Value(keyId),
          screenOptions: Value(options),
          createdAt: at,
          updatedAt: at,
        ));
  }

  /// The carrier gw (deploy's password) and the screen desk behind it at
  /// [address]:5900, with the VNC password in its key (or none).
  Future<void> carrierAndScreen({String address = 'localhost', String? options, bool screenKey = true}) async {
    await host('h-gw', 'gw', 'gw.example.com', keyId: await key('deploy', username: 'deploy', password: 'ssh-pass'));
    await host('s-desk', 'desk', address,
        protocol: 'vnc',
        port: 5900,
        via: 'h-gw',
        options: options,
        keyId: screenKey ? await key('desk vnc', username: 'alex', password: 'vnc-pass') : null);
  }

  Future<String> open(String id) async => sessions().startSession((await tree.connectionsDao.getById(id))!)!;

  /// The channel the session asks the carrier for: its open message, and
  /// the played channel once given.
  Future<(SSH_Message_Channel_Open, PlayedChannel)> channelAsked() async {
    final channel = await server.confirmChannel();
    return (channel.asked, channel);
  }

  /// The carrier refuses the next channel with [code].
  Future<SSH_Message_Channel_Open> refuseChannel(int code) async {
    final open = SSH_Message_Channel_Open.decode(await server.next(SSH_Message_Channel_Open.messageId));
    server.send([
      SSH_Message_Channel_Open_Failure(recipientChannel: open.senderChannel, reasonCode: code, description: 'refused')
          .encode(),
    ]);
    return open;
  }

  test('a screen through its carrier: signed in to the SSH host with no terminal, a direct-tcpip channel to '
      'localhost:5900, the engine given the key\'s VNC password inside its start request, and the session counted; '
      'broadcast and snippets pass it over, and nothing typed goes into it', () async {
    await start(isPro: false);
    await carrierAndScreen();
    engine.onOpen = (s) => s.connect(name: 'desk', width: 1920, height: 1080, security: 'VncAuth');
    final id = await open('s-desk');
    expect(sessions().isScreen(id), isTrue);
    await server.letIn();
    final (open1, channel) = await channelAsked();
    expect(open1.channelType, 'direct-tcpip');
    expect((open1.host, open1.port), ('localhost', 5900));
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    expect(dialled, ['gw.example.com:22']);

    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    expect(shell.isEncryptedSsh, isTrue);
    expect(shell.connectedInfo!.width, 1920);
    final engineSide = engine.sessions.single;
    expect(engineSide.request['password'], 'vnc-pass');
    expect(engineSide.request['require_tls'], isFalse);
    // The server's bytes reach the engine, and the engine's reach the server.
    server.send([channel.data('RFB 003.008\n')]);
    await until(() => engineSide.fed.length > 0, 'the bytes to reach the engine');
    expect(utf8.decode(engineSide.fed.toBytes()), 'RFB 003.008\n');

    // No terminal and no shell was asked for on the carrier: no request on any channel.
    expect(await server.sent(SSH_Message_Channel_Request.messageId), isFalse);
    // Counted as a session (the free tier), passed over by a broadcast, and nothing typed goes in.
    expect(sessions().occupiedSessionSlots, 1);
    expect(container.read(broadcastAwayProvider), contains(id));
    expect(container.read(screenSessionsProvider), {id});
    expect(sessions().sendInput(id, Uint8List.fromList(utf8.encode('ls\n'))), isFalse);
    // The log says what happened, never a password.
    final log = stateOf(id)!.connectionLog.join('\n');
    expect(log, contains('screen: Connected (VncAuth)'));
    expect(log, isNot(contains('vnc-pass')));
    expect(log, isNot(contains('ssh-pass')));

    await sessions().endSession(id);
    expect(engineSide.closed, isTrue);
    expect(sessions().isScreen(id), isFalse);
  });

  test('closing a screen returns once its carrier SSH connection is closed, not a moment before', () async {
    await start();
    await carrierAndScreen();
    engine.onOpen = (s) => s.connect();
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    final carrier = shell.carrier!;
    expect(carrier.isConnected, isTrue);
    await shell.disconnect();
    expect(engine.sessions.single.closed, isTrue);
    expect(carrier.isConnected, isFalse, reason: 'disconnect completed before the carrier was closed');
    await sessions().endSession(id);
  });

  test('a Unix socket under ~/ is read once from the carrier (printf %s "\$HOME") and opened with '
      'direct-streamlocal', () async {
    await start();
    await carrierAndScreen(options: '{"v":1,"target":"unix","socket":"~/.vnc/zest.sock"}');
    engine.onOpen = (s) => s.connect();
    final id = await open('s-desk');
    await server.letIn();
    final exec = await server.confirmChannel();
    final ask = await exec.nextRequest();
    expect(ask.requestType, 'exec');
    expect(ask.command, contains(r'printf %s "$HOME"'));
    server.send([exec.success, exec.data('/home/alex'), exec.exitStatus(0), exec.eof, exec.close]);
    final (open1, _) = await channelAsked();
    expect(open1.channelType, 'direct-streamlocal@openssh.com');
    expect(open1.socketPath, '/home/alex/.vnc/zest.sock');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    await sessions().endSession(id);
  });

  test('the carrier refuses forwarding: ZS-1802, and no try by itself; nothing listens: ZS-1801; no socket: '
      'ZS-1806', () async {
    await start();
    await carrierAndScreen();
    final id = await open('s-desk');
    await server.letIn();
    await refuseChannel(SSH_Message_Channel_Open_Failure.codeAdministrativelyProhibited);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the screen to fail');
    expect(stateOf(id)!.errorMessage, allOf(contains('gw does not allow a remote screen'), contains('ZS-1802')));
    expect(engine.sessions, isEmpty, reason: 'the engine is never started without a channel');

    const nothing = ScreenFailure(ScreenFailureKind.nothingAnswers, 'x', carrier: 'gw', address: 'localhost:5900');
    expect(screenFailureText(en, nothing), allOf(contains('localhost:5900 on gw'), endsWith('(ZS-1801)')));
    expect(reconnectCannotHelp(nothing), isFalse, reason: 'a server that is starting may be there next time');
    const socket = ScreenFailure(ScreenFailureKind.socketMissing, 'x', carrier: 'gw', address: '/run/vnc.sock');
    expect(screenFailureText(en, socket), endsWith('(ZS-1806)'));
    expect(reconnectCannotHelp(const ScreenFailure(ScreenFailureKind.forwardingRefused, 'x')), isTrue);
  });

  test('nothing listens at the address: ZS-1801 with the address and the carrier', () async {
    await start();
    await carrierAndScreen();
    final id = await open('s-desk');
    await server.letIn();
    await refuseChannel(SSH_Message_Channel_Open_Failure.codeConnectFailed);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the screen to fail');
    expect(stateOf(id)!.errorMessage, allOf(contains('localhost:5900 on gw'), contains('ZS-1801')));
  });

  test('the VNC server refuses the saved password: ZS-1803 at once, never asked again by itself', () async {
    await start();
    await carrierAndScreen();
    engine.onOpen = (s) => s.closeWith('auth', 'authentication failed');
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the screen to fail');
    expect(stateOf(id)!.errorMessage, allOf(contains('refused the password'), contains('ZS-1803')));
    expect(engine.sessions, hasLength(1));
    expect(reconnectCannotHelp(const ScreenFailure(ScreenFailureKind.passwordRefused, 'x')), isTrue);
    expect(container.read(passwordPromptProvider), isNull);
  });

  test('a VeNCrypt certificate on first use: asked as a screen\'s, through which SSH host, kept for the carrier\'s '
      'route only, and the second connection pinned to it', () async {
    await start();
    await carrierAndScreen();
    final der = Uint8List.fromList(List.generate(64, (i) => i));
    const sha = 'ab' '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd';
    engine.onOpen = (s) {
      if (s.request['tls_pin'] == null) {
        s.closeWith('certificate', 'the certificate is not the trusted one',
            extra: {'sha256': sha, 'der': base64Encode(der), 'subject': 'CN=desk'});
      } else {
        s.connect(security: 'VeNCrypt');
      }
    };
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    final question = asked.singleWhere((v) => v.certificate);
    expect(question.screen, isTrue);
    expect(question.via, 'gw');
    expect((question.host, question.port), ('localhost', 5900));
    expect(engine.sessions.last.request['tls_pin'], sha);
    final known = KnownHostsService(tree.knownHostsDao);
    expect(await known.pinnedCertificate('localhost', 5900, viaScope: 'gw.example.com:22'), sha);
    expect(await known.pinnedCertificate('localhost', 5900), isNull, reason: 'kept for this route only');
    await sessions().endSession(id);
  });

  test('a free account: the hop to the carrier is free, while the carrier\'s own jump host is gated as always '
      '(it is dialled directly, with the notice)', () async {
    await start(isPro: false);
    await host('h-bastion', 'bastion', 'bastion.example.com',
        keyId: await key('ops', username: 'ops', password: 'ssh-pass'));
    await carrierAndScreen();
    await (tree.update(tree.connections)..where((c) => c.id.equals('h-gw')))
        .write(const ConnectionsCompanion(connectViaId: Value('h-bastion')));
    engine.onOpen = (s) => s.connect();
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    expect(dialled, ['gw.example.com:22'], reason: 'the carrier is reached, its own jump gated off');
    expect(stateOf(id)!.connectionLog.join('\n'), contains('Jump host routing needs Squeezed'));
    await sessions().endSession(id);
  });

  // Found in a security review: a screen whose carrier was deleted
  // used to lose it (clearConnectViaReferences) and be dialled directly at
  // its address as the carrier saw it.
  test('a screen whose carrier is deleted keeps pointing at it and is refused (ZS-1808), never dialled directly; '
      "an SSH host's jump host is still cleared", () async {
    await start();
    await carrierAndScreen(address: '10.0.0.5');
    await host('h-web', 'web', 'web.example.com', via: 'h-gw');
    await ConnectionCrudNotifier(tree.connectionsDao, tree.portForwardRulesDao, tree.connectionTagsDao).delete('h-gw');
    expect((await tree.connectionsDao.getById('s-desk'))!.connectViaId, 'h-gw', reason: 'not turned into a direct screen');
    expect((await tree.connectionsDao.getById('h-web'))!.connectViaId, isNull, reason: 'a jump host, cleared as before');

    final id = await open('s-desk');
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the screen to be refused');
    expect(stateOf(id)!.errorMessage, allOf(contains('is not here any more'), contains('ZS-1808')));
    expect(dialled, isEmpty, reason: 'neither the carrier nor 10.0.0.5');
    expect(engine.sessions, isEmpty);
    const gone = ScreenFailure(ScreenFailureKind.carrierGone, 'its SSH host (h-gw) is not in its space');
    expect(gone.code?.code, 'ZS-1808');
    expect(gone.reconnectCannotHelp, isTrue);
  });

  // 4.0: an RDP host opens through the same bridge as a VNC
  // screen, and the engine is told it is RDP (never spoken VNC to: the VNC
  // engine would offer the host's key in VNC's own way).
  Future<void> carrierAndRdp({String keyUser = 'alex', String? options, bool withKey = true}) async {
    await host('h-gw', 'gw', 'gw.example.com', keyId: await key('deploy', username: 'deploy', password: 'ssh-pass'));
    await host('r-pc', 'office-pc', 'localhost',
        protocol: 'rdp',
        port: 3389,
        via: 'h-gw',
        options: options,
        keyId: withKey ? await key('pc', username: keyUser, password: 'win-pass') : null);
  }

  test('an RDP host that asks for three displays: the engine is told three, each the size a session starts at, '
      'side by side; a host with one tells none', () async {
    await start();
    await carrierAndRdp(options: const ScreenOptions(displays: 3).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final request = engine.sessions.single.request;
    expect(request['displays'], [
      {'x': 0, 'y': 0, 'width': 1280, 'height': 800, 'primary': true},
      {'x': 1280, 'y': 0, 'width': 1280, 'height': 800},
      {'x': 2560, 'y': 0, 'width': 1280, 'height': 800},
    ]);
    expect(request.containsKey('width'), isFalse, reason: 'the displays say the size');
  });

  test('an RDP host with a text size: the engine is told it, for the one display or for each of several', () async {
    await start();
    await carrierAndRdp(options: const ScreenOptions(textScale: 150).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final request = engine.sessions.single.request;
    expect(request['scale'], 150);
    expect(request.containsKey('displays'), isFalse);
  });

  test('an RDP host with a text size and two displays: each display carries it', () async {
    await start();
    await carrierAndRdp(options: const ScreenOptions(textScale: 200, displays: 2).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(engine.sessions.single.request['displays'], [
      {'x': 0, 'y': 0, 'width': 1280, 'height': 800, 'scale': 200, 'primary': true},
      {'x': 1280, 'y': 0, 'width': 1280, 'height': 800, 'scale': 200},
    ]);
  });

  test("an RDP host plays the remote's sound on a computer unless its person turned it off; silent until a view "
      'says it is seen', () async {
    await start();
    await carrierAndRdp();
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    var id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(engine.sessions.single.request['rdp_sound'], 'off', reason: 'asked for, and silent at the start');
    expect(engine.sessions.single.sounds, isEmpty, reason: 'no view has said it is seen');
    await sessions().endSession(id);
  });

  test("an RDP host whose person turned the remote's sound off: the server is told there is none here", () async {
    await start();
    await carrierAndRdp(options: const ScreenOptions(sound: false).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(engine.sessions.single.request.containsKey('rdp_sound'), isFalse);
    await sessions().endSession(id);
  });

  test('an RDP host whose person turned relative mouse on: the engine is told to ask the server for it', () async {
    await start();
    await carrierAndRdp(options: const ScreenOptions(relativeMouse: true).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(engine.sessions.single.request['rdp_relative_mouse'], isTrue);
  });

  test('an RDP host through its carrier: a direct-tcpip channel to localhost:3389, and the engine told RDP with NLA, '
      "the account with its domain apart, and the server's name", () async {
    await start();
    await carrierAndRdp(keyUser: r'CORP\alex');
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    expect(sessions().isScreen(id), isTrue);
    await server.letIn();
    final (open1, _) = await channelAsked();
    expect(open1.channelType, 'direct-tcpip');
    expect((open1.host, open1.port), ('localhost', 3389));
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(dialled, ['gw.example.com:22']);
    final request = engine.sessions.single.request;
    expect(request['kind'], 'rdp');
    expect(request['username'], 'alex');
    expect(request['domain'], 'CORP');
    expect(request['password'], 'win-pass');
    // A host of the person's own: the session has the clipboard's channel, shared once a view
    // of it says so.
    expect(request['rdp_clipboard'], 'off');
    // Graphics left at Auto: the pipeline, without H.264.
    expect((request['rdp_graphics'], request['rdp_h264']), ('gfx', 'off'));
    expect(request['rdp_nla'], isTrue);
    expect(request['server_name'], 'localhost');
    expect(request['rdp_graphics'], 'gfx');
    expect(request['rdp_h264'], 'off');
    expect(request.containsKey('encodings'), isFalse, reason: "VNC's");
    expect(request.containsKey('displays'), isFalse, reason: 'one display: the request of before');
    expect(request.containsKey('rdp_relative_mouse'), isFalse, reason: 'not asked for unless the host says so');
    expect(request.containsKey('scale'), isFalse, reason: 'no text size said: the remote keeps its own');
    expect(stateOf(id)!.connectionLog.join('\n'), contains('Connected (RDP, NLA)'));
    expect(stateOf(id)!.connectionLog.join('\n'), isNot(contains('win-pass')));
    await sessions().endSession(id);
  });

  test("a team's log of an RDP session says RDP, how it connected and the account of its key that signed in; "
      'never a password, and no word of VNC', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    await start();
    await carrierAndRdp(keyUser: r'CORP\alex');
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    // (As a session of a vault that logs sessions is, before anything of it is shown.)
    TeamSessionLogs.expect(id);
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    expect((shell.keyAccount, shell.signedInAs), (r'CORP\alex', r'CORP\alex'));
    final log = TeamSessionLogs.debugWaiting(id)!;
    expect(log.split('\n').take(3), [
      '[remote screen (RDP): who, the host, the account and when are logged; the picture, keys and clipboard are not]',
      '[remote screen: connected through its SSH host]',
      r'[remote screen: signed in as CORP\alex]',
    ]);
    expect(log, isNot(contains('win-pass')));
    expect(log, isNot(contains('VNC')));
    await sessions().endSession(id);
  });

  test('an RDP session without NLA names no account in its team\'s log: the server\'s own sign-in screen knows who, '
      'not the app', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    await start();
    await carrierAndRdp(options: const ScreenOptions(nla: false).encode());
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    TeamSessionLogs.expect(id);
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    expect((shell.keyAccount, shell.signedInAs), (null, null));
    final log = TeamSessionLogs.debugWaiting(id)!;
    expect(log, contains('[remote screen (RDP):'));
    expect(log, isNot(contains('signed in as')));
    await sessions().endSession(id);
  });

  test('an RDP host that signs in without NLA: the engine is told so and given no password; its graphics choice goes '
      'with it', () async {
    await start();
    await carrierAndRdp(options: '{"v":1,"nla":false,"graphics":"basic"}');
    engine.onOpen = (s) => s.connect(name: 'office-pc');
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final request = engine.sessions.single.request;
    expect(request['kind'], 'rdp');
    expect(request['rdp_nla'], isFalse);
    expect(request.containsKey('password'), isFalse, reason: 'the server shows its own sign-in screen');
    expect(request['username'], 'alex', reason: 'the name alone');
    expect(request['rdp_graphics'], 'bitmap');
    expect(stateOf(id)!.connectionLog.join('\n'), contains('Connected (RDP, without NLA)'));
    await sessions().endSession(id);
  });

  test('an RDP host whose server has no NLA says so, with the switch to turn on and ZS-1813; the engine is asked once',
      () async {
    await start();
    await carrierAndRdp();
    engine.onOpen = (s) => s.closeWith('protocol', 'connection request: negotiation failure', extra: {'detail': 'nla_missing'});
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the RDP host to be refused');
    expect(stateOf(id)!.errorMessage,
        allOf(contains('no Network Level Authentication'), contains('Sign in without NLA'), contains('ZS-1813')));
    expect(engine.sessions, hasLength(1), reason: 'not tried again by itself');
  });

  test('an RDP host set to sign in without NLA whose server insists on it says ZS-1814', () async {
    await start();
    await carrierAndRdp(options: '{"v":1,"nla":false}');
    engine.onOpen = (s) => s.closeWith('protocol', 'connection request: negotiation failure', extra: {'detail': 'nla_required'});
    final id = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the RDP host to be refused');
    expect(stateOf(id)!.errorMessage, allOf(contains('Turn off'), contains('Sign in without NLA'), contains('ZS-1814')));
    expect(engine.sessions.single.request.containsKey('password'), isFalse);
  });

  test('an RDP session its server ends says why where the ended session is shown, with its code where it has one; '
      'it is not connected again by itself, and a new connection forgets the reason', () async {
    await start();
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(hours: 1);
    await carrierAndRdp();
    engine.onOpen = (s) => s.connect(name: 'office-pc');

    Future<String> endedWith(String? detail, String message) async {
      final id = await open('r-pc');
      await server.letIn();
      await channelAsked();
      await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
      expect(sessions().isRdpScreen(id), isTrue);
      expect(sessions().screenEndOf(id), isNull);
      engine.sessions.last.closeWith('server_closed', message, extra: {'detail': ?detail});
      await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the RDP session to end');
      expect(stateOf(id)!.isReconnecting, isFalse);
      return id;
    }

    // Idle too long: the app's own sentence, no code (nothing is wrong on this side).
    final idle = await endedWith('idle', 'the server ended the session: [Protocol independent error] idle');
    expect(sessions().screenEndOf(idle)?.kind, ScreenFailureKind.rdpEnded);
    expect(dropSaid(en, stateOf(idle)!, 'office-pc', screenEnd: sessions().screenEndOf(idle)).sentence,
        en.screenRdpEndedIdle);
    // Without the reason the same state says what any ended session says.
    expect(dropSaid(en, stateOf(idle)!, 'office-pc').sentence, en.sessionEndedByHost('office-pc'));
    await sessions().endSession(idle);
    expect(sessions().screenEndOf(idle), isNull);
    expect(sessions().isRdpScreen(idle), isFalse);

    // The account signed in elsewhere: its code, and never tried again by itself.
    server = PlayedServer();
    final taken = await endedWith('replaced', 'the server ended the session: another user connected');
    final said = dropSaid(en, stateOf(taken)!, 'office-pc', screenEnd: sessions().screenEndOf(taken)).sentence;
    expect(said, allOf(contains(en.screenRdpTakenOver), contains('ZS-1819')));
    await sessions().endSession(taken);

    // No reason given: nothing kept, and the ended session is said as any is.
    server = PlayedServer();
    final plain = await endedWith(null, 'the server ended the session: server initiated disconnect');
    expect(sessions().screenEndOf(plain), isNull);
    await sessions().endSession(plain);
  });

  test('a VNC screen is no RDP screen, and its end keeps no reason whatever the engine says with it', () async {
    await start();
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(hours: 1);
    await carrierAndScreen();
    engine.onOpen = (s) => s.connect();
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    expect((sessions().isScreen(id), sessions().isRdpScreen(id)), (true, false));
    engine.sessions.single.closeWith('server_closed', 'the server closed the connection', extra: {'detail': 'idle'});
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the screen to end');
    expect(sessions().screenEndOf(id), isNull);
  });

  test('an RDP host that does not open keeps what its server said: nothing at its address names RDP, and a '
      'connection the server refuses for a reason it names says that reason', () async {
    await start();
    await carrierAndRdp();
    final id = await open('r-pc');
    await server.letIn();
    await refuseChannel(SSH_Message_Channel_Open_Failure.codeConnectFailed);
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the RDP host to fail');
    expect(stateOf(id)!.errorMessage,
        allOf(contains('the RDP server is not running'), contains('localhost:3389 on gw'), contains('ZS-1801'), isNot(contains('VNC'))));
    await sessions().endSession(id);

    // The server ends the connection at once and says why (nobody may connect now): the reason,
    // not only "The server ended the session."
    server = PlayedServer();
    engine.onOpen = (s) => s.closeWith('server_closed', 'the server ended the session: denied', extra: {'detail': 'denied'});
    final id2 = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id2)?.status == SessionStatus.error, 'the RDP host to be refused');
    expect(stateOf(id2)!.errorMessage, allOf(contains(en.screenRdpEndedDenied), isNot(contains(en.screenRdpServerEnded))));
  });

  test('an RDP host with NLA and no key, opened with nobody there, is stopped before anything is dialled', () async {
    await start();
    await carrierAndRdp(withKey: false);
    final id = sessions().startSession((await tree.connectionsDao.getById('r-pc'))!, unattended: true)!;
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the RDP host to be stopped');
    expect(stateOf(id)!.errorMessage, contains('no key with a user name'));
    expect(dialled, isEmpty, reason: 'not even its carrier');
    expect(engine.sessions, isEmpty);
    expect(container.read(passwordPromptProvider), isNull, reason: 'nobody to ask');
  });

  test('an RDP host with NLA and no key asks for the account, user name and password together, before the engine '
      'is started; the name is taken apart as a key\'s is; refused, it is asked again with why', () async {
    await start();
    await carrierAndRdp(withKey: false);
    var tries = 0;
    engine.onOpen = (s) {
      tries++;
      if (tries == 1) {
        s.closeWith('auth', 'the server refused the sign-in');
      } else {
        s.connect(name: 'office-pc');
      }
    };
    final id = await open('r-pc');
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    TeamSessionLogs.expect(id);
    await server.letIn();
    await until(() => container.read(passwordPromptProvider) != null, 'the account to be asked for');
    final first = container.read(passwordPromptProvider)!;
    expect((first.askUsername, first.username, first.offerSave), (true, '', false));
    expect(first.errorHint, en.screenRdpAccountWhy);
    expect(engine.sessions, isEmpty, reason: 'nothing is sent before the account is known');
    container.read(passwordPromptProvider.notifier).state = null;
    first.completer.complete(const PasswordPromptResult(password: 'wrong-one', username: r' CORP\alex '));
    await channelAsked();
    await until(() => engine.sessions.length == 1, 'the first try');
    expect(engine.sessions.first.request['username'], 'alex');
    expect(engine.sessions.first.request['domain'], 'CORP');
    expect(engine.sessions.first.request['password'], 'wrong-one');

    // Refused: both are asked for again, saying so.
    await until(() => container.read(passwordPromptProvider) != null, 'the account to be asked for again');
    final again = container.read(passwordPromptProvider)!;
    expect((again.askUsername, again.errorHint), (true, en.screenRdpAccountAgain));
    container.read(passwordPromptProvider.notifier).state = null;
    again.completer.complete(const PasswordPromptResult(password: 'right-one', username: 'alex@corp.example'));
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the RDP host to connect');
    final request = engine.sessions.last.request;
    expect((request['username'], request['domain'], request['password']), ('alex@corp.example', null, 'right-one'));
    // Its team's log names the account the server let in, the one typed last, and neither password.
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    expect((shell.keyAccount, shell.signedInAs), (null, 'alex@corp.example'));
    final log = TeamSessionLogs.debugWaiting(id)!;
    expect(log, contains('[remote screen: signed in as alex@corp.example]'));
    expect(log, isNot(contains('CORP')), reason: 'the account that was refused is not said');
    expect(log, isNot(anyOf(contains('right-one'), contains('wrong-one'))));
  });

  test("an RDP host whose key has no saved password: the key's own question asks for it before anything is dialled, "
      'with no word of VNC; a sign-in the server refuses for a reason it names is not asked about again', () async {
    await start();
    await host('h-gw', 'gw', 'gw.example.com', keyId: await key('deploy', username: 'deploy', password: 'ssh-pass'));
    await host('r-pc', 'office-pc', 'localhost',
        protocol: 'rdp', port: 3389, via: 'h-gw', keyId: await key('pc', username: 'alex'));
    engine.onOpen = (s) => s.closeWith('auth', 'the server refused the sign-in', extra: {'detail': 'account_locked'});
    final id = await open('r-pc');
    // (The carrier is let in while the question waits: the server answers when asked.)
    unawaited(server.letIn());
    await until(() => container.read(passwordPromptProvider) != null, 'the password to be asked for');
    final asked = container.read(passwordPromptProvider)!;
    expect((asked.askUsername, asked.username), (false, 'alex'));
    expect(asked.errorHint ?? '', isNot(contains('VNC')));
    expect(engine.sessions, isEmpty);
    container.read(passwordPromptProvider.notifier).state = null;
    asked.completer.complete(const PasswordPromptResult(password: 'p'));
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the locked account to be said');
    expect(stateOf(id)!.errorMessage, allOf(contains(en.screenRdpAccountLocked), contains('ZS-1815')));
    expect(engine.sessions, hasLength(1), reason: 'another password cannot help a locked account');
    expect(container.read(passwordPromptProvider), isNull);
  });

  test('a team\'s rule "remote screens through SSH only": a screen that connects directly is refused before anything '
      'is dialled or asked (ZS-1821), VNC and RDP alike, and not tried again; through its SSH host it opens; the rule '
      'the server tells a held-back account holds as well', () async {
    await start(team: true);
    await _team(tree);
    await carrierAndScreen();
    await host('s-direct', 'lab', 'lab.example.com', protocol: 'vnc', port: 5900);
    await host('r-direct', 'pc', 'pc.example.com', protocol: 'rdp', port: 3389);
    await _teamRules(tree, const RecordRules(screensSshOnly: true));
    expect(await screenTeamRulesIn(tree), const ScreenTeamRules(sshOnly: true));

    Future<void> refused(String hostId) async {
      final id = await open(hostId);
      await until(() => stateOf(id)?.status == SessionStatus.error, '$hostId to be refused');
      expect(stateOf(id)!.errorMessage,
          allOf(contains('through an SSH host only'), contains('"Reach through"'), contains('ZS-1821')),
          reason: hostId);
      expect(stateOf(id)!.isReconnecting, isFalse, reason: 'connecting again cannot help');
      await sessions().endSession(id);
    }

    await refused('s-direct');
    await refused('r-direct');
    // A Proxmox guest's console (4.0) is not through an SSH host either: refused
    // before its account is read or the API asked.
    var consoleAsked = false;
    sessions().debugOpenConsole = ({required base, required token, required guest, pin}) async {
      consoleAsked = true;
      throw StateError('not asked');
    };
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-vm',
          label: 'web-vm',
          host: '10.50.0.20',
          createdAt: at,
          updatedAt: at,
          cloudSource: const Value('{"v":1,"p":"proxmox","id":"pve.example.test:8006/pve/100"}'),
        ));
    final console = sessions().startConsole((await tree.connectionsDao.getById('h-vm'))!)!;
    await until(() => stateOf(console)?.status == SessionStatus.error, 'the console to be refused');
    expect(stateOf(console)!.errorMessage, contains('ZS-1821'));
    expect(consoleAsked, isFalse);
    await sessions().endSession(console);
    expect(dialled, isEmpty);
    expect(engine.sessions, isEmpty);
    expect(asked, isEmpty);

    // The same team's screen through its SSH host opens as ever.
    engine.onOpen = (s) => s.connect(name: 'desk', width: 800, height: 600, security: 'VncAuth');
    final through = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(through)?.status == SessionStatus.connected, 'the screen through its SSH host');
    expect(dialled, ['gw.example.com:22']);
    await sessions().endSession(through);

    // The copy of the rules kept beside the record does not name the rule (a version from before
    // it wrote that copy, or a refresh stopped before writing it): the record itself decides.
    await tree.customStatement('UPDATE orchard_info SET rules = ? WHERE id = 1', [jsonEncode(RecordRules.none.toBody())]);
    expect(await screenTeamRulesIn(tree), const ScreenTeamRules(sshOnly: true));
    await tree.customStatement('UPDATE orchard_info SET rules = NULL WHERE id = 1');
    expect(await screenTeamRulesIn(tree), const ScreenTeamRules(sshOnly: true));
    await refused('s-direct');
    expect(dialled, ['gw.example.com:22'], reason: 'nothing more was dialled');

    // The record as this device last read it has no such rule, and the server, holding this
    // account back by another rule, says it is in force: it holds.
    await _teamRules(tree, RecordRules.none);
    expect(await screenTeamRulesIn(tree), ScreenTeamRules.none);
    await tree.customStatement('UPDATE orchard_info SET held = ? WHERE id = 1', [
      jsonEncode({
        'unmet': ['two_step'],
        'device_rules': const RecordRules(noExport: true, screensSshOnly: true).toBody(),
      }),
    ]);
    expect(await screenTeamRulesIn(tree), const ScreenTeamRules(sshOnly: true));
    engine.sessions.clear();
    dialled.clear();
    await refused('s-direct');
    expect(dialled, isEmpty);
    expect(engine.sessions, isEmpty);

    // Off again (and what the server tells is never read as a rule of another kind).
    await tree.customStatement('UPDATE orchard_info SET held = ? WHERE id = 1', [
      jsonEncode({'device_rules': {'screens_ssh_only': 'true', 'screens_lock_redirections': 1}}),
    ]);
    expect(await screenTeamRulesIn(tree), ScreenTeamRules.none);
  });

  test('a team\'s rule that shares nothing with remote screens: the clipboard is locked off whatever the host and '
      'this device say, and an RDP session is given no clipboard channel; without the rule the same host has one',
      () async {
    await start(team: true);
    await _team(tree);
    // The host's own setting: clipboard on, and members may turn it on.
    await carrierAndRdp(options: const ScreenOptions(clipboard: true).encode());
    await _teamRules(tree, RecordRules.none);
    expect(await screenTeamRulesIn(tree), ScreenTeamRules.none);
    engine.onOpen = (s) => s.connect(name: 'office-pc');

    final before = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(before)?.status == SessionStatus.connected, 'the RDP host to connect');
    expect(engine.sessions.single.request['rdp_clipboard'], 'off', reason: 'a channel, shared once a view says so');
    final open1 = stateOf(before)!.session!.shell as ScreenShellService;
    expect(open1.options.clipboardTogglable(inTeam: open1.inTeam), isTrue);
    await sessions().endSession(before);

    // An owner turns the rule on: it holds from the next time the screen is opened.
    await _teamRules(tree, const RecordRules(screensLockRedirections: true));
    expect(await screenTeamRulesIn(tree), const ScreenTeamRules(lockRedirections: true));
    server = PlayedServer();
    engine.sessions.clear();
    final after = await open('r-pc');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(after)?.status == SessionStatus.connected, 'the RDP host to connect under the rule');
    expect(engine.sessions.single.request['rdp_clipboard'], 'none', reason: 'the server has nothing to ask through');
    final shell = stateOf(after)!.session!.shell as ScreenShellService;
    expect(shell.inTeam, isTrue);
    expect(shell.options.clipboardTogglable(inTeam: shell.inTeam), isFalse, reason: 'no view offers its switch');
    expect(screenClipboardOn(shell.options, inTeam: true, deviceChoice: 'on'), isFalse,
        reason: "this device's own choice for the host does not turn it on");
    // The host's saved options are not changed by it.
    final saved = ScreenOptions.decode((await tree.connectionsDao.getById('r-pc'))!.screenOptions);
    expect((saved.clipboard, saved.clipboardLocked), (true, false));
    await sessions().endSession(after);
  });

  test('your own space has neither rule, whatever a database of it holds', () async {
    await start();
    expect(await screenTeamRulesIn(tree), ScreenTeamRules.none);
  });

  test('a screen in a watched vault is refused before anything is dialled or asked (ZS-1807)', () async {
    await start(team: true);
    await _watch(tree, 's-desk');
    await carrierAndScreen();
    final id = await open('s-desk');
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the screen to be refused');
    expect(stateOf(id)!.errorMessage, allOf(contains('cannot be watched yet'), contains('ZS-1807')));
    expect(dialled, isEmpty);
    expect(engine.sessions, isEmpty);
  });

  test('the VNC server ends the session: it stays, ended, and is not connected again by itself; a dropped '
      'carrier is connected again as a terminal is', () async {
    await start();
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(hours: 1);
    await carrierAndScreen();
    engine.onOpen = (s) => s.connect();
    final id = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the screen to connect');
    final shell = stateOf(id)!.session!.shell as ScreenShellService;
    engine.sessions.single.closeWith('server_closed', 'the server closed the connection');
    await until(() => stateOf(id)?.status == SessionStatus.disconnected, 'the screen to end');
    expect(shell.exitedCleanly, isTrue);
    expect(shell.closedWith!.message, 'the server closed the connection');
    expect(stateOf(id)!.isReconnecting, isFalse);
    expect(screenFailureText(en, const ScreenFailure(ScreenFailureKind.serverEnded, 'x')),
        'The VNC server ended the session.');
    await sessions().endSession(id);

    server = PlayedServer();
    final id2 = await open('s-desk');
    await server.letIn();
    await channelAsked();
    await until(() => stateOf(id2)?.status == SessionStatus.connected, 'the second screen to connect');
    engine.sessions.last.closeWith('ssh', 'SSH: the connection ended');
    await until(() => stateOf(id2)?.status == SessionStatus.disconnected, 'the screen to drop');
    expect(stateOf(id2)!.isReconnecting, isTrue);
    await sessions().endSession(id2);
  });
}

/// The team's rules as this device keeps them once it read the record
/// (orchard_info.rules), for a member the server does not hold back.
Future<void> _teamRules(AppDatabase db, RecordRules rules) async {
  final team = _teams[db]!;
  final entry = await signRecordEntry(team.keys,
      orchardId: team.orchard,
      seq: team.chain.length + 1,
      prev: team.chain.last.hash(team.orchard),
      type: RecordTypes.rulesSet,
      body: rules.toSetBody(),
      by: team.owner);
  team.chain.add(entry);
  await (await LocalRecord.load(db, team.orchard)).extend(db, [entry]);
  await db.customStatement('UPDATE orchard_info SET rules = ?, held = NULL WHERE id = 1', [jsonEncode(rules.toBody())]);
}

/// What [_team] made in a database, for the entries that follow.
class _TeamSpace {
  _TeamSpace(this.orchard, this.owner, this.keys, this.chain);

  final String orchard;
  final String owner;
  final AccountKeys keys;
  final List<RecordEntry> chain;
}

final _teams = Expando<_TeamSpace>('the team set up in a test database');

/// The screen [hostId] of [db] in a vault whose sessions are watched.
Future<void> _watch(AppDatabase db, String hostId) => _team(db, watchedHost: hostId);

/// [db] as a team's space with one vault, this account its owner; with
/// [watchedHost], that host in the vault and the vault's sessions watched.
Future<void> _team(AppDatabase db, {String? watchedHost}) async {
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
  if (watchedHost != null) await add(RecordTypes.crateSet, {'id': crate, 'watched': true, 'allow': <String>[]});
  await db.customStatement(
      'INSERT INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id) '
      "VALUES (1, ?, 'Acme', 'owner', 1, ?)",
      [orchard, crate]);
  await LocalRecord.empty(orchard).extend(db, chain);
  _teams[db] = _TeamSpace(orchard, owner, keys, chain);
  await db.customStatement(
      "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'Production', 'manage', ?, 1)",
      [crate, jsonEncode(switchList(CrateSwitches.all))]);
  if (watchedHost != null) await CratePlacement(db).place('host', watchedHost, crate);
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
