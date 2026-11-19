import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/models/enums.dart';

/// A remote screen's options (4.0): the JSON of a VNC host's screen_options
/// column, read leniently and bounded, and the kind classes that keep screens
/// apart from what older versions read.
void main() {
  group('ScreenOptions', () {
    test('a new host starts from the defaults, and they read back the same', () {
      const d = ScreenOptions.defaults;
      expect(d.target, ScreenTargetKind.tcp);
      expect(d.socket, isNull);
      expect(d.auth, ScreenAuth.auto);
      expect(d.clipboard, isNull, reason: "the space's default");
      expect(d.clipboardLocked, isFalse);
      expect(d.scaling, ScreenScaling.fit);
      expect(d.quality, ScreenQuality.auto);
      expect(d.viewOnly, isFalse);
      expect(d.shared, isTrue);
      final json = jsonDecode(ScreenOptions.encodeDefaults()) as Map<String, dynamic>;
      expect(json['v'], 1);
      expect(json.containsKey('clipboard'), isFalse);
      expect(json.containsKey('socket'), isFalse);
      expect(ScreenOptions.decode(ScreenOptions.encodeDefaults()), d);
    });

    test('every value round trips by its name in the column', () {
      const o = ScreenOptions(
        target: ScreenTargetKind.unix,
        socket: '~/.vnc/zest.sock',
        auth: ScreenAuth.apple,
        clipboard: false,
        clipboardLocked: true,
        scaling: ScreenScaling.remoteResize,
        quality: ScreenQuality.low,
        viewOnly: true,
        shared: false,
      );
      final json = jsonDecode(o.encode()) as Map<String, dynamic>;
      expect(json, {
        'v': 1,
        'target': 'unix',
        'socket': '~/.vnc/zest.sock',
        'auth': 'apple',
        'clipboard': 'off',
        'clipboard_locked': true,
        'clipboard_send': 'focus',
        'scaling': 'remote_resize',
        'quality': 'low',
        'view_only': true,
        'shared': false,
      });
      expect(ScreenOptions.decode(o.encode()), o);
      expect(ScreenOptions.decode('{"scaling":"one_to_one","clipboard":"on"}').scaling, ScreenScaling.oneToOne);
      expect(ScreenOptions.decode('{"clipboard":"on"}').clipboard, isTrue);
    });

    test('a bad value falls back to its default, the others kept', () {
      final o = ScreenOptions.decode(jsonEncode({
        'target': 'carrier-pigeon',
        'auth': 7,
        'clipboard': 'maybe',
        'clipboard_locked': 'yes',
        'scaling': 'stretch',
        'quality': null,
        'view_only': 1,
        'shared': false,
      }));
      expect(o.target, ScreenTargetKind.tcp);
      expect(o.auth, ScreenAuth.auto);
      expect(o.clipboard, isNull);
      expect(o.clipboardLocked, isFalse);
      expect(o.scaling, ScreenScaling.fit);
      expect(o.quality, ScreenQuality.auto);
      expect(o.viewOnly, isFalse);
      expect(o.shared, isFalse, reason: 'a good value is kept');
    });

    test('a socket target needs a socket path that is fit to use', () {
      expect(ScreenOptions.decode('{"target":"unix"}').target, ScreenTargetKind.tcp, reason: 'no path');
      // No control character at all (found in a security review: ESC and TAB too).
      for (final bad in ['', '   ', 'a\u0000b', '/tmp/x\n-SecurityTypes None', 'x' * 256, '/tmp/\u001b[2Jx', 'a\tb',
        'a\u007fb']) {
        final o = ScreenOptions.decode(jsonEncode({'target': 'unix', 'socket': bad}));
        expect(o.socket, isNull, reason: jsonEncode(bad));
        expect(o.target, ScreenTargetKind.tcp);
      }
      final ok = ScreenOptions.decode(jsonEncode({'target': 'unix', 'socket': '/run/user/1000/vnc.sock'}));
      expect(ok.target, ScreenTargetKind.unix);
      expect(ok.socket, '/run/user/1000/vnc.sock');
      // A TCP target writes no socket even if one was kept.
      expect(jsonDecode(ok.copyWith(target: ScreenTargetKind.tcp).encode()), isNot(contains('socket')));
    });

    test("keys this version does not know are kept and written back, a known key always its own", () {
      final later = jsonEncode({
        'v': 2,
        'scaling': 'one_to_one',
        'monitors': [1, 2],
        'codec': {'h264': true},
      });
      final o = ScreenOptions.decode(later);
      expect(o.unknown, {
        'monitors': [1, 2],
        'codec': {'h264': true},
      });
      final again = jsonDecode(o.copyWith(viewOnly: true).encode()) as Map<String, dynamic>;
      expect(again['monitors'], [1, 2]);
      expect(again['codec'], {'h264': true});
      expect(again['scaling'], 'one_to_one');
      expect(again['view_only'], isTrue);
      expect(again['v'], 1, reason: 'what this version writes');
    });

    test('bounded at 4 KB: a longer column reads as the defaults, kept keys that would overflow are dropped', () {
      final long = jsonEncode({'scaling': 'one_to_one', 'pad': 'x' * ScreenOptions.maxChars});
      expect(long.length, greaterThan(ScreenOptions.maxChars));
      expect(ScreenOptions.decode(long), ScreenOptions.defaults);
      expect(ScreenOptions.sanitize(long), isNull);

      final big = ScreenOptions.defaults.copyWith(viewOnly: true, unknown: {'pad': 'y' * (ScreenOptions.maxChars - 10)});
      final encoded = big.encode();
      expect(encoded.length, lessThanOrEqualTo(ScreenOptions.maxChars));
      final read = ScreenOptions.decode(encoded);
      expect(read.viewOnly, isTrue);
      expect(read.unknown, isEmpty);
    });

    test('what is not a JSON object reads as the defaults, and is not taken from outside', () {
      for (final raw in [null, '', 'not json', '[1,2]', '"text"', '42', 'null']) {
        expect(ScreenOptions.decode(raw), ScreenOptions.defaults, reason: '$raw');
        expect(ScreenOptions.sanitize(raw), isNull, reason: '$raw');
      }
      expect(ScreenOptions.sanitize(42), isNull);
      // A JSON object is taken as it came: each value is checked on reading.
      const raw = '{"v":9,"scaling":"stretch","future":true}';
      expect(ScreenOptions.sanitize(raw), raw);
    });

    test("the clipboard: on in the person's own space, off in a team, locked off by a team's editor", () {
      const d = ScreenOptions.defaults;
      expect(d.clipboardOnByDefault(inTeam: false), isTrue);
      expect(d.clipboardOnByDefault(inTeam: true), isFalse);
      expect(d.copyWith(clipboard: true).clipboardOnByDefault(inTeam: true), isTrue);
      expect(d.copyWith(clipboard: false).clipboardOnByDefault(inTeam: false), isFalse);
      final locked = d.copyWith(clipboard: true, clipboardLocked: true);
      expect(locked.clipboardOnByDefault(inTeam: true), isFalse);
      expect(locked.clipboardTogglable(inTeam: true), isFalse);
      expect(d.clipboardTogglable(inTeam: true), isTrue);
      // A lock means nothing in the person's own space.
      expect(locked.clipboardOnByDefault(inTeam: false), isTrue);
      expect(locked.clipboardTogglable(inTeam: false), isTrue);
    });
  });

  group('kind classes', () {
    test('VNC is a screen; FTPS its own class; everything older versions read the first', () {
      expect(ConnectionProtocol.vnc.name, 'vnc', reason: 'the stored name');
      expect(ConnectionProtocol.vnc.englishName, 'VNC');
      expect(ConnectionProtocol.vnc.isScreen, isTrue);
      expect(ConnectionProtocol.storedIsScreen('vnc'), isTrue);
      expect([for (final p in ConnectionProtocol.values) if (p.isScreen) p],
          [ConnectionProtocol.vnc, ConnectionProtocol.rdp]);
      expect(ConnectionProtocol.storedIsScreen('ssh'), isFalse);
      expect(ConnectionProtocol.storedIsScreen(null), isFalse);
      expect(ConnectionProtocol.storedIsScreen('VNC'), isFalse, reason: 'stored names are exact');

      expect(ConnectionProtocol.kindClassOf('vnc'), ConnectionProtocol.kindClassScreen);
      expect(ConnectionProtocol.kindClassOf('ftps'), ConnectionProtocol.kindClassFtps);
      expect(ConnectionProtocol.kindClassOf('ftpsImplicit'), ConnectionProtocol.kindClassFtps);
      for (final p in ['ssh', 'sftp', 'mosh', 'et', 'telnet', 'serial', 'localShell', 'demo', 'spice', '', null]) {
        expect(ConnectionProtocol.kindClassOf(p), ConnectionProtocol.kindClassShell, reason: '$p');
      }
      expect(ConnectionProtocol.storedNamesOfClass(ConnectionProtocol.kindClassScreen), ['vnc']);
      expect(ConnectionProtocol.storedNamesOfClass(ConnectionProtocol.kindClassFtps), ['ftps', 'ftpsImplicit']);
      expect(
        ConnectionProtocol.storedNamesOfClass(ConnectionProtocol.kindClassShell),
        ['ssh', 'sftp', 'mosh', 'et', 'telnet', 'serial', 'localShell', 'demo'],
      );
    });

    // 4.0: an RDP host gives its key's password to whatever answers
    // at its address, so it is a screen of a kind of its own, and a team's VNC
    // host can never become one (found in security reviews).
    test('RDP is a screen of a class of its own, apart from VNC', () {
      expect(ConnectionProtocol.rdp.name, 'rdp', reason: 'the stored name');
      expect(ConnectionProtocol.rdp.englishName, 'RDP');
      expect(ConnectionProtocol.rdp.isScreen, isTrue);
      expect(ConnectionProtocol.storedIsScreen('rdp'), isTrue);
      expect(ConnectionProtocol.storedIsScreen('RDP'), isFalse, reason: 'stored names are exact');
      expect(ConnectionProtocol.kindClassOf('rdp'), ConnectionProtocol.kindClassRdp);
      expect(ConnectionProtocol.kindClassRdp, isNot(ConnectionProtocol.kindClassScreen));
      expect(ConnectionProtocol.storedNamesOfClass(ConnectionProtocol.kindClassRdp), ['rdp']);
      expect(ConnectionProtocol.storedCanBeJumpHost('rdp'), isFalse, reason: 'a screen is never a hop');
      // Every protocol is in exactly one class, and every class is listed.
      expect(ConnectionProtocol.kindClasses, [1, 2, 3, 4]);
      expect([
        for (final k in ConnectionProtocol.kindClasses) ...ConnectionProtocol.storedNamesOfClass(k),
      ]..sort(), [for (final p in ConnectionProtocol.values) p.name]..sort());
    });
  });

  group("ScreenOptions, an RDP host's two", () {
    test('NLA is on and the graphics the app chooses, and neither is written while so', () {
      const d = ScreenOptions.defaults;
      expect(d.nla, isTrue);
      expect(d.graphics, ScreenGraphics.auto);
      final json = jsonDecode(d.encode()) as Map<String, dynamic>;
      expect(json.containsKey('nla'), isFalse, reason: "a VNC host's column is what it was");
      expect(json.containsKey('graphics'), isFalse);
    });

    test('without NLA and a chosen graphics round trip by name; a bad value is the default', () {
      final o = ScreenOptions.defaults.copyWith(nla: false, graphics: ScreenGraphics.remotefx);
      final json = jsonDecode(o.encode()) as Map<String, dynamic>;
      expect(json['nla'], false);
      expect(json['graphics'], 'remotefx');
      final back = ScreenOptions.decode(o.encode());
      expect(back.nla, isFalse);
      expect(back.graphics, ScreenGraphics.remotefx);
      expect(back, o);
      for (final g in ScreenGraphics.values) {
        expect(ScreenOptions.decode(ScreenOptions.defaults.copyWith(graphics: g).encode()).graphics, g);
      }
      // NLA is only ever turned off by the word false itself.
      for (final bad in ['"off"', '0', 'null', '"false"']) {
        expect(ScreenOptions.decode('{"nla":$bad,"graphics":"h264"}').nla, isTrue, reason: bad);
      }
      expect(ScreenOptions.decode('{"nla":false,"graphics":"h264"}').graphics, ScreenGraphics.auto);
      // Neither is a key kept as unknown.
      expect(ScreenOptions.decode('{"nla":false,"graphics":"basic","later":1}').unknown, {'later': 1});
    });
  });
}
