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
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_list_pane.dart' show keyAddedDate;
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';

/// The Keys page on a computer says when a key was added and last used in the
/// page's language (3.0): its LAST USED and AGE cells said
/// "45m", "23h", "2w" or "6mo", their tooltips and the key's details "45m
/// ago", in English in every language. Each cell is as wide as the widest of
/// the list's, so a time in German or French is whole ("45 Min.", "23 Std.").
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SharedPreferences prefs;
  late AppDatabase db;
  late IdentityCrudNotifier crud;
  late String used;
  late DateTime added;
  late DateTime lastUsed;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// Two passwords: one added 45 minutes ago and used 23 hours ago (another
  /// device's sign-in, its time synced), one added 19 days ago and never used.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        final now = DateTime.now();
        added = now.subtract(const Duration(minutes: 45));
        lastUsed = now.subtract(const Duration(hours: 23));
        used = await crud.create(label: 'deploy', username: 'deploy', authMethod: 'password', password: 'demo-only');
        await db.identitiesDao.updateIdentity(IdentitiesCompanion(id: Value(used), createdAt: Value(added)));
        final old = await crud.create(label: 'backup', username: 'backup', authMethod: 'password', password: 'demo-only');
        await db.identitiesDao
            .updateIdentity(IdentitiesCompanion(id: Value(old), createdAt: Value(now.subtract(const Duration(days: 19)))));
      });

  Future<void> pumpKeys(WidgetTester tester, Locale locale) async {
    await tester.runAsync(() async {
      for (final (family, files) in [
        ('GeistSans', ['GeistSans-Regular.ttf', 'GeistSans-Medium.ttf', 'GeistSans-SemiBold.ttf']),
        ('JetBrainsMono', ['JetBrainsMono-Regular.ttf']),
      ]) {
        final loader = FontLoader(family);
        for (final f in files) {
          loader.addFont(Future.value(ByteData.view(Uint8List.fromList(File('assets/fonts/$f').readAsBytesSync()).buffer)));
        }
        await loader.load();
      }
    });
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
        identityLastUsedProvider.overrideWith((ref) => Stream.value({used: lastUsed})),
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'GeistSans'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: const Scaffold(body: KeysView()),
      ),
    ));
    await settle(tester);
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets("a key's LAST USED and AGE, their tooltips and its details say when in the page's language, the "
        'cells whole ($locale)', (tester) async {
      final l = lookupAppLocalizations(locale);
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpKeys(tester, locale);

      // LAST USED in words of their own, ADDED as a date (as designed,
      // "2h ago", "Sep 1").
      for (final shown in [timeAgoWords(l, lastUsed), keyAddedDate(l, added)]) {
        final cell = find.text(shown);
        expect(cell, findsOneWidget, reason: shown);
        expect(tester.renderObject<RenderParagraph>(cell).didExceedMaxLines, isFalse, reason: '"$shown" whole in its cell');
      }
      expect(find.byTooltip(l.zestKeysMetricLastUsed(timeAgoInSentence(l, lastUsed))), findsOneWidget);
      expect(find.byTooltip(l.zestKeysMetricAge(timeAgoInSentence(l, added))), findsOneWidget);

      await tester.tap(find.text('deploy').first);
      await settle(tester);
      // Set to break only between its parts (it broke "last used 2" over
      // "hours ago", as a design review found).
      expect(
          find.text(breakAtDots(l.keysUiSubtitle(l.identityPassword, keyAddedDate(l, added), timeAgoInSentence(l, lastUsed)))),
          findsOneWidget,
          reason: 'added and last used, in its details');
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });
  }
}

/// Lets the screen read what it shows from the database, which answers in real time.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
}
