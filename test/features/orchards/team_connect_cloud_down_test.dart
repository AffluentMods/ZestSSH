import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/hostkeys/team_host_keys.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../../packages/zest_ssh_core/test/src/played_listener.dart';
import '../../../packages/zest_ssh_core/test/src/played_server.dart';
import '../../helpers/orchard_db_fixture.dart';
import '../../helpers/played_sign_in.dart';

/// A team's hosts connect with what the device holds, whatever ZestSSH
/// Cloud does: the server coordinates a team, it never gates a connection
/// (a rule of the app: the backend being down must never be
/// why a team cannot SSH). Here ZestSSH Cloud cannot be reached at all, and
/// in the second case the team's record has also stopped following the
/// server, as on every device after a server is restored from an older
/// backup. The host is played on the
/// loopback address, with the team's pin of its key and a saved password.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  late AppDatabase db;
  late ProviderContainer container;
  late List<HostKeyVerification> prompts;
  late List<http.BaseRequest> askedCloud;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    db = AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
    await seedOrchardAsOwner(db);
    final at = DateTime(2026, 10, 19);
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-deploy', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await OrchardIdentitySecrets(db).write('k-deploy', IdentitySecret.password, 'made up for this test');
    // ZestSSH Cloud, unreachable: every request fails as a dead network does.
    askedCloud = [];
    final cloud = MockClient((request) async {
      askedCloud.add(request);
      throw const SocketException('Connection refused');
    });
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      databaseProvider.overrideWithValue(db),
      askBeforeTrustingKeysProvider.overrideWith((ref) => true),
      orchardsApiProvider.overrideWithValue(
          OrchardsApi(client: cloud, baseUrl: 'https://api.test/v1', bearer: () async => 'session')),
    ]);
    container.read(databaseSessionProvider.notifier).seed(db);
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

  /// The host web-01 in the team's Crate, as the sync engine leaves it:
  /// played at [listener]'s address, signing in with k-deploy, and the
  /// team's pin of the key it shows ([shows]).
  Future<void> synced(PlayedListener listener, PlayedHostKey shows) async {
    final at = DateTime(2026, 10, 19);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 1 WHERE id = 1');
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: listener.host,
          port: Value(listener.port),
          identityId: const Value('k-deploy'),
          createdAt: at,
          updatedAt: at,
        ));
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('host', 'h-web', ?, 1)",
        [kFixtureCrateId]);
    final pin = teamHostKeyId(listener.host, listener.port, null, crateId: kFixtureCrateId);
    await db.customStatement(
        "INSERT INTO team_host_keys (id, host, port, via_scope, host_keys) VALUES (?, ?, ?, '', ?)",
        [pin, listener.host, listener.port, jsonEncode([hostKeyLine(SSHHostKey(type: shows.algorithm, bytes: shows.blob))])]);
    await db.customStatement(
        "INSERT INTO crate_items_meta (kind, item_key, crate_id, server_revision) VALUES ('hostkey', ?, ?, 1)",
        [pin, kFixtureCrateId]);
    await db.customStatement('UPDATE orchard_sync_control SET applying = 0 WHERE id = 1');
  }

  /// A session to web-01, played through to its shell: how it signed in,
  /// once the session says it is connected.
  Future<List<String>> connectToTheHost() async {
    final listener = await PlayedListener.bind();
    final shows = PlayedHostKey.ed25519();
    await synced(listener, shows);
    final id = sessions().startSession((await db.connectionsDao.getById('h-web'))!)!;
    final server = PlayedServer(line: await listener.line(), hostKey: shows);
    addTearDown(server.hangUp);
    await server.greet();
    final signIn = PlayedSignIn(ways: ['password'], password: 'made up for this test');
    expect(await signIn.play(server), isTrue, reason: 'let in with the saved password');
    final channel = await server.confirmChannel();
    // The terminal's requests (a pty, the shell): yes to each.
    unawaited(() async {
      while (true) {
        final request = await channel.nextRequest();
        if (request.wantReply) server.send([channel.success]);
        if (request.requestType == 'shell') {
          server.send([channel.data(r'web-01 $ ')]);
          return;
        }
      }
    }().then((_) {}, onError: (Object _) {}));
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'the session to connect');
    expect(prompts, isEmpty, reason: 'the key is the one the team pinned: nobody is asked');
    expect(askedCloud, isEmpty, reason: 'connecting to an ordinary team host asks ZestSSH Cloud nothing');
    // Ended here, before the container goes: nothing of the session runs after the test.
    await sessions().endSession(id);
    server.hangUp();
    await until(() => stateOf(id)?.status != SessionStatus.connected, 'the session to end');
    return signIn.seen;
  }

  test('ZestSSH Cloud unreachable: a team host connects with what this device holds, and nobody is asked', () async {
    expect(await connectToTheHost(), ['password:made up for this test']);
  });

  test("the team's record stopped following the server (as after a server restored from an older backup), and "
      'ZestSSH Cloud unreachable: its hosts still connect', () async {
    await db.customStatement('UPDATE orchard_info SET record_problem = ? WHERE id = 1',
        ['the server holds 3 entries and this device 5']);
    expect(await connectToTheHost(), ['password:made up for this test']);
  });
}

/// A Squeezed account, without RevenueCat.
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
