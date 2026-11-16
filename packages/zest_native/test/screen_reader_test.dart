// A screen shown in a window of its own (4.0): that window is another engine of the
// process, which does not own the session. It reads the picture through a view and drives the
// session by its number (ScreenSession.reader). Over a fake engine: what the reader finds by
// looking, what it sends, what it leaves to the owner, and that it never ends the session.
import 'dart:async';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';

const every = Duration(milliseconds: 2);

Future<void> looks([int n = 6]) => Future<void>.delayed(every * n);

ScreenFrame frame(int seq, int width, int height, {void Function()? onFree}) => ScreenFrame(
  seq: seq,
  width: width,
  height: height,
  updates: 1,
  tiles: [ScreenTile(0, 0, width, height, Uint8List(width * height * 4))],
  onFree: onFree,
);

class Rig {
  Rig() {
    owner = ScreenSession.open(const ScreenConnectOptions.rdp(), native: native);
    engine = native.sessions.single;
    engine.connect(name: 'office-pc', width: 1280, height: 800);
  }

  final native = FakeScreenNative();
  late final ScreenSession owner;
  late final FakeScreenSession engine;

  ScreenSession reader() => ScreenSession.reader(
    owner.handle,
    protocol: ScreenProtocol.rdp,
    info: const {'name': 'office-pc', 'width': 1280, 'height': 800, 'protocol': 'rdp', 'relative_mouse': true},
    native: native,
    every: every,
  );
}

