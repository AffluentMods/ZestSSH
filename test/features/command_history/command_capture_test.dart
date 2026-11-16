import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/command_history/command_capture.dart';

/// A [CommandCapture] fed one whole string, with a display-line provider that
/// mimics a shell echoing the command at the end of the prompt line. Returns
/// the last command finalized by the input.
String? _run(CommandCapture c, String input,
    {String prompt = r'user@host:~$ '}) {
  // The echo check reads the "current display line". A normal shell shows the
  // typed command after the prompt; a password prompt shows only the prompt.
  final typed = StringBuffer();
  String? last;
  for (final ch in input.split('')) {
    // Mirror what a normal shell would echo: printables append, backspace
    // erases the last char on screen too.
    final code = ch.codeUnitAt(0);
    if (code == 0x7f || code == 0x08) {
      final s = typed.toString();
      typed.clear();
      if (s.isNotEmpty) typed.write(s.substring(0, s.length - 1));
    } else if (code >= 0x20) {
      typed.write(ch);
    }
    last = c.onInput(ch, () => '$prompt${typed.toString()}') ?? last;
  }
  return last;
}

void main() {
  group('commandLooksSensitive', () {
    test('flags inline credentials', () {
      expect(commandLooksSensitive('mysql -psecret'), isTrue);
      expect(commandLooksSensitive('mysql --password=hunter2'), isTrue);
      expect(commandLooksSensitive('export TOKEN=abc123'), isTrue);
      expect(commandLooksSensitive('curl -H "Authorization: Bearer x"'), isTrue);
      expect(commandLooksSensitive('deploy --api-key=zzz'), isTrue);
    });

    test('leaves ordinary commands alone', () {
      expect(commandLooksSensitive('ls -la'), isFalse);
      expect(commandLooksSensitive('git status'), isFalse);
      expect(commandLooksSensitive('docker ps'), isFalse);
    });

    // Found in a review: common ways of putting a password or a
    // token on a command line passed, so with the default setting (sensitive
    // commands not recorded) they were recorded and synced.
    const secretBearing = [
      'sshpass -p hunter2 ssh admin@db1',
      '/usr/bin/sshpass -p hunter2 scp a b:',
      'docker login -u deploy -p hunter2 registry.example.com',
      'podman login registry.example.com -u deploy -p hunter2',
      'curl -u admin:hunter2 https://ci.example.com/api',
      'curl -s --user admin:hunter2 https://ci.example.com/api',
      'git clone https://deploy:ghp_abcdef1234567890@github.com/acme/app.git',
      'psql postgres://app:hunter2@db1:5432/app',
      'redis-cli -u redis://:hunter2@cache1:6379',
      'openssl rsa -in key.pem -passin pass:hunter2',
      'openssl enc -aes-256-cbc -pass pass:hunter2 -in a -out b',
      'mysql -u root --password hunter2',
    ];
    for (final cmd in secretBearing) {
      test('treated as carrying a secret: $cmd', () {
        expect(commandLooksSensitive(cmd), isTrue);
      });
    }

    const ordinary = [
      'ssh -p 2222 admin@db1',
      'ssh login-server -p 2222',
      'scp -P 2222 a admin@db1:',
      'docker run -u 1000:1000 alpine id',
      'git clone https://github.com/acme/app.git',
      'git clone ssh://git@github.com:22/acme/app.git',
      'curl -u admin https://ci.example.com/api',
      'curl https://example.com:8443/path',
      'docker login -u deploy registry.example.com',
      'docker login registry.example.com',
    ];
    for (final cmd in ordinary) {
      test('an ordinary command is kept: $cmd', () {
        expect(commandLooksSensitive(cmd), isFalse);
      });
    }
  });

  group('CommandCapture', () {
    test('records a simple echoed command on Enter', () {
      final c = CommandCapture();
      expect(_run(c, 'ls -la\r'), 'ls -la');
    });

    test('handles backspace before recording', () {
      final c = CommandCapture();
      expect(_run(c, 'lst\x7f -la\r'), 'ls -la');
    });

    test('does NOT record a password (not echoed on the display line)', () {
      final c = CommandCapture();
      // The display line stays at the prompt, so the typed secret never appears.
      var result;
      for (final ch in 'hunter2\r'.split('')) {
        result = c.onInput(ch, () => '[sudo] password for user: ');
      }
      expect(result, isNull);
    });

    test('an escape sequence (arrow / history recall) marks the line untrusted',
        () {
      final c = CommandCapture();
      // Arrow-up recalls history: we can't trust our reconstruction, so skip.
      final r = _run(c, 'ls\x1b[A\r');
      expect(r, isNull);
    });

    test('Ctrl+C abandons the line', () {
      final c = CommandCapture();
      expect(_run(c, 'rm -rf /tmp\x03\r'), isNull);
    });

    test('returns an echoed secret-bearing command (caller applies the filter)',
        () {
      final c = CommandCapture();
      // CommandCapture only echo-verifies; commandLooksSensitive + the user's
      // opt-in decide whether it is stored (terminal_providers._captureCommand).
      expect(_run(c, 'mysql -psecret\r'), 'mysql -psecret');
      expect(commandLooksSensitive('mysql -psecret'), isTrue);
    });

    test('suppresses an immediate duplicate', () {
      final c = CommandCapture();
      expect(_run(c, 'pwd\r'), 'pwd');
      // Second identical run in a row is deduped.
      expect(_run(c, 'pwd\r'), isNull);
    });

    test('empty line records nothing', () {
      final c = CommandCapture();
      expect(_run(c, '\r'), isNull);
    });
  });

  // What a broadcast typed into this terminal (typed by the person into
  // another one): the line is followed, and nothing of it is a command of
  // this terminal's to record.
  group('CommandCapture, typed here by a broadcast', () {
    test('a line that was received is not recorded when it is entered', () {
      final c = CommandCapture();
      c.onReceived('uptime\r');
      expect(c.line, '');
      // The same line typed here right after IS one: receiving it did not
      // count as running it here.
      expect(_run(c, 'uptime\r'), 'uptime');
    });

    test('what was received is part of the line the person goes on typing', () {
      final c = CommandCapture();
      c.onReceived('apt upd');
      expect(c.line, 'apt upd');
      expect(c.trusted, isTrue);
      // The person types the rest here: the command is the whole line, not
      // the letters typed last.
      String? last;
      for (final ch in 'ate\r'.split('')) {
        last = c.onInput(ch, () => r'user@host:~$ apt update') ?? last;
      }
      expect(last, 'apt update');
    });

    test('backspace, Ctrl+U and Ctrl+C that were received edit the line', () {
      final c = CommandCapture();
      c.onReceived('lss\x7f');
      expect(c.line, 'ls');
      c.onReceived('\x15');
      expect(c.line, '');
      c.onReceived('abc\x03');
      expect(c.line, '');
      expect(c.trusted, isTrue);
    });

    test('an arrow that was received makes the line unknown, until it is entered', () {
      final c = CommandCapture();
      c.onReceived('ls\x1b[A');
      expect(c.trusted, isFalse);
      String? last;
      for (final ch in ' -la\r'.split('')) {
        last = c.onInput(ch, () => r'user@host:~$ ls -la') ?? last;
      }
      expect(last, isNull, reason: 'the line was edited in a way that cannot be followed');
      // An Enter that was received ends the line, and the next one is known.
      c.onReceived('x\x1b[A');
      expect(c.trusted, isFalse);
      c.onReceived('\r');
      expect(c.trusted, isTrue);
      expect(c.line, '');
      expect(_run(c, 'pwd\r'), 'pwd');
    });

    test('several lines that were received leave only what follows the last line end', () {
      final c = CommandCapture();
      c.onReceived('one\rtwo\nthr');
      expect(c.line, 'thr');
    });

    test('a received line is not what an immediate duplicate is measured by', () {
      final c = CommandCapture();
      expect(_run(c, 'pwd\r'), 'pwd');
      c.onReceived('ls\r');
      // (Running the last recorded line again right away is still skipped.)
      expect(_run(c, 'pwd\r'), isNull);
      expect(_run(c, 'ls\r'), 'ls');
    });
  });

  // A command longer than the terminal is wide wraps across several rows; the
  // echo check needs the whole logical line, not just the last visual row
  // (that dropped every wrapped command, including `cd ... && npm run build`).
  group('joinLogicalLine (wrapped commands)', () {
    test('joins wrapped continuation rows into the full line', () {
      final rows = ['user@host:~\$ cd ~/We', 'bshop && npm run buil', 'd'];
      const wrapped = [false, true, true]; // rows 1,2 continue the row above
      final line = joinLogicalLine(2, (y) => rows[y], (y) => wrapped[y]);
      expect(line, 'user@host:~\$ cd ~/Webshop && npm run build');
      // The whole command is now a suffix, so the echo check passes.
      expect(line.endsWith('cd ~/Webshop && npm run build'), isTrue);
    });

    test('even a short command wraps when the prompt is long', () {
      // Long prompt + `cd` pushed to a second row; the last row alone is `d`.
      final rows = ['deploy@web-01:~\$ c', 'd'];
      const wrapped = [false, true];
      final line = joinLogicalLine(1, (y) => rows[y], (y) => wrapped[y]);
      expect(line.endsWith('cd'), isTrue);
    });

    test('a single unwrapped row is returned unchanged', () {
      final line =
          joinLogicalLine(0, (y) => 'user@host:~\$ help', (_) => false);
      expect(line, 'user@host:~\$ help');
    });
  });
}
