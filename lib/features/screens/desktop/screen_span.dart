// Remote screens (4.1): full screen on all monitors, an RDP screen on a
// computer with several monitors. The remote is asked for one display per
// monitor of this PC, each the monitor's own size and place (its pixels, and
// the text size its scaling gives), and the window covers them all, so each
// remote display sits on a monitor of its own, as Windows' own Remote Desktop
// does with "Use all my monitors". Windows first: its runner lists the
// monitors and stretches the window (windows/runner/monitor_span.cpp); on
// other computers the channel answers nothing and the action is not offered.
import 'dart:ui' show Rect;

import 'package:flutter/services.dart';
import 'package:zest_native/screen.dart' show ScreenDisplaySpec;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';

/// One monitor of this PC, in its real pixels on the desktop.
class LocalMonitor {
  const LocalMonitor({
    required this.left,
    required this.top,
    required this.width,
    required this.height,
    this.dpi = 96,
    this.primary = false,
  });

  final int left;
  final int top;
  final int width;
  final int height;

  /// Its effective DPI: 96 is 100%.
  final int dpi;
  final bool primary;

  int get right => left + width;
  int get bottom => top + height;

  /// Its scaling in percent, as RDP takes it (100 to 500).
  int get scalePercent => (dpi * 100 / 96).round().clamp(100, 500);

  @override
  String toString() => 'LocalMonitor($left, $top, ${width}x$height, $dpi dpi${primary ? ', primary' : ''})';
}

/// The computer's part that lists the monitors and stretches the window.
abstract interface class MonitorSpanner {
  /// This PC's monitors, the primary one first; empty where it cannot say.
  Future<List<LocalMonitor>> monitors();

  /// Stretches the window over [area] (real pixels), borderless and on top.
  Future<bool> span(Rect area);

  /// Puts the window back as it was.
  Future<void> unspan();
}

/// [MonitorSpanner] over the app's channel `zestssh/monitor_span`
/// (windows/runner). Elsewhere: no monitors, nothing stretched.
class ChannelMonitorSpanner implements MonitorSpanner {
  const ChannelMonitorSpanner();

  static const _methods = MethodChannel('zestssh/monitor_span');

  @override
  Future<List<LocalMonitor>> monitors() async {
    try {
      final list = await _methods.invokeMethod<List<Object?>>('monitors') ?? const [];
      return [
        for (final m in list)
          if (m is List && m.length == 6)
            LocalMonitor(
              left: m[0] as int,
              top: m[1] as int,
              width: m[2] as int,
              height: m[3] as int,
              dpi: m[4] as int,
              primary: m[5] as bool,
            ),
      ];
    } on PlatformException {
      return const [];
    } on MissingPluginException {
      return const [];
    }
  }

  @override
  Future<bool> span(Rect area) async {
    try {
      return await _methods.invokeMethod<bool>('span', [
            area.left.round(),
            area.top.round(),
            area.width.round(),
            area.height.round(),
          ]) ??
          false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<void> unspan() async {
    try {
      await _methods.invokeMethod<void>('unspan');
    } on PlatformException {
      // Not stretched.
    } on MissingPluginException {
      // No such part on this device.
    }
  }
}

/// What spanning asks for: the monitors used, the remote's displays (one
/// for each, at its size and place, the primary first and primary), and the
/// area of this PC the window covers (the rectangle around them).
class SpanPlan {
  const SpanPlan(this.monitors, this.displays, this.area);

  final List<LocalMonitor> monitors;
  final List<ScreenDisplaySpec> displays;
  final Rect area;

  /// The plan for [all] this PC's monitors, or null where there is not more
  /// than one to use. At most [ScreenOptions.maxDisplays]: the primary
  /// first, then the nearest to it. A monitor larger than one remote display
  /// may be (a side over [ScreenViewSize.maxSide], more than
  /// [ScreenViewSize.maxPixels]) is left out, as the engine takes several
  /// displays only as they are given.
  static SpanPlan? of(List<LocalMonitor> all) {
    final fits = [
      for (final m in all)
        if (m.width > 0 &&
            m.height > 0 &&
            m.width <= ScreenViewSize.maxSide &&
            m.height <= ScreenViewSize.maxSide &&
            m.width * m.height <= ScreenViewSize.maxPixels)
          m,
    ];
    if (fits.length < 2) return null;
    final primary = fits.firstWhere((m) => m.primary, orElse: () => fits.first);
    final cx = primary.left + primary.width / 2;
    final cy = primary.top + primary.height / 2;
    double far(LocalMonitor m) {
      final dx = m.left + m.width / 2 - cx;
      final dy = m.top + m.height / 2 - cy;
      return dx * dx + dy * dy;
    }

    final others = [for (final m in fits) if (!identical(m, primary)) m]..sort((a, b) => far(a).compareTo(far(b)));
    final used = [primary, ...others.take(ScreenOptions.maxDisplays - 1)];
    final left = used.map((m) => m.left).reduce((a, b) => a < b ? a : b);
    final top = used.map((m) => m.top).reduce((a, b) => a < b ? a : b);
    final right = used.map((m) => m.right).reduce((a, b) => a > b ? a : b);
    final bottom = used.map((m) => m.bottom).reduce((a, b) => a > b ? a : b);
    return SpanPlan(
      used,
      [
        for (final m in used)
          ScreenDisplaySpec(
            x: m.left - left,
            y: m.top - top,
            width: m.width,
            height: m.height,
            scale: m.scalePercent,
            primary: identical(m, primary),
          ),
      ],
      Rect.fromLTRB(left.toDouble(), top.toDouble(), right.toDouble(), bottom.toDouble()),
    );
  }
}
