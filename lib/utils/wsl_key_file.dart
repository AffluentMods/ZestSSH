import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/utils/windows_programs.dart';

// A key for Mosh or Eternal Terminal on Windows, written where they read it
// (found 16 October 2026 while comparing the five versions). They run inside
// WSL there, and were handed the key's path in Windows (C:\Users\...), which
// WSL's ssh cannot open; nor would it take a key from Windows' folders, which
// all show to it as readable by everyone (a key so readable is ignored). So
// the key is written inside WSL, into a folder of its own in /tmp
// (/tmp/zestssh_mosh_XXXXXX/id_key) that the WSL account alone can open, by
// one command that reads the key from its input, never from its command line,
// and is removed when the session ends; what a crash left there goes at the
// next session with a key, once an hour old.

/// Runs [arguments] with wsl.exe in WSL's default distribution, with [input]
/// written to its input; its exit code and what it printed.
typedef WslRun = Future<({int code, String out})> Function(List<String> arguments, {String? input});

/// Whether [path] is a key's path in WSL as [writeKeyInWsl] makes it in
/// [root].
bool isWslKeyPath(String path, {String root = '/tmp'}) =>
    RegExp('^${RegExp.escape(root)}/zestssh_mosh_[A-Za-z0-9]{6}/id_key\$').hasMatch(path);

/// Makes a folder of its own in the folder it is given ($1), readable by the
/// WSL account alone, writes the key it reads from its input into it, and
/// prints its path; a key not written leaves no folder.
const _writeScript = r'umask 077; d=$(mktemp -d "$1/zestssh_mosh_XXXXXX") || exit 1; '
    r'if cat > "$d/id_key"; then printf %s "$d/id_key"; else rm -rf -- "$d"; exit 1; fi';

/// Removes the folders in the folder it is given ($1) that a crash left:
/// those holding nothing but a key, in which nothing has changed for an hour
/// (a session signing in with a newer one may be using it).
const _sweepScript = r'for d in "$1"/zestssh_mosh_*; do '
    r'[ -d "$d" ] && [ ! -L "$d" ] || continue; '
    r'[ "$(ls -A "$d")" = id_key ] || continue; '
    r'[ -z "$(find "$d" -maxdepth 1 -mmin -60)" ] || continue; '
    r'rm -rf -- "$d"; done';

/// Writes [pem] into a folder of its own in WSL's /tmp ([root] in tests),
/// readable by the WSL account alone, and returns its path there. Throws
/// where it was not written.
Future<String> writeKeyInWsl(String pem, {@visibleForTesting String root = '/tmp', @visibleForTesting WslRun? run}) async {
  // With the line ends of Linux, and one at its end, as ssh reads a key there.
  final lines = pem.replaceAll('\r\n', '\n').trimRight();
  final done = await (run ?? _wsl)(['--exec', 'sh', '-c', _writeScript, 'sh', root], input: '$lines\n');
  final path = done.out.trim();
  if (done.code != 0 || !isWslKeyPath(path, root: root)) {
    throw StateError('The key was not written in WSL (exit ${done.code})');
  }
  return path;
}

/// Removes the key [path] in WSL (as [writeKeyInWsl] returns it) with its
/// folder; anything else is left alone. Never throws.
Future<void> removeKeyInWsl(String path, {@visibleForTesting String root = '/tmp', @visibleForTesting WslRun? run}) async {
  if (!isWslKeyPath(path, root: root)) return;
  try {
    await (run ?? _wsl)(['--exec', 'rm', '-rf', '--', path.substring(0, path.lastIndexOf('/'))]);
  } catch (_) {
    // WSL not reached: the folder stays, for the next sweep.
  }
}

/// Removes what a crash left of keys in WSL's /tmp ([root] in tests,
/// [_sweepScript]). Never throws.
Future<void> clearLeftoverKeysInWsl({@visibleForTesting String root = '/tmp', @visibleForTesting WslRun? run}) async {
  try {
    await (run ?? _wsl)(['--exec', 'sh', '-c', _sweepScript, 'sh', root]);
  } catch (_) {
    // WSL not reached: nothing to clear there now.
  }
}

Future<({int code, String out})> _wsl(List<String> arguments, {String? input}) async {
  final process = await Process.start(windowsSystemProgram('wsl.exe'), arguments);
  final out = process.stdout.transform(const Utf8Decoder(allowMalformed: true)).join();
  final err = process.stderr.drain<void>();
  if (input != null) process.stdin.write(input);
  await process.stdin.close();
  final code = await process.exitCode.timeout(const Duration(seconds: 30), onTimeout: () {
    process.kill();
    return -1;
  });
  await err;
  return (code: code, out: await out);
}
