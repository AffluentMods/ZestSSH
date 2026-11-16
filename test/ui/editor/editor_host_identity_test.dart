import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_hosts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// The editor knows a file by its host's id and the space it is kept in,
/// never by the label it shows (found in a 3.4 security review): two hosts called
/// "web" are two hosts, Save writes to the one the tab was opened from, and
/// a draft never moves between hosts, or between Personal and a team.
class _Drafts implements EditorDraftStore {
  /// Kept by (team, identity); '' for Personal.
  final Map<(String, String), EditorDraft> kept = {};

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async => kept[(team ?? '', identity)];

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async => kept[(team ?? '', identity)] = draft;

  @override
  Future<void> remove(String identity, {String? team}) async => kept.remove((team ?? '', identity));

  @override
  Future<void> forgetOld({DateTime? now}) async {}
}

EditorDraft _draft(String text, {String? over}) => EditorDraft(
      text: text,
      encoding: 'utf8',
      lineBreak: 'lf',
      baseHash: over == null ? null : sha256Of(utf8.encode(over)),
      keptAt: DateTime.now(),
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  const path = '/etc/nginx/nginx.conf';
  FakeEditorSource staging() => FakeEditorSource(path,
      hostLabel: 'web', host: EditorHost.saved(connectionId: 'staging-id'), text: 'worker_processes 1;\n');
  FakeEditorSource production() => FakeEditorSource(path,
      hostLabel: 'web', host: EditorHost.saved(team: 'team-a', connectionId: 'prod-id'), text: 'worker_processes 8;\n');

  Future<void> type(WidgetTester tester, String text) async {
    editorCode(tester).text = text;
    await tester.pump(const Duration(milliseconds: 150));
  }

  testWidgets('one path on two hosts with the same label opens two tabs, and Save writes to the tab\'s own host', (tester) async {
    final a = staging();
    final b = production();
    expect(a.identity, isNot(b.identity));
    await openEditorPage(tester, [a, b]);
    await openFile(tester, a);
    await openFile(tester, b);
    expect(find.byKey(ValueKey('editor-tab-${a.identity}')), findsOneWidget);
    expect(find.byKey(ValueKey('editor-tab-${b.identity}')), findsOneWidget);
    // The second host's file is read, not the first host's tab shown again.
    expect(editorCode(tester).text, 'worker_processes 8;\n');

    await type(tester, 'worker_processes 16;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(utf8.decode(b.writes.single), 'worker_processes 16;\n');
    expect(a.writes, isEmpty, reason: 'the other "web" is never written');

    await tester.tap(find.byKey(ValueKey('editor-tab-${a.identity}')));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'worker_processes 1;\n');
    await type(tester, 'worker_processes 2;\n');
    await tester.tap(find.byKey(const ValueKey('editor-save')));
    await tester.pumpAndSettle();
    expect(utf8.decode(a.writes.single), 'worker_processes 2;\n');
    expect(b.writes, hasLength(1));
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('the same host under another account is another tab', (tester) async {
    final deploy = FakeEditorSource(path, hostLabel: 'web', host: EditorHost.saved(connectionId: 'h', account: 'deploy-key'));
    final own = FakeEditorSource(path, hostLabel: 'web', host: EditorHost.saved(connectionId: 'h'));
    expect(deploy.identity, isNot(own.identity));
  });

  testWidgets('panes with no host the editor can name ("Remote") never share a tab, and keep no draft', (tester) async {
    final drafts = _Drafts();
    final left = FakeEditorSource(path, hostLabel: 'Remote', host: EditorHost.unknown(), text: 'left\n');
    final right = FakeEditorSource(path, hostLabel: 'Remote', host: EditorHost.unknown(), text: 'right\n');
    expect(left.identity, isNot(right.identity));
    await openEditorPage(tester, [left, right], overrides: [editorDraftStoreProvider.overrideWithValue(drafts)]);
    await openFile(tester, left);
    await openFile(tester, right);
    expect(editorCode(tester).text, 'right\n');
    await type(tester, 'typed\n');
    await tester.pump(const Duration(seconds: 3));
    expect(drafts.kept, isEmpty);
    // Files opened beside it ("+") are on the same host.
    expect(left.sibling('/etc/hosts')!.host.key, left.host.key);
  });

  testWidgets("a draft of one host's file is never put in another host's tab of the same label and path", (tester) async {
    final drafts = _Drafts();
    final a = staging();
    final b = production();
    drafts.kept[('', a.identity)] = _draft('worker_processes 4; # staging only\n', over: 'worker_processes 1;\n');
    await openEditorPage(tester, [b], overrides: [editorDraftStoreProvider.overrideWithValue(drafts)]);
    await openFile(tester, b);
    expect(editorCode(tester).text, 'worker_processes 8;\n');
    expect(find.text(en.editorDraftRestoredTitle), findsNothing);
  });

  testWidgets("a team host's draft is kept in that team's store, never in Personal", (tester) async {
    final drafts = _Drafts();
    final b = production();
    await openEditorPage(tester, [b], overrides: [editorDraftStoreProvider.overrideWithValue(drafts)]);
    await openFile(tester, b);
    await type(tester, 'worker_processes 9;\n');
    await tester.pump(const Duration(seconds: 3));
    expect(drafts.kept.keys.single, ('team-a', b.identity));
  });

  group('a draft kept under the label (before drafts named the host by its id)', () {
    Future<void> openWith(WidgetTester tester, _Drafts drafts, FakeEditorSource f,
        List<({String? team, String connectionId})> owners) async {
      await openEditorPage(tester, [f], overrides: [
        editorDraftStoreProvider.overrideWithValue(drafts),
        editorLabelOwnersProvider.overrideWithValue((_) async => owners),
      ]);
      await openFile(tester, f);
    }

    testWidgets('is put back where the label is that one host\'s alone, and moved under its id', (tester) async {
      final drafts = _Drafts();
      final a = staging();
      drafts.kept[('', a.labelIdentity)] = _draft('worker_processes 3;\n', over: 'worker_processes 1;\n');
      await openWith(tester, drafts, a, [(team: null, connectionId: 'staging-id')]);
      expect(editorCode(tester).text, 'worker_processes 3;\n');
      expect(drafts.kept.keys, [('', a.identity)]);
    });

    testWidgets('is left unopened where two hosts share the label', (tester) async {
      final drafts = _Drafts();
      final a = staging();
      drafts.kept[('', a.labelIdentity)] = _draft('worker_processes 3;\n');
      await openWith(tester, drafts, a, [(team: null, connectionId: 'staging-id'), (team: 'team-a', connectionId: 'prod-id')]);
      expect(editorCode(tester).text, 'worker_processes 1;\n');
      expect(drafts.kept.keys, [('', a.labelIdentity)], reason: 'left as it was, to go after its 7 days');
    });

    testWidgets('is left unopened where the one host with the label is another (in a team)', (tester) async {
      final drafts = _Drafts();
      final a = staging();
      drafts.kept[('', a.labelIdentity)] = _draft('worker_processes 3;\n');
      await openWith(tester, drafts, a, [(team: 'team-a', connectionId: 'staging-id')]);
      expect(editorCode(tester).text, 'worker_processes 1;\n');
    });
  });

  group('kept in the database of the host\'s own space', () {
    late AppDatabase tree;
    late AppDatabase team;
    setUp(() {
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      team = AppDatabase.forTesting(NativeDatabase.memory());
    });
    tearDown(() async {
      await tree.close();
      await team.close();
    });

    test("a team host's draft is in the team's database; with the team closed it is neither kept nor read", () async {
      var open = true;
      final store = LocalEditorDraftStore(LocalStateStore(tree),
          teams: (id) => id == 'team-a' && open ? LocalStateStore(team) : null,
          allTeams: () => [if (open) LocalStateStore(team)]);
      await store.write('x', _draft('team text'), team: 'team-a');
      expect(await LocalStateStore(tree).keysWithPrefix(LocalEditorDraftStore.prefix), isEmpty);
      expect(await LocalStateStore(team).keysWithPrefix(LocalEditorDraftStore.prefix), hasLength(1));
      expect(await store.read('x'), isNull, reason: 'not in Personal');
      expect((await store.read('x', team: 'team-a'))!.text, 'team text');
      open = false;
      expect(await store.read('x', team: 'team-a'), isNull);
      await store.write('y', _draft('lost'), team: 'team-a');
      expect(await LocalStateStore(tree).keysWithPrefix(LocalEditorDraftStore.prefix), isEmpty);
    });

    test('old drafts go as a database opens, the editor not opened at all', () async {
      final old = EditorDraft(
          text: 'old', encoding: 'utf8', lineBreak: 'lf', baseHash: null, keptAt: DateTime.now().subtract(const Duration(days: 8)));
      await LocalEditorDraftStore(LocalStateStore(team)).write('z', old);
      await LocalEditorDraftStore.forgetOldIn(LocalStateStore(team));
      expect(await LocalStateStore(team).keysWithPrefix(LocalEditorDraftStore.prefix), isEmpty);
    });
  });

  test('two untitled files handed over from one host (a window of its own) are two files', () {
    final one = TextEditorSource(fileName: 'untitled', initialText: '', hostLabel: 'web');
    final two = TextEditorSource(fileName: 'untitled', initialText: '', hostLabel: 'web');
    expect(one.identity, isNot(two.identity));
    expect(one.host.known, isFalse, reason: 'keeps no draft');
  });
}
