import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';

/// The pane's honest numbers: the footer never passes the selected files'
/// bytes off as the whole selection once folders are in it, and a Windows
/// pane shows the Windows attributes that are really set instead of a
/// made-up Unix permission string.
void main() {
  group('the footer', () {
    test('files alone: count and size, as before', () {
      expect(paneSelectionLabel(3, 0, '1.2 MB'), '3 selected, 1.2 MB');
    });

    test('with folders, the size is labelled as the files alone', () {
      // Two big folders and one 333 B file read as
      // "3 selected, 333 B".
      expect(paneSelectionLabel(3, 2, '333 B'),
          '2 folders and 1 file selected (files: 333 B)');
      expect(paneSelectionLabel(4, 1, '9 KB'),
          '1 folder and 3 files selected (files: 9 KB)');
    });

    test('folders alone name no size at all', () {
      expect(paneSelectionLabel(2, 2, '0 B'), '2 folders selected');
      expect(paneSelectionLabel(1, 1, '0 B'), '1 folder selected');
    });
  });

  test('attribute letters come in a fixed order, and none is empty', () {
    expect(
        windowsAttributeLetters(
            (readOnly: true, hidden: true, system: true)),
        'RHS');
    expect(
        windowsAttributeLetters(
            (readOnly: false, hidden: true, system: false)),
        'H');
    expect(
        windowsAttributeLetters(
            (readOnly: false, hidden: false, system: false)),
        '');
  });

  test('a Windows listing carries the attributes Windows reports', () async {
    if (!Platform.isWindows) {
      markTestSkipped('Windows attributes exist only on Windows');
      return;
    }
    final dir = await Directory.systemTemp.createTemp('zestssh_attrs_');
    final plain = File('${dir.path}\\plain.txt')..writeAsStringSync('a');
    final locked = File('${dir.path}\\locked.txt')..writeAsStringSync('b');
    final secret = File('${dir.path}\\secret.txt')..writeAsStringSync('c');
    addTearDown(() async {
      await Process.run('attrib', ['-r', '-h', '${dir.path}\\*']);
      await dir.delete(recursive: true);
    });
    await Process.run('attrib', ['+r', locked.path]);
    await Process.run('attrib', ['+h', secret.path]);

    final entries = await LocalPaneFileSource().list(dir.path);
    String? attrs(String name) =>
        entries.firstWhere((e) => e.name == name).windowsAttributes;
    expect(attrs('plain.txt'), '');
    expect(attrs('locked.txt'), 'R');
    expect(attrs('secret.txt'), 'H');
    expect(entries.firstWhere((e) => e.name == 'secret.txt').isHidden, isTrue,
        reason: 'the Hidden attribute still hides it by default');
    expect(plain.existsSync(), isTrue);
  });
}
