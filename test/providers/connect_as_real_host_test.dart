import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// "Connect as" through the app's own sign-in, against a real SSH server
/// (3.0, accounts per host): an account chosen for the session is signed in
/// with on any network, its own username and key, where the network the
/// device is on names another identity and another user for the host; and a
/// session to a saved host says who it is signed in as (it said nothing,
/// which the status bar showed as the host alone).
///
/// The server is the WSL test sshd on 127.0.0.1:2299 (tool/test_sshd.sh
/// starts it); `client_ed25519` signs in as the user the tests run as. Skips
/// itself when the server is not there. Override the location with
/// ZESTSSH_TEST_SSHD_HOST / _PORT / _USER / _DIR.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final sshPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  final en = lookupAppLocalizations(const Locale('en'));
  var up = false;
  String? keyPem;
  String? strangerPem;
  SSHHostKey? hostKey;
  late AppDatabase tree;
  late ProviderContainer container;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      if (!file.existsSync()) return;
      keyPem = file.readAsStringSync();
      strangerPem = (await KeyGenerationService().generateEd25519(comment: 'stranger')).privatePem;
      // The server's host key, as a person approves it once.
      final client = SSHClient(
        await SSHSocket.connect(sshHost, sshPort, timeout: const Duration(seconds: 2)),
        username: user,
        identities: SSHKeyPair.fromPem(keyPem!),
        onVerifyHostKey: (type, bytes) {
          hostKey = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
          return true;
        },
      );
      await client.authenticated.timeout(const Duration(seconds: 20));
      client.close();
      up = true;
    } catch (_) {
      up = false;
    }
  });

  Future<void> start(ConnectionResolver resolver, {required String defaultIdentity}) async {
    FlutterSecureStorage.setMockInitialValues({
      'identity_key_id-deploy': keyPem!,
      'identity_key_id-default': strangerPem!,
      'identity_key_id-stranger': strangerPem!,
    });
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(en);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(resolver),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final at = DateTime(2026, 10, 15);
    for (final (id, username) in [('id-deploy', user), ('id-default', user), ('id-stranger', 'nobody')]) {
      await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
            id: id,
            label: id,
            username: username,
            authMethod: 'publicKey',
            createdAt: at,
          ));
    }
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: 'h-web',
          label: 'web-01',
          host: sshHost,
          port: Value(sshPort),
          identityId: Value(defaultIdentity),
          createdAt: at,
          updatedAt: at,
        ));
    await tree.hostAccountsDao.setOtherAccounts('h-web', ['id-deploy']);
    await KnownHostsService(tree.knownHostsDao).trustHost(sshHost, sshPort, hostKey!);
  }

  tearDown(() async {
    if (!up) return;
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String id) => container.read(activeSessionsProvider)[id];

  Future<void> until(bool Function() check, String what) async {
    final clock = Stopwatch()..start();
    while (!check()) {
      if (clock.elapsed > const Duration(seconds: 40)) fail('waited for $what: ${stateOf('').toString()}');
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('on a network that names another identity and user for the host, Connect as signs in with the account chosen, '
      'as its own user', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    await start(_OnTheOfficeNetwork(sshHost, sshPort), defaultIdentity: 'id-default');
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!, asAccount: 'id-deploy')!;
    await until(
        () => stateOf(id)?.status == SessionStatus.connected || stateOf(id)?.status == SessionStatus.error, 'the session');
    expect(stateOf(id)?.status, SessionStatus.connected, reason: '${stateOf(id)?.connectionLog}');
    expect(stateOf(id)?.username, user);
    await sessions().endSession(id);
  });

  test('a session to a saved host says who it is signed in as', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$sshPort');
      return;
    }
    await start(_AsSaved(), defaultIdentity: 'id-deploy');
    final id = sessions().startSession((await tree.connectionsDao.getById('h-web'))!)!;
    await until(() => stateOf(id)?.status == SessionStatus.connected, 'connected');
    expect(stateOf(id)?.username, user);
    await sessions().endSession(id);
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

/// No networks are set up: a host is reached as it is saved.
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The device is on a network whose override for the host names another
/// identity (a key the server does not take) and another user.
class _OnTheOfficeNetwork implements ConnectionResolver {
  _OnTheOfficeNetwork(this.host, this.port);

  final String host;
  final int port;

  @override
  Future<ResolvedConnection> resolve(String hostId) async => ResolvedConnection(
        hostId: hostId,
        network: const Network(
          id: 'n-office',
          name: 'Office',
          color: GroupColor.blue,
          icon: LucideIcons.globe,
          triggers: [AlwaysTrigger()],
          isFallback: false,
        ),
        address: host,
        port: port,
        username: 'nobody',
        identityKeyId: 'id-stranger',
        jumpChain: const [],
        bringUpVpnHostId: null,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
