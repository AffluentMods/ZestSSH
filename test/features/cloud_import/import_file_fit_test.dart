import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart' show ImportKind;
import 'package:zestssh/features/cloud_import/ui/import_file.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';

import '../../visual/shots_util.dart';

/// Import a file in the real fonts, in every language: what it found, what it
/// could not tell, and what nothing imports; nothing overflows, on a computer
/// or a phone. With ZEST_SHOTS the pictures land in
/// build/shots/import-file-*.png.

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

/// Import hosts in [locale], with the file [name] found.
Future<void> _openFound(WidgetTester tester, Locale locale, String name, List<int> bytes,
    {Size size = const Size(1200, 900), GlobalKey? key}) async {
  FlutterSecureStorage.setMockInitialValues({});
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  SharedPreferences.setMockInitialValues(const {});
  final prefs = await SharedPreferences.getInstance();
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      recordingModeProvider.overrideWith((ref) => false),
      databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      orchardDatabaseStorageProvider.overrideWithValue(_NoOrchards()),
    ],
    child: RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showZestModal<ImportHostsResult>(
                context: context,
                size: ZestModalSize.large,
                child: ImportHostsDialog(
                  pickFile: () async => importFileOf(name: name, path: '/demo/$name', bytes: bytes),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(const ValueKey('import-file')));
  await tester.pumpAndSettle();
  expect(find.byKey(const ValueKey('import-found')), findsOneWidget);
}

void main() {
  Future<void> show(WidgetTester tester, Locale locale, String name, List<int> bytes,
      {required String shot, Size size = const Size(1200, 900)}) async {
    await tester.runAsync(loadShotFonts);
    final key = GlobalKey();
    await _openFound(tester, locale, name, bytes, size: size, key: key);
    expect(tester.takeException(), isNull, reason: '$locale');
    if (shotsEnabled) {
      realShadows();
      await tester.pump();
      await saveShot(tester, key, shot);
      plainShadows();
    }
    await tester.pumpWidget(const SizedBox.shrink());
  }

  final backup = [...utf8.encode('ZEST'), 3, 1, 2, 3];
  final unknown = utf8.encode('Dear team,\nnothing of ours\n');
  final knownHosts = utf8.encode('web1.example.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo\n');
  final publicKey = utf8.encode('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemo demo@example.com\n');

  testWidgets('right to left, what it found is laid out the same from the other side', (tester) async {
    (double, double) insets(bool rtl) {
      final panel = tester.getRect(find.byKey(const ValueKey('import-found')));
      double from(Finder f) => rtl ? panel.right - tester.getRect(f).right : tester.getRect(f).left - panel.left;
      return (
        from(find.descendant(of: find.byKey(const ValueKey('import-found')), matching: find.byType(Icon)).first),
        from(find.byKey(const ValueKey('import-found-go'))),
      );
    }

    Future<(double, double)> measure(Locale locale) async {
      await tester.runAsync(loadShotFonts);
      await _openFound(tester, locale, 'hosts.csv', utf8.encode('name,host\nWeb,203.0.113.10\n'));
      final at = insets(locale.languageCode == 'ar');
      await tester.pumpWidget(const SizedBox.shrink());
      return at;
    }

    final ltr = await measure(const Locale('en'));
    final rtl = await measure(const Locale('ar'));
    expect(rtl, ltr);
    expect(ltr.$1, greaterThan(0));
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('$locale: a backup', (tester) async {
      await show(tester, locale, 'northwind-2026-10-30.zest', backup, shot: 'import-file-backup-$locale');
    });
    testWidgets('$locale: could not tell', (tester) async {
      await show(tester, locale, 'notes.txt', unknown, shot: 'import-file-unknown-$locale');
    });
    testWidgets('$locale: known_hosts', (tester) async {
      await show(tester, locale, 'known_hosts', knownHosts, shot: 'import-file-known-hosts-$locale');
    });
    testWidgets('$locale: a public key, a phone\'s width', (tester) async {
      await show(tester, locale, 'id_ed25519.pub', publicKey, shot: 'import-file-public-phone-$locale', size: const Size(390, 844));
    });
    // A file with a private key in it and more: This file is not for, with its
    // three answers, the longest of them the way past.
    for (final (where, size) in [('a computer', const Size(1200, 900)), ('a narrow window', const Size(640, 600)), ('a phone', const Size(360, 700))]) {
      testWidgets('$locale on $where: a private key and more, its three answers whole', (tester) async {
        await tester.runAsync(loadShotFonts);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final key = GlobalKey();
        final l10n = lookupAppLocalizations(locale);
        final file = importFileOf(
          name: 'notes.txt',
          path: '/demo/notes.txt',
          bytes: utf8.encode('-----BEGIN OPENSSH PRIVATE KEY-----\nb3Blbg==\n-----END OPENSSH PRIVATE KEY-----\nHost web1\n'),
        );
        await tester.pumpWidget(RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: BuiltInThemes.getById('default_dark').toThemeData(),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            locale: locale,
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () => routeIfOtherFile(context, file, chosen: l10n.cloudImpSshConfig, takes: const {ImportKind.sshConfig}, readsHere: true),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
        final screen = Offset.zero & size;
        expect(find.text(l10n.importReadRestBody(l10n.cloudImpSshConfig)), findsOneWidget);
        for (final label in [l10n.importReadRest, l10n.cancel, l10n.importItAction]) {
          final found = find.text(label);
          expect(found, findsOneWidget, reason: label);
          final paragraph = tester.renderObject<RenderParagraph>(found);
          expect(paragraph.didExceedMaxLines, isFalse, reason: '"$label" whole');
          final at = tester.getRect(found);
          expect(screen.contains(at.topLeft) && screen.contains(at.bottomRight), isTrue, reason: '"$label" on screen: $at');
          expect(at.width, greaterThan(10), reason: '"$label" has room: $at');
        }
        if (shotsEnabled) {
          realShadows();
          await tester.pump();
          await saveShot(tester, key, 'import-file-read-as-${where.replaceAll(' ', '-')}-$locale');
          plainShadows();
        }
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
}
