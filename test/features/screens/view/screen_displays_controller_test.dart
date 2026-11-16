// Remote screens (4.0): a remote with several displays is shown one at
// a time or all at once. The controller on the fake engine: what it tells the
// app of the displays, what it asks the engine to hand it, where the pointer
// goes, the keys that change the display, and what happens to the picture and
// the view when the display or the remote changes.
import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';

import 'screen_view_fixture.dart';

const _two = [
  [0, 0, 1920, 1080],
  [1920, 0, 1280, 1024],
];

class _Rig {
  _Rig(this.native, this.session, this.engine, this.controller);
  final FakeScreenNative native;
  final ScreenSession session;
  final FakeScreenSession engine;
  final ScreenController controller;
  int _seq = 0;

  /// A connected RDP session whose engine tells [displays] (rectangles of a
  /// picture of [width] by [height]), and its controller.
  static Future<_Rig> connect(
    WidgetTester tester, {
    int width = 3200,
    int height = 1080,
    List<List<int>>? displays = _two,
    ScreenTileDecoder decode = syncDecode,
  }) async {
    final native = FakeScreenNative();
    final session = ScreenSession.open(const ScreenConnectOptions.rdp(), native: native);
    final engine = native.sessions.single;
    engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': width, 'height': height, 'displays': ?displays});
    await tester.pump();
    final controller = ScreenController(session, decodeTile: decode);
    addTearDown(() {
      controller.dispose();
      session.close();
    });
    await tester.pump();
    return _Rig(native, session, engine, controller);
  }

  /// The engine has a frame of [width] by [height] ready, one tile of [color].
  void frame(int width, int height, Color color) {
    _seq++;
    engine.frames.add(ScreenFrame(seq: _seq, width: width, height: height, updates: 1, tiles: [tile(0, 0, 8, 8, color)]));
    engine.emit(ScreenEventKind.frame, a: _seq);
  }

  ScreenDisplays get displays => controller.displays.value;
}

KeyEvent _down(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
    KeyDownEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);
KeyEvent _up(PhysicalKeyboardKey p, LogicalKeyboardKey l) =>
    KeyUpEvent(physicalKey: p, logicalKey: l, timeStamp: Duration.zero);

