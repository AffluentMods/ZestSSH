// Remote screens (4.0): relative mouse on a phone. In Mouse pointer
// mode, with the session's switch on, a finger's movement goes to the remote
// as movement, and so do its clicks, its drag and the wheel: no place is
// sent, since a game turns its view by how far the mouse moved. Touch mode is
// untouched by it, and a screen that is only looked at sends nothing.
import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';

import 'screen_view_fixture.dart';

Future<(FakeScreenSession, ScreenController)> _connect(WidgetTester tester, {bool taken = true}) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.rdp(relativeMouse: true), native: native);
  final engine = native.sessions.single;
  engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': 800, 'height': 500, 'relative_mouse': taken});
  await tester.pump();
  final controller = ScreenController(session, decodeTile: syncDecode, capture: FakeCapture());
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  await pumpView(tester, controller, size: const Size(800, 500));
  return (engine, controller);
}

const _left = 1;
const _right = 4;

void main() {
  testWidgets('a finger moving: how far, as movement, twice its way in counts; no place is sent', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    engine.pointers.clear();
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await finger.moveBy(const Offset(20, 0));
    await finger.moveBy(const Offset(15, -5));
    await finger.moveBy(const Offset(0.4, 0));
    await finger.moveBy(const Offset(0.4, 0));
    await finger.up();
    await tester.pump();
    final moved = engine.relativePointers.where((m) => m.$1 != 0 || m.$2 != 0).toList();
    expect(moved.every((m) => m.$3 == 0), isTrue, reason: 'no button while a finger only moves');
    final (dx, dy) = moved.fold((0, 0), (sum, m) => (sum.$1 + m.$1, sum.$2 + m.$2));
    // 35.8 to the right and 5 up, at two counts a pixel; the part of a count left over waits.
    expect((dx, dy), (71, -10));
    expect(engine.pointers, isEmpty, reason: 'where the pointer is means nothing to relative movement');
    // The place this device would draw a pointer at is not drawn: the remote draws its own.
    expect(c.cursorDraw.$1, ScreenCursorDraw.none);
  });

  testWidgets('a tap is a click, a hold and a lift a right click, two fingers tapped a right click', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    await tester.tapAt(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(engine.relativePointers, [(0, 0, _left), (0, 0, 0)]);
    engine.relativePointers.clear();

    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump(ScreenTouch.holdTime + const Duration(milliseconds: 50));
    await finger.up();
    await tester.pump();
    expect(engine.relativePointers, [(0, 0, _right), (0, 0, 0)]);
    engine.relativePointers.clear();

    final a = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(const Offset(340, 200), kind: PointerDeviceKind.touch);
    await a.up();
    await b.up();
    await tester.pump();
    expect(engine.relativePointers, [(0, 0, _right), (0, 0, 0)]);
    expect(engine.pointers, isEmpty);
  });

  testWidgets('a hold and then a move is a left drag: the button down, movement with it, the button up',
      (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump(ScreenTouch.holdTime + const Duration(milliseconds: 50));
    await finger.moveBy(const Offset(30, 0));
    await finger.moveBy(const Offset(10, 10));
    await finger.up();
    await tester.pump();
    expect(engine.relativePointers.first, (0, 0, _left));
    expect(engine.relativePointers.last, (0, 0, 0));
    final dragged = engine.relativePointers.sublist(1, engine.relativePointers.length - 1);
    expect(dragged, isNotEmpty);
    expect(dragged.every((m) => m.$3 == _left), isTrue);
    expect(dragged.fold(0, (sum, m) => sum + m.$1), 80);
    expect(engine.pointers, isEmpty);
  });

  testWidgets('two fingers dragged scroll the wheel, as buttons with no movement', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    final a = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(const Offset(340, 200), kind: PointerDeviceKind.touch);
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(0, 20));
      await b.moveBy(const Offset(0, 20));
    }
    await tester.pump(const Duration(seconds: 1));
    await a.up();
    await b.up();
    await tester.pump();
    expect(engine.relativePointers, isNotEmpty);
    expect(engine.relativePointers.every((m) => m.$1 == 0 && m.$2 == 0), isTrue);
    final wheel = engine.relativePointers.where((m) => m.$3 != 0).map((m) => m.$3).toSet();
    expect(wheel.length, 1, reason: 'one direction of the wheel');
    expect(wheel.single & 0x18, isNot(0), reason: 'a wheel bit, not a button');
    expect(engine.pointers, isEmpty);
  });

  testWidgets('Touch mode is a place as it always was, the switch on or not; and off, Mouse pointer mode is a place '
      'again', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.touch
      ..relativeMouse = true;
    await tester.tapAt(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(engine.relativePointers, isEmpty);
    expect(engine.pointers, isNotEmpty);
    expect(engine.pointers.first.$1, 300);

    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = false;
    engine.pointers.clear();
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await finger.moveBy(const Offset(40, 0));
    await finger.up();
    await tester.pump();
    expect(engine.relativePointers, isEmpty);
    expect(engine.pointers, isNotEmpty);
  });

  testWidgets('a screen that is only looked at sends nothing, and a server that does not take it leaves the finger '
      'a place', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true
      ..viewOnly = true;
    expect(c.relativeMouse, isFalse, reason: 'view only turns it off');
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await finger.moveBy(const Offset(40, 0));
    await finger.up();
    await tester.tapAt(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(engine.relativePointers, isEmpty);
    expect(engine.pointers, isEmpty);

    final (other, not) = await _connect(tester, taken: false);
    not
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    expect(not.relativeMouse, isFalse);
    await tester.tapAt(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(other.relativePointers, isEmpty);
    expect(other.pointers, isNotEmpty);
  });

  testWidgets('view only turned on and off again leaves relative mouse off for a finger too: it is a place again',
      (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true
      ..viewOnly = true
      ..viewOnly = false;
    expect(c.relativeMouse, isFalse, reason: 'the switch shows off');
    engine.pointers.clear();
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await finger.moveBy(const Offset(40, 0));
    await finger.up();
    await tester.pump();
    expect(engine.relativePointers, isEmpty, reason: 'no movement is sent with the switch off');
    expect(engine.pointers, isNotEmpty);
  });

  testWidgets('turned off in the middle of a drag: the button is let go the way it was pressed', (tester) async {
    final (engine, c) = await _connect(tester);
    c
      ..touchMode = ScreenTouchMode.mousePointer
      ..relativeMouse = true;
    final finger = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
    await tester.pump(ScreenTouch.holdTime + const Duration(milliseconds: 50));
    await finger.moveBy(const Offset(30, 0));
    expect(engine.relativePointers.last.$3, _left);
    c.relativeMouse = false;
    expect(engine.relativePointers.last, (0, 0, 0));
    expect(engine.pointers.where((p) => p.$3 != 0), isEmpty, reason: 'no click at a place because of it');
    await finger.up();
    await tester.pump();
  });
}
