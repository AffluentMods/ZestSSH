import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/command_history/shell_integration_parser.dart';

/// The Phase 2b OSC 133 / OSC 7 parser turns a raw stdout stream into typed
/// shell-integration events. It must ignore ordinary output and non-OSC escapes,
/// handle both BEL and ST terminators, and stitch sequences split across chunks.
void main() {
  const esc = '\x1b';
  const bel = '\x07';

  group('ShellIntegrationParser', () {
    test('emits nothing for plain output', () {
      final p = ShellIntegrationParser();
      expect(p.addOutput('total 12\r\ndrwxr-xr-x 2 me me\r\n'), isEmpty);
    });

    test('parses OSC 133 A / C / D with an exit code (BEL-terminated)', () {
      final p = ShellIntegrationParser();
      final events = p.addOutput(
        '$esc]133;A${bel}me@host:~\$ $esc]133;C${bel}output$esc]133;D;0$bel',
      );
      expect(events, hasLength(3));
      expect(events[0], isA<OscPromptStart>());
      expect(events[1], isA<OscCommandStart>());
      expect(events[2], isA<OscCommandEnd>());
      expect((events[2] as OscCommandEnd).exitCode, 0);
    });

    test('parses a non-zero exit code and D with no code', () {
      final p = ShellIntegrationParser();
      expect((p.addOutput('$esc]133;D;137$bel').single as OscCommandEnd).exitCode,
          137);
      expect((p.addOutput('$esc]133;D$bel').single as OscCommandEnd).exitCode,
          isNull);
    });

    test('accepts the ST (ESC backslash) terminator', () {
      final p = ShellIntegrationParser();
      final e = p.addOutput('$esc]133;D;2$esc\\');
      expect(e.single, isA<OscCommandEnd>());
      expect((e.single as OscCommandEnd).exitCode, 2);
    });

    test('parses OSC 7 into a decoded cwd path, stripping the host', () {
      final p = ShellIntegrationParser();
      final e =
          p.addOutput('$esc]7;file://myhost/home/me/My%20Site$bel').single;
      expect(e, isA<OscCwd>());
      expect((e as OscCwd).path, '/home/me/My Site');
    });

    test('ignores non-OSC escapes (CSI colour codes) around a sequence', () {
      final p = ShellIntegrationParser();
      final e = p.addOutput('$esc[32mgreen$esc[0m$esc]133;D;0${bel}next');
      expect(e, hasLength(1));
      expect((e.single as OscCommandEnd).exitCode, 0);
    });

    test('stitches a sequence split across two chunks', () {
      final p = ShellIntegrationParser();
      expect(p.addOutput('$esc]133;D;'), isEmpty); // incomplete: carried
      final e = p.addOutput('0$bel');
      expect(e.single, isA<OscCommandEnd>());
      expect((e.single as OscCommandEnd).exitCode, 0);
    });

    test('strips control chars from a decoded cwd and caps its length', () {
      final p = ShellIntegrationParser();
      // %00 and %1b decode to control bytes and must be stripped.
      final e = p.addOutput('$esc]7;file://h/tmp/a%00b%1bc$bel').single;
      expect((e as OscCwd).path, '/tmp/abc');
      // A long-but-within-scan-bound cwd is capped rather than stored whole.
      // (A payload beyond the 8192 terminator-scan bound is dropped entirely by
      // the anti-DoS guard, which the flood test below covers.)
      final long = 'x' * 6000;
      final e2 = p.addOutput('$esc]7;file://h/$long$bel').single;
      expect((e2 as OscCwd).path.length, lessThanOrEqualTo(4096));
    });

    test('a folder that would read otherwise than it is: its direction overrides, the marks that take no room and '
        'the C1 controls are taken out', () {
      final p = ShellIntegrationParser();
      // U+202E before "gnp.exe", then U+0085 and U+200B.
      final e = p.addOutput('$esc]7;file://h/tmp/%E2%80%AEgnp.exe%C2%85%E2%80%8B$bel').single;
      expect((e as OscCwd).path, '/tmp/gnp.exe');
    });

    test('an unterminated OSC flood is bounded and emits nothing', () {
      final p = ShellIntegrationParser();
      // A single ESC] with a huge tail and no terminator: the bounded scan must
      // return fast and produce no events (not carry the whole tail).
      final junk = '$esc]${'A' * 40000}';
      expect(p.addOutput(junk), isEmpty);
      // A real sequence right after still parses on the next chunk.
      expect(p.addOutput('$esc]133;D;0$bel').single, isA<OscCommandEnd>());
    });

    test('a full prompt/command/finish cycle yields the ordered events', () {
      final p = ShellIntegrationParser();
      final e = p.addOutput(
        '$esc]7;file://h/tmp$bel$esc]133;A${bel}\$ ls$esc]133;C$bel'
        'file1 file2\r\n$esc]133;D;0$bel',
      );
      expect(e.map((x) => x.runtimeType).toList(), [
        OscCwd,
        OscPromptStart,
        OscCommandStart,
        OscCommandEnd,
      ]);
      expect((e[0] as OscCwd).path, '/tmp');
    });

    group("iTerm2's OSC 1337;CurrentDir= (4.0, the SFTP dock follows the terminal's folder)", () {
      test('gives the folder as it is written, with BEL or ST', () {
        final p = ShellIntegrationParser();
        final e = p.addOutput('$esc]1337;CurrentDir=/srv/www/My Site$bel').single;
        expect((e as OscCwd).path, '/srv/www/My Site');
        final st = p.addOutput('$esc]1337;CurrentDir=/var/log$esc\\').single;
        expect((st as OscCwd).path, '/var/log');
      });

      test('is not percent-decoded (it is no URI)', () {
        final p = ShellIntegrationParser();
        final e = p.addOutput('$esc]1337;CurrentDir=/tmp/100%25$bel').single;
        expect((e as OscCwd).path, '/tmp/100%25');
      });

      test('a Windows host\'s folder is taken, either slash', () {
        final p = ShellIntegrationParser();
        expect((p.addOutput('$esc]1337;CurrentDir=C:\\Users\\me$bel').single as OscCwd).path, 'C:\\Users\\me');
        expect((p.addOutput('$esc]1337;CurrentDir=D:/data$bel').single as OscCwd).path, 'D:/data');
      });

      test('is cleaned as OSC 7 is: controls and direction marks out, its length capped', () {
        final p = ShellIntegrationParser();
        final e = p.addOutput('$esc]1337;CurrentDir=/tmp/\u202Egnp.exe\u0085\u200B$bel').single;
        expect((e as OscCwd).path, '/tmp/gnp.exe');
        final long = p.addOutput('$esc]1337;CurrentDir=/${'y' * 6000}$bel').single;
        expect((long as OscCwd).path.length, lessThanOrEqualTo(4096));
      });

      test('nothing for an empty or relative folder, or for other OSC 1337 sequences', () {
        final p = ShellIntegrationParser();
        expect(p.addOutput('$esc]1337;CurrentDir=$bel'), isEmpty);
        expect(p.addOutput('$esc]1337;CurrentDir=projects/app$bel'), isEmpty);
        expect(p.addOutput('$esc]1337;CurrentDir=\u202E$bel'), isEmpty);
        expect(p.addOutput('$esc]1337;SetMark$bel'), isEmpty);
        expect(p.addOutput('$esc]1337;RemoteHost=me@host$bel'), isEmpty);
      });

      test('is stitched across two chunks', () {
        final p = ShellIntegrationParser();
        expect(p.addOutput('$esc]1337;Current'), isEmpty);
        expect((p.addOutput('Dir=/opt$bel').single as OscCwd).path, '/opt');
      });
    });
  });
}
