// The spike's measurements and input checks, driven through the widget's own input path: the
// pointer as Flutter pointer events (hit-tested to the view's Listener, mapped to remote pixels
// by the view's layout) and keys through the same handler the view's Focus calls.
//
// Against the test servers' Xvnc :31 (xterm at +20+20, 80 x 24 in the 6 x 13 "fixed" font;
// xeyes at +700+40, 240 x 180): idle, input to painted pixels (xeyes after a pointer jump, xterm
// after a key), frame rate while xeyes follows a circling pointer, while xterm scrolls and while
// ico spins, then the input check (a typed command writes a file; a double click selects a word
// into PRIMARY, which TigerVNC also hands back as clipboard text).
//
// Against xrdp's Xfce session (runRdp): the same phases with an xterm and xeyes the test started
// on the session's display (ZS_XTERM_ORIGIN, the xterm's inside top left, and ZS_XEYES_CENTER,
// both "x,y" from xwininfo), the whole-screen phase as a full-screen xterm flipping to reverse
// video, and resizes of the desktop at the end (ZS_RDP_RESIZE, WxH, or several comma separated).
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zest_native/screen.dart';

import 'cpu.dart';
import 'env.dart';
import 'keysyms.dart' as keysyms;
import 'screen_view.dart';

String jsonLine(Map<String, Object?> m) => jsonEncode(m);

class SelfTest {
  SelfTest({
    required this.session,
    required this.controller,
    required this.viewKey,
    required this.shotKey,
    required this.log,
  });

  final ScreenSession session;
  final ScreenController controller;
  final GlobalKey viewKey;
  final GlobalKey shotKey;
  final void Function(Map<String, Object?>) log;

  static const _device = 77;
  int _pointer = 100;
  bool _added = false;

  Future<void> _pause(int ms) => Future.delayed(Duration(milliseconds: ms));

  Offset _global(int x, int y) {
    final box = viewKey.currentContext!.findRenderObject()! as RenderBox;
    return box.localToGlobal(controller.toLocal(x, y));
  }

  void _send(PointerEvent e) => GestureBinding.instance.handlePointerEvent(e);

  void hover(int x, int y) {
    final p = _global(x, y);
    if (!_added) {
      _added = true;
      _send(PointerAddedEvent(device: _device, position: p, kind: PointerDeviceKind.mouse));
    }
    _send(PointerHoverEvent(device: _device, position: p, kind: PointerDeviceKind.mouse));
  }

  Future<void> click(int x, int y, {int times = 1}) async {
    hover(x, y);
    final p = _global(x, y);
    for (var i = 0; i < times; i++) {
      final id = ++_pointer;
      _send(PointerDownEvent(
          pointer: id, device: _device, position: p, kind: PointerDeviceKind.mouse, buttons: kPrimaryButton));
      _send(PointerUpEvent(pointer: id, device: _device, position: p, kind: PointerDeviceKind.mouse));
      await _pause(40);
    }
  }

