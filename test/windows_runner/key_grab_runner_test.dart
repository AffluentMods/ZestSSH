// The Windows runner's key_grab.cpp (system keys to a full-screen remote
// screen: a low-level keyboard hook that takes the keys Windows would act on,
// only while the app asks, renews and is in front), built with the C++
// compiler of the PC's Visual Studio beside a harness of its own
// (key_grab_harness.cpp), and run.
//
// Windows is played in the harness: the keyboard of this PC is never hooked.
// Skipped where no Visual Studio with the C++ tools is installed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';

void main() {
  test(
    'system keys are taken only while the app asks, renews and is in front, a taken press has its release taken, '
    'and the hook goes with the grab',
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
      final dir = await Directory.systemTemp.createTemp('zest_key_grab_');
      addTearDown(() => dir.delete(recursive: true));
      final runner = p.absolute('windows', 'runner');
      final build = File(p.join(dir.path, 'build.cmd'))
        ..writeAsStringSync(
          [
            '@echo off',
            'call "$vcvars" >nul',
            'cd /d "${dir.path}"',
            'cl /nologo /EHsc /std:c++17 /W4 /WX /DNOMINMAX /DUNICODE /D_UNICODE /I "$runner" '
                '"${p.absolute('test', 'windows_runner', 'key_grab_harness.cpp')}" '
                '"${p.join(runner, 'key_grab.cpp')}" /Fe:harness.exe',
          ].join('\r\n'),
        );
      final built = await Process.run('cmd.exe', ['/d', '/c', build.path]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

      final run = await Process.run(p.join(dir.path, 'harness.exe'), const []).timeout(const Duration(minutes: 2));
      final said = '${run.stdout}';
      expect(run.exitCode, 0, reason: said);
      expect(said, isNot(contains('FAILED')));
      for (final line in const [
        'ok: the Windows keys, the menu key and Print Screen are taken alone',
        'ok: Alt+Tab, Alt+Space, Alt+F4, Alt+Esc and Ctrl+Esc are taken',
        'ok: Tab, Space and Esc alone, letters, Alt, Ctrl and Alt+Enter are not',
        'ok: not started: nothing is taken',
        'ok: started: the hook is set once',
        'ok: the Windows key, pressed and let go: both taken and posted',
        'ok: a letter and Tab alone go on to Windows',
        'ok: Alt+Tab: taken',
        'ok: Ctrl+Esc: taken',
        'ok: the window hands each on: the key, its scan code, extended, down then up',
        "ok: other messages are not the grab's",
        'ok: another program is in front: its keys are not taken',
        'ok: a press taken',
        'ok: its release is taken too, though the window is no longer in front',
        "ok: not renewed for two seconds (the app stuck): the keys are Windows' again",
        'ok: renewed: taken again',
        'ok: stopped: the hook is removed and nothing is taken',
        'ok: Windows refuses the hook: not started',
        'ok: gone while grabbing: the hook is removed',
        'ok: the real Windows: no window is not in front',
        'all hold',
      ]) {
        expect(said, contains(line));
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
