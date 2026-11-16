import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/data/host_network_overrides_repository.dart';
import 'package:zestssh/features/hosts/models/host_network_override.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/orchards/spaces.dart';
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
import '../helpers/orchard_db_fixture.dart';
import '../helpers/played_sign_in.dart';

/// A session works in its host's own space (3.0), whichever is on
/// screen: a Duplicate, a split or a Reconnect of a session of your Tree,
/// made while a team space was on screen, filed the host under that space,
/// so its key was looked for there (and not found: it signed in with
/// nothing), and the network it is on was read from the space on screen (the
/// host not found there, it connected as it is saved, not as the network
/// has it). Now each is opened in the space its session works in, and reads
/// both from there.
///
/// The hosts are played on the loopback address, and their keys trusted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late AppDatabase orchard;
  late ProviderContainer container;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    orchard = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(orchard);
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      orchardDatabasesProvider.overrideWith((ref) => _OneOrchard(orchard)),
      // The Office network, chosen by hand: no detector is asked.
      manualNetworkOverrideProvider.overrideWith((ref) => ValueNotifier<String?>('n-office')),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
        id: 'id-deploy', label: 'deploy-key', username: 'deploy', authMethod: 'publicKey', createdAt: DateTime(2026, 10, 16)));
    await NetworkRepository(tree.networksDao).create(const Network(
      id: 'n-office',
      name: 'Office',
      color: GroupColor.blue,
      icon: LucideIcons.globe,
      triggers: [AlwaysTrigger()],
      isFallback: false,
    ));
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
    await orchard.close();
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

  /// A host of your Tree played on [listener], signed in to with the Tree's
  /// key, whose key this device trusts; on the Office network it is at
  /// [office] where that is given.
  Future<PlayedHostKey> treeHost(_Place listener, {_Place? office}) async {
    final shows = PlayedHostKey.ed25519();
    for (final l in [listener, ?office]) {
      await KnownHostsService(tree.knownHostsDao)
          .trustHost(l.host, l.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    }
    final at = DateTime(2026, 10, 16);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web',
          host: listener.host,
          port: Value(listener.port),
          identityId: const Value('id-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
    if (office != null) {
      await HostNetworkOverridesRepository(tree.networksDao).create(HostNetworkOverride(
        id: 'o-web-office',
        hostId: 'h-web',
        networkId: 'n-office',
        address: office.host,
        port: office.port,
      ));
    }
    return shows;
  }

  /// Plays a host on [listener] that takes the key: the session [id] signs
  /// in with it, and its shell opens.
  Future<List<String>> signsInWithTheKey(_Place listener, PlayedHostKey shows, String id) async {
    final server = PlayedServer(line: await listener.line(), hostKey: shows);
    await server.greet();
    final signIn = PlayedSignIn(ways: ['publickey'], takesKey: true);
    expect(await signIn.play(server, over: () => over(id)), isTrue, reason: '${stateOf(id)?.connectionLog}');
    await PlayedSignIn.openShell(server);
    await until(() => stateOf(id)?.status == SessionStatus.connected || over(id), 'the session');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.errorMessage}');
    return signIn.seen;
  }

  void teamSpaceOnScreen() => container.read(activeSpaceProvider.notifier).state = const OrchardSpace(kFixtureOrchardId);

  test("a Duplicate of a session of your Tree, made while a team space is on screen: signed in with the Tree's key",
      () async {
    final listener = await _Place.bind();
    addTearDown(listener.close);
    final shows = await treeHost(listener);
    final first = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await signsInWithTheKey(listener, shows, first);

    teamSpaceOnScreen();
    final second = (await sessions().openLike(first))!;
    expect(await signsInWithTheKey(listener, shows, second), contains('key!'));
    await sessions().endSession(first);
    await sessions().endSession(second);
  }, skip: !kOrchardsEnabled);

  test('Try again of a session of your Tree that is gone, while a team space is on screen: opened from your Tree, '
      "with the Tree's key", () async {
    final listener = await _Place.bind();
    addTearDown(listener.close);
    final shows = await treeHost(listener);
    final first = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await signsInWithTheKey(listener, shows, first);
    await sessions().endSession(first);

    teamSpaceOnScreen();
    final again = (await sessions().openHostAgain('h-web'))!;
    expect(await signsInWithTheKey(listener, shows, again), contains('key!'));
    await sessions().endSession(again);
  }, skip: !kOrchardsEnabled);

  test('a Reconnect of a session of your Tree, made while a team space is on screen: as the network it is on has '
      'it, with the Tree\'s key', () async {
    final saved = await _Place.bind();
    final office = await _Place.bind();
    addTearDown(saved.close);
    addTearDown(office.close);
    final shows = await treeHost(saved, office: office);
    final first = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await signsInWithTheKey(office, shows, first);

    teamSpaceOnScreen();
    final again = (await sessions().openAgain(first))!;
    expect(await signsInWithTheKey(office, shows, again), contains('key!'), reason: "at the Office network's address");
    await expectLater(saved.line().timeout(const Duration(milliseconds: 400)), throwsA(isA<TimeoutException>()),
        reason: 'not at the address it is saved with');
    await sessions().endSession(again);
  }, skip: !kOrchardsEnabled);
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
