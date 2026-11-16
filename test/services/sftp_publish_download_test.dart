import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';

/// A staged file whose rename fails, as one held by another program does.
class _Held implements File {
  _Held(this.path);

  @override
  final String path;

  @override
  Future<File> rename(String newPath) async => throw FileSystemException('held by another program', path);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not in this test');
}

/// A finished download is put in place in one step (found in security
/// reviews). The old file was
/// deleted first and the new one renamed after: when the rename failed, the
/// person's file was gone and the download sat under its staging name.
void main() {
  late Directory folder;
  setUp(() => folder = Directory.systemTemp.createTempSync('zest_publish_'));
  tearDown(() => folder.deleteSync(recursive: true));

  test('the new file takes the name, and what was there is replaced', () async {
    final staged = File('${folder.path}/report.pdf.zestpart')..writeAsStringSync('the new one');
    final destination = File('${folder.path}/report.pdf')..writeAsStringSync('the old one');
    await publishDownload(staged, destination);
    expect(destination.readAsStringSync(), 'the new one');
    expect(staged.existsSync(), isFalse);
    expect(folder.listSync(), hasLength(1));
  });

  test('where nothing was there, the new file is simply there', () async {
    final staged = File('${folder.path}/notes.txt.zestpart')..writeAsStringSync('new');
    final destination = File('${folder.path}/notes.txt');
    await publishDownload(staged, destination);
    expect(destination.readAsStringSync(), 'new');
  });

  test('when the rename fails, the old file is still there as it was', () async {
    final destination = File('${folder.path}/report.pdf')..writeAsStringSync('the old one');
    await expectLater(
      publishDownload(_Held('${folder.path}/report.pdf.zestpart'), destination),
      throwsA(isA<FileSystemException>()),
    );
    expect(destination.existsSync(), isTrue, reason: 'it was deleted before the rename was tried');
    expect(destination.readAsStringSync(), 'the old one');
  });
}
