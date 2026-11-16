import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/identities_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/data/host_network_overrides_repository.dart';
import 'package:zestssh/features/hosts/models/host_network_override.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';

// ── Fixtures ───────────────────────────────────────────────────────

Connection _conn({
  required String id,
  String label = 'host',
  String host = 'example.com',
  int port = 22,
  String? identityId,
  String? connectViaId,
}) {
  // Connection is a Drift-generated DataClass - we can construct it
  // directly without going through a database.
  final now = DateTime.utc(2025);
  return Connection(
    id: id,
    label: label,
    host: host,
    port: port,
    identityId: identityId,
    connectViaId: connectViaId,
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: now,
    updatedAt: now,
  );
}

Identity _identity({
  required String id,
  required String username,
  String label = 'identity',
}) {
  return Identity(
    id: id,
    label: label,
    username: username,
    authMethod: 'publicKey',
    colorIndex: 0,
    isDefault: false,
    usesAgent: false,
    allowUnattended: false,
    passwordAfterKey: false,
    createdAt: DateTime.utc(2025),
  );
}

Network _net({
  required String id,
  required String name,
  List<NetworkTrigger> triggers = const [AlwaysTrigger()],
  bool isFallback = false,
  String? bringUpVpn,
}) {
  return Network(
    id: id,
    name: name,
    color: GroupColor.blue,
    icon: LucideIcons.globe,
    triggers: triggers,
    isFallback: isFallback,
    bringUpVpn: bringUpVpn,
  );
}

HostNetworkOverride _override({
  required String hostId,
  required String networkId,
  String? address,
  int? port,
  String? username,
  String? identityKeyId,
  String? jumpHostId,
  List<String>? jumpHostChain,
  bool? skipHost,
}) {
  return HostNetworkOverride(
    id: 'override-$hostId-$networkId',
    hostId: hostId,
    networkId: networkId,
    address: address,
    port: port,
    username: username,
    identityKeyId: identityKeyId,
    jumpHostId: jumpHostId,
    jumpHostChain: jumpHostChain,
    skipHost: skipHost,
  );
}

