import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';

/// Fake repository: holds an in-memory list and answers queries
/// synchronously. Lets us test the detector's logic without booting
/// SQLite or a Flutter binding.
class _FakeRepo implements NetworkRepository {
  _FakeRepo(this._networks);
  final List<Network> _networks;

  @override
  Future<List<Network>> list() async => _networks;

  // The detector only uses `list()` - the rest of the API can throw.
  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError(
        'Method ${invocation.memberName} not used by NetworkDetector tests');
  }
}

Network _net({
  required String id,
  required String name,
  required List<NetworkTrigger> triggers,
  bool isFallback = false,
}) {
  return Network(
    id: id,
    name: name,
    color: GroupColor.blue,
    icon: LucideIcons.globe,
    triggers: triggers,
    isFallback: isFallback,
  );
}

void main() {
  group('NetworkDetector.detectFromState', () {
    test('matches by subnet trigger', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'home',
          name: 'Home',
          triggers: const [SubnetTrigger('10.50.0.0/16')],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: ['10.50.5.7'],
        connectivityKind: ConnectivityKind.wifi,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'home');
    });

    test('matches by SSID trigger', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'home',
          name: 'Home',
          triggers: const [SsidTrigger('home-net')],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: ['192.0.2.5'],
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'home-net',
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'home');
    });

    test('matches by cellular trigger', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'cell',
          name: 'Cellular',
          triggers: const [CellularTrigger()],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: [],
        connectivityKind: ConnectivityKind.cellular,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'cell');
    });

    test('matches by connectivity trigger (ethernet)', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'wired',
          name: 'Wired',
          triggers: const [ConnectivityTrigger(ConnectivityKind.ethernet)],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: [],
        connectivityKind: ConnectivityKind.ethernet,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'wired');
    });

    test('falls through to Default when nothing else matches', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'home',
          name: 'Home',
          triggers: const [SubnetTrigger('10.50.0.0/16')],
        ),
        _net(
          id: 'cell',
          name: 'Cellular',
          triggers: const [CellularTrigger()],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: ['172.16.0.5'],
        connectivityKind: ConnectivityKind.wifi,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, kDefaultNetworkId);
    });

    test('respects evaluation order (first match wins)', () async {
      // Same CIDR matches both - first one in the list should win.
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'first',
          name: 'First',
          triggers: const [SubnetTrigger('192.168.0.0/16')],
        ),
        _net(
          id: 'second',
          name: 'Second',
          triggers: const [SubnetTrigger('192.168.0.0/16')],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: ['192.168.1.5'],
        connectivityKind: ConnectivityKind.wifi,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'first');
    });

    test('synthesises a default if repository returns empty list', () async {
      final detector = NetworkDetector(_FakeRepo(const []));
      final state = const NetworkState(
        localAddresses: ['10.0.0.5'],
        connectivityKind: ConnectivityKind.wifi,
      );
      final match = await detector.detectFromState(state);
      expect(match.isFallback, isTrue);
      expect(match.id, kDefaultNetworkId);
    });

    test('OR-combines multiple triggers on a single network', () async {
      // Network matches if EITHER subnet OR ssid matches.
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'home',
          name: 'Home',
          triggers: const [
            SubnetTrigger('10.50.0.0/16'),
            SsidTrigger('home-wifi'),
          ],
        ),
        Network.systemDefault(),
      ]));
      // SSID matches, subnet doesn't.
      final state = const NetworkState(
        localAddresses: ['192.0.2.1'],
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'home-wifi',
      );
      final match = await detector.detectFromState(state);
      expect(match.id, 'home');
    });

    test('skips invalid CIDR triggers gracefully', () async {
      final detector = NetworkDetector(_FakeRepo([
        _net(
          id: 'broken',
          name: 'Broken',
          triggers: const [SubnetTrigger('not-a-cidr')],
        ),
        Network.systemDefault(),
      ]));
      final state = const NetworkState(
        localAddresses: ['10.0.0.5'],
        connectivityKind: ConnectivityKind.wifi,
      );
      final match = await detector.detectFromState(state);
      expect(match.id, kDefaultNetworkId);
    });
  });
}
