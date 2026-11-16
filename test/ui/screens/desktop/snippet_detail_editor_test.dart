import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/snippet_detail_editor.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';

/// Widget coverage for the 1.7 detected-variables table. Each variable renders
/// as a row with a mono Name, a READ-ONLY Default cell (the command string
/// `${VAR:-default}` is the single source of truth for defaults), an editable
/// Prompt cell that persists into snippet metadata, and a computed Required
/// badge.
///
/// Each test unmounts (pumpWidget(SizedBox()) + pump) before it ends so the
/// editor's dispose-scheduled zero-duration timers (category-combobox overlay +
/// the child fields' Drift stream teardown) fire before the framework's
/// "Timer still pending" guard runs.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;
  late AppLocalizations l10n;
  late SharedPreferences prefs;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });
  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // The header's command preview goes through the recording-mode scan,
    // which watches the prefs-backed settings.
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() async {
    await db.close();
  });

  Widget host(Snippet? snippet, {List<ConnectionWithDetails> hosts = const []}) {
    return ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The recording-mode provider instantiates the fleet registrar, which
        // listens to several live DB streams (groups, networks, identities);
        // their teardown timers would trip the pending-timer guard here.
        redactionFleetRegistrar.overrideWith((ref) {}),
        // Replace the live Drift `.watch()` streams the editor's child fields
        // subscribe to (categories / category-meta / connections) with
        // single-value streams. Those DB subscriptions otherwise schedule a
        // zero-duration teardown timer that FakeAsync leaves pending, tripping
        // the framework's "Timer still pending" guard on dispose.
        snippetsProvider.overrideWith((ref) => Stream.value(const <Snippet>[])),
        snippetCategoryMetaProvider
            .overrideWith((ref) => Stream.value(const <SnippetCategory>[])),
        connectionsWithDetailsProvider.overrideWith((ref) => Stream.value(hosts)),
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
    );
  }

  Finder fieldWithHint(String hint) => find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.hintText == hint);

  // The editable per-variable Prompt cell: a borderless TextField whose hint is
  // the "Add a prompt" placeholder. (Lazily reads l10n, so it is safe to build
  // this Finder before setUpAll assigns l10n - the predicate only runs later.)
  final promptCell = find.byWidgetPredicate((w) =>
      w is TextField &&
      w.decoration?.hintText == l10n.zestSnippetsVarPromptHint);

  testWidgets(
      'renders a row per variable and flags only the no-default one as Required',
      (tester) async {
    await db.snippetsDao.insertSnippet(SnippetsCompanion(
      id: const Value('t1'),
      label: const Value('Connect'),
      command: const Value(r'ssh ${USER:-root}@${HOST}'),
      createdAt: Value(DateTime.now()),
      updatedAt: Value(DateTime.now()),
    ));
    final snippet = await db.snippetsDao.getById('t1');

    await tester.pumpWidget(host(snippet));
    await tester.pumpAndSettle();

    // A row per variable.
    expect(find.text('USER'), findsOneWidget);
    expect(find.text('HOST'), findsOneWidget);

    // USER carries a default (root) → NOT required ("No"). HOST has none →
    // Required ("Yes"). Exactly one of each across the two rows.
    expect(find.text(l10n.zestSnippetsVarRequiredYes), findsOneWidget);
    expect(find.text(l10n.zestSnippetsVarRequiredNo), findsOneWidget);

    // The read-only Default cell for USER shows its baked-in default value.
    expect(find.text('root'), findsOneWidget);

    // Unmount + flush so the editor's dispose-scheduled zero-duration timers
    // fire before the framework's "Timer still pending" guard runs.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets(
      r'a ${VAR:-value} default in the command drives the row and persists',
      (tester) async {
    await tester.pumpWidget(host(null)); // new snippet
    await tester.pumpAndSettle();

    // Label + command make the snippet valid (Save enabled). A variable name
    // that does NOT collide with a column header ("Name"/"Default"/…).
    await tester.enterText(fieldWithHint('Restart Docker'), 'Restart web');
    await tester.enterText(fieldWithHint(r'docker restart ${NAME:-web}'),
        r'docker restart ${CONTAINER}');
    await tester.pumpAndSettle();

    // With no default yet, the CONTAINER row is Required.
    expect(find.text('CONTAINER'), findsOneWidget);
    expect(find.text(l10n.zestSnippetsVarRequiredYes), findsOneWidget);

    // Defaults are edited in the command itself now (the Default column is
    // read-only). Add `:-web` to the command → the row updates live.
    await tester.enterText(fieldWithHint(r'docker restart ${NAME:-web}'),
        r'docker restart ${CONTAINER:-web}');
    await tester.pumpAndSettle();

    // The read-only Default cell now shows the parsed default, and the Required
    // badge is gone.
    expect(find.text('web'), findsOneWidget);
    expect(find.text(l10n.zestSnippetsVarRequiredYes), findsNothing);

    // Save persists the command verbatim.
    await tester.tap(find.text(l10n.zestCommonSave));
    await tester.pumpAndSettle();

    final all = await db.snippetsDao.getAll();
    expect(all, hasLength(1));
    expect(all.single.command, r'docker restart ${CONTAINER:-web}');

    // Reloading parses the persisted default back out.
    final reparsed = parseVariablesWithOptions(all.single.command).single;
    expect(reparsed.defaultValue, 'web');
    expect(reparsed.isRequired, isFalse);

    // The save is said ("Snippet added"): its notice closes by itself.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('a per-variable prompt persists into snippet metadata',
      (tester) async {
    await tester.pumpWidget(host(null));
    await tester.pumpAndSettle();

    await tester.enterText(fieldWithHint('Restart Docker'), 'Logs');
    await tester.enterText(fieldWithHint(r'docker restart ${NAME:-web}'),
        r'docker logs ${CONTAINER}');
    await tester.pumpAndSettle();

    // The editable per-variable Prompt cell ("Add a prompt" hint).
    expect(promptCell, findsOneWidget);
    await tester.enterText(promptCell, 'container name');
    await tester.pumpAndSettle();

    await tester.tap(find.text(l10n.zestCommonSave));
    await tester.pumpAndSettle();

    final saved = (await db.snippetsDao.getAll()).single;
    final meta = parseSnippetMetadata(saved.metadata);
    expect(meta.variableDescriptions['CONTAINER'], 'container name');

    // The save is said ("Snippet added"): its notice closes by itself.
    await tester.pump(const Duration(seconds: 4));
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });

  testWidgets('the default host it has, picked again, changes nothing: Save stays off',
      (tester) async {
    final now = DateTime(2026, 10, 19);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'c1', label: 'web-01', host: '192.168.10.21', createdAt: now, updatedAt: now));
    final web = await (db.select(db.connections)..where((c) => c.id.equals('c1'))).getSingle();
    await db.snippetsDao.insertSnippet(SnippetsCompanion(
      id: const Value('t1'),
      label: const Value('Disk usage'),
      command: const Value('df -h'),
      metadata: Value(encodeSnippetMetadata(const SnippetMetadata(defaultConnectionId: 'c1'))),
      createdAt: Value(now),
      updatedAt: Value(now),
    ));
    final snippet = await db.snippetsDao.getById('t1');

    await tester.pumpWidget(host(snippet, hosts: [ConnectionWithDetails(connection: web)]));
    await tester.pumpAndSettle();
    bool saveOn() => tester.widget<ZestPaneFooter>(find.byType(ZestPaneFooter)).saveEnabled;
    expect(saveOn(), isFalse);

    await tester.tap(find.text('web-01'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('web-01').last);
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionPickerDialog), findsNothing, reason: 'picked');
    expect(saveOn(), isFalse, reason: 'the host it has, picked again');

    // The picker read the groups from the database: their stream's teardown
    // runs on a later turn.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
