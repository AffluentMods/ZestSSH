import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// The local pane's Recycle Bin call (delete safety spec, section 1). A real
/// file and a real folder tree go to the bin of this machine (they stay
/// there, like any deleted file), and a refusal comes back with a reason
/// instead of a bare false, so the pane can ask before deleting permanently.
void main() {
  test('a temp file and a folder tree go to the Recycle Bin', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final dir = await Directory.systemTemp.createTemp('zestssh_recycle_test');
    final file = File('${dir.path}\\file.txt');
    await file.writeAsString('recycle me');
    final tree = Directory('${dir.path}\\tree\\inner');
    await tree.create(recursive: true);
    await File('${tree.path}\\deep.txt').writeAsString('deep');

    final r1 = windowsRecycleDetailed([file.path]);
    expect(r1.ok, isTrue, reason: r1.reason);
    expect(file.existsSync(), isFalse);

    final r2 = windowsRecycleDetailed(['${dir.path}/tree']);
    expect(r2.ok, isTrue, reason: 'forward slashes are accepted: ${r2.reason}');
    expect(Directory('${dir.path}\\tree').existsSync(), isFalse);

    final source = LocalPaneFileSource();
    expect((await source.trashPathsDetailed([])).ok, isTrue);
    if (dir.existsSync()) await dir.delete(recursive: true);
  });

  test('a path that does not exist is refused with a reason', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final r = windowsRecycleDetailed([r'C:\zestssh_no_such_dir_\no_such_file.txt']);
    expect(r.ok, isFalse);
    expect(r.reason, isNotEmpty);
    expect(r.aborted, isFalse);
    final source = LocalPaneFileSource();
    final t = await source.trashPathsDetailed([r'C:\zestssh_no_such_dir_\x']);
    expect(t.ok, isFalse);
    expect(t.reason, isNotEmpty);
  });

  test('the pane recycles through a helper, so a big folder cannot freeze the '
      'window, and the result is the same', () async {
    if (!Platform.isWindows) return markTestSkipped('Windows only');
    final dir = await Directory.systemTemp.createTemp('zestssh_recycle_helper');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final tree = Directory('${dir.path}\\tree\\inner');
    await tree.create(recursive: true);
    for (var i = 0; i < 40; i++) {
      await File('${tree.path}\\f$i.txt').writeAsString('x' * 64);
    }
    final loose = File('${dir.path}\\loose.txt');
    await loose.writeAsString('recycle me');

    // The shell call runs in its own isolate with COM set up for it.
    final direct = await windowsRecycleInHelper([loose.path]);
    expect(direct.ok, isTrue, reason: direct.reason);
    expect(loose.existsSync(), isFalse);

    final result = await LocalPaneFileSource()
        .trashPathsDetailed(['${dir.path}\\tree']);
    expect(result.ok, isTrue, reason: result.reason);
    expect(result.cancelled, isFalse);
    expect(Directory('${dir.path}\\tree').existsSync(), isFalse);

    // A refusal still comes back with its reason from the helper.
    final refused = await windowsRecycleInHelper(
        [r'C:\zestssh_no_such_dir_\no_such_file.txt']);
    expect(refused.ok, isFalse);
    expect(refused.reason, isNotEmpty);
  });
}
