import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';

/// A file for the editor's tests, held here: what it holds, when it was
/// changed, whether its host is connected, and what was written to it.
class FakeEditorSource extends EditorSource {
  /// On [host] where one is given, else on a Personal host whose id comes
  /// from its label (this computer where it has none).
  FakeEditorSource(this.path,
      {this.hostLabel = 'web-01', EditorHost? host, String text = 'hello\n', List<int>? bytes, this.accessIs})
      : bytes = Uint8List.fromList(bytes ?? utf8.encode(text)),
        host = host ??
            (hostLabel == null ? const EditorHost.thisComputer() : EditorHost.saved(connectionId: 'id-$hostLabel'));

  @override
  final String path;

  @override
  final String? hostLabel;

  @override
  final EditorHost host;

  Uint8List bytes;
  DateTime modified = DateTime(2026, 11, 6, 9);

  /// Whether the host says the file's hash.
  bool hashes = true;

  bool connected = true;

  /// Whether Reconnect brings it back.
  bool reconnects = true;
  int reconnectsAsked = 0;

  final List<Uint8List> writes = [];
  final List<(Uint8List, String)> rootWrites = [];
  Object? writeFails;
  Object? rootWriteFails;
  FileAccess? accessIs;

  /// Someone else changes the file on its host to [to], keeping its time
  /// where [sameTime] (a file put back from an older copy).
  void changedElsewhere(String to, {bool sameTime = false}) {
    bytes = Uint8List.fromList(utf8.encode(to));
    if (!sameTime) modified = modified.add(const Duration(minutes: 1));
  }

  @override
  String get fileName => path.split('/').last;

  @override
  Future<Uint8List> read() async => bytes;

  @override
  Future<void> write(Uint8List data) async {
    final fails = writeFails;
    if (fails != null) throw fails;
    writes.add(data);
    bytes = data;
    modified = modified.add(const Duration(seconds: 5));
  }

  @override
  Future<FileVersion?> version() async =>
      FileVersion(modified: modified, size: bytes.length, sha256: hashes ? sha256Of(bytes) : null);

  @override
  Future<FileAccess?> access() async => accessIs;

  @override
  Future<void> writeAsRoot(Uint8List data, String password) async {
    final fails = rootWriteFails;
    if (fails != null) throw fails;
    rootWrites.add((data, password));
    bytes = data;
    modified = modified.add(const Duration(seconds: 5));
  }

  @override
  bool get isConnected => connected;

  @override
  Future<bool> reconnect() async {
    reconnectsAsked++;
    if (reconnects) connected = true;
    return connected;
  }

  /// Other files on the same host, for the tab strip's "+".
  final Map<String, String> siblings = {};

  @override
  EditorSource? sibling(String path) => siblings.containsKey(path)
      ? FakeEditorSource(path, hostLabel: hostLabel, host: host, text: siblings[path]!)
      : FakeEditorSource(path, hostLabel: hostLabel, host: host, text: '');
}

/// A page with a button per file in [files] ("open path"), each opening it
/// in the editor's tabs, as the file managers do; a window [size] wide, in
/// [theme] where one is given.
Future<void> openEditorPage(
  WidgetTester tester,
  List<EditorSource> files, {
  Size size = const Size(1300, 850),
  Map<String, Object> prefs = const {},
  List<Override> overrides = const [],
  ThemeData? theme,
}) async {
  SharedPreferences.setMockInitialValues(prefs);
  final saved = await SharedPreferences.getInstance();
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [sharedPreferencesProvider.overrideWithValue(saved), ...overrides],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: theme,
      home: Builder(
        builder: (context) => Scaffold(
          body: ListView(
            children: [
              for (final f in files)
                TextButton(
                  key: ValueKey('open ${f.identity}'),
                  onPressed: () => openInEditor(context, f),
                  child: Text('open ${f.path}'),
                ),
            ],
          ),
        ),
      ),
    ),
  ));
}

/// Opens [file] as a file manager does: from the page while the editor is
/// not showing, else (a window beside it, a pane behind it) into its tabs.
Future<void> openFile(WidgetTester tester, EditorSource file) async {
  final editor = find.byType(TextEditorScreen);
  if (editor.evaluate().isEmpty) {
    await tester.tap(find.byKey(ValueKey('open ${file.identity}')));
  } else {
    unawaited(openInEditor(tester.element(editor), file));
  }
  await tester.pumpAndSettle();
}
