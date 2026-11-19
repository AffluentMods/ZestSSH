// A screen in a window of its own (4.0): what the main window hands
// that window, as text. What it starts with, the session's events that are
// passed on and the ones that never are, and that anything malformed reads
// as nothing.
import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_native/screen.dart';
import 'package:zestssh/features/screens/window/screen_window_protocol.dart';

void main() {
  group('what the window starts with', () {
    final payload = ScreenWindowPayload(
      sessionId: 's1',
      handle: 0x7fffffffffffffff,
      protocol: ScreenProtocol.rdp,
      info: {
        'protocol': 'rdp',
        'width': 3200,
        'height': 1080,
        'displays': [
          [0, 0, 1920, 1080],
          [1920, 0, 1280, 1024],
        ],
      },
      menuKey: 'f9',
      viewOnly: true,
      fit: 'fill',
      followViewSize: true,
      textScale: 150,
      frameLimit: 30,
      displayCount: 2,
      smoothScaling: true,
      commandAsControl: true,
      panelFolded: ['video', 'details'],
      displayKeys: [
        ShortcutKey(keyId: LogicalKeyboardKey.digit1.keyId, alt: true),
        null,
        ShortcutKey(keyId: LogicalKeyboardKey.f9.keyId, ctrl: true, shift: true),
      ],
    );

    test('goes through text and comes back the same, a 64-bit number included', () {
      final back = ScreenWindowPayload.fromJson(jsonDecode(jsonEncode(payload.toJson())) as Map<String, dynamic>)!;
      expect(back.sessionId, 's1');
      expect(back.handle, 0x7fffffffffffffff);
      expect(back.protocol, ScreenProtocol.rdp);
      expect(ScreenConnected(back.info).displays, hasLength(2));
      expect((back.menuKey, back.viewOnly, back.fit, back.followViewSize), ('f9', true, 'fill', true));
      expect((back.textScale, back.displayCount, back.smoothScaling, back.commandAsControl), (150, 2, true, true));
      expect(back.frameLimit, 30);
      expect(back.panelFolded, ['video', 'details']);
      expect(back.displayKeys, [
        ShortcutKey(keyId: LogicalKeyboardKey.digit1.keyId, alt: true),
        null,
        ShortcutKey(keyId: LogicalKeyboardKey.f9.keyId, ctrl: true, shift: true),
      ]);
      expect(payload.toJson()['type'], 'screen');
      expect(payload.toJson()['handle'], isA<String>());
    });

    test('names no host and carries no secret', () {
      final text = jsonEncode(payload.toJson());
      for (final never in const ['password', 'username', 'host', 'address', 'name', 'clipboard']) {
        expect(text.contains('"$never"'), isFalse, reason: never);
      }
    });

    test('anything that is not a screen payload, or names no session, is none', () {
      final good = payload.toJson();
      expect(ScreenWindowPayload.fromJson({...good, 'type': 'editor'}), isNull);
      expect(ScreenWindowPayload.fromJson({...good, 'sessionId': ''}), isNull);
      expect(ScreenWindowPayload.fromJson({...good, 'sessionId': 7}), isNull);
      expect(ScreenWindowPayload.fromJson({...good, 'handle': '0'}), isNull);
      expect(ScreenWindowPayload.fromJson({...good, 'handle': 'x'}), isNull);
      expect(ScreenWindowPayload.fromJson({...good, 'protocol': 'ssh'}), isNull);
      expect(ScreenWindowPayload.fromJson(const {}), isNull);
    });

    test('a value out of place reads as its default', () {
      final odd = ScreenWindowPayload.fromJson({
        ...payload.toJson(),
        'info': 'x',
        'menuKey': 9,
        'viewOnly': 'yes',
        'fit': null,
        'textScale': 9000,
        'displayCount': 40,
        'smoothScaling': 1,
        'panelFolded': ['video', 7, 'x' * 40, null],
        'displayKeys': [7, 'x', {'keyId': 'y'}, null, {'keyId': 49}],
      })!;
      expect(odd.info, isEmpty);
      expect((odd.menuKey, odd.viewOnly, odd.fit), ('f8', false, 'fit'));
      expect((odd.textScale, odd.displayCount, odd.smoothScaling), (0, 1, false));
      expect(odd.panelFolded, ['video']);
      expect(odd.displayKeys, [null, null, null, null], reason: 'four at most, and none that is not a key');
    });
  });

  group('the events passed on', () {
    ScreenEvent? through(ScreenEvent e) => decodeScreenWindowEvent(encodeScreenWindowEvent(e));

    test('the remote cursor: its picture, its hot spot, hidden, and the system pointer', () {
      final rgba = Uint8List.fromList([for (var i = 0; i < 2 * 3 * 4; i++) i]);
      final cursor = through(ScreenCursor(2, 3, 1, 2, rgba)) as ScreenCursor;
      expect((cursor.width, cursor.height, cursor.hotX, cursor.hotY, cursor.system), (2, 3, 1, 2, false));
      expect(cursor.rgba, rgba);
      final hidden = through(ScreenCursor(0, 0, 0, 0, Uint8List(0))) as ScreenCursor;
      expect(hidden.hidden, isTrue);
      expect((through(ScreenCursor.systemPointer()) as ScreenCursor).system, isTrue);
    });

    test('the displays, a new size, a bell, and why the session ended', () {
      final displays = through(const ScreenDisplaysChanged([ScreenDisplayRect(0, 0, 1920, 1080), ScreenDisplayRect(1920, 0, 1280, 1024)]))
          as ScreenDisplaysChanged;
      expect(displays.displays, const [ScreenDisplayRect(0, 0, 1920, 1080), ScreenDisplayRect(1920, 0, 1280, 1024)]);
      final resized = through(const ScreenResized(1600, 900)) as ScreenResized;
      expect((resized.width, resized.height), (1600, 900));
      expect(through(const ScreenBell()), isA<ScreenBell>());
      final closed = through(const ScreenClosed(ScreenCloseReason.serverClosed, 'the server closed the connection')) as ScreenClosed;
      expect((closed.reason, closed.message), (ScreenCloseReason.serverClosed, 'the server closed the connection'));
    });

    test('never passed on: new pixels, the clipboard, what the server says, the handshake', () {
      expect(encodeScreenWindowEvent(const ScreenFrameReady(3)), isNull);
      expect(encodeScreenWindowEvent(const ScreenClipboard('secret text')), isNull);
      expect(encodeScreenWindowEvent(const ScreenInfo({'graphics': {}})), isNull);
      expect(encodeScreenWindowEvent(const ScreenConnected({'name': 'office-pc'})), isNull);
    });

    test('anything malformed is nothing', () {
      String cursor(Map<String, Object?> over) =>
          jsonEncode({'k': 'cursor', 'w': 1, 'h': 1, 'x': 0, 'y': 0, 'rgba': base64Encode([1, 2, 3, 4]), ...over});
      expect(decodeScreenWindowEvent(cursor(const {})), isA<ScreenCursor>());
      // Pixels that are not the cursor's own size, a size past the largest, text that is no base64.
      expect(decodeScreenWindowEvent(cursor({'w': 2})), isNull);
      expect(decodeScreenWindowEvent(cursor({'w': 513, 'h': 1, 'rgba': base64Encode(Uint8List(513 * 4))})), isNull);
      expect(decodeScreenWindowEvent(cursor({'rgba': '***'})), isNull);
      expect(decodeScreenWindowEvent(cursor({'x': -1})), isNull);
      for (final bad in <Object?>[
        null,
        7,
        '',
        'not json',
        '[]',
        '{"k":"nothing"}',
        '{"k":"resized","w":0,"h":10}',
        '{"k":"resized","w":"a","h":10}',
        '{"k":"displays","rects":[]}',
        '{"k":"displays","rects":[[0,0,-5,10]]}',
      ]) {
        expect(decodeScreenWindowEvent(bad), isNull, reason: '$bad');
      }
      // An unknown reason still ends the window's reader.
      final closed = decodeScreenWindowEvent('{"k":"closed","reason":"??","message":7}') as ScreenClosed;
      expect((closed.reason, closed.message), (ScreenCloseReason.internal, ''));
    });
  });
}
