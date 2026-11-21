// Full screen on all monitors (4.1, Windows): the app talks to the runner's
// part that lists the monitors and stretches the window over one channel. A
// part not built into the runner, or naming the channel another way, answers
// nothing, and the menu never offers it. So the wiring is read here.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  const channel = 'zestssh/monitor_span';
  const calls = ['monitors', 'span', 'unspan'];

  test('the app and the Windows runner name the same channel and calls, and the part is built', () {
    final dart = read('lib/features/screens/desktop/screen_span.dart');
    expect(dart, contains("MethodChannel('$channel')"));
    final window = read('windows/runner/flutter_window.cpp');
    expect(window, contains('"$channel"'));
    expect(window, contains('SetUpMonitorSpan();'));
    for (final call in calls) {
      expect(dart, contains("'$call'"), reason: call);
      expect(window, contains('"$call"'), reason: call);
    }
    expect(read('windows/runner/CMakeLists.txt'), contains('"monitor_span.cpp"'));
    // The channel goes before the engine's other channels when the window does.
    expect(window.indexOf('span_channel_ = nullptr;'), lessThan(window.indexOf('deep_link_channel_ = nullptr;')));
  });

  test('leaving puts back the window\'s style, its place and its order', () {
    final span = read('windows/runner/monitor_span.cpp');
    expect(span, contains('SetWindowPlacement(window, &placement_)'));
    expect(span, contains('SetWindowLongPtrW(window, GWL_STYLE, style_)'));
    expect(span, contains('HWND_NOTOPMOST'));
  });
}