void main() {
  group('the displays told to the app', () {
    testWidgets('a remote with two: both, numbered from the first, all of them shown', (tester) async {
      final r = await _Rig.connect(tester);
      expect(r.displays.several, isTrue);
      expect(r.displays.list, const [
        ScreenDisplay(index: 0, x: 0, y: 0, width: 1920, height: 1080, primary: true),
        ScreenDisplay(index: 1, x: 1920, y: 0, width: 1280, height: 1024),
      ]);
      expect(r.displays.shown, isNull);
      expect(r.displays.shownDisplay, isNull);
      expect((r.controller.width, r.controller.height), (3200, 1080));
      expect((r.controller.desktopWidth, r.controller.desktopHeight), (3200, 1080));
      expect(r.engine.shown, isEmpty, reason: 'all of the picture is what the engine gives without being asked');
    });

    testWidgets('a remote with one, or one that tells none (VNC): nothing to pick', (tester) async {
      for (final displays in <List<List<int>>?>[
        null,
        const [
          [0, 0, 1280, 800],
        ],
      ]) {
        final r = await _Rig.connect(tester, width: 1280, height: 800, displays: displays);
        expect(r.displays.several, isFalse);
        expect(r.displays.list, isEmpty);
        // Asking for a display there is not shows all, and asks the engine for nothing.
        r.controller.showDisplay(1);
        r.controller.stepDisplay(next: true);
        expect(r.displays.shown, isNull);
        expect(r.engine.shown, isEmpty);
        expect(r.controller.width, 1280);
      }
    });

    testWidgets('a display that is not inside the picture is not one, and four at most are told', (tester) async {
      final r = await _Rig.connect(tester, width: 3200, height: 1080, displays: const [
        [0, 0, 1920, 1080],
        [1920, 0, 1280, 1024],
        [3000, 0, 800, 600],
      ]);
      expect(r.displays.list, hasLength(2));
      final many = await _Rig.connect(tester, width: 600, height: 100, displays: [
        for (var i = 0; i < 6; i++) [i * 100, 0, 100, 100],
      ]);
      expect(many.displays.list, hasLength(ScreenDisplays.most));
    });
  });

  group('one display shown', () {
    testWidgets('the engine is asked for that part, which is the screen from then on', (tester) async {
      final r = await _Rig.connect(tester);
      r.controller.showDisplay(1);
      expect(r.engine.shown, [(1920, 0, 1280, 1024)]);
      expect(r.displays.shown, 1);
      expect(r.displays.shownDisplay!.width, 1280);
      expect((r.controller.width, r.controller.height), (1280, 1024));
      expect((r.controller.desktopWidth, r.controller.desktopHeight), (3200, 1080), reason: 'the desktop is still all of it');
      // Its frames are the part's: applied as they come.
      r.frame(1280, 1024, const Color(0xFF00FF00));
      await tester.pump();
      await tester.pump();
      expect(r.controller.hasPicture, isTrue);
      expect((r.controller.width, r.controller.height), (1280, 1024));
    });

    testWidgets('the pointer goes out at its place in the whole desktop', (tester) async {
      final r = await _Rig.connect(tester);
      r.controller.pointer.send(10, 20, 0);
      r.controller.showDisplay(1);
      r.controller.pointer.send(10, 20, 1);
      r.controller.showDisplay(null);
      r.controller.pointer.send(10, 20, 0);
      expect(r.engine.pointers, [(10, 20, 0), (1930, 20, 1), (10, 20, 0)]);
    });

    testWidgets('all of them again: the engine is told, and the screen is the desktop', (tester) async {
      final r = await _Rig.connect(tester);
      r.controller.showDisplay(0);
      r.controller.showDisplay(null);
      expect(r.engine.shown, [(0, 0, 1920, 1080), (0, 0, 0, 0)]);
      expect(r.displays.shown, isNull);
      expect(r.controller.width, 3200);
      // The same again asks nothing.
      r.controller.showDisplay(null);
      r.controller.showDisplay(7);
      expect(r.engine.shown, hasLength(2));
    });

    testWidgets('next and previous go round the displays, and from all of them to the first or the last', (tester) async {
      final r = await _Rig.connect(tester);
      final c = r.controller;
      c.stepDisplay(next: true);
      expect(r.displays.shown, 0);
      c.stepDisplay(next: true);
      expect(r.displays.shown, 1);
      c.stepDisplay(next: true);
      expect(r.displays.shown, 0, reason: 'round the end');
      c.stepDisplay(next: false);
      expect(r.displays.shown, 1);
      c.showDisplay(null);
      c.stepDisplay(next: false);
      expect(r.displays.shown, 1, reason: 'from all of them, back is the last');
    });

    testWidgets('a frame taken before the display changed is not drawn as the new one', (tester) async {
      // A decoder that waits: the frame is in the air while the display changes.
      final gate = Completer<void>();
      final decoded = <ui.Image>[];
      Future<ui.Image> slow(ScreenTile t) async {
        final image = await syncDecode(t);
        decoded.add(image);
        await gate.future;
        return image;
      }

      final r = await _Rig.connect(tester, decode: slow);
      r.frame(3200, 1080, const Color(0xFFFF0000));
      await tester.pump();
      await tester.pump();
      expect(decoded, hasLength(1), reason: 'taken, not yet shown');
      r.controller.showDisplay(1);
      gate.complete();
      await tester.pump();
      await tester.pump();
      expect(r.controller.hasPicture, isFalse, reason: 'the whole desktop is not the second display');
      expect((r.controller.width, r.controller.height), (1280, 1024));
      expect(decoded.single.debugDisposed, isTrue);
    });

    testWidgets('each display keeps the view it was left at', (tester) async {
      final r = await _Rig.connect(tester);
      final c = r.controller;
      c.layoutView(const Size(960, 540));
      c.showDisplay(0);
      c.viewport.zoomTo(3, const Offset(100, 100), const Offset(50, 50));
      expect(c.viewport.zoom, 3);
      c.showDisplay(1);
      expect(c.viewport.zoom, 1, reason: 'a display not seen yet starts whole');
      c.viewport.zoomTo(2, const Offset(10, 10), const Offset(5, 5));
      c.showDisplay(0);
      expect(c.viewport.zoom, 3);
      c.showDisplay(1);
      expect(c.viewport.zoom, 2);
    });
  });

  group('the remote changes', () {
    testWidgets('a display that goes: all of them are shown, and it is shown again when it is back', (tester) async {
      final r = await _Rig.connect(tester);
      r.controller.showDisplay(1);
      // The server made one screen of it.
      r.engine
        ..emit(ScreenEventKind.resize, a: (1920 << 32) | 1080)
        ..displays(const [
          [0, 0, 1920, 1080],
        ]);
      await tester.pump();
      expect(r.displays.several, isFalse);
      expect(r.displays.shown, isNull);
      expect(r.controller.width, 1920);
      expect(r.engine.shown.last, (0, 0, 0, 0));
      // Two again: the second, as its person had chosen.
      r.engine
        ..emit(ScreenEventKind.resize, a: (3200 << 32) | 1080)
        ..displays(_two);
      await tester.pump();
      expect(r.displays.shown, 1);
      expect(r.engine.shown.last, (1920, 0, 1280, 1024));
      expect(r.controller.width, 1280);
    });

    testWidgets('the shown display gets another size: the engine is asked for the part again', (tester) async {
      final r = await _Rig.connect(tester);
      r.controller.showDisplay(0);
      r.engine
        ..emit(ScreenEventKind.resize, a: (2880 << 32) | 1024)
        ..displays(const [
          [0, 0, 1600, 900],
          [1600, 0, 1280, 1024],
        ]);
      await tester.pump();
      expect(r.displays.shown, 0);
      expect(r.engine.shown.last, (0, 0, 1600, 900));
      expect((r.controller.width, r.controller.height), (1600, 900));
    });

    testWidgets('one screen that is resized keeps its pointer where it was', (tester) async {
      final r = await _Rig.connect(tester, width: 1280, height: 800, displays: null);
      r.controller.pointer.send(300, 200, 0);
      r.engine.emit(ScreenEventKind.resize, a: (1600 << 32) | 900);
      await tester.pump();
      expect((r.controller.width, r.controller.height), (1600, 900));
      expect(r.controller.pointer.placed, isTrue);
      expect((r.controller.pointer.x, r.controller.pointer.y), (300, 200));
      expect(r.engine.shown, isEmpty);
    });
  });

  group('a view that follows its size', () {
    testWidgets('a host with several displays asks for that many at the size the view has, not for one resized', (
      tester,
    ) async {
      final r = await _Rig.connect(tester, width: 2560, height: 800, displays: const [
        [0, 0, 1280, 800],
        [1280, 0, 1280, 800],
      ]);
      r.controller.displayCount = 2;
      await pumpView(tester, r.controller, size: const Size(1280, 800));
      r.controller.followViewSize = true;
      await tester.pump(Duration.zero);
      // What the remote has already: nothing is asked.
      expect(r.engine.layouts, isEmpty);
      expect(r.engine.resizes, isEmpty);

      tester.view.physicalSize = const Size(1001, 700);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(ScreenController.resizeSettle);
      expect(r.engine.resizes, isEmpty, reason: 'a resize would make one display of the two');
      expect(r.engine.layouts, [
        [
          {'x': 0, 'y': 0, 'width': 1000, 'height': 700, 'primary': true},
          {'x': 1000, 'y': 0, 'width': 1000, 'height': 700},
        ],
      ]);
    });

    testWidgets('a host with a text size keeps it in the layout a view asks for', (tester) async {
      final r = await _Rig.connect(tester, width: 2560, height: 800, displays: const [
        [0, 0, 1280, 800],
        [1280, 0, 1280, 800],
      ]);
      r.controller
        ..displayCount = 2
        ..textScale = 150;
      await pumpView(tester, r.controller, size: const Size(1280, 800));
      r.controller.followViewSize = true;
      await tester.pump(Duration.zero);
      tester.view.physicalSize = const Size(1001, 700);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.pump(ScreenController.resizeSettle);
      expect(r.engine.layouts, [
        [
          {'x': 0, 'y': 0, 'width': 1000, 'height': 700, 'scale': 150, 'primary': true},
          {'x': 1000, 'y': 0, 'width': 1000, 'height': 700, 'scale': 150},
        ],
      ]);
    });

    testWidgets('another text size in the running session: the displays the remote has, each with it; a size '
        'that is none of the five is not asked for', (tester) async {
      // One display.
      final one = await _Rig.connect(tester, width: 1280, height: 800, displays: null);
      await pumpView(tester, one.controller, size: const Size(1280, 800));
      one.controller.setTextScale(150);
      expect(one.controller.textScale, 150);
      expect(one.engine.layouts, [
        [
          {'x': 0, 'y': 0, 'width': 1280, 'height': 800, 'scale': 150, 'primary': true},
        ],
      ]);
      one.controller.setTextScale(137);
      expect(one.engine.layouts, hasLength(1));
      expect(one.controller.textScale, 150);
      // Back to nothing said: a layout without a scale.
      one.controller.setTextScale(0);
      expect(one.engine.layouts.last, [
        {'x': 0, 'y': 0, 'width': 1280, 'height': 800, 'primary': true},
      ]);

      // Two displays, the second shown: both keep their places and sizes.
      final two = await _Rig.connect(tester, width: 3200, height: 1080, displays: const [
        [0, 0, 1920, 1080],
        [1920, 0, 1280, 1024],
      ]);
      await pumpView(tester, two.controller, size: const Size(1280, 800));
      two.controller.showDisplay(1);
      two.controller.setTextScale(200);
      expect(two.engine.layouts, [
        [
          {'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'scale': 200, 'primary': true},
          {'x': 1920, 'y': 0, 'width': 1280, 'height': 1024, 'scale': 200},
        ],
      ]);
    });

    testWidgets('a host with one display asks for a resize, as before', (tester) async {
      final r = await _Rig.connect(tester, width: 1280, height: 800, displays: null);
      await pumpView(tester, r.controller, size: const Size(1000, 700));
      r.controller.followViewSize = true;
      await tester.pump(Duration.zero);
      expect(r.engine.resizes, [(1000, 700)]);
      expect(r.engine.layouts, isEmpty);
    });
  });

  group('a frame rate limit', () {
    testWidgets('15 a second: a frame that comes sooner waits for its time, and is drawn then; nothing is lost',
        (tester) async {
      final r = await _Rig.connect(tester, width: 800, height: 500, displays: null);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      await settleFrames(tester);
      r.controller.frameLimit = 15;
      expect(r.controller.frameLimit, 15);
      final shown = r.controller.framesShown;
      r.frame(800, 500, const Color(0xFF102030));
      await tester.pump();
      await tester.pump();
      expect(r.controller.framesShown, shown + 1, reason: 'the first goes at once');
      r.frame(800, 500, const Color(0xFF405060));
      await tester.pump(const Duration(milliseconds: 30));
      await tester.pump();
      expect(r.controller.framesShown, shown + 1, reason: 'not before a fifteenth of a second has passed');
      expect(r.engine.frames, hasLength(1), reason: 'it waits in the engine, where later ones are merged into it');
      await tester.pump(const Duration(milliseconds: 40));
      await tester.pump();
      await tester.pump();
      expect(r.controller.framesShown, shown + 2);
      expect(r.engine.frames, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('the limit taken away while a frame waits: it is drawn at once; and gone with a wait running, '
        'nothing is left behind', (tester) async {
      final r = await _Rig.connect(tester, width: 800, height: 500, displays: null);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      await settleFrames(tester);
      r.controller.frameLimit = 15;
      final shown = r.controller.framesShown;
      r.frame(800, 500, const Color(0xFF102030));
      await tester.pump();
      await tester.pump();
      r.frame(800, 500, const Color(0xFF405060));
      await tester.pump(const Duration(milliseconds: 5));
      expect(r.controller.framesShown, shown + 1);
      r.controller.frameLimit = 0;
      await tester.pump();
      await tester.pump();
      expect(r.controller.framesShown, shown + 2);
      // A wait running when the controller goes (the test would fail on a timer left behind).
      r.controller.frameLimit = 15;
      r.frame(800, 500, const Color(0xFF708090));
      await tester.pump();
      await tester.pump();
      r.controller.frameLimit = -5;
      expect(r.controller.frameLimit, 0);
      r.controller.frameLimit = 30;
      r.frame(800, 500, const Color(0xFF0A0B0C));
      await tester.pump();
      await tester.pump();
    });
  });

  group('shown elsewhere (a window of its own)', () {
    testWidgets('idle: no frame is taken and nothing is sent; back, what waited is taken at once', (tester) async {
      final r = await _Rig.connect(tester, width: 800, height: 500, displays: null);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      r.frame(800, 500, const Color(0xFF102030));
      await settleFrames(tester);
      final shown = r.controller.framesShown;
      expect(shown, greaterThan(0));

      var told = 0;
      r.controller.addListener(() => told++);
      r.controller.idle = true;
      expect(told, 1, reason: 'the tab is told, to say so in the picture place');
      r.frame(800, 500, const Color(0xFF405060));
      await settleFrames(tester);
      expect(r.controller.framesShown, shown);
      expect(r.engine.frames, hasLength(1), reason: 'it waits in the engine');
      expect(r.engine.pauses, 0, reason: 'the server goes on sending for the window');

      r.controller.idle = false;
      await settleFrames(tester);
      expect(r.controller.framesShown, shown + 1);
      expect(r.engine.frames, isEmpty);
    });

    testWidgets('a tab that is not seen does not stop the server while its screen is shown elsewhere',
        (tester) async {
      final r = await _Rig.connect(tester, width: 800, height: 500, displays: null);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      // Not seen, then shown elsewhere: the server is asked to send again.
      r.controller.pause();
      expect((r.engine.pauses, r.engine.resumes), (1, 0));
      r.controller.idle = true;
      expect((r.engine.pauses, r.engine.resumes), (1, 1));
      // Seen and not seen again meanwhile: the server is left alone.
      r.controller.resume();
      r.controller.pause();
      expect((r.engine.pauses, r.engine.resumes), (1, 1));
      // Back in a tab that is still not seen: the server stops again.
      r.controller.idle = false;
      expect((r.engine.pauses, r.engine.resumes), (2, 1));
      r.controller.resume();
      expect((r.engine.pauses, r.engine.resumes), (2, 2));
    });
  });

  group('three fingers sideways', () {
    Future<List<TestGesture>> threeDown(WidgetTester tester) async => [
          await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch),
          await tester.startGesture(const Offset(360, 200), kind: PointerDeviceKind.touch),
          await tester.startGesture(const Offset(420, 200), kind: PointerDeviceKind.touch),
        ];

    Future<void> moveAll(WidgetTester tester, List<TestGesture> fingers, Offset by) async {
      for (final f in fingers) {
        await f.moveBy(by);
      }
      await tester.pump();
    }

    Future<void> lift(WidgetTester tester, List<TestGesture> fingers) async {
      for (final f in fingers) {
        await f.up();
      }
      await tester.pump();
    }

    testWidgets('to the left is the next display, to the right the one before, once for each swipe', (tester) async {
      final r = await _Rig.connect(tester);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      var fingers = await threeDown(tester);
      await moveAll(tester, fingers, const Offset(-30, 2));
      expect(r.displays.shown, isNull, reason: 'not far enough yet');
      await moveAll(tester, fingers, const Offset(-40, 2));
      expect(r.displays.shown, 0, reason: 'from all of them, next is the first');
      // The same fingers going on change nothing more.
      await moveAll(tester, fingers, const Offset(-200, 0));
      expect(r.displays.shown, 0);
      await lift(tester, fingers);

      fingers = await threeDown(tester);
      await moveAll(tester, fingers, const Offset(-80, 0));
      expect(r.displays.shown, 1);
      await lift(tester, fingers);

      fingers = await threeDown(tester);
      await moveAll(tester, fingers, const Offset(80, 0));
      expect(r.displays.shown, 0, reason: 'to the right: the one before');
      await lift(tester, fingers);

      // Nothing of it reached the remote: no click, no wheel, no right click on lifting.
      expect(r.engine.pointers, isEmpty);
      expect(r.controller.viewport.zoom, 1, reason: 'nor is it a pinch');
    });

    testWidgets('up or down is not a change of display, and with one display a third finger is nothing', (tester) async {
      final r = await _Rig.connect(tester);
      await pumpView(tester, r.controller, size: const Size(800, 500));
      final fingers = await threeDown(tester);
      await moveAll(tester, fingers, const Offset(-60, 90));
      expect(r.displays.shown, isNull);
      await lift(tester, fingers);

      final one = await _Rig.connect(tester, width: 1280, height: 800, displays: null);
      await pumpView(tester, one.controller, size: const Size(800, 500));
      final three = await threeDown(tester);
      await moveAll(tester, three, const Offset(-120, 0));
      await lift(tester, three);
      expect(one.displays.shown, isNull);
      expect(tester.takeException(), isNull);
    });
  });

  group('Ctrl+Alt+Left and Right', () {
    Future<void> press(ScreenController c, LogicalKeyboardKey arrow, PhysicalKeyboardKey physical) async {
      c.keyboard
        ..handle(_down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft))
        ..handle(_down(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft));
      expect(c.keyboard.handle(_down(physical, arrow)), KeyEventResult.handled);
      c.keyboard
        ..handle(_up(physical, arrow))
        ..handle(_up(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft))
        ..handle(_up(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft));
    }

    testWidgets('change the display and never reach the remote, where there are several', (tester) async {
      final r = await _Rig.connect(tester);
      await press(r.controller, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
      expect(r.displays.shown, 0);
      await press(r.controller, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
      expect(r.displays.shown, 1);
      await press(r.controller, LogicalKeyboardKey.arrowLeft, PhysicalKeyboardKey.arrowLeft);
      expect(r.displays.shown, 0);
      // Ctrl and Alt went down and up three times; no arrow went at all.
      const arrows = {0xff51, 0xff53};
      expect(r.engine.keys.where((k) => arrows.contains(k.$1)), isEmpty);
      expect(r.engine.keys, hasLength(12));
    });

    testWidgets('are the remote keys where it has one display', (tester) async {
      final r = await _Rig.connect(tester, width: 1280, height: 800, displays: null);
      await press(r.controller, LogicalKeyboardKey.arrowRight, PhysicalKeyboardKey.arrowRight);
      expect(r.engine.keys.where((k) => k.$1 == 0xff53), hasLength(2), reason: 'Right down and up');
      expect(r.displays.shown, isNull);
    });

    testWidgets('an arrow alone, or with Shift as well, is the remote key', (tester) async {
      final r = await _Rig.connect(tester);
      final k = r.controller.keyboard;
      k.handle(_down(PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight));
      k.handle(_up(PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight));
      k
        ..handle(_down(PhysicalKeyboardKey.controlLeft, LogicalKeyboardKey.controlLeft))
        ..handle(_down(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft))
        ..handle(_down(PhysicalKeyboardKey.shiftLeft, LogicalKeyboardKey.shiftLeft))
        ..handle(_down(PhysicalKeyboardKey.arrowRight, LogicalKeyboardKey.arrowRight));
      expect(r.displays.shown, isNull);
      expect(r.engine.keys.where((key) => key.$1 == 0xff53 && key.$3), hasLength(2));
    });
  });

  test('the displays as data: what is shown, and when two are the same', () {
    const a = ScreenDisplay(index: 0, x: 0, y: 0, width: 1920, height: 1080, primary: true);
    const b = ScreenDisplay(index: 1, x: 1920, y: 0, width: 1280, height: 1024);
    expect(ScreenDisplays.none.several, isFalse);
    expect(const ScreenDisplays(list: [a]).several, isFalse);
    const two = ScreenDisplays(list: [a, b], shown: 1);
    expect(two.several, isTrue);
    expect(two.shownDisplay, b);
    expect(const ScreenDisplays(list: [a, b], shown: 5).shownDisplay, isNull);
    expect(two, const ScreenDisplays(list: [a, b], shown: 1));
    expect(two == const ScreenDisplays(list: [a, b]), isFalse);
    expect(two == const ScreenDisplays(list: [b, a], shown: 1), isFalse);
    expect(two.toString(), 'ScreenDisplays(2, shown: 2)');
    expect(b.toString(), 'ScreenDisplay(2: 1280x1024 at 1920,0)');
    expect(ScreenDisplays.most, 4);
  });
}
