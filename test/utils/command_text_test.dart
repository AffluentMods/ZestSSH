import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/command_text.dart';

/// The line ends of a command, as the place it goes to takes them. A command
/// written or pasted on Windows ends its lines in a carriage return and a
/// line feed; typed as it stands, a shell takes each of the two for Enter
/// (in 2.2.1 a snippet of several lines came out double spaced).
void main() {
  const cr = '\r';
  const lf = '\n';
  const crlf = '\r\n';

  group('Typed at a prompt', () {
    test('a command written on Windows gets one Enter per line', () {
      expect(CommandText.typed('cd /srv${crlf}ls -la${crlf}df -h'),
          'cd /srv${cr}ls -la${cr}df -h');
    });

    test('a command written anywhere else gets one Enter per line too', () {
      expect(CommandText.typed('cd /srv${lf}ls -la'), 'cd /srv${cr}ls -la');
      expect(CommandText.typed('cd /srv${cr}ls -la'), 'cd /srv${cr}ls -la');
    });

    test('lines that end in different ways each get one Enter', () {
      expect(CommandText.typed('a${crlf}b${lf}c${cr}d'), 'a${cr}b${cr}c${cr}d');
    });

    test('an empty line in the command is an empty line, not two', () {
      expect(CommandText.typed('a$crlf${crlf}b'), 'a$cr${cr}b');
      expect(CommandText.typed('a$lf${lf}b'), 'a$cr${cr}b');
    });

    test('a command of one line is typed as it is', () {
      expect(CommandText.typed('sudo systemctl restart nginx'),
          'sudo systemctl restart nginx');
      expect(CommandText.typed(''), '');
    });

    test('nothing but line ends is changed', () {
      const command = "printf '%s\\n' \"tab\there\"  # ünïcödé \\r stays text";
      expect(CommandText.typed(command), command);
    });

    test('the last line waits for Enter', () {
      expect(CommandText.typed('a${crlf}b').endsWith(cr), isFalse);
      expect(CommandText.typed('ls'), 'ls');
    });

    test('a line end at the end of the text is the Enter it says', () {
      expect(CommandText.typed('ls$lf'), 'ls$cr');
      expect(CommandText.typed('ls$crlf'), 'ls$cr');
    });

    test('there is no line feed left in what is typed', () {
      for (final command in [
        'a${crlf}b',
        'a${lf}b',
        'a$lf',
        crlf,
        lf,
        'a$cr${lf}b$lf$cr',
      ]) {
        expect(CommandText.typed(command), isNot(contains(lf)));
        expect(CommandText.entered(command), isNot(contains(lf)));
      }
    });
  });

  group('Typed and entered', () {
    test('one Enter follows', () {
      expect(CommandText.entered('ls'), 'ls$cr');
      expect(CommandText.entered('a${crlf}b'), 'a${cr}b$cr');
      expect(CommandText.entered(''), cr);
    });

    test('a text that ends with a line end is not entered twice', () {
      expect(CommandText.entered('ls$lf'), 'ls$cr');
      expect(CommandText.entered('ls$crlf'), 'ls$cr');
      expect(CommandText.entered('ls$cr'), 'ls$cr');
    });

    test('a line that goes on after a backslash goes on', () {
      // Typed with both characters of a Windows line end, the second ended
      // the command where the backslash had asked for more.
      expect(CommandText.entered('rsync -a \\$crlf  src/ dst/'),
          'rsync -a \\$cr  src/ dst/$cr');
    });

    test('before its last Enter it is the same as when only typed', () {
      const command = 'a${crlf}b${lf}c';
      expect(CommandText.entered(command), '${CommandText.typed(command)}$cr');
    });
  });

  group('Handed whole to a shell', () {
    test('lines end in a line feed, wherever the command was written', () {
      expect(CommandText.script('cd /srv${crlf}ls -la'), 'cd /srv${lf}ls -la');
      expect(CommandText.script('cd /srv${cr}ls -la'), 'cd /srv${lf}ls -la');
      expect(CommandText.script('cd /srv${lf}ls -la'), 'cd /srv${lf}ls -la');
    });

    test('an empty line stays one empty line', () {
      expect(CommandText.script('a$crlf${crlf}b'), 'a$lf${lf}b');
    });

    test('no carriage return is left to stick to the last word of a line', () {
      for (final command in ['a${crlf}b', 'a$cr', 'a$crlf', 'a$cr${cr}b']) {
        expect(CommandText.script(command), isNot(contains(cr)));
      }
    });

    test('a command of one line is as it is', () {
      expect(CommandText.script('uptime'), 'uptime');
      expect(CommandText.script(''), '');
    });
  });

  group('Kept by the app', () {
    test('lines end in a line feed', () {
      expect(CommandText.stored('a${crlf}b${cr}c${lf}d'), 'a${lf}b${lf}c${lf}d');
      expect(CommandText.stored('one line'), 'one line');
    });

    test('what is kept is typed and run the same as what was written', () {
      const written = 'cd /srv${crlf}ls -la$crlf';
      final kept = CommandText.stored(written);
      expect(CommandText.entered(kept), CommandText.entered(written));
      expect(CommandText.typed(kept), CommandText.typed(written));
      expect(CommandText.script(kept), CommandText.script(written));
    });
  });

  group('The command that goes into a folder', () {
    test('the path stands in single quotes', () {
      expect(CommandText.cdInto('/srv/app'), "cd '/srv/app'");
      expect(CommandText.cdInto('/srv/my app/logs'), "cd '/srv/my app/logs'");
    });

    test('a quote in a text is closed, escaped and opened again, as a POSIX shell reads it', () {
      expect(CommandText.quoted("/srv/it's here"), r"'/srv/it'\''s here'");
      expect(CommandText.quoted("a'b'c"), r"'a'\''b'\''c'");
    });

    // POSIX quotes hold these for sh, bash and zsh, and not for every shell a
    // host can run: cmd.exe has no single quotes (`&` runs what follows),
    // PowerShell ends the string at a quote and runs what follows `;`, and
    // fish reads `\'` inside single quotes as a quote (found in a security
    // review). A folder's name is the server's to choose.
    test('a name another shell could read as part of a command is not typed at all', () {
      for (final name in [
        "/srv/it's here",
        r'/srv/$HOME',
        '/srv/`id`',
        '/srv/a;b',
        '/srv/a && b',
        '/srv/a & calc & rem x',
        r'/srv/a\b',
        '/srv/a"b',
        '/srv/a|b',
        '/srv/100%',
      ]) {
        expect(CommandText.mayBeTyped(name), isTrue, reason: name);
        expect(CommandText.cdInto(name), isNull, reason: name);
      }
    });

    // Typed into a tty, these act before any shell reads a quote (a review's
    // proof: Ctrl-U wiped the line with its opening quote, Enter ran the rest).
    test('a name with a control character in it is not typed at all', () {
      for (final name in [
        'backup\x15touch RAN\r',
        '/srv/a\nb',
        '/srv/a\rb',
        '/srv/a\tb',
        '/srv/a\x03',
        '/srv/\x1b[201~',
        '/srv/a\x7f',
        '/srv/a\x00',
        '/srv/a\u0080',
        '/srv/a\u009b201~',
      ]) {
        expect(CommandText.mayBeTyped(name), isFalse, reason: name);
        expect(CommandText.cdInto(name), isNull, reason: name);
      }
    });

    test('and a name in any other script is', () {
      for (final name in ['/srv/café', '/srv/日本語', '/srv/\u{1F600}', '/srv/a b']) {
        expect(CommandText.mayBeTyped(name), isTrue, reason: name);
        expect(CommandText.cdInto(name), startsWith("cd '"));
      }
    });
  });

  test('text dragged onto a terminal and dictated words lose every control character, C1 too', () {
    expect(CommandText.withoutControlCharacters('a\x03b\x1b[31mc\x7fd\u0080e\u009bf\r\ng\th'), 'ab[31mcdefgh');
    expect(CommandText.withoutControlCharacters('caf\u00e9 \u65e5\u672c'), 'caf\u00e9 \u65e5\u672c');
  });

  group('The paths of files dropped on a terminal', () {
    test('each stands in single quotes, with a space between them', () {
      expect(CommandText.quotedPaths(['/a b', "/it's"]), r"'/a b' '/it'\''s'");
      expect(CommandText.quotedPaths(const []), '');
    });

    test('one with a control character in it and none is typed', () {
      expect(CommandText.quotedPaths(['/fine', '/x\x15cmd\r']), isNull);
    });
  });
}
