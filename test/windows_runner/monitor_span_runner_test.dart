// The Windows runner's monitor_span.cpp (full screen on all monitors),
// built with the C++ compiler of the PC's Visual Studio beside a harness of
// its own (monitor_span_harness.cpp), and run. Only what reads is checked;
// no window is moved.
// Skipped where no Visual Studio with the C++ tools is installed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _vswhere = r'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe';

void main() {
  test(
    "the rectangle around monitors, and this PC's monitors as Windows lists them",
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
      final dir = await Directory.systemTemp.createTemp('zest_monitor_span_');
      addTearDown(() => dir.delete(recursive: true));
      final runner = p.absolute('windows', 'runner');
      final build = File(p.join(dir.path, 'build.cmd'))
        ..writeAsStringSync(
          [
            '@echo off',
            'call "$vcvars" >nul',
            'cd /d "${dir.path}"',
            'cl /nologo /EHsc /std:c++17 /W4 /WX /DNOMINMAX /DUNICODE /D_UNICODE /I "$runner" '
                '"${p.absolute('test', 'windows_runner', 'monitor_span_harness.cpp')}" '
                '"${p.join(runner, 'monitor_span.cpp')}" shcore.lib /Fe:harness.exe',
          ].join('\r\n'),
        );
      final built = await Process.run('cmd.exe', ['/d', '/c', build.path]);
      expect(built.exitCode, 0, reason: '${built.stdout}${built.stderr}');

      final run = await Process.run(p.join(dir.path, 'harness.exe'), const []).timeout(const Duration(minutes: 2));
      final said = '${run.stdout}';
      expect(run.exitCode, 0, reason: said);
      expect(said, isNot(contains('FAILED')));
      for (final line in const [
        "ok: no monitors: an empty rectangle",
        "ok: two side by side: the rectangle around both",
        "ok: one to the left of the primary, lower and smaller: from its left edge, the primary's top to the taller's bottom",
        "ok: one above the primary: its negative top is kept",
        "ok: no window: nothing is stretched",
        "ok: an empty area: nothing is stretched",
        "ok: leaving when not stretched does nothing",
        "ok: the real Windows: at least one monitor, one primary, listed first",
        "ok: the real Windows: each monitor has a size and a DPI",
        "all hold",
      ]) {
        expect(said, contains(line));
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