  void _key(LogicalKeyboardKey logical, PhysicalKeyboardKey physical, String? character, bool down) {
    final e = down
        ? KeyDownEvent(physicalKey: physical, logicalKey: logical, character: character, timeStamp: Duration.zero)
        : KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: Duration.zero);
    controller.key(e);
  }

  /// Types [text] as a US keyboard would: each character on its own key, with Shift held for the
  /// ones that need it.
  Future<void> type(String text) async {
    for (final ch in text.runes) {
      final s = String.fromCharCode(ch);
      final logical = LogicalKeyboardKey(ch);
      final (physical, shift) = keysyms.usKey(ch) ?? (PhysicalKeyboardKey.keyA, false);
      if (shift) _key(LogicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftLeft, null, true);
      _key(logical, physical, s, true);
      _key(logical, physical, s, false);
      if (shift) _key(LogicalKeyboardKey.shiftLeft, PhysicalKeyboardKey.shiftLeft, null, false);
      await _pause(4);
    }
  }

  Future<void> press(LogicalKeyboardKey key, PhysicalKeyboardKey physical) async {
    _key(key, physical, null, true);
    _key(key, physical, null, false);
    await _pause(4);
  }

  Future<void> enter() => press(LogicalKeyboardKey.enter, PhysicalKeyboardKey.enter);

  static double _pct(List<double> sorted, double p) =>
      sorted.isEmpty ? 0 : sorted[math.min(sorted.length - 1, (sorted.length * p).floor())];

  static Map<String, Object?> _dist(List<double> v) {
    final s = [...v]..sort();
    String r(double x) => x.toStringAsFixed(1);
    return {
      'n': s.length,
      'p50': r(_pct(s, 0.5)),
      'p95': r(_pct(s, 0.95)),
      'max': r(s.isEmpty ? 0 : s.last),
      'mean': r(s.isEmpty ? 0 : s.reduce((a, b) => a + b) / s.length),
    };
  }

  final List<ui.FrameTiming> _timings = [];

  /// Measures [ms] milliseconds while [during] runs.
  Future<Map<String, Object?>> measure(String name, int ms, [Future<void> Function()? during]) async {
    controller.painted.clear();
    _timings.clear();
    final cpu0 = processCpuUs();
    final t0 = ScreenSession.nowUs();
    final in0 = session.bytesIn;
    final out0 = session.bytesOut;
    final work = during?.call();
    await _pause(ms);
    await work;
    final t1 = ScreenSession.nowUs();
    final cpu1 = processCpuUs();
    final secs = (t1 - t0) / 1e6;
    final f = [...controller.painted];
    double ms_(int us) => us / 1000;
    final result = <String, Object?>{
      'phase': name,
      'seconds': secs.toStringAsFixed(2),
      'screen': '${controller.width}x${controller.height}',
      'frames_painted': f.length,
      'fps': (f.length / secs).toStringAsFixed(1),
      'server_updates': f.fold<int>(0, (a, x) => a + x.updates),
      'update_to_painted_ms': _dist([for (final x in f) ms_(x.paintedUs - x.firstChangeUs)]),
      'stage_engine_ms': _dist([for (final x in f) ms_(x.lastDoneUs - x.firstChangeUs)]),
      'stage_wait_take_ms': _dist([for (final x in f) ms_(x.takenUs - x.lastDoneUs)]),
      'stage_images_ms': _dist([for (final x in f) ms_(x.imagesUs - x.takenUs)]),
      'stage_to_painted_ms': _dist([for (final x in f) ms_(x.paintedUs - x.imagesUs)]),
      'raster_ms': _dist([for (final x in _timings) x.rasterDuration.inMicroseconds / 1000]),
      'tiles_per_frame': f.isEmpty ? 0 : (f.fold<int>(0, (a, x) => a + x.tiles) / f.length).toStringAsFixed(1),
      'pixels_mb_per_s': (f.fold<int>(0, (a, x) => a + x.bytes) / secs / 1e6).toStringAsFixed(2),
      'network_in_kb_per_s': ((session.bytesIn - in0) / secs / 1e3).toStringAsFixed(1),
      'network_out_kb_per_s': ((session.bytesOut - out0) / secs / 1e3).toStringAsFixed(1),
      'cpu_percent_of_one_core': ((cpu1 - cpu0) / (t1 - t0) * 100).toStringAsFixed(1),
      'rss_mb': (ProcessInfo.currentRss / 1e6).toStringAsFixed(0),
    };
    log(result);
    return result;
  }

  /// Input to painted pixels: each step sends one input, then waits for the first painted frame
  /// whose change reached the engine after it.
  Future<void> inputLatency(String name, int steps, Future<void> Function(int i) step) async {
    final lat = <double>[];
    var missed = 0;
    for (var i = 0; i < steps; i++) {
      controller.painted.clear();
      final sent = ScreenSession.nowUs();
      await step(i);
      FrameTimes? hit;
      for (var w = 0; w < 100 && hit == null; w++) {
        await _pause(5);
        for (final f in controller.painted) {
          if (f.firstChangeUs > sent) {
            hit = f;
            break;
          }
        }
      }
      if (hit == null) {
        missed++;
      } else {
        lat.add((hit.paintedUs - sent) / 1000);
      }
      await _pause(150);
    }
    log({'phase': name, 'input_to_painted_ms': _dist(lat), 'missed': missed});
  }

  /// A real pause: [command] keeps the screen changing; the session is paused for 2 s (the
  /// server should send next to nothing), then resumed (the whole screen comes again).
  Future<void> pauseCheck(String command) async {
    await type(command);
    await enter();
    await _pause(500);
    final running = await measure('before_pause', 1000);
    final in0 = session.bytesIn;
    final t0 = ScreenSession.nowUs();
    controller.paused = true;
    session.pause();
    // The update in flight when the pause went out may still come: start counting after it.
    await _pause(300);
    final in1 = session.bytesIn;
    final t1 = ScreenSession.nowUs();
    await _pause(2000);
    final pausedBytes = session.bytesIn - in1;
    final pausedSecs = (ScreenSession.nowUs() - t1) / 1e6;
    controller.painted.clear();
    final resumeUs = ScreenSession.nowUs();
    session.resume();
    controller.paused = false;
    FrameTimes? first;
    for (var i = 0; i < 400 && first == null; i++) {
      await _pause(5);
      for (final f in controller.painted) {
        if (f.firstChangeUs > resumeUs) {
          first = f;
          break;
        }
      }
    }
    log({
      'phase': 'pause_resume',
      'running_network_in_kb_per_s': running['network_in_kb_per_s'],
      'first_300ms_after_pause_kb': ((in1 - in0) / 1e3).toStringAsFixed(1),
      'paused_network_in_kb_per_s': (pausedBytes / pausedSecs / 1e3).toStringAsFixed(2),
      'paused_seconds': pausedSecs.toStringAsFixed(2),
      'pause_to_resume_ms': ((resumeUs - t0) / 1000).toStringAsFixed(0),
      'resume_to_painted_ms': first == null ? null : ((first.paintedUs - resumeUs) / 1000).toStringAsFixed(1),
      'resume_first_frame_tiles': first?.tiles,
    });
    await _pause(2500);
  }

  Future<void> run(String? shotPath) async {
    SchedulerBindingTimings.add(_timings);
    controller.onlyDevice = _device;
    await _pause(1500);
    await measure('idle', 2000);

    // xeyes: pointer jumps between two spots beside it; the pupils follow.
    await inputLatency('input_xeyes_pointer', 14, (i) async => hover(i.isEven ? 640 : 1000, i.isEven ? 120 : 260));
    // xeyes following a circling pointer (60 moves a second).
    await measure('xeyes_circle', 4000, () async {
      for (var i = 0; i < 240; i++) {
        final a = i / 30 * math.pi;
        hover((820 + 160 * math.cos(a)).round(), (130 + 110 * math.sin(a)).round());
        await _pause(16);
      }
    });

    // xterm: click into it (focus follows the pointer anyway, there is no window manager).
    await click(200, 200);
    // Ctrl+C first: drops whatever an earlier run left on the prompt (and checks a modifier).
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, false);
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, false);
    await _pause(300);
    await inputLatency('input_xterm_key', 10, (i) => type('x'));
    for (var i = 0; i < 10; i++) {
      await press(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
    }
    await _pause(300);

    // xterm scrolling as fast as it can for 5 s.
    await type("timeout 5 sh -c 'while :; do date +%s.%N; done'");
    await enter();
    await measure('xterm_scroll', 5200);
    await _pause(500);

    // ico spinning in a big window for 6 s.
    await type('timeout 6 ico -faces -geometry ${controller.width - 100}x${controller.height - 100}+60+60');
    await enter();
    await measure('ico_spin', 6200);
    await _pause(1200);

    // The worst case for path A: the whole root window changes colour as fast as xsetroot can
    // (tiny on the wire, every tile uploaded again).
    await type("timeout 5 sh -c 'while :; do xsetroot -solid red; xsetroot -solid blue; done'; xsetroot -solid black");
    await enter();
    await measure('fullscreen_flip', 5200);
    await _pause(800);

    // Pause and resume while xterm scrolls.
    hover(200, 200);
    await pauseCheck("timeout 4 sh -c 'while :; do date +%s.%N; done'");

    // The input check: a command typed through the view writes a file; then a double click on
    // the word it printed selects it (PRIMARY).
    hover(200, 200);
    await type('clear');
    await enter();
    await _pause(300);
    await type('echo ZSWORD; echo zs-typed-OK > ~/zs-input-check');
    await enter();
    await _pause(800);
    // Row 1 (after the prompt line), column 2: xterm at (20, 20), border 1, inner border 2,
    // 6 x 13 cells.
    await click(20 + 1 + 2 + 2 * 6 + 3, 20 + 1 + 2 + 13 + 6, times: 2);
    await _pause(800);
    await measure('after_input', 500);

    if (shotPath != null && shotPath.isNotEmpty) {
      final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      // Right after a frame, before anything asks for the next paint.
      final drawn = Completer<ui.Image>();
      SchedulerBinding.instance.addPostFrameCallback((_) => drawn.complete(boundary.toImage(pixelRatio: 1 / controller.scale)));
      SchedulerBinding.instance.scheduleFrame();
      final image = await drawn.future;
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      File(shotPath).writeAsBytesSync(png!.buffer.asUint8List());
      log({
        'event': 'shot',
        'path': shotPath,
        'size': '${image.width}x${image.height}',
        // Where the remote picture sits in the PNG, at 1:1.
        'origin': [controller.origin.dx / controller.scale, controller.origin.dy / controller.scale],
        'scale': controller.scale,
      });
    }
    SchedulerBindingTimings.remove(_timings);
    controller.onlyDevice = null;
    log({'event': 'SELFTEST_DONE'});
  }
}

