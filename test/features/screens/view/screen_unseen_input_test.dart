// Remote screens: a view that is not seen sends nothing. A tab behind
// another, a hidden window, a picture covered by recording mode and a locked
// app all pause the view; a panel or a bar that is still on the screen then
// (the session panel over a covered picture) must not be a way to press keys
// on a remote computer nobody is looking at.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';

import 'screen_view_fixture.dart';

Future<(FakeScreenSession, ScreenController)> _connect(WidgetTester tester) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
  final engine = native.sessions.single;
  engine.connect(width: 800, height: 500);
  await tester.pump();
  final controller = ScreenController(session, decodeTile: syncDecode);
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  return (engine, controller);
}

void main() {
  final chord = ScreenAction.sendCtrlAltDel.keysWith(ScreenMenuKey.f8);

  testWidgets('paused: no key, no text and no pointer goes to the remote; seen again, they go', (tester) async {
    final (engine, c) = await _connect(tester);
    c.keyboard.sendChord(chord);
    expect(engine.keys, hasLength(chord.length * 2), reason: 'seen: the keys go');
    engine.keys.clear();
    engine.pointers.clear();

    c.pause();
    c.keyboard.sendChord(chord);
    c.keyboard.typeText('rm -rf');
    c.pointer.send(10, 10, 1);
    expect(engine.keys, isEmpty, reason: 'not seen: nothing is pressed on the remote');
    expect(engine.pointers, isEmpty);

    c.resume();
    c.keyboard.sendChord(chord);
    expect(engine.keys, hasLength(chord.length * 2));
  });

  testWidgets('a key held when the view stops being seen is let go on the remote before anything is refused', (tester) async {
    final (engine, c) = await _connect(tester);
    c.keyboard.handle(const KeyDownEvent(
      physicalKey: PhysicalKeyboardKey.controlLeft,
      logicalKey: LogicalKeyboardKey.controlLeft,
      timeStamp: Duration.zero,
    ));
    expect(engine.keys.where((k) => k.$3), hasLength(1));
    c.pause();
    final down = <int>{};
    for (final k in engine.keys) {
      k.$3 ? down.add(k.$1) : down.remove(k.$1);
    }
    expect(down, isEmpty, reason: 'its release was sent');
  });

  testWidgets('view only and paused are each enough, and leaving one does not undo the other', (tester) async {
    final (engine, c) = await _connect(tester);
    c.viewOnly = true;
    c.pause();
    c.resume();
    c.keyboard.sendChord(chord);
    expect(engine.keys, isEmpty, reason: 'seen again, still only looked at');
    c.pause();
    c.viewOnly = false;
    c.keyboard.sendChord(chord);
    expect(engine.keys, isEmpty, reason: 'no longer view only, still not seen');
    c.resume();
    c.keyboard.sendChord(chord);
    expect(engine.keys, isNotEmpty);
  });
}
