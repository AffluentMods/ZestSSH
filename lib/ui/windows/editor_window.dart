import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/ui/widgets/pop_out_window_guard.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/redactor.dart';

/// The file editor in a window of its own (its own engine, apart from the
/// main window's memory): the app of that window, from what the main window
/// handed it ([payload]), reaching the main window through [backend].
///
/// It runs in a ProviderScope of its own (3.4.1): the editor's widgets read
/// providers (the host's name reads recording mode), and with none above
/// them every one of those threw "No ProviderScope found" as it was built, so
/// each showed "Something went wrong" in its place. Nothing in it is the main
/// window's: recording mode is the main window's, carried in as the window
/// opens and kept in step on each change ([applyEditorRecording]; security
/// review 3.4.1, L3), so host names, paths and the rest are masked here as
/// there; drafts go to the main window's databases.
Widget editorWindowApp({
  required int windowId,
  required Map<String, dynamic> payload,
  required EditorWindowBackend backend,
  required ValueListenable<bool> locked,
  required VoidCallback onActivity,
}) {
  final link = PopOutEditorLink(windowId: windowId, backend: backend);
  return ProviderScope(
    overrides: [
      // Off until the main window says how it masks ([applyEditorRecording]),
      // before the first file shows.
      recordingModeProvider.overrideWith((ref) => Redactor.instance.enabled),
      recordingRedactLevelProvider.overrideWith((ref) => Redactor.instance.level),
      editorDraftStoreProvider.overrideWithValue(BridgedDraftStore(backend)),
    ],
    child: secondaryWindowApp(
      title: 'ZestSSH Editor',
      // The app lock's cover over everything the window shows, the questions
      // an editor opens over its page too (Save before closing?, the 13th
      // file, Find and replace): they are routes of the window's navigator,
      // which a cover inside the page lay under (the step 4 review, 4.0).
      over: (context, child) => PopOutWindowGuard(locked: locked, onActivity: onActivity, child: child),
      localeName: payload['locale'] as String?,
      theme: payload['theme'],
      accent: payload['accent'] as int?,
      home: EditorWindowHome(
        link: link,
        firstEditKey: payload['editKey'] as String? ?? '',
        nanoKeys: payload['nanoKeys'] as bool?,
        minimap: payload['minimap'] as bool?,
      ),
    ),
  );
}

/// Recording mode as the main window has it ([Redactor.toWindow], [state]),
/// in this editor window: its Redactor masks as the main window's does, and
/// what shows a name here is built again ([ref]'s providers).
void applyEditorRecording(WidgetRef ref, Object? state) {
  Object? decoded = state;
  if (state is String) {
    try {
      decoded = jsonDecode(state);
    } on FormatException {
      return;
    }
  }
  Redactor.instance.fromWindow(decoded);
  ref.read(recordingModeProvider.notifier).state = Redactor.instance.enabled;
  ref.read(recordingRedactLevelProvider.notifier).state = Redactor.instance.level;
}

/// What answers the main window's calls in an editor window ([EditorWindowHome]
/// registers itself here), by window id.
final Map<int, Future<Object?> Function(String method, Object? arguments)> editorWindowHandlers = {};

/// A call from the main window to editor window [windowId]; null where it
/// has no editor (yet).
Future<Object?> answerEditorWindowCall(int windowId, String method, Object? arguments) async =>
    editorWindowHandlers[windowId]?.call(method, arguments);

/// A window of its own's link to the main window, which holds the
/// connections and keeps the list of the editor windows.
class PopOutEditorLink extends EditorWindowLink {
  PopOutEditorLink({required this.windowId, required this.backend});

  @override
  final int windowId;
  final EditorWindowBackend backend;

  String? _keyOf(EditorDocument doc) {
    final source = doc.source;
    return source is BridgedEditorSource ? source.editKey : null;
  }

