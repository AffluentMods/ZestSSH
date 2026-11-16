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
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
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

/// A host's saved forwards with more than one of its sessions open (3.0,
/// found while checking a list of suspected faults in signing in). A forward
/// set to start with the connection was started by every session of the
/// host that connected: the second found its port taken, and said that the
/// forward could not be started. And a forward started by hand went to
/// whichever of the host's sessions came first, so it ran as the account
/// that one was opened with (Connect as), where the host's own account had a
/// session open too.
///
/// The host is played on the loopback address, its key trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late ProviderContainer container;
  late _Place place;
  late PlayedHostKey shows;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem, 'identity_key_id-root': keyPem});
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
    place = await _Place.bind();
    addTearDown(place.close);
    shows = PlayedHostKey.ed25519();
    await KnownHostsService(tree.knownHostsDao)
        .trustHost(place.host, place.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    final at = DateTime(2026, 10, 16);
    for (final (id, user) in [('id-deploy', 'deploy'), ('id-root', 'root')]) {
      await tree.into(tree.identities).insert(
          IdentitiesCompanion.insert(id: id, label: '$user key', username: user, authMethod: 'publicKey', createdAt: at));
    }
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: place.host,
          port: Value(place.port),
          identityId: const Value('id-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
    // root is one of the host's other accounts (Connect as).
    await tree.into(tree.hostAccounts).insert(
        HostAccountsCompanion.insert(connectionId: 'h-web', identityId: 'id-root', position: 0));
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

  /// A port nothing listens on, for a forward to take.
  Future<int> freePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  Future<void> forward(String id, int port, {required bool withTheConnection}) =>
      tree.into(tree.portForwardRules).insert(PortForwardRulesCompanion.insert(
            id: id,
            connectionId: 'h-web',
            type: 'local',
            bindPort: port,
            remoteHost: 'localhost',
            remotePort: 5432,
            autoStart: Value(withTheConnection),
            createdAt: DateTime(2026, 10, 16),
          ));

  /// A session of web-01 (as [account] where given), signed in to and its
  /// shell open.
  Future<String> connected({String? account, bool beside = false}) async {
    final host = (await tree.connectionsDao.getById('h-web'))!;
    final id = sessions().startSession(host, allowDuplicate: beside, asAccount: account)!;
    final server = PlayedServer(line: await place.line(), hostKey: shows);
    await server.greet();
    expect(await PlayedSignIn(ways: ['publickey'], takesKey: true).play(server, over: () => over(id)), isTrue,
        reason: '${stateOf(id)?.connectionLog}');
    await PlayedSignIn.openShell(server);
    await until(() => stateOf(id)?.status == SessionStatus.connected || over(id), 'the session');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    return id;
  }

  List<AppNotification> errorsSaid() => [
        for (final n in container.read(notificationCenterProvider).history)
          if (n.severity == NotificationSeverity.error) n,
      ];

  test('a forward set to start with the connection: started by the first session of the host, and left there by '
      'a second, which says nothing of it', () async {
    await forward('pf-db', await freePort(), withTheConnection: true);
    // Each time the forwards' state is told: once a session's own start of them is over.
    var told = 0;
    container.listen(activeForwardIdsProvider, (_, _) => told++);

    final first = await connected();
    await until(() => sessions().activeForwardRuleIds().contains('pf-db'), 'the forward up');
    final toldThen = told;
    final second = await connected(beside: true);
    await until(() => told > toldThen, "the second session's start of its forwards");

    expect(sessions().lastForwardError('pf-db'), isNull);
    expect(errorsSaid(), isEmpty);
    expect(sessions().getPortForwardService(first)!.activeForwardIds, contains('pf-db'));
    expect(sessions().getPortForwardService(second)!.activeForwardIds, isNot(contains('pf-db')));
    await sessions().endSession(second);
    await sessions().endSession(first);
  });

  test('two sessions of the host that start their forwards at the same moment: one has each up, and neither says '
      'that it could not be started', () async {
    await forward('pf-db', await freePort(), withTheConnection: true);
    final first = await connected();
    await until(() => sessions().activeForwardRuleIds().contains('pf-db'), 'the forward up');
    final second = await connected(beside: true);
    // Taken down, then started by both at once, as when two sessions of the host connect together.
    for (final id in [first, second]) {
      await sessions().getPortForwardService(id)!.stopForward('pf-db');
    }
    expect(sessions().activeForwardRuleIds(), isNot(contains('pf-db')));
    await Future.wait([
      sessions().debugAutoStartPortForwards(first, 'h-web'),
      sessions().debugAutoStartPortForwards(second, 'h-web'),
    ]);

    expect(sessions().lastForwardError('pf-db'), isNull);
    expect(errorsSaid(), isEmpty);
    expect([
      for (final id in [first, second])
        if (sessions().getPortForwardService(id)!.activeForwardIds.contains('pf-db')) id,
    ], hasLength(1));
    await sessions().endSession(second);
    await sessions().endSession(first);
  });

  test("a forward started by hand goes to the session signed in as the host's own account, where another of its "
      'accounts has one open too', () async {
    await forward('pf-web', await freePort(), withTheConnection: false);
    final asRoot = await connected(account: 'id-root');
    final rule = (await tree.portForwardRulesDao.getAll()).single;
    // With only that one open, it goes there.
    expect(await sessions().startSavedForward(rule), StartForwardResult.started);
    expect(sessions().getPortForwardService(asRoot)!.activeForwardIds, contains('pf-web'));
    await sessions().getPortForwardService(asRoot)!.stopForward('pf-web');

    final own = await connected(beside: true);
    expect(await sessions().startSavedForward(rule), StartForwardResult.started);
    expect(sessions().getPortForwardService(own)!.activeForwardIds, contains('pf-web'));
    expect(sessions().getPortForwardService(asRoot)!.activeForwardIds, isNot(contains('pf-web')));
    await sessions().endSession(own);
    await sessions().endSession(asRoot);
  });

  test('on the free tier a forward starts, with the connection and by hand: port forwarding is free '
      '(not a paid feature)', () async {
    (container.read(isProProvider.notifier) as _Pro).free();
    expect(container.read(isProProvider), isFalse);
    await forward('pf-db', await freePort(), withTheConnection: true);
    final id = await connected();
    await until(() => sessions().activeForwardRuleIds().contains('pf-db'), 'the forward up with the connection');
    await sessions().getPortForwardService(id)!.stopForward('pf-db');
    final rule = (await tree.portForwardRulesDao.getAll()).single;
    expect(await sessions().startSavedForward(rule), StartForwardResult.started);
    expect(sessions().getPortForwardService(id)!.activeForwardIds, contains('pf-db'));
    expect(errorsSaid(), isEmpty);
    await sessions().endSession(id);
  });
}

/// A place on the loopback address that takes any number of connections,
/// each a line a played server holds (a played listener takes one).
class _Place {
  _Place._(this._socket) : _incoming = StreamIterator(_socket);

  static Future<_Place> bind() async => _Place._(await ServerSocket.bind(InternetAddress.loopbackIPv4, 0));

  final ServerSocket _socket;
  final StreamIterator<Socket> _incoming;

  String get host => InternetAddress.loopbackIPv4.address;
  int get port => _socket.port;

  /// The next connection that comes.
  Future<PlayedSocketLine> line() async {
    if (!await _incoming.moveNext().timeout(PlayedServer.patience)) throw StateError('no longer listening');
    return PlayedSocketLine(_incoming.current);
  }

  Future<void> close() => _socket.close();
}

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  /// Squeezed taken away: the free tier.
  void free() => state = false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
