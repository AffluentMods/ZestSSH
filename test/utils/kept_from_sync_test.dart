import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/kept_from_sync.dart';

/// The key, snippet and group editors keep what a sync changed while they
/// were open, as the host editor does (found in a review).
typedef _Item = ({String name, int color, DateTime? at});

void main() {
  final t1 = DateTime(2026, 11, 1);
  final t2 = DateTime(2026, 11, 2);

  test('a field the person did not touch takes what a sync wrote; one they changed keeps theirs', () {
    const _Item? none = null;
    final loaded = (name: 'deploy', color: 1, at: t1);
    final now = (name: 'deploy key', color: 4, at: t2);
    final keep = keptSince<_Item>(loaded, now, (i) => i.at);
    expect(keep('deploy', (i) => i.name), 'deploy key');
    expect(keep(1, (i) => i.color), 4);
    expect(keep(7, (i) => i.color), 7);
    expect(keptSince<_Item>(none, now, (i) => i.at)('x', (i) => i.name), 'x');
  });

  test('with no change meanwhile (or no stamp at all), the form is written', () {
    final loaded = (name: 'deploy', color: 1, at: t1);
    expect(keptSince<_Item>(loaded, loaded, (i) => i.at)('ops', (i) => i.name), 'ops');
    final unstamped = (name: 'deploy', color: 1, at: null);
    final unstampedNow = (name: 'other', color: 2, at: null);
    expect(keptSince<_Item>(unstamped, unstampedNow, (i) => i.at)('deploy', (i) => i.name), 'deploy');
  });
}
