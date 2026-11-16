// Remote screens (4.0): the small live picture of one of the remote's
// displays in a computer's strip. It reads the display through a view of the
// session's picture, asks for it twice a second, and asks for nothing while
// the screen is paused or covered.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_display_preview.dart';

import 'screen_view_fixture.dart';

const _two = [
  [0, 0, 1920, 1080],
  [1920, 0, 1280, 1024],
];

Future<(FakeScreenSession, ScreenController)> _connect(WidgetTester tester, {List<List<int>> displays = _two}) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(const ScreenConnectOptions.rdp(), native: native);
  final engine = native.sessions.single;
  engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': 3200, 'height': 1080, 'displays': displays});
  await tester.pump();
  final controller = ScreenController(session, decodeTile: syncDecode);
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  return (engine, controller);
}

Future<void> _pump(WidgetTester tester, ScreenController c, {int index = 1, bool covered = false, Size size = const Size(160, 128)}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(400, 300);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: ScreenDisplayPreview(controller: c, index: index, size: size, covered: covered, decodeTile: syncDecode),
      ),
    ),
  );
}

ScreenFrame _small(int seq, Color color) =>
    ScreenFrame(seq: seq, width: 160, height: 128, updates: 0, tiles: [tile(0, 0, 160, 128, color)]);

void main() {
  test('the picture is asked as small as still fills where it is drawn, 1 to 16 times smaller', () {
    // 1280 by 1024 drawn at 160 by 128: eight times smaller.
    expect(ScreenDisplayPreview.divideFor(1280, 1024, const Size(160, 128), 1), 8);
    // On a screen of two pixels to the point, half as much smaller.
    expect(ScreenDisplayPreview.divideFor(1280, 1024, const Size(160, 128), 2), 4);
    // A 4K display in a small box: the most the engine does.
    expect(ScreenDisplayPreview.divideFor(3840, 2160, const Size(96, 54), 1), 16);
    // A display smaller than its box: as it is.
    expect(ScreenDisplayPreview.divideFor(200, 200, const Size(300, 300), 1), 1);
    // Not the same shape as its box: by the side that needs more of it.
    expect(ScreenDisplayPreview.divideFor(1920, 1080, const Size(160, 160), 1), 6);
    expect(ScreenDisplayPreview.divideFor(1920, 1080, Size.zero, 1), 16);
  });

  testWidgets('a view on its display, eight times smaller, and its picture drawn when one comes', (tester) async {
    final (engine, c) = await _connect(tester);
    await _pump(tester, c);
    expect(engine.views.values.single, (x: 1920, y: 0, width: 1280, height: 1024, divide: 8));
    expect(find.byType(RawImage), findsNothing, reason: 'nothing came yet');
    final view = engine.views.keys.single;

    engine.viewFrames[view] = [_small(1, const Color(0xFF00AA00))];
    await tester.pump(ScreenDisplayPreview.every);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.width, 160);
    expect(tester.getSize(find.byType(ScreenDisplayPreview)), const Size(160, 128));
    // The remote's picture is nothing a screen reader reads.
    expect(find.ancestor(of: find.byType(RawImage), matching: find.byType(ExcludeSemantics)), findsWidgets);

    // The next one takes its place, and the old image is let go.
    final first = tester.widget<RawImage>(find.byType(RawImage)).image!;
    engine.viewFrames[view] = [_small(2, const Color(0xFFAA0000))];
    await tester.pump(ScreenDisplayPreview.every);
    await tester.pump();
    expect(first.debugDisposed, isTrue);
    expect(tester.widget<RawImage>(find.byType(RawImage)).image!.debugDisposed, isFalse);
    // It takes nothing of the picture the tab itself draws.
    expect(engine.shown, isEmpty);
  });

  testWidgets('covered by recording mode: a plain box, and nothing is asked for', (tester) async {
    final (engine, c) = await _connect(tester);
    await _pump(tester, c);
    final view = engine.views.keys.single;
    engine.viewFrames[view] = [_small(1, const Color(0xFF00AA00))];
    await tester.pump(ScreenDisplayPreview.every);
    await tester.pump();
    expect(find.byType(RawImage), findsOneWidget);

    await _pump(tester, c, covered: true);
    expect(find.byType(RawImage), findsNothing, reason: 'the picture it had is gone at once');
    engine.viewFrames[view] = [_small(2, const Color(0xFFAA0000))];
    await tester.pump(ScreenDisplayPreview.every * 3);
    expect(engine.viewFrames[view], hasLength(1), reason: 'not taken');
    expect(find.byType(RawImage), findsNothing);

    // Shown again: it is asked for again.
    await _pump(tester, c);
    await tester.pump(ScreenDisplayPreview.every);
    await tester.pump();
    expect(engine.viewFrames[view], isEmpty);
    expect(find.byType(RawImage), findsOneWidget);
  });

  testWidgets('a paused screen (its tab not in front) is not asked for its displays', (tester) async {
    final (engine, c) = await _connect(tester);
    await _pump(tester, c);
    final view = engine.views.keys.single;
    c.pause();
    engine.viewFrames[view] = [_small(1, const Color(0xFF00AA00))];
    await tester.pump(ScreenDisplayPreview.every * 3);
    expect(engine.viewFrames[view], hasLength(1));
    c.resume();
    await tester.pump(ScreenDisplayPreview.every);
    await tester.pump();
    expect(engine.viewFrames[view], isEmpty);
  });

  testWidgets('the display changes or goes: the view is on the display as it is now, or there is none', (tester) async {
    final (engine, c) = await _connect(tester);
    await _pump(tester, c);
    final before = engine.views.keys.single;
    // The second display got another size.
    engine
      ..emit(ScreenEventKind.resize, a: (2944 << 32) | 1080)
      ..displays(const [
        [0, 0, 1920, 1080],
        [1920, 0, 1024, 768],
      ]);
    await tester.pump();
    expect(engine.views.containsKey(before), isFalse, reason: 'the old view is let go');
    expect(engine.views.values.single, (x: 1920, y: 0, width: 1024, height: 768, divide: 6));
    // One screen again: no second display, no view, a plain box.
    engine
      ..emit(ScreenEventKind.resize, a: (1920 << 32) | 1080)
      ..displays(const [
        [0, 0, 1920, 1080],
      ]);
    await tester.pump();
    expect(engine.views, isEmpty);
    expect(find.byType(RawImage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('it lets its view go when it goes, and one for each display may be open', (tester) async {
    final (engine, c) = await _connect(tester);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(400, 400);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Column(
          children: [
            for (final i in [0, 1])
              ScreenDisplayPreview(controller: c, index: i, size: const Size(160, 90), decodeTile: syncDecode),
          ],
        ),
      ),
    );
    expect(engine.views, hasLength(2));
    await tester.pumpWidget(const SizedBox());
    expect(engine.views, isEmpty);
  });
}
