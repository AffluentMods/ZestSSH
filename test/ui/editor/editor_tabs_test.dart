import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// Several files in tabs (3.4), from
/// several hosts: each tab names its host, a dot while unsaved, every way to
/// close one asks while it holds changes, a 13th file asks which to close,
/// and a tab whose host dropped goes grey with Reconnect.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Finder tab(FakeEditorSource f) => find.byKey(ValueKey('editor-tab-${f.identity}'));

  testWidgets('files from two hosts open side by side, each tab naming its host', (tester) async {
    final nginx = FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;\n');
    final yaml = FakeEditorSource('/home/deploy/app/config.yaml', text: 'app:\n  port: 8080\n');
    final pg = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: 'port = 5432\n');
    await openEditorPage(tester, [nginx, yaml, pg]);
    await openFile(tester, nginx);
    await openFile(tester, yaml);
    await openFile(tester, pg);
    expect(find.byType(TextEditorScreen), findsOneWidget, reason: 'one editor, three tabs');
    for (final (f, host) in [(nginx, 'web-01'), (yaml, 'web-01'), (pg, 'db-primary')]) {
      expect(find.descendant(of: tab(f), matching: find.text(f.fileName)), findsOneWidget);
      expect(find.descendant(of: tab(f), matching: find.text(host)), findsOneWidget);
    }
    // The newest is in front.
    expect(editorCode(tester).text, 'port = 5432\n');
    // A tab is chosen by a tap; the same file opened again is its tab.
    await tester.tap(tab(nginx));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'user www-data;\n');
    await openFile(tester, yaml);
    expect(find.byKey(ValueKey('editor-tab-${yaml.identity}')), findsOneWidget);
    expect(editorCode(tester).text, 'app:\n  port: 8080\n');
  });

  testWidgets('a tab with changes shows the dot', (tester) async {
    final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
    final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
    await openEditorPage(tester, [a, b]);
    await openFile(tester, a);
    editorCode(tester).text = 'a changed\n';
    await tester.pump(const Duration(milliseconds: 150));
    await openFile(tester, b);
    expect(find.byKey(ValueKey('editor-tab-unsaved-${a.identity}')), findsOneWidget);
    expect(find.byKey(ValueKey('editor-tab-unsaved-${b.identity}')), findsNothing);
  });

  testWidgets("closing a tab with changes asks: Cancel keeps it, Don't save closes it, and the last tab closes the editor", (tester) async {
    final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
    final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
    await openEditorPage(tester, [a, b]);
    await openFile(tester, a);
    await openFile(tester, b);
    editorCode(tester).text = 'b changed\n';
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(ValueKey('editor-tab-close-${b.identity}')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveChangesTitle('b.conf')), findsOneWidget);
    expect(find.text(en.editorSaveChangesBody(1)), findsOneWidget);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(tab(b), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('editor-tab-close-${b.identity}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-dont-save')));
    await tester.pumpAndSettle();
    expect(tab(b), findsNothing);
    expect(b.writes, isEmpty);
    // a has nothing to ask about: its close closes the editor.
    await tester.tap(find.byKey(ValueKey('editor-tab-close-${a.identity}')));
    await tester.pumpAndSettle();
    expect(find.byType(TextEditorScreen), findsNothing);
  });

  testWidgets('closing the editor with changes in two tabs asks once, listing both, and Save all saves both', (tester) async {
    final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
    final b = FakeEditorSource('/srv/b.conf', hostLabel: 'db-primary', text: 'b\n');
    await openEditorPage(tester, [a, b]);
    await openFile(tester, a);
    editorCode(tester).text = 'A\n';
    await tester.pump(const Duration(milliseconds: 150));
    await openFile(tester, b);
    editorCode(tester).text = 'B\n';
    await tester.pump(const Duration(milliseconds: 150));
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveChangesManyTitle(2)), findsOneWidget);
    await tester.tap(find.text(en.editorSaveAll));
    await tester.pumpAndSettle();
    expect([for (final w in a.writes) utf8.decode(w)], ['A\n']);
    expect([for (final w in b.writes) utf8.decode(w)], ['B\n']);
    expect(find.byType(TextEditorScreen), findsNothing);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('a 13th file asks which open one to close, and opens in its place', (tester) async {
    final files = [for (var i = 1; i <= 13; i++) FakeEditorSource('/srv/f$i.conf', text: 'file $i\n')];
    await openEditorPage(tester, files);
    for (final f in files.take(12)) {
      await openFile(tester, f);
    }
    expect(find.byType(TextEditorScreen), findsOneWidget);
    await openFile(tester, files.last);
    expect(find.text(en.editorTooManyTabsTitle('f13.conf')), findsOneWidget);
    await tester.tap(find.byKey(ValueKey('editor-close-pick-${files[4].identity}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-close-and-open')));
    await tester.pumpAndSettle();
    expect(find.byKey(ValueKey('editor-tab-${files[4].identity}'), skipOffstage: false), findsNothing);
    expect(editorCode(tester).text, 'file 13\n');
    // Cancel opens nothing.
    final fourteen = FakeEditorSource('/srv/f14.conf', text: 'file 14\n');
    await openFile(tester, fourteen);
    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(editorCode(tester).text, 'file 13\n');
  });

  testWidgets('a tab whose host dropped goes grey with Reconnect, and Reconnect brings it back', (tester) async {
    final pg = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: 'port = 5432\n');
    final web = FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;\n');
    await openEditorPage(tester, [pg, web]);
    await openFile(tester, pg);
    await openFile(tester, web);
    pg.connected = false;
    // The editor looks every few seconds.
    await tester.pump(const Duration(seconds: 4));
    final reconnect = find.byKey(ValueKey('editor-reconnect-${pg.identity}'));
    expect(reconnect, findsOneWidget);
    expect(find.byTooltip(en.editorHostDisconnected('db-primary')), findsOneWidget);
    await tester.tap(reconnect);
    await tester.pumpAndSettle();
    expect(pg.reconnectsAsked, 1);
    expect(reconnect, findsNothing);
  });
}
