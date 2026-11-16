import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/services/sftp_drop_names.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';

/// No two files of one drop are written to one place (found in a security
/// review): two names of a server that come to one local name, in a folder
/// the drop just made (where nothing was looked at) or beside a file that is
/// still on its way (so not on the disk yet), replaced one another with no
/// question.
void main() {
  String join(String dir, String name) => p.windows.join(dir, name);

  /// A destination that holds [held], counting what it was asked.
  (Future<bool> Function(String), List<String>) disk([Set<String> held = const {}]) {
    final asked = <String>[];
    return ((path) async {
      asked.add(path);
      return held.contains(path);
    }, asked);
  }

  test('the names a Windows disk cannot tell apart come to one local name: what the walk has to catch', () {
    expect(safeChildName('a:b', forWindows: true), safeChildName('a_b', forWindows: true));
    expect(safeChildName('x.', forWindows: true), safeChildName('x', forWindows: true));
  });

  test('a second file for a place the drop gave out keeps both, with nothing on the disk yet', () async {
    final names = DropDestinationNames(caseInsensitive: true);
    final (exists, _) = disk();
    expect(await names.claim(r'C:\down\src', 'a_b', join: join, exists: exists), 'a_b');
    expect(names.isTaken(r'C:\down\src\a_b'), isTrue);
    expect(await names.claim(r'C:\down\src', 'a_b', join: join, exists: exists), 'a_b (1)');
    // A third, and one whose own name is the name the second was given.
    expect(await names.claim(r'C:\down\src', 'a_b', join: join, exists: exists), 'a_b (2)');
    expect(await names.claim(r'C:\down\src', 'a_b (1)', join: join, exists: exists), 'a_b (1) (1)');
  });

  test('Makefile and makefile are one place on this computer, and two on a host', () async {
    final (exists, _) = disk();
    final here = DropDestinationNames(caseInsensitive: true);
    expect(await here.claim(r'C:\down', 'Makefile', join: join, exists: exists), 'Makefile');
    expect(here.isTaken(r'C:\down\makefile'), isTrue);
    expect(await here.claim(r'C:\down', 'makefile', join: join, exists: exists), 'makefile (1)');

    final host = DropDestinationNames(caseInsensitive: false);
    String posix(String dir, String name) => p.posix.join(dir, name);
    expect(await host.claim('/srv', 'Makefile', join: posix, exists: exists), 'Makefile');
    expect(host.isTaken('/srv/makefile'), isFalse);
    expect(await host.claim('/srv', 'makefile', join: posix, exists: exists), 'makefile');
  });

  test('the same name in another folder is another place', () async {
    final names = DropDestinationNames(caseInsensitive: true);
    final (exists, _) = disk();
    expect(await names.claim(r'C:\down\a', 'notes.txt', join: join, exists: exists), 'notes.txt');
    expect(await names.claim(r'C:\down\b', 'notes.txt', join: join, exists: exists), 'notes.txt');
  });

  test('the name of its own is one the destination does not hold either', () async {
    final names = DropDestinationNames(caseInsensitive: true);
    final (exists, _) = disk({r'C:\down\report (1).txt'});
    expect(await names.claim(r'C:\down', 'report.txt', join: join, exists: exists), 'report.txt');
    expect(await names.claim(r'C:\down', 'report.txt', join: join, exists: exists), 'report (2).txt');
  });

  test('Keep both, the answer for a file the destination holds, takes a name the drop has not given out', () async {
    final names = DropDestinationNames(caseInsensitive: true);
    final (exists, _) = disk({r'C:\down\report.txt'});
    // Two files of the drop both come to report.txt, which is there already.
    expect(await names.claim(r'C:\down', 'report.txt', join: join, exists: exists, keepBoth: true), 'report (1).txt');
    expect(await names.claim(r'C:\down', 'report.txt', join: join, exists: exists, keepBoth: true), 'report (2).txt');
  });

  test('a first claim asks the destination nothing: a folder the drop just made stays free of round trips',
      () async {
    final names = DropDestinationNames(caseInsensitive: false);
    final (exists, asked) = disk();
    await names.claim('/srv/new', 'a', join: p.posix.join, exists: exists);
    await names.claim('/srv/new', 'b', join: p.posix.join, exists: exists);
    expect(asked, isEmpty);
  });
}
