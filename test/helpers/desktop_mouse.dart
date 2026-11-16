import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

/// A widget test as on a computer: a mouse shows what is under it from the
/// first frame, as it does in the app there. (On a phone a mouse only counts
/// once it has been used, and what shows under it is decided before that.)
void desktopTest(String name, Future<void> Function(WidgetTester) body) {
  testWidgets(name, (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await body(tester);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });
}

/// One mouse for a test, used the way a person uses one: it is moved over
/// something, and what is under it is pressed. Unlike [WidgetTester.tap],
/// which touches a place without anything having been over it, this keeps
/// where the mouse is, so what only shows under the mouse shows, and what
/// leaves when the mouse is elsewhere leaves.
class TestMouse {
  /// The one mouse of [tester]'s test: asking again gives the same mouse,
  /// where it was left.
  factory TestMouse(WidgetTester tester) =>
      _mice[tester] ??= TestMouse._(tester);

  TestMouse._(this.tester);

  static final _mice = Expando<TestMouse>();

  final WidgetTester tester;
  TestGesture? _gesture;
  int _buttons = kPrimaryButton;

  /// Where the mouse was last put.
  Offset at = const Offset(5, 5);

  Future<TestGesture> _with(int buttons) async {
    final current = _gesture;
    if (current != null && _buttons == buttons) return current;
    await putAway();
    final gesture = await tester.createGesture(
        kind: PointerDeviceKind.mouse, buttons: buttons);
    await gesture.addPointer(location: at);
    _gesture = gesture;
    _buttons = buttons;
    addTearDown(putAway);
    await tester.pump();
    return gesture;
  }

  /// Takes the mouse away (nothing is under it any more).
  Future<void> putAway() async {
    final gesture = _gesture;
    _gesture = null;
    if (gesture != null) await gesture.removePointer();
  }

  /// Moves the mouse to [where] without pressing anything.
  Future<void> moveTo(Offset where) async {
    final gesture = await _with(_buttons);
    await gesture.moveTo(where);
    at = where;
    await tester.pumpAndSettle();
  }

  Future<void> moveOver(Finder what) => moveTo(tester.getCenter(what));

  Future<void> _press(Offset where, int buttons) async {
    final gesture = await _with(buttons);
    await gesture.moveTo(where);
    at = where;
    await tester.pump();
    await gesture.down(where);
    await gesture.up();
    await tester.pumpAndSettle();
  }

  /// Moves over [what] and clicks it with the left button.
  Future<void> click(Finder what) => _press(tester.getCenter(what), kPrimaryButton);

  Future<void> clickAt(Offset where) => _press(where, kPrimaryButton);

  /// Moves over [what] and clicks it with the right button.
  Future<void> rightClick(Finder what) =>
      _press(tester.getCenter(what), kSecondaryButton);
}
