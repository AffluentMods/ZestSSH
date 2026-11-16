import 'dart:io' show ZLibEncoder;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/help/guides/guide_markdown.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/help/guide_markdown_view.dart';
import 'package:zestssh/ui/screens/help/guide_picture_viewer.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// Help > Guides (3.0.x): a guide's picture opens full size over the guide.
/// Pinch, double-tap, the scroll wheel or a click zoom; a swipe, the arrow
/// keys or the side buttons go to the guide's next and previous picture;
/// Esc, a tap beside the picture or Close go back; the picture's words are
/// its caption. Only the docs site's pictures are shown, there as here.
void main() {
  const page = '''
## Set it up

1. Open **Networks** in the side rail.

   ![Step 1: the Networks page](/guides/img/networks-and-jump-hosts/desktop-networks.webp)

2. Press **New network**.

> [!NOTE]
> ![Step 2: the new network's form](https://docs.zestssh.com/guides/img/networks-and-jump-hosts/new-network.webp)

![A tracking pixel](https://tracker.example/pixel.gif)
''';

  const first = 'Step 1: the Networks page';
  const second = "Step 2: the new network's form";

  // A picture that decodes in a test: the network answers nothing there.
  final png = _png(120, 80);
  final asked = <Uri>[];
  ImageProvider imageFor(Uri uri) {
    asked.add(uri);
    return MemoryImage(png);
  }

  setUp(() {
    asked.clear();
    debugTouchLayout = false;
  });
  tearDown(() => debugTouchLayout = null);

  Future<AppLocalizations> pumpGuide(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: GuideMarkdownView(
            blocks: parseGuideMarkdown(page),
            slug: 'networks-and-jump-hosts',
            onOpenGuide: (_) {},
            onOpenOutside: (_) {},
            imageFor: imageFor,
          ),
        ),
      ),
    ));
    await tester.runAsync(() => precacheImage(MemoryImage(png), tester.element(find.byType(GuideMarkdownView))));
    await tester.pumpAndSettle();
    return AppLocalizations.of(tester.element(find.byType(GuideMarkdownView)))!;
  }

  Finder viewer() => find.byKey(const ValueKey('guide-picture-viewer'));
  GuidePictureViewerState state(WidgetTester tester) => tester.state<GuidePictureViewerState>(find.byType(GuidePictureViewer));
  String caption(WidgetTester tester) => tester.widget<Text>(find.byKey(const ValueKey('guide-picture-caption'))).data!;
  Finder image(int i) => find.byKey(ValueKey('guide-picture-image-$i'));

  Future<void> open(WidgetTester tester, int which) async {
    await tester.tap(find.byKey(const ValueKey('guide-picture-open')).at(which));
    await tester.pumpAndSettle();
    expect(viewer(), findsOneWidget);
  }

  testWidgets('a tap on a picture opens it full size, its words the caption; only the docs site\'s pictures',
      (tester) async {
    final l10n = await pumpGuide(tester);
    // Two pictures of the docs site can open; the tracker's is not loaded
    // and its words open nothing.
    expect(find.byKey(const ValueKey('guide-picture-open')), findsNWidgets(2));
    expect(asked.every((u) => u.host == 'docs.zestssh.com'), isTrue);
    expect(
      find.byWidgetPredicate((w) => w is Semantics && w.properties.label == first && w.properties.hint == l10n.guidePictureOpen),
      findsOneWidget,
    );
    await tester.tap(find.text('A tracking pixel'));
    await tester.pumpAndSettle();
    expect(viewer(), findsNothing);

    await open(tester, 1);
    expect(caption(tester), second);
    expect(find.text(l10n.guidePictureCount(2, 2)), findsOneWidget);
    expect(find.text(l10n.guidePictureHintComputer), findsOneWidget);
    expect(state(tester).index, 1);
  });

  testWidgets('the arrow keys go to the next and previous picture, Esc closes', (tester) async {
    final l10n = await pumpGuide(tester);
    await open(tester, 0);
    expect(caption(tester), first);
    expect(find.text(l10n.guidePictureCount(1, 2)), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(caption(tester), second);
    expect(find.text(l10n.guidePictureCount(2, 2)), findsOneWidget);
    // The last picture has no next one.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(caption(tester), second);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pumpAndSettle();
    expect(caption(tester), first);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(viewer(), findsNothing);
  });

  testWidgets('the side buttons and a swipe go to the next picture', (tester) async {
    await pumpGuide(tester);
    await open(tester, 0);
    await tester.tap(find.byKey(const ValueKey('guide-picture-next')));
    await tester.pumpAndSettle();
    expect(caption(tester), second);
    await tester.tap(find.byKey(const ValueKey('guide-picture-previous')));
    await tester.pumpAndSettle();
    expect(caption(tester), first);

    await tester.fling(find.byType(PageView), const Offset(-400, 0), 1000);
    await tester.pumpAndSettle();
    expect(caption(tester), second);
    await tester.fling(find.byType(PageView), const Offset(400, 0), 1000);
    await tester.pumpAndSettle();
    expect(caption(tester), first);
  });

  testWidgets('on a computer a click and the scroll wheel zoom', (tester) async {
    await pumpGuide(tester);
    await open(tester, 0);
    expect(state(tester).scale, 1);

    await tester.tap(image(0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle(kDoubleTapTimeout);
    expect(state(tester).scale, closeTo(kGuidePictureZoom, 0.001));
    // Zoomed in, a sideways drag moves the picture, not to the next one.
    await tester.drag(image(0), const Offset(-300, 0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle(kDoubleTapTimeout);
    expect(state(tester).index, 0);
    await tester.tap(image(0), kind: PointerDeviceKind.mouse);
    await tester.pumpAndSettle(kDoubleTapTimeout);
    expect(state(tester).scale, 1);

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(image(0))));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
    await tester.pumpAndSettle();
    expect(state(tester).scale, greaterThan(1.5));

    // The next picture is shown whole.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(state(tester).index, 1);
    expect(state(tester).scale, 1);
  });

  testWidgets('on a phone a double-tap and a pinch zoom', (tester) async {
    debugTouchLayout = true;
    final l10n = await pumpGuide(tester);
    await open(tester, 0);
    expect(find.text(l10n.guidePictureHintTouch), findsOneWidget);

    // One tap on the picture does nothing; two zoom in, two more out.
    await tester.tap(image(0));
    await tester.pumpAndSettle(kDoubleTapTimeout);
    expect(state(tester).scale, 1);
    expect(viewer(), findsOneWidget);
    await tester.tap(image(0));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(image(0));
    await tester.pumpAndSettle();
    expect(state(tester).scale, closeTo(kGuidePictureZoom, 0.001));
    await tester.tap(image(0));
    await tester.pump(const Duration(milliseconds: 60));
    await tester.tap(image(0));
    await tester.pumpAndSettle();
    expect(state(tester).scale, 1);

    final c = tester.getCenter(image(0));
    final a = await tester.startGesture(c - const Offset(20, 0), pointer: 7);
    final b = await tester.startGesture(c + const Offset(20, 0), pointer: 8);
    for (var step = 1; step <= 6; step++) {
      await a.moveTo(c - Offset(20.0 + step * 15, 0));
      await b.moveTo(c + Offset(20.0 + step * 15, 0));
      await tester.pump();
    }
    await a.up();
    await b.up();
    await tester.pumpAndSettle();
    expect(state(tester).scale, greaterThan(2));
  });

  testWidgets('Close and a tap beside the picture go back to the guide', (tester) async {
    final l10n = await pumpGuide(tester);
    await open(tester, 0);
    expect(find.byTooltip(l10n.close), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('guide-picture-close')));
    await tester.pumpAndSettle();
    expect(viewer(), findsNothing);

    await open(tester, 0);
    // Beside the picture (below the top line, left of nothing else).
    await tester.tapAt(const Offset(120, 140));
    await tester.pumpAndSettle();
    expect(viewer(), findsNothing);
    expect(find.byType(GuideMarkdownView), findsOneWidget);
  });
}

/// A PNG of [w] by [h] pixels in one colour.
Uint8List _png(int w, int h) {
  final raw = BytesBuilder();
  for (var y = 0; y < h; y++) {
    raw.addByte(0); // no filter
    for (var x = 0; x < w; x++) {
      raw.add(const [0xFF, 0x7A, 0x1A, 0xFF]);
    }
  }
  Uint8List be32(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v);
  final out = BytesBuilder()..add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
  void chunk(String type, List<int> data) {
    final body = [...type.codeUnits, ...data];
    out
      ..add(be32(data.length))
      ..add(body)
      ..add(be32(_crc32(body)));
  }

  chunk('IHDR', [...be32(w), ...be32(h), 8, 6, 0, 0, 0]);
  chunk('IDAT', ZLibEncoder().convert(raw.toBytes()));
  chunk('IEND', const []);
  return out.toBytes();
}

int _crc32(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final b in bytes) {
    crc ^= b;
    for (var k = 0; k < 8; k++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}
