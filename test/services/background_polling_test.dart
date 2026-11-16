import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/background_polling.dart';

/// Server Monitor and the reachability checks on a computer go on while its
/// window is not in front (found in a review): a window that loses
/// focus reports inactive, and they paused every time another window was
/// clicked. On a phone or tablet they still stop in the background.
void main() {
  test('a computer never stops them for its window', () {
    for (final state in AppLifecycleState.values) {
      expect(backgroundPollingStops(state, computer: true), isFalse, reason: '$state');
    }
  });

  test('a phone stops them in the background and not in front', () {
    expect(backgroundPollingStops(AppLifecycleState.inactive, computer: false), isTrue);
    expect(backgroundPollingStops(AppLifecycleState.paused, computer: false), isTrue);
    expect(backgroundPollingStops(AppLifecycleState.resumed, computer: false), isFalse);
  });
}
