import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// "Connect as" (3.0, accounts per host): a session opened with one of its
/// host's other accounts signs in with that identity, and keeps it: an open
/// session is reused for the same account only; connecting again after a
/// drop, Duplicate, a split and Reconnect sign in as it did; an account taken
/// off the host since is not used again (the default is). Plain Connect signs
/// in with the host's default, as before.
void main() {
  late AppDatabase tree;
  late ProviderContainer container;
  late List<_Shell> shells;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    ActiveSessionsNotifier.debugReconnectDelay = const Duration(milliseconds: 20);
    shells = [];
    container.read(activeSessionsProvider.notifier).debugShellFor = (connection) {
      final shell = _Shell(connection.identityId);
      shells.add(shell);
      return shell;
    };
    final at = DateTime(2026, 10, 15);
    for (final (id, user) in [('i-root', 'root'), ('i-deploy', 'deploy')]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: '$user key',
            username: user,
            authMethod: 'publicKey',
            createdAt: at,
          ));
    }
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web1',
          label: 'web-01',
          host: '10.50.0.5',
          identityId: const Value('i-root'),
          createdAt: at,
          updatedAt: at,
        ));
    await tree.hostAccountsDao.setOtherAccounts('h-web1', ['i-deploy']);
  });

  tearDown(() async {
    ActiveSessionsNotifier.debugReconnectDelay = null;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];
  Future<Connection> host() async => (await tree.connectionsDao.getById('h-web1'))!;

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 15)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  Future<String> open({String? asAccount}) async {
    final id = sessions().startSession(await host(), asAccount: asAccount)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session');
    return id;
  }

  test('Connect as signs in with that account; Connect with the default', () async {
    final plain = await open();
    expect(shells.single.identityId, 'i-root');
    expect(sessions().accountOf(plain), isNull);
    final as = await open(asAccount: 'i-deploy');
    expect(as, isNot(plain));
    expect(shells.last.identityId, 'i-deploy');
    expect(sessions().accountOf(as), 'i-deploy');
  });

  test('an open session is reused for the same account only; the default named is the default', () async {
    final plain = await open();
    final as = await open(asAccount: 'i-deploy');
    expect(sessions().startSession(await host()), plain);
    expect(sessions().startSession(await host(), asAccount: 'i-deploy'), as);
    expect(sessions().startSession(await host(), asAccount: 'i-root'), plain);
    expect(shells, hasLength(2), reason: 'nothing opened a third');
  });

  test('dropped, it connects again with the same account; one taken off the host since, with the default', () async {
    final as = await open(asAccount: 'i-deploy');
    shells.last.drop();
    await until(() => shells.length == 2 && stateOf(as)?.status == SessionStatus.connected, 'connected again');
    expect(shells.last.identityId, 'i-deploy');

    await tree.hostAccountsDao.setOtherAccounts('h-web1', const []);
    shells.last.drop();
    await until(() => shells.length == 3 && stateOf(as)?.status == SessionStatus.connected, 'connected again');
    expect(shells.last.identityId, 'i-root');
    expect(sessions().accountOf(as), isNull);
  });

  test('Duplicate, a split and Reconnect sign in as the session did', () async {
    final as = await open(asAccount: 'i-deploy');
    final plain = await open();

    final copy = (await sessions().openLike(as))!;
    await until(() => stateOf(copy)?.status == SessionStatus.connected, 'the duplicate');
    expect(shells.last.identityId, 'i-deploy');
    expect(sessions().accountOf(copy), 'i-deploy');

    final split = sessions().startLike(as, await host())!;
    await until(() => stateOf(split)?.status == SessionStatus.connected, 'the split');
    expect(shells.last.identityId, 'i-deploy');

    final again = (await sessions().openAgain(as))!;
    await until(() => stateOf(again)?.status == SessionStatus.connected, 'opened again');
    expect(again, isNot(as));
    expect(shells.last.identityId, 'i-deploy');
    expect(sessions().accountOf(again), 'i-deploy');
    expect(stateOf(as)?.status, isNot(SessionStatus.connected), reason: 'the one it replaces was ended');

    final plainCopy = (await sessions().openLike(plain))!;
    await until(() => stateOf(plainCopy)?.status == SessionStatus.connected, 'a duplicate of the default');
    expect(shells.last.identityId, 'i-root');
    expect(sessions().accountOf(plainCopy), isNull);
  });

  test('Try again of a session that is gone (a phone still says why it failed): signed in as it was', () async {
    final as = await open(asAccount: 'i-deploy');
    await sessions().endSession(as);
    final again = (await sessions().openHostAgain('h-web1', account: 'i-deploy'))!;
    await until(() => stateOf(again)?.status == SessionStatus.connected, 'opened again');
    expect(shells.last.identityId, 'i-deploy');
    expect(sessions().accountOf(again), 'i-deploy');

    final own = (await sessions().openHostAgain('h-web1'))!;
    await until(() => stateOf(own)?.status == SessionStatus.connected, 'opened as its own');
    expect(shells.last.identityId, 'i-root');
    expect(sessions().accountOf(own), isNull);
  });

  test('Reconnect reads the host before the session ends: where the host is gone, the session stays as it is',
      () async {
    final as = await open(asAccount: 'i-deploy');
    await tree.connectionsDao.deleteConnection('h-web1');
    expect(await sessions().openAgain(as), isNull);
    expect(stateOf(as)?.status, SessionStatus.connected);
    expect(sessions().accountOf(as), 'i-deploy');
    expect(await sessions().openHostAgain('h-web1'), isNull);
    expect(shells, hasLength(1));
  });

  test('a session that ends forgets its account', () async {
    final as = await open(asAccount: 'i-deploy');
    await sessions().endSession(as);
    expect(sessions().accountOf(as), isNull);
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

/// A shell the test drives, with the identity the session gave it.
class _Shell extends ShellService {
  _Shell(this.identityId);

  final String? identityId;
  final _state = StreamController<bool>.broadcast();
  final _out = StreamController<Uint8List>.broadcast();
  bool _connected = false;

  void drop() {
    _connected = false;
    _state.add(false);
  }

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    _state.add(false);
  }

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;
}
