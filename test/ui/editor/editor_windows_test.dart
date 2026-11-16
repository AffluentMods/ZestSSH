import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider, recordingRedactLevelProvider;
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/editor_window_drop.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_chrome.dart';
import 'package:zestssh/ui/windows/editor_window.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../helpers/fake_editor_source.dart';

/// The file editor on a computer (3.4.1; 3.4.0's editor
/// worked poorly): it minimizes to the status bar and comes back
/// as it was; a file opened joins the editor already open (minimized or not,
/// in the main window or in a window of its own), its tab in front where it is
/// open already, never a second copy; a second editor can be popped out (the
/// first pop-out window was the app's error screen where it named its host);
/// and a tab moves between editor windows (its menu, or dragged out) with its
/// unsaved text.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  setUp(() => L10nGlobal.update(en));
  tearDown(EditorWindows.instance.reset);

  test('a tab travels whole: its text saved and unsaved, encoding, line endings, caret, file version and draft',
      () {
    final source = FakeEditorSource('/srv/app.yaml', text: 'a: 1\r\nb: 2\r\n');
    final doc = EditorDocument.fromBytes(source, source.bytes);
    doc.controller.text = 'a: 1\nb: 3\n';
    doc.controller.selection = const CodeLineSelection.collapsed(index: 1, offset: 3);
    doc
      ..drafted = true
      ..scrollTop = 120;
    final there = EditorTabSnapshot.fromJson(jsonDecode(jsonEncode(EditorTabSnapshot.of(doc, editKey: 'k').toJson())))!;
    final again = there.toDocument(source);
    expect(again.controller.text, 'a: 1\nb: 3\n');
    expect(again.savedText, 'a: 1\nb: 2\n');
    expect(again.modified, isTrue);
    expect(again.lineBreak, EditorLineBreak.crlf);
    expect(again.encoding, EditorEncoding.utf8);
    expect(again.language, EditorLanguage.yaml);
    expect(again.controller.selection, const CodeLineSelection.collapsed(index: 1, offset: 3));
    expect(again.baseline!.sha256, doc.baseline!.sha256);
    expect(again.drafted, isTrue);
    expect(again.scrollTop, 120);
    expect(there.identity, source.identity);
    doc.dispose();
    again.dispose();
  });

  group('on a computer', () {
    late _Windows windows;
    late _Drafts drafts;

    setUp(() {
      drafts = _Drafts();
      windows = _Windows(drafts);
    });

    testWidgets('minimizing keeps every tab, its unsaved text, caret and scrolling, and the chip shows it again',
        (tester) async {
      final long = FakeEditorSource('/var/log/app.log', text: [for (var i = 1; i <= 300; i++) 'line $i'].join('\n'));
      final b = FakeEditorSource('/etc/hosts', text: '127.0.0.1 localhost\n');
      await windows.start(tester, [long, b]);
      await windows.open(tester, long);
      await windows.open(tester, b);
      _code(tester).text = '127.0.0.1 localhost\n10.0.0.5 db-primary\n';
      _code(tester).selection = const CodeLineSelection.collapsed(index: 1, offset: 4);
      await tester.pump();
      await tester.tap(find.byKey(ValueKey('editor-tab-${long.identity}')));
      await tester.pumpAndSettle();
      final scroller = tester.widget<CodeEditor>(find.byType(CodeEditor)).scrollController!.verticalScroller;
      scroller.jumpTo(900);
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('editor-minimize')));
      await tester.pumpAndSettle();
      expect(find.byType(TextEditorScreen), findsNothing, reason: 'back to the page behind it');
      expect(find.text(en.editorMinimizedFiles(2)), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-minimized-unsaved')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('editor-minimized')));
      await tester.pumpAndSettle();
      expect(find.byType(TextEditorScreen), findsOneWidget);
      expect(find.byKey(const ValueKey('editor-minimized')), findsNothing);
      expect(_code(tester).text, startsWith('line 1\n'), reason: 'the tab that was in front');
      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).scrollController!.verticalScroller.offset, 900);
      await tester.tap(find.byKey(ValueKey('editor-tab-${b.identity}')));
      await tester.pumpAndSettle();
      expect(_code(tester).text, '127.0.0.1 localhost\n10.0.0.5 db-primary\n');
      expect(_code(tester).selection, const CodeLineSelection.collapsed(index: 1, offset: 4));
      await windows.end(tester);
    });

    testWidgets('a file opened while the editor is minimized joins its tabs and shows it; one open already comes to the front',
        (tester) async {
      final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
      final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
      final c = FakeEditorSource('/srv/c.conf', text: 'c\n');
      await windows.start(tester, [a, b, c]);
      await windows.open(tester, a);
      _code(tester).text = 'a changed\n';
      await tester.pump();
      await windows.open(tester, b);
      await tester.tap(find.byKey(const ValueKey('editor-minimize')));
      await tester.pumpAndSettle();

      await windows.open(tester, c);
      expect(find.byType(TextEditorScreen), findsOneWidget, reason: 'one editor, shown again');
      expect(_tabs(tester), [a.identity, b.identity, c.identity]);
      expect(_code(tester).text, 'c\n');

      await tester.tap(find.byKey(const ValueKey('editor-minimize')));
      await tester.pumpAndSettle();
      await windows.open(tester, a);
      expect(find.byType(TextEditorScreen), findsOneWidget);
      expect(_tabs(tester), [a.identity, b.identity, c.identity], reason: 'never a second copy of a.conf');
      expect(_code(tester).text, 'a changed\n', reason: 'its tab in front, its unsaved text kept');
      await windows.end(tester);
    });

    testWidgets('a 13th file opened while minimized asks which to close; Cancel opens nothing and keeps it minimized',
        (tester) async {
      final files = [for (var i = 1; i <= 13; i++) FakeEditorSource('/srv/f$i.conf', text: 'file $i\n')];
      await windows.start(tester, files);
      for (final f in files.take(12)) {
        await windows.open(tester, f);
      }
      await tester.tap(find.byKey(const ValueKey('editor-minimize')));
      await tester.pumpAndSettle();
      await windows.open(tester, files.last);
      expect(find.text(en.editorTooManyTabsTitle('f13.conf')), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(find.byType(TextEditorScreen), findsNothing);
      expect(find.text(en.editorMinimizedFiles(12)), findsOneWidget);
      await windows.open(tester, files.last);
      await tester.tap(find.byKey(ValueKey('editor-close-pick-${files[2].identity}')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-close-and-open')));
      await tester.pumpAndSettle();
      expect(find.byType(TextEditorScreen), findsOneWidget);
      expect(_code(tester).text, 'file 13\n');
      expect(_tabs(tester), hasLength(12));
      expect(_tabs(tester), isNot(contains(files[2].identity)));
      await windows.end(tester);
    });

    testWidgets('a second editor pops out as the first did, each in its own window naming its host', (tester) async {
      final a = FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;\n');
      final b = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary', text: 'port = 5432\n');
      await windows.start(tester, [a, b]);
      await windows.open(tester, a);
      await windows.open(tester, b);
      _code(tester).text = 'port = 5433\n';
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      expect(windows.titles.values, ['ZestSSH - Editor 2']);
      // The main window's editor still has nginx.conf: it pops out too.
      expect(windows.mainTabs(tester), [a.identity]);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')).first);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(windows.titles.values, ['ZestSSH - Editor 2', 'ZestSSH - Editor 3']);
      expect(windows.mainTabs(tester), isEmpty);
      expect(find.text(en.mainAppSomethingWentWrong), findsNothing);
      expect(windows.tabsOf(tester, windows.ids[0]), [b.identity]);
      expect(windows.tabsOf(tester, windows.ids[1]), [a.identity]);
      expect(windows.textOf(tester, windows.ids[0]), 'port = 5433\n', reason: 'its unsaved text went with it');
      expect(find.text('db-primary'), findsWidgets);
      // Saved there: written here, through the main window's connection.
      await windows.save(tester, windows.ids[0]);
      expect([for (final w in b.writes) utf8.decode(w)], ['port = 5433\n']);
      await windows.end(tester);
    });

    testWidgets('the app locks with a question open in a window of its own: the cover is over the question too, '
        'and a click meets the cover', (tester) async {
      final a = FakeEditorSource('/etc/nginx/nginx.conf', text: 'user www-data;');
      await windows.start(tester, [a]);
      await windows.open(tester, a);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      final id = windows.ids.single;
      // A question the editor's window opens over its page: a route of the window's navigator.
      unawaited(showDialog<void>(
        context: tester.element(find.descendant(
            of: find.byKey(ValueKey('window-$id')), matching: find.byType(TextEditorScreen))),
        builder: (_) => const AlertDialog(
          key: ValueKey('a-question'),
          content: Text('Save before closing?'),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('a-question')), findsOneWidget);

      windows.windowsLocked.value = true;
      await tester.pumpAndSettle();
      final cover = find.descendant(of: find.byKey(ValueKey('window-$id')), matching: find.byKey(const ValueKey('pop-out-locked')));
      expect(cover, findsOneWidget);
      final hit = tester.hitTestOnBinding(tester.getCenter(find.byKey(const ValueKey('a-question'))));
      expect(hit.path.any((e) => e.target == tester.renderObject(cover)), isTrue,
          reason: 'the cover, not the question, is what a click meets');

      windows.windowsLocked.value = false;
      await tester.pumpAndSettle();
      expect(cover, findsNothing);
      expect(find.byKey(const ValueKey('a-question')), findsOneWidget, reason: 'unlocked, the question is as it was');
      Navigator.of(tester.element(find.byKey(const ValueKey('a-question')))).pop();
      await tester.pumpAndSettle();
      await windows.end(tester);
    });

    testWidgets(
        'recording mode reaches a window of its own and is kept in step there: '
        'its host names are masked as it turns on after the tab moved, and shown again as it turns off '
        '(found in a security review)', (tester) async {
      final b = FakeEditorSource('/etc/postgresql/16/main/postgresql.conf', hostLabel: 'db-primary-01', text: 'port = 5432\n');
      // As main.dart does: each change of recording mode goes to the windows.
      Redactor.instance
        ..enabled = false
        ..level = RedactLevel.layout
        ..onChanged = () => unawaited(EditorWindows.instance.broadcastRecording());
      addTearDown(() => Redactor.instance
        ..onChanged = null
        ..enabled = false
        ..level = RedactLevel.layout);
      await windows.start(tester, [b]);
      await windows.open(tester, b);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      final id = windows.ids.single;
      Finder inWindow(Finder f) => find.descendant(of: find.byKey(ValueKey('window-$id')), matching: f);
      expect(inWindow(find.text('db-primary-01')), findsWidgets);
      // What the window's own recording mode says, which its widgets watch.
      bool recordingThere() => ProviderScope.containerOf(tester.element(inWindow(find.byType(TextEditorScreen))))
          .read(recordingModeProvider);
      expect(recordingThere(), isFalse);

      // Turned on after the tab moved out: masked there at once.
      Redactor.instance.enabled = true;
      await tester.pumpAndSettle();
      expect(recordingThere(), isTrue);
      expect(inWindow(find.text('db-primary-01')), findsNothing, reason: 'never the real name while recording');
      expect(inWindow(find.text(Redactor.name('db-primary-01'))), findsWidgets);

      // The level too.
      Redactor.instance.level = RedactLevel.strict;
      await tester.pumpAndSettle();
      expect(ProviderScope.containerOf(tester.element(inWindow(find.byType(TextEditorScreen))))
          .read(recordingRedactLevelProvider), RedactLevel.strict);
      expect(inWindow(find.text('db-primary-01')), findsNothing);

      // Turned off: the real name again (a label masked as it was handed over
      // stayed masked for good).
      Redactor.instance.enabled = false;
      await tester.pumpAndSettle();
      expect(recordingThere(), isFalse);
      expect(inWindow(find.text('db-primary-01')), findsWidgets);
      await windows.end(tester);
    });

    testWidgets('a window of its own that opens while recording mode is on masks from the start', (tester) async {
      final b = FakeEditorSource('/etc/hosts', hostLabel: 'db-primary-01', text: '127.0.0.1 localhost\n');
      await windows.start(tester, [b]);
      await windows.open(tester, b);
      // On in the main window only (as the main window's engine has it).
      EditorWindows.instance.recording = () => {...Redactor.instance.toWindow(), 'on': true};
      addTearDown(() {
        EditorWindows.instance.recording = Redactor.instance.toWindow;
        Redactor.instance.enabled = false;
      });
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      final id = windows.ids.single;
      final there = ProviderScope.containerOf(
          tester.element(find.descendant(of: find.byKey(ValueKey('window-$id')), matching: find.byType(TextEditorScreen))));
      expect(there.read(recordingModeProvider), isTrue, reason: 'asked of the main window as it opened');
      expect(find.descendant(of: find.byKey(ValueKey('window-$id')), matching: find.text('db-primary-01')), findsNothing);
      await windows.end(tester);
    });

    testWidgets('while only a window of its own has an editor, a file opens there; one open there comes to the front',
        (tester) async {
      final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
      final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
      await windows.start(tester, [a, b]);
      await windows.open(tester, a);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      final window = windows.ids.single;
      windows.focused.clear();

      await windows.open(tester, b);
      expect(find.byType(TextEditorScreen), findsOneWidget, reason: 'the window\'s; none in the main window');
      expect(windows.mainTabs(tester), isEmpty);
      expect(windows.tabsOf(tester, window), [a.identity, b.identity]);
      expect(windows.focused, [window]);

      windows.focused.clear();
      await windows.open(tester, a);
      expect(windows.tabsOf(tester, window), [a.identity, b.identity], reason: 'never a second copy');
      expect(windows.textOf(tester, window), 'a\n', reason: 'its tab in front');
      expect(windows.focused, [window]);
      await windows.end(tester);
    });

    testWidgets('a 13th file sent to a full window of its own asks there; Cancel opens nothing', (tester) async {
      final files = [for (var i = 1; i <= 13; i++) FakeEditorSource('/srv/f$i.conf', text: 'file $i\n')];
      await windows.start(tester, files);
      await windows.open(tester, files.first);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      for (final f in files.skip(1).take(11)) {
        await windows.open(tester, f);
      }
      final window = windows.ids.single;
      expect(windows.tabsOf(tester, window), hasLength(12));
      await windows.open(tester, files.last);
      expect(find.text(en.editorTooManyTabsTitle('f13.conf')), findsOneWidget);
      await tester.tap(find.text(en.cancel));
      await tester.pumpAndSettle();
      expect(windows.tabsOf(tester, window), hasLength(12));
      expect(windows.mainTabs(tester), isEmpty, reason: 'nothing opened anywhere');
      expect(EditorWindows.instance.bridge('none'), isNull);
      await windows.end(tester);
    });

    testWidgets('a tab moves between windows with its unsaved text: its menu, to another window and back to the main window',
        (tester) async {
      final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
      final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
      await windows.start(tester, [a, b]);
      await windows.open(tester, a);
      await windows.open(tester, b);
      // Two windows of their own: b in one, a in the other.
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')).first);
      await tester.pumpAndSettle();
      final (first, second) = (windows.ids[0], windows.ids[1]);
      await windows.type(tester, second, 'a typed in a window\n');
      await tester.pump(const Duration(seconds: 3));
      expect(drafts.kept[a.identity]?.text, 'a typed in a window\n', reason: 'its draft kept by the main window');

      // Its menu: Move to editor window 2.
      await windows.tabMenu(tester, second, a);
      expect(find.text(en.editorMoveToMainWindow), findsOneWidget);
      expect(find.text(en.editorMoveToNewWindow), findsOneWidget);
      await tester.tap(find.text(en.editorMoveToWindow(2)));
      await tester.pumpAndSettle();
      expect(windows.tabsOf(tester, first), [b.identity, a.identity]);
      expect(windows.textOf(tester, first), 'a typed in a window\n');
      expect(windows.ids, [first], reason: 'the window whose last tab moved closed');

      // Its menu again: Move to the main window.
      await windows.tabMenu(tester, first, a);
      await tester.tap(find.text(en.editorMoveToMainWindow));
      await tester.pumpAndSettle();
      expect(windows.tabsOf(tester, first), [b.identity]);
      expect(windows.mainTabs(tester), [a.identity]);
      expect(_mainCode(tester).text, 'a typed in a window\n');
      expect(windows.mainDoc(tester, a).modified, isTrue, reason: 'still unsaved, as it was');
      expect(windows.mainDoc(tester, a).savedText, 'a\n');

      // Saved in the main window: the draft goes.
      await tester.tap(find.byKey(const ValueKey('editor-save')).first);
      await tester.pumpAndSettle();
      expect([for (final w in a.writes) utf8.decode(w)], ['a typed in a window\n']);
      await tester.pump(const Duration(seconds: 3));
      expect(drafts.kept[a.identity], isNull);
      await windows.end(tester);
    });

    testWidgets('a tab dragged out of the main window lands in the window it is let go on', (tester) async {
      final a = FakeEditorSource('/srv/a.conf', text: 'a\n');
      final b = FakeEditorSource('/srv/b.conf', text: 'b\n');
      await windows.start(tester, [a, b]);
      await windows.open(tester, a);
      await tester.tap(find.byKey(const ValueKey('editor-pop-out')));
      await tester.pumpAndSettle();
      final window = windows.ids.single;
      await windows.open(tester, b); // into the window of its own
      // A file in the main window's own editor, then dragged out onto the
      // window of its own (as the system says where it was let go).
      final c = FakeEditorSource('/srv/c.conf', text: 'c changed\n');
      final doc = EditorDocument.fromBytes(c, c.bytes);
      await takeIntoEditor(windows.mainContext, doc);
      await tester.pumpAndSettle();
      _mainCode(tester).text = 'c unsaved\n';
      await tester.pump();
      EditorWindows.instance.dropResolver = _DropOn(EditorWindows.instance.titleOf(window));
      final tab = find.byKey(ValueKey('editor-tab-${c.identity}'));
      await tester.drag(tab, const Offset(-3000, 0));
      await tester.pumpAndSettle();
      expect(windows.tabsOf(tester, window), [a.identity, b.identity, c.identity]);
      expect(windows.textOf(tester, window), 'c unsaved\n');
      expect(windows.mainTabs(tester), isEmpty);
      await windows.end(tester);
    });
  });
}

CodeLineEditingController _code(WidgetTester tester) =>
    tester.widget<CodeEditor>(find.byType(CodeEditor).first).controller!;

CodeLineEditingController _mainCode(WidgetTester tester) => tester
    .widget<CodeEditor>(find.descendant(of: find.byKey(const ValueKey('main-window')), matching: find.byType(CodeEditor)))
    .controller!;

List<String> _tabs(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(TextEditorScreen).first))
        .read(editorWorkspaceProvider)
        .docs
        .map((d) => d.source.identity)
        .toList();

