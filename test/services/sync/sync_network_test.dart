import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/services/sync/sync_network.dart';

/// What background sync hears of the device's network (3.0):
/// whether there is one. A sync that waits its time after the store could
/// not be reached goes at once when there is one again.
void main() {
  test('every kind of network counts as one, and only none at all does not', () async {
    final heard = await networkUpOf(Stream.fromIterable(ConnectivityKind.values)).toList();
    expect(heard, [for (final kind in ConnectivityKind.values) kind != ConnectivityKind.none]);
    expect(heard.where((up) => !up), hasLength(1));
    expect(heard.where((up) => up), hasLength(ConnectivityKind.values.length - 1));
  });

  test('a network that goes and comes back is heard as that, in order', () async {
    final heard = await networkUpOf(Stream.fromIterable(const [
      ConnectivityKind.wifi,
      ConnectivityKind.none,
      ConnectivityKind.cellular,
      ConnectivityKind.none,
      ConnectivityKind.ethernet,
    ])).toList();
    expect(heard, [true, false, true, false, true]);
  });
}
