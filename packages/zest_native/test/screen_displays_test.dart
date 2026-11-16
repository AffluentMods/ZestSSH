// The remote's displays and the views on a session's picture (4.0), on the Dart side
// over a fake engine: what the start request says, what a layout asked for while connected
// carries, the displays the engine tells, and a view's life.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';

Future<void> settle([int turns = 5]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

ScreenFrame frame(int seq, int width, int height) => ScreenFrame(
  seq: seq,
  width: width,
  height: height,
  updates: 1,
  tiles: [ScreenTile(0, 0, width, height, Uint8List(width * height * 4))],
);

void main() {
  const two = [
    ScreenDisplaySpec(width: 1920, height: 1080, primary: true),
    ScreenDisplaySpec(x: 1920, width: 1280, height: 1024, scale: 150),
  ];

  group('the request', () {
    test('several displays go as a list, each with its place; a scale and primary only where said', () {
      const o = ScreenConnectOptions.rdp(username: 'alex', serverName: 'pc.example.test', displays: two);
      expect(o.toRequest()['displays'], [
        {'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'primary': true},
        {'x': 1920, 'y': 0, 'width': 1280, 'height': 1024, 'scale': 150},
      ]);
      // What the engine reads back is the same list.
      expect(jsonDecode(jsonEncode(o.toRequest()))['displays'], hasLength(2));
    });

    test('without displays the request is the one a session sent before, and a scale is said only when there is one', () {
      const plain = ScreenConnectOptions.rdp(width: 1280, height: 800);
      expect(plain.toRequest().containsKey('displays'), isFalse);
      expect(plain.toRequest().containsKey('scale'), isFalse);
      expect(const ScreenConnectOptions.rdp(displays: []).toRequest().containsKey('displays'), isFalse);
      expect(const ScreenConnectOptions.rdp(scale: 0).toRequest().containsKey('scale'), isFalse);
      expect(const ScreenConnectOptions.rdp(scale: 150).toRequest()['scale'], 150);
      expect(const ScreenConnectOptions.vnc().toRequest().containsKey('displays'), isFalse);
    });

    test('a new certificate pin keeps the displays, the scale and relative mouse', () {
      const o = ScreenConnectOptions.rdp(displays: two, scale: 125, relativeMouse: true);
      final pinned = o.copyWith(tlsPin: 'ab' * 32);
      expect(pinned.displays, two);
      expect(pinned.scale, 125);
      expect(pinned.rdpRelativeMouse, isTrue);
    });

    test('relative mouse is asked for only where a host says so', () {
      expect(const ScreenConnectOptions.rdp().toRequest().containsKey('rdp_relative_mouse'), isFalse);
      expect(const ScreenConnectOptions.rdp(relativeMouse: true).toRequest()['rdp_relative_mouse'], isTrue);
      expect(const ScreenConnectOptions.vnc().toRequest().containsKey('rdp_relative_mouse'), isFalse);
    });

    test('a display is equal to one with the same numbers, and says them', () {
      expect(two[1], const ScreenDisplaySpec(x: 1920, width: 1280, height: 1024, scale: 150));
      expect(two[1] == two[0], isFalse);
      expect(two[1].toString(), 'ScreenDisplaySpec(1280x1024 at 1920,0 150%)');
      expect(two[0].toString(), 'ScreenDisplaySpec(1920x1080 at 0,0 primary)');
    });
  });

  group('a list of displays from anywhere', () {
    test('a number above what a picture can have, below zero, or no whole number makes no display', () {
      expect(ScreenDisplayRect.listFrom([
        [0, 0, 1920, 1080],
        [1920, 0, 1280, 1024],
      ]), const [ScreenDisplayRect(0, 0, 1920, 1080), ScreenDisplayRect(1920, 0, 1280, 1024)]);
      const big = 0x4000000000000000;
      for (final bad in <Object?>[
        [big, 0, big, 10], // a place and a side whose sum passes what a whole number holds
        [0, 0, 65536, 10],
        [0, 65536, 10, 10],
        [0, 0, 10, 0],
        [0, 0, 0, 10],
        [-1, 0, 10, 10],
        [0, 0, 10],
        [0, 0, 10, 10, 10],
        [0, 0, 10.5, 10],
        ['0', 0, 10, 10],
        'no list',
        null,
        {'x': 0},
      ]) {
        expect(ScreenDisplayRect.listFrom([bad]), isEmpty, reason: '$bad');
      }
      expect(ScreenDisplayRect.listFrom('no list'), isEmpty);
      expect(ScreenDisplayRect.listFrom(null), isEmpty);
      // The largest a picture can have is taken.
      expect(ScreenDisplayRect.listFrom([
        [65535, 65535, 65535, 65535],
      ]), hasLength(1));
    });

    test('a list without end is read as far as any session has displays, and no further', () {
      final many = List.generate(100000, (i) => [i % 1000, 0, 10, 10]);
      final watch = Stopwatch()..start();
      final read = ScreenDisplayRect.listFrom(many);
      expect(read, hasLength(ScreenDisplayRect.mostRead));
      expect(watch.elapsedMilliseconds, lessThan(200));
      // What is no display among the first is left out, and the rest is still not looked at.
      expect(ScreenDisplayRect.listFrom([for (var i = 0; i < 40; i++) i.isEven ? 'x' : [0, 0, 10, 10]]), hasLength(8));
    });
  });

  group('a connected session', () {
    late FakeScreenNative native;
    late ScreenSession s;
    late FakeScreenSession f;
    late List<ScreenEvent> events;

    setUp(() async {
      native = FakeScreenNative();
      s = ScreenSession.open(const ScreenConnectOptions.rdp(displays: two), native: native);
      events = [];
      s.events.listen(events.add);
      f = native.sessions.single
        ..emitJson(ScreenEventKind.connected, {
          'protocol': 'rdp',
          'width': 3200,
          'height': 1080,
          'displays': [
            [0, 0, 1920, 1080],
            [1920, 0, 1280, 1024],
          ],
        });
      await s.connected;
    });

    tearDown(() => s.close());

    test('the displays the engine tells at connect are rectangles of the picture', () async {
      final connected = await s.connected;
      expect(connected.displays, const [ScreenDisplayRect(0, 0, 1920, 1080), ScreenDisplayRect(1920, 0, 1280, 1024)]);
      expect(connected.displays[1].toString(), 'ScreenDisplayRect(1280x1024 at 1920,0)');
    });

    test('a VNC session is told no displays', () async {
      final vnc = ScreenSession.open(const ScreenConnectOptions.vnc(), native: native);
      native.sessions.last.connect();
      expect((await vnc.connected).displays, isEmpty);
      vnc.close();
    });

    test('a layout asked for while connected goes to the engine as the list it reads', () {
      expect(s.setDisplays(const [ScreenDisplaySpec(width: 2560, height: 1440)]), isTrue);
      expect(s.setDisplays(two), isTrue);
      expect(f.layouts, [
        [
          {'x': 0, 'y': 0, 'width': 2560, 'height': 1440},
        ],
        [
          {'x': 0, 'y': 0, 'width': 1920, 'height': 1080, 'primary': true},
          {'x': 1920, 'y': 0, 'width': 1280, 'height': 1024, 'scale': 150},
        ],
      ]);
      // No displays is not a layout.
      expect(s.setDisplays(const []), isFalse);
      expect(f.layouts, hasLength(2));
    });

    test('a change of the displays comes after the change of size, and nothing else is taken as displays', () async {
      f
        ..emit(ScreenEventKind.resize, a: (1920 << 32) | 1080)
        ..displays([
          [0, 0, 1920, 1080],
        ]);
      await settle();
      expect(events.whereType<ScreenResized>().single.width, 1920);
      final changed = events.whereType<ScreenDisplaysChanged>().single;
      expect(changed.displays, const [ScreenDisplayRect(0, 0, 1920, 1080)]);
      expect(events.indexOf(changed), greaterThan(events.indexWhere((e) => e is ScreenResized)));

      // Not rectangles: left out one by one; with none left there is no event.
      events.clear();
      f.emitJson(ScreenEventKind.displays, {
        'displays': [
          [0, 0, 800],
          [0, 0, -5, 600],
          [0, 0, 0, 600],
          'x',
          [10, 20, 800, 600],
        ],
      });
      f.emitJson(ScreenEventKind.displays, {'displays': 'none'});
      f.emitJson(ScreenEventKind.displays, {'other': 1});
      await settle();
      expect(events.whereType<ScreenDisplaysChanged>().single.displays, const [ScreenDisplayRect(10, 20, 800, 600)]);
    });

    test('the reader of the session is shown one display, and all of the picture again', () {
      s.showPart(1920, 0, 1280, 1024);
      s.showAll();
      expect(f.shown, [(1920, 0, 1280, 1024), (0, 0, 0, 0)]);
      // Not parts of a picture: nothing is asked.
      s.showPart(-1, 0, 10, 10);
      s.showPart(0, 0, 0, 10);
      s.showPart(0, 0, 10, -3);
      expect(f.shown, hasLength(2));
    });

    test('movement goes as movement, and the engine says whether the server takes it', () async {
      expect((await s.connected).relativeMouse, isFalse, reason: 'not said: not taken');
      s.pointerRelative(12, -7, 1);
      expect(f.relativePointers, [(12, -7, 1)]);
      expect(f.pointers, isEmpty);
      final other = ScreenSession.open(const ScreenConnectOptions.rdp(relativeMouse: true), native: native);
      native.sessions.last.emitJson(ScreenEventKind.connected, {'width': 800, 'height': 600, 'relative_mouse': true});
      expect((await other.connected).relativeMouse, isTrue);
      other.close();
    });

    test('a closed session asks for nothing', () async {
      s.close();
      await settle();
      s.pointerRelative(1, 1, 0);
      expect(f.relativePointers, isEmpty);
      expect(s.setDisplays(two), isFalse);
      expect(f.layouts, isEmpty);
      s.showPart(0, 0, 10, 10);
      s.showAll();
      expect(f.shown, isEmpty);
      expect(s.openView(x: 0, y: 0, width: 10, height: 10), isNull);
    });
  });

  group('a view', () {
    late FakeScreenNative native;
    late ScreenSession s;
    late FakeScreenSession f;

    setUp(() async {
      native = FakeScreenNative();
      s = ScreenSession.open(const ScreenConnectOptions.rdp(displays: two), native: native);
      f = native.sessions.single..connect(width: 3200, height: 1080);
      await s.connected;
    });

    tearDown(() => s.close());

    test('is opened on a rectangle of the picture and gives its own frames', () {
      final view = s.openView(x: 1920, y: 0, width: 1280, height: 1024)!;
      expect(view.id, 1);
      expect(view.sessionHandle, s.handle);
      expect(f.views[1], (x: 1920, y: 0, width: 1280, height: 1024, divide: 1));
      expect(view.alive, isTrue);
      expect(view.takeFrame(), isNull, reason: 'nothing changed in it');
      f.viewFrames[1] = [frame(7, 1280, 1024)];
      final got = view.takeFrame()!;
      expect((got.seq, got.width, got.height), (7, 1280, 1024));
      got.free();
      expect(view.takeFrame(), isNull);
      // The session's own reader is another reader.
      f.frames.add(frame(8, 3200, 1080));
      expect(s.takeFrame()!.width, 3200);
    });

    test('is opened by the session number alone, as a window of its own does', () {
      final view = ScreenViewReader.open(s.handle, x: 0, y: 0, width: 1920, height: 1080, divide: 8, native: native)!;
      expect(f.views[view.id]!.divide, 8);
      expect(view.alive, isTrue);
      view.close();
      expect(f.views, isEmpty);
      expect(view.isClosed, isTrue);
      expect(view.alive, isFalse);
      expect(view.takeFrame(), isNull);
      view.close();
    });

    test('is not opened for nothing: no session, no size, a place below zero, a divisor that is not 1 to 16', () {
      ScreenViewReader? open({int handle = -1, int x = 0, int y = 0, int width = 10, int height = 10, int divide = 1}) =>
          ScreenViewReader.open(handle == -1 ? s.handle : handle, x: x, y: y, width: width, height: height, divide: divide, native: native);
      expect(open(handle: 0), isNull);
      expect(open(handle: 999), isNull);
      expect(open(width: 0), isNull);
      expect(open(height: -1), isNull);
      expect(open(x: -1), isNull);
      expect(open(y: -1), isNull);
      expect(open(divide: 0), isNull);
      expect(open(divide: 17), isNull);
      expect(f.views, isEmpty);
      expect(open(divide: 16), isNotNull);
    });

    test('sixteen at most, and a closed one makes room', () {
      final views = [for (var i = 0; i < 16; i++) s.openView(x: 0, y: 0, width: 10, height: 10)!];
      expect(s.openView(x: 0, y: 0, width: 10, height: 10), isNull);
      views.first.close();
      expect(s.openView(x: 0, y: 0, width: 10, height: 10), isNotNull);
    });

    test('ends with its session: not alive, nothing to take, and closing it is harmless', () async {
      final view = s.openView(x: 0, y: 0, width: 1920, height: 1080)!;
      f.viewFrames[view.id] = [frame(1, 1920, 1080)];
      s.close();
      await settle();
      expect(view.alive, isFalse);
      expect(view.takeFrame(), isNull);
      view.close();
      // And none is opened on a session that has ended.
      expect(ScreenViewReader.open(s.handle, x: 0, y: 0, width: 10, height: 10, native: native), isNull);
    });
  });
}
