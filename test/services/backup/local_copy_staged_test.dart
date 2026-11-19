import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/backup/local_destination.dart';

/// A backup made on this device is copied into its folder. The copy went
/// straight to the backup's own name: one that broke off (the app ended, the
/// disk filled) left a short file under that name, listed and offered to
/// restore from as any other. It now goes beside the name and is put under it
/// only when all of it is there.
void main() {
  late Directory folder;
  late Directory elsewhere;
  late File made;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('zest-backups-');
    elsewhere = Directory.systemTemp.createTempSync('zest-made-');
    made = File('${elsewhere.path}/new.zest')..writeAsBytesSync(List<int>.generate(4096, (i) => i % 251));
  });

  tearDown(() {
    folder.deleteSync(recursive: true);
    elsewhere.deleteSync(recursive: true);
  });

  List<String> inFolder() => [for (final f in folder.listSync()) f.uri.pathSegments.last]..sort();

  test('a whole copy is under the backup\'s name, with nothing left beside it', () async {
    final local = LocalBackupDestination(folder: () async => folder);
    await local.uploadBackup(made, 'zestssh-1.zest');
    expect(inFolder(), ['zestssh-1.zest']);
    expect(File('${folder.path}/zestssh-1.zest').readAsBytesSync(), made.readAsBytesSync());
    expect((await local.listBackups()).map((b) => (b.filename, b.sizeBytes)), [('zestssh-1.zest', 4096)]);
  });

  test('a copy that breaks off leaves no backup of that name, and nothing that is listed', () async {
    final local = LocalBackupDestination(
      folder: () async => folder,
      copy: (from, to) async {
        // Half of it is written, then the disk is full.
        File(to).writeAsBytesSync(from.readAsBytesSync().sublist(0, 2048));
        throw const FileSystemException('No space left on device');
      },
    );
    await expectLater(local.uploadBackup(made, 'zestssh-1.zest'), throwsA(isA<FileSystemException>()));
    expect(inFolder(), isEmpty);
    expect(await local.listBackups(), isEmpty);
  });

  test('a copy that ends short without an error is not a backup either', () async {
    final local = LocalBackupDestination(
      folder: () async => folder,
      copy: (from, to) async => File(to)..writeAsBytesSync(from.readAsBytesSync().sublist(0, 100)),
    );
    await expectLater(local.uploadBackup(made, 'zestssh-1.zest'), throwsA(isA<FileSystemException>()));
    expect(await local.listBackups(), isEmpty);
    expect(inFolder(), isEmpty);
  });

  test('the app ended in the middle of a copy: what it left is not listed, and the next backup clears it', () async {
    // As a copy that was never finished leaves it.
    File('${folder.path}/zestssh-1.zest.part').writeAsBytesSync(List.filled(1000, 7));
    final local = LocalBackupDestination(folder: () async => folder);
    expect(await local.listBackups(), isEmpty, reason: 'not offered to restore from');
    await local.uploadBackup(made, 'zestssh-1.zest');
    expect(inFolder(), ['zestssh-1.zest']);
    expect(File('${folder.path}/zestssh-1.zest').lengthSync(), 4096);
  });

  test('a backup made again under a name that is there takes its place whole, and stays where a copy fails', () async {
    final good = LocalBackupDestination(folder: () async => folder);
    await good.uploadBackup(made, 'zestssh-1.zest');
    final failing = LocalBackupDestination(
      folder: () async => folder,
      copy: (from, to) async {
        File(to).writeAsBytesSync(const [1, 2, 3]);
        throw const FileSystemException('The device is not ready');
      },
    );
    made.writeAsBytesSync(List.filled(9000, 9));
    await expectLater(failing.uploadBackup(made, 'zestssh-1.zest'), throwsA(isA<FileSystemException>()));
    expect(File('${folder.path}/zestssh-1.zest').lengthSync(), 4096, reason: 'the backup that was there is whole');
    await good.uploadBackup(made, 'zestssh-1.zest');
    expect(File('${folder.path}/zestssh-1.zest').lengthSync(), 9000);
    expect(inFolder(), ['zestssh-1.zest']);
  });
}
