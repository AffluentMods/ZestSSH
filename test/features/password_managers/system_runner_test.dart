import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';

/// The real process runner for password manager tools (3.0),
/// against a compiled stand-in tool: arguments reach it exactly as given
/// (spaces and quotes included, never through a shell), the input and the
/// variables it was handed arrive, an error is read back, and a tool that
/// hangs is stopped. Skipped when this machine cannot compile the stand-in.
void main() {
  String? tool;
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('zest-fake-pm-');
    final out = '${dir.path}${Platform.pathSeparator}fake_pm_tool${Platform.isWindows ? '.exe' : ''}';
    final src = 'test${Platform.pathSeparator}features${Platform.pathSeparator}password_managers'
        '${Platform.pathSeparator}fake_tool${Platform.pathSeparator}fake_pm_tool.dart';
    try {
      // Compiled outside the app's package, which has build hooks that
      // `dart compile` does not run; the tool needs nothing but the SDK.
      final copy = '${dir.path}${Platform.pathSeparator}fake_pm_tool.dart';
      await File(src).copy(copy);
      final r = await Process.run('dart', ['compile', 'exe', copy, '-o', out], runInShell: true, workingDirectory: dir.path);
      if (r.exitCode == 0 && File(out).existsSync()) tool = out;
    } catch (_) {}
  });

  tearDownAll(() async {
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  const runner = SystemPmProcessRunner();

  test('arguments, input and variables arrive exactly; nothing goes through a shell', () async {
    if (tool == null) return markTestSkipped('could not compile the stand-in tool');
    final args = ['read', '--no-newline', '--', 'op://My Vault/db "prod" & more/pass word', r'%PATH%', r'$HOME', '^&|<>'];
    final r = await runner.run(tool!, args,
        environment: const {'BW_SESSION': 'S3SSION', 'ZESTSSH_BW_PASSWORD': 'm@ster pass', 'BW_NOINTERACTION': 'true'},
        stdin: 'db-pass\n',
        timeout: const Duration(seconds: 30));
    expect(r.exitCode, 0, reason: r.stderr);
    final got = jsonDecode(r.stdout) as Map;
    expect(got['args'], args, reason: 'no quoting, expansion or splitting on the way');
    expect(got['stdin'], 'db-pass\n');
    expect(got['env'], {'BW_SESSION': 'S3SSION', 'ZESTSSH_BW_PASSWORD': 'm@ster pass', 'BW_NOINTERACTION': 'true'});
  });

  test('an error is read back as the tool wrote it', () async {
    if (tool == null) return markTestSkipped('could not compile the stand-in tool');
    final r = await runner.run(tool!, const ['read'],
        environment: const {'ZEST_FAKE_MODE': 'fail'}, timeout: const Duration(seconds: 30));
    expect((r.exitCode, r.stderr, r.stdout), (1, '[ERROR] account is not signed in', ''));
  });

  test('a tool that hangs is stopped', () async {
    if (tool == null) return markTestSkipped('could not compile the stand-in tool');
    final took = Stopwatch()..start();
    final pidFile = '${dir.path}${Platform.pathSeparator}hung.pid';
    await expectLater(
        runner.run(tool!, const ['read'],
            environment: {'ZEST_FAKE_MODE': 'sleep', 'ZEST_FAKE_PIDFILE': pidFile}, timeout: const Duration(seconds: 2)),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.timedOut)));
    expect(took.elapsed, lessThan(const Duration(seconds: 20)));
    // The tool itself is gone, not left running.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final hung = int.parse(File(pidFile).readAsStringSync());
    expect(Process.killPid(hung), isFalse, reason: 'the runner stopped it');
  });

  test('a tool that is not there says so', () async {
    await expectLater(
        runner.run('${dir.path}${Platform.pathSeparator}missing${Platform.isWindows ? '.exe' : ''}', const ['read'],
            timeout: const Duration(seconds: 5)),
        throwsA(isA<PasswordManagerException>().having((e) => e.failure, 'failure', PmFailure.notInstalled)));
  });
}
