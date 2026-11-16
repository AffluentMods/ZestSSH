import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// Unsaved drafts (3.4: kept
/// encrypted on the device for 7 days, and Don't save throws the draft away
/// too): kept a few seconds after each change, put back when the file is
/// opened again with what the host's file did since (by its hash), and gone
/// once the text is saved or thrown away.
class _Drafts implements EditorDraftStore {
  final Map<String, EditorDraft> kept = {};

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async => kept[identity];

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async => kept[identity] = draft;

  @override
  Future<void> remove(String identity, {String? team}) async => kept.remove(identity);

  @override
  Future<void> forgetOld({DateTime? now}) async {}
}

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  Future<void> open(WidgetTester tester, _Drafts drafts, FakeEditorSource f) async {
    await openEditorPage(tester, [f], overrides: [editorDraftStoreProvider.overrideWithValue(drafts)]);
    await openFile(tester, f);
  }

  Future<void> type(WidgetTester tester, String text) async {
    editorCode(tester).text = text;
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('a change is kept as a draft a few seconds later, with what it is written in and the file it was typed over', (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: 'port = 5432\n');
    await open(tester, drafts, f);
    await type(tester, 'port = 5433\n');
    expect(drafts.kept, isEmpty, reason: 'not at once');
    await tester.pump(const Duration(seconds: 3));
    final draft = drafts.kept[f.identity]!;
    expect(draft.text, 'port = 5433\n');
    expect(draft.encoding, 'utf8');
    expect(draft.lineBreak, 'lf');
    expect(draft.baseHash, sha256Of(utf8.encode('port = 5432\n')));
    expect(find.text(en.editorUnsavedLinesDraft(1)), findsOneWidget);
  });

  testWidgets('a save forgets the draft', (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/srv/app.conf', text: 'a\n');
    await open(tester, drafts, f);
    await type(tester, 'b\n');
    await tester.pump(const Duration(seconds: 3));
    expect(drafts.kept, hasLength(1));
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(drafts.kept, isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets("Don't save forgets the draft", (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/srv/app.conf', text: 'a\n');
    await open(tester, drafts, f);
    await type(tester, 'b\n');
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.byKey(ValueKey('editor-tab-close-${f.identity}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-dont-save')));
    await tester.pumpAndSettle();
    expect(drafts.kept, isEmpty);
  });

  testWidgets('the editor taken away with changes (a crash, the app killed) keeps them; the file opened again puts them back, safe to save', (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: 'port = 5432\nmax_connections = 100\n');
    await open(tester, drafts, f);
    await type(tester, 'port = 5432\nmax_connections = 200 # raised from 100\n');
    // Gone before the draft's few seconds: it is kept as the editor goes.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(drafts.kept[f.identity]!.text, contains('200'));

    await open(tester, drafts, f);
    expect(editorCode(tester).text, 'port = 5432\nmax_connections = 200 # raised from 100\n');
    expect(find.text(en.editorDraftRestoredTitle), findsOneWidget);
    expect(find.text(en.editorDraftSame('db-primary')), findsOneWidget);
    expect(find.byKey(const ValueKey('editor-unsaved')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(utf8.decode(f.writes.single), contains('200'));
    expect(drafts.kept, isEmpty);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('where the file on the host changed since, the notice says so, and Show changes compares them line by line', (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/srv/app.conf', text: 'one\ntwo\nthree\n');
    drafts.kept[f.identity] = EditorDraft(
      text: 'one\nTWO\nthree\n',
      encoding: 'utf8',
      lineBreak: 'lf',
      baseHash: sha256Of(utf8.encode('one\ntwo\n')),
      keptAt: DateTime(2026, 11, 5, 22, 14),
    );
    await open(tester, drafts, f);
    expect(find.text(en.editorDraftChanged('web-01')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('editor-draft-show')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-changes')), findsOneWidget);
    expect(find.text('- two'), findsOneWidget);
    expect(find.text('+ TWO'), findsOneWidget);
  });

  testWidgets('Discard draft puts the file back as it is and forgets the draft', (tester) async {
    final drafts = _Drafts();
    final f = FakeEditorSource('/srv/app.conf', text: 'kept\n');
    drafts.kept[f.identity] = EditorDraft(
      text: 'typed\n',
      encoding: 'utf8',
      lineBreak: 'lf',
      baseHash: sha256Of(utf8.encode('kept\n')),
      keptAt: DateTime.now(),
    );
    await open(tester, drafts, f);
    expect(editorCode(tester).text, 'typed\n');
    await tester.tap(find.byKey(const ValueKey('editor-draft-discard')));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'kept\n');
    expect(drafts.kept, isEmpty);
    expect(find.byKey(const ValueKey('editor-unsaved')), findsNothing);
    expect(find.text(en.editorDraftRestoredTitle), findsNothing);
  });

  group('kept in the encrypted database', () {
    late AppDatabase db;
    late LocalEditorDraftStore store;
    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      store = LocalEditorDraftStore(LocalStateStore(db));
    });
    tearDown(() => db.close());

    EditorDraft draft(String text, DateTime at) =>
        EditorDraft(text: text, encoding: 'utf8', lineBreak: 'lf', baseHash: null, keptAt: at);

    test('under a key that names neither the host nor the path', () async {
      const identity = 'db-primary\u0000/etc/postgresql/16/main/postgresql.conf';
      await store.write(identity, draft('x', DateTime.now()));
      final keys = await LocalStateStore(db).keysWithPrefix(LocalEditorDraftStore.prefix);
      expect(keys, hasLength(1));
      expect(keys.single, isNot(contains('db-primary')));
      expect(keys.single, isNot(contains('postgresql')));
      expect((await store.read(identity))!.text, 'x');
    });

    test('for 7 days, then gone', () async {
      final now = DateTime.now();
      await store.write('a', draft('fresh', now.subtract(const Duration(days: 6))));
      await store.write('b', draft('old', now.subtract(const Duration(days: 8))));
      expect(await store.read('b'), isNull, reason: 'an old one is not put back');
      await store.write('b', draft('old', now.subtract(const Duration(days: 8))));
      await store.forgetOld(now: now);
      expect((await store.read('a'))!.text, 'fresh');
      expect(await LocalStateStore(db).read(LocalEditorDraftStore.keyOf('b')), isNull);
    });
  });

  test('a comparison leaves out the lines the same at both ends', () {
    final d = compareLines('a\nb\nc\nd\n', 'a\nB\nC\nd\n');
    expect(d.at, 2);
    expect(d.removed, ['b', 'c']);
    expect(d.added, ['B', 'C']);
  });
}
