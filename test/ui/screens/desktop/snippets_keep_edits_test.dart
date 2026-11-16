import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart'
    show refreshPersonState;
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_editor.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippets_library_view.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

/// The Snippets page goes when the computer shows a terminal in its place,
/// and its editor's unsaved edits went with it, with no word. They are kept in
/// memory now, and the same editor opens again with them, unsaved. (All names
/// and commands made up.)
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async => null,
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  Future<(ProviderContainer, ValueNotifier<bool>)> open(
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(2000, 1050);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    db = (await tester.runAsync(() async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final at = DateTime(2026, 10, 2);
      await db.snippetsDao.insertSnippet(
        SnippetsCompanion(
          id: const Value('s-disk'),
          label: const Value('Disk usage'),
          command: const Value('du -sh *'),
          category: const Value('Files'),
          createdAt: Value(at),
          updatedAt: Value(at),
        ),
      );
      return db;
    }))!;
    final container = ProviderContainer(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        connectionsWithDetailsProvider.overrideWith(
          (ref) => Stream.value(const <ConnectionWithDetails>[]),
        ),
        connectionGroupsProvider.overrideWith(
          (ref) => Stream.value(const <ConnectionGroup>[]),
        ),
      ],
    );
    final pageShown = ValueNotifier(true);
    addTearDown(pageShown.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: pageShown,
              builder: (_, shown, _) => shown
                  ? const SnippetsLibraryView()
                  : const Text('a terminal'),
            ),
          ),
        ),
      ),
    );
    await settle(tester);
    return (container, pageShown);
  }

  Future<void> finish(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox());
    container.dispose();
    await tester.pump(const Duration(minutes: 5));
    await tester.runAsync(db.close);
  }

  Finder field(String label) => find.descendant(
    of: find.byWidgetPredicate((w) => w is ZestField && w.label == label),
    matching: find.byType(EditableText),
  );
  SnippetDetailEditorState editor(WidgetTester tester) =>
      tester.state<SnippetDetailEditorState>(find.byType(SnippetDetailEditor));
  ZestDetailScaffold scaffold(WidgetTester tester) =>
      tester.widget<ZestDetailScaffold>(
        find.descendant(
          of: find.byType(SnippetDetailEditor),
          matching: find.byType(ZestDetailScaffold),
        ),
      );
  bool prefsHold(String typed) => prefs.getKeys().any(
    (k) =>
        k.toLowerCase().contains('draft') || '${prefs.get(k)}'.contains(typed),
  );

  Future<void> awayAndBack(
    WidgetTester tester,
    ValueNotifier<bool> pageShown,
  ) async {
    pageShown.value = false;
    await settle(tester);
    expect(
      find.byType(SnippetsLibraryView),
      findsNothing,
      reason: 'the page went, as it does for a terminal',
    );
    pageShown.value = true;
    await settle(tester);
  }

  Future<void> typeNew(WidgetTester tester) async {
    await tester.enterText(field(en.snippetsLabel), 'Restart web');
    await tester.enterText(
      field(en.zestSnippetsFieldCommand),
      r'systemctl restart ${UNIT:-nginx}',
    );
    await tester.enterText(
      field(en.zestSnippetsFieldAbout),
      'Restarts the web server',
    );
    await settle(tester);
    expect(scaffold(tester).isDirty, isTrue);
  }

  testWidgets(
    'a new snippet typed, a terminal, the page again: the editor as it was, unsaved; Save leaves nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await typeNew(tester);
      await awayAndBack(tester, pageShown);

      final kept = editor(tester).keptEdit();
      expect(kept, isNotNull, reason: 'shown as unsaved');
      expect(kept!.snippetId, isNull);
      expect(kept.label, 'Restart web');
      expect(kept.command, r'systemctl restart ${UNIT:-nginx}');
      expect(kept.description, 'Restarts the web server');
      expect(scaffold(tester).isDirty, isTrue);
      expect(find.text('Restart web'), findsWidgets);
      expect(prefsHold('Restart web'), isFalse, reason: 'kept in memory only');

      scaffold(tester).onSave!();
      await settle(tester);
      final rows = (await tester.runAsync(() => db.snippetsDao.getAll()))!;
      expect(rows.where((s) => s.label == 'Restart web'), hasLength(1));
      expect(container.read(snippetDraftsProvider).isEmpty, isTrue);

      await awayAndBack(tester, pageShown);
      expect(
        editor(tester).keptEdit(),
        isNull,
        reason: 'nothing unsaved came back',
      );
      expect(scaffold(tester).isDirty, isFalse);
      await finish(tester, container);
    },
  );

  testWidgets(
    'a saved snippet edited, a terminal, the page again: its editor with the edit, unsaved; Clear and Discard '
    'leave nothing kept',
    (tester) async {
      final (container, pageShown) = await open(tester);
      await tester.tap(find.text('Disk usage').first);
      await settle(tester);
      expect(find.byType(SnippetDetailView), findsOneWidget);
      await tester.tap(find.text(en.zestSnippetsEdit).first);
      await settle(tester);
      await tester.enterText(
        field(en.zestSnippetsFieldCommand),
        'du -sh * | sort -h',
      );
      await settle(tester);
      await awayAndBack(tester, pageShown);

      expect(
        find.byType(SnippetDetailView),
        findsNothing,
        reason: 'the editor, not the details',
      );
      final kept = editor(tester).keptEdit();
      expect(kept?.snippetId, 's-disk');
      expect(kept?.label, 'Disk usage');
      expect(kept?.command, 'du -sh * | sort -h');
      expect(scaffold(tester).isDirty, isTrue);

      scaffold(tester).onCancel!();
      await settle(tester);
      await tester.tap(find.text(en.zestDiscardDiscard).last);
      await settle(tester);
      expect(container.read(snippetDraftsProvider).isEmpty, isTrue);
      await awayAndBack(tester, pageShown);
      expect(editor(tester).keptEdit(), isNull);
      final rows = (await tester.runAsync(() => db.snippetsDao.getAll()))!;
      expect(rows.single.command, 'du -sh *', reason: 'nothing was saved');
      await finish(tester, container);
    },
  );

  testWidgets('a change of profile forgets the edits, kept or on screen', (
    tester,
  ) async {
    final (container, pageShown) = await open(tester);
    await typeNew(tester);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(snippetDraftsProvider).isEmpty, isFalse);

    refreshPersonState(container);
    await settle(tester);
    expect(container.read(snippetDraftsProvider).isEmpty, isTrue);
    pageShown.value = true;
    await settle(tester);
    expect(editor(tester).keptEdit(), isNull);

    await typeNew(tester);
    refreshPersonState(container);
    await settle(tester);
    expect(editor(tester).keptEdit(), isNull);
    pageShown.value = false;
    await settle(tester);
    expect(container.read(snippetDraftsProvider).isEmpty, isTrue);
    expect(prefsHold('Restart web'), isFalse);
    await finish(tester, container);
  });
}