  @override
  Future<List<EditorWindowTarget>> targets() async {
    try {
      final answer = await backend.invoke(kMainWindowId, 'editorTargets');
      final list = answer is String ? jsonDecode(answer) : null;
      if (list is! List) return const [];
      return [
        for (final t in list)
          if (t is List && t.length == 2 && t[0] is int && t[1] is int) EditorWindowTarget(t[0] as int, t[1] as int),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<EditorMoveResult> _ask(String method, EditorDocument doc, {int? to}) async {
    final key = _keyOf(doc);
    if (key == null) return EditorMoveResult.failed;
    try {
      final answer = await backend.invoke(
        kMainWindowId,
        method,
        jsonEncode({'tab': EditorTabSnapshot.of(doc, editKey: key).toJson(), 'to': to ?? -1}),
      );
      return EditorMoveResult.values.asNameMap()[answer] ?? EditorMoveResult.failed;
    } catch (_) {
      return EditorMoveResult.failed;
    }
  }

  @override
  Future<EditorMoveResult> moveTo(EditorDocument doc, {int? to, Offset? at}) => _ask('editorMove', doc, to: to);

  @override
  Future<EditorMoveResult> draggedOut(EditorDocument doc) => _ask('editorDraggedOut', doc);

  @override
  void closed(EditorDocument doc) {
    final key = _keyOf(doc);
    if (key != null) unawaited(backend.invoke(kMainWindowId, 'editorClosed', key).catchError((Object _) => null));
  }

  @override
  void lastClosed() => unawaited(backend.close(windowId).catchError((Object _) {}));
}

/// An editor window's page: its first file, fetched from the main window
/// (too big for the window's command line), then the editor with its tabs;
/// files the main window sends later join them ([answerEditorWindowCall]).
class EditorWindowHome extends ConsumerStatefulWidget {
  const EditorWindowHome({
    super.key,
    required this.link,
    required this.firstEditKey,
    this.nanoKeys,
    this.minimap,
  });

  final PopOutEditorLink link;
  final String firstEditKey;
  final bool? nanoKeys;
  final bool? minimap;

  @override
  ConsumerState<EditorWindowHome> createState() => _EditorWindowHomeState();
}

class _EditorWindowHomeState extends ConsumerState<EditorWindowHome> {
  bool _ready = false;
  Object? _error;

  EditorWorkspace get _ws => ref.read(editorWorkspaceProvider);
  EditorWindowBackend get _backend => widget.link.backend;

  @override
  void initState() {
    super.initState();
    editorWindowHandlers[widget.link.windowId] = _answer;
    unawaited(_load());
  }

  @override
  void dispose() {
    if (editorWindowHandlers[widget.link.windowId] == _answer) editorWindowHandlers.remove(widget.link.windowId);
    super.dispose();
  }

  Future<void> _load() async {
    try {
      // How the main window masks names, before the first file shows.
      final recording = await _backend.invoke(kMainWindowId, 'editorRecordingState');
      if (!mounted) return;
      applyEditorRecording(ref, recording);
      final answer = await _backend.invoke(kMainWindowId, 'editorInit', widget.firstEditKey);
      final snapshot = answer is String && answer.isNotEmpty ? EditorTabSnapshot.fromJson(jsonDecode(answer)) : null;
      if (snapshot == null) throw StateError('The main window handed no file');
      if (!mounted) return;
      if (_ws.byIdentity(snapshot.identity) == null) _ws.add(snapshot.toDocument(BridgedEditorSource(snapshot, _backend)));
      setState(() => _ready = true);
    } catch (e) {
      if (mounted && !_ready) setState(() => _error = e);
    }
  }

  Future<Object?> _answer(String method, Object? arguments) async {
    switch (method) {
      case 'editorAddTab':
        final snapshot = arguments is String ? EditorTabSnapshot.fromJson(jsonDecode(arguments)) : null;
        if (snapshot == null || !mounted) return 'failed';
        return _take(snapshot);
      case 'editorRecording':
        if (!mounted) return 'failed';
        applyEditorRecording(ref, arguments);
        return 'ok';
      case 'editorFocusTab':
        final open = _ws.byIdentity(arguments as String? ?? '');
        if (open == null) return 'gone';
        _ws.activate(open);
        return 'ok';
    }
    return null;
  }

  /// A tab handed by the main window: taken where this window has room for
  /// it (or the person made it, closing one), its file not open here yet.
  Future<String> _take(EditorTabSnapshot snapshot) async {
    final open = _ws.byIdentity(snapshot.identity);
    if (open != null) {
      _ws.activate(open);
      return 'open';
    }
    if (!await makeRoomFor(context, _ws, snapshot.fileName) || !mounted) return 'refused';
    _ws.add(snapshot.toDocument(BridgedEditorSource(snapshot, _backend)));
    if (!_ready) setState(() => _ready = true);
    return 'ok';
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      // That it could not be opened, with the report of why to copy (3.0, UI
      // step 12: the raw error was shown under it, which can name a path).
      return Scaffold(
        backgroundColor: AppColors.v3Background,
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    gl10n.editorPopOutCouldNotOpen,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 12),
                  ErrorDetailsPanel(
                    report: ErrorReport.build(
                      what: 'A file could not be opened in its own window',
                      where: 'Opening a file in its own window',
                      error: _error,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    if (!_ready) {
      return Scaffold(
        backgroundColor: AppColors.v3Background,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return TextEditorScreen.tabs(
      link: widget.link,
      handedSettings: true,
      initialNanoKeys: widget.nanoKeys,
      // A person's settings, kept by the main window for a window of its
      // own (which has no way to the profile's database).
      onNanoKeysChanged: (on) =>
          unawaited(_backend.invoke(kMainWindowId, 'editorNanoKeys', on ? '1' : '0').catchError((Object _) => null)),
      initialMinimap: widget.minimap,
      onMinimapChanged: (on) =>
          unawaited(_backend.invoke(kMainWindowId, 'editorMinimap', on ? '1' : '0').catchError((Object _) => null)),
    );
  }
}
