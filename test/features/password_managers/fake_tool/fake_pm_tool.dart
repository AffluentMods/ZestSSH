import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A stand-in for a password manager's command line tool, compiled by
/// system_runner_test.dart: it reports what it was given (its arguments,
/// its input and a few variables) and behaves as ZEST_FAKE_MODE says.
Future<void> main(List<String> args) async {
  final mode = Platform.environment['ZEST_FAKE_MODE'] ?? 'ok';
  if (mode == 'sleep') {
    // Says who it is, so the test can see it was stopped.
    final pidFile = Platform.environment['ZEST_FAKE_PIDFILE'];
    if (pidFile != null) File(pidFile).writeAsStringSync('$pid');
    await Future<void>.delayed(const Duration(minutes: 5));
    return;
  }
  final input = await stdin.transform(utf8.decoder).join();
  if (mode == 'fail') {
    stderr.write('[ERROR] account is not signed in');
    exitCode = 1;
    return;
  }
  stdout.write(jsonEncode({
    'args': args,
    'stdin': input,
    'env': {
      for (final k in ['BW_SESSION', 'ZESTSSH_BW_PASSWORD', 'BW_NOINTERACTION']) k: Platform.environment[k],
    },
  }));
}
