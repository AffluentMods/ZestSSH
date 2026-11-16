// The Windows runner's single_instance.cpp, built with the C++ compiler of
// the PC's Visual Studio (the one the Windows build uses) beside a harness of
// its own (single_instance_harness.cpp), and run: a second start hands its
// zestssh:// link (a share link, a join code, an automation key) only to a
// window of a ZestSSH, never to any window carrying the mark (found in a
// security review). The harness uses names no
// ZestSSH uses: a ZestSSH that runs is never found, nor handed anything.
// Skipped where no Visual Studio with the C++ tools is installed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _vswhere =
    r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';

void main() {
  test(
    'a second start hands its link only to a ZestSSH: not to another program\'s marked window, nor one at a lower integrity level',
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
      final vcvars = p.join(
        install,
        'VC',
        'Auxiliary',
        'Build',
        'vcvars64.bat',
      );
      if (install.isEmpty || !File(vcvars).existsSync()) {
        markTestSkipped('No Visual Studio with the C++ tools on this PC');
        return;
      }
      final dir = await Directory.systemTemp.createTemp(
        'zest_single_instance_',
      );
      addTearDown(() => dir.delete(recursive: true));
      final runner = p.absolute('windows', 'runner');
      final build = File(p.join(dir.path, 'build.cmd'))
        ..writeAsStringSync(
          [
            '@echo off',
            'call "$vcvars" >nul',
            'cd /d "${dir.path}"',
            'cl /nologo /EHsc /std:c++17 /W4 /WX /wd4100 /DNOMINMAX /DUNICODE /D_UNICODE '
                '/DZEST_SINGLE_INSTANCE_TEST /I "$runner" '
                '"${p.absolute('test', 'windows_runner', 'single_instance_harness.cpp')}" '
                '"${p.join(runner, 'single_instance.cpp')}" /Fe:harness.exe',
          ].join('\r\n'),
        );
      final built = await Process.run('cmd.exe', ['/d', '/c', build.path]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

      final run = await Process.run(p.join(dir.path, 'harness.exe'), [
        'test',
      ]).timeout(const Duration(minutes: 2));
      final said = '${run.stdout}';
      expect(run.exitCode, 0, reason: said);
      expect(
        said,
        contains('ok: a window of this very program takes the link'),
      );
      expect(
        said,
        contains('ok: a marked window of another program is handed nothing'),
      );
      expect(
        said,
        contains(
          'ok: a marked window at a lower integrity level is handed nothing',
        ),
      );
      expect(
        said,
        contains('ok: another running copy of this program takes the link'),
      );
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