/// Drafts kept in memory, as the main window's databases keep them.
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

class _DropOn extends EditorDropResolver {
  const _DropOn(this.title);

  final String title;

  @override
  EditorDrop resolve() => EditorDrop(ours: true, windowTitle: title);
}

/// The app's windows in one test: the main window at the left, each editor
/// window of its own beside it (its own ProviderScope and MaterialApp, as its
/// own engine has), the calls between them as desktop_multi_window carries
/// them.
class _Windows {
  _Windows(this.drafts);

  final _Drafts drafts;
  final ValueNotifier<List<int>> _open = ValueNotifier([]);
  final Map<int, Map<String, dynamic>> payloads = {};
  final Map<int, String> titles = {};
  final List<int> focused = [];
  final _mainKey = GlobalKey();
  int _next = 1;

  List<int> get ids => _open.value;

  /// The app lock, as the main window tells its windows of it.
  final windowsLocked = ValueNotifier<bool>(false);
  BuildContext get mainContext => _mainKey.currentContext!;

  EditorWindowBackend asWindow(int id) => _Backend(this, id);

  Future<void> start(WidgetTester tester, List<EditorSource> files) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(2400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    EditorWindows.instance
      ..reset()
      ..backend = asWindow(kMainWindowId)
      ..dropResolver = const _DropOn('nowhere')
      ..drafts = (() => drafts)
      ..takeIntoMain = ((doc) => takeIntoEditor(mainContext, doc));
    addTearDown(() {
      EditorWindows.instance
        ..backend = const PluginEditorWindowBackend()
        ..dropResolver = EditorDropResolver.platform()
        ..drafts = null
        ..takeIntoMain = null;
    });
    final main = ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        editorDraftStoreProvider.overrideWithValue(drafts),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          key: _mainKey,
          builder: (context) => Scaffold(
            body: Column(
              children: [
                for (final f in files)
                  TextButton(
                    key: ValueKey('open ${f.identity}'),
                    onPressed: () => openInEditor(context, f),
                    child: Text('open ${f.path}'),
                  ),
                // The status bar's chip of the minimized editor.
                EditorMinimizedChip(onShow: () => showEditorTabs(context)),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: ValueListenableBuilder<List<int>>(
        valueListenable: _open,
        builder: (context, open, _) => Row(
          children: [
            Expanded(child: KeyedSubtree(key: const ValueKey('main-window'), child: main)),
            for (final id in open)
              Expanded(
                child: KeyedSubtree(
                  key: ValueKey('window-$id'),
                  child: editorWindowApp(
                    windowId: id,
                    payload: payloads[id]!,
                    backend: asWindow(id),
                    locked: windowsLocked,
                    onActivity: () {},
                  ),
                ),
              ),
          ],
        ),
      ),
    ));
  }

  /// Opens [file] from the main window's page, as the file managers do
  /// (behind the editor, or beside it).
  Future<void> open(WidgetTester tester, EditorSource file) async {
    unawaited(openInEditor(mainContext, file));
    await tester.pumpAndSettle();
  }

  Finder _in(int id, Finder f) => find.descendant(of: find.byKey(ValueKey('window-$id')), matching: f);

  EditorWorkspace _wsOf(WidgetTester tester, int id) =>
      ProviderScope.containerOf(tester.element(_in(id, find.byType(TextEditorScreen)))).read(editorWorkspaceProvider);

  List<String> tabsOf(WidgetTester tester, int id) => [for (final d in _wsOf(tester, id).docs) d.source.identity];

  String textOf(WidgetTester tester, int id) => _wsOf(tester, id).current!.controller.text;

  List<String> mainTabs(WidgetTester tester) => [
        for (final d in ProviderScope.containerOf(mainContext).read(editorWorkspaceProvider).docs) d.source.identity,
      ];

  EditorDocument mainDoc(WidgetTester tester, EditorSource f) =>
      ProviderScope.containerOf(mainContext).read(editorWorkspaceProvider).byIdentity(f.identity)!;

  Future<void> type(WidgetTester tester, int id, String text) async {
    _wsOf(tester, id).current!.controller.text = text;
    await tester.pump();
  }

  Future<void> save(WidgetTester tester, int id) async {
    await tester.tap(_in(id, find.byKey(const ValueKey('editor-save'))));
    await tester.pumpAndSettle();
  }

  Future<void> tabMenu(WidgetTester tester, int id, EditorSource f) async {
    await tester.tap(_in(id, find.byKey(ValueKey('editor-tab-${f.identity}'))), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
  }

  /// Lets what is waiting run out (a draft is kept two seconds after a
  /// change).
  Future<void> end(WidgetTester tester) => tester.pump(const Duration(seconds: 3));
}

class _Backend implements EditorWindowBackend {
  _Backend(this.windows, this.self);

  final _Windows windows;
  final int self;

  @override
  Future<int> createWindow(String payload) async {
    final id = ++windows._next;
    windows.payloads[id] = jsonDecode(payload) as Map<String, dynamic>;
    windows._open.value = [...windows._open.value, id];
    return id;
  }

  @override
  Future<void> place(int id, Rect frame, String title) async => windows.titles[id] = title;

  @override
  Future<void> focus(int id) async => windows.focused.add(id);

  @override
  Future<void> close(int id) async {
    windows._open.value = [for (final w in windows._open.value) if (w != id) w];
    windows.titles.remove(id);
  }

  @override
  Future<List<int>> windowIds() async => List.of(windows._open.value);

  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) async {
    if (id == kMainWindowId) {
      if (method == 'editorNanoKeys' || method == 'editorMinimap') return '';
      return await EditorWindows.instance.handle(method, arguments, self) ?? '';
    }
    if (!windows._open.value.contains(id)) throw PlatformException(code: '-1', message: 'target window not found.');
    return await answerEditorWindowCall(id, method, arguments) ?? '';
  }
}
