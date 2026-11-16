import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/tool_path.dart';

/// Mosh and Eternal Terminal are looked for, and run, with where package
/// managers put programs, which a Mac app started from the Finder or the Dock
/// does not have on its PATH (found while comparing the five
/// versions: installed with Homebrew, neither was found).
void main() {
  test("the PATH a tool runs with: the app's own first, then the package managers' folders it lacks", () {
    expect(toolPath('/usr/bin:/bin:/usr/sbin:/sbin'),
        '/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:/opt/local/bin');
    expect(toolPath('/usr/local/bin:/usr/bin'), '/usr/local/bin:/usr/bin:/opt/homebrew/bin:/opt/local/bin',
        reason: 'none twice');
    expect(toolPath(''), '/opt/homebrew/bin:/usr/local/bin:/opt/local/bin');
  });

  test('a tool is found by its full path in a folder of that PATH, and an absent one is not', () async {
    final dir = await Directory.systemTemp.createTemp('tool_path_');
    addTearDown(() => dir.delete(recursive: true));
    File('${dir.path}/mosh').writeAsStringSync('');
    // The folder as a POSIX path (on Windows the drive is the current one).
    final folder = dir.path.replaceFirst(RegExp(r'^[A-Za-z]:'), '').replaceAll(r'\', '/');
    expect(findTool('mosh', path: folder), '$folder/mosh');
    expect(findTool('zest-no-such-tool', path: folder), isNull);
    // Found in a package manager's folder that the app's PATH lacks.
    expect(findTool('mosh', path: '/usr/bin:/bin', folders: [folder]), '$folder/mosh');
    expect(findTool('mosh', path: '/usr/bin:/bin', folders: const []), isNot('$folder/mosh'));
  });

  test('Mosh and Eternal Terminal are looked for and started that way', () {
    for (final (file, tool) in [
      ('lib/services/mosh_service.dart', 'mosh'),
      ('lib/services/eternal_terminal_service.dart', 'et'),
    ]) {
      final text = File(file).readAsStringSync();
      expect(text, contains("findTool('$tool') != null"), reason: file);
      expect(text, contains("findTool('$tool') ?? '$tool',"), reason: file);
      expect(text, contains("'PATH': toolPath(),"), reason: file);
      expect(text, isNot(contains("Process.run('which'")), reason: file);
    }
  });
}
