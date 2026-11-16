// Remote screens (4.0): the view of a screen session on the
// fake engine. Tiles painted where they belong at every scaling, frames taken
// at most once a vsync and never while paused, the pointer and fingers mapped
// to exact remote pixels through zoom and pan (the spike's checks as
// tests), keys to keysyms and scancodes, the remote cursor drawn, images
// disposed.
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_pointer.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/theme/app_colors.dart';

import 'screen_view_fixture.dart';

const red = Color(0xFFFF0000);
const blue = Color(0xFF0000FF);
const green = Color(0xFF00FF00);

void main() {
  group('the picture', () {
    testWidgets('tiles are painted where they belong, fitted and centred on whole pixels', (tester) async {
      // 64 x 40 in a 400 x 250 view: fit never enlarges, so 1:1, centred.
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      expect(find.byKey(const ValueKey('screen-waiting')), findsOneWidget);
      rig.frame([tile(0, 0, 32, 40, red), tile(32, 0, 32, 40, blue)]);
      await settleFrames(tester);
      expect(find.byKey(const ValueKey('screen-waiting')), findsNothing);

      final v = rig.controller.viewport;
      expect(v.scale, 1);
      expect(v.origin, const Offset(168, 105));
      final p = await probe(tester);
      expect(p.at(168, 105), isColor(red));
      expect(p.at(199, 144), isColor(red));
      expect(p.at(200, 105), isColor(blue));
      expect(p.at(231, 144), isColor(blue));
      // Outside the picture: the letterbox.
      expect(p.at(167, 105), isColor(AppColors.screenLetterbox));
      expect(p.at(232, 120), isColor(AppColors.screenLetterbox));
      expect(p.at(200, 145), isColor(AppColors.screenLetterbox));
    });

    testWidgets('fill enlarges to the view keeping the shape; one to one is a device pixel', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      rig.frame([tile(0, 0, 32, 40, red), tile(32, 0, 32, 40, blue)]);
      await settleFrames(tester);

      rig.controller.fit = ScreenFit.fill;
      await tester.pump();
      final v = rig.controller.viewport;
      // min(400 / 64, 250 / 40) = 6.25, kept under 4 logical pixels per remote pixel.
      expect(v.scale, 4);
      expect(v.origin, const Offset(72, 45));
      var p = await probe(tester);
      expect(p.at(72, 45), isColor(red));
      expect(p.at(72 + 127, 45 + 159), isColor(red));
      expect(p.at(72 + 128, 45), isColor(blue));
      expect(p.at(71, 100), isColor(AppColors.screenLetterbox));

      // A display of 2 device pixels per logical pixel: one to one is half a logical pixel.
      tester.view.devicePixelRatio = 2;
      tester.view.physicalSize = const Size(800, 500);
      rig.controller.fit = ScreenFit.oneToOne;
      await tester.pump();
      expect(v.scale, 0.5);
      expect(v.devicePixelRatio, 2);
      p = await probe(tester);
      expect(p.at(v.origin.dx + 1, v.origin.dy + 1), isColor(red));
      expect(p.at(v.origin.dx + 17, v.origin.dy + 1), isColor(blue));
    });

    testWidgets('frames are taken on the frame-ready event, at most one per vsync', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      rig.frame([tile(0, 0, 32, 40, red)]);
      rig.frame([tile(0, 0, 32, 40, blue)]);
      rig.frame([tile(0, 0, 32, 40, green)]);
      // Nothing is taken outside a frame callback.
      expect(rig.engine.frames, hasLength(3));
      await tester.pump();
      expect(rig.engine.frames.length, greaterThanOrEqualTo(2));
      await settleFrames(tester);
      expect(rig.engine.frames, hasLength(2), reason: 'three events before one vsync: one take');
      expect(rig.controller.framesShown, 1);
      // The next event: the next take.
      rig.engine.emit(ScreenEventKind.frame, a: 9);
      await settleFrames(tester);
      expect(rig.engine.frames, hasLength(1));
      expect(rig.controller.framesShown, 2);
    });

    testWidgets('a replaced tile disposes its image; a new size or the whole screen drops the rest', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      rig.frame([tile(0, 0, 32, 40, red), tile(32, 0, 32, 40, blue)]);
      await settleFrames(tester);
      final first = [for (final t in rig.controller.tiles) t.image];
      expect(first, hasLength(2));

      rig.frame([tile(0, 0, 32, 40, green)]);
      await settleFrames(tester);
      expect(first[0].debugDisposed, isTrue);
      expect(first[1].debugDisposed, isFalse);
      expect((await probe(tester)).at(168, 105), isColor(green));

      // The whole screen as one image: every tile under it goes.
      final second = [for (final t in rig.controller.tiles) t.image];
      rig.frame([tile(0, 0, 64, 40, red)]);
      await settleFrames(tester);
      expect(second.every((i) => i.debugDisposed), isTrue);
      expect(rig.controller.tiles, hasLength(1));

      // A new size.
      final third = [for (final t in rig.controller.tiles) t.image];
      rig.frame([tile(0, 0, 80, 50, blue)], width: 80, height: 50);
      await settleFrames(tester);
      expect(third.single.debugDisposed, isTrue);
      expect(rig.controller.width, 80);
      expect(rig.controller.height, 50);

      final last = rig.controller.tiles.single.image;
      await tester.pumpWidget(const SizedBox());
      rig.controller.dispose();
      expect(last.debugDisposed, isTrue);
    });

    testWidgets('the real decoder makes an image of the pixels as they are', (tester) async {
      await tester.runAsync(() async {
        final image = await decodeScreenTile(tile(0, 0, 3, 2, const Color(0xFF123456)));
        expect((image.width, image.height), (3, 2));
        final data = (await image.toByteData())!;
        expect([data.getUint8(0), data.getUint8(1), data.getUint8(2), data.getUint8(3)], [0x12, 0x34, 0x56, 0xff]);
        image.dispose();
      });
    });

    testWidgets('paused, nothing is taken and the server is told; resumed, the picture comes again', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      rig.takeKeys();

      rig.controller.pause();
      expect(rig.engine.pauses, 1);
      expect(rig.takeKeys(), [(0xffe1, 0x2a, false)], reason: 'a key held is let go');
      rig.frame([tile(0, 0, 32, 40, red)]);
      await settleFrames(tester);
      expect(rig.engine.frames, hasLength(1), reason: 'no frame taken while paused');
      expect(rig.controller.framesShown, 0);
      rig.controller.pause();
      expect(rig.engine.pauses, 1);

      rig.controller.resume();
      expect(rig.engine.resumes, 1);
      await settleFrames(tester);
      expect(rig.engine.frames, isEmpty);
      expect(rig.controller.framesShown, 1);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    });
  });

  group('the mouse', () {
    testWidgets('maps to the exact remote pixel through fit, zoom and pan, with every button', (tester) async {
      // 800 x 500 in 400 x 250: fit 0.5.
      final rig = await ScreenRig.connect(tester);
      await pumpView(tester, rig.controller);
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(const Offset(100.2, 50.7));
      expect(rig.takePointers().last, (200, 101, 0));

      final v = rig.controller.viewport;
      v.zoomTo(4, const Offset(400, 250), const Offset(200, 125));
      // Scale 2: the remote point (400, 250) stays at the view's (200, 125).
      expect(v.scale, 2);
      await mouse.moveTo(const Offset(200, 125));
      expect(rig.takePointers().last, (400, 250, 0));
      v.panBy(const Offset(-30, 10));
      await mouse.moveTo(const Offset(200, 125));
      expect(rig.takePointers().last, (415, 245, 0));

      await mouse.down(const Offset(200, 125));
      expect(rig.takePointers().last.$3, ScreenButtons.left);
      await mouse.up();
      expect(rig.takePointers().last.$3, 0);
      final right = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kSecondaryMouseButton);
      await right.down(const Offset(200, 125));
      expect(rig.takePointers().last.$3, ScreenButtons.right);
      await right.up();
      final middle = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kMiddleMouseButton);
      await middle.down(const Offset(200, 125));
      expect(rig.takePointers().last.$3, ScreenButtons.middle);
      await middle.up();
      final back = await tester.createGesture(kind: PointerDeviceKind.mouse, buttons: kBackMouseButton);
      await back.down(const Offset(200, 125));
      expect(rig.takePointers().last.$3, ScreenButtons.back);
      await back.up();
    });

    testWidgets('a wheel step is one notch each way; a trackpad gathers 24 px a notch', (tester) async {
      final rig = await ScreenRig.connect(tester);
      await pumpView(tester, rig.controller);
      final mouse = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(mouse.hover(const Offset(100, 100)));
      rig.takePointers();
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, -120)));
      expect(rig.takePointers(), [(200, 200, ScreenButtons.wheelUp), (200, 200, 0)]);
      await tester.sendEventToBinding(mouse.scroll(const Offset(0, 53)));
      expect(rig.takePointers(), [(200, 200, ScreenButtons.wheelDown), (200, 200, 0)]);
      await tester.sendEventToBinding(mouse.scroll(const Offset(-40, 0)));
      expect(rig.takePointers(), [(200, 200, ScreenButtons.wheelLeft), (200, 200, 0)]);
      await tester.sendEventToBinding(mouse.scroll(const Offset(40, 0)));
      expect(rig.takePointers(), [(200, 200, ScreenButtons.wheelRight), (200, 200, 0)]);

      final pad = TestPointer(2, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pad.panZoomStart(const Offset(100, 100)));
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(100, 100), pan: const Offset(0, 30)));
      expect(rig.takePointers(), [(200, 200, ScreenButtons.wheelUp), (200, 200, 0)]);
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(100, 100), pan: const Offset(0, 40)));
      expect(rig.takePointers(), isEmpty, reason: '6 left over and 10 more: no notch yet');
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(100, 100), pan: const Offset(0, -40)));
      expect(rig.takePointers().where((p) => p.$3 != 0).map((p) => p.$3), [ScreenButtons.wheelDown, ScreenButtons.wheelDown]);
      // A pinch on the trackpad zooms about the pointer.
      await tester.sendEventToBinding(pad.panZoomUpdate(const Offset(100, 100), pan: const Offset(0, -40), scale: 2));
      expect(rig.controller.viewport.scale, 1);
      expect(rig.controller.viewport.toRemote(const Offset(100, 100)), (200, 200));
      await tester.sendEventToBinding(pad.panZoomEnd());
    });

    testWidgets('"Resize the remote": the view\'s size is told to the session once it has settled, at once when '
        'turned on, and a server that takes no resize turns it off again', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 800, height: 500);
      await pumpView(tester, rig.controller, size: const Size(401, 250));
      // Off (as for every VNC screen): nothing is asked.
      await tester.pump(ScreenController.resizeSettle * 2);
      expect(rig.engine.resizes, isEmpty);

      // Turned on: the size the view has now, the width made even, with no wait.
      var unavailable = 0;
      rig.controller.onResizeUnavailable = () => unavailable++;
      rig.controller.followViewSize = true;
      await tester.pump(Duration.zero);
      expect(rig.engine.resizes, [(400, 250)]);
      expect(ScreenViewSize.lastFollowed, const Size(401, 250));

      // The view changes size several times: only the size it settles at is asked.
      for (final size in const [Size(500, 300), Size(520, 310), Size(640, 400)]) {
        tester.view.physicalSize = size;
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(rig.engine.resizes, hasLength(1));
      await tester.pump(ScreenController.resizeSettle);
      expect(rig.engine.resizes, [(400, 250), (640, 400)]);

      // The size the remote already has is not asked for.
      rig.engine.emit(ScreenEventKind.resize, a: (640 << 32) | 400);
      await tester.pump();
      tester.view.physicalSize = const Size(641, 400);
      await tester.pump(ScreenController.resizeSettle * 2);
      expect(rig.engine.resizes, hasLength(2));

      // The server takes no resize: off again, said once, and nothing more asked.
      rig.engine.emitJson(ScreenEventKind.info, {'resize_unavailable': true});
      await tester.pump();
      expect((rig.controller.followViewSize, unavailable), (false, 1));
      tester.view.physicalSize = const Size(700, 440);
      await tester.pump(ScreenController.resizeSettle * 2);
      expect(rig.engine.resizes, hasLength(2));
      rig.engine.emitJson(ScreenEventKind.info, {'resize_unavailable': true});
      await tester.pump();
      expect(unavailable, 1);

      // A remote screen is never asked to be smaller than a server takes.
      expect(ScreenViewSize.remoteOf(const Size(120.9, 90)), (200, 200));
      expect(ScreenViewSize.remoteOf(const Size(1281.7, 800.9)), (1280, 800));
    });

    testWidgets('the remote cursor is drawn at the pointer in place of the system one', (tester) async {
      final rig = await ScreenRig.connect(tester, width: 64, height: 40);
      await pumpView(tester, rig.controller);
      rig.frame([tile(0, 0, 64, 40, blue)]);
      await settleFrames(tester);
      expect(rig.controller.mouseCursor, SystemMouseCursors.basic);

      // A 4 x 4 cursor, its hot spot at (1, 1): green with its last row clear.
      final shape = BytesBuilder()
        ..add([4, 0, 4, 0, 1, 0, 1, 0])
        ..add(solid(green, 12))
        ..add(Uint8List(16));
      rig.engine.emit(ScreenEventKind.cursor, data: shape.toBytes());
      await settleFrames(tester);
      expect(rig.controller.mouseCursor, SystemMouseCursors.none);

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      addTearDown(mouse.removePointer);
      await mouse.addPointer(location: const Offset(178.5, 115.5));
      await mouse.moveTo(const Offset(178.5, 115.5));
      await tester.pump();
      // The remote pixel (10, 10) is at (178, 115); the shape's top left one up and left.
      expect(rig.controller.cursorDraw, (ScreenCursorDraw.remote, 10, 10));
      var p = await probe(tester);
      expect(p.at(177, 114), isColor(green));
      expect(p.at(180, 116), isColor(green));
      expect(p.at(180, 117), isColor(blue), reason: 'a clear pixel shows the picture');
      expect(p.at(176, 114), isColor(blue));

      // The server hides it: nothing drawn, and no system pointer either.
      rig.engine.emit(ScreenEventKind.cursor, data: Uint8List.fromList([0, 0, 0, 0, 0, 0, 0, 0]));
      await settleFrames(tester);
      p = await probe(tester);
      expect(p.at(177, 114), isColor(blue));
      expect(rig.controller.mouseCursor, SystemMouseCursors.none);

      // The server has no shape of its own (RDP's "default pointer", the event's number 1): the
      // system's pointer again, and nothing of the old shape drawn.
      rig.engine.emit(ScreenEventKind.cursor, data: shape.toBytes());
      await settleFrames(tester);
      expect(rig.controller.cursorDraw.$1, ScreenCursorDraw.remote);
      rig.engine.emit(ScreenEventKind.cursor, a: 1, data: Uint8List(8));
      await settleFrames(tester);
      expect(rig.controller.mouseCursor, SystemMouseCursors.basic);
      expect(rig.controller.remoteCursor, isNull);
      expect(rig.controller.cursorDraw.$1, ScreenCursorDraw.none);
      p = await probe(tester);
      expect(p.at(177, 114), isColor(blue));
    });
  });

  group('fingers', () {
    Future<ScreenRig> touchRig(WidgetTester tester, {Size view = const Size(400, 250), int w = 800, int h = 500}) async {
      final rig = await ScreenRig.connect(tester, width: w, height: h);
      await pumpView(tester, rig.controller, size: view);
      return rig;
    }

    testWidgets('a tap clicks the exact remote pixel under the finger', (tester) async {
      final rig = await touchRig(tester);
      await tester.tapAt(const Offset(123.4, 56.9));
      expect(rig.takePointers(), [(246, 113, 0), (246, 113, 1), (246, 113, 0)]);
    });

    testWidgets('a double tap clicks one pixel twice, however the finger landed', (tester) async {
      final rig = await touchRig(tester);
      final down1 = await tester.startGesture(const Offset(100, 100), kind: PointerDeviceKind.touch);
      await down1.up(timeStamp: const Duration(milliseconds: 60));
      final down2 = await tester.startGesture(
        const Offset(106, 103),
        kind: PointerDeviceKind.touch,
        pointer: 7,
      );
      await down2.up(timeStamp: const Duration(milliseconds: 260));
      expect(rig.takePointers(), [
        (200, 200, 0), (200, 200, 1), (200, 200, 0),
        (200, 200, 0), (200, 200, 1), (200, 200, 0),
      ]);
    });

    testWidgets('a hold of 500 ms is a right click there, once, and the lift sends nothing more', (tester) async {
      final rig = await touchRig(tester);
      final g = await tester.startGesture(const Offset(50, 60), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 450));
      expect(rig.takePointers(), isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      expect(rig.takePointers(), [(100, 120, 0), (100, 120, 4), (100, 120, 0)]);
      await g.up();
      expect(rig.takePointers(), isEmpty);
    });

    testWidgets('a one-finger drag is a left drag from where it went down', (tester) async {
      final rig = await touchRig(tester);
      final g = await tester.startGesture(const Offset(50, 50), kind: PointerDeviceKind.touch);
      await g.moveBy(const Offset(30, 0));
      await g.moveBy(const Offset(20, 10));
      await g.up();
      expect(rig.takePointers(), [(100, 100, 0), (100, 100, 1), (160, 100, 1), (200, 120, 1), (200, 120, 0)]);
    });

    testWidgets('two fingers dragged 200 px down give 7 wheel-up notches', (tester) async {
      final rig = await touchRig(tester);
      final a = await tester.startGesture(const Offset(150, 20), kind: PointerDeviceKind.touch, pointer: 1);
      final b = await tester.startGesture(const Offset(250, 20), kind: PointerDeviceKind.touch, pointer: 2);
      for (var i = 0; i < 20; i++) {
        await a.moveBy(const Offset(0, 10));
        await b.moveBy(const Offset(0, 10));
      }
      await a.up();
      await b.up();
      final notches = rig.takePointers().where((p) => p.$3 != 0).toList();
      expect(notches.map((p) => p.$3).toSet(), {ScreenButtons.wheelUp});
      expect(notches, hasLength(7));
      expect(rig.controller.viewport.zoom, 1, reason: 'a scroll is not a zoom');
    });

    testWidgets('a pinch zooms about the fingers (drift 0.00) and pans with them (150 px)', (tester) async {
      final rig = await touchRig(tester);
      final v = rig.controller.viewport;
      final a = await tester.startGesture(const Offset(140, 120), kind: PointerDeviceKind.touch, pointer: 1);
      final b = await tester.startGesture(const Offset(260, 120), kind: PointerDeviceKind.touch, pointer: 2);
      final anchor = v.toRemoteOffset(const Offset(200, 120));
      // 120 to 360 apart, about the same middle.
      for (var i = 0; i < 12; i++) {
        await a.moveBy(const Offset(-10, 0));
        await b.moveBy(const Offset(10, 0));
      }
      expect(v.zoom, closeTo(3.0, 1e-9));
      final drift = (v.toRemoteOffset(const Offset(200, 120)) - anchor).distance;
      expect(drift.toStringAsFixed(2), '0.00');

      // Then 150 px left, both fingers: the picture goes with them.
      final before = v.origin;
      for (var i = 0; i < 15; i++) {
        await a.moveBy(const Offset(-10, 0));
        await b.moveBy(const Offset(-10, 0));
      }
      expect((v.origin.dx - before.dx).toStringAsFixed(1), '-150.0');
      expect(v.origin.dy, before.dy);
      await a.up();
      await b.up();
      expect(rig.takePointers(), isEmpty, reason: 'a pinch clicks nothing');
    });

    testWidgets('two fingers tapped together are a right click', (tester) async {
      final rig = await touchRig(tester);
      final a = await tester.startGesture(const Offset(100, 100), kind: PointerDeviceKind.touch, pointer: 1);
      final b = await tester.startGesture(const Offset(140, 100), kind: PointerDeviceKind.touch, pointer: 2);
      await a.up(timeStamp: const Duration(milliseconds: 120));
      await b.up(timeStamp: const Duration(milliseconds: 130));
      expect(rig.takePointers(), [(240, 200, 0), (240, 200, 4), (240, 200, 0)]);
    });

    testWidgets('Mouse pointer mode: a finger moves the pointer 194 x 97 at scale 0.514', (tester) async {
      // The spike's emulator: 1280 x 800 fitted into 914 x 411.
      final rig = await touchRig(tester, view: const Size(914, 411), w: 1280, h: 800);
      rig.frame([tile(0, 0, 1280, 800, blue)]);
      await settleFrames(tester);
      rig.controller.touchMode = ScreenTouchMode.mousePointer;
      final v = rig.controller.viewport;
      expect(v.scale.toStringAsFixed(3), '0.514');
      final (sx, sy) = rig.controller.touch.pointerPosition;
      expect((sx, sy), (640, 400));
      final g = await tester.startGesture(const Offset(300, 200), kind: PointerDeviceKind.touch);
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(10, 5));
      }
      await g.up();
      final (x, y) = rig.controller.touch.pointerPosition;
      expect(((x - sx) - 100 / v.scale).abs(), lessThanOrEqualTo(1));
      expect(((y - sy) - 50 / v.scale).abs(), lessThanOrEqualTo(1));
      expect((x - sx, y - sy), (195, 97));
      final sent = rig.takePointers();
      expect(sent.every((p) => p.$3 == 0), isTrue, reason: 'moving the pointer clicks nothing');
      expect(sent.last, (x, y, 0));
      // The pointer is drawn (an arrow, until the server sends a shape).
      expect(rig.controller.cursorDraw, (ScreenCursorDraw.arrow, x, y));
      final p = await probe(tester);
      final at = v.toLocal(x.toDouble(), y.toDouble());
      expect(p.at(at.dx + 3, at.dy + 10), isColor(AppColors.screenPointerFill));
      expect(p.at(at.dx + 3, at.dy - 3), isColor(blue));
    });

    testWidgets('Mouse pointer mode: a tap clicks at the pointer; a hold and lift is a right click', (tester) async {
      final rig = await touchRig(tester);
      rig.controller.touchMode = ScreenTouchMode.mousePointer;
      await tester.tapAt(const Offset(10, 10));
      expect(rig.takePointers(), [(400, 250, 0), (400, 250, 1), (400, 250, 0)]);
      final g = await tester.startGesture(const Offset(10, 10), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 600));
      expect(rig.takePointers(), isEmpty, reason: 'the lift or a drag decides');
      await g.up();
      expect(rig.takePointers(), [(400, 250, 0), (400, 250, 4), (400, 250, 0)]);
      // A hold then a drag: a left drag from the pointer.
      final d = await tester.startGesture(const Offset(10, 10), kind: PointerDeviceKind.touch);
      await tester.pump(const Duration(milliseconds: 600));
      await d.moveBy(const Offset(20, 0));
      await d.up();
      final sent = rig.takePointers();
      expect(sent.first, (400, 250, 1));
      expect(sent[sent.length - 2].$3, 1);
      expect(sent.last, (440, 250, 0));
    });

    testWidgets('view only: fingers and the mouse send nothing, a pinch still zooms', (tester) async {
      final rig = await touchRig(tester);
      rig.controller.viewOnly = true;
      await tester.tapAt(const Offset(100, 100));
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      expect(rig.takePointers(), isEmpty);
      expect(rig.takeKeys(), isEmpty);
      final a = await tester.startGesture(const Offset(140, 120), kind: PointerDeviceKind.touch, pointer: 1);
      final b = await tester.startGesture(const Offset(260, 120), kind: PointerDeviceKind.touch, pointer: 2);
      for (var i = 0; i < 6; i++) {
        await a.moveBy(const Offset(-10, 0));
        await b.moveBy(const Offset(10, 0));
      }
      await a.up();
      await b.up();
      expect(rig.controller.viewport.zoom, closeTo(2, 1e-9));
      expect(rig.takePointers(), isEmpty);
    });
  });

  group('keys', () {
    testWidgets('a key goes down and up as its keysym and scancode', (tester) async {
      final rig = await ScreenRig.connect(tester);
      await pumpView(tester, rig.controller);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(rig.takeKeys(), [(0x61, 0x1e, true), (0x61, 0x1e, false), (0xff0d, 0x1c, true), (0xff0d, 0x1c, false)]);
    });

    testWidgets('keys held are let go when the picture loses the focus', (tester) async {
      final rig = await ScreenRig.connect(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpView(tester, rig.controller, focusNode: focus);
      expect(focus.hasFocus, isTrue);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      rig.takeKeys();
      focus.unfocus();
      await tester.pump();
      expect(rig.takeKeys(), [(0xffe9, 0x38, false), (0xffe3, 0x1d, false)]);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(rig.takeKeys(), isEmpty, reason: 'their key ups were sent already');
    });

    testWidgets('F8 opens the menu and is never sent; with no menu it is a key', (tester) async {
      final rig = await ScreenRig.connect(tester);
      var menus = 0;
      await pumpView(tester, rig.controller, onMenuKey: () => menus++);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.f8);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.f8);
      expect(menus, 1);
      expect(rig.takeKeys(), isEmpty);

      await pumpView(tester, rig.controller);
      await tester.sendKeyEvent(LogicalKeyboardKey.f8);
      expect(rig.takeKeys(), [(0xffc5, 0x42, true), (0xffc5, 0x42, false)]);
    });

    testWidgets('a click on the picture takes the focus back', (tester) async {
      final rig = await ScreenRig.connect(tester);
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await pumpView(tester, rig.controller, focusNode: focus);
      focus.unfocus();
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pump();
      expect(focus.hasFocus, isTrue);
    });
  });

  testWidgets('a screen reader hears what the picture is, and can undo a zoom', (tester) async {
    final semantics = tester.ensureSemantics();
    final rig = await ScreenRig.connect(tester);
    await pumpView(tester, rig.controller);
    expect(find.bySemanticsLabel(RegExp('^Remote screen')), findsOneWidget);
    var node = tester.getSemantics(find.bySemanticsLabel(RegExp('^Remote screen')));
    expect(node.getSemanticsData().customSemanticsActionIds ?? const <int>{}, isEmpty);
    final a = await tester.startGesture(const Offset(140, 120), kind: PointerDeviceKind.touch, pointer: 1);
    final b = await tester.startGesture(const Offset(260, 120), kind: PointerDeviceKind.touch, pointer: 2);
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(-10, 0));
      await b.moveBy(const Offset(10, 0));
    }
    await a.up();
    await b.up();
    await tester.pump();
    node = tester.getSemantics(find.bySemanticsLabel(RegExp('^Remote screen')));
    final actions = node.getSemanticsData().customSemanticsActionIds ?? const <int>{};
    expect(actions, isNotEmpty);
    rig.controller.resetZoom();
    await tester.pump();
    expect(rig.controller.viewport.isZoomed, isFalse);
    semantics.dispose();
  });
}
