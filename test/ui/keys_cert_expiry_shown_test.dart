import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_view.dart';
import 'package:zestssh/utils/redactor.dart';

/// The Keys screen on a computer says, under the name of a key, when its
/// certificate runs out (3.0): in its last fourteen days and when it has run
/// out. It said so in English in every language, and by whole days of
/// twenty-four hours: a certificate that had run out three hours earlier
/// "expires today", and one that ends tomorrow at noon "expires today" from
/// noon on.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const publicKey = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDemoDemoDemoDemoDemoDemoDemoDemoDemoDemoDemo demo@northwind.example';

  late SharedPreferences prefs;
  late AppDatabase db;
  late IdentityCrudNotifier crud;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  /// Three keys with a certificate each: one that ran out three hours ago,
  /// one that ends tomorrow at noon, and one with forty days to go.
  Future<void> build(WidgetTester tester) => tester.runAsync(() async {
        db = AppDatabase.forTesting(NativeDatabase.memory());
        crud = IdentityCrudNotifier(
            db.identitiesDao, IdentitySecretStore.forDatabase(db, const FlutterSecureStorage()), db.connectionsDao);
        final today = DateTime.now();
        for (final (label, runsOut) in [
          ('gone', today.subtract(const Duration(hours: 3))),
          ('tomorrow', DateTime(today.year, today.month, today.day + 1, 12)),
          ('far', today.add(const Duration(days: 40))),
        ]) {
          final id = await crud.create(
              label: label,
              username: 'deploy',
              authMethod: 'certificate',
              publicKeyData: publicKey,
              privateKeyPem: 'not read here');
          await db.identitiesDao.updateIdentity(IdentitiesCompanion(
            id: Value(id),
            certValidAfter: Value(runsOut.subtract(const Duration(days: 90))),
            certValidBefore: Value(runsOut),
          ));
        }
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
    tester.view.physicalSize = const Size(1400, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        identitiesDaoProvider.overrideWithValue(db.identitiesDao),
        identityCrudProvider.overrideWithValue(crud),
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

  Future<void> pick(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await settle(tester);
  }

  for (final locale in const [Locale('en'), Locale('de')]) {
    testWidgets('under the name of a key: that its certificate has run out, or on which day it does ($locale)',
        (tester) async {
      final l = lookupAppLocalizations(locale);
      await build(tester);
      addTearDown(() => tester.runAsync(db.close));
      await pumpKeys(tester, locale);

      await pick(tester, 'gone');
      expect(find.textContaining(l.certSaidRanOut), findsOneWidget);
      expect(find.textContaining(l.certSaidRunsOutToday), findsNothing);

      await pick(tester, 'tomorrow');
      expect(find.textContaining(l.certSaidRunsOutTomorrow), findsOneWidget);
      expect(find.textContaining(l.certSaidRanOut), findsNothing);
      expect(find.textContaining(l.certSaidRunsOutToday), findsNothing);

      // With forty days to go nothing is said.
      await pick(tester, 'far');
      for (final words in [l.certSaidRanOut, l.certSaidRunsOutToday, l.certSaidRunsOutTomorrow]) {
        expect(find.textContaining(words), findsNothing);
      }
      expect(find.textContaining(l.certSaidRunsOutInDays(40)), findsNothing);
      await finish(tester);
    });
  }
}

/// Lets the screen read what it shows from the database, which answers in real time.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
  }
  await tester.pump(const Duration(seconds: 5));
}

/// Takes the screen down while the test still runs, so what closes with it
/// closes inside the test.
Future<void> finish(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(milliseconds: 10));
}
