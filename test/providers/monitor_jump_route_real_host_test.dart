import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
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
import 'package:zestssh/providers/changed_host_keys_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/ssh_connection_factory.dart' show MonitorExecOutcome;
import 'package:zestssh/services/ssh_service.dart' show SSHHostKey;

/// Server Monitor's own connection to a host and the host's key (3.0, found
/// while checking a list of suspected faults in signing in), with real
/// OpenSSH servers: the first test server is a jump host (127.0.0.1:2299)
/// and the second the host behind it (127.0.0.1:2297), both started by
/// tool/test_sshd.sh of the SSH core package. Skips itself when they are not
/// running.
///
/// A session trusts the key of a host behind a jump host under the route it
/// is reached by. Server Monitor looked for the key as if the host were
/// reached directly: it never found it (the host stayed "check its key"),
/// and where this device trusts another server's key at the host's address,
/// reached directly, it compared the host's key with that one and marked
/// the host's card as having a changed key. And a changed key at the
/// address a network gives the host was marked under that address, where no
/// card shows it, and not under the one the host is saved with.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final env = Platform.environment;
  final sshHost = env['ZESTSSH_TEST_SSHD_HOST'] ?? '127.0.0.1';
  final jumpPort = int.tryParse(env['ZESTSSH_TEST_SSHD_PORT'] ?? '') ?? 2299;
  final targetPort = int.tryParse(env['ZESTSSH_TEST_REKEY_SSHD_PORT'] ?? '') ?? 2297;
  final user = env['ZESTSSH_TEST_SSHD_USER'] ?? env['USERNAME'] ?? env['USER'] ?? '';
  final dir = env['ZESTSSH_TEST_SSHD_DIR'] ?? '//wsl.localhost/Ubuntu/home/$user/zestssh-sshd-test';
  late bool up;
  String? keyPem;
  final hostKeys = <int, SSHHostKey>{};
  // A key that no test server has: another server's, at the host's address.
  final anotherServers = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => i)));
  late AppDatabase tree;
  late ProviderContainer container;
  late _OnNetwork network;

  setUpAll(() async {
    try {
      final file = File('$dir/client_ed25519');
      up = file.existsSync();
      if (!up) return;
      keyPem = file.readAsStringSync();
      for (final port in [jumpPort, targetPort]) {
        final client = SSHClient(
          await SSHSocket.connect(sshHost, port, timeout: const Duration(seconds: 2)),
          username: user,
          identities: SSHKeyPair.fromPem(keyPem!),
          onVerifyHostKey: (type, bytes) {
            hostKeys[port] = SSHHostKey(type: type, bytes: Uint8List.fromList(bytes));
            return true;
          },
        );
        await client.authenticated.timeout(const Duration(seconds: 20));
        client.close();
      }
    } catch (_) {
      up = false;
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({if (keyPem != null) 'identity_key_id-deploy': keyPem!});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    network = _OnNetwork();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      connectionResolverProvider.overrideWithValue(network),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    if (!up) return;
    final at = DateTime(2026, 10, 16);
    await tree.into(tree.identities).insert(IdentitiesCompanion.insert(
          id: 'id-deploy',
          label: 'deploy key',
          username: user,
          authMethod: 'publicKey',
          createdAt: at,
        ));
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  KnownHostsService known() => KnownHostsService(tree.knownHostsDao);

  Future<void> saved(String id, int port, {String? via, String? named}) async {
    final at = DateTime(2026, 10, 16);
    await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: id,
          host: named ?? sshHost,
          port: Value(port),
          identityId: const Value('id-deploy'),
          connectViaId: Value(via),
          monitored: const Value(true),
          createdAt: at,
          updatedAt: at,
        ));
  }

  test("a host behind a jump host whose key this device trusts under that route: polled, though another server's "
      'key is trusted at its address reached directly, and its card is left as it is', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$jumpPort and $sshHost:$targetPort');
      return;
    }
    await saved('h-bastion', jumpPort);
    await saved('h-db', targetPort, via: 'h-bastion');
    // As a session leaves them: the jump host's key as itself, the host's under the route it is reached by.
    await known().trustHost(sshHost, jumpPort, hostKeys[jumpPort]!);
    await known().trustHost(sshHost, targetPort, hostKeys[targetPort]!, viaScope: '${normalizeKnownHost(sshHost)}:$jumpPort');
    // Another server answers at the host's address when it is reached directly.
    await known().trustHost(sshHost, targetPort, anotherServers);

    final result = await sessions().openExecClient((await tree.connectionsDao.getById('h-db'))!);
    expect(result.outcome, MonitorExecOutcome.ok, reason: '${result.failedWith}');
    await result.service!.disconnect();
    expect(container.read(changedHostKeysProvider), isEmpty);
    expect((await known().verify(sshHost, targetPort, anotherServers)).result, HostKeyVerifyResult.trusted,
        reason: "the other server's key is left as it is");
    expect((await known().verify(sshHost, jumpPort, hostKeys[jumpPort]!)).result, HostKeyVerifyResult.trusted,
        reason: "the jump host's key is looked for as itself, and stays so (not moved under the host's route)");
  });

  test('a host the network the device is on has at another address, whose key there is not the one this device '
      'trusts: its card is marked under the address it is saved with', () async {
    if (!up) {
      markTestSkipped('no test sshd at $sshHost:$targetPort');
      return;
    }
    // Saved where nothing answers, by another name; on the Office network it is the second test server.
    final dead = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final deadPort = dead.port;
    await dead.close();
    await saved('h-db', deadPort, named: 'localhost');
    network.answers['h-db'] = network.onOffice('h-db', sshHost, targetPort);
    await known().trustHost(sshHost, targetPort, anotherServers);

    final result = await sessions().openExecClient((await tree.connectionsDao.getById('h-db'))!);
    expect(result.outcome, MonitorExecOutcome.needsHostKeyReview);
    final changed = container.read(changedHostKeysProvider.notifier);
    expect(changed.isChanged('localhost', deadPort), isTrue, reason: 'the card shows the host as it is saved');
    expect(changed.isChanged(sshHost, targetPort), isFalse);
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

/// Each host as it is saved, but those given here, which are as the Office
/// network has them.
class _OnNetwork implements ConnectionResolver {
  final answers = <String, ResolvedConnection>{};

  ResolvedConnection onOffice(String hostId, String address, int port) => ResolvedConnection(
        hostId: hostId,
        network: const Network(
          id: 'n-office',
          name: 'Office',
          color: GroupColor.blue,
          icon: LucideIcons.globe,
          triggers: [AlwaysTrigger()],
          isFallback: false,
        ),
        address: address,
        port: port,
        username: '',
        identityKeyId: 'id-deploy',
        jumpChain: const [],
        bringUpVpnHostId: null,
      );

  @override
  Future<ResolvedConnection> resolve(String hostId) async =>
      answers[hostId] ?? (throw StateError('no network for $hostId'));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