extension RdpSelfTest on SelfTest {
  static (int, int) _point(String? v, (int, int) fallback) {
    final p = (v ?? '').split(',');
    if (p.length != 2) return fallback;
    return (int.tryParse(p[0].trim()) ?? fallback.$1, int.tryParse(p[1].trim()) ?? fallback.$2);
  }

  Future<void> _ctrlC() async {
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, false);
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, false);
    await _pause(300);
  }

  Future<void> _shot(String? shotPath) async {
    if (shotPath == null || shotPath.isEmpty) return;
    final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final drawn = Completer<ui.Image>();
    SchedulerBinding.instance.addPostFrameCallback((_) => drawn.complete(boundary.toImage(pixelRatio: 1 / controller.scale)));
    SchedulerBinding.instance.scheduleFrame();
    final image = await drawn.future;
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    File(shotPath).writeAsBytesSync(png!.buffer.asUint8List());
    log({
      'event': 'shot',
      'path': shotPath,
      'size': '${image.width}x${image.height}',
      'origin': [controller.origin.dx / controller.scale, controller.origin.dy / controller.scale],
      'scale': controller.scale,
    });
  }

  /// The RDP run: see the file's header.
  Future<void> runRdp(String? shotPath) async {
    SchedulerBindingTimings.add(_timings);
    controller.onlyDevice = SelfTest._device;
    await _pause(1500);
    await measure('idle', 2000);

    final (xx, xy) = _point(env['ZS_XTERM_ORIGIN'], (40, 80));
    final (ex, ey) = _point(env['ZS_XEYES_CENTER'], (820, 170));
    await inputLatency('input_xeyes_pointer', 14, (i) async => hover(i.isEven ? ex - 180 : ex + 180, i.isEven ? ey - 10 : ey + 130));
    await measure('xeyes_circle', 4000, () async {
      for (var i = 0; i < 240; i++) {
        final a = i / 30 * math.pi;
        hover((ex + 160 * math.cos(a)).round(), (ey + 110 * math.sin(a)).round());
        await _pause(16);
      }
    });

    // xterm: click into it (Xfce gives the focus on a click).
    final inside = (xx + 240, xy + 150);
    await click(inside.$1, inside.$2);
    await _pause(300);
    await _ctrlC();
    await inputLatency('input_xterm_key', 10, (i) => type('x'));
    for (var i = 0; i < 10; i++) {
      await press(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
    }
    await _pause(300);

    await type("timeout 5 sh -c 'while :; do date +%s.%N; done'");
    await enter();
    await measure('xterm_scroll', 5200);
    await _pause(500);

    await type('timeout 6 ico -faces -geometry ${controller.width - 100}x${controller.height - 140}+60+80');
    await enter();
    await measure('ico_spin', 6200);
    await _pause(1200);

    // The whole screen changing: a full-screen xterm flipping to reverse video and back.
    await type(r"""timeout 5 xterm -fullscreen -e sh -c 'while :; do printf "\033[?5h"; sleep 0.02; printf "\033[?5l"; sleep 0.02; done'""");
    await enter();
    await measure('fullscreen_flip', 5200);
    await _pause(1000);

    // Pause and resume while xterm scrolls.
    await click(inside.$1, inside.$2);
    await _pause(300);
    await pauseCheck("timeout 4 sh -c 'while :; do date +%s.%N; done'");

    // The input check: a command typed through the view writes a file; a double click on the
    // word it printed selects it (PRIMARY).
    await click(inside.$1, inside.$2);
    await _pause(300);
    await type('clear');
    await enter();
    await _pause(300);
    await type('echo ZSWORD; echo zs-typed-OK > ~/zs-input-check');
    await enter();
    await _pause(800);
    // Row 1 (after the prompt line), column 2: the inside's top left, xterm's inner border 2,
    // 6 x 13 cells.
    await click(xx + 2 + 2 * 6 + 3, xy + 2 + 13 + 6, times: 2);
    await _pause(800);
    await measure('after_input', 500);
    hover(inside.$1 + 200, inside.$2 + 200);
    await _pause(500);
    await _shot(shotPath);
    // Time for the test to take the server's own screenshot of the same moment.
    await _pause(int.tryParse(env['ZS_SHOT_HOLD_MS'] ?? '') ?? 4000);

    // Resize the desktop (the display control channel), timed to the first frame at the new
    // size; ZS_RDP_RESIZE may list several sizes (comma separated), one after the other.
    for (final size in (env['ZS_RDP_RESIZE'] ?? '').split(',')) {
      final m = RegExp(r'^(\d+)x(\d+)$').firstMatch(size.trim());
      if (m == null) continue;
      final w = int.parse(m.group(1)!), h = int.parse(m.group(2)!);
      final resized = Completer<int>();
      final sub = session.events.listen((e) {
        if (e is ScreenResized && !resized.isCompleted) resized.complete(ScreenSession.nowUs());
      });
      controller.painted.clear();
      final t0 = ScreenSession.nowUs();
      session.resize(w, h);
      int? atUs;
      try {
        atUs = await resized.future.timeout(const Duration(seconds: 10));
      } on TimeoutException {
        atUs = null;
      }
      await sub.cancel();
      int? paintedUs;
      for (var i = 0; i < 400 && atUs != null && paintedUs == null; i++) {
        await _pause(5);
        for (final f in controller.painted) {
          if (f.firstChangeUs >= atUs && controller.width == w && controller.height == h) {
            paintedUs = f.paintedUs;
            break;
          }
        }
      }
      log({
        'phase': 'resize',
        'asked': '${w}x$h',
        'now': '${controller.width}x${controller.height}',
        'to_resized_ms': atUs == null ? null : ((atUs - t0) / 1000).toStringAsFixed(1),
        'to_painted_ms': paintedUs == null ? null : ((paintedUs - t0) / 1000).toStringAsFixed(1),
      });
      await _pause(1500);
      await measure('after_resize', 1000);
    }
    SchedulerBindingTimings.remove(_timings);
    controller.onlyDevice = null;
    log({'event': 'SELFTEST_DONE'});
  }
}

