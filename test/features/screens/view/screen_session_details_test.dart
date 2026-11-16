// Remote screens (4.0): the numbers behind Session details. The
// controller samples them once a second while the details are shown, and
// only then.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_controller.dart';

import 'screen_view_fixture.dart';

Future<(ScreenSession, FakeScreenSession, ScreenController)> _connect(WidgetTester tester, {bool rdp = true}) async {
  final native = FakeScreenNative();
  final session = ScreenSession.open(rdp ? const ScreenConnectOptions.rdp() : const ScreenConnectOptions.vnc(), native: native);
  final engine = native.sessions.single;
  if (rdp) {
    engine.emitJson(ScreenEventKind.connected, {'protocol': 'rdp', 'width': 3200, 'height': 1080});
  } else {
    engine.connect(width: 1280, height: 800);
  }
  await tester.pump();
  final controller = ScreenController(session, decodeTile: syncDecode);
  addTearDown(() {
    controller.dispose();
    session.close();
  });
  await tester.pump();
  return (session, engine, controller);
}

void main() {
  group('what the picture is drawn with', () {
    test('the codec of the graphics pipeline that decoded the most pixels', () {
      expect(
        ScreenSessionDetails.drawnWithFrom({
          'gfx_codecs': {
            'planar': {'count': 400, 'pixels': 1000, 'bytes': 0},
            'avc420': {'count': 3, 'pixels': 900000, 'bytes': 5000},
            'alpha': {'count': 9, 'pixels': 99999999, 'bytes': 1},
          },
          'fastpath': {
            'pointer': {'count': 2, 'bytes': 6000, 'pixels': 0},
          },
        }),
        'H.264 (AVC420)',
      );
      for (final (key, name) in const [
        ('avc444', 'H.264 (AVC444)'),
        ('progressive', 'RemoteFX Progressive'),
        ('cavideo', 'RemoteFX'),
        ('planar', 'Planar'),
        ('clearcodec', 'ClearCodec'),
        ('uncompressed', 'Uncompressed'),
      ]) {
        expect(
          ScreenSessionDetails.drawnWithFrom({
            'gfx_codecs': {
              key: {'pixels': 10},
            },
          }),
          name,
        );
      }
    });

    test('without the pipeline, the kind of update that carried the most bytes', () {
      expect(
        ScreenSessionDetails.drawnWithFrom({
          'gfx_codecs': <String, Object?>{},
          'fastpath': {
            'surface/remotefx': {'count': 30, 'bytes': 90000, 'pixels': 0},
            'bitmap/rle': {'count': 2, 'bytes': 300, 'pixels': 0},
            'pointer': {'count': 2, 'bytes': 999999, 'pixels': 0},
          },
        }),
        'RemoteFX',
      );
      expect(
        ScreenSessionDetails.drawnWithFrom({
          'fastpath': {
            'bitmap/planar': {'bytes': 10},
            'bitmap/raw': {'bytes': 5},
          },
        }),
        'Bitmap',
      );
    });

    test('nothing where the report names nothing, or is not a report', () {
      for (final report in <Object?>[
        null,
        'gfx',
        const <String, Object?>{},
        {'gfx_codecs': 'none', 'fastpath': 7},
        {
          'gfx_codecs': {
            'planar': {'pixels': 0},
            'new-codec': {'pixels': 500},
            'avc420': 'broken',
          },
        },
        {
          'fastpath': {
            'pointer': {'bytes': 500},
            'orders': {'bytes': 100},
          },
        },
      ]) {
        expect(ScreenSessionDetails.drawnWithFrom(report), '', reason: '$report');
      }
    });
  });

  group('sampling', () {
    testWidgets('nothing is sampled until the details are shown, and nothing after they are closed', (tester) async {
      final (session, engine, c) = await _connect(tester);
      expect(c.detailsShown, isFalse);
      session.feed(Uint8List(500));
      await tester.pump(const Duration(seconds: 3));
      expect(c.details.value, same(ScreenSessionDetails.none));

      c.detailsShown = true;
      expect(c.detailsShown, isTrue);
      // At once: what is known without waiting, and no second yet.
      expect(c.details.value.last, isEmpty);
      expect((c.details.value.protocol, c.details.value.width, c.details.value.height), ('RDP', 3200, 1080));
      await tester.pump(const Duration(seconds: 2));
      expect(c.details.value.last, hasLength(2));

      c.detailsShown = false;
      final kept = c.details.value;
      session.feed(Uint8List(500));
      await tester.pump(const Duration(seconds: 5));
      expect(c.details.value, same(kept), reason: 'not sampled while closed');
      expect(engine.closed, isFalse);
    });

    testWidgets('each second holds the bytes that came and went and the frames drawn in it', (tester) async {
      final (session, engine, c) = await _connect(tester);
      // What came before the details were opened is not theirs.
      session.feed(Uint8List(4096));
      c.detailsShown = true;

      session.feed(Uint8List(1000));
      session.feed(Uint8List(234));
      await tester.pump(const Duration(seconds: 1));
      var last = c.details.value.last.single;
      expect((last.bytesIn, last.bytesOut, last.frames), (1234, 0, 0));
      expect(last.at.inSeconds, 1);

      // A second in which nothing came: zeros, not the second before again.
      await tester.pump(const Duration(seconds: 1));
      last = c.details.value.last.last;
      expect((last.bytesIn, last.bytesOut, last.frames), (0, 0, 0));
      expect(c.details.value.last, hasLength(2));
      expect(c.details.value.last.first.bytesIn, 1234, reason: 'oldest first');
      expect(engine.closed, isFalse);
    });

    testWidgets('the last minute is kept, oldest first', (tester) async {
      final (_, _, c) = await _connect(tester);
      c.detailsShown = true;
      await tester.pump(const Duration(seconds: 75));
      final last = c.details.value.last;
      expect(last, hasLength(ScreenSessionDetails.keep));
      expect(last.first.at.inSeconds, 16);
      expect(last.last.at.inSeconds, 75);
      // Shown again: a new minute.
      c.detailsShown = false;
      c.detailsShown = true;
      expect(c.details.value.last, isEmpty);
    });

    testWidgets('what the server draws with comes from its last report, and a VNC session names none', (tester) async {
      final (_, engine, c) = await _connect(tester);
      c.detailsShown = true;
      expect(c.details.value.drawnWith, '');
      engine.emitJson(ScreenEventKind.info, {
        'graphics': {
          'gfx_codecs': {
            'progressive': {'count': 12, 'pixels': 2073600, 'bytes': 0},
          },
        },
        'at_us': 1,
      });
      await tester.pump(const Duration(seconds: 1));
      expect(c.details.value.drawnWith, 'RemoteFX Progressive');
      expect(c.details.value.roundTripMs, isNull, reason: 'not measured yet');

      final (_, _, vnc) = await _connect(tester, rdp: false);
      vnc.detailsShown = true;
      await tester.pump(const Duration(seconds: 1));
      expect((vnc.details.value.protocol, vnc.details.value.drawnWith), ('VNC', ''));
      expect((vnc.details.value.width, vnc.details.value.height), (1280, 800));
    });

    testWidgets('the desktop is all of it while one display is shown', (tester) async {
      final (_, engine, c) = await _connect(tester);
      engine.displays(const [
        [0, 0, 1920, 1080],
        [1920, 0, 1280, 1024],
      ]);
      await tester.pump();
      c.showDisplay(1);
      c.detailsShown = true;
      await tester.pump(const Duration(seconds: 1));
      expect((c.details.value.width, c.details.value.height), (3200, 1080));
    });

    testWidgets('the round trip: asked when the details open and every five seconds while they are shown, one question '
        'at a time; no answer in time takes the row away', (tester) async {
      final (_, _, c) = await _connect(tester, rdp: false);
      final asked = <Completer<int?>>[];
      c.measureRoundTrip = () {
        asked.add(Completer<int?>());
        return asked.last.future;
      };
      // Nothing is asked while the details are closed.
      await tester.pump(const Duration(seconds: 12));
      expect(asked, isEmpty);

      c.detailsShown = true;
      expect(asked, hasLength(1), reason: 'asked at once');
      expect(c.details.value.roundTripMs, isNull, reason: 'no answer yet');
      asked.last.complete(24);
      await tester.pump();
      expect(c.details.value.roundTripMs, 24);

      // Seconds 1 to 4: not asked again; the fifth: asked.
      await tester.pump(const Duration(seconds: 4));
      expect(asked, hasLength(1));
      expect(c.details.value.roundTripMs, 24, reason: 'kept between questions');
      await tester.pump(const Duration(seconds: 1));
      expect(asked, hasLength(2));
      // An answer that takes its time is not asked for twice at once.
      await tester.pump(const Duration(seconds: 10));
      expect(asked, hasLength(2));
      expect(c.details.value.roundTripMs, 24);
      asked.last.complete(310);
      await tester.pump();
      expect(c.details.value.roundTripMs, 310);
      expect(c.details.value.last, hasLength(15), reason: 'the samples are kept as an answer comes');

      // No answer in time (null), a failure, a number that is none: the row goes.
      await tester.pump(const Duration(seconds: 5));
      expect(asked, hasLength(3));
      asked.last.complete(null);
      await tester.pump();
      expect(c.details.value.roundTripMs, isNull);
      await tester.pump(const Duration(seconds: 5));
      asked.last.complete(41);
      await tester.pump();
      expect(c.details.value.roundTripMs, 41);
      await tester.pump(const Duration(seconds: 5));
      asked.last.completeError(StateError('the connection went'));
      await tester.pump();
      expect(c.details.value.roundTripMs, isNull);
      await tester.pump(const Duration(seconds: 5));
      asked.last.complete(-3);
      await tester.pump();
      expect(c.details.value.roundTripMs, isNull);
    });

    testWidgets('the round trip: an answer for details that were closed, or opened anew, since it was asked is not '
        'taken; a screen nothing can measure has no such number', (tester) async {
      final (_, _, c) = await _connect(tester);
      final asked = <Completer<int?>>[];
      c.measureRoundTrip = () {
        asked.add(Completer<int?>());
        return asked.last.future;
      };
      c.detailsShown = true;
      c.detailsShown = false;
      final closed = c.details.value;
      asked.single.complete(99);
      await tester.pump();
      expect(c.details.value, same(closed), reason: 'closed: nothing changes');

      // Opened, closed and opened again while one question is out: its answer
      // belongs to neither, and the new details ask their own when it is back.
      c.detailsShown = true;
      expect(asked, hasLength(2));
      c.detailsShown = false;
      c.detailsShown = true;
      expect(asked, hasLength(2), reason: 'one question at a time');
      asked.last.complete(77);
      await tester.pump();
      expect(c.details.value.roundTripMs, isNull);
      await tester.pump(const Duration(seconds: 5));
      expect(asked, hasLength(3));
      asked.last.complete(12);
      await tester.pump();
      expect(c.details.value.roundTripMs, 12);
      // Opened anew: the old number is not shown as the new one.
      c.detailsShown = false;
      c.detailsShown = true;
      expect(c.details.value.roundTripMs, isNull);
      c.detailsShown = false;

      // Nothing to measure with: never a number, and nothing breaks.
      c.measureRoundTrip = null;
      c.detailsShown = true;
      await tester.pump(const Duration(seconds: 11));
      expect(c.details.value.roundTripMs, isNull);
      expect(c.details.value.last, hasLength(11));
    });

    testWidgets('a controller that goes stops sampling', (tester) async {
      final native = FakeScreenNative();
      final session = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      native.sessions.single.connect();
      await tester.pump();
      final c = ScreenController(session, decodeTile: syncDecode);
      await tester.pump();
      c.detailsShown = true;
      c.dispose();
      await tester.pump(const Duration(seconds: 3));
      expect(tester.takeException(), isNull);
      session.close();
    });
  });

  test('the data: a sample and the details say what they hold', () {
    const s = ScreenSessionSample(at: Duration(seconds: 3), bytesIn: 10, bytesOut: 2, frames: 1);
    expect(s, const ScreenSessionSample(at: Duration(seconds: 3), bytesIn: 10, bytesOut: 2, frames: 1));
    expect(s.toString(), 'ScreenSessionSample(3s: 10 in, 2 out, 1 frames)');
    expect(ScreenSessionDetails.none.last, isEmpty);
    expect(ScreenSessionDetails.none.toString(), 'ScreenSessionDetails( 0x0, unknown, 0 samples)');
    expect(ScreenSessionDetails.keep, 60);
  });
}
