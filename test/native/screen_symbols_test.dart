import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';

/// The app's native library carries the remote screen engine (4.0: the features vnc and rdp from
/// the app's pubspec; ironrdp is the name of RDP's crates) and nothing a developer build adds: no
/// probe (the feature probes). The library is the one the build hook made for this machine,
/// which the app's tests load.
void main() {
  /// The library cargo built for this machine through the hook (the newest, should there be
  /// several targets in the shared folder).
  File builtLibrary() {
    final root = Directory('.dart_tool/hooks_runner/shared/zest_native/build/cargo');
    final names = {'zest_native.dll', 'libzest_native.so', 'libzest_native.dylib'};
    final found = [
      if (root.existsSync())
        for (final f in root.listSync(recursive: true).whereType<File>())
          if (names.contains(f.uri.pathSegments.last) && f.parent.uri.pathSegments.where((s) => s.isNotEmpty).last == 'release')
            f,
    ]..sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    if (found.isEmpty) fail('no zest_native library under ${root.path}: the build hook did not run');
    return found.first;
  }

  bool has(List<int> bytes, String text) {
    final needle = text.codeUnits;
    outer:
    for (var i = 0; i + needle.length <= bytes.length; i++) {
      for (var j = 0; j < needle.length; j++) {
        if (bytes[i + j] != needle[j]) continue outer;
      }
      return true;
    }
    return false;
  }

  test('the screen engine loads in the app and answers', () {
    // Through the same lookup the app uses (a @Native call into the hook-built library).
    final t0 = ScreenSession.nowUs();
    expect(ScreenSession.nowUs(), greaterThanOrEqualTo(t0));
  });

  test('the calls for displays and views are in the library with the shapes Dart calls them by', () {
    // Session 987654321 is not there: each call answers as the engine does for none (4.0).
    final native = RustScreenNative();
    expect(ScreenViewReader.open(987654321, x: 0, y: 0, width: 64, height: 64), isNull);
    expect(native.viewOpen(987654321, 0, 0, 64, 64, 1), 0);
    expect(native.viewAlive(987654321, 1), isFalse);
    expect(native.viewTakeFrame(987654321, 1), isNull);
    native.viewClose(987654321, 1);
    native.show(987654321, 0, 0, 64, 64);
    native.pointerRelative(987654321, 5, -5, 0);
    // The list is read before the session is looked for: a list of displays is taken, anything else is not.
    expect(native.displays(987654321, '[{"x":0,"y":0,"width":1920,"height":1080}]'), isTrue);
    expect(native.displays(987654321, '{"width":1920}'), isFalse);
    expect(native.displays(987654321, 'not json'), isFalse);
  });

  test('the built library has the zest_screen functions, RDP and the Mosh client, and no probe', () {
    final bytes = builtLibrary().readAsBytesSync();
    for (final symbol in [
      'zest_screen_open',
      'zest_screen_feed',
      'zest_screen_feed_end',
      'zest_screen_feed_fail',
      'zest_screen_pointer',
      'zest_screen_key',
      'zest_screen_clipboard',
      'zest_screen_clipboard_share',
      'zest_screen_resize',
      'zest_screen_pause',
      'zest_screen_resume',
      'zest_screen_full_refresh',
      // The remote's displays (4.0).
      'zest_screen_displays',
      // A part of the picture read by its own reader (a window for one display).
      'zest_screen_show',
      'zest_screen_pointer_relative',
      'zest_screen_view_open',
      'zest_screen_view_take_frame',
      'zest_screen_view_alive',
      'zest_screen_view_close',
      'zest_screen_take_frame',
      'zest_screen_free_frame',
      'zest_screen_free_bytes',
      'zest_screen_now_us',
      'zest_screen_close',
      // The remote's sound (4.0; cargo_features: sound).
      'zest_screen_sound',
      'zest_ftps_open',
      // The built-in Mosh client (4.0, cargo_features: mosh).
      'zest_mosh_open',
      'zest_mosh_keys',
      'zest_mosh_resize',
      'zest_mosh_close',
      'zest_mosh_free_bytes',
    ]) {
      expect(has(bytes, symbol), isTrue, reason: symbol);
    }
    // RDP is built in since 4.0 (pubspec.yaml, cargo_features: rdp): IronRDP's name is
    // in the library (its files' paths, for a session's "the engine stopped at" line).
    expect(has(bytes, 'ironrdp'), isTrue, reason: 'cargo_features has rdp');
    // And its sound channel and speaker (cargo_features: sound).
    expect(has(bytes, 'ironrdp-rdpsnd') || has(bytes, 'ironrdp_rdpsnd'), isTrue, reason: 'cargo_features has sound');
    // The developer probes are never in the app's library.
    for (final absent in ['zest_vnc_probe', 'zest_rdp_probe']) {
      expect(has(bytes, absent), isFalse, reason: absent);
    }
  });
}
