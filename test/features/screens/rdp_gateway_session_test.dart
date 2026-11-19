// Remote screens (4.0): an RDP host reached through an RD
// Gateway, as the app opens it. The socket goes to the gateway, the engine is
// told the gateway, the PC and the gateway's sign-in (the PC's own, or a key
// of its own), the gateway's certificate is asked about and kept under its own
// address apart from the PC's, its refusals say what they are with ZS-1822 to
// ZS-1827, and a host that names a gateway is never opened without it (the
// switch off, a gateway this version cannot read, an SSH host chosen too).
import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart' show ScreenChannel;
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';

const _gatewaySha = 'ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56ef56';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase tree;
  late ProviderContainer container;
  late FakeScreenNative engine;
  late List<String> dialled;
  late List<HostKeyVerification> asked;

  Future<void> start({bool offered = true}) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      rdpGatewayOfferedProvider.overrideWithValue(offered),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    engine = FakeScreenNative();
    dialled = [];
    final sessions = container.read(activeSessionsProvider.notifier)
      ..debugScreenNative = engine
      ..debugOpenScreenSocket = (host, port) async {
        dialled.add('$host:$port');
        return ScreenChannel(StreamController<Uint8List>().stream, StreamController<List<int>>());
      };
    expect(sessions.debugScreenNative, engine);
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

  final at = DateTime(2026, 11, 16);
  Future<void> pc(String id, {required ScreenOptions options, String? keyId, String? via, String? rawOptions}) =>
      tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: 'office pc',
            host: 'pc1.example.test',
            port: const Value(3389),
            protocol: const Value('rdp'),
            identityId: Value(keyId),
            connectViaId: Value(via),
            screenOptions: Value(rawOptions ?? options.encode()),
            createdAt: at,
            updatedAt: at,
          ));

  Future<String> open(String id) async => sessions().startSession((await tree.connectionsDao.getById(id))!)!;

  const through = ScreenOptions(gateway: ScreenGateway(host: 'rdg.example.test'));

  test('with the PC\'s own sign-in: the socket goes to the gateway, the engine is told the gateway, the PC and the '
      'account; the gateway\'s certificate is asked about under its own address and kept apart from the PC\'s', () async {
    await start();
    await pc('r1', options: through, keyId: await key('pc', username: r'EXAMPLE\alex', password: 'pc-pass'));
    engine.onOpen = (s) {
      final gw = s.request['rdp_gateway'] as Map;
      if (gw['tls_pin'] != _gatewaySha) {
        s.closeWith('certificate', 'certificate not trusted', extra: {
          'detail': 'gateway',
          'sha256': _gatewaySha,
          'der': base64.encode([0x30, 0x03, 0x02, 0x01, 0x01]),
          'subject': 'CN=rdg.example.test',
          'not_before': 1794086665,
          'not_after': 4950000000,
        });
      } else {
        s.connect(name: 'pc1', width: 1280, height: 800, security: 'TLS');
      }
    };
    final id = await open('r1');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session through the gateway');
    expect(dialled, ['rdg.example.test:443', 'rdg.example.test:443'], reason: 'the gateway, never the PC');
    final request = engine.sessions.last.request;
    expect(request['rdp_gateway'], {
      'host': 'rdg.example.test',
      'port': 443,
      'tls_pin': _gatewaySha,
      'username': 'alex',
      'password': 'pc-pass',
      'domain': 'EXAMPLE',
      'target': 'pc1.example.test',
      'target_port': 3389,
    });
    expect(request['server_name'], 'pc1.example.test');
    expect(request['tls_pin'], isNull, reason: "the PC's own pin is not the gateway's");
    final question = asked.single;
    expect((question.host, question.port), ('rdg.example.test', 443));
    expect(question.name, en.screenGatewayCertificateName('office pc'));
    final log = stateOf(id)!.connectionLog.join('\n');
    expect(log, contains('through the RD Gateway rdg.example.test'));
    expect(log, isNot(contains('pc-pass')));
    await sessions().endSession(id);
  });

  test('with a key of its own, the gateway signs in with that key\'s account, and its refusal says so (ZS-1822)',
      () async {
    await start();
    final gwKey = await key('gateway', username: 'gw-account@example.test', password: 'gw-pass');
    await pc('r2',
        options: ScreenOptions(gateway: ScreenGateway(host: 'rdg.example.test', port: 8443, keyId: gwKey)),
        keyId: await key('pc', username: 'alex', password: 'pc-pass'));
    engine.onOpen = (s) => s.closeWith('auth', 'RD Gateway: the gateway refused the sign-in', extra: {'detail': 'gateway_sign_in'});
    final id = await open('r2');
    await until(() => stateOf(id)?.status == SessionStatus.error, 'the refusal');
    expect(dialled, ['rdg.example.test:8443']);
    final gw = engine.sessions.single.request['rdp_gateway'] as Map;
    // A name@domain account goes as it is written (NTLM takes it so), as the PC's does.
    expect((gw['username'], gw['password'], gw['port'], gw['domain']), ('gw-account@example.test', 'gw-pass', 8443, null));
    expect(engine.sessions.single.request['username'], 'alex');
    expect(stateOf(id)!.errorMessage, allOf(contains(en.screenGatewaySignInRefused(en.connectionEditScreenVia)), contains('ZS-1822')));
    expect(stateOf(id)!.isReconnecting, isFalse);
    expect(container.read(passwordPromptProvider), isNull, reason: "the key's account is not asked for");
    await sessions().endSession(id);
  });

  test('the gateway\'s refusals each say what they are, with their code', () async {
    await start();
    final keyId = await key('pc', username: 'alex', password: 'pc-pass');
    for (final (detail, reason, text, code) in [
      ('gateway_not_allowed', 'auth', en.screenGatewayNotAllowed, 'ZS-1823'),
      ('gateway_target', 'network', en.screenGatewayTarget, 'ZS-1824'),
      ('gateway_consent', 'protocol', en.screenGatewayUnsupported, 'ZS-1825'),
      ('gateway_none', 'protocol', en.screenGatewayRefused, 'ZS-1826'),
    ]) {
      final hostId = 'r-$detail';
      await pc(hostId, options: through, keyId: keyId);
      engine.onOpen = (s) => s.closeWith(reason, 'RD Gateway: $detail', extra: {'detail': detail});
      final id = await open(hostId);
      await until(() => stateOf(id)?.status == SessionStatus.error || stateOf(id)?.isReconnecting == true, detail);
      expect(stateOf(id)!.errorMessage, allOf(contains(text), contains(code)), reason: detail);
      await sessions().endSession(id);
    }
  });

  test("the PC's certificate through a gateway is asked about and kept for that route, and the team rule on where a "
      "password goes sees the gateway's address", () async {
    await start();
    await pc('r-route', options: through, keyId: await key('pc', username: 'alex', password: 'pc-pass'));
    engine.onOpen = (s) {
      if (s.request['tls_pin'] != 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12') {
        s.closeWith('certificate', 'certificate not trusted', extra: {
          'sha256': 'ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12ab12',
          'der': base64.encode([0x30, 0x03, 0x02, 0x01, 0x01]),
          'subject': 'CN=pc1.example.test',
          'not_before': 1794086665,
          'not_after': 4950000000,
        });
      } else {
        s.connect(name: 'pc1', width: 1280, height: 800, security: 'TLS');
      }
    };
    final id = await open('r-route');
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session');
    final question = asked.single;
    expect((question.host, question.port), ('pc1.example.test', 3389));
    expect(question.via, 'rdg.example.test', reason: 'asked about as the PC behind that gateway');
    final known = await tree.knownHostsDao.findAllForHostPortAnyRoute('pc1.example.test', 3389);
    expect(known.single.viaScope, 'rdg.example.test:443', reason: "kept for the route, not the PC's bare address");
    await sessions().endSession(id);

    final row = (await tree.connectionsDao.getById('r-route'))!;
    expect(await screenCarrierRouteIn(tree, row), (id: null, via: 'rdg.example.test:443'));
  });

  test('a host that names a gateway is never opened without it: the switch off, a gateway this version cannot read, '
      'or an SSH host chosen too, each refused with ZS-1827 before anything is dialled', () async {
    Future<void> refused(String hostId) async {
      final id = await open(hostId);
      await until(() => stateOf(id)?.status == SessionStatus.error, hostId);
      expect(stateOf(id)!.errorMessage, allOf(contains(en.screenGatewayUnavailable), contains('ZS-1827')), reason: hostId);
      expect(stateOf(id)!.isReconnecting, isFalse, reason: hostId);
      await sessions().endSession(id);
      expect(dialled, isEmpty, reason: hostId);
      expect(engine.sessions, isEmpty, reason: hostId);
      expect(asked, isEmpty, reason: hostId);
    }

    await start(offered: false);
    await pc('off', options: through, keyId: await key('pc', username: 'alex', password: 'pc-pass'));
    await refused('off');
    container.dispose();
    await tree.close();

    await start();
    final keyId = await key('pc', username: 'alex', password: 'pc-pass');
    await pc('unreadable', options: ScreenOptions.defaults, keyId: keyId, rawOptions: '{"v":1,"gateway":{"host":"bad host"}}');
    await refused('unreadable');
    // A gateway and an SSH host to reach it through: not in this version.
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-gw',
          label: 'gw',
          host: 'gw.example.test',
          createdAt: at,
          updatedAt: at,
        ));
    await pc('both', options: through, keyId: keyId, via: 'h-gw');
    await refused('both');
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

/// No networks are set up here: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
