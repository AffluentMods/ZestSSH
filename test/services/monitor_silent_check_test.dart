import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';

/// Whether Server Monitor may poll a host without asking anybody, which it
/// decides before it dials (3.0, found while checking a list of suspected
/// faults in signing in): by the key the poll signs in with, which is the
/// one the network the device is on gives the host, where it gives one. The
/// host's own key was looked at: a host whose own key could not sign in by
/// itself was held at "needs credentials" though the network's could, and
/// one whose own key could was dialled though the network's could not.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final keyPem = File('packages/zest_ssh_core/test/fixtures/ssh-ed25519/id_ed25519').readAsStringSync();
  late AppDatabase tree;
  late ProviderContainer container;
  late _OnNetwork network;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({'identity_key_id-deploy': keyPem});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    network = _OnNetwork();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      connectionResolverProvider.overrideWithValue(network),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    final at = DateTime(2026, 10, 16);
    // A key that is saved, with no passphrase; and a password that is not saved.
    for (final (id, method) in [('id-deploy', 'publicKey'), ('id-pass', 'password')]) {
      await tree.into(tree.identities).insert(
          IdentitiesCompanion.insert(id: id, label: id, username: 'deploy', authMethod: method, createdAt: at));
    }
    for (final (id, key) in [('h-web', 'id-pass'), ('h-db', 'id-deploy')]) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id, label: id, host: '$id.example.com', identityId: Value(key), monitored: const Value(true), createdAt: at, updatedAt: at));
    }
  });

  tearDown(() async {
    container.dispose();
    await tree.close();
  });

  Future<bool> silent(String id) async =>
      container.read(sshConnectionFactoryProvider).canPollSilently((await tree.connectionsDao.getById(id))!);

  test('where no network gives the host another key: its own key decides', () async {
    expect(await silent('h-web'), isFalse, reason: 'a password that is not saved would be asked for');
    expect(await silent('h-db'), isTrue, reason: 'a key that is saved, with no passphrase');
  });

  test('where the network the device is on gives the host another key: that key decides', () async {
    network.keys['h-web'] = 'id-deploy';
    network.keys['h-db'] = 'id-pass';
    expect(await silent('h-web'), isTrue, reason: "the network's key can sign in by itself");
    expect(await silent('h-db'), isFalse, reason: "the network's key would ask for a password");
  });
}

/// Each host as it is saved (the resolver cannot tell), but those given
/// here, which the Office network gives another key.
class _OnNetwork implements ConnectionResolver {
  final keys = <String, String>{};

  @override
  Future<ResolvedConnection> resolve(String hostId) async {
    final key = keys[hostId];
    if (key == null) throw StateError('no network for $hostId');
    return ResolvedConnection(
      hostId: hostId,
      network: const Network(
        id: 'n-office',
        name: 'Office',
        color: GroupColor.blue,
        icon: LucideIcons.globe,
        triggers: [AlwaysTrigger()],
        isFallback: false,
      ),
      address: '$hostId.example.com',
      port: 22,
      username: 'deploy',
      identityKeyId: key,
      jumpChain: const [],
      bringUpVpnHostId: null,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
