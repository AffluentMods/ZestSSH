// Relative mouse on a remote screen (4.0): the app talks to each
// computer's own part over one channel. A part that is not built into its
// runner, or that names the channel another way, answers nothing, and the
// app then says "not available on this computer" with no error anywhere. So
// the wiring is read here: the same channel names on every side, the same
// four calls, and each part in its runner's build.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String read(String path) => File(path).readAsStringSync();

void main() {
  const methods = 'zestssh/pointer_capture';
  const events = 'zestssh/pointer_capture/events';
  const calls = ['available', 'start', 'stop', 'renew'];

  test('the app names the channel and its events', () {
    final dart = read('lib/features/screens/view/screen_pointer_hold.dart');
    expect(dart, contains("MethodChannel('$methods')"));
    expect(dart, contains("EventChannel('$events')"));
    for (final call in calls) {
      expect(dart, contains("'$call'"), reason: call);
    }
    expect(dart, contains("'lost'"));
  });

  test('Windows: the part is in the runner, built, and answers the same names', () {
    final window = read('windows/runner/flutter_window.cpp');
    expect(window, contains('"$methods"'));
    expect(window, contains('"$events"'));
    for (final call in calls) {
      expect(window, contains('"$call"'), reason: call);
    }
    expect(window, contains('std::string("lost")'));
    // The hold sees the window's messages before Flutter does, and the
    // pointer is given back before the window's channels go.
    expect(window.indexOf('pointer_hold_->OnMessage('), lessThan(window.indexOf('HandleTopLevelWindowProc(')));
    expect(window.indexOf('pointer_hold_ = nullptr;'), lessThan(window.indexOf('deep_link_channel_ = nullptr;')));
    expect(read('windows/runner/CMakeLists.txt'), contains('"pointer_hold.cpp"'));
    // The watch that frees a pointer when the app is stuck is a thread of
    // its own, not a timer of the window.
    final hold = read('windows/runner/pointer_hold.cpp');
    expect(hold, contains('std::thread(&PointerHold::Watch, this)'));
    expect(read('windows/runner/pointer_hold.h'), contains('kRenewWithinMs = 2000'));
  });

  test('macOS: the part is in the runner, built, and answers the same names', () {
    final part = read('macos/Runner/PointerCaptureChannel.swift');
    expect(part, contains('static let name = "$methods"'));
    expect(part, contains('static let eventsName = "$events"'));
    for (final call in calls) {
      expect(part, contains('case "$call":'), reason: call);
    }
    expect(part, contains('sink?("lost")'));
    expect(part, contains('renewWithin: TimeInterval = 2'));
    // The watch is on a queue of its own, not the main one.
    expect(part, contains('DispatchSource.makeTimerSource(queue: DispatchQueue.global('));
    expect(read('macos/Runner/MainFlutterWindow.swift'), contains('PointerCaptureChannel(messenger:'));
    final project = read('macos/Runner.xcodeproj/project.pbxproj');
    expect('PointerCaptureChannel.swift in Sources'.allMatches(project), hasLength(2));
    expect('PointerCaptureChannel.swift */'.allMatches(project).length, greaterThanOrEqualTo(3));
  });

  test('Linux: the part is in the runner, built, and answers the same names', () {
    final part = read('linux/runner/pointer_capture.cc');
    expect(part, contains('kMethods[] = "$methods"'));
    expect(part, contains('kEvents[] = "$events"'));
    for (final call in calls) {
      expect(part, contains('strcmp(name, "$call") == 0'), reason: call);
    }
    expect(part, contains('fl_value_new_string("lost")'));
    expect(part, contains('kRenewWithinUs = 2 * G_USEC_PER_SEC'));
    // Nothing is grabbed at the X server, and no barrier is made there: a
    // stuck program would keep either, and nothing could take it away.
    for (final never in const ['gdk_seat_grab', 'gdk_device_grab', 'XGrabPointer', 'XIGrabDevice', 'PointerBarrier']) {
      expect(part, isNot(contains(never)), reason: never);
    }
    // Under X11 it holds the pointer itself; every event still reaches GTK.
    expect(part, contains('GDK_IS_X11_DISPLAY('));
    // Under Wayland the compositor holds it: a lock asked for once, which the
    // compositor ends by itself, and the mouse's own movement. Only where the
    // compositor offers both protocols.
    expect(part, contains('GDK_IS_WAYLAND_DISPLAY('));
    expect(part, contains('ZWP_POINTER_CONSTRAINTS_V1_LIFETIME_ONESHOT'));
    expect(part, isNot(contains('LIFETIME_PERSISTENT')));
    expect(part, contains('self->constraints != nullptr && self->relative_manager != nullptr'));
    expect(part, contains('dx_unaccelerated'));
    final cmake = read('linux/runner/CMakeLists.txt');
    for (final generated in const [
      'pointer-constraints-unstable-v1-protocol.c',
      'relative-pointer-unstable-v1-protocol.c',
    ]) {
      expect(cmake, contains('"wayland/$generated"'), reason: generated);
      final code = read('linux/runner/wayland/$generated');
      expect(code, startsWith('/* Generated by wayland-scanner'), reason: 'generated, not written');
      expect(code, contains('Permission is hereby granted, free of charge'), reason: 'its licence stays');
    }
    // Built without the Wayland client library, the app builds and says "not available" there.
    expect(cmake, contains('if(ZEST_WAYLAND_CLIENT_FOUND)'));
    expect(part, contains('defined(GDK_WINDOWING_WAYLAND) && defined(ZEST_WAYLAND_POINTER)'));
    expect(part, contains('gtk_main_do_event(event);'));
    final app = read('linux/runner/my_application.cc');
    expect(app, contains('zest_pointer_capture_new('));
    expect(app, contains('g_clear_pointer(&self->pointer_capture, zest_pointer_capture_free);'));
    expect(read('linux/runner/CMakeLists.txt'), contains('"pointer_capture.cc"'));
  });

  test('the app lets the computer wait four renewals before it lets go', () {
    // Twice a second from the app, two seconds on the computer.
    expect(read('lib/features/screens/view/screen_pointer_hold.dart'),
        contains('renewEvery = Duration(milliseconds: 500)'));
  });
}
