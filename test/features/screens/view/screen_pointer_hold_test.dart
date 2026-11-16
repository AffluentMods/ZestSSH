// Remote screens (4.0): relative mouse. The pointer is held by the
// computer (played here), its movement goes to the remote as movement, and
// every way out lets go of it: the release key, the picture losing the
// keyboard, the tab leaving, view only, the session ending, and the computer
// letting go by itself.
import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_pointer_hold.dart';

import 'screen_view_fixture.dart';

Future<(FakeScreenSession, ScreenController, FakeCapture)> _connect(WidgetTester tester, {bool taken = true}) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.rdp(relativeMouse: true), native: native);
  final engine = native.sessions.single;
  engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': 800, 'height': 500, 'relative_mouse': taken});
  await tester.pump();
  final capture = FakeCapture();
  final controller = ScreenController(session, decodeTile: syncDecode, capture: capture);
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  return (engine, controller, capture);
}

void main() {
  group('a way out while the computer is still answering', () {
    late FakeCapture capture;
    late List<(int, int, int)> sent;
    late ScreenPointerHold hold;

    setUp(() {
      capture = FakeCapture()..startLater = Completer<bool>();
      sent = [];
      hold = ScreenPointerHold(capture: capture, send: (dx, dy, b) => sent.add((dx, dy, b)));
    });

    test('let go of before the computer answered: it does not hold after all, and the computer is told to let go',
        () async {
      final grabbing = hold.grab();
      expect(hold.held, isFalse);
      // The release key, the tab leaving, the session ending: each is this.
      hold.release();
      capture.startLater!.complete(true);
      expect(await grabbing, isFalse);
      expect(hold.held, isFalse, reason: 'the way out is not lost in the moment of taking');
      expect(capture.stops, 1);
      expect(capture.renews, 0);
      // Movement the computer still reports goes nowhere.
      capture.move(5, 5);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
      // And it can be taken again, this time for good.
      capture.startLater = null;
      expect(await hold.grab(), isTrue);
      expect(hold.held, isTrue);
      hold.dispose();
    });

    test('the computer let go by itself before it answered: not held', () async {
      final grabbing = hold.grab();
      capture.lose();
      capture.startLater!.complete(true);
      expect(await grabbing, isFalse);
      expect(hold.held, isFalse);
      expect(capture.renews, 0);
      hold.dispose();
    });

    test('gone before the computer answered: nothing is held, nothing is left listening', () async {
      final grabbing = hold.grab();
      hold.dispose();
      capture.startLater!.complete(true);
      expect(await grabbing, isFalse);
      expect(capture.stops, 1);
      capture.lose();
      capture.move(1, 1);
      await Future<void>.delayed(Duration.zero);
      expect(sent, isEmpty);
    });

    test('nothing happened meanwhile: held as before, and a later loss lets go', () async {
      final grabbing = hold.grab();
      // A second click while the first is still being answered takes nothing twice.
      expect(await hold.grab(), isFalse);
      expect(capture.starts, 1);
      capture.startLater!.complete(true);
      expect(await grabbing, isTrue);
      expect(hold.held, isTrue);
      expect(capture.stops, 0);
      capture.lose();
      expect(hold.held, isFalse);
      expect(capture.stops, 0, reason: 'the computer let go itself: it is not told again');
      hold.dispose();
    });

    test('the computer says it cannot, after a wait: not held, and not told to let go of what it never held', () async {
      final grabbing = hold.grab();
      capture.startLater!.complete(false);
      expect(await grabbing, isFalse);
      expect(hold.held, isFalse);
      expect(capture.stops, 0);
      hold.dispose();
    });
  });

  group('the hold', () {
    late FakeCapture capture;
    late List<(int, int, int)> sent;
    late ScreenPointerHold hold;

    setUp(() {
      capture = FakeCapture();
      sent = [];
      hold = ScreenPointerHold(capture: capture, send: (dx, dy, b) => sent.add((dx, dy, b)));
    });

    testWidgets('held: the computer is told at once and twice a second that the app is there', (tester) async {
      expect(hold.held, isFalse);
      expect(await hold.grab(), isTrue);
      expect(hold.held, isTrue);
      expect((capture.starts, capture.renews), (1, 1));
      await tester.pump(ScreenPointerHold.renewEvery * 4);
      expect(capture.renews, 5);
      // Held already: not started again.
      expect(await hold.grab(), isTrue);
      expect(capture.starts, 1);
      hold.dispose();
    });

    testWidgets('movement goes out once a frame, summed', (tester) async {
      await hold.grab();
      capture
        ..move(3, 4)
        ..move(1, 1)
        ..move(-10, 0);
      expect(sent, isEmpty, reason: 'not before the frame');
      await tester.pump();
      expect(sent, [(-6, 5, 0)]);
      // Movement that comes to nothing sends nothing.
      capture
        ..move(5, 5)
        ..move(-5, -5);
      await tester.pump();
      expect(sent, hasLength(1));
      hold.dispose();
    });

    testWidgets('a button goes at once with the movement before it, and movement after carries it', (tester) async {
      await hold.grab();
      capture.move(7, 0);
      hold.buttons(1);
      expect(sent, [(7, 0, 1)], reason: 'the click lands where the movement ended');
      capture.move(2, 2);
      await tester.pump();
      expect(sent.last, (2, 2, 1));
      hold.buttons(1);
      expect(sent, hasLength(2), reason: 'the same buttons again are nothing');
      hold.buttons(0);
      expect(sent.last, (0, 0, 0));
      hold.dispose();
    });

    testWidgets('let go: the computer is told, nothing more is sent, and a button still down is let go of', (tester) async {
      await hold.grab();
      hold.buttons(4);
      capture.move(9, 9);
      hold.release();
      expect(hold.held, isFalse);
      expect(capture.stops, 1);
      expect(sent.last, (0, 0, 0), reason: 'the remote is not left with a button down');
      final count = sent.length;
      capture.move(50, 50);
      await tester.pump();
      await tester.pump(ScreenPointerHold.renewEvery * 3);
      expect(sent, hasLength(count));
      expect(capture.renews, 1, reason: 'no longer renewed');
      // Not held: buttons mean nothing, and letting go again is nothing.
      hold.buttons(1);
      hold.release();
      expect((sent.length, capture.stops), (count, 1));
      hold.dispose();
    });

    testWidgets('the computer let go by itself: not held, and it is not told to stop', (tester) async {
      await hold.grab();
      var changes = 0;
      hold.addListener(() => changes++);
      capture.lose();
      expect(hold.held, isFalse);
      expect(capture.stops, 0);
      expect(changes, 1);
      hold.dispose();
    });

    testWidgets('a computer that cannot hold it: not held', (tester) async {
      capture.startAnswer = false;
      expect(await hold.grab(), isFalse);
      expect(hold.held, isFalse);
      expect(capture.renews, 0);
      hold.dispose();
    });

    testWidgets('a movement past all reason is cut, and one that goes goes whole', (tester) async {
      await hold.grab();
      for (var i = 0; i < 100; i++) {
        capture.move(1 << 30, -(1 << 30));
      }
      await tester.pump();
      expect(sent.single, (ScreenPointerHold.most, -ScreenPointerHold.most, 0));
      hold.dispose();
    });

    testWidgets('gone while held: let go', (tester) async {
      await hold.grab();
      hold.dispose();
      expect(capture.stops, 1);
      await tester.pump(ScreenPointerHold.renewEvery * 3);
      expect(capture.renews, 1);
    });
  });

  group('a screen', () {
    testWidgets('relative mouse is only on where the server takes it', (tester) async {
      final (_, c, capture) = await _connect(tester, taken: false);
      expect(c.relativeTaken, isFalse);
      c.relativeMouse = true;
      expect(c.relativeMouse, isFalse);
      expect(c.takePointer(), isFalse);
      expect(capture.starts, 0);

      final (_, yes, _) = await _connect(tester);
      expect(yes.relativeTaken, isTrue);
      expect(yes.relativeMouse, isFalse, reason: 'never on by itself');
      yes.relativeMouse = true;
      expect(yes.relativeMouse, isTrue);
    });

    testWidgets('a click in the picture takes the pointer and is not a click; held, movement goes as movement and '
        'the mouse moving over the picture sends no place', (tester) async {
      final (engine, c, capture) = await _connect(tester);
      await pumpView(tester, c, size: const Size(800, 500));
      c.relativeMouse = true;
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(100, 100));
      await mouse.moveTo(const Offset(120, 110));
      await tester.pump();
      engine.pointers.clear();

      await mouse.down(const Offset(120, 110));
      await tester.pump();
      expect(c.hold.held, isTrue);
      expect(capture.starts, 1);
      expect(c.mouseCursor, SystemMouseCursors.none, reason: 'held: this computer shows no pointer over the picture');
      expect(engine.pointers, isEmpty, reason: 'the press that took the pointer is not a click');
      await mouse.up();
      await tester.pump();

      capture.move(15, -3);
      await tester.pump();
      expect(engine.relativePointers, [(15, -3, 0)]);
      await mouse.moveTo(const Offset(300, 300));
      await tester.pump();
      expect(engine.pointers, isEmpty, reason: 'where the pointer is means nothing while it is held');

      // A press and a lift while held: the buttons, with the movement.
      await mouse.down(const Offset(300, 300));
      await tester.pump();
      expect(engine.relativePointers.last, (0, 0, 1));
      await mouse.up();
      await tester.pump();
      expect(engine.relativePointers.last, (0, 0, 0));
      expect(engine.pointers, isEmpty);
    });

    testWidgets('the release key gets the pointer back and is that and nothing more; pressed again it is the menu key',
        (tester) async {
      final (engine, c, capture) = await _connect(tester);
      var menus = 0;
      await pumpView(tester, c, size: const Size(800, 500), onMenuKey: () => menus++);
      c.relativeMouse = true;
      await tester.tap(find.byKey(pictureKey), kind: PointerDeviceKind.mouse);
      await tester.pump();
      expect(c.hold.held, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      expect(c.hold.held, isFalse);
      expect(capture.stops, 1);
      expect(c.mouseCursor, SystemMouseCursors.basic, reason: 'let go: the pointer is shown again');
      expect(menus, 0, reason: 'the key got the pointer back; it did not open the menu');
      expect(engine.keys, isEmpty, reason: 'and never reached the remote');
      expect(c.relativeMouse, isTrue, reason: 'the switch stays on: the next click holds it again');

      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      await tester.pump();
      expect(menus, 1);
    });

    testWidgets('the picture losing the keyboard, the tab leaving, view only and the end of the session each let go',
        (tester) async {
      Future<(FakeScreenSession, ScreenController, FakeCapture, FocusNode)> held() async {
        final (engine, c, capture) = await _connect(tester);
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await pumpView(tester, c, size: const Size(800, 500), focusNode: focus);
        c.relativeMouse = true;
        await tester.tap(find.byKey(pictureKey), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(c.hold.held, isTrue);
        return (engine, c, capture, focus);
      }

      // The keyboard goes elsewhere (another window, a question of the app).
      var (engine, c, capture, focus) = await held();
      focus.unfocus();
      await tester.pump();
      expect((c.hold.held, capture.stops), (false, 1));

      // The tab is no longer in front.
      (engine, c, capture, focus) = await held();
      c.pause();
      expect((c.hold.held, capture.stops), (false, 1));

      // View only: let go, and relative mouse is off (nothing is sent at all).
      (engine, c, capture, focus) = await held();
      c.viewOnly = true;
      expect((c.hold.held, c.relativeMouse), (false, false));
      c.relativeMouse = true;
      expect(c.relativeMouse, isFalse, reason: 'not while the screen is only looked at');

      // The session ends.
      (engine, c, capture, focus) = await held();
      engine.closeWith('server', 'ended');
      await tester.pump();
      expect((c.hold.held, capture.stops), (false, 1));

      // The switch turned off.
      (engine, c, capture, focus) = await held();
      c.relativeMouse = false;
      expect((c.hold.held, capture.stops), (false, 1));

      // The computer let go by itself: the app follows.
      (engine, c, capture, focus) = await held();
      capture.lose();
      expect(c.hold.held, isFalse);
    });
  });
}
