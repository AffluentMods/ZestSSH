// The Windows runner's pointer_hold.cpp (relative mouse on a remote screen:
// the pointer hidden and kept on one point, its movement read and handed to
// the app), built with the C++ compiler of the PC's Visual Studio beside a
// harness of its own (pointer_hold_harness.cpp), and run.
//
// A held pointer is a pointer the person cannot use, so what is checked first
// is every way it is given back without the app asking: the window no longer
// in front, its menu, a move of the window, the displays changing, the window
// going, and the app saying nothing for two seconds (watched from a thread of
// its own, since a stuck app runs no timer).
//
// Windows is played in the harness: the pointer of this PC is never taken.
// Skipped where no Visual Studio with the C++ tools is installed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';

void main() {
  test(
    'the pointer is held only for a window in front, its movement is handed on, and it is given back on every way '
    'out, also when the app is stuck',
    () async {
      final found = await Process.run(_vswhere, [
        '-latest',
        '-products',
        '*',
        '-requires',
        'Microsoft.VisualStudio.Component.VC.Tools.x86.x64',
        '-property',
        'installationPath',
      ]);
      final install = '${found.stdout}'.trim();
      final vcvars = p.join(install, 'VC', 'Auxiliary', 'Build', 'vcvars64.bat');
      if (install.isEmpty || !File(vcvars).existsSync()) {
        markTestSkipped('No Visual Studio with the C++ tools on this PC');
        return;
      }
      final dir = await Directory.systemTemp.createTemp('zest_pointer_hold_');
      addTearDown(() => dir.delete(recursive: true));
      final runner = p.absolute('windows', 'runner');
      final build = File(p.join(dir.path, 'build.cmd'))
        ..writeAsStringSync(
          [
            '@echo off',
            'call "$vcvars" >nul',
            'cd /d "${dir.path}"',
            'cl /nologo /EHsc /std:c++17 /W4 /WX /DNOMINMAX /DUNICODE /D_UNICODE /I "$runner" '
                '"${p.absolute('test', 'windows_runner', 'pointer_hold_harness.cpp')}" '
                '"${p.join(runner, 'pointer_hold.cpp')}" /Fe:harness.exe',
          ].join('\r\n'),
        );
      final built = await Process.run('cmd.exe', ['/d', '/c', build.path]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

      final run = await Process.run(p.join(dir.path, 'harness.exe'), const []).timeout(const Duration(minutes: 2));
      final said = '${run.stdout}';
      expect(run.exitCode, 0, reason: said);
      expect(said, isNot(contains('FAILED')));
      for (final line in const [
        'ok: a window that is not in front is refused, and nothing is touched',
        'ok: the pointer is kept on the one point it was at',
        'ok: what waited goes with the timer, summed',
        'ok: a place after it is the way from the place before, in pixels',
        'ok: the window is no longer the active one: let go',
        'ok: another program is in front: let go',
        'ok: not renewed for two seconds: the watch frees the pointer itself, with the window',
        'ok: a renewal that comes too late finishes the release, and does not take the pointer back',
        'ok: gone while held: everything is given back',
        'ok: the real Windows: a window that is not in front is refused and the pointer of this PC is as it was',
        'all hold',
      ]) {
        expect(said, contains(line));
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
