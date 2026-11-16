import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// Windows' own programs are started by their full paths (found in a
/// security review of the client): started by a name alone, a program
/// is looked for in the app's current folder before System32, and a file of
/// that name there was run in its stead.
void main() {
  test("Windows' own programs are where Windows keeps them", () {
    expect(windowsSystemProgram('icacls.exe'), '$windowsRoot\\System32\\icacls.exe');
    expect(windowsPowerShell, '$windowsRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe');
    expect(windowsExplorer, '$windowsRoot\\explorer.exe');
    if (Platform.isWindows) {
      for (final path in [
        windowsSystemProgram('icacls.exe'),
        windowsSystemProgram('reg.exe'),
        windowsSystemProgram('sc.exe'),
        windowsSystemProgram('cmd.exe'),
        windowsPowerShell,
        windowsExplorer,
      ]) {
        expect(File(path).existsSync(), isTrue, reason: path);
      }
    }
  });

  test('a program on PATH is found by its full path in a folder named in full, never in the current folder', () {
    final dir = Directory.systemTemp.createTempSync('zest_path_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bin = Directory('${dir.path}${Platform.pathSeparator}bin')..createSync();
    final tool = File('${bin.path}${Platform.pathSeparator}tool.exe')..writeAsStringSync('');
    final sep = Platform.isWindows ? ';' : ':';
    final windows = Platform.isWindows;

    expect(findOnPath('tool.exe', path: ['', bin.path].join(sep), windows: windows), tool.path);
    expect(findOnPath('tool.exe', path: ['.', 'bin', 'missing'].join(sep), windows: windows), isNull,
        reason: 'the current folder, and a folder relative to it, are never looked in');
    expect(findOnPath('none.exe', path: bin.path, windows: windows), isNull);
  });

  test('Windows tells a folder named in full from one that is not', () {
    final root = Directory.systemTemp.createTempSync('zest_drive_');
    addTearDown(() => root.deleteSync(recursive: true));
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final tool = File('${root.path}\\tool.exe')..writeAsStringSync('');
    expect(findOnPath('tool.exe', path: root.path, windows: true), tool.path);
    expect(findOnPath('tool.exe', path: '${root.path}\\', windows: true), tool.path);
    expect(findOnPath('tool.exe', path: root.path.substring(2), windows: true), isNull,
        reason: 'a folder with no drive is the current drive\'s');
  });

  test("no program of Windows' own is started by its name alone", () {
    final bare = RegExp(
        r'''Process\.(run|start|runSync)\(\s*['"](icacls|where|wsl|sc|cmd|explorer|reg|powershell|ssh-add)(\.exe)?['"]''');
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final text = file.readAsStringSync();
      for (final m in bare.allMatches(text)) {
        found.add('${file.path}: ${m.group(0)}');
      }
    }
    expect(found, isEmpty);
  });
}
