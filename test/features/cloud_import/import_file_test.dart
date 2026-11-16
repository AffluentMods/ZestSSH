import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/features/cloud_import/csv/other_app_hosts.dart';
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/hosts/host_share_file.dart' show importHostShareFile;
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/key_generation_service.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/screens/import/ssh_config_import_screen.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../visual/shots_util.dart';

/// Import a file: one action, which says what it
/// found and lets the person correct it, with the app tiles below as they
/// were; and an importer picked by hand that gets another kind of file says so
/// and offers the right one, reading nothing of it.

final l10n = lookupAppLocalizations(const Locale('en'));

const _privateKey = '-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n';
const _publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemo demo@example.com\n';
const _knownHosts = 'web1.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n';
const _sshConfig = 'Host web1\n  HostName 203.0.113.10\n  User deploy\n\nHost db\n  HostName db.example.com\n';
const _csv = 'name,host,user\nWeb,203.0.113.10,deploy\nDb,203.0.113.11,deploy\n';
// (Whole as far as can be told without its password: since 3.4.2 one shorter is said
// to be cut short before its password is asked.)
final _backup = [...utf8.encode('ZEST'), 3, 0, 2, ...utf8.encode('{}'), ...List.filled(60, 0)];
const _moba = '[Bookmarks]\nSubRep=\nImgNum=42\nweb1=#109#0%203.0.113.10%22%deploy%%-1%-1%\n';

/// A key made for this test, with the passphrase [_demoPassphrase]: it opens nothing.
const _encryptedKey = '''-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAACmFlczI1Ni1jdHIAAAAGYmNyeXB0AAAAGAAAABCL8wTMH8
vRYYkl+Nw7aNqrAAAAEAAAAAEAAAAzAAAAC3NzaC1lZDI1NTE5AAAAIDPJ8PTd0sTg/ymg
QBpy/+Ed3eCIWo0Auo3JLRz2Xq7fAAAAoIL4EUF5rxn/FRvy+zjJzsdTFYkSGuI6C8teDu
1QaeXKXM2nXsJ5ESgWMWK69G3ekDAQuNtrbI3YkdVFAqgQJDc+dOrKQtkmuLCANEGPmytV
r9yAcC8GcKcSEE54xQICP4cLIJ3Tq3KZ3aUJudiogMJEUrjsGAbj8ckchgLcuaeyR75mEw
de+/cZH5OaIz7ohTo5RLqbSAm8/DsVbGXIu5Y=
-----END OPENSSH PRIVATE KEY-----
''';
const _demoPassphrase = 'demo-passphrase';

class _Picker extends FilePicker {
  _Picker(this.path);

  final String path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = true,
    int compressionQuality = 30,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async =>
      FilePickerResult([PlatformFile(path: path, name: 'picked', size: 0)]);
}

class _NoOrchards implements OrchardDatabaseStorage {
  @override
  Future<bool> exists(String orchardId) async => false;

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async => throw StateError('no Orchard here');

  @override
  Future<void> delete(String orchardId) async {}

  @override
  Future<List<String>> list() async => const [];
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  Future<SharedPreferences> prefs() async {
    SharedPreferences.setMockInitialValues(const {});
    return SharedPreferences.getInstance();
  }

