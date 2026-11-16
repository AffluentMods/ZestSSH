// A screen session on the fake engine (zest_native's FakeScreenNative), the
// app's ScreenView around it, and pixel probes of what it painted (the repo
// has no golden files: colours are read back from the rendered image).
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';
import 'package:zestssh/features/screens/view/screen_pointer_hold.dart';
import 'package:zestssh/features/screens/view/screen_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// [len] pixels of one colour, RGBA.
Uint8List solid(Color c, int len) {
  final out = Uint8List(len * 4);
  final (r, g, b, a) = ((c.r * 255).round(), (c.g * 255).round(), (c.b * 255).round(), (c.a * 255).round());
  for (var i = 0; i < out.length; i += 4) {
    out[i] = r;
    out[i + 1] = g;
    out[i + 2] = b;
    out[i + 3] = a;
  }
  return out;
}

ScreenTile tile(int x, int y, int w, int h, Color c) => ScreenTile(x, y, w, h, solid(c, w * h));

/// A tile decoder that needs no engine thread (widget tests run on a fake
/// clock): the pixels drawn into a picture, a row's runs of one colour at a
/// time, made an image at once.
Future<ui.Image> syncDecode(ScreenTile t) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final p = t.pixels;
  for (var y = 0; y < t.height; y++) {
    var x = 0;
    while (x < t.width) {
      final i = (y * t.width + x) * 4;
      var end = x + 1;
      while (end < t.width) {
        final j = (y * t.width + end) * 4;
        if (p[j] != p[i] || p[j + 1] != p[i + 1] || p[j + 2] != p[i + 2] || p[j + 3] != p[i + 3]) break;
        end++;
      }
      canvas.drawRect(
        Rect.fromLTWH(x.toDouble(), y.toDouble(), (end - x).toDouble(), 1),
        Paint()
          ..isAntiAlias = false
          ..color = Color.fromARGB(p[i + 3], p[i], p[i + 1], p[i + 2]),
      );
      x = end;
    }
  }
  final picture = recorder.endRecording();
  final image = picture.toImageSync(t.width, t.height);
  picture.dispose();
  return image;
}

class ScreenRig {
  ScreenRig._(this.native, this.session, this.engine, this.controller);

  final FakeScreenNative native;
  final ScreenSession session;
  final FakeScreenSession engine;
  final ScreenController controller;

  /// A connected session of [width] x [height] and its controller.
  static Future<ScreenRig> connect(WidgetTester tester, {int width = 800, int height = 500}) async {
    final native = FakeScreenNative();
    final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
    final engine = native.sessions.single;
    engine.connect(width: width, height: height);
    await tester.pump();
    final controller = ScreenController(session, decodeTile: syncDecode);
    addTearDown(() {
      controller.dispose();
      session.close();
    });
    await tester.pump();
    return ScreenRig._(native, session, engine, controller);
  }

  int _seq = 0;

  /// The engine has a frame of [tiles] ready.
  void frame(List<ScreenTile> tiles, {int? width, int? height}) {
    _seq++;
    engine.frames.add(
      ScreenFrame(
        seq: _seq,
        width: width ?? controller.width,
        height: height ?? controller.height,
        updates: 1,
        tiles: tiles,
      ),
    );
    engine.emit(ScreenEventKind.frame, a: _seq);
  }

  /// The pointer events the engine got since the last call.
  List<(int, int, int)> takePointers() {
    final out = List.of(engine.pointers);
    engine.pointers.clear();
    return out;
  }

  List<(int, int, bool)> takeKeys() {
    final out = List.of(engine.keys);
    engine.keys.clear();
    return out;
  }
}

const pictureKey = ValueKey('screen-view-boundary');

/// The view in an app of [size] logical pixels at a device pixel ratio of 1.
Future<void> pumpView(
  WidgetTester tester,
  ScreenController controller, {
  Size size = const Size(400, 250),
  VoidCallback? onMenuKey,
  FocusNode? focusNode,
  EdgeInsets insets = EdgeInsets.zero,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: RepaintBoundary(
        key: pictureKey,
        child: ScreenView(controller: controller, onMenuKey: onMenuKey, focusNode: focusNode, insets: insets),
      ),
    ),
  );
  await tester.pump();
}

/// Lets the frame callback take the frame, the decoder finish and the
/// picture repaint.
Future<void> settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// What the view painted, read back: the colour at a logical pixel.
class Probe {
  Probe(this.width, this.bytes);
  final int width;
  final ByteData bytes;

  Color at(double x, double y) {
    final i = (y.floor() * width + x.floor()) * 4;
    return Color.fromARGB(bytes.getUint8(i + 3), bytes.getUint8(i), bytes.getUint8(i + 1), bytes.getUint8(i + 2));
  }
}

Future<Probe> probe(WidgetTester tester) async {
  await tester.pump();
  final boundary = tester.renderObject<RenderRepaintBoundary>(find.byKey(pictureKey));
  late Probe out;
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final data = await image.toByteData();
    out = Probe(image.width, data!);
    image.dispose();
  });
  return out;
}

Matcher isColor(Color c) => predicate<Color>(
  (got) => got.toARGB32() == c.toARGB32(),
  'is ${c.toARGB32().toRadixString(16)}',
);

/// The computer's part, played.
class FakeCapture implements PointerCapture {
  bool can = true;
  bool startAnswer = true;
  int starts = 0;
  int stops = 0;
  int renews = 0;
  final _moves = StreamController<(int, int)>.broadcast(sync: true);
  final _lost = StreamController<void>.broadcast(sync: true);

  void move(int dx, int dy) => _moves.add((dx, dy));
  void lose() => _lost.add(null);

  @override
  Future<bool> available() async => can;

  /// Where set, the computer takes its time to answer [start]: until this is completed.
  Completer<bool>? startLater;

  @override
  Future<bool> start() async {
    starts++;
    final later = startLater;
    if (later != null) return later.future;
    return startAnswer;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  void renew() => renews++;

  @override
  Stream<(int, int)> get moves => _moves.stream;

  @override
  Stream<void> get lost => _lost.stream;
}
