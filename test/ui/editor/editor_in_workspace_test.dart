import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

import '../../helpers/code_editor_text.dart';
import '../../helpers/fake_editor_source.dart';

/// On a computer (4.0.1) the file editor is shown in the workspace area,
/// where a terminal shows, not as a page over the whole window: the sidebar
/// and the session tabs stay usable beside it. Going to a terminal puts it
/// behind with its files and their unsaved text kept; its tab brings it
/// back; closing it closes its files. Here a stand-in for the desktop shell
/// hosts it as the shell does (desktop_shell.dart).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<EditorWorkspace> pumpShell(WidgetTester tester, List<FakeEditorSource> files) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1300, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late EditorWorkspace ws;
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (context, ref, _) {
          ws = ref.read(editorWorkspaceProvider)..hostedInShell = true;
          final front = ref.watch(editorWorkspaceProvider.select((w) => w.front));
          return Scaffold(
            body: Row(
              children: [
                // The sidebar and the session tabs, as the shell keeps them.
                SizedBox(
                  width: 240,
                  child: ListView(
                    children: [
                      for (final f in files)
                        TextButton(
                          key: ValueKey('open ${f.identity}'),
                          onPressed: () => openInEditor(context, f),
                          child: Text('open ${f.path}'),
                        ),
                      TextButton(
                        key: const ValueKey('to-terminal'),
                        onPressed: () => ws.front = false,
                        child: const Text('web-01'),
                      ),
                      TextButton(
                        key: const ValueKey('to-editor'),
                        onPressed: () => ws.front = true,
                        child: const Text('Editor'),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: front
                      ? const TextEditorScreen.tabs(key: ValueKey('editor-in-shell'), hosted: true)
                      : const Text('the terminal', key: ValueKey('terminal')),
                ),
              ],
            ),
          );
        }),
      ),
    ));
    return ws;
  }

  testWidgets('a file opens in the workspace area, beside the sidebar and the tabs, not as a page over them',
      (tester) async {
    final nginx = FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;\n');
    final ws = await pumpShell(tester, [nginx]);
    await tester.tap(find.byKey(ValueKey('open ${nginx.identity}')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-in-shell')), findsOneWidget);
    expect(ws.front, isTrue);
    expect(editorCode(tester).text, 'user www-data;\n');
    // No page was pushed over the window: the sidebar is still there to use.
    expect(find.byKey(const ValueKey('to-terminal')).hitTestable(), findsOneWidget);
    expect(Navigator.of(tester.element(find.byKey(const ValueKey('to-terminal')))).canPop(), isFalse);
    // Its tab in the strip does what minimizing did: no minimize button.
    expect(find.byKey(const ValueKey('editor-minimize')), findsNothing);
  });

  testWidgets('going to a terminal puts it behind with its files and unsaved text kept; its tab brings it back as '
      'it was', (tester) async {
    final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
    final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
    final ws = await pumpShell(tester, [a, b]);
    await tester.tap(find.byKey(ValueKey('open ${a.identity}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('open ${b.identity}')));
    await tester.pumpAndSettle();
    editorCode(tester).text = 'b changed\n';
    await tester.pump(const Duration(milliseconds: 150));

    await tester.tap(find.byKey(const ValueKey('to-terminal')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('terminal')), findsOneWidget);
    expect(find.byType(TextEditorScreen), findsNothing);
    expect(ws.length, 2, reason: 'both files are kept');
    expect(ws.unsaved, hasLength(1), reason: 'and the unsaved text with them');
    expect(b.writes, isEmpty);

    await tester.tap(find.byKey(const ValueKey('to-editor')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('editor-in-shell')), findsOneWidget);
    expect(editorCode(tester).text, 'b changed\n');
    expect(find.byKey(ValueKey('editor-tab-${a.identity}')), findsOneWidget);
  });

  testWidgets("closing it closes its files and shows what was there; with unsaved changes its tab's close asks first",
      (tester) async {
    final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
    final ws = await pumpShell(tester, [a]);
    await tester.tap(find.byKey(ValueKey('open ${a.identity}')));
    await tester.pumpAndSettle();
    editorCode(tester).text = 'a changed\n';
    await tester.pump(const Duration(milliseconds: 150));

    // The close button of its tab in the strip runs the editor's own close.
    expect(ws.closeAsked, isNotNull);
    final closing = ws.closeAsked!();
    await tester.pumpAndSettle();
    expect(find.text(en.editorSaveChangesManyTitle(1)).evaluate().isNotEmpty ||
        find.text(en.editorSaveChangesTitle('a.conf')).evaluate().isNotEmpty, isTrue,
        reason: 'unsaved changes are asked about');
    await tester.tap(find.byKey(const ValueKey('editor-dont-save')));
    await tester.pumpAndSettle();
    await closing;
    expect(ws.isEmpty, isTrue);
    expect(ws.front, isFalse);
    expect(find.byKey(const ValueKey('terminal')), findsOneWidget);
    expect(a.writes, isEmpty);

    // Opened again, then closed with its own button and nothing to ask.
    await tester.tap(find.byKey(ValueKey('open ${a.identity}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-close')));
    await tester.pumpAndSettle();
    expect(ws.isEmpty, isTrue);
    expect(find.byKey(const ValueKey('terminal')), findsOneWidget);
  });
}
