import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/view/keysyms.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_key_grab.dart';
import 'package:zestssh/features/screens/view/screen_keyboard.dart';

import 'screen_view_fixture.dart';

/// System keys to a full-screen remote screen (4.1, Windows): the app asks
/// the native part for them only while the screen is in full screen with
/// the keyboard, Settings on, keys going to the remote and the tab seen;
/// renews it while it does; and sends what it gets as the keys they are,
/// let go with the rest.

/// The native part, played.
class _FakeGrabber implements KeyGrabber {
  final calls = <String>[];
  final _keys = StreamController<(int, int, bool, bool)>.broadcast();
  bool refuse = false;

  void press(int vk, {required bool down}) => _keys.add((vk, 0, false, down));

  @override
  Future<bool> start() async {
    calls.add('start');
    return !refuse;
  }

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  void renew() => calls.add('renew');

  @override
  Stream<(int, int, bool, bool)> get keys => _keys.stream;
}

void main() {
  late _FakeGrabber grabber;

  setUp(() {
    grabber = _FakeGrabber();
    ScreenController.debugKeyGrabber = grabber;
  });
  tearDown(() => ScreenController.debugKeyGrabber = null);

  test('every key the native part takes has its key here and goes as the remote knows it', () {
    expect(kGrabbedKeys.keys.toSet(), {0x5B, 0x5C, 0x5D, 0x2C, 0x09, 0x20, 0x73, 0x1B});
    expect(kGrabbedKeys[0x5B]!.$2, ScreenKey.superLeft);
    expect(kGrabbedKeys[0x09]!.$2, ScreenKey.tab);
    expect(kGrabbedKeys[0x1B]!.$2, ScreenKey.escape);
    expect(kGrabbedKeys[0x20]!.$2, ScreenKey.space);
    expect(kGrabbedKeys[0x73]!.$2, ScreenKey.f(4));
    expect(kGrabbedKeys[0x2C]!.$2, ScreenKey.printScreen);
  });

  testWidgets('asked for only in full screen with the keyboard; the Windows key goes to the remote', (tester) async {
    final rig = await ScreenRig.connect(tester);
    final c = rig.controller;
    c.systemKeysWanted = true;
    await tester.pump();
    expect(grabber.calls, isEmpty, reason: 'full screen, but the picture has not got the keyboard');
    c.keyboardFocused = true;
    await tester.pump();
    expect(grabber.calls, ['start']);
    expect(c.keyGrab.grabbing, isTrue);

    await tester.pump(ScreenKeyGrab.renewEvery * 3);
    expect(grabber.calls.where((x) => x == 'renew').length, 3);

    grabber.press(0x5B, down: true);
    await tester.pump();
    grabber.press(0x5B, down: false);
    await tester.pump();
    expect(rig.takeKeys(), [(0xffeb, 0xdb, true), (0xffeb, 0xdb, false)]);

    c.keyboardFocused = false;
    await tester.pump();
    expect(grabber.calls.last, 'stop');
    expect(c.keyGrab.grabbing, isFalse);
    grabber.press(0x5B, down: true);
    await tester.pump();
    expect(rig.takeKeys(), isEmpty, reason: 'a key that comes after the screen let go goes nowhere');
  });

  testWidgets('let go for view only, a tab not seen and a screen that goes; a key held is let go too', (tester) async {
    final rig = await ScreenRig.connect(tester);
    final c = rig.controller
      ..systemKeysWanted = true
      ..keyboardFocused = true;
    await tester.pump();
    expect(c.keyGrab.grabbing, isTrue);
    // Alt+Tab under way: Tab held on the remote.
    grabber.press(0x09, down: true);
    await tester.pump();
    expect(rig.takeKeys(), [(0xff09, 0x0f, true)]);

    c.viewOnly = true;
    await tester.pump();
    expect(c.keyGrab.grabbing, isFalse);
    expect(rig.takeKeys(), [(0xff09, 0x0f, false)], reason: 'the key held is let go on the remote');
    c.viewOnly = false;
    await tester.pump();
    expect(c.keyGrab.grabbing, isTrue);

    c.pause();
    await tester.pump();
    expect(c.keyGrab.grabbing, isFalse);
    c.resume();
    await tester.pump();
    expect(c.keyGrab.grabbing, isTrue);

    c.systemKeysWanted = false;
    await tester.pump();
    expect(c.keyGrab.grabbing, isFalse, reason: 'full screen left, or Settings off');
    c.systemKeysWanted = true;
    await tester.pump();
    expect(c.keyGrab.grabbing, isTrue);

    final stops = grabber.calls.where((x) => x == 'stop').length;
    c.dispose();
    await tester.pump();
    expect(grabber.calls.where((x) => x == 'stop').length, stops + 1);
  });

  testWidgets('a native part that refuses: nothing renewed, nothing sent', (tester) async {
    grabber.refuse = true;
    final rig = await ScreenRig.connect(tester);
    rig.controller
      ..systemKeysWanted = true
      ..keyboardFocused = true;
    await tester.pump(ScreenKeyGrab.renewEvery * 2);
    expect(grabber.calls, ['start']);
    expect(rig.controller.keyGrab.grabbing, isFalse);
  });

  testWidgets('one screen at a time: a second screen asking takes the keys from the first', (tester) async {
    final a = await ScreenRig.connect(tester);
    final b = await ScreenRig.connect(tester);
    a.controller
      ..systemKeysWanted = true
      ..keyboardFocused = true;
    await tester.pump();
    b.controller
      ..systemKeysWanted = true
      ..keyboardFocused = true;
    await tester.pump();
    grabber.press(0x5B, down: true);
    await tester.pump();
    expect(a.takeKeys(), isEmpty);
    expect(b.takeKeys(), [(0xffeb, 0xdb, true)]);
    // The first letting go does not stop the second's.
    final stops = grabber.calls.where((x) => x == 'stop').length;
    a.controller.keyboardFocused = false;
    await tester.pump();
    expect(grabber.calls.where((x) => x == 'stop').length, stops);
    expect(b.controller.keyGrab.grabbing, isTrue);
  });

  testWidgets('on Windows the Windows key stays this PC\'s outside full screen, and is the remote\'s in it',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      final rig = await ScreenRig.connect(tester);
      final c = rig.controller;
      KeyEvent down(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
          KeyDownEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);
      expect(c.keyboard.handle(down(PhysicalKeyboardKey.metaLeft, LogicalKeyboardKey.metaLeft)), KeyEventResult.ignored);
      expect(rig.takeKeys(), isEmpty, reason: 'Windows opens its own Start on it: not the remote\'s too');
      // Letters and the rest still go.
      expect(
          c.keyboard.handle(KeyDownEvent(
              physicalKey: PhysicalKeyboardKey.keyA, logicalKey: LogicalKeyboardKey.keyA, character: 'a', timeStamp: Duration.zero)),
          KeyEventResult.handled);
      rig.takeKeys();
      // Full screen with the keyboard: the hook's, and the remote's.
      c
        ..systemKeysWanted = true
        ..keyboardFocused = true;
      await tester.pump();
      grabber.press(0x5B, down: true);
      await tester.pump();
      expect(rig.takeKeys(), [(0xffeb, 0xdb, true)]);
      grabber.press(0x5B, down: false);
      await tester.pump();
      rig.takeKeys();
      c.systemKeysWanted = false;
      await tester.pump();
      expect(c.keyboard.keepSuperLocal, isTrue);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('without scancodes only the keysym goes', () {
    final sent = <(int, int, bool)>[];
    final k = ScreenKeyboard((keysym, scancode, down) => sent.add((keysym, scancode, down)))..sendScancodes = false;
    k.grabbedKey(PhysicalKeyboardKey.metaLeft, ScreenKey.superLeft, down: true);
    expect(sent.single, (0xffeb, 0, true));
  });
}
