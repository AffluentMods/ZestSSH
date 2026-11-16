import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/app_instance_lock.dart';

/// A running ZestSSH holds a lock that `zestssh admin ...` finds (found in
/// a review): the command started a whole second app on
/// the same data beside the open one.
void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('zest_instance_lock_');
    AppInstanceLock.folder = () async => dir;
  });
  tearDown(() async {
    await AppInstanceLock.release();
    dir.deleteSync(recursive: true);
  });

  test('the app takes the lock once and holds it', () async {
    expect(await AppInstanceLock.take(), isTrue);
    expect(await AppInstanceLock.take(), isTrue, reason: 'held already in this run');
    expect(File('${dir.path}${Platform.pathSeparator}${AppInstanceLock.fileName}').existsSync(), isTrue);
  });

  test('another process cannot take it while the app holds it, and can once it is let go', () async {
    expect(await AppInstanceLock.take(), isTrue);
    // Another process: a lock taken through a handle of its own (on Windows
    // a lock belongs to its handle, so a second handle stands in for it).
    final other = await File('${dir.path}${Platform.pathSeparator}${AppInstanceLock.fileName}').open(mode: FileMode.append);
    addTearDown(other.close);
    await expectLater(other.lock(FileLock.exclusive), throwsA(isA<FileSystemException>()));
    await AppInstanceLock.release();
    await other.lock(FileLock.exclusive);
    await other.unlock();
  }, skip: Platform.isWindows ? false : 'a lock belongs to the process there, not to the handle');

  test('a folder that cannot hold the lock never stops anything: the answer is no', () async {
    AppInstanceLock.folder = () async => throw const FileSystemException('no folder');
    expect(await AppInstanceLock.take(), isFalse);
  });
}
