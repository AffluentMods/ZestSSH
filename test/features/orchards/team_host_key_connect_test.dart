import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome, MonitorExecResult;
import 'package:zestssh/services/ssh_service.dart';

import '../../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/orchard_db_fixture.dart';
import '../../helpers/played_jump_host.dart';

/// What the app's own connections to an Orchard's hosts go by (3.0):
/// a team's pin counts only for the hosts of its own Crate. A session
/// through a jump host of another Crate goes by the jump host's own Crate's
/// pin there, not by that of the host it leads to; the background monitor
/// goes by the pin of the host's own Crate, not by another Crate's pin of
/// the same address. The app dials for itself, so the jump host and the
/// monitored host are played on the loopback address; nothing behind the
/// jump host is reached (it hangs up when it is asked for the way on), so no
/// SSH server is needed.

const _viewCrate = '77777777-7777-4777-8777-777777777777'; // connect only

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;
  late ProviderContainer container;
  late List<HostKeyVerification> prompts;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db);
    await db.customStatement(
        "INSERT INTO orchard_crates (crate_id, name, level, switches, key_generation) VALUES (?, 'View', 'connect', ?, 1)",
        [_viewCrate, jsonEncode(switchList(levelSwitches(CrateLevel.connect)))]);
    // The key every host here signs in with: a password, saved in Fixture.
    final at = DateTime(2026, 10, 18);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-deploy', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await OrchardIdentitySecrets(db).write('k-deploy', IdentitySecret.password, 'made up for this test');
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      databaseProvider.overrideWithValue(db),
      askBeforeTrustingKeysProvider.overrideWith((ref) => true),
    ]);
    // The Orchard's database is the one the sessions work in.
    container.read(databaseSessionProvider.notifier).seed(db);
    // Every question about a key is collected, and answered no.
    prompts = [];
    final queue = container.read(hostKeyVerificationQueueProvider.notifier);
    container.listen<List<HostKeyVerification>>(hostKeyVerificationQueueProvider, (_, next) {
      for (final v in next) {
        if (prompts.contains(v)) continue;
        prompts.add(v);
        scheduleMicrotask(() => queue.resolve(v, false));
      }
    });
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('waited for $what');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// As the sync engine leaves them: the hosts [hosts] (id, label, address,
  /// port, the jump host on the way, Crate), each signing in with k-deploy,
  /// and a pin of [listener]'s address, with the key [shows], in [pinnedIn].
  Future<void> synced(List<(String, String, String, int, String?, String)> hosts, PlayedListener listener,
      PlayedHostKey shows, String pinnedIn) async {
    final at = DateTime(2026, 10, 18);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    for (final (id, label, host, port, via, crate) in hosts) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: id,
            label: label,
            host: host,
            port: Value(port),
            identityId: const Value('k-deploy'),
            connectViaId: Value(via),
            createdAt: at,
            updatedAt: at,
          ));
      await db.customStatement(
          "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', ?, ?, 1)", [id, crate]);
    }
    final pin = teamHostKeyId(listener.host, listener.port, null, crateId: pinnedIn);
    await db.customStatement(
        "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, ?, ?, '', ?)",
        [pin, listener.host, listener.port, jsonEncode([hostKeyLine(SSHHostKey(type: shows.algorithm, bytes: shows.blob))])]);
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
        [pin, pinnedIn]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  /// The jump host bastion in View, at the address the test plays it on;
  /// db-primary in Fixture, through bastion; a pin of bastion's address,
  /// with the key it shows, in [pinnedIn]. Then a session to db-primary, up
  /// to where the app dials bastion.
  Future<({String id, PlayedJumpHost bastion, String host, int port})> dialled({required String pinnedIn}) async {
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await synced([
      ('h-bastion', 'bastion', listener.host, listener.port, null, _viewCrate),
      ('h-db', 'db-primary', '10.50.0.5', 22, 'h-bastion', kFixtureCrateId),
    ], listener, shows, pinnedIn);
    final id = sessions().startSession((await db.connectionsDao.getById('h-db'))!)!;
    final bastion = PlayedJumpHost(line: await listener.line(), hostKey: shows);
    addTearDown(bastion.stop);
    return (id: id, bastion: bastion, host: listener.host, port: listener.port);
  }

  /// The host web-01 in Fixture, at the address the test plays it on, and a
  /// pin of that address, with the key it shows, in [pinnedIn]. Then the
  /// background monitor's own connection to it: what it is told.
  Future<MonitorExecResult> monitored({required String pinnedIn}) async {
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await synced([('h-web', 'web-01', listener.host, listener.port, null, kFixtureCrateId)], listener, shows, pinnedIn);
    final playing = () async {
      await PlayedServer(line: await listener.line(), hostKey: shows).letIn();
    }();
    final told =
        await sessions().openExecClient((await db.connectionsDao.getById('h-web'))!).timeout(const Duration(seconds: 20));
    addTearDown(() async => told.service?.disconnect());
    // A host whose key is not taken waits for a sign-in that never comes: that ends with the connection.
    await playing.timeout(const Duration(seconds: 20)).then((_) {}, onError: (Object _) {});
    return told;
  }

  test("the jump host goes by its own Crate's pin: its key is taken, nobody asked, though the host it leads to is in "
      'another Crate', () async {
    final s = await dialled(pinnedIn: _viewCrate);
    // Signed in to bastion, the app asks it for the way on to db-primary.
    await s.bastion.letIn();
    await s.bastion.server.confirmChannel();
    expect(prompts, isEmpty, reason: "bastion's key was the one its Crate pinned");
    s.bastion.server.hangUp();
    await until(() => stateOf(s.id)?.status == SessionStatus.error, 'the session to end');
    expect(prompts, isEmpty);
  });

  test("the jump host does not go by the pin of the host's Crate: asked about as a host this device has not seen",
      () async {
    final s = await dialled(pinnedIn: kFixtureCrateId);
    final signedIn = s.bastion.letIn();
    await until(() => prompts.isNotEmpty, 'the question about the key');
    final asked = prompts.single;
    expect([asked.host, asked.port, asked.isChanged], [s.host, s.port, false]);
    expect(asked.teamPin, isNull, reason: 'no pin of its own Crate, and nothing offered for a jump host');
    // Not trusted, the jump host is not signed in to; its person said no, so the session closes.
    await expectLater(signedIn, throwsA(isA<StateError>()));
    await until(() => stateOf(s.id) == null, 'the session to close');
  });

  test("the background monitor goes by the host's own Crate's pin: the key is taken", () async {
    final told = await monitored(pinnedIn: kFixtureCrateId);
    expect(told.outcome, MonitorExecOutcome.ok, reason: '${told.failedWith}');
  });

  test("the background monitor does not go by another Crate's pin of the host's address: a key to be looked at",
      () async {
    final told = await monitored(pinnedIn: _viewCrate);
    expect([told.outcome, told.hostKeyChanged], [MonitorExecOutcome.needsHostKeyReview, false],
        reason: 'a host this device has not seen');
  });
}

/// A Squeezed account, without RevenueCat: a host is reached through its jump host.
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
