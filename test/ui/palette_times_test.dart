import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';

/// The palette says when a host was last connected to in the page's language,
/// whole in its slot (3.0): it said "just now", "45m ago" or
/// "2w ago" in English in every language, in a slot 42 wide that cut "45m
/// ago" in English too. The slot is as wide as the widest of its times.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SharedPreferences prefs;
  late AppDatabase db;
  late Map<String, DateTime> connected;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// Three hosts connected to 45 minutes, 23 hours and 19 days ago.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        final now = DateTime.now();
        connected = {
          'web-01': now.subtract(const Duration(minutes: 45)),
          'db-primary': now.subtract(const Duration(hours: 23)),
          'log-store': now.subtract(const Duration(days: 19)),
        };
        var i = 0;
        for (final MapEntry(key: name, value: at) in connected.entries) {
          await db.into(db.connections).insert(ConnectionsCompanion.insert(
              id: 'c$i',
              label: name,
              host: '192.168.10.${21 + i}',
              port: const Value(22),
              lastConnected: Value(at),
              createdAt: now,
              updatedAt: now));
          i++;
        }
      });

  Future<void> open(WidgetTester tester, Locale locale) async {
    await tester.runAsync(() async {
      for (final (family, files) in [
        ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf']),
        ('JetBrainsMono', ['JetBrainsMono-Regular.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final f in files) {
          loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
        }
        await loader.load();
      }
    });
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: Consumer(
            builder: (context, ref, _) => TextButton(
              onPressed: () => showCommandPalette(context, ref, actions: const []),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    await tester.tap(find.text('open'));
    await settle(tester);
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets("the palette says when each host was connected to in the page's language, whole in its slot "
        '($locale)', (tester) async {
      final l = lookupAppLocalizations(locale);
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await open(tester, locale);

      for (final at in connected.values) {
        final said = timeAgoShort(l, at);
        final shown = find.text(said);
        expect(shown, findsWidgets, reason: said);
        for (final e in shown.evaluate()) {
          final p = e.renderObject! as RenderParagraph;
          expect(p.didExceedMaxLines, isFalse, reason: '"$said" whole in its slot');
        }
      }
      // Closed as a person closes it, so the next one opens.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text(timeAgoShort(l, connected['web-01']!)), findsNothing, reason: 'the palette closed');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}

/// Lets the palette read the hosts from the database, which answers in real time.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}
