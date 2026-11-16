// "Resize the remote" (RDP, 4.0): the size a screen's view has, as the
// remote is asked to take it.
import 'dart:ui' show Size;

import 'package:zest_native/screen.dart' show ScreenDisplaySpec;

abstract final class ScreenViewSize {
  /// The size of the last screen view that followed its tab ("Resize the
  /// remote"), in logical pixels: what the next RDP session of that kind
  /// starts at, so it is not resized a moment after it connects. Null until
  /// one was laid out.
  static Size? lastFollowed;

  /// [view] (logical pixels) as a remote screen's size: whole pixels, the
  /// width even (RDP wants it so), neither side under 200 (the smallest a
  /// server takes). One logical pixel is one remote pixel, so a screen with
  /// more pixels to the inch shows the remote scaled up, at a size that can
  /// be read.
  static (int, int) remoteOf(Size view) {
    final w = view.width.floor() & ~1, h = view.height.floor();
    return (w < 200 ? 200 : w, h < 200 ? 200 : h);
  }

  /// The size a remote display starts at where no view has said one yet.
  static const startSize = Size(1280, 800);

  /// The largest side and the most pixels the engine takes for one display.
  static const maxSide = 8192;
  static const maxPixels = 8294400;

  /// [count] displays for a remote shown one at a time in a view of [view]
  /// (4.0): each the view's size as [remoteOf] gives it, side by
  /// side from the left, the first the primary one. So moving between them
  /// never rescales. A size the engine would not take as it is (a side
  /// over 8192, more than its pixels for one display) is brought down
  /// first, keeping its shape: the engine takes several displays only as
  /// they are given. [scale]: how large each draws its text, in percent
  /// (0: nothing said). [maxDesktopPixels]: where the device has a ceiling
  /// for the whole desktop (a phone), as many of the displays as fit
  /// under it, one at least.
  static List<ScreenDisplaySpec> displaysOf(int count, Size view, {int scale = 0, int? maxDesktopPixels}) {
    var (w, h) = remoteOf(view);
    if (w > maxSide || h > maxSide || w * h > maxPixels) {
      var scale = 1.0;
      if (w > maxSide) scale = maxSide / w;
      if (h * scale > maxSide) scale = maxSide / h;
      while ((w * scale).floor() * (h * scale).floor() > maxPixels) {
        scale *= 0.98;
      }
      (w, h) = remoteOf(Size(w * scale, h * scale));
    }
    if (maxDesktopPixels != null) {
      while (count > 1 && count * w * h > maxDesktopPixels) {
        count--;
      }
    }
    return [
      for (var i = 0; i < count; i++)
        ScreenDisplaySpec(x: i * w, width: w, height: h, scale: scale, primary: i == 0),
    ];
  }
}
