import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/services/connection_share_service.dart';

/// A connection shared as a `.zest` file is not left behind (3.0):
/// it was written straight into the app's temporary folder and
/// never deleted, the host, the user and the forwards in the clear, and the
/// password and the key if they were chosen, sealed under a password that
/// can be guessed offline. And a share password that is too short is said
/// in the dialog, not as an English error after it.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));

  final now = DateTime.utc(2026);
  final conn = Connection(
    id: 'c1',
    label: 'web 01',
    host: 'web-01.northwind.example',
    port: 22,
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: now,
    updatedAt: now,
  );

  test('a share is written into a folder of its own, which is deleted once shared', () async {
    // The app's temporary folder, for this test.
    final temp = await Directory.systemTemp.createTemp('zestssh_temp_');
    addTearDown(() => temp.delete(recursive: true));
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => temp.path);
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null));
    final path = await ConnectionShareService.exportConnection(connection: conn, identity: null, portForwardRules: const []);
    final file = File(path);
    final folder = file.parent;
    expect(file.existsSync(), isTrue);
    expect(folder.parent.path, temp.path);
    expect(folder.uri.pathSegments.where((s) => s.isNotEmpty).last, startsWith(ConnectionShareService.shareFolderPrefix));
    expect(file.uri.pathSegments.last, 'web_01.zest');
    expect(jsonEncode(jsonDecode(file.readAsStringSync())), contains('web-01.northwind.example'));

    await ConnectionShareService.removeShareFile(path);
    expect(file.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    // (Twice is nothing.)
    await ConnectionShareService.removeShareFile(path);
  });

  // On Android too: it was left there for the next start, as if the app chosen read it from where
  // it was written, where the sheet hands that app a copy of its own (share_plus copies it before the sheet opens).
  test('after sharing, the file is deleted with its folder, on every system, and both shares go through it', () async {
    final temp = await Directory.systemTemp.createTemp('zestssh_temp_');
    addTearDown(() => temp.delete(recursive: true));
    final folder = temp.createTempSync(ConnectionShareService.shareFolderPrefix);
    final shared = File('${folder.path}${Platform.pathSeparator}web_01.zest')..writeAsStringSync('{}');

    await ConnectionShareService.removeAfterShare(shared.path);
    expect(shared.existsSync(), isFalse);
    expect(folder.existsSync(), isFalse);
    expect(File('lib/features/hosts/host_share_file.dart').readAsStringSync(),
        contains('sheet ? ConnectionShareService.removeAfterShare(written) : ConnectionShareService.removeShareFile(written)'));
  });

  test('what earlier shares left is deleted at start-up, and nothing else', () async {
    final temp = await Directory.systemTemp.createTemp('zestssh_temp_');
    addTearDown(() => temp.delete(recursive: true));
    final sep = Platform.pathSeparator;
    final old = File('${temp.path}${sep}web_01.zest')..writeAsStringSync('{}');
    final oldUpper = File('${temp.path}${sep}DB_01.ZEST')..writeAsStringSync('{}');
    final shareFolder = Directory('${temp.path}$sep${ConnectionShareService.shareFolderPrefix}abc')..createSync();
    File('${shareFolder.path}${sep}db_01.zest').writeAsStringSync('{}');
    final other = File('${temp.path}${sep}notes.txt')..writeAsStringSync('keep');
    final otherFolder = Directory('${temp.path}${sep}flutter_cache')..createSync();

    await ConnectionShareService.removeLeftovers(temp.path);
    expect(old.existsSync(), isFalse);
    expect(oldUpper.existsSync(), isFalse);
    expect(shareFolder.existsSync(), isFalse);
    expect(other.existsSync(), isTrue);
    expect(otherFolder.existsSync(), isTrue);
    // A folder that is not there is nothing.
    await ConnectionShareService.removeLeftovers('${temp.path}${sep}gone');
  });

  group('the share dialog', () {
    Future<ShareOptions?> open(WidgetTester tester,
        {required bool password, required String secret, String? again}) async {
      ShareOptions? chosen;
      var closed = false;
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(1000, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                chosen = await showDialog<ShareOptions>(
                  context: context,
                  builder: (_) => const ShareOptionsDialog(connectionLabel: 'web 01', offerPassword: true, offerKey: true),
                );
                closed = true;
              },
              child: const Text('share'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('share'));
      await tester.pumpAndSettle();
      if (password) {
        await tester.tap(find.text(en.homeShareIncludePassword));
        await tester.pumpAndSettle();
        await tester.enterText(find.byKey(const ValueKey('share-encryption-password')), secret);
        await tester.enterText(find.byKey(const ValueKey('share-encryption-password-again')), again ?? secret);
      }
      await tester.tap(find.text(en.homeShare).last);
      await tester.pumpAndSettle();
      return closed ? chosen : null;
    }

    testWidgets('with a password to share asks for one long enough, under its field', (tester) async {
      expect(await open(tester, password: true, secret: ''), isNull);
      expect(find.text(en.homeShareEncryptionRequired), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('share-encryption-password')), 'short one');
      await tester.tap(find.text(en.homeShare).last);
      await tester.pumpAndSettle();
      expect(find.text(en.settingsMobPasswordMin12), findsOneWidget);
      // Typing clears what it said.
      await tester.enterText(find.byKey(const ValueKey('share-encryption-password')), 'twelve chars!');
      await tester.pump();
      expect(find.text(en.settingsMobPasswordMin12), findsNothing);
    });

    testWidgets('a long enough one is taken', (tester) async {
      final chosen = await open(tester, password: true, secret: 'a long enough password');
      expect(chosen, isNotNull);
      expect(chosen!.includePassword, isTrue);
      expect(chosen.encryptionPassword, 'a long enough password');
    });

    // The password a share is sealed under is typed twice (it was typed
    // once): a slip in it made a
    // file nobody could open.
    testWidgets('two that differ share nothing, said under the second; typing clears it; the same twice is taken',
        (tester) async {
      expect(await open(tester, password: true, secret: 'a long enough password', again: 'a long enough passwort'),
          isNull);
      expect(find.text(en.backupPasswordMismatch), findsOneWidget);
      final again = find.byKey(const ValueKey('share-encryption-password-again'));
      await tester.enterText(again, 'a long enough password');
      await tester.pump();
      expect(find.text(en.backupPasswordMismatch), findsNothing);
      await tester.tap(find.text(en.homeShare).last);
      await tester.pumpAndSettle();
      expect(find.byType(ShareOptionsDialog), findsNothing, reason: 'shared');
    });

    testWidgets('without secrets asks for none', (tester) async {
      final chosen = await open(tester, password: false, secret: '');
      expect(chosen, isNotNull);
      expect(chosen!.encryptionPassword, isNull);
    });
  });
}
