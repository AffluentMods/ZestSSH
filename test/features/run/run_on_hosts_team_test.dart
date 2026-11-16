import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

import '../../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/played_sign_in.dart';
import '../orchards/fake_crate_server.dart';

const _dana = 'uid-dana';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
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

/// Run on hosts (3.0) on a team's hosts, as the app runs it: never on a host
/// of a Crate whose sessions are watched, since nobody could watch it;
/// on another, noted while the team's owners record activity and
/// logged for them where its Crate logs sessions; and each host run on
/// in the space it was in when the run started, whatever is on screen when
/// its turn comes.
///
/// The Orchard's record is on a stand-in server, and its hosts are played
/// on the loopback address.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final en = lookupAppLocalizations(const Locale('en'));
  late AccountKeys danaKeys;
  late FakeCrateServer server;
  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late OrchardService dana;
  late String orchardId;
  late String crateId;

  setUpAll(() async => danaKeys = await AccountKeys.generate());

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    TeamSessionLogs.reset();
    server = FakeCrateServer(accountUid: _dana);
    await server.publish(_dana, danaKeys, email: 'dana@example.com');
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => CrateAuthor(uid: _dana, keys: danaKeys))),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      // The app's own service is the one this test's server answers.
      orchardServiceProvider.overrideWith((ref) => dana),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    dana = OrchardService(
      server: server.as(_dana),
      databases: container.read(orchardDatabasesProvider.notifier),
      author: () async => CrateAuthor(uid: _dana, keys: danaKeys),
    );
    orchardId = await dana.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    crateId = server.recordOf(orchardId).crates.keys.single;
    await container.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
  });

  tearDown(() async {
    TeamSessionLogs.reset();
    container.dispose();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  AppDatabase orchardDb() => container.read(orchardDatabasesProvider)[orchardId]!;
  RunOnHostsNotifier runs() => container.read(runOnHostsProvider.notifier);
  HostsRun? run() => container.read(runOnHostsProvider);

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 30)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// A key of the Crate that signs in as deploy with a password, kept.
  Future<void> key() async {
    final db = orchardDb();
    final at = DateTime(2026, 10, 15);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-web', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await CratePlacement(db).place('key', 'k-web', crateId);
    await IdentitySecretStore.forDatabase(db, container.read(secureStorageProvider))
        .write('k-web', IdentitySecret.password, 'made-up-for-this-test');
  }

  /// A host of the Crate, played on the loopback address, signed in to with
  /// the Crate's key, whose host key the Orchard trusts.
  Future<({PlayedListener listener, PlayedHostKey shows, Connection host})> playedHost(String id) async {
    final db = orchardDb();
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await KnownHostsService(db.knownHostsDao)
        .trustHost(listener.host, listener.port, SSHHostKey(type: shows.algorithm, bytes: shows.blob));
    final at = DateTime(2026, 10, 15);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: 'Web $id',
          host: listener.host,
          port: Value(listener.port),
          protocol: const Value('ssh'),
          identityId: const Value('k-web'),
          createdAt: at,
          updatedAt: at,
        ));
    await CratePlacement(db).place('host', id, crateId);
    return (listener: listener, shows: shows, host: (await db.connectionsDao.getById(id))!);
  }

  /// The host's part: the password sign-in, then the command, printing
  /// [output] and ending well once [release] completes.
  Future<void> play(({PlayedListener listener, PlayedHostKey shows, Connection host}) h,
      {String output = '', Future<void>? release}) async {
    final server = PlayedServer(line: await h.listener.line(), hostKey: h.shows);
    await server.greet();
    if (!await PlayedSignIn(ways: ['password'], password: 'made-up-for-this-test').play(server)) return;
    final channel = await server.confirmChannel();
    await channel.nextRequest();
    server.send([channel.success, if (output.isNotEmpty) channel.data(output)]);
    if (release != null) await release;
    server.send([channel.exitStatus(0), channel.eof, channel.close]);
  }

  test('never on a host of a Crate whose sessions are watched: it says why, and nothing is connected', () async {
    await dana.setCrateWatched(orchardId, crateId, true);
    await dana.refresh();
    await key();
    final h = await playedHost('h-watched');
    var connected = false;
    unawaited(h.listener.line().then((_) => connected = true));
    await runs().run([h.host], 'uptime');
    final result = run()!.hosts.single;
    expect(result.state, HostRunState.failed);
    expect(result.failure, isA<OrchardAccessRefused>().having((e) => e.message, 'message', en.runOnHostsWatched));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(connected, isFalse);
  });

  test('a team\'s host: the run is noted while its owners record activity, logged for them where its Crate logs '
      'sessions, and the host\'s last use noted', () async {
    await dana.setTracking(orchardId, const RecordTracking(activity: true));
    await dana.setCrateSessionLogs(orchardId, crateId, true);
    await dana.refresh();
    await key();
    final h = await playedHost('h-web');
    final going = runs().run([h.host], 'uptime');
    await play(h, output: 'up 5 days\n');
    await going;
    final result = run()!.hosts.single;
    expect(result.succeeded, isTrue, reason: '${result.failure}');
    expect(result.logged, isTrue);

    // Noted as a connection to the host.
    final db = orchardDb();
    String? queued;
    for (var i = 0; i < 100 && queued == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      queued = await LocalStateStore(db).read('activity.queue');
    }
    expect(queued, isNotNull, reason: 'a note waits to go with the next sync');
    expect(jsonDecode(queued!) as List, hasLength(1));

    // Logged for the team.
    var text = '';
    var closed = false;
    for (var i = 0; i < 250 && !closed; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entries = (await dana.teamSessionLogs(orchardId, crateId)).entries;
      if (entries.isNotEmpty && entries.single.closed) {
        closed = true;
        expect(entries.single.header.connectionId, 'h-web');
        expect(entries.single.header.user, 'deploy');
        text = (await dana.teamSessionLogText(orchardId, crateId, entries.single)).text;
      }
    }
    expect(closed, isTrue, reason: 'the run\'s log ended');
    expect(text, '[ZestSSH] ${en.runOnHostsLogLine}\n\$ uptime\nup 5 days\n\n[ZestSSH] ${en.runOnHostsOk}\n');

    // Its last use, in the Orchard.
    Connection? row;
    for (var i = 0; i < 100 && row?.lastConnected == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      row = await db.connectionsDao.getById('h-web');
    }
    expect(row!.lastConnected, isNotNull);
  });

  test('each host is run on in the space it was in when the run started, whatever is on screen when its turn comes',
      () async {
    await key();
    // As many hosts as a run takes at once, each running until released,
    // and one more, whose turn comes once they are through.
    final busy = [for (var i = 1; i <= kRunAtOnce; i++) await playedHost('h-$i')];
    final last = await playedHost('h-last');
    final release = Completer<void>();
    final going = runs().run([for (final h in busy) h.host, last.host], 'uptime');
    final busyPlay = Future.wait([for (final h in busy) play(h, output: '${h.host.id}\n', release: release.future)]);
    await until(() => run()!.hosts.take(kRunAtOnce).every((h) => h.state == HostRunState.running), 'every turn taken');
    expect(run()!.hosts.last.state, HostRunState.waiting);
    // Your Tree on screen now, before the last host's turn.
    await container.read(spaceControllerProvider).switchTo(const TreeSpace());
    release.complete();
    await busyPlay;
    await play(last, output: 'last\n');
    await going;
    expect([for (final h in run()!.hosts) h.succeeded], everyElement(isTrue),
        reason: '${[for (final h in run()!.hosts) h.failure]}');
    expect(run()!.hosts.last.output, 'last\n');
  });
}
