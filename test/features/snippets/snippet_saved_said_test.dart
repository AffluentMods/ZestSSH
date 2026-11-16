import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/snippets/save_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_editor.dart';
import 'package:zestssh/ui/screens/snippets/snippets_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/platform_utils.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Saving a snippet says so, with its name, on a computer and on a phone, and
/// only once it is stored (before, saving a snippet showed nothing to say
/// it was saved).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  tearDown(() {
    debugTopSnackBarOnPhone = null;
    debugTouchLayout = null;
  });

  group("a computer's snippet editor", () {
    late AppDatabase db;
    late SharedPreferences prefs;

    setUp(() async {
      debugTopSnackBarOnPhone = false;
      db = AppDatabase.forTesting(NativeDatabase.memory());
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });
    tearDown(() => db.close());

    // As snippet_detail_editor_test draws it: the live streams the editor's
    // fields read are single values, so no teardown timer is left behind.
    Future<ProviderContainer> open(WidgetTester tester, Snippet? snippet) async {
      await tester.pumpWidget(ProviderScope(
        overrides: [
          databaseProvider.overrideWithValue(db),
          sharedPreferencesProvider.overrideWithValue(prefs),
          redactionFleetRegistrar.overrideWith((ref) {}),
          snippetsProvider.overrideWith((ref) => Stream.value(const <Snippet>[])),
          snippetCategoryMetaProvider.overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
          connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(const [])),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: SizedBox(
              width: 960,
              height: 760,
              child: SnippetDetailEditor(
                snippet: snippet,
                existingCategories: const [],
                resetToken: 0,
                onRequestNew: () {},
                onClose: () {},
              ),
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return ProviderScope.containerOf(tester.element(find.byType(SnippetDetailEditor)));
    }

    Finder field(String hint) => find.byWidgetPredicate((w) => w is TextField && w.decoration?.hintText == hint);

    Future<void> finish(WidgetTester tester) async {
      // The toast closes by itself after a few seconds.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    }

    testWidgets('a new snippet, saved, says "Snippet added" with its name', (tester) async {
      final c = await open(tester, null);
      await tester.enterText(field(en.snippetsLabelHint), 'Restart web');
      await tester.enterText(field(r'docker restart ${NAME:-web}'), 'docker restart web');
      await tester.pumpAndSettle();
      expect(c.read(notificationCenterProvider).history, isEmpty, reason: 'nothing said before Save');

      await tester.tap(find.text(en.zestCommonSave));
      await tester.pumpAndSettle();

      expect((await db.snippetsDao.getAll()).single.label, 'Restart web');
      final said = c.read(notificationCenterProvider).history;
      expect([for (final n in said) n.title], [en.snippetAddedToast('Restart web')]);
      expect(said.single.title, 'Snippet added: Restart web');
      expect(said.single.severity, NotificationSeverity.success);
      await finish(tester);
    });

    testWidgets('an edit, saved, says "Snippet saved" with its name', (tester) async {
      final now = DateTime(2026, 11, 6);
      await db.snippetsDao.insertSnippet(SnippetsCompanion(
        id: const Value('s1'),
        label: const Value('Disk usage'),
        command: const Value('df -h'),
        createdAt: Value(now),
        updatedAt: Value(now),
      ));
      final c = await open(tester, await db.snippetsDao.getById('s1'));
      await tester.enterText(field(en.snippetsLabelHint), 'Disk usage, all');
      await tester.enterText(field(r'docker restart ${NAME:-web}'), 'df -ah');
      await tester.pumpAndSettle();

      await tester.tap(find.text(en.zestCommonSave));
      await tester.pumpAndSettle();

      expect((await db.snippetsDao.getById('s1'))!.command, 'df -ah');
      final said = c.read(notificationCenterProvider).history;
      expect([for (final n in said) n.title], ['Snippet saved: Disk usage, all']);
      expect(said.single.severity, NotificationSeverity.success);
      await finish(tester);
    });

    testWidgets('a save that a missing name blocks says nothing and stores nothing', (tester) async {
      final c = await open(tester, null);
      await tester.enterText(field(r'docker restart ${NAME:-web}'), 'uptime');
      await tester.pumpAndSettle();

      await tester.tap(find.text(en.zestCommonSave));
      await tester.pumpAndSettle();

      expect(await db.snippetsDao.getAll(), isEmpty);
      expect(c.read(notificationCenterProvider).history, isEmpty);
      await finish(tester);
    });
  });

  group("a phone's snippets", () {
    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 20; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 50));
      }
    }

    Future<(AppDatabase, GlobalKey<SnippetsScreenState>)> open(WidgetTester tester, {bool withSnippet = false}) async {
      debugTouchLayout = true;
      debugTopSnackBarOnPhone = true;
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      if (withSnippet) {
        await tester.runAsync(() => db.snippetsDao.insertSnippet(SnippetsCompanion(
              id: const Value('s1'),
              label: const Value('Disk usage'),
              command: const Value('df -h'),
              createdAt: Value(DateTime(2026, 11, 6)),
              updatedAt: Value(DateTime(2026, 11, 6)),
            )));
      }
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Plan()),
        databaseSessionProvider.overrideWith((ref) => DatabaseSessionNotifier()..seed(db)),
      ]);
      addTearDown(container.dispose);
      final key = GlobalKey<SnippetsScreenState>();
      final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => Scaffold(body: SnippetsScreen(key: key)))]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
        ),
      ));
      await settle(tester);
      return (db, key);
    }

    Finder labelField() => find.widgetWithText(TextFormField, en.snippetEditDisplayName);
    Finder commandField() => find.widgetWithText(TextFormField, r'docker restart $[DOCKER]');

    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    }

    testWidgets('a new snippet, created, says "Snippet added" with its name', (tester) async {
      final (db, key) = await open(tester);
      key.currentState!.newSnippet();
      await settle(tester);
      await tester.enterText(labelField(), 'Restart web');
      await tester.enterText(commandField(), 'docker restart web');
      await settle(tester);
      expect(find.text('Snippet added: Restart web'), findsNothing);

      await tester.tap(find.text(en.create));
      await settle(tester);

      expect((await tester.runAsync(db.snippetsDao.getAll))!.single.label, 'Restart web');
      expect(find.text(en.snippetAddedToast('Restart web')), findsOneWidget);
      expect(find.text('Snippet added: Restart web'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('an edit, saved, says "Snippet saved" with its name', (tester) async {
      final (db, key) = await open(tester, withSnippet: true);
      // Its own sheet, as a phone's selection's More opens it with the one
      // snippet selected (a long press selects, 3.4).
      key.currentState!.showSnippetActions('s1');
      await settle(tester);
      await tester.tap(find.text(en.edit));
      await settle(tester);
      await tester.enterText(labelField(), 'Disk usage, all');
      await settle(tester);

      await tester.tap(find.text(en.save));
      await settle(tester);

      expect((await tester.runAsync(() => db.snippetsDao.getById('s1')))!.label, 'Disk usage, all');
      expect(find.text('Snippet saved: Disk usage, all'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('a save that a missing name blocks says nothing and stores nothing', (tester) async {
      final (db, key) = await open(tester);
      key.currentState!.newSnippet();
      await settle(tester);
      await tester.enterText(commandField(), 'uptime');
      await settle(tester);

      await tester.tap(find.text(en.create));
      await settle(tester);

      expect(find.text(en.snippetEditNameRequired), findsOneWidget, reason: 'the form says what is missing');
      expect(await tester.runAsync(db.snippetsDao.getAll), isEmpty);
      expect(find.textContaining('Snippet added'), findsNothing);
      expect(find.textContaining('Snippet saved'), findsNothing);
      await finish(tester);
    });
  });

  group('a save that is not stored', () {
    Future<ProviderContainer> run(WidgetTester tester, Object thrown) async {
      debugTopSnackBarOnPhone = false;
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      bool? result;
      await tester.pumpWidget(ProviderScope(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async => result = await saveSnippetSaying(
                context,
                name: 'Restart web',
                added: true,
                write: () async => throw thrown,
              ),
              child: const Text('save'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('save'));
      await tester.pump();
      await tester.pump();
      expect(result, isFalse);
      return ProviderScope.containerOf(tester.element(find.text('save')));
    }

    testWidgets('says it was not saved, with what was thrown to copy, and never that it was', (tester) async {
      final c = await run(tester, StateError('database is locked'));
      final said = c.read(notificationCenterProvider).history;
      expect([for (final n in said) n.title], [en.snippetNotSaved]);
      expect(said.single.severity, NotificationSeverity.error);
      expect(said.single.details, contains('database is locked'));
    });

    testWidgets("a team's refusal says so in its own words", (tester) async {
      final c = await run(tester, Exception('orchard-access: add'));
      final said = c.read(notificationCenterProvider).history;
      expect([for (final n in said) n.title], [en.orchardWriteNotAllowed]);
      expect(said.single.severity, NotificationSeverity.error);
    });
  });
}
