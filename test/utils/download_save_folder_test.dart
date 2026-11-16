import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/android_save_folder.dart';

/// Where the file browser's plain Download saves (found in a review).
/// On iOS getDownloadsDirectory names `<container>/Downloads`, which the
/// system never makes and Files does not show; it is never null there, so
/// the Documents fallback never ran.
void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('zest_dl_'));
  tearDown(() => root.deleteSync(recursive: true));

  Future<Directory> folder(String os) => downloadSaveFolder(
        os: os,
        android: () async => Directory('${root.path}/android'),
        downloads: () async => Directory('${root.path}/Downloads'),
        documents: () async => Directory('${root.path}/Documents'),
      );

  test('an iPhone or iPad saves to Documents, which Files shows, made when it is not there', () async {
    final dir = await folder('ios');
    expect(dir.path, '${root.path}/Documents');
    expect(dir.existsSync(), isTrue);
  });

  test('a computer saves to its Downloads folder; Android to its own save folder', () async {
    expect((await folder('windows')).path, '${root.path}/Downloads');
    expect((await folder('macos')).path, '${root.path}/Downloads');
    expect((await folder('linux')).existsSync(), isTrue);
    expect((await folder('android')).path, '${root.path}/android');
  });

  test('a computer with no Downloads folder saves to the documents', () async {
    final dir = await downloadSaveFolder(
      os: 'linux',
      downloads: () async => null,
      documents: () async => Directory('${root.path}/Documents'),
    );
    expect(dir.path, '${root.path}/Documents');
  });
}
