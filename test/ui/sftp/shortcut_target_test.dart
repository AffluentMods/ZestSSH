import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// A Windows shortcut opened in SFTP's local pane is followed to its target
/// (found in a security review of the client). Its path went
/// into a PowerShell command as a single-quoted string with its quotes
/// doubled, but PowerShell also ends such a string at the typographic quotes
/// U+2018 to U+201B, which a file's name may hold: a shortcut so named,
/// downloaded from a host and opened, ran what its name said. Now the path
/// reaches PowerShell as text alone.
///
/// Every shortcut is made by one PowerShell before the test, and each one the
/// app follows starts a PowerShell of its own (as the app does): it took eight
/// starts in the test's own 30 seconds, which a full suite's load on the
/// machine let run out.
void main() {
  final windows = Platform.isWindows;
  late Directory dir;
  late String target;

  final systemRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
  final powershell = '$systemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';

  /// Shortcuts at [names] in the folder, each to the target file, made by one
  /// PowerShell; their paths. The names reach it in an environment variable
  /// ("|" between them: no file name holds one), never in its command.
  Future<List<String>> shortcuts(List<String> names) async {
    final paths = [for (final name in names) '${dir.path}\\$name'];
    final made = await Process.run(
      powershell,
      [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        r'$shell = New-Object -ComObject WScript.Shell; '
            r"foreach ($lnk in $env:LNKS.Split('|')) { $s = $shell.CreateShortcut($lnk); $s.TargetPath = $env:TARGET; $s.Save() }",
      ],
      environment: {'LNKS': paths.join('|'), 'TARGET': target},
    );
    expect(made.exitCode, 0, reason: '${made.stderr}');
    for (final (i, path) in paths.indexed) {
      expect(File(path).existsSync(), isTrue, reason: 'the shortcut ${names[i]} was made');
    }
    return paths;
  }

  setUp(() {
    if (!windows) return;
    dir = Directory.systemTemp.createTempSync('zest_shortcut_');
    target = '${dir.path}\\notes.txt';
    File(target).writeAsStringSync('notes');
  });

  tearDown(() {
    if (windows && dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('a shortcut is followed to its target, whatever quotes its name holds, and nothing in its name is run',
      () async {
    final [plain, apostrophe, hostile, quotes] = await shortcuts([
      'notes.lnk',
      "it's here.lnk",
      // Ends a string at each typographic quote, and would print a word of
      // its own where its name were taken for code.
      'x\u2019);\u2019INJECTED\u2019;(\u2019.lnk',
      // (The shell's shortcuts take no name with U+201B, which the system's
      // own code page has no place for.)
      'a\u2018b\u201Ac.lnk',
    ]);
    final source = LocalPaneFileSource();
    expect(await source.resolveShortcut(plain), target);
    expect(await source.resolveShortcut(apostrophe), target);
    final resolved = await source.resolveShortcut(hostile);
    expect(resolved, target);
    expect(resolved, isNot(contains('INJECTED')));
    expect(await source.resolveShortcut(quotes), target);
    // Five PowerShell starts, each well under a second on an idle machine and
    // several times that under a full suite: room for a loaded machine.
  }, skip: !windows, timeout: const Timeout(Duration(minutes: 2)));

  test('what is no shortcut is not followed', () async {
    final source = LocalPaneFileSource();
    expect(await source.resolveShortcut(target), isNull);
  }, skip: !windows);
}