/// The phone checks (runTouch): touch gestures as Flutter touch events through the view's own
/// Listener (device 78, so a real finger cannot interfere), the soft keyboard's text through the
/// handler the text input channel calls (SoftKeyboard.updateEditingValue, as an IME commits one
/// character a key), and checkpoints where the run holds still for ZS_CHECK_HOLD_MS (3000) so the
/// test can read the server's PRIMARY selection or take a screenshot. VNC: Xvnc :31's xterm at
/// +20+20; RDP: the xterm at ZS_XTERM_ORIGIN.
extension TouchSelfTest on SelfTest {
  static const _touchDevice = 78;

  void _t(PointerEvent e) => GestureBinding.instance.handlePointerEvent(e);

  Future<void> _tap(int x, int y, {int holdMs = 40}) async {
    final p = _global(x, y);
    final id = ++_pointer;
    _t(PointerDownEvent(pointer: id, device: _touchDevice, position: p, kind: PointerDeviceKind.touch));
    await _pause(holdMs);
    _t(PointerUpEvent(pointer: id, device: _touchDevice, position: p, kind: PointerDeviceKind.touch));
  }

  /// One finger from [from] to [to] (global positions), in [steps] moves over [ms].
  Future<void> _drag(Offset from, Offset to, {int steps = 12, int ms = 240, int holdMs = 0}) async {
    final id = ++_pointer;
    _t(PointerDownEvent(pointer: id, device: _touchDevice, position: from, kind: PointerDeviceKind.touch));
    if (holdMs > 0) await _pause(holdMs);
    for (var i = 1; i <= steps; i++) {
      _t(PointerMoveEvent(
          pointer: id, device: _touchDevice, position: Offset.lerp(from, to, i / steps)!, kind: PointerDeviceKind.touch));
      await _pause(ms ~/ steps);
    }
    _t(PointerUpEvent(pointer: id, device: _touchDevice, position: to, kind: PointerDeviceKind.touch));
  }

