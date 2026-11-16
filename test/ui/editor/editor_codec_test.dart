import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';

/// How the file editor reads and writes a file's bytes (3.4): the real
/// encoding and line endings, kept when it is saved, and a file that is not
/// UTF-8 opened in the closest match rather than refused.
void main() {
  group('reading', () {
    test('UTF-8 with LF', () {
      final d = EditorCodec.decode(utf8.encode('café\nline 2\n'));
      expect(d.encoding, EditorEncoding.utf8);
      expect(d.lineBreak, EditorLineBreak.lf);
      expect(d.text, 'café\nline 2\n');
      expect(d.notUtf8, isFalse);
    });

    test('CRLF is found, and the text is in lines', () {
      final d = EditorCodec.decode(utf8.encode('a\r\nb\r\nc'));
      expect(d.lineBreak, EditorLineBreak.crlf);
      expect(d.text, 'a\nb\nc');
      expect(d.mixedLineBreaks, isFalse);
    });

    test('old Mac CR is found', () {
      final d = EditorCodec.decode(utf8.encode('a\rb\rc'));
      expect(d.lineBreak, EditorLineBreak.cr);
      expect(d.text, 'a\nb\nc');
    });

    test('mixed line endings: the most common one, and said', () {
      final d = EditorCodec.decode(utf8.encode('a\r\nb\r\nc\nd'));
      expect(d.lineBreak, EditorLineBreak.crlf);
      expect(d.mixedLineBreaks, isTrue);
    });

    test('a UTF-8 byte order mark is kept apart from the text', () {
      final d = EditorCodec.decode([0xEF, 0xBB, 0xBF, ...utf8.encode('x = 1')]);
      expect(d.encoding, EditorEncoding.utf8Bom);
      expect(d.text, 'x = 1');
    });

    test('UTF-16 little and big endian, by their marks', () {
      final le = EditorCodec.decode([0xFF, 0xFE, 0x68, 0x00, 0xE9, 0x00]);
      expect(le.encoding, EditorEncoding.utf16le);
      expect(le.text, 'hé');
      final be = EditorCodec.decode([0xFE, 0xFF, 0x00, 0x68, 0x00, 0xE9]);
      expect(be.encoding, EditorEncoding.utf16be);
      expect(be.text, 'hé');
    });

    test('a file that is not UTF-8 opens as Windows-1252, said so, every byte a letter', () {
      final bytes = [0x63, 0x61, 0x66, 0xE9, 0x20, 0x80, 0x0A];
      final d = EditorCodec.decode(bytes);
      expect(d.encoding, EditorEncoding.windows1252);
      expect(d.notUtf8, isTrue);
      expect(d.text, 'café \u20AC\n');
      expect(EditorCodec.encode(d.text, d.encoding, d.lineBreak), bytes, reason: 'saved back as it was');
    });

    test('in an encoding asked for', () {
      expect(EditorCodec.decode([0xA4], as: EditorEncoding.latin9).text, '\u20AC');
      expect(EditorCodec.decode([0xA4], as: EditorEncoding.latin1).text, '\u00A4');
      expect(EditorCodec.decode(utf8.encode('é'), as: EditorEncoding.latin1).text, 'Ã©');
    });
  });

  group('writing', () {
    test('line endings as the file had them', () {
      expect(EditorCodec.encode('a\nb', EditorEncoding.utf8, EditorLineBreak.crlf), utf8.encode('a\r\nb'));
      expect(EditorCodec.encode('a\nb', EditorEncoding.utf8, EditorLineBreak.cr), utf8.encode('a\rb'));
      expect(EditorCodec.encode('a\nb', EditorEncoding.utf8, EditorLineBreak.lf), utf8.encode('a\nb'));
    });

    test('a byte order mark where the file had one', () {
      expect(EditorCodec.encode('x', EditorEncoding.utf8Bom, EditorLineBreak.lf), [0xEF, 0xBB, 0xBF, 0x78]);
      expect(EditorCodec.encode('h', EditorEncoding.utf16le, EditorLineBreak.lf), [0xFF, 0xFE, 0x68, 0x00]);
      expect(EditorCodec.encode('h', EditorEncoding.utf16be, EditorLineBreak.lf), [0xFE, 0xFF, 0x00, 0x68]);
    });

    test('every file round-trips: read, then written, gives the same bytes', () {
      final files = <List<int>>[
        utf8.encode('server {\r\n  listen 80;\r\n}\r\n'),
        [0xEF, 0xBB, 0xBF, ...utf8.encode('a\nb')],
        [0xFF, 0xFE, 0x61, 0x00, 0x0D, 0x00, 0x0A, 0x00],
        [0x48, 0xE9, 0x8A, 0x0A],
      ];
      for (final bytes in files) {
        final d = EditorCodec.decode(bytes);
        expect(EditorCodec.encode(d.text, d.encoding, d.lineBreak), bytes, reason: '$bytes');
      }
    });

    test('a character with no byte in the encoding refuses the save, naming it and its line', () {
      expect(
        () => EditorCodec.encode('ok\nemoji \u{1F600}', EditorEncoding.windows1252, EditorLineBreak.lf),
        throwsA(isA<EditorEncodeException>()
            .having((e) => e.line, 'line', 2)
            .having((e) => e.char, 'char', '\u{1F600}')
            .having((e) => e.typeName, 'typeName', 'EditorEncodeException')),
      );
      expect(() => EditorCodec.encode('\u20AC', EditorEncoding.latin1, EditorLineBreak.lf), throwsA(isA<EditorEncodeException>()));
      expect(EditorCodec.encode('\u20AC', EditorEncoding.latin9, EditorLineBreak.lf), [0xA4]);
    });
  });

  group('languages', () {
    test('by full name, by where the file is, by extension, by the #! line', () {
      expect(EditorLanguages.detect('nginx.conf'), EditorLanguage.nginx);
      expect(EditorLanguages.detect('shop.conf', path: '/etc/nginx/sites-available/shop.conf'), EditorLanguage.nginx);
      expect(EditorLanguages.detect('Dockerfile'), EditorLanguage.dockerfile);
      expect(EditorLanguages.detect('docker-compose.yml'), EditorLanguage.yaml);
      expect(EditorLanguages.detect('sshd_config'), EditorLanguage.sshConfig);
      expect(EditorLanguages.detect('config', path: '/home/deploy/.ssh/config'), EditorLanguage.sshConfig);
      expect(EditorLanguages.detect('shop.service'), EditorLanguage.systemd);
      expect(EditorLanguages.detect('backup', path: '/etc/cron.d/backup'), EditorLanguage.crontab);
      expect(EditorLanguages.detect('postgresql.conf'), EditorLanguage.postgresql);
      expect(EditorLanguages.detect('.bashrc'), EditorLanguage.shell);
      expect(EditorLanguages.detect('app.py'), EditorLanguage.python);
      expect(EditorLanguages.detect('Makefile'), EditorLanguage.makefile);
      expect(EditorLanguages.detect('deploy', firstLine: '#!/usr/bin/env bash'), EditorLanguage.shell);
      expect(EditorLanguages.detect('tool', firstLine: '#!/usr/bin/python3'), EditorLanguage.python);
      expect(EditorLanguages.detect('README'), EditorLanguage.plainText);
    });

    test('each coloured language has its highlighter', () {
      for (final lang in EditorLanguage.values) {
        if (lang.mode != null) expect(EditorLanguages.modes[lang.mode], isNotNull, reason: lang.name);
      }
    });

    test('indentation: YAML spaces only, a Makefile tabs, else what the file does', () {
      expect(EditorIndent.detect('a:\n  b: 1\n', EditorLanguage.yaml), const EditorIndent.spaces(2));
      expect(EditorIndent.detect('a:\n\tb: 1\n', EditorLanguage.yaml), isNot(const EditorIndent.tabs()));
      expect(EditorIndent.detect('all:\n\tmake\n', EditorLanguage.makefile), const EditorIndent.tabs());
      expect(EditorIndent.detect('', EditorLanguage.makefile), const EditorIndent.tabs());
      expect(EditorIndent.detect('def f():\n    return 1\n', EditorLanguage.python), const EditorIndent.spaces(4));
      expect(EditorIndent.detect('server {\n  listen 80;\n}\n', EditorLanguage.nginx), const EditorIndent.spaces(2));
      expect(EditorIndent.detect('x\n', EditorLanguage.plainText), const EditorIndent.spaces(4));
    });
  });
}