void main() {
  group('ConnectionResolver.mergeFromInputs (pure)', () {
    test('no override → uses base host config', () {
      final host = _conn(
        id: 'h1',
        host: 'home.lan',
        port: 2222,
        identityId: 'id1',
      );
      final identity = _identity(id: 'id1', username: 'alice');
      final network = _net(id: 'home', name: 'Home');

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: identity,
        override: null,
        network: network,
      );

      expect(resolved.hostId, 'h1');
      expect(resolved.network.id, 'home');
      expect(resolved.address, 'home.lan');
      expect(resolved.port, 2222);
      expect(resolved.username, 'alice');
      expect(resolved.identityKeyId, 'id1');
      expect(resolved.jumpChain, isEmpty);
      expect(resolved.bringUpVpnHostId, isNull);
    });

    test('partial override - only port changed → mixes', () {
      final host = _conn(
        id: 'h1',
        host: 'home.lan',
        port: 22,
        identityId: 'id1',
      );
      final identity = _identity(id: 'id1', username: 'alice');
      final network = _net(id: 'work', name: 'Work');
      final override = _override(
        hostId: 'h1',
        networkId: 'work',
        port: 2200, // only port differs
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: identity,
        override: override,
        network: network,
      );

      expect(resolved.address, 'home.lan'); // base
      expect(resolved.port, 2200); // override
      expect(resolved.username, 'alice'); // base via identity
      expect(resolved.identityKeyId, 'id1'); // base
      expect(resolved.jumpChain, isEmpty);
    });

    test('full override → all override fields used', () {
      final host = _conn(
        id: 'h1',
        host: 'home.lan',
        port: 22,
        identityId: 'id1',
        connectViaId: 'jump-base',
      );
      final identity = _identity(id: 'id1', username: 'alice');
      final network = _net(id: 'work', name: 'Work');
      final override = _override(
        hostId: 'h1',
        networkId: 'work',
        address: '10.0.0.5',
        port: 2200,
        username: 'bob',
        identityKeyId: 'id2',
        jumpHostId: 'jump-work',
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: identity,
        override: override,
        network: network,
      );

      expect(resolved.address, '10.0.0.5');
      expect(resolved.port, 2200);
      expect(resolved.username, 'bob');
      expect(resolved.identityKeyId, 'id2');
      expect(resolved.jumpChain, ['jump-work']);
    });

    test('skipHost: true → throws HostUnreachableException', () {
      final host = _conn(id: 'h1', label: 'Production DB');
      final network = _net(id: 'cell', name: 'Cellular');
      final override = _override(
        hostId: 'h1',
        networkId: 'cell',
        skipHost: true,
      );

      expect(
        () => ConnectionResolver.mergeFromInputs(
          host: host,
          identity: null,
          override: override,
          network: network,
        ),
        throwsA(
          isA<HostUnreachableException>()
              .having((e) => e.hostName, 'hostName', 'Production DB')
              .having((e) => e.networkName, 'networkName', 'Cellular'),
        ),
      );
    });

    test('jumpChain is empty list (not null) when no jump configured', () {
      final host = _conn(id: 'h1');
      final network = _net(id: 'home', name: 'Home');

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: null,
        network: network,
      );

      expect(resolved.jumpChain, isA<List<String>>());
      expect(resolved.jumpChain, isEmpty);
    });

    test('base connectViaId becomes a single-element jump chain', () {
      final host = _conn(id: 'h1', connectViaId: 'jump-base');
      final network = _net(id: 'home', name: 'Home');

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: null,
        network: network,
      );

      expect(resolved.jumpChain, ['jump-base']);
    });

    test('override jumpHostChain wins over base connectViaId', () {
      final host = _conn(id: 'h1', connectViaId: 'jump-base');
      final network = _net(id: 'work', name: 'Work');
      final override = _override(
        hostId: 'h1',
        networkId: 'work',
        jumpHostChain: ['hop-a', 'hop-b'],
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: override,
        network: network,
      );

      expect(resolved.jumpChain, ['hop-a', 'hop-b']);
    });

    test('explicit empty jumpHostChain clears the base jump', () {
      // The spec carve-out: "[] means no jump on this network."
      final host = _conn(id: 'h1', connectViaId: 'jump-base');
      final network = _net(id: 'cell', name: 'Cellular');
      final override = _override(
        hostId: 'h1',
        networkId: 'cell',
        jumpHostChain: const [],
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: override,
        network: network,
      );

      expect(resolved.jumpChain, isEmpty);
    });

    test('override jumpHostId wins over base connectViaId', () {
      final host = _conn(id: 'h1', connectViaId: 'jump-base');
      final network = _net(id: 'work', name: 'Work');
      final override = _override(
        hostId: 'h1',
        networkId: 'work',
        jumpHostId: 'jump-work',
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: override,
        network: network,
      );

      expect(resolved.jumpChain, ['jump-work']);
    });

    test('username override wins even when no identity exists', () {
      final host = _conn(id: 'h1');
      final network = _net(id: 'work', name: 'Work');
      final override = _override(
        hostId: 'h1',
        networkId: 'work',
        username: 'root',
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: override,
        network: network,
      );

      expect(resolved.username, 'root');
    });

    test('username falls back to empty string with no identity / override', () {
      // Defensive: a host with no identity attached and no override -
      // the resolver should still produce a valid object rather than
      // crash. The connect flow is responsible for blocking the actual
      // connection later (no auth available).
      final host = _conn(id: 'h1');
      final network = _net(id: 'home', name: 'Home');

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: null,
        network: network,
      );

      expect(resolved.username, '');
    });

    test('bringUpVpnHostId comes from the network', () {
      final host = _conn(id: 'h1');
      final network = _net(
        id: 'home',
        name: 'Home',
        bringUpVpn: 'vpn-host-id',
      );

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: null,
        network: network,
      );

      expect(resolved.bringUpVpnHostId, 'vpn-host-id');
    });

    // "Reach via": saved and read into the route, and used
    // by nothing. A host is connected to through it, as through a jump host.
    test("a network's Reach via host is the way to a host that has none of its own", () {
      final network = _net(id: 'office', name: 'Office', bringUpVpn: 'vpn');
      ResolvedConnection on(Connection host, [HostNetworkOverride? override]) =>
          ConnectionResolver.mergeFromInputs(host: host, identity: null, override: override, network: network);

      expect(on(_conn(id: 'h1')).jumpChain, ['vpn']);
      expect(on(_conn(id: 'h2', connectViaId: 'bastion')).jumpChain, ['bastion'], reason: 'its own Connect via stands');
      expect(on(_conn(id: 'h3'), _override(hostId: 'h3', networkId: 'office', jumpHostChain: const [])).jumpChain,
          isEmpty,
          reason: 'an override that says direct on this network stands');
      expect(on(_conn(id: 'h4'), _override(hostId: 'h4', networkId: 'office', jumpHostId: 'other')).jumpChain, ['other']);
      expect(on(_conn(id: 'vpn')).jumpChain, isEmpty, reason: 'the Reach via host itself is reached directly');
      expect(
          ConnectionResolver.mergeFromInputs(
                  host: _conn(id: 'h1'), identity: null, override: null, network: _net(id: 'home', name: 'Home'))
              .jumpChain,
          isEmpty);
    });

    test('jumpChain is unmodifiable (defensive copy)', () {
      final host = _conn(id: 'h1', connectViaId: 'jump-base');
      final network = _net(id: 'home', name: 'Home');

      final resolved = ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: null,
        network: network,
      );

      // Caller cannot stomp on the resolver's output.
      expect(
        () => resolved.jumpChain.add('rogue'),
        throwsUnsupportedError,
      );
    });
  });

  group('ConnectionResolver.resolve (end-to-end with fakes)', () {
    test('manual override beats auto-detected network', () async {
      // The detector says we're on Home; the manual override forces Work.
      // The Work-scoped override row should be the one that applies.
      final connections = _FakeConnections({
        'h1': _conn(id: 'h1', host: 'home.lan', port: 22, identityId: 'id1'),
      });
      final identities = _FakeIdentities({
        'id1': _identity(id: 'id1', username: 'alice'),
      });
      final home = _net(id: 'home', name: 'Home');
      final work = _net(id: 'work', name: 'Work');
      final overrides = _FakeOverridesRepo([
        _override(
          hostId: 'h1',
          networkId: 'work',
          address: '10.0.0.42',
          port: 4242,
          username: 'bob',
        ),
      ]);
      final networks = _FakeNetworkRepo([home, work]);
      final detector = _FakeDetector(home);
      final manual = ValueNotifier<String?>('work');

      final resolver = ConnectionResolver(
        connections: connections,
        identities: identities,
        overrides: overrides,
        networks: networks,
        detector: detector,
        manualOverride: manual,
      );

      final resolved = await resolver.resolve('h1');

      expect(resolved.network.id, 'work');
      expect(resolved.address, '10.0.0.42');
      expect(resolved.port, 4242);
      expect(resolved.username, 'bob');
      // The detector should NOT have been hit when the manual override
      // resolved cleanly.
      expect(detector.detectCount, 0);
    });

    test('manual override with deleted network falls through to detector',
        () async {
      // User set an override pointing at a network they then deleted.
      // The resolver should not crash - it should fall back to detection.
      final connections = _FakeConnections({
        'h1': _conn(id: 'h1', identityId: 'id1'),
      });
      final identities = _FakeIdentities({
        'id1': _identity(id: 'id1', username: 'alice'),
      });
      final home = _net(id: 'home', name: 'Home');
      final overrides = _FakeOverridesRepo(const []);
      // 'work' is no longer in the repo.
      final networks = _FakeNetworkRepo([home]);
      final detector = _FakeDetector(home);
      final manual = ValueNotifier<String?>('work-deleted');

      final resolver = ConnectionResolver(
        connections: connections,
        identities: identities,
        overrides: overrides,
        networks: networks,
        detector: detector,
        manualOverride: manual,
      );

      final resolved = await resolver.resolve('h1');
      expect(resolved.network.id, 'home');
      expect(detector.detectCount, 1);
    });

    test('unknown hostId throws StateError', () async {
      final connections = _FakeConnections(const {});
      final identities = _FakeIdentities(const {});
      final overrides = _FakeOverridesRepo(const []);
      final networks =
          _FakeNetworkRepo([_net(id: 'home', name: 'Home')]);
      final detector = _FakeDetector(_net(id: 'home', name: 'Home'));

      final resolver = ConnectionResolver(
        connections: connections,
        identities: identities,
        overrides: overrides,
        networks: networks,
        detector: detector,
        manualOverride: ValueNotifier(null),
      );

      await expectLater(
        () => resolver.resolve('does-not-exist'),
        throwsStateError,
      );
    });

    // For whoever resolves several hosts in one go (the checks of whether
    // hosts can be reached): finding the network asks the system, and once
    // is enough.
    test('several hosts are resolved on one lookup of the network: currentNetwork once, then resolveOn for each',
        () async {
      final connections = _FakeConnections({
        'h1': _conn(id: 'h1', host: 'a.example.com'),
        'h2': _conn(id: 'h2', label: 'Internal API', host: 'b.example.com'),
      });
      final home = _net(id: 'home', name: 'Home');
      final work = _net(id: 'work', name: 'Work');
      final overrides = _FakeOverridesRepo([
        _override(hostId: 'h1', networkId: 'work', address: '192.0.2.42', port: 2222),
        _override(hostId: 'h2', networkId: 'work', skipHost: true),
      ]);
      final detector = _FakeDetector(work);
      final manual = ValueNotifier<String?>(null);
      final resolver = ConnectionResolver(
        connections: connections,
        identities: _FakeIdentities(const {}),
        overrides: overrides,
        networks: _FakeNetworkRepo([home, work]),
        detector: detector,
        manualOverride: manual,
      );

      final network = await resolver.currentNetwork();
      expect(network.id, 'work');
      expect(detector.detectCount, 1);
      final first = await resolver.resolveOn(network, 'h1');
      expect((first.network.id, first.address, first.port), ('work', '192.0.2.42', 2222));
      await expectLater(
        () => resolver.resolveOn(network, 'h2'),
        throwsA(isA<HostUnreachableException>().having((e) => e.networkName, 'networkName', 'Work')),
      );
      await expectLater(() => resolver.resolveOn(network, 'gone'), throwsStateError);
      expect(detector.detectCount, 1, reason: 'not looked up again for each host');

      // On the network it is given, whichever the device is on.
      final atHome = await resolver.resolveOn(home, 'h1');
      expect((atHome.network.id, atHome.address, atHome.port), ('home', 'a.example.com', 22));
      expect(detector.detectCount, 1);

      // The network forced by hand is the current one, with nothing detected.
      manual.value = 'home';
      expect((await resolver.currentNetwork()).id, 'home');
      expect(detector.detectCount, 1);
      // And resolve() still looks it up by itself.
      manual.value = null;
      expect((await resolver.resolve('h1')).address, '192.0.2.42');
      expect(detector.detectCount, 2);
    });

    test('skipHost flows through to HostUnreachableException', () async {
      final connections = _FakeConnections({
        'h1': _conn(id: 'h1', label: 'Internal API'),
      });
      final identities = _FakeIdentities(const {});
      final cell = _net(id: 'cell', name: 'Cellular');
      final overrides = _FakeOverridesRepo([
        _override(hostId: 'h1', networkId: 'cell', skipHost: true),
      ]);
      final networks = _FakeNetworkRepo([cell]);
      final detector = _FakeDetector(cell);

      final resolver = ConnectionResolver(
        connections: connections,
        identities: identities,
        overrides: overrides,
        networks: networks,
        detector: detector,
        manualOverride: ValueNotifier(null),
      );

      await expectLater(
        () => resolver.resolve('h1'),
        throwsA(
          isA<HostUnreachableException>()
              .having((e) => e.hostName, 'hostName', 'Internal API')
              .having((e) => e.networkName, 'networkName', 'Cellular'),
        ),
      );
    });

    test('username comes from identity when not overridden', () async {
      final connections = _FakeConnections({
        'h1': _conn(id: 'h1', identityId: 'id-alice'),
      });
      final identities = _FakeIdentities({
        'id-alice': _identity(id: 'id-alice', username: 'alice'),
      });
      final home = _net(id: 'home', name: 'Home');
      final overrides = _FakeOverridesRepo(const []);
      final networks = _FakeNetworkRepo([home]);
      final detector = _FakeDetector(home);

      final resolver = ConnectionResolver(
        connections: connections,
        identities: identities,
        overrides: overrides,
        networks: networks,
        detector: detector,
        manualOverride: ValueNotifier(null),
      );

      final resolved = await resolver.resolve('h1');
      expect(resolved.username, 'alice');
    });
  });
}

