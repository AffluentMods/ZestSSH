// What a phone hands to the share sheet, and the files it picks to import,
// leave nothing behind (found in a security review of the client,
// in released versions too). An exported private key and its public
// key were written straight into the app's folder of temporary files, under
// a name that can be guessed, and deleted once the sheet closed; the
// snippets and a terminal theme were written there and never deleted; a
// file shared from a host's file pane went through a folder of another
// name; and the copies the file picker made of files picked to import (a
// key, a backup) stayed for good. Now every file handed to the share sheet
// is written into a folder of its own, deleted once the sheet has closed,
// on every system (Android's sheet hands the app chosen a copy of its own,
// which goes an hour later at the next start), and what earlier versions
// left is deleted at start-up, with the file picker's copies.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/utils/leftover_copies.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
  const share = MethodChannel('dev.fluttercommunity.plus/share');
  final sep = Platform.pathSeparator;
  late Directory temp;

  setUp(() async {
    // The app's folder of temporary files, for this test.
    temp = await Directory.systemTemp.createTemp('zestssh_temp_');
    addTearDown(() => temp.delete(recursive: true));
    messenger.setMockMethodCallHandler(pathProvider, (call) async => temp.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
  });

  List<String> left([Directory? folder]) =>
      [for (final entry in (folder ?? temp).listSync()) entry.uri.pathSegments.lastWhere((s) => s.isNotEmpty)]..sort();

  group('a file handed to the share sheet', () {
    test('is written into a folder of its own, said before the sheet opens, and deleted with it once the sheet has '
        'closed', () async {
      final happened = <String>[];
      Map<Object?, Object?>? handed;
      messenger.setMockMethodCallHandler(share, (call) async {
        happened.add('sheet');
        handed = call.arguments as Map<Object?, Object?>;
        // What the sheet is handed is there, as written, while it is open.
        final paths = (handed!['paths'] as List).cast<String>();
        happened.add([for (final path in paths) File(path).readAsStringSync()].join(' | '));
        return 'com.example.mail';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(share, null));

      await ConnectionShareService.shareFiles(
        {'work_id_rsa.pem': 'the private key'.codeUnits, 'work_id_rsa.pub': 'ssh-ed25519 AAAA work'.codeUnits},
        subject: 'SSH Key: work',
        written: () => happened.add('said'),
      );

      expect(happened, ['said', 'sheet', 'the private key | ssh-ed25519 AAAA work']);
      final paths = (handed!['paths'] as List).cast<String>();
      expect(paths.map((path) => path.split(sep).last), ['work_id_rsa.pem', 'work_id_rsa.pub']);
      final folder = File(paths.first).parent;
      expect(folder.parent.path, temp.path);
      expect(folder.path.split(sep).last, startsWith(ConnectionShareService.shareFolderPrefix));
      expect(File(paths.last).parent.path, folder.path, reason: 'the two in one folder');
      expect(handed!['subject'], 'SSH Key: work');
      expect(left(), isEmpty, reason: 'the folder and what it held are deleted once the sheet has closed');
    });

    test('is deleted all the same where the sheet fails (Linux has none), and the failure is thrown', () async {
      var opened = false;
      messenger.setMockMethodCallHandler(share, (call) async {
        opened = true;
        throw PlatformException(code: 'none', message: 'no share sheet here');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(share, null));

      await expectLater(
          ConnectionShareService.shareFiles({'zestssh_snippets.json': '{}'.codeUnits}), throwsA(isA<PlatformException>()));
      expect(opened, isTrue);
      expect(left(), isEmpty);
    });

    test('one that cannot be written: the sheet is not opened, nothing is left, and the failure is thrown', () async {
      var opened = false;
      var said = false;
      messenger.setMockMethodCallHandler(share, (call) async {
        opened = true;
        return 'com.example.mail';
      });
      addTearDown(() => messenger.setMockMethodCallHandler(share, null));

      await expectLater(
          ConnectionShareService.shareFiles({'no folder${sep}theme.zestheme': '{}'.codeUnits}, written: () => said = true),
          throwsA(isA<FileSystemException>()));
      expect(opened, isFalse);
      expect(said, isFalse);
      expect(left(), isEmpty);
    });

    test("is deleted once the sheet has closed on Android too, where the app chosen reads the sheet's own copy",
        () async {
      final folder = await ConnectionShareService.newShareFolder();
      final file = File('${folder.path}${sep}web_01.zest')..writeAsStringSync('{}');
      await ConnectionShareService.removeAfterShare(file.path);
      expect(left(), isEmpty);
    });
  });

  group('what shares left, deleted at start-up', () {
    test("earlier versions' folders a file shared from a host's file pane went through; on a phone, the files they "
        'handed to the sheet straight from the folder; nothing else, and those files not on a computer', () async {
      final fetched = Directory('${temp.path}${sep}zest_share_1729050000')..createSync();
      File('${fetched.path}${sep}backup.tar.gz').writeAsStringSync('a file on a host');
      final handed = ['work_id_rsa.pem', 'work_id_rsa.pub', 'zestssh_snippets.json', 'dracula.zestheme'];
      final kept = ['notes.txt', 'id_rsa.pub', 'zestssh_snippets.json.bak', 'theme.zesthemes'];
      for (final name in [...handed, ...kept]) {
        File('${temp.path}$sep$name').writeAsStringSync('kept?');
      }
      Directory('${temp.path}${sep}zest_shared_photos').createSync();

      // A computer: its folder of temporary files is every program's.
      await ConnectionShareService.removeLeftovers(temp.path, phone: false, android: false);
      expect(left(), [...handed, ...kept, 'zest_shared_photos']..sort());

      // A phone: the folder is the app's own.
      await ConnectionShareService.removeLeftovers(temp.path, phone: true, android: false);
      expect(left(), [...kept, 'zest_shared_photos']..sort());
    });

    test('on Android, the copies the share sheet was handed, once an hour old; the folder once it holds none; and not '
        'elsewhere', () async {
      final copies = Directory('${temp.path}${sep}share_plus')..createSync();
      final now = DateTime.now();
      File('${copies.path}${sep}work_id_rsa.pem')
        ..writeAsStringSync('the private key')
        ..setLastModifiedSync(now.subtract(const Duration(hours: 2)));
      File('${copies.path}${sep}web_01.zest')
        ..writeAsStringSync('{}')
        ..setLastModifiedSync(now.subtract(const Duration(minutes: 20)));

      await ConnectionShareService.removeLeftovers(temp.path, phone: true, android: false, now: now);
      expect(left(copies), ['web_01.zest', 'work_id_rsa.pem'], reason: 'not on an iPhone');

      await ConnectionShareService.removeLeftovers(temp.path, phone: true, android: true, now: now);
      expect(left(copies), ['web_01.zest'], reason: 'the one shared 20 minutes ago may still be being read');

      await ConnectionShareService.removeLeftovers(temp.path,
          phone: true, android: true, now: now.add(const Duration(hours: 1)));
      expect(left(), isEmpty);
    });
  });

  group("the file picker's copies of files picked to import", () {
    test('are cleared on a phone at start-up, not on a computer; a picker that cannot is no failure', () async {
      final picker = _Picker();
      FilePicker.platform = picker;

      await clearPickedCopies(phone: false);
      expect(picker.cleared, 0);
      await clearPickedCopies(phone: true);
      expect(picker.cleared, 1);

      FilePicker.platform = _Picker(fails: true);
      await clearPickedCopies(phone: true);

      final app = File('lib/app.dart').readAsStringSync().replaceAll('\r\n', '\n');
      final cleanup = app.substring(app.indexOf('Future<void> _removeShareLeftovers() async {'));
      expect(cleanup.substring(0, cleanup.indexOf('\n  }\n')), contains('await clearPickedCopies();'));
      expect(app, contains('unawaited(_removeShareLeftovers());'));
    });
  });

  test('every file a phone hands to the share sheet goes through a folder of its own', () {
    String body(String path, String start) {
      final source = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      final from = source.indexOf(start);
      expect(from, isNot(-1), reason: '$start in $path');
      return source.substring(from, source.indexOf('\n  }\n', from));
    }

    final key = body('lib/ui/screens/identity/identity_edit_screen.dart', 'Future<void> _exportPrivateKey() async {');
    expect(key, contains('ConnectionShareService.shareFiles('));
    expect(key, contains('publicKeyLineOf(pem, comment: label)'));
    final snippets = body('lib/ui/screens/snippets/snippets_screen.dart', 'Future<void> _exportSnippets() async {');
    expect(snippets, contains('ConnectionShareService.shareFiles('));
    expect(snippets, contains('l10n.snippetsExportedChooseTarget(snippets.length)'));
    final theme = body('lib/ui/screens/settings/appearance_screen.dart', 'Future<void> _exportCurrentTheme() async {');
    expect(theme, contains('ConnectionShareService.shareFiles('));
    expect(theme, contains('l10n.appearanceThemeNotExported, isError: true'));
    final fetched =
        body('lib/ui/screens/sftp/sftp_browser_screen.dart', 'Future<void> _downloadAndShareFile(SftpEntry entry) async {');
    expect(fetched, contains('shareDir = await ConnectionShareService.newShareFolder();'));
    expect(fetched, contains('if (shareDir != null && await shareDir.exists()) await shareDir.delete(recursive: true);'));

    // And nothing else in the app writes a file for the sheet into the folder of temporary files: the share sheet
    // is opened by these alone.
    final opened = <String>[
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && file.readAsStringSync().contains('Share.shareXFiles('))
          file.path.replaceAll(r'\', '/'),
    ]..sort();
    expect(opened, [
      'lib/features/hosts/host_share_file.dart',
      'lib/services/connection_share_service.dart',
      'lib/ui/screens/settings/session_logs_screen.dart',
      'lib/ui/screens/settings/ssh_config_export.dart',
      'lib/ui/screens/sftp/sftp_browser_screen.dart',
    ]);
  });
}

/// A file picker that counts how often it is asked to clear its copies, or
/// cannot.
class _Picker extends FilePicker {
  _Picker({this.fails = false});

  final bool fails;
  var cleared = 0;

  @override
  Future<bool?> clearTemporaryFiles() async {
    if (fails) throw PlatformException(code: 'clear', message: 'cannot');
    cleared++;
    return true;
  }
}