  Widget app(SharedPreferences p, Widget Function(BuildContext) child, {bool recording = false}) => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(p),
          recordingModeProvider.overrideWith((ref) => recording),
          databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
          orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: Builder(builder: child)),
        ),
      );

  group('Import a file', () {
    late ImportHostsResult? result;

    Future<void> open(WidgetTester tester, ImportFile? Function() file, {bool recording = false}) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      result = null;
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () async {
            result = await showZestModal<ImportHostsResult>(
              context: context,
              size: ZestModalSize.large,
              child: ImportHostsDialog(pickFile: () async => file()),
            );
          },
          child: const Text('open'),
        ),
        recording: recording,
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('import-file')));
      await tester.pumpAndSettle();
    }

    ImportFile fileOf(String name, List<int> bytes, {String? path}) =>
        importFileOf(name: name, path: path ?? '/demo/$name', bytes: bytes);

    Finder k(String key) => find.byKey(ValueKey(key));

    testWidgets('the one action is above the app tiles, which stay', (tester) async {
      await open(tester, () => null);
      expect(k('import-found'), findsNothing, reason: 'nothing was chosen');
      final action = tester.getTopLeft(k('import-file')).dy;
      for (final tile in ['file-source-ssh-config', 'file-source-mobaxterm', 'file-source-securecrt', 'file-source-zest', 'file-source-csv']) {
        expect(tester.getTopLeft(k(tile)).dy, greaterThan(action), reason: tile);
      }
    });

    final found = <String, (List<int>, ImportKind, String)>{
      'a backup': (_backup, ImportKind.zestBackup, l10n.importFoundBackup),
      'an SSH config': (utf8.encode(_sshConfig), ImportKind.sshConfig, l10n.importFoundSshConfig),
      'a CSV file': (utf8.encode(_csv), ImportKind.csv, l10n.importFoundCsv),
      'a MobaXterm export': (utf8.encode(_moba), ImportKind.mobaxterm, l10n.importFoundMoba),
    };
    for (final MapEntry(key: name, value: (bytes, kind, words)) in found.entries) {
      testWidgets('$name: says so, by the file\'s name, and Import it hands it to its import', (tester) async {
        await open(tester, () => fileOf('some.file', bytes));
        expect(find.text(words), findsOneWidget);
        expect(find.text('some.file'), findsOneWidget);
        await tester.tap(k('import-found-go'));
        await tester.pumpAndSettle();
        final r = result! as ImportFromFile;
        expect(r.kind, kind);
        expect(r.file.name, 'some.file');
      });
    }

    testWidgets('what it found can be corrected: the file goes as what the person says', (tester) async {
      await open(tester, () => fileOf('hosts.txt', utf8.encode(_csv)));
      expect(find.text(l10n.importFoundCsv), findsOneWidget);
      await tester.tap(k('import-found-as'));
      await tester.pumpAndSettle();
      await tester.tap(k('zest-select-item-${ImportKind.secureCrt}'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.importFoundCrt), findsOneWidget);
      await tester.tap(k('import-found-go'));
      await tester.pumpAndSettle();
      expect((result! as ImportFromFile).kind, ImportKind.secureCrt);
    });

    testWidgets('could not tell: said, with the file\'s name, and asks which app; nothing goes until it is chosen', (tester) async {
      await open(tester, () => fileOf('notes.txt', utf8.encode('Dear team,\nplease find attached.\n')));
      expect(find.text(l10n.importFoundUnknown), findsOneWidget);
      expect(find.text(l10n.importFoundUnknownBody), findsOneWidget);
      final go = tester.widget(k('import-found-go')) as dynamic;
      expect(go.onPressed, isNull);
      await tester.tap(k('import-found-as'));
      await tester.pumpAndSettle();
      // The names of what it can be read as.
      for (final kind in kImportKindsToChoose) {
        expect(find.descendant(of: k('zest-select-item-$kind'), matching: find.text(importKindName(kind, l10n))), findsOneWidget);
      }
      await tester.tap(k('zest-select-item-${ImportKind.csv}'));
      await tester.pumpAndSettle();
      await tester.tap(k('import-found-go'));
      await tester.pumpAndSettle();
      expect((result! as ImportFromFile).kind, ImportKind.csv);
    });

    testWidgets('a private key with more besides: It is something else is there, and what it is said to be goes on', (tester) async {
      final mixed = utf8.encode('$_privateKey\nHost web1\n  HostName 203.0.113.10\n');
      await open(tester, () => fileOf('notes.txt', mixed));
      expect(find.text(l10n.importFoundKey), findsOneWidget);
      await tester.tap(k('import-found-as'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('zest-select-item-${ImportKind.sshConfig}')).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.importFoundSshConfig), findsOneWidget);
      await tester.tap(k('import-found-go'));
      await tester.pumpAndSettle();
      final r = result! as ImportFromFile;
      expect(r.kind, ImportKind.sshConfig);
      expect(r.file.bytes, isNull, reason: 'read when it goes on');
    });

    testWidgets('a private key: offered for Keys, its contents kept nowhere, and nothing else may read it', (tester) async {
      await open(tester, () => fileOf('id_ed25519', utf8.encode(_privateKey)));
      expect(find.text(l10n.importFoundKey), findsOneWidget);
      expect(k('import-found-as'), findsNothing, reason: 'nothing else reads a private key');
      await tester.tap(k('import-found-go'));
      await tester.pumpAndSettle();
      final r = result! as ImportFromFile;
      expect(r.kind, ImportKind.privateKey);
      expect(r.file.bytes, isNull);
    });

    testWidgets('a public key: what it is, and Keys; nothing to import', (tester) async {
      await open(tester, () => fileOf('id_ed25519.pub', utf8.encode(_publicKey)));
      expect(find.text(l10n.importFoundPublicKey), findsOneWidget);
      expect(k('import-found-keys'), findsOneWidget);
      expect(k('import-found-go'), findsNothing);
    });

    testWidgets('known_hosts: what it is, and that ZestSSH keeps its own: nothing to import', (tester) async {
      await open(tester, () => fileOf('known_hosts', utf8.encode(_knownHosts)));
      expect(find.text(l10n.importFoundKnownHosts), findsOneWidget);
      expect(k('import-found-go'), findsNothing);
      expect(k('import-found-keys'), findsNothing);
      // Closed, the tiles are still there to choose from.
      await tester.tap(k('import-found-close'));
      await tester.pumpAndSettle();
      expect(k('import-found'), findsNothing);
    });

    testWidgets('a file that cannot be read: said, with its details, and the dialog stays', (tester) async {
      await open(tester, () => throw const FileSystemException('The process cannot access the file'));
      expect(find.text(l10n.csvImpUnreadable), findsOneWidget);
      expect(find.text(l10n.desktopShellCopyDetails), findsOneWidget);
      expect(k('import-file'), findsOneWidget);
    });

    testWidgets('while the screen is recorded the file\'s name is masked', (tester) async {
      Redactor.instance.enabled = true;
      addTearDown(() => Redactor.instance.enabled = false);
      await open(tester, () => fileOf('acme-prod-hosts.csv', utf8.encode(_csv)), recording: true);
      expect(find.text(l10n.importFoundCsv), findsOneWidget);
      expect(find.text('acme-prod-hosts.csv'), findsNothing);
      expect(find.text(Redactor.path('acme-prod-hosts.csv')), findsOneWidget);
    });

    testWidgets('layout with the real fonts: it fits, a long name too', (tester) async {
      await tester.runAsync(loadShotFonts);
      await open(tester, () => fileOf('${'a-very-long-export-name-' * 6}.txt', utf8.encode('nothing of ours\n')));
      expect(tester.takeException(), isNull);
      expect(k('import-found'), findsOneWidget);
    });
  });

  group('the host file import, given another kind of file', () {
    Future<void> open(WidgetTester tester, HostFileKind kind, List<int> bytes, {String? path}) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => showZestModal<CsvImportResult>(
            context: context,
            size: ZestModalSize.large,
            child: CsvImportDialog(
              kind: kind,
              pickedPath: path,
              pickFile: () async => (name: 'chosen.file', bytes: bytes),
            ),
          ),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('csv-choose')));
      await tester.pumpAndSettle();
    }

    testWidgets('a backup chosen as CSV: says so, reads nothing, and offers the right import', (tester) async {
      await open(tester, HostFileKind.csv, _backup, path: '/demo/backup.zest');
      expect(find.text(l10n.importWrongTitle(l10n.cloudImpCsv)), findsOneWidget);
      expect(find.text(l10n.importFoundBackup), findsOneWidget);
      expect(find.text(l10n.importItAction), findsOneWidget);
      expect(find.byKey(const ValueKey('csv-problem')), findsNothing);
      // Declined: back where it was, nothing read.
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('csv-choose')), findsOneWidget);
    });

    testWidgets('a private key chosen as SecureCRT: said, and nothing of it is read as hosts', (tester) async {
      await open(tester, HostFileKind.securecrt, utf8.encode(_privateKey), path: '/demo/id_ed25519');
      expect(find.text(l10n.importWrongTitle('SecureCRT')), findsOneWidget);
      expect(find.text(l10n.importFoundKey), findsOneWidget);
      expect(find.textContaining('BEGIN OPENSSH'), findsNothing);
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('csv-found')), findsNothing, reason: 'read as nothing');
    });

    testWidgets('known_hosts chosen as CSV: what it is, and only Close', (tester) async {
      await open(tester, HostFileKind.csv, utf8.encode(_knownHosts));
      expect(find.text(l10n.importFoundKnownHosts), findsOneWidget);
      expect(find.text(l10n.importItAction), findsNothing);
      expect(find.text(l10n.close), findsWidgets);
    });

    testWidgets('another app\'s file: read as what it is, and said', (tester) async {
      await open(tester, HostFileKind.securecrt, utf8.encode(_moba));
      expect(find.text(l10n.importReadAsOther('MobaXterm', 'SecureCRT')), findsOneWidget);
      expect(find.text(l10n.migrateTitle('MobaXterm')), findsOneWidget);
      expect(find.textContaining('web1'), findsWidgets);
    });

    testWidgets('a .reg file from PuTTY, chosen as CSV: its sessions, ready to import, with Compatibility mode on offer', (tester) async {
      await open(tester, HostFileKind.csv, utf8.encode(r'''
Windows Registry Editor Version 5.00

[HKEY_CURRENT_USER\Software\SimonTatham\PuTTY\Sessions\web1]
"HostName"="203.0.113.10"
"UserName"="deploy"
"PortNumber"=dword:00000016
'''));
      expect(find.text(l10n.migrateTitle('PuTTY')), findsOneWidget);
      expect(find.text(l10n.csvImpFound(1, 0, 0)), findsOneWidget);
      expect(find.byKey(const ValueKey('csv-compatibility')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('csv-compatibility')));
      await tester.pump();
      await tester.tap(find.text(l10n.cloudImpImportN(1)));
      await tester.pumpAndSettle();
      final host = (await db.connectionsDao.getAll()).single;
      expect((host.label, host.host, host.compatibilityMode), ('web1', '203.0.113.10', true));
    });

    testWidgets('a file with no host column in it says what it says, as before', (tester) async {
      await open(tester, HostFileKind.csv, utf8.encode('fruit,colour\napple,green\n'));
      expect(find.text(l10n.csvImpNoHostColumn), findsOneWidget);
    });

    testWidgets('a file handed in from Import a file is read at once', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => showCsvImport(context, kind: HostFileKind.csv, picked: (name: 'hosts.csv', bytes: utf8.encode(_csv))),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.csvImpFound(2, 0, 0)), findsOneWidget);
      expect(find.byKey(const ValueKey('csv-choose')), findsNothing);
    });
  });

  group('the SSH config import', () {
    testWidgets('a file handed in from Import a file: its hosts at once, with Compatibility mode on offer', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => showDesktopSshConfigImport(context, file: importFileOf(name: 'c', path: '/demo/c', bytes: utf8.encode(_sshConfig))),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.sshImportHostsFound(2).toUpperCase()), findsOneWidget);
      expect(find.byKey(const ValueKey('ssh-import-compatibility')), findsOneWidget);
    });

    /// The dialog, handed [file].
    Future<void> handed(WidgetTester tester, ImportFile file) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(onPressed: () => showDesktopSshConfigImport(context, file: file), child: const Text('open')),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// A phone's screen, handed [file].
    Future<void> handedPhone(WidgetTester tester, ImportFile? file) async {
      tester.view.physicalSize = const Size(600, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SshConfigImportScreen(file: file))),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    /// Until [found] shows, for what is read on another isolate, off the test's clock.
    Future<void> away(WidgetTester tester, Finder found) async {
      for (var i = 0; i < 500 && found.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(found, findsWidgets);
      await tester.pumpAndSettle();
    }

    final tooLarge = [...utf8.encode('Host web\n'), ...List.filled(kCsvMaxBytes, 0x20)];
    final tooMany = utf8.encode('Host ${List.generate(kCsvMaxHosts + 1, (i) => 'web$i').join(' ')}\n');

    group('Paste from clipboard: what it is first, at every size', () {
      void clipboardHolds(WidgetTester tester, String text) {
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.getData') return {'text': text};
          return null;
        });
        addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      }

      String field(WidgetTester tester) => tester.widget<EditableText>(find.byType(EditableText).first).controller.text;

      for (final (name, key) in [
        ('a private key', _privateKey),
        ('SSH.com\'s form of one', '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n'),
      ]) {
        testWidgets('$name on a computer: never in the field, not for a moment', (tester) async {
          clipboardHolds(tester, key);
          await handed(tester, importFileOf(name: 'c', bytes: utf8.encode('Host a\n')));
          await tester.tap(find.text(l10n.sshImportChooseAnother));
          await tester.pumpAndSettle();
          final before = field(tester);
          await tester.tap(find.text(l10n.sshImportPasteFromClipboard));
          await tester.pumpAndSettle();
          expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsOneWidget);
          expect(find.text(l10n.importPastedOther), findsOneWidget);
          expect(field(tester), before);
          expect(find.textContaining('PRIVATE KEY'), findsNothing);
          await tester.tap(find.text(l10n.close).last);
          await tester.pumpAndSettle();
          expect(field(tester), before);
        });

        testWidgets('$name on a phone: the same', (tester) async {
          clipboardHolds(tester, key);
          await handedPhone(tester, null);
          await tester.tap(find.text(l10n.sshImportPasteFromClipboard));
          await tester.pumpAndSettle();
          expect(find.text(l10n.importPastedOther), findsOneWidget);
          expect(field(tester), isEmpty);
          expect(find.textContaining('PRIVATE KEY'), findsNothing);
        });
      }

      testWidgets('a config stays in this importer, in the field to look over', (tester) async {
        clipboardHolds(tester, _sshConfig);
        await handed(tester, importFileOf(name: 'c', bytes: utf8.encode('Host a\n')));
        await tester.tap(find.text(l10n.sshImportChooseAnother));
        await tester.pumpAndSettle();
        await tester.tap(find.text(l10n.sshImportPasteFromClipboard));
        await tester.pumpAndSettle();
        expect(field(tester), _sshConfig);
        expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsNothing);
      });

      testWidgets('and on a phone', (tester) async {
        clipboardHolds(tester, _sshConfig);
        await handedPhone(tester, null);
        await tester.tap(find.text(l10n.sshImportPasteFromClipboard));
        await tester.pumpAndSettle();
        expect(field(tester), _sshConfig);
      });

      testWidgets('what it could not tell stays too: a person may be part way through typing a config', (tester) async {
        clipboardHolds(tester, 'web1\n');
        await handedPhone(tester, null);
        await tester.tap(find.text(l10n.sshImportPasteFromClipboard));
        await tester.pumpAndSettle();
        expect(field(tester), 'web1\n');
      });
    });

    group('a config of thousands', () {
      String names(String name) => 'Host ${List.filled(5000, name).join(' ')}\n  HostName b.example.com\n';

      testWidgets('10 KB of names: only the rows on screen are built, however many are ticked', (tester) async {
        final config = names('a');
        expect(config.length, lessThan(kImportHereBytes));
        await handed(tester, importFileOf(name: 'c', bytes: utf8.encode(config)));
        expect(find.text(l10n.sshImportHostsFound(5000).toUpperCase()), findsOneWidget);
        expect(find.byType(Checkbox, skipOffstage: false).evaluate().length, lessThan(30));
        expect(find.text(l10n.sshImportButtonCount(5000)), findsOneWidget);
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        expect(find.text(l10n.sshImportButtonCount(4999)), findsOneWidget);
        // The last of them is there to get to.
        await tester.drag(find.byKey(const ValueKey('ssh-import-rows')), const Offset(0, -400000));
        await tester.pumpAndSettle();
        expect(find.byType(Checkbox, skipOffstage: false).evaluate().length, lessThan(30));
        await tester.tap(find.byType(Checkbox).first);
        await tester.pump();
        expect(find.text(l10n.sshImportButtonCount(4998)), findsOneWidget);
      });

      testWidgets('thousands left out: the same', (tester) async {
        await handed(tester, importFileOf(name: 'c', bytes: utf8.encode('Host ${List.filled(5000, 'a/b').join(' ')}\n')));
        expect(find.text(l10n.sshImportReviewSkipped(5000).toUpperCase()), findsOneWidget);
        expect(find.byIcon(LucideIcons.minusCircle, skipOffstage: false).evaluate().length, lessThan(30));
      });

      testWidgets('a few: all of them shown at once, with nothing to scroll in the real fonts', (tester) async {
        await tester.runAsync(loadShotFonts);
        await handed(tester, importFileOf(name: 'c', bytes: utf8.encode('Host a b c d\n  HostName b.example.com\n  User deploy\n')));
        final list = tester.widget<ListView>(find.byKey(const ValueKey('ssh-import-rows')));
        expect(list.semanticChildCount, 4);
        expect(find.byType(Checkbox).evaluate().length, greaterThanOrEqualTo(4));
        final position = tester.state<ScrollableState>(find.descendant(of: find.byKey(const ValueKey('ssh-import-rows')), matching: find.byType(Scrollable))).position;
        expect(position.maxScrollExtent, 0);
      });
    });

    testWidgets('a config larger than a host file may be: said as that (it was cut, and nothing said)', (tester) async {
      await handed(tester, importFileOf(name: 'c', bytes: tooLarge));
      expect(find.text(l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024))), findsOneWidget);
      expect(find.text(l10n.sshImportHostsFound(1).toUpperCase()), findsNothing);
    });

    testWidgets('and on a phone', (tester) async {
      await handedPhone(tester, importFileOf(name: 'c', bytes: tooLarge));
      expect(find.text(l10n.csvImpTooLarge(kCsvMaxBytes ~/ (1024 * 1024))), findsOneWidget);
    });

    testWidgets('more hosts than are read: as many as are, and said', (tester) async {
      await handed(tester, await tester.runAsync(() => importFileAway(name: 'c', bytes: tooMany)) as ImportFile);
      await away(tester, find.byKey(const ValueKey('ssh-import-cut')));
      expect(find.text(l10n.csvImpCut(kCsvMaxHosts)), findsOneWidget);
      expect(find.text(l10n.sshImportHostsFound(kCsvMaxHosts).toUpperCase()), findsOneWidget);
    });

    testWidgets('and on a phone', (tester) async {
      await handedPhone(tester, await tester.runAsync(() => importFileAway(name: 'c', bytes: tooMany)) as ImportFile);
      await away(tester, find.byKey(const ValueKey('ssh-import-cut')));
      expect(find.text(l10n.csvImpCut(kCsvMaxHosts)), findsOneWidget);
    });

    testWidgets('typed into the field, however much: read away from the screen, the same as a file', (tester) async {
      await handed(tester, importFileOf(name: 'c', bytes: utf8.encode('Host a\n')));
      await tester.tap(find.text(l10n.sshImportChooseAnother));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Host web\n  HostName web.example.com\n${'# a comment\n' * 10000}');
      await tester.pump();
      debugImportWorkHere = 0;
      await tester.tap(find.text(l10n.sshImportParseConfig).last);
      await away(tester, find.text(l10n.sshImportHostsFound(1).toUpperCase()));
      expect(debugImportWorkHere, 0, reason: 'it ran on the screen\'s thread');
    });

    testWidgets('and on a phone', (tester) async {
      await handedPhone(tester, null);
      await tester.enterText(find.byType(TextField).first, 'Host web\n  HostName web.example.com\n${'# a comment\n' * 10000}');
      await tester.pump();
      debugImportWorkHere = 0;
      await tester.tap(find.text(l10n.sshImportParseConfig).last);
      await away(tester, find.text(l10n.sshImportHostsFound(1)));
      expect(debugImportWorkHere, 0, reason: 'it ran on the screen\'s thread');
    });

    testWidgets('what is large is never laid out in the field', (tester) async {
      final config = utf8.encode('Host web\n  HostName web.example.com\n${'# a comment\n' * 10000}');
      await handed(tester, await tester.runAsync(() => importFileAway(name: 'c', bytes: config)) as ImportFile);
      await away(tester, find.text(l10n.sshImportHostsFound(1).toUpperCase()));
      await tester.tap(find.text(l10n.sshImportChooseAnother));
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, isEmpty);
    });

    testWidgets('SSH.com\'s form of a private key, picked as a config: said, and none of it in the field', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => showDesktopSshConfigImport(context, file: importFileOf(name: 'c', bytes: utf8.encode('Host a\n'))),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.sshImportChooseAnother));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first,
          '---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nComment: "demo"\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n');
      await tester.pump();
      await tester.tap(find.text(l10n.sshImportParseConfig).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsOneWidget);
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, isEmpty);
    });

    testWidgets('a private key pasted: said, and it does not stay in the field', (tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      // (Handed a file, so as not to look for this computer's own config.)
      await tester.pumpWidget(app(
        p,
        (context) => TextButton(
          onPressed: () => showDesktopSshConfigImport(context, file: importFileOf(name: 'c', bytes: utf8.encode('Host a\n'))),
          child: const Text('open'),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.sshImportChooseAnother));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, _privateKey);
      await tester.pump();
      await tester.tap(find.text(l10n.sshImportParseConfig).last);
      await tester.pumpAndSettle();
      expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsOneWidget);
      expect(find.text(l10n.importPastedOther), findsOneWidget);
      await tester.tap(find.text(l10n.close).last);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(find.byType(EditableText).first).controller.text, isEmpty);
    });
  });

  group('where a file goes', () {
    late Directory dir;

    setUp(() async => dir = await Directory.systemTemp.createTemp('zest_import_file_'));
    tearDown(() => dir.delete(recursive: true));

    String write(String name, List<int> bytes) {
      final path = '${dir.path}${Platform.pathSeparator}$name';
      File(path).writeAsBytesSync(bytes);
      return path;
    }

    /// Real files are read off the test's clock.
    Future<void> until(WidgetTester tester, Finder found) async {
      for (var i = 0; i < 200 && found.evaluate().isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(found, findsWidgets);
    }

    /// Waits until a computer's notification center was told [words]. A
    /// message with details has Copy details beside it.
    Future<AppNotification> told(WidgetTester tester, String words) async {
      AppNotification? found() {
        final all = ProviderScope.containerOf(tester.element(find.text('open'))).read(notificationCenterProvider).history;
        return all.where((n) => '${n.title} ${n.body ?? ''}'.contains(words)).firstOrNull;
      }

      for (var i = 0; i < 200 && found() == null; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump();
      }
      expect(found(), isNotNull, reason: words);
      return found()!;
    }

    Future<void> open(WidgetTester tester, Future<void> Function(BuildContext) go) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final p = await prefs();
      await tester.pumpWidget(app(p, (context) => TextButton(onPressed: () => go(context), child: const Text('open'))));
      await tester.tap(find.text('open'));
    }

    testWidgets('a file dropped on Import a file, on a computer: read, and what it is said', (tester) async {
      final path = write('northwind.zest', _backup);
      await open(tester, (context) => showZestModal<ImportHostsResult>(context: context, size: ZestModalSize.large, child: const ImportHostsDialog()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('import-found')), findsNothing);
      final drop = tester.widget<DropTarget>(find.byType(DropTarget));
      drop.onDragDone!(DropDoneDetails(files: [DropItemFile(path)], localPosition: Offset.zero, globalPosition: Offset.zero));
      await until(tester, find.byKey(const ValueKey('import-found')));
      expect(find.text(l10n.importFoundBackup), findsOneWidget);
      expect(find.text('northwind.zest'), findsOneWidget);
    });

    testWidgets('SSH config chosen and a .zest picked: it says what it is, and the restore takes it from there', (tester) async {
      FilePicker.platform = _Picker(write('northwind.zest', _backup));
      await open(tester, (context) => showDesktopSshConfigImport(context, pickFile: true));
      await until(tester, find.byKey(const ValueKey('import-other-file')));
      expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsOneWidget);
      expect(find.text(l10n.importFoundBackup), findsOneWidget);
      await tester.tap(find.text(l10n.importItAction));
      // The SSH config dialog is gone, and the backup's own question is asked.
      await until(tester, find.text(l10n.accountBackupPassword));
      expect(find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)), findsNothing);
      expect(find.text('Parse config'), findsNothing);
    });

    testWidgets('the same, declined: the SSH config dialog stays, and has read nothing of it', (tester) async {
      FilePicker.platform = _Picker(write('northwind.zest', _backup));
      await open(tester, (context) => showDesktopSshConfigImport(context, pickFile: true));
      await until(tester, find.byKey(const ValueKey('import-other-file')));
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('import-other-file')), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, isEmpty);
    });

    testWidgets('a key without a passphrase: its editor opens with it', (tester) async {
      final made = (await tester.runAsync(() => KeyGenerationService().generateEd25519(comment: 'demo@example.com')))!;
      final path = write('deploy-key', utf8.encode(made.privatePem));
      await open(tester, (context) => openImportFile(context, importFileOf(name: 'deploy-key', path: path, bytes: utf8.encode(made.privatePem)), ImportKind.privateKey));
      await until(tester, find.byType(IdentityEditScreen));
      final key = tester.widget<IdentityEditScreen>(find.byType(IdentityEditScreen)).initialImportedKey!;
      expect((key.fingerprint, key.keyType, key.label), (made.fingerprint, 'ssh-ed25519', 'deploy-key'));
      expect(key.passphrase, isNull);
    });

    testWidgets('a key with a passphrase: asked for, wrong is said, and right opens its editor with the passphrase', (tester) async {
      final path = write('id_ed25519', utf8.encode(_encryptedKey));
      await open(tester, (context) => importKeyFile(context, path));
      await until(tester, find.text(l10n.identityKeyPassphrase));
      // Its button says what it does (the dialog rules of 3.4): it said OK.
      expect(find.text('OK'), findsNothing);
      await tester.enterText(find.byType(TextField), 'not it');
      await tester.tap(find.text(l10n.passphrasePromptUnlock));
      await until(tester, find.text(l10n.identityIncorrectPassphrase));
      await tester.enterText(find.byType(TextField), _demoPassphrase);
      await tester.tap(find.text(l10n.passphrasePromptUnlock));
      await until(tester, find.byType(IdentityEditScreen));
      final key = tester.widget<IdentityEditScreen>(find.byType(IdentityEditScreen)).initialImportedKey!;
      expect((key.keyType, key.label, key.passphrase), ('ssh-ed25519', 'id_ed25519', _demoPassphrase));
    });

    testWidgets('a key whose passphrase is not known: three tries, then said; nothing opens', (tester) async {
      final path = write('id_ed25519', utf8.encode(_encryptedKey));
      await open(tester, (context) => importKeyFile(context, path));
      for (var attempt = 0; attempt < 3; attempt++) {
        await until(tester, find.text(l10n.identityKeyPassphrase));
        await tester.enterText(find.byType(TextField), 'not it $attempt');
        await tester.tap(find.text(l10n.passphrasePromptUnlock));
        await tester.pumpAndSettle();
      }
      await told(tester, l10n.identityDecryptFailed);
      expect(find.byType(IdentityEditScreen), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a key whose passphrase is not given: asked once, and nothing more', (tester) async {
      final path = write('id_ed25519', utf8.encode(_encryptedKey));
      await open(tester, (context) => importKeyFile(context, path));
      await until(tester, find.text(l10n.identityKeyPassphrase));
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(find.text(l10n.identityKeyPassphrase), findsNothing);
      expect(find.byType(IdentityEditScreen), findsNothing);
    });

    testWidgets('a share link under a comment: the link alone goes on, and its host is offered', (tester) async {
      final bytes = utf8.encode('# from the wiki\nzestssh://add-host?host=web1.example.com&port=22&user=deploy&label=Web\n');
      await open(tester, (context) => openImportFile(context, importFileOf(name: 'link.txt', bytes: bytes), ImportKind.shareLink));
      await tester.pumpAndSettle();
      expect(find.byType(IncomingShareDialog), findsOneWidget);
    });

    testWidgets('a file chosen as a shared host, however large: looked at away from the screen, no more of it than a host file may be, and said for what it is', (tester) async {
      debugImportWorkHere = 0;
      final path = write('large.zest', utf8.encode('name,host\n${'web,web1.example.com\n' * 400000}'));
      expect(File(path).lengthSync(), greaterThan(kCsvMaxBytes));
      await open(tester, (context) => importHostShareFile(context, path: path));
      await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpZest)));
      expect(debugImportWorkHere, 0, reason: 'it ran on the screen\'s thread');
      await tester.tap(find.text(l10n.cancel).last);
      await tester.pumpAndSettle();
    });

    group('a form of key that is not read here is said at once, with no question of a passphrase', () {
      for (final (name, bytes) in <(String, List<int>)>[
        ('SSH.com\'s, with the word ENCRYPTED in it', utf8.encode('---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nSubject: demo\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n')),
        ('PGP\'s', utf8.encode('-----BEGIN PGP PRIVATE KEY BLOCK-----\n\nlQOYBF==\n-----END PGP PRIVATE KEY BLOCK-----\n')),
        ('the old SSH 1 file', [...utf8.encode('SSH PRIVATE KEY FILE FORMAT 1.1\n'), 0, 0, 1, 2, 3]),
        ('DER', [0x30, 0x82, 0x04, 0xbe, 0x02, 0x01, 0x00, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48]),
        ('PKCS#12', [0x30, 0x82, 0x04, 0xbe, 0x02, 0x01, 0x03, 0x30, 0x82, 0x04, 0x80, 0x06, 0x09, 0x2a]),
      ]) {
        testWidgets(name, (tester) async {
          final path = write('key', bytes);
          await open(tester, (context) => importKeyFile(context, path));
          final said = await told(tester, l10n.keyImportNotAKey);
          expect(said.details, isNotNull);
          expect(find.text(l10n.identityKeyPassphrase), findsNothing);
          expect(find.byType(IdentityEditScreen), findsNothing);
          await tester.pump(const Duration(seconds: 10));
        });
      }

      test('a real encrypted PEM is still asked for', () {
        final service = KeyImportService();
        expect(service.isEncrypted('-----BEGIN ENCRYPTED PRIVATE KEY-----\nMII\n-----END ENCRYPTED PRIVATE KEY-----\n'), isTrue);
        expect(service.isEncrypted('-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nMII\n-----END RSA PRIVATE KEY-----\n'), isTrue);
        expect(service.isEncrypted('---- BEGIN SSH2 ENCRYPTED PRIVATE KEY ----\nP2/56wAAAAA=\n---- END SSH2 ENCRYPTED PRIVATE KEY ----\n'), isFalse);
        expect(service.readsForm('-----BEGIN RSA PRIVATE KEY-----\nMII\n-----END RSA PRIVATE KEY-----\n'), isTrue);
        expect(service.readsForm('PuTTY-User-Key-File-3: ssh-ed25519\n'), isTrue);
      });
    });

    group('a private key and more besides: a way past, for a file', () {
      const mixed = '$_privateKey\nHost web1\n  HostName 203.0.113.10\n';

      testWidgets('a hand-picked SSH config: Read it as it, and its hosts come', (tester) async {
        final path = write('notes.txt', utf8.encode(mixed));
        FilePicker.platform = _Picker(path);
        await open(tester, (context) => showDesktopSshConfigImport(context, pickFile: true));
        await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)));
        expect(find.textContaining('BEGIN OPENSSH'), findsNothing);
        expect(find.text(l10n.importReadRestBody(l10n.cloudImpSshConfig)), findsOneWidget, reason: 'what it does is said');
        await tester.tap(find.text(l10n.importReadRest));
        await until(tester, find.text(l10n.sshImportHostsFound(1).toUpperCase()));
        expect(find.text('web1'), findsOneWidget);
        // The field behind it holds the rest, and none of the key.
        await tester.tap(find.text(l10n.sshImportChooseAnother));
        await tester.pumpAndSettle();
        final held = tester.widget<EditableText>(find.byType(EditableText).first).controller.text;
        expect(held, contains('Host web1'));
        expect(held, isNot(contains('PRIVATE KEY')));
        expect(held, isNot(contains(_privateKey.split('\n')[1])));
      });

      testWidgets('on a phone, with no host in it and Try again back to the field: not in it either', (tester) async {
        final path = write('notes.txt', utf8.encode('$_privateKey\nAn old note about this key.\n'));
        final file = await tester.runAsync(() async => importFileToRead(await readImportFile(path)));
        expect(file!.bytes, isNotNull);
        await open(tester, (context) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => SshConfigImportScreen(file: file))));
        await until(tester, find.text(l10n.sshImportTryAgain));
        await tester.tap(find.text(l10n.sshImportTryAgain));
        await tester.pumpAndSettle();
        final held = tester.widget<EditableText>(find.byType(EditableText).first).controller.text;
        expect(held, contains('An old note about this key.'));
        expect(held, isNot(contains('PRIVATE KEY')));
        expect(held, isNot(contains(_privateKey.split('\n')[1])));
      });

      testWidgets('a hand-picked CSV: the same, and nothing of the key is shown', (tester) async {
        const list = 'name,host\nweb1,203.0.113.10\n$_privateKey\n';
        final path = write('notes.csv', utf8.encode(list));
        await open(
          tester,
          (context) => showZestModal<CsvImportResult>(
            context: context,
            size: ZestModalSize.large,
            child: CsvImportDialog(
              kind: HostFileKind.csv,
              pickedPath: path,
              pickFile: () async => (name: 'notes.csv', bytes: utf8.encode(list)),
            ),
          ),
        );
        await until(tester, find.byKey(const ValueKey('csv-choose')));
        await tester.tap(find.byKey(const ValueKey('csv-choose')));
        await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpCsv)));
        expect(find.byKey(const ValueKey('csv-found')), findsNothing);
        await tester.tap(find.text(l10n.importReadRest));
        await until(tester, find.byKey(const ValueKey('csv-found')));
        expect(find.textContaining('203.0.113.10'), findsWidgets);
        expect(find.textContaining('PRIVATE KEY'), findsNothing);
        expect(find.textContaining(_privateKey.split('\n')[1]), findsNothing);
      });

      testWidgets('only a key by the time it is read: said, and the dialog does not stay busy', (tester) async {
        const list = 'name,host\nweb1,203.0.113.10\n$_privateKey\n';
        final path = write('notes.csv', utf8.encode('PuTTY-User-Key-File-3: ssh-ed25519\nEncryption: none\n'));
        await open(
          tester,
          (context) => showZestModal<CsvImportResult>(
            context: context,
            size: ZestModalSize.large,
            child: CsvImportDialog(
              kind: HostFileKind.csv,
              pickedPath: path,
              pickFile: () async => (name: 'notes.csv', bytes: utf8.encode(list)),
            ),
          ),
        );
        await until(tester, find.byKey(const ValueKey('csv-choose')));
        await tester.tap(find.byKey(const ValueKey('csv-choose')));
        await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpCsv)));
        await tester.tap(find.text(l10n.importReadRest));
        await until(tester, find.text(l10n.csvImpUnreadable));
        expect(find.byKey(const ValueKey('csv-found')), findsNothing);
        expect(tester.widget<ZestButton>(find.byKey(const ValueKey('csv-choose'))).onPressed, isNotNull, reason: 'not busy');
      });

      testWidgets('said to be a CSV under Import a file: the same', (tester) async {
        const list = 'name,host\nweb1,203.0.113.10\n$_privateKey\n';
        final path = write('notes.csv', utf8.encode(list));
        final file = await tester.runAsync(() => readImportFile(path));
        await open(tester, (context) => openImportFile(context, file!, ImportKind.csv));
        await until(tester, find.byKey(const ValueKey('csv-found')));
        expect(find.textContaining('PRIVATE KEY'), findsNothing);
        expect(find.textContaining(_privateKey.split('\n')[1]), findsNothing);
      });

      test('a large one is read off the screen\'s thread', () async {
        final path = write('notes.txt', utf8.encode('$_privateKey\n${'Host web1\n' * 20000}'));
        final file = await readImportFile(path);
        debugImportWorkHere = 0;
        final read = await importFileToRead(file);
        expect(debugImportWorkHere, 0, reason: 'it ran on the screen\'s thread');
        expect(utf8.decode(read.bytes!), isNot(contains('PRIVATE KEY')));
      });

      test('larger than any import reads: said as that, with none of it held', () async {
        final path = write('notes.csv', [...utf8.encode('$_privateKey\nHost web1\n'), ...List.filled(kCsvMaxBytes, 0x20)]);
        final file = await readImportFile(path);
        expect(file.kind, ImportKind.privateKey);
        expect(importCanReadAnyway(file), isTrue);
        final read = await importFileToRead(file);
        expect(read.bytes!.length, greaterThan(kCsvMaxBytes));
        expect(read.bytes!.every((b) => b == 0), isTrue);
      });

      test('a key put there since it was looked at, and nothing more: nothing to read', () async {
        final path = write('notes.txt', utf8.encode(mixed));
        final file = await readImportFile(path);
        File(path).writeAsBytesSync(utf8.encode('$_privateKey\n'));
        final read = await importFileToRead(file);
        expect(read.kind, ImportKind.unknown);
        expect(utf8.decode(read.bytes!), isNot(contains('PRIVATE KEY')));
      });

      testWidgets('or Cancel: nothing is read', (tester) async {
        final path = write('notes.txt', utf8.encode(mixed));
        FilePicker.platform = _Picker(path);
        await open(tester, (context) => showDesktopSshConfigImport(context, pickFile: true));
        await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)));
        await tester.tap(find.text(l10n.cancel).last);
        await tester.pumpAndSettle();
        expect(find.text(l10n.sshImportHostsFound(1).toUpperCase()), findsNothing);
      });

      testWidgets('only a key: no such choice', (tester) async {
        final path = write('id_ed25519', utf8.encode(_privateKey));
        FilePicker.platform = _Picker(path);
        await open(tester, (context) => showDesktopSshConfigImport(context, pickFile: true));
        await until(tester, find.text(l10n.importWrongTitle(l10n.cloudImpSshConfig)));
        expect(find.text(l10n.importReadRest), findsNothing);
        expect(find.byKey(const ValueKey('import-read-rest')), findsNothing);
      });

      testWidgets('where a file is read for a backup: no such choice', (tester) async {
        final path = write('notes.zest', utf8.encode(mixed));
        await open(tester, (context) async {
          await routeIfOtherFile(context, await readImportFile(path), chosen: 'x', takes: const {}, closes: false);
        });
        await until(tester, find.text(l10n.importWrongTitle('x')));
        expect(find.text(l10n.importReadRest), findsNothing);
        expect(find.byKey(const ValueKey('import-read-rest')), findsNothing);
      });

      testWidgets('said to be something else under Import a file: read then, as that', (tester) async {
        final path = write('notes.txt', utf8.encode(mixed));
        final file = await tester.runAsync(() => readImportFile(path));
        expect(file!.bytes, isNull);
        await open(tester, (context) => openImportFile(context, file, ImportKind.sshConfig));
        await until(tester, find.text(l10n.sshImportHostsFound(1).toUpperCase()));
      });
    });

    testWidgets('a key file longer than any key: not read at all, and said as no key, with the details', (tester) async {
      final made = (await tester.runAsync(() => KeyGenerationService().generateEd25519(comment: 'demo@example.com')))!;
      final path = write('deploy-key', [...utf8.encode(made.privatePem), ...List.filled(kMaxKeyFileBytes, 0x0a)]);
      await open(tester, (context) => importKeyFile(context, path));
      final said = await told(tester, l10n.keyImportNotAKey);
      expect(said.details, isNotNull, reason: 'Copy details');
      expect(find.byType(IdentityEditScreen), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a key file of the longest a key may be is read', (tester) async {
      final made = (await tester.runAsync(() => KeyGenerationService().generateEd25519(comment: 'demo@example.com')))!;
      final pem = utf8.encode(made.privatePem);
      final path = write('deploy-key', [...pem, ...List.filled(kMaxKeyFileBytes - pem.length, 0x0a)]);
      await open(tester, (context) => importKeyFile(context, path));
      await until(tester, find.byType(IdentityEditScreen));
    });

    testWidgets('what is no key after all: said in words, with the details to copy', (tester) async {
      final path = write('not-a-key', utf8.encode('Dear team,\n'));
      await open(tester, (context) => importKeyFile(context, path));
      final said = await told(tester, l10n.keyImportNotAKey);
      expect(said.details, isNotNull, reason: 'Copy details');
      expect(find.byType(IdentityEditScreen), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    testWidgets('a key file that went away between the question and the yes: said, with the details to copy', (tester) async {
      await open(tester, (context) => importKeyFile(context, '${dir.path}${Platform.pathSeparator}gone'));
      final said = await told(tester, l10n.keyImportNotImported);
      expect(said.details, isNotNull, reason: 'Copy details');
      expect(find.byType(IdentityEditScreen), findsNothing);
      await tester.pump(const Duration(seconds: 10));
    });

    for (final (name, kind, content, shows) in <(String, ImportKind, String, String)>[
      ('a CSV', ImportKind.csv, _csv, 'Web'),
      ('MobaXterm', ImportKind.mobaxterm, _moba, 'web1'),
    ]) {
      testWidgets('$name: read at once by the host file import', (tester) async {
        final bytes = utf8.encode(content);
        await open(tester, (context) => openImportFile(context, importFileOf(name: 'hosts.file', path: '/demo/hosts.file', bytes: bytes), kind));
        await tester.pumpAndSettle();
        expect(find.textContaining(shows), findsWidgets);
        expect(find.byKey(const ValueKey('csv-choose')), findsNothing);
      });
    }

    for (final kind in const [ImportKind.publicKey, ImportKind.knownHosts, ImportKind.unknown]) {
      testWidgets('${kind.name}: nothing imports it, so nothing opens', (tester) async {
        await open(tester, (context) => openImportFile(context, importFileOf(name: 'x', path: '/demo/x', bytes: utf8.encode(_knownHosts)), kind));
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsNothing);
        expect(find.text('open'), findsOneWidget);
      });
    }

    testWidgets('Open Keys on a computer: its page, in front of any terminal or tab', (tester) async {
      final p = await prefs();
      late WidgetRef seen;
      await tester.pumpWidget(app(
          p,
          (context) => Consumer(builder: (context, ref, _) {
                seen = ref;
                return TextButton(onPressed: () => openKeysPage(context), child: const Text('open'));
              })));
      seen.read(workTabsProvider.notifier).createTab('a-session');
      seen.read(v3ActiveSessionTabProvider.notifier).state = 'a-session';
      expect(seen.read(workTabsProvider).activeTabId, isNotNull);
      await tester.tap(find.text('open'));
      await tester.pump();
      expect(seen.read(activeSidebarNavProvider), NavSection.keys);
      expect(seen.read(v3ActiveSessionTabProvider), isNull);
      expect(seen.read(workTabsProvider).activeTabId, isNull);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  });

  group('the words', () {
    test('every kind has its own words, and a name where it may be chosen', () {
      for (final k in ImportKind.values) {
        expect(importFoundWords(k, l10n), isNotEmpty, reason: '$k');
        expect(importKindName(k, l10n), isNotEmpty, reason: '$k');
      }
      expect({for (final k in ImportKind.values) importFoundWords(k, l10n)}, hasLength(ImportKind.values.length));
      expect(kImportKindsToChoose, isNot(contains(ImportKind.unknown)));
      expect(kImportKindsToChoose, isNot(contains(ImportKind.knownHosts)), reason: 'nothing imports them');
    });
  });

  test('the file is only ever read as far as a host file may be, and a detector is not given more', () async {
    final dir = await Directory.systemTemp.createTemp('zest-import-file');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/big.zest');
    await file.writeAsBytes([...utf8.encode('ZEST'), 3, ...List.filled(kCsvMaxBytes + 4096, 7)]);
    final read = await readImportFile(file.path);
    expect(read.kind, ImportKind.zestBackup);
    expect(read.bytes!.length, kCsvMaxBytes + 1);
    expect(read.name, 'big.zest');
  });

  testWidgets('layout of the offer with real fonts', (tester) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = const Size(1000, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final p = await prefs();
    await tester.pumpWidget(app(
      p,
      (context) => TextButton(
        onPressed: () => routeIfOtherFile(context, importFileOf(name: 'x', path: '/demo/x', bytes: utf8.encode(_knownHosts)),
            chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig}, closes: false),
        child: const Text('open'),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.importFoundKnownHosts), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