  /// Two fingers on a horizontal line around a centroid going from [c0] to [c1], their distance
  /// from [span0] to [span1] (global logical pixels).
  Future<void> _two(Offset c0, Offset c1, double span0, double span1,
      {int steps = 20, int ms = 400, bool liftAtEnd = true}) async {
    final a = ++_pointer, b = ++_pointer;
    Offset pa(double t) => Offset.lerp(c0, c1, t)! - Offset((span0 + (span1 - span0) * t) / 2, 0);
    Offset pb(double t) => Offset.lerp(c0, c1, t)! + Offset((span0 + (span1 - span0) * t) / 2, 0);
    _t(PointerDownEvent(pointer: a, device: _touchDevice, position: pa(0), kind: PointerDeviceKind.touch));
    await _pause(10);
    _t(PointerDownEvent(pointer: b, device: _touchDevice, position: pb(0), kind: PointerDeviceKind.touch));
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      _t(PointerMoveEvent(pointer: a, device: _touchDevice, position: pa(t), kind: PointerDeviceKind.touch));
      _t(PointerMoveEvent(pointer: b, device: _touchDevice, position: pb(t), kind: PointerDeviceKind.touch));
      await _pause(ms ~/ steps);
    }
    if (!liftAtEnd) return;
    _t(PointerUpEvent(pointer: a, device: _touchDevice, position: pa(1), kind: PointerDeviceKind.touch));
    _t(PointerUpEvent(pointer: b, device: _touchDevice, position: pb(1), kind: PointerDeviceKind.touch));
  }

  /// The two fingers of the last [_two] (left down) move on from centroid [c0] to [c1] with the
  /// same [span], then lift.
  Future<void> _twoContinue(Offset c0, Offset c1, double span, {int steps = 15, int ms = 300}) async {
    final b = _pointer, a = b - 1;
    Offset pa(double t) => Offset.lerp(c0, c1, t)! - Offset(span / 2, 0);
    Offset pb(double t) => Offset.lerp(c0, c1, t)! + Offset(span / 2, 0);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      _t(PointerMoveEvent(pointer: a, device: _touchDevice, position: pa(t), kind: PointerDeviceKind.touch));
      _t(PointerMoveEvent(pointer: b, device: _touchDevice, position: pb(t), kind: PointerDeviceKind.touch));
      await _pause(ms ~/ steps);
    }
    _t(PointerUpEvent(pointer: a, device: _touchDevice, position: pa(1), kind: PointerDeviceKind.touch));
    _t(PointerUpEvent(pointer: b, device: _touchDevice, position: pb(1), kind: PointerDeviceKind.touch));
  }

  /// What an IME does for one key: the character committed after the text.
  Future<void> _imeType(SoftKeyboard kb, String text) async {
    for (final ch in text.runes) {
      final t = kb.currentTextEditingValue!.text + String.fromCharCode(ch);
      kb.updateEditingValue(TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length)));
      await _pause(4);
    }
  }

  void _imeBackspace(SoftKeyboard kb) {
    final cur = kb.currentTextEditingValue!.text;
    final t = cur.substring(0, cur.length - 1);
    kb.updateEditingValue(TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length)));
  }

  Future<void> _checkpoint(String name, [Map<String, Object?> extra = const {}]) async {
    log({'event': 'checkpoint', 'name': name, ...extra});
    await _pause(int.tryParse(env['ZS_CHECK_HOLD_MS'] ?? '') ?? 3000);
  }

  Map<String, Object?> _view() => {
        'zoom': controller.zoom.toStringAsFixed(3),
        'scale': controller.scale.toStringAsFixed(4),
        'origin': [controller.origin.dx.toStringAsFixed(1), controller.origin.dy.toStringAsFixed(1)],
        'view': '${controller.viewSizeNow.width.toStringAsFixed(0)}x${controller.viewSizeNow.height.toStringAsFixed(0)}',
      };

  Future<void> runTouch({required SoftKeyboard keyboard, required bool rdp}) async {
    SchedulerBindingTimings.add(_timings);
    controller.onlyDevice = _touchDevice;
    controller.touchMode = TouchMode.touch;
    controller.resetZoom();
    await _pause(1000);
    log({'event': 'touch_start', ..._view()});
    final (xx, xy) = rdp ? RdpSelfTest._point(env['ZS_XTERM_ORIGIN'], (40, 80)) : (20 + 1, 20 + 1);
    // The middle of xterm's cell (col, row).
    (int, int) cell(int col, int row) => (xx + 2 + col * 6 + 3, xy + 2 + row * 13 + 6);

    // Touch mode: a tap into xterm (focus), Ctrl+C through the key path, then the soft keyboard.
    final inside = cell(40, 12);
    await _tap(inside.$1, inside.$2);
    await _pause(300);
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, true);
    _key(LogicalKeyboardKey.keyC, PhysicalKeyboardKey.keyC, null, false);
    _key(LogicalKeyboardKey.controlLeft, PhysicalKeyboardKey.controlLeft, null, false);
    await _pause(300);
    keyboard.show();
    await _pause(1200);
    log({'event': 'keyboard_shown', ..._view()});

    // Soft keyboard text to painted: one character a step, then as many deletions.
    await inputLatency('input_ime_char', 10, (i) => _imeType(keyboard, 'x'));
    for (var i = 0; i < 10; i++) {
      _imeBackspace(keyboard);
      await _pause(30);
    }
    await _pause(300);
    // A character no US key types (VNC: its keysym; RDP: Unicode events).
    await _imeType(keyboard, 'echo été > ~/zs-unicode-check');
    keyboard.performAction(TextInputAction.newline);
    await _pause(400);
    await _imeType(keyboard, 'clear');
    keyboard.performAction(TextInputAction.newline);
    await _pause(400);
    await _imeType(keyboard, 'echo ZSWORD; echo zs-ime-OK > ~/zs-touch-check');
    keyboard.performAction(TextInputAction.newline);
    await _pause(800);
    keyboard.hide();
    await _pause(1200);
    log({'event': 'keyboard_hidden', ..._view()});

    // A double tap on ZSWORD (row 1, column 2): a double click, the word selected.
    final word = cell(2, 1);
    await _tap(word.$1, word.$2);
    await _pause(60);
    await _tap(word.$1, word.$2);
    await _checkpoint('double_tap_select');

    // Hold on row 2, column 6: a right click there, which in xterm extends the selection.
    final ext = cell(6, 2);
    await _tap(ext.$1, ext.$2, holdMs: 700);
    await _checkpoint('long_press_right_click');

    // Two fingers dragged down by 200 px: the wheel turns up (xterm scrolls back), timed to the
    // first frame painted after the first notch.
    await _imeTypeSilently(keyboard, 'seq 1 300');
    await _pause(800);
    final mid = _global(inside.$1, inside.$2);
    controller.painted.clear();
    controller.touchLog.clear();
    await _two(mid, mid + const Offset(0, 200), 60, 60, steps: 20, ms: 400);
    final firstWheel = controller.touchLog.where((e) => e.$1.startsWith('wheel')).firstOrNull;
    await _pause(400);
    final afterWheel = firstWheel == null ? null : controller.painted.where((f) => f.firstChangeUs > firstWheel.$2).firstOrNull;
    log({
      'phase': 'two_finger_scroll',
      'notches': controller.touchLog.where((e) => e.$1.startsWith('wheel')).length,
      'first': firstWheel?.$1,
      'wheel_to_painted_ms': afterWheel == null || firstWheel == null ? null : ((afterWheel.paintedUs - firstWheel.$2) / 1000).toStringAsFixed(1),
    });
    await _checkpoint('scrolled_back');
    await _two(mid + const Offset(0, 200), mid, 60, 60, steps: 20, ms: 400);
    await _pause(500);

    // Pinch: fingers 120 px apart to 360 px around the view's centre, then a pan of the
    // centroid by 150 px left with the same spread; the remote point under the fingers must stay
    // under them.
    final box = viewKey.currentContext!.findRenderObject()! as RenderBox;
    final centre = box.localToGlobal(box.size.center(Offset.zero));
    final local0 = box.size.center(Offset.zero);
    final anchor0 = (local0 - controller.origin) / controller.scale;
    controller.touchLog.clear();
    final z0 = controller.zoom;
    final sw = Stopwatch()..start();
    await _two(centre, centre, 120, 360, steps: 24, ms: 480);
    final pinchMs = sw.elapsedMilliseconds;
    final anchor1 = (local0 - controller.origin) / controller.scale;
    log({
      'phase': 'pinch_zoom',
      'zoom_before': z0.toStringAsFixed(3),
      'zoom_after': controller.zoom.toStringAsFixed(3),
      'expected': math.min(controller.maxZoom, z0 * 3).toStringAsFixed(3),
      'anchor_drift_remote_px': (anchor1 - anchor0).distance.toStringAsFixed(2),
      'gesture_ms': pinchMs,
      ..._view(),
    });
    await _pause(300);
    // Pinch and pan in one gesture: spread first (it becomes a zoom), then the centroid moves
    // 150 px left with the spread kept: the picture follows the fingers.
    final o0 = controller.origin;
    final z1 = controller.zoom;
    await _two(centre, centre, 200, 240, steps: 10, ms: 200, liftAtEnd: false);
    final oMid = controller.origin;
    await _twoContinue(centre, centre - const Offset(150, 0), 240, steps: 15, ms: 300);
    log({
      'phase': 'pinch_pan',
      'zoom_before': z1.toStringAsFixed(3),
      'origin_moved_by_zoom': (oMid - o0).dx.toStringAsFixed(1),
      'origin_moved_by_pan': (controller.origin - oMid).dx.toStringAsFixed(1),
      ..._view(),
    });
    // Frames while zoomed in: xterm scrolling for 3 s.
    await _imeTypeSilently(keyboard, "timeout 3 sh -c 'while :; do date +%s.%N; done'");
    await measure('xterm_scroll_zoomed', 3200);
    await _checkpoint('zoomed');
    controller.resetZoom();
    await _pause(500);

    // Mouse pointer mode: a finger moves the pointer like a trackpad (by its own distance on the
    // screen), a tap clicks where the pointer is.
    controller.touchMode = TouchMode.pointer;
    await _pause(300);
    final p0 = controller.pointerPosition;
    final start = _global(inside.$1, inside.$2);
    await _drag(start, start + const Offset(100, 50));
    final p1 = controller.pointerPosition;
    log({
      'phase': 'pointer_move',
      'from': [p0.$1, p0.$2],
      'to': [p1.$1, p1.$2],
      'expected_delta': [(100 / controller.scale).toStringAsFixed(1), (50 / controller.scale).toStringAsFixed(1)],
    });
    // The pointer onto ZSWORD (`clear; echo ZSWORD` prints it on row 0), then a
    // double tap anywhere: a double click at the pointer.
    await _imeTypeSilently(keyboard, 'clear; echo ZSWORD');
    await _pause(800);
    final target = cell(2, 0);
    final now = controller.pointerPosition;
    final delta = Offset((target.$1 - now.$1).toDouble(), (target.$2 - now.$2).toDouble()) * controller.scale;
    final far = _global(inside.$1, inside.$2 + 60);
    await _drag(far, far + delta, steps: 10, ms: 200);
    log({'phase': 'pointer_to_word', 'pointer': [controller.pointerPosition.$1, controller.pointerPosition.$2], 'target': [target.$1, target.$2]});
    await _tap(inside.$1 + 100, inside.$2 + 100);
    await _pause(60);
    await _tap(inside.$1 + 100, inside.$2 + 100);
    await _checkpoint('pointer_double_tap_select');

    // Hold, then drag: a left drag from the pointer (in ZSWORD) to row 1, column 12, which selects
    // "WORD", the line break and the start of the prompt.
    await _drag(far, far + const Offset(60, 13) * controller.scale, steps: 10, ms: 300, holdMs: 650);
    await _checkpoint('pointer_hold_drag_select');

    controller.touchMode = TouchMode.touch;
    controller.resetZoom();
    await _pause(300);
    SchedulerBindingTimings.remove(_timings);
    controller.onlyDevice = null;
    log({'event': 'TOUCHTEST_DONE', 'touch_log': [for (final e in controller.touchLog) e.$1]});
  }

  /// Types a command through the soft keyboard (shown for it) and presses Enter.
  Future<void> _imeTypeSilently(SoftKeyboard kb, String command) async {
    kb.show();
    await _pause(600);
    await _imeType(kb, command);
    kb.performAction(TextInputAction.newline);
    await _pause(200);
    kb.hide();
    await _pause(800);
  }
}

