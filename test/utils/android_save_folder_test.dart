import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/utils/android_save_folder.dart';

/// Where an Android phone saves a backup or a file fetched from a host (found
/// while comparing the five versions, in released versions
/// too): always the shared Download folder, which on Android 8 to 10 takes a
/// permission the app does not ask for, so every backup and download there
/// failed. Now: the Download folder where the app may write there, else the
/// app's own folder on the shared storage, else its documents.
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('zest-app-android-save-test');
    addTearDown(() => temp.delete(recursive: true));
  });

  Directory folder(String name) => Directory('${temp.path}${Platform.pathSeparator}$name')..createSync();

  test('the Download folder where the app may write there, with nothing left of the try', () async {
    final download = folder('Download');
    var ownAsked = false;
    final got = await androidSaveFolder(
      shared: download,
      own: () async {
        ownAsked = true;
        return folder('own');
      },
    );
    expect(got.path, download.path);
    expect(download.listSync(), isEmpty, reason: 'the file it tried with is gone');
    expect(ownAsked, isFalse);
  });

  test("the app's own folder where it may not (Android 8 to 10: no permission), and its documents where there is "
      'no shared storage', () async {
    final notThere = Directory('${temp.path}${Platform.pathSeparator}no-download');
    final own = folder('own');
    final docs = folder('documents');
    Future<Directory> documents() async => docs;

    expect((await androidSaveFolder(shared: notThere, own: () async => own, documents: documents)).path, own.path);
    expect((await androidSaveFolder(shared: notThere, own: () async => null, documents: documents)).path, docs.path);
    expect((await androidSaveFolder(shared: notThere, own: () => throw const FileSystemException('none'), documents: documents))
        .path, docs.path);
    expect(Directory(notThere.path).existsSync(), isFalse, reason: 'nothing is made where it could not write');
  });

  test('backups, automatic ones and those asked for, and files fetched from a host go there on Android', () {
    String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
    expect(read('lib/services/backup_service.dart'),
        contains('    if (Platform.isAndroid) {\n      // The Download folder where Android lets the app write there, else\n'
            '      // the app\'s own folder (androidSaveFolder: Android 8 to 10).\n      return androidSaveFolder();\n'));
    expect(read('lib/services/backup/local_destination.dart'), contains('      dir = await androidSaveFolder();\n'));
    expect(read('lib/ui/screens/sftp/sftp_browser_screen.dart'),
        contains('  Future<Directory> _getDownloadDirectory() => downloadSaveFolder();\n'));
    // (Through downloadSaveFolder now; download_save_folder_test.dart
    // says where each platform saves.)
    expect(read('lib/utils/android_save_folder.dart'),
        contains("  if (system == 'android') return (android ?? androidSaveFolder)();\n"));
    // A download says where it went: Downloads, or the app's own folder by its path (it said Downloads wherever).
    final pane = read('lib/ui/screens/sftp/sftp_browser_screen.dart');
    // (Both messages through _placeName since the 4.0 platform comparison, which names iOS's Documents as the
    // Files app's ZestSSH folder; phone_download_folder_test.dart says what each system's message says.)
    expect(pane, contains('    if (dir.path == androidDownloadFolder) return l10n.sftpPlaceDownloads;\n'));
    expect('final location = _placeName(l10n, dir);'.allMatches(pane), hasLength(2));
    expect(pane, isNot(contains('Platform.isAndroid ? l10n.sftpPlaceDownloads')));
    for (final path in [
      'lib/services/backup_service.dart',
      'lib/services/backup/local_destination.dart',
      'lib/ui/screens/sftp/sftp_browser_screen.dart',
    ]) {
      expect(read(path), isNot(contains("'/storage/emulated/0/Download'")), reason: path);
    }
  });
}