void main() {
  test('a reader is connected at once with what its owner was told, and has a view on all of the picture', () async {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    expect(reader.isReader, isTrue);
    expect(r.owner.isReader, isFalse);
    expect(reader.state, ScreenSessionState.connected);
    final connected = await reader.connected;
    expect((connected.name, connected.width, connected.height, connected.relativeMouse), ('office-pc', 1280, 800, true));
    expect(reader.handle, r.owner.handle);
    expect(r.engine.views.values.single, (x: 0, y: 0, width: 1 << 16, height: 1 << 16, divide: 1));
    expect(r.native.sessions, hasLength(1), reason: 'no session of its own');
  });

  test('it finds new pixels by looking, says so once, and hands the frame over when asked', () async {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    final ready = <int>[];
    reader.events.listen((e) {
      if (e is ScreenFrameReady) ready.add(e.seq);
    });
    await looks();
    expect(ready, isEmpty, reason: 'nothing changed: nothing said');

    final view = r.engine.views.keys.single;
    r.engine.viewFrames[view] = [frame(7, 1280, 800), frame(8, 1280, 800)];
    await looks();
    expect(ready, [7], reason: 'a frame waits: the next is not taken until it is handed over');
    expect(r.engine.viewFrames[view], hasLength(1));
    expect(reader.takeFrame()?.seq, 7);
    await looks();
    expect(ready, [7, 8]);
    expect(reader.takeFrame()?.seq, 8);
    expect(reader.takeFrame(), isNull);
    // Never the session's own reader's frames.
    r.engine.frames.add(frame(99, 1280, 800));
    await looks();
    expect(reader.takeFrame(), isNull);
    expect(r.engine.frames, hasLength(1));
  });

  test('keys, the pointer, movement, a resize, a layout and a refresh go to the session', () {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    reader
      ..pointer(10, 20, 1)
      ..pointerRelative(3, -4, 0)
      ..key(0x61, down: true, scancode: 0x1e)
      ..resize(1600, 900)
      ..fullRefresh();
    expect(reader.setDisplays(const [ScreenDisplaySpec(width: 1600, height: 900, scale: 150, primary: true)]), isTrue);
    expect(r.engine.pointers, [(10, 20, 1)]);
    expect(r.engine.relativePointers, [(3, -4, 0)]);
    expect(r.engine.keys, [(0x61, 0x1e, true)]);
    expect(r.engine.resizes, [(1600, 900)]);
    expect(r.engine.fullRefreshes, 1);
    expect(r.engine.layouts.single.single['scale'], 150);
  });

  test('what belongs to the owner stays with the owner: the clipboard, whether the server sends, the channel', () {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    reader
      ..sendClipboard('secret text')
      ..shareClipboard(on: true)
      ..pause()
      ..resume()
      ..transportFailed('x');
    expect(reader.feed(Uint8List(4)), 0);
    expect(r.engine.clipboard, isEmpty);
    expect(r.engine.clipboardShares, isEmpty);
    expect((r.engine.pauses, r.engine.resumes), (0, 0));
    expect(r.engine.failed, isNull);
    expect(r.engine.fed.length, 0);
    expect(() => reader.attach(const Stream.empty(), StreamController<List<int>>().sink), throwsStateError);
  });

  test('paused, it does not look; resumed, it starts with all of its part again', () async {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    final ready = <int>[];
    reader.events.listen((e) {
      if (e is ScreenFrameReady) ready.add(e.seq);
    });
    reader.showPart(1280, 0, 1920, 1080);
    final part = r.engine.views.keys.single;
    reader.pause();
    r.engine.viewFrames[part] = [frame(3, 1920, 1080)];
    await looks();
    expect(ready, isEmpty);
    reader.resume();
    expect(r.engine.views.values.single, (x: 1280, y: 0, width: 1920, height: 1080, divide: 1),
        reason: 'a new view on the same part: the engine gives all of it first');
    expect(r.engine.views.keys.single, isNot(part));
  });

  test('one display of several: its own view moves there, and the reader of the session itself is left alone', () async {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    final whole = r.engine.views.keys.single;
    var freed = 0;
    r.engine.viewFrames[whole] = [frame(1, 3200, 1080, onFree: () => freed++)];
    await looks();
    reader.showPart(1920, 0, 1280, 1024);
    expect(freed, 1, reason: 'a frame of the old part that waited is freed, not shown');
    expect(r.engine.shown, isEmpty, reason: 'what the reader of the owner shows is for the owner to say');
    expect(r.engine.views.values.single, (x: 1920, y: 0, width: 1280, height: 1024, divide: 1));
    final part = r.engine.views.keys.single;
    r.engine.viewFrames[part] = [frame(2, 1280, 1024)];
    // Taken without waiting to be told, as after any change of part.
    expect(reader.takeFrame()?.seq, 2);
    reader.showAll();
    expect(r.engine.views.values.single, (x: 0, y: 0, width: 1 << 16, height: 1 << 16, divide: 1));
    expect(r.engine.shown, isEmpty);
  });

  test('what only the owner knows is handed in: the cursor, the displays, a new size; not frames or the clipboard',
      () async {
    final r = Rig();
    final reader = r.reader();
    addTearDown(reader.close);
    final got = <ScreenEvent>[];
    reader.events.listen(got.add);
    reader
      ..relayed(const ScreenResized(1600, 900))
      ..relayed(const ScreenDisplaysChanged([ScreenDisplayRect(0, 0, 1600, 900)]))
      ..relayed(const ScreenBell())
      ..relayed(const ScreenFrameReady(5))
      ..relayed(const ScreenClipboard('secret text'))
      ..relayed(const ScreenConnected({}));
    expect(got.map((e) => e.runtimeType).toList(), [ScreenResized, ScreenDisplaysChanged, ScreenBell]);
    // Not a reader: nothing is handed in.
    final owned = <ScreenEvent>[];
    r.owner.events.listen(owned.add);
    r.owner.relayed(const ScreenBell());
    expect(owned.whereType<ScreenBell>(), isEmpty);
  });

  test('closing a reader lets go of its view and leaves the session running', () async {
    final r = Rig();
    final reader = r.reader();
    final view = r.engine.views.keys.single;
    var freed = 0;
    r.engine.viewFrames[view] = [frame(1, 1280, 800, onFree: () => freed++)];
    await looks();
    final events = <ScreenEvent>[];
    reader.events.listen(events.add);
    reader.close();
    expect(reader.isClosed, isTrue);
    expect(events.single, isA<ScreenClosed>().having((c) => c.reason, 'reason', ScreenCloseReason.local));
    expect(r.engine.views, isEmpty);
    expect(freed, 1, reason: 'the frame that waited is freed');
    expect(r.engine.closed, isFalse, reason: 'only its owner ends the session');
    expect(r.owner.isClosed, isFalse);
    expect(reader.takeFrame(), isNull);
    // Nothing more is sent by a closed reader, and it looks no more.
    reader.pointer(1, 1, 0);
    expect(r.engine.pointers, isEmpty);
    await looks();
  });

  test('the owner says why the session ended: the reader ends with that reason', () async {
    final r = Rig();
    final reader = r.reader();
    final events = <ScreenEvent>[];
    reader.events.listen(events.add);
    reader.relayed(const ScreenClosed(ScreenCloseReason.serverClosed, 'the server closed the connection'));
    expect(reader.isClosed, isTrue);
    expect(reader.closedWith?.reason, ScreenCloseReason.serverClosed);
    expect(events.single, isA<ScreenClosed>());
    expect(r.engine.views, isEmpty);
    expect(r.engine.closed, isFalse, reason: 'a reader never ends the session');
  });

  test('the session ends and nobody says so (its owner is gone too): the reader notices by itself', () async {
    final r = Rig();
    final reader = r.reader();
    final closed = Completer<ScreenClosed>();
    reader.events.listen((e) {
      if (e is ScreenClosed) closed.complete(e);
    });
    r.owner.close();
    final c = await closed.future.timeout(const Duration(seconds: 5));
    expect(c.reason, ScreenCloseReason.local);
    expect(reader.isClosed, isTrue);
  });

  test('a session that is gone already gives a reader that is closed', () async {
    final r = Rig();
    r.owner.close();
    final reader = r.reader();
    expect(reader.isClosed, isTrue);
    expect(reader.closedWith?.reason, ScreenCloseReason.local);
    expect(reader.takeFrame(), isNull);
    expect(await reader.connected, isA<ScreenConnected>());
    // No such session at all.
    final none = ScreenSession.reader(424242, protocol: ScreenProtocol.vnc, native: r.native, every: every);
    expect(none.isClosed, isTrue);
  });

  test('a seventeenth view is not to be had: the reader is closed, the sixteen stay', () {
    final r = Rig();
    for (var i = 0; i < 16; i++) {
      expect(r.owner.openView(x: 0, y: 0, width: 10, height: 10), isNotNull);
    }
    final reader = r.reader();
    expect(reader.isClosed, isTrue);
    expect(r.engine.views, hasLength(16));
  });
}