/// Collects the engine's frame timings (raster time) into whichever list is listening.
class SchedulerBindingTimings {
  static final _lists = <List<ui.FrameTiming>>{};
  static bool _hooked = false;

  static void add(List<ui.FrameTiming> list) {
    _lists.add(list);
    if (!_hooked) {
      _hooked = true;
      WidgetsBinding.instance.addTimingsCallback((t) {
        for (final l in _lists) {
          l.addAll(t);
        }
      });
    }
  }

  static void remove(List<ui.FrameTiming> list) => _lists.remove(list);
}

/// The X runs (X11 forwarding into the local X server's view, and the X program in a VNC tab):
/// an xterm the test started reads one line and writes it to a file on the host. The pointer goes
/// over it (no window manager: focus follows the pointer), keys measure input to painted pixels
/// through the whole path, then the line is typed and a PNG saved. ZS_XTERM_ORIGIN: "x,y" inside
/// the xterm (60,60 by default); ZS_X_TYPE: the line (zs-x-typed-OK).
extension XSelfTest on SelfTest {
  Future<void> runX(String? shotPath) async {
    SchedulerBindingTimings.add(_timings);
    controller.onlyDevice = SelfTest._device;
    await _pause(1500);
    final (x, y) = RdpSelfTest._point(env['ZS_XTERM_ORIGIN'], (60, 60));
    hover(x, y);
    await _pause(300);
    await measure('idle', 1000);
    await inputLatency('input_xterm_key', 10, (i) => type('x'));
    for (var i = 0; i < 10; i++) {
      await press(LogicalKeyboardKey.backspace, PhysicalKeyboardKey.backspace);
    }
    await _pause(300);
    await type(env['ZS_X_TYPE'] ?? 'zs-x-typed-OK');
    await _pause(400);
    await _shot(shotPath);
    await enter();
    await _pause(800);
    SchedulerBindingTimings.remove(_timings);
    controller.onlyDevice = null;
    log({'event': 'SELFTEST_DONE'});
  }
}
