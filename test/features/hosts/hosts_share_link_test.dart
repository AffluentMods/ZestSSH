import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// A host's share link on a computer's Hosts page (add a new
/// host by pasting that link, and done): pasted into the quick field,
/// or through New host's menu, it goes to the question of whether to add its
/// host, and nothing is added without the yes.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final link = ConnectionShareUrlService.buildShareUrl(label: 'web 01', host: 'web-01.example.com', port: 2222, user: 'deploy')
      .toString();

  late AppDatabase db;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    debugTopSnackBarOnPhone = true;
  });
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump(const Duration(milliseconds: 150));
    }
  }

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 22);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(id: 'h1', label: 'db-01', host: '10.0.0.1', createdAt: now, updatedAt: now));
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: HostsHomePage(onConnectTo: (_) {})),
      ),
    ));
    await settle(tester);
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  Future<List<String>> hosts(WidgetTester tester) async =>
      [for (final c in (await tester.runAsync(db.connectionsDao.getAll))!) c.id];

  testWidgets('a link pasted into the quick field shows its host to add; Cancel adds nothing and the box is empty',
      (tester) async {
    await pump(tester);
    final field = find.byType(TextField).first;
    await tester.enterText(field, link);
    await settle(tester);
    expect(find.byType(IncomingShareDialog), findsOneWidget);
    expect(find.text('web 01'), findsWidgets);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'the link went to the question');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(find.byType(IncomingShareDialog), findsNothing);
    expect(await hosts(tester), ['h1'], reason: 'nothing without the yes');
    await finish(tester);
  });

  testWidgets('New host\'s menu has Paste a share link, which reads it and shows its host to add', (tester) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('hosts-new-menu')));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(l10n.shareLinkPasteTitle), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('hosts-new-share-link')));
    await settle(tester);
    expect(find.byKey(const ValueKey('share-link-field')), findsOneWidget);
    await tester.enterText(
        find.descendant(of: find.byKey(const ValueKey('share-link-field')), matching: find.byType(EditableText)), link);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('share-link-continue')));
    await settle(tester);
    expect(find.byType(IncomingShareDialog), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(await hosts(tester), ['h1']);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await finish(tester);
  });
}