// ── Fakes ─────────────────────────────────────────────────────────
//
// The dao/repo classes are concrete; we use noSuchMethod to pin the
// surface area we actually need without dragging in a real database.

class _FakeConnections implements ConnectionsDao {
  _FakeConnections(this._byId);
  final Map<String, Connection> _byId;

  @override
  Future<Connection?> getById(String id) async => _byId[id];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'ConnectionsDao.${invocation.memberName} not used by resolver tests',
    );
  }
}

class _FakeIdentities implements IdentitiesDao {
  _FakeIdentities(this._byId);
  final Map<String, Identity> _byId;

  @override
  Future<Identity?> getById(String id) async => _byId[id];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'IdentitiesDao.${invocation.memberName} not used by resolver tests',
    );
  }
}

class _FakeOverridesRepo implements HostNetworkOverridesRepository {
  _FakeOverridesRepo(this._all);
  final List<HostNetworkOverride> _all;

  @override
  Future<HostNetworkOverride?> getForHostAndNetwork({
    required String hostId,
    required String networkId,
  }) async {
    for (final o in _all) {
      if (o.hostId == hostId && o.networkId == networkId) return o;
    }
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'HostNetworkOverridesRepository.${invocation.memberName} '
      'not used by resolver tests',
    );
  }
}

class _FakeNetworkRepo implements NetworkRepository {
  _FakeNetworkRepo(this._all);
  final List<Network> _all;

  @override
  Future<Network?> get(String id) async {
    for (final n in _all) {
      if (n.id == id) return n;
    }
    return null;
  }

  @override
  Future<List<Network>> list() async => List.unmodifiable(_all);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'NetworkRepository.${invocation.memberName} '
      'not used by resolver tests',
    );
  }
}

class _FakeDetector implements NetworkDetector {
  _FakeDetector(this._network);
  final Network _network;
  int detectCount = 0;

  @override
  Future<Network> detect({bool useSsid = false}) async {
    detectCount++;
    return _network;
  }

  @override
  Future<Network> detectFromState(NetworkState state) async {
    detectCount++;
    return _network;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
      'NetworkDetector.${invocation.memberName} '
      'not used by resolver tests',
    );
  }
}
