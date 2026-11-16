import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every place in the app that types text into a session, or hands a command
/// to a host's shell to run: a command a person wrote goes through
/// `CommandText` there (lib/utils/command_text.dart), so its line ends are
/// what the shell takes them for. The others are listed below with what they
/// send and why that needs no such care.
///
/// A new place that types or runs text fails this test until it either uses
/// `CommandText` or is added to the list with its reason. (Keys from the
/// keyboard and pasted text go other ways: `Terminal.keyInput` and
/// `Terminal.paste`, which has the same rule for line ends built in.)
void main() {
  // (file, what the statement contains, why it needs no care for line ends)
  const allowed = <(String, String, String)>[
    (
      'lib/providers/terminal_providers.dart',
      'utf8.encode(cmd)',
      "the exports the app builds from a host's environment variables: one line",
    ),
    (
      'lib/providers/terminal_providers.dart',
      'utf8.encode(transformed)',
      'what the terminal sends for the keys pressed in it, or typed again into it by a broadcast: '
          'the terminal makes it, with the line ends its program asked for',
    ),
    (
      'lib/ui/widgets/terminal_paste.dart',
      'textInput(typed)',
      'the quoted paths of files dropped on a terminal or a pane: one line, and none with a control character '
          '(CommandText.quotedPaths)',
    ),
    (
      'lib/ui/screens/desktop/widgets/desktop_terminal_area.dart',
      'textInput(sanitized)',
      'dropped text with every control character taken out: no line ends left',
    ),
    (
      'lib/ui/screens/tmux/tmux_workspace.dart',
      'textInput(sanitized)',
      'dropped text with every control character taken out: no line ends left',
    ),
    (
      'lib/ui/screens/terminal/widgets/soft_key_catalog.dart',
      'textInput(key)',
      'a key of the key bar',
    ),
    (
      'lib/ui/screens/terminal/terminal_screen.dart',
      r"textInput('\x03')",
      'Ctrl+C',
    ),
    (
      'lib/ui/screens/terminal/terminal_screen.dart',
      'textInput(sanitized)',
      'dictated words with every control character taken out: no line ends left',
    ),
    (
      'lib/features/terminal/terminal_dictation.dart',
      'textInput(sanitized)',
      "a computer's dictated words with every control character taken out: no line ends left",
    ),
    (
      'lib/database/database.dart',
      'rawDb.execute(',
      'the database on this device, not a host',
    ),
    (
      'lib/features/tmux/tmux_session_host.dart',
      'client.execute(',
      'tmux commands the app builds itself',
    ),
    (
      'lib/services/server_stats_service.dart',
      'client.runCapped(command',
      "Server Monitor's own commands",
    ),
    (
      'lib/services/sftp_service.dart',
      '_client.execute(',
      'commands the app builds for one file',
    ),
    (
      'lib/services/sftp_service.dart',
      '_client.runCapped(cmd',
      'commands the app builds for one file',
    ),
    (
      'lib/services/sudo_runner.dart',
      'client.execute(command)',
      "the app's own commands for files, run as root through sudo (Save as root, Retry with sudo): "
          'mv, cp, rm, mkdir, cat and fixed sh scripts, every path quoted (CommandText.quoted) and only one '
          'that stands in any shell (CommandText.standsInAnyShell); the password goes on standard input',
    ),
    (
      'lib/providers/terminal_providers.dart',
      'ssh.client.execute(command)',
      "mosh-server's start for the built-in Mosh client (4.0): one line of fixed words the app builds "
          '(moshServerCommand in lib/services/mosh/mosh_bootstrap.dart: a path of its own list, new, -s, -c 256, the '
          'port range and a locale of its own list), nothing of the person in it',
    ),
    (
      'lib/features/screens/xprogram/x_program_run.dart',
      'client.execute(xProgramCommand(',
      "an X program's host script (4.0): one line of fixed text that carries the script and the "
          "person's program line as printf formats, every byte but letters, digits and a few plain marks an octal "
          'escape, so no line end, quote or control character of either reaches the shell (the line holds none)',
    ),
    (
      'lib/services/os_detection_service.dart',
      'client.runCapped(',
      'the one command the app asks a host what system it runs with',
    ),
  ];

  final typed = RegExp(r'\.textInput\(');
  final written = RegExp(r'\.write\(\s*Uint8List\.fromList\(\s*utf8\.encode\(');
  // Text sent into a session for its person goes through the session layer's
  // one door (ActiveSessionsNotifier.sendInput), which writes it.
  final sent = RegExp(r'\.sendInput\(\s*[^,;]+,\s*Uint8List\.fromList\(\s*utf8\.encode\(');
  final run = RegExp(r'\.(?:execute|runCapped)\(');

  /// Every statement in lib/ that types, writes text or runs: (file, the
  /// statement on one line).
  List<(String, String)> sites() {
    final out = <(String, String)>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final path = file.path.replaceAll('\\', '/');
      final text = file.readAsStringSync().replaceAll('\r\n', '\n');
      for (final pattern in [typed, written, sent, run]) {
        for (final m in pattern.allMatches(text)) {
          final start = text.lastIndexOf('\n', m.start) + 1;
          final line = text.substring(start, m.start).trimLeft();
          if (line.startsWith('//')) continue; // said in a comment
          final end = text.indexOf(';', m.end);
          final statement = text
              .substring(start, end < 0 ? text.length : end + 1)
              .split(RegExp(r'\s+'))
              .join(' ')
              .trim();
          out.add((path, statement));
        }
      }
    }
    return out;
  }

  bool isAllowed((String, String) site) => allowed
      .any((a) => a.$1 == site.$1 && site.$2.contains(a.$2));

  test('a command a person wrote is typed and run through CommandText', () {
    final found = sites();
    expect(found.length, greaterThan(20), reason: 'the scan finds the sites');

    final careless = [
      for (final site in found)
        if (!site.$2.contains('CommandText.') && !isAllowed(site))
          '${site.$1}: ${site.$2}',
    ];
    expect(careless, isEmpty,
        reason: 'these type or run text without CommandText and are not on '
            'the list of those that need not');
  });

  test('each of them uses the form of the rule it should', () {
    // What is typed for the person to enter is `typed`; what is typed and
    // entered is `entered`; what a shell is handed whole is `script`.
    const forms = <String, List<String>>{
      // A snippet typed at a prompt (entered where the person has "Press
      // Enter after pasting a snippet" on, the palette and the Inspector
      // included); and sent to a host's session made ready as everywhere a
      // snippet runs (its variables filled in, a dangerous one asked about:
      // commandReadyToRun), from the computer's snippet library, its editor
      // and its details (runCommandOnHost, runCommandInSession).
      'lib/features/snippets/run_snippet.dart': [
        'terminal.textInput(read(autoExecuteSnippetsProvider) ? '
            'CommandText.entered(command) : CommandText.typed(command));',
        '.sendInput(sessionId, Uint8List.fromList(utf8.encode(CommandText.entered(ready.command))));',
      ],
      // A command from the Inspector's history is typed for the person to
      // enter; one run from its Tools (a snippet or a recent command run
      // again, a risky one asked about first) is entered.
      'lib/ui/screens/desktop/widgets/inspector_panel.dart': [
        'terminal.textInput(CommandText.typed(e.command))',
        'terminal.textInput(CommandText.entered(command))',
      ],
      'lib/providers/terminal_providers.dart': [
        'utf8.encode(CommandText.entered(command))',
      ],
      'lib/ui/screens/sftp/sftp_dual_pane_screen.dart': [
        'utf8.encode(CommandText.entered(cd))',
      ],
      // The command that lists a snippet's options, run on its own on the
      // session's host (3.0: on every device, SshService.runOnce).
      'lib/services/ssh_service.dart': [
        'client.runCapped(CommandText.script(command)',
      ],
      'lib/services/automation_service.dart': [
        'client.execute(CommandText.script(command))',
      ],
      // Run on hosts (3.0): one command on many hosts, handed whole.
      'lib/features/run/run_on_hosts.dart': [
        '.execute(CommandText.script(run.command))',
      ],
      // Replace on all hosts (3.0, Keys): the app's own sh commands that
      // read, add to and write authorized_keys, each handed whole.
      'lib/features/keys/replace_key.dart': [
        '.execute(CommandText.script(command))',
      ],
    };
    final byFile = <String, List<String>>{};
    for (final (file, statement) in sites()) {
      if (statement.contains('CommandText.')) {
        byFile.putIfAbsent(file, () => []).add(statement);
      }
    }
    expect(byFile.keys.toSet(), forms.keys.toSet());
    for (final entry in forms.entries) {
      final statements = byFile[entry.key]!;
      expect(statements, hasLength(entry.value.length), reason: entry.key);
      for (final form in entry.value) {
        expect(statements.where((s) => s.contains(form)), hasLength(1),
            reason: '${entry.key} should hold: $form\nit holds: $statements');
      }
    }
  });

  test('what leads to those places hands them the command as it is', () {
    String text(String path) =>
        File(path).readAsStringSync().replaceAll('\r\n', '\n');
    // A snippet picked inside a session goes to the one function that types
    // it, with the screen's own way to read a setting.
    expect(text('lib/ui/screens/terminal/terminal_screen.dart'),
        contains('typePickedSnippet(ref.read, terminal, command, secrets: secrets);'));
    // A new session opened in a folder is given the same command a session
    // already open is typed, and neither is typed for a name that may not be.
    final sftp = text('lib/ui/screens/sftp/sftp_dual_pane_screen.dart');
    expect(sftp, contains('final cd = CommandText.cdInto(path);'));
    expect(sftp, contains('if (cd == null) {'));
    expect(sftp, contains('initialCommand: cd,'));
    // Commands the app builds itself are entered with the same Enter.
    expect(text('lib/ui/screens/desktop/widgets/monitor_table_view.dart'),
        contains("CommandText.entered('systemctl --failed')"));
    expect(text('lib/ui/screens/monitoring/server_detail_screen.dart'),
        contains("initialCommand: 'systemctl --failed',"));
    expect(text('lib/providers/terminal_providers.dart'),
        contains(r"final cmd = CommandText.entered('${buffer}clear');"));
    expect(text('lib/features/tmux/tmux_controller.dart'),
        contains(r"CommandText.entered('tmux -CC new -A -s $sessionName')"));
  });

  test('no command the app types ends in a line feed of its own', () {
    // Enter is a carriage return: a line feed is not Enter to the shell of a
    // Windows host. Looked for: a quoted text that ends in a line feed and is
    // typed, turned into bytes, or given as a first command.
    final lineFeedEnter = RegExp(
        r'''(textInput\(|utf8\.encode\(|initialCommand:\s*|_sendCommandWhenReady\(\s*\w+,\s*)['"][^'"\r\n]*\\n['"]''');
    // Bytes that end in a line feed and are not typed at a prompt.
    const notTyped = {
      'lib/features/orchards/export/event_export.dart':
          'a label that is hashed, sent nowhere',
      'lib/features/keys/key_action_dialogs.dart':
          'the last line of an exported public key file, handed to the share sheet',
      'lib/features/keys/replace_key.dart':
          "the public key line the app made, given to Install on hosts' command on its standard input (read with read -r)",
      'lib/features/orchards/orchard_session_logs.dart':
          'a line of a session log',
      'lib/services/sudo_runner.dart':
          'the sudo password of Save as root and Retry with sudo, given to sudo -S on its standard input, which reads one line',
      'lib/features/tmux/tmux_controller.dart':
          "a command for tmux's control mode, whose lines end in a line feed",
      'lib/services/ssh_service.dart':
          'a line shown on this screen, not sent to the host',
      'lib/ui/screens/identity/identity_edit_screen.dart':
          'the last line of an exported public key file, handed to the share sheet',
    };
    final found = <String>[];
    final excused = <String>{};
    for (final file in Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'))) {
      final path = file.path.replaceAll(r'\', '/');
      final text = file.readAsStringSync();
      for (final m in lineFeedEnter.allMatches(text)) {
        if (notTyped.containsKey(path) && m.group(1) == 'utf8.encode(') {
          excused.add(path);
        } else {
          found.add('$path: ${m.group(0)}');
        }
      }
    }
    expect(found, isEmpty);
    expect(excused, notTyped.keys.toSet(),
        reason: 'every file excused still has such bytes');
  });

  test('every entry of the list still names something in the app', () {
    final found = sites();
    final stale = [
      for (final a in allowed)
        if (!found.any((s) => s.$1 == a.$1 && s.$2.contains(a.$2)))
          '${a.$1}: ${a.$2}',
    ];
    expect(stale, isEmpty, reason: 'listed, but no longer in the app');
  });
}
