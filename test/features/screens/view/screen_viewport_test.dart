// Remote screens (4.0): where the picture sits. Fit never
// enlarges, fill does, one to one is a device pixel; the picture is centred on
// whole logical pixels inside the safe area, may go under the edges only when
// zoomed, zooms about a point without drift, and slides up from under a soft
// keyboard without shrinking.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';

ScreenViewport vp(int w, int h, Size view, {EdgeInsets insets = EdgeInsets.zero, double dpr = 1}) => ScreenViewport()
  ..setRemote(w, h)
  ..setView(view, insets: insets, devicePixelRatio: dpr);

void main() {
  test('fit: never above one to one, centred on whole logical pixels', () {
    final small = vp(1280, 800, const Size(1921, 1201));
    expect(small.scale, 1);
    expect(small.origin, const Offset(320, 200));
    final big = vp(1920, 1080, const Size(1001, 701));
    expect(big.scale, closeTo(1001 / 1920, 1e-12));
    expect(big.origin.dx, 0);
    expect(big.origin.dy, big.origin.dy.floorToDouble());
    expect(big.toRemote(const Offset(1000.9, 700.9)), (1919, 1079));
    expect(big.toRemote(const Offset(-5, -5)), (0, 0));
  });

  test('fill enlarges up to 4 logical pixels per remote pixel; one to one follows the device', () {
    final v = vp(640, 400, const Size(1600, 1000))..fit = ScreenFit.fill;
    expect(v.scale, 2.5);
    v.setView(const Size(4000, 4000));
    expect(v.scale, 4);
    v
      ..fit = ScreenFit.oneToOne
      ..setView(const Size(1600, 1000), devicePixelRatio: 2);
    expect(v.scale, 0.5);
  });

  test('fitted inside the safe area; zoomed, it may go under the edges', () {
    final v = vp(1000, 500, const Size(1100, 500), insets: const EdgeInsets.only(left: 100, top: 40, bottom: 20));
    // 1000 x 440 inside: 0.88, 880 x 440, centred in it.
    expect(v.scale, closeTo(0.88, 1e-12));
    expect(v.origin, const Offset(160, 40));
    v.zoomTo(3, const Offset(500, 250), const Offset(550, 250));
    expect(v.origin.dx, lessThan(0));
    v.panBy(const Offset(10000, 10000));
    expect(v.origin, Offset.zero, reason: 'up to the edge, no gap');
    v.panBy(const Offset(-10000, -10000));
    expect(v.pictureRect.right, closeTo(1100, 1e-9));
    expect(v.pictureRect.bottom, closeTo(500, 1e-9));
  });

  test('a zoom keeps the remote point under the fingers, and is kept under 4 per pixel', () {
    final v = vp(800, 500, const Size(400, 250));
    const focal = Offset(123, 77);
    final anchor = v.toRemoteOffset(focal);
    v.zoomTo(3.7, anchor, focal);
    expect((v.toRemoteOffset(focal) - anchor).distance, lessThan(1e-9));
    expect(v.maxZoom, 8);
    v.zoomTo(100, anchor, focal);
    expect(v.scale, 4);
    v.resetZoom();
    expect(v.scale, 0.5);
    expect(v.origin, Offset.zero);
  });

  test('a soft keyboard: the picture keeps its size and slides up to show the point', () {
    final v = vp(1280, 800, const Size(914, 411));
    final scale = v.scale;
    final before = v.origin;
    v.obscuredBottom = 250;
    expect(v.scale, scale, reason: 'never shrunk to a strip');
    expect(v.origin, before, reason: 'nothing moves until asked');
    // The last tap was near the bottom of the remote screen.
    v.reveal(640, 760);
    final at = v.toLocal(640, 760);
    // Above the keyboard (the picture can slide up by the keyboard's height, no more).
    expect(at.dy, lessThan(411 - 250));
    expect(v.origin.dy, closeTo(-250, 1e-9));
    expect(v.origin.dy, lessThan(before.dy));
    // A point already in view: nothing moves.
    final o = v.origin;
    v.reveal(640, v.toRemoteOffset(const Offset(457, 100)).dy);
    expect(v.origin, o);
    // The keyboard goes: back in place.
    v.obscuredBottom = 0;
    expect(v.origin, before);
  });
}
