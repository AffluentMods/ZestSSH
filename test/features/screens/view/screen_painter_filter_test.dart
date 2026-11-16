// Remote screens (4.0): how the picture is filtered when it is drawn
// at another size than the remote's. Off, it is what it always was: sharp at
// one to one and above, a little smoothing below. On, it is smoothed wherever
// a remote pixel is not a whole number of the screen's own pixels, and left
// alone where it is (smoothing a picture that needs none only blurs it).
import 'dart:ui' show FilterQuality;

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/view/screen_painter.dart';

void main() {
  FilterQuality f(double scale, double dpr, {required bool smooth}) =>
      ScreenPainter.filterFor(scale, dpr, smooth: smooth);

  test('off: sharp at one to one and above, a little smoothing below, whatever the screen', () {
    for (final dpr in [1.0, 1.25, 2.0, 3.0]) {
      expect(f(1, dpr, smooth: false), FilterQuality.none);
      expect(f(1.37, dpr, smooth: false), FilterQuality.none);
      expect(f(4, dpr, smooth: false), FilterQuality.none);
      expect(f(0.99, dpr, smooth: false), FilterQuality.low);
      expect(f(0.3, dpr, smooth: false), FilterQuality.low);
    }
  });

  test('on: nothing where a remote pixel is a whole number of pixels of the screen', () {
    expect(f(1, 1, smooth: true), FilterQuality.none);
    expect(f(2, 1, smooth: true), FilterQuality.none);
    expect(f(3, 1, smooth: true), FilterQuality.none);
    // One to one on a screen with two pixels to a logical one: each remote
    // pixel is two by two.
    expect(f(1, 2, smooth: true), FilterQuality.none);
    expect(f(0.5, 2, smooth: true), FilterQuality.none);
    expect(f(1.5, 2, smooth: true), FilterQuality.none);
    // A whisker off a whole number (the viewport's arithmetic) is still whole.
    expect(f(1.0005, 1, smooth: true), FilterQuality.none);
    expect(f(0.9995, 2, smooth: true), FilterQuality.none);
  });

  test('on: shown larger at an uneven size, neighbouring pixels are blended', () {
    expect(f(1.37, 1, smooth: true), FilterQuality.low);
    expect(f(2.5, 1, smooth: true), FilterQuality.low);
    expect(f(1, 1.25, smooth: true), FilterQuality.low, reason: 'Windows at 125 percent');
    expect(f(1, 1.5, smooth: true), FilterQuality.low);
    expect(f(0.8, 2, smooth: true), FilterQuality.low, reason: '1.6 pixels of the screen');
  });

  test('on: shown smaller, the filter made for a picture made smaller', () {
    expect(f(0.5, 1, smooth: true), FilterQuality.medium);
    expect(f(0.99, 1, smooth: true), FilterQuality.medium);
    expect(f(0.3, 2, smooth: true), FilterQuality.medium);
  });

  test('a screen that says no pixel ratio counts as one', () {
    expect(f(1, 0, smooth: true), FilterQuality.none);
    expect(f(1.5, -1, smooth: true), FilterQuality.low);
  });
}
