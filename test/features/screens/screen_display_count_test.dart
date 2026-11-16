// Remote screens (4.0): how many displays an RDP host asks its remote
// for, as its options keep it, and the displays a view's size becomes.
import 'dart:convert';
import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart' show ScreenDisplaySpec;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';

void main() {
  group("ScreenOptions, an RDP host's displays", () {
    test('one, and not written while it is one: a host from before reads and writes as it did', () {
      const o = ScreenOptions();
      expect(o.displays, 1);
      expect(o.toJson().containsKey('displays'), isFalse);
      expect(ScreenOptions.decode(o.encode()).displays, 1);
      expect(ScreenOptions.decode(const ScreenOptions().encode()).encode(), const ScreenOptions().encode());
    });

    test('two to four round trip; anything else is one', () {
      for (final n in [2, 3, 4]) {
        final o = const ScreenOptions().copyWith(displays: n);
        expect(o.toJson()['displays'], n);
        expect(ScreenOptions.decode(o.encode()).displays, n);
      }
      for (final bad in <Object?>[0, -1, 5, 99, '2', 2.0, true, null, [2]]) {
        final json = {...const ScreenOptions().toJson(), 'displays': bad};
        expect(ScreenOptions.decode(jsonEncode(json)).displays, 1, reason: '$bad');
      }
      // A number out of range set in code is not written either.
      expect(const ScreenOptions(displays: 9).toJson().containsKey('displays'), isFalse);
    });

    test('it is a key this version knows: not kept among the unknown ones', () {
      final read = ScreenOptions.decode(jsonEncode({...const ScreenOptions().toJson(), 'displays': 3, 'later': 'x'}));
      expect(read.displays, 3);
      expect(read.unknown, {'later': 'x'});
    });

    test('one to four on a phone as on a computer; a phone has a ceiling of pixels for the whole desktop', () {
      expect(const ScreenOptions(displays: 4).displayCount, 4);
      expect(const ScreenOptions(displays: 3).displayCount, 3);
      expect(const ScreenOptions().displayCount, 1);
      expect(const ScreenOptions(displays: 0).displayCount, 1);
      expect(const ScreenOptions(displays: 12).displayCount, 4);
      expect(ScreenOptions.maxDisplays, 4);
      // A phone's ceiling is in pixels, not in displays: one 4K picture for the whole desktop.
      expect(ScreenOptions.maxDesktopPixelsOn(phone: true), 3840 * 2160);
      expect(ScreenOptions.maxDesktopPixelsOn(phone: false), isNull);
      // Four displays the size of a phone or tablet's own view fit under it, the largest tablet's too.
      for (final view in const [Size(800, 360), Size(1024, 768), Size(1366, 1024)]) {
        expect(ScreenViewSize.displaysOf(4, view, maxDesktopPixels: ScreenOptions.maxDesktopPixelsOnPhone),
            hasLength(4), reason: '$view');
      }
      // Displays that would pass it: as many as fit, one at least, each still the size asked for.
      final large = ScreenViewSize.displaysOf(4, const Size(1920, 1080),
          maxDesktopPixels: ScreenOptions.maxDesktopPixelsOnPhone);
      expect(large, hasLength(4), reason: 'four of 1920 by 1080 are exactly one 4K picture');
      final larger = ScreenViewSize.displaysOf(4, const Size(2560, 1440),
          maxDesktopPixels: ScreenOptions.maxDesktopPixelsOnPhone);
      expect(larger, hasLength(2));
      expect((larger.first.width, larger.first.height, larger.last.x), (2560, 1440, 2560));
      expect(ScreenViewSize.displaysOf(4, const Size(3840, 2160), maxDesktopPixels: 1000), hasLength(1));
      // A computer has no such ceiling.
      expect(ScreenViewSize.displaysOf(4, const Size(2560, 1440)), hasLength(4));
    });
  });

  group("ScreenOptions, an RDP host's relative mouse", () {
    test('off, and not written while it is off; on round trips; anything else is off', () {
      const o = ScreenOptions();
      expect(o.relativeMouse, isFalse);
      expect(o.toJson().containsKey('relative_mouse'), isFalse);
      final on = o.copyWith(relativeMouse: true);
      expect(on.toJson()['relative_mouse'], isTrue);
      expect(ScreenOptions.decode(on.encode()).relativeMouse, isTrue);
      expect(ScreenOptions.decode(on.encode()).unknown, isEmpty);
      for (final bad in <Object?>['true', 1, 'on', null]) {
        final json = {...const ScreenOptions().toJson(), 'relative_mouse': bad};
        expect(ScreenOptions.decode(jsonEncode(json)).relativeMouse, isFalse, reason: '$bad');
      }
    });
  });

  group("ScreenOptions, an RDP host's text size on the remote", () {
    test('nothing said, and not written then; a size Windows offers round trips; anything else says nothing', () {
      const o = ScreenOptions();
      expect(o.textScale, 0);
      expect(o.toJson().containsKey('text_scale'), isFalse);
      expect(ScreenOptions.textScales, [0, 100, 125, 150, 200]);
      for (final n in [100, 125, 150, 200]) {
        final with_ = o.copyWith(textScale: n);
        expect(with_.toJson()['text_scale'], n);
        expect(ScreenOptions.decode(with_.encode()).textScale, n);
        expect(ScreenOptions.decode(with_.encode()).unknown, isEmpty);
      }
      for (final bad in <Object?>[99, 110, 175, 250, 500, -150, '150', 150.0, true, null]) {
        final json = {...const ScreenOptions().toJson(), 'text_scale': bad};
        expect(ScreenOptions.decode(jsonEncode(json)).textScale, 0, reason: '$bad');
      }
      // A size that is not one of them is never written, however it got there.
      expect(const ScreenOptions(textScale: 137).toJson().containsKey('text_scale'), isFalse);
      // Back to nothing said.
      expect(o.copyWith(textScale: 150).copyWith(textScale: 0).toJson().containsKey('text_scale'), isFalse);
    });
  });

  group("ScreenOptions, a screen host's frame rate limit", () {
    test('none, and not written then; 60, 30 and 15 round trip; anything else is none', () {
      const o = ScreenOptions();
      expect(o.frameLimit, 0);
      expect(o.toJson().containsKey('frame_limit'), isFalse);
      expect(ScreenOptions.frameLimits, [0, 60, 30, 15]);
      for (final n in [60, 30, 15]) {
        final with_ = o.copyWith(frameLimit: n);
        expect(with_.toJson()['frame_limit'], n);
        expect(ScreenOptions.decode(with_.encode()).frameLimit, n);
        expect(ScreenOptions.decode(with_.encode()).unknown, isEmpty);
      }
      for (final bad in <Object?>[1, 24, 120, -30, '30', 30.0, true, null]) {
        final json = {...const ScreenOptions().toJson(), 'frame_limit': bad};
        expect(ScreenOptions.decode(jsonEncode(json)).frameLimit, 0, reason: '$bad');
      }
      expect(const ScreenOptions(frameLimit: 24).toJson().containsKey('frame_limit'), isFalse);
    });
  });

  group("a view's size as displays", () {
    test('each display is the view, side by side from the left, the first the primary one', () {
      expect(ScreenViewSize.displaysOf(3, const Size(1281.5, 800.9)), const [
        ScreenDisplaySpec(width: 1280, height: 800, primary: true),
        ScreenDisplaySpec(x: 1280, width: 1280, height: 800),
        ScreenDisplaySpec(x: 2560, width: 1280, height: 800),
      ]);
      expect(ScreenViewSize.displaysOf(1, const Size(400, 300)), const [ScreenDisplaySpec(width: 400, height: 300, primary: true)]);
      // A text size is each display's.
      expect(ScreenViewSize.displaysOf(2, const Size(1280, 800), scale: 150), const [
        ScreenDisplaySpec(width: 1280, height: 800, scale: 150, primary: true),
        ScreenDisplaySpec(x: 1280, width: 1280, height: 800, scale: 150),
      ]);
    });

    test('every size is one the engine takes as it is: even, 200 to 8192 a side, within one display of pixels', () {
      for (final view in const [
        Size(1, 1),
        Size(199, 5000),
        Size(1921, 1081),
        Size(3840, 2160),
        Size(5120, 2880),
        Size(9000, 300),
        Size(300, 9000),
        Size(20000, 20000),
      ]) {
        final displays = ScreenViewSize.displaysOf(4, view);
        final (w, h) = (displays.first.width, displays.first.height);
        expect(w.isEven, isTrue, reason: '$view');
        expect(w >= 200 && w <= ScreenViewSize.maxSide, isTrue, reason: '$view gives $w');
        expect(h >= 200 && h <= ScreenViewSize.maxSide, isTrue, reason: '$view gives $h');
        expect(w * h <= ScreenViewSize.maxPixels, isTrue, reason: '$view gives $w x $h');
        // They touch and none is over another.
        expect([for (final d in displays) d.x], [0, w, 2 * w, 3 * w]);
        expect(displays.every((d) => d.width == w && d.height == h && d.y == 0), isTrue);
        expect(displays.where((d) => d.primary), hasLength(1));
      }
      // A size the engine takes is kept as it is.
      expect(ScreenViewSize.displaysOf(2, const Size(3840, 2160)).first.width, 3840);
      // The start size is one of them.
      final start = ScreenViewSize.displaysOf(2, ScreenViewSize.startSize);
      expect((start[1].x, start[1].width, start[1].height), (1280, 1280, 800));
    });
  });
}
