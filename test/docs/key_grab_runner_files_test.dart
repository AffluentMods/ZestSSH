// System keys to a full-screen remote screen (4.1, Windows): the app talks to
// the runner's keyboard hook over one channel. A part not built into the
// runner, or naming the channel another way, answers nothing and the keys
// stay this PC's with no error anywhere. So the wiring is read here: the same
// names on both sides, the same calls, the part in the runner's build, its
// messages seen before Flutter's, and the hook gone before the channels.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  const methods = 'zestssh/key_grab';
  const events = 'zestssh/key_grab/events';
  const calls = ['available', 'start', 'stop', 'renew'];

  test('the app names the channel, its events and its calls', () {
    final dart = read('lib/features/screens/view/screen_key_grab.dart');
    expect(dart, contains("MethodChannel('$methods')"));
    expect(dart, contains("EventChannel('$events')"));
    for (final call in const ['start', 'stop', 'renew']) {
      expect(dart, contains("'$call'"), reason: call);
    }
  });

  test('Windows: the part is in the runner, built, and answers the same names', () {
    final window = read('windows/runner/flutter_window.cpp');
    expect(window, contains('"$methods"'));
    expect(window, contains('"$events"'));
    for (final call in calls) {
      expect(window, contains('"$call"'), reason: call);
    }
    expect(window, contains('SetUpKeyGrab();'));
    expect(window.indexOf('key_grab_->OnMessage('), lessThan(window.indexOf('HandleTopLevelWindowProc(')));
    expect(window.indexOf('key_grab_ = nullptr;'), lessThan(window.indexOf('deep_link_channel_ = nullptr;')));
    expect(read('windows/runner/CMakeLists.txt'), contains('"key_grab.cpp"'));
    // The hook decides on a thread of its own, so a busy app never slows the
    // keyboard of the rest of the PC, and lets go without a renewal.
    final grab = read('windows/runner/key_grab.cpp');
    expect(grab, contains('WH_KEYBOARD_LL'));
    expect(grab, contains('std::thread('));
    expect(grab, contains('LLKHF_INJECTED'));
    expect(read('windows/runner/key_grab.h'), contains('kRenewWithinMs = 2000'));
  });

  test('the app renews well within the two seconds', () {
    final dart = read('lib/features/screens/view/screen_key_grab.dart');
    expect(dart, contains('renewEvery = Duration(milliseconds: 500)'));
  });
}
