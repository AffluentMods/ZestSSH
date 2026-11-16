import 'dart:async';
import 'dart:convert';
import 'dart:ui';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:re_editor/re_editor.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_reply.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/editor_window_drop.dart';
import 'package:zestssh/ui/windows/secondary_window_app.dart' show windowThemePayload;
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/redactor.dart';

// The editor in windows of its own (3.4.1). One editor per window, each
// with its tabs: the main window's, and
// any number of windows of their own. A file is open in one of them at most,
// and a tab moves between them (its menu's Move to window, or dragged out of
// its window where the system says where it was dropped) with its unsaved
// text, its caret, its encoding and line endings, and its draft.
//
// The connection to a file's host is the main window's: a window of its own
// (its own engine, apart from the main window's memory) saves, reads again and
// keeps drafts through it, by the tab's key (editKey), over the windows'
// channel.

/// The main window's id among the app's windows.
const int kMainWindowId = 0;

/// A tab as it travels from one of the app's windows to another: the file
/// (its name, path and host, as the editor tells hosts apart), the text as
/// last saved or read and what is typed over it, what it is written in, the
/// file on its host as it was then, its language, indentation, caret and
/// scrolling, and whether a draft of it is kept.
class EditorTabSnapshot {
  const EditorTabSnapshot({
    required this.editKey,
    required this.fileName,
    required this.path,
    required this.hostLabel,
    required this.identity,
    required this.hostKey,
    required this.team,
    required this.hostKnown,
    required this.savedText,
    required this.text,
    required this.encoding,
    required this.lineBreak,
    this.mixedLineBreaks = false,
    this.encodingChanged = false,
    this.baseline,
    required this.language,
    required this.indent,
    this.selection,
    required this.canSave,
    required this.canReload,
    this.drafted = false,
    this.draftKeptAt,
    this.draftHostChanged,
    this.scrollTop = 0,
    this.scrollLeft = 0,
  });

  /// The tab as it is in [doc] now, under [editKey]. Its host's label goes as
  /// it is: the window it goes to masks it itself while recording mode is on,
  /// as the main window's recording mode is carried into it and kept in step
  /// (found in a security review: masked once as the tab was handed over, a
  /// label stayed real where recording mode was turned on after).
  factory EditorTabSnapshot.of(EditorDocument doc, {required String editKey}) {
    final source = doc.source;
    final restored = doc.draftRestored;
    return EditorTabSnapshot(
      editKey: editKey,
      fileName: source.fileName,
      path: source.path,
      hostLabel: source.hostLabel,
      identity: source.identity,
      hostKey: source.host.key,
      team: source.host.team,
      hostKnown: source.host.known,
      savedText: doc.savedText,
      text: doc.controller.text,
      encoding: doc.encoding,
      lineBreak: doc.lineBreak,
      mixedLineBreaks: doc.mixedLineBreaks,
      encodingChanged: doc.encodingChanged,
      baseline: doc.baseline,
      language: doc.language,
      indent: doc.indent,
      selection: doc.controller.selection,
      canSave: source.canSave,
      canReload: source.canReload,
      // A tab that moves with changes leaves a draft of them behind it (its
      // window keeps one as the tab goes), which the window it goes to
      // forgets once they are saved.
      drafted: doc.drafted || (doc.modified && source.keepsDrafts),
      draftKeptAt: restored?.keptAt,
      draftHostChanged: restored?.hostChanged,
      scrollTop: doc.scrollTop,
      scrollLeft: doc.scrollLeft,
    );
  }

  final String editKey;
  final String fileName;
  final String path;
  final String? hostLabel;
  final String identity;
  final String hostKey;
  final String? team;
  final bool hostKnown;
  final String savedText;
  final String text;
  final EditorEncoding encoding;
  final EditorLineBreak lineBreak;
  final bool mixedLineBreaks;
  final bool encodingChanged;
  final FileVersion? baseline;
  final EditorLanguage language;
  final EditorIndent indent;
  final CodeLineSelection? selection;
  final bool canSave;
  final bool canReload;
  final bool drafted;
  final DateTime? draftKeptAt;
  final bool? draftHostChanged;
  final double scrollTop;
  final double scrollLeft;

  /// Whether what is typed differs from what was last saved or read.
  bool get modified => text != savedText || encodingChanged;

  /// The tab, in a window, with [source] behind it: as it was where it came
  /// from.
  EditorDocument toDocument(EditorSource source) {
    final doc = EditorDocument.moved(
      source,
      savedText: savedText,
      text: text,
      encoding: encoding,
      lineBreak: lineBreak,
      mixedLineBreaks: mixedLineBreaks,
      encodingChanged: encodingChanged,
      baseline: baseline,
      language: language,
      indent: indent,
      selection: selection,
    );
    doc
      ..drafted = drafted
      ..draftRestored = draftKeptAt == null ? null : (keptAt: draftKeptAt!, hostChanged: draftHostChanged)
      ..scrollTop = scrollTop
      ..scrollLeft = scrollLeft;
    return doc;
  }

  Map<String, Object?> toJson() => {
        'v': 1,
        'editKey': editKey,
        'fileName': fileName,
        'path': path,
        'hostLabel': hostLabel,
        'identity': identity,
        'hostKey': hostKey,
        'team': team,
        'hostKnown': hostKnown,
        'savedText': savedText,
        'text': text,
        'encoding': encoding.name,
        'lineBreak': lineBreak.name,
        'mixedLineBreaks': mixedLineBreaks,
        'encodingChanged': encodingChanged,
        'baseline': versionToJson(baseline),
        'language': language.name,
        'indentTabs': indent.tabs,
        'indentSize': indent.size,
        if (selection case final s?) 'selection': [s.baseIndex, s.baseOffset, s.extentIndex, s.extentOffset],
        'canSave': canSave,
        'canReload': canReload,
        'drafted': drafted,
        'draftKeptAt': draftKeptAt?.millisecondsSinceEpoch,
        'draftHostChanged': draftHostChanged,
        'scrollTop': scrollTop,
        'scrollLeft': scrollLeft,
      };

  /// The tab [json] says (from [toJson]); null where it says none.
  static EditorTabSnapshot? fromJson(Object? json) {
    if (json is! Map) return null;
    final editKey = json['editKey'];
    final fileName = json['fileName'];
    final identity = json['identity'];
    final hostKey = json['hostKey'];
    final savedText = json['savedText'];
    final text = json['text'];
    if (editKey is! String || fileName is! String || identity is! String || hostKey is! String) return null;
    if (savedText is! String || text is! String) return null;
    final selection = json['selection'];
    final language = EditorLanguage.values.asNameMap()[json['language']] ?? EditorLanguage.plainText;
    final size = json['indentSize'] is int ? json['indentSize'] as int : 4;
    return EditorTabSnapshot(
      editKey: editKey,
      fileName: fileName,
      path: json['path'] is String ? json['path'] as String : '',
      hostLabel: json['hostLabel'] is String ? json['hostLabel'] as String : null,
      identity: identity,
      hostKey: hostKey,
      team: json['team'] is String ? json['team'] as String : null,
      hostKnown: json['hostKnown'] == true,
      savedText: savedText,
      text: text,
      encoding: EditorEncoding.values.asNameMap()[json['encoding']] ?? EditorEncoding.utf8,
      lineBreak: EditorLineBreak.values.asNameMap()[json['lineBreak']] ?? EditorLineBreak.lf,
      mixedLineBreaks: json['mixedLineBreaks'] == true,
      encodingChanged: json['encodingChanged'] == true,
      baseline: versionFromJson(json['baseline']),
      language: language,
      indent: json['indentTabs'] == true ? const EditorIndent.tabs() : EditorIndent.spaces(size),
      selection: selection is List && selection.length == 4 && selection.every((e) => e is int)
          ? CodeLineSelection(
              baseIndex: selection[0] as int,
              baseOffset: selection[1] as int,
              extentIndex: selection[2] as int,
              extentOffset: selection[3] as int,
            )
          : null,
      canSave: json['canSave'] != false,
      canReload: json['canReload'] != false,
      drafted: json['drafted'] == true,
      draftKeptAt: json['draftKeptAt'] is int ? DateTime.fromMillisecondsSinceEpoch(json['draftKeptAt'] as int) : null,
      draftHostChanged: json['draftHostChanged'] is bool ? json['draftHostChanged'] as bool : null,
      scrollTop: (json['scrollTop'] as num?)?.toDouble() ?? 0,
      scrollLeft: (json['scrollLeft'] as num?)?.toDouble() ?? 0,
    );
  }

}

Map<String, Object?>? versionToJson(FileVersion? v) =>
    v == null ? null : {'modified': v.modified?.millisecondsSinceEpoch, 'size': v.size, 'sha256': v.sha256};

FileVersion? versionFromJson(Object? json) {
  if (json is! Map) return null;
  final modified = json['modified'];
  return FileVersion(
    modified: modified is int ? DateTime.fromMillisecondsSinceEpoch(modified) : null,
    size: json['size'] is int ? json['size'] as int : null,
    sha256: json['sha256'] is String ? json['sha256'] as String : null,
  );
}

// ── The windows' plugin ─────────────────────────────────────────────────

/// How the editor opens, places and reaches the app's windows: the
/// desktop_multi_window plugin, or a test's stand-in.
abstract class EditorWindowBackend {
  /// A new window, running the app with [payload]; its id.
  Future<int> createWindow(String payload);

  /// Puts window [id] at [frame] with [title], and shows it.
  Future<void> place(int id, Rect frame, String title);

  /// Brings window [id] to the front.
  Future<void> focus(int id);

  /// Calls [method] in window [id]'s engine and answers what it answered.
  Future<Object?> invoke(int id, String method, [Object? arguments]);

  /// The ids of the windows of their own still open.
  Future<List<int>> windowIds();

  /// Closes window [id] (a window of its own whose last tab closed).
  Future<void> close(int id);
}

class PluginEditorWindowBackend implements EditorWindowBackend {
  const PluginEditorWindowBackend();

  @override
  Future<int> createWindow(String payload) async => (await DesktopMultiWindow.createWindow(payload)).windowId;

  @override
  Future<void> place(int id, Rect frame, String title) async {
    final window = WindowController.fromWindowId(id);
    await window.setFrame(frame);
    await window.setTitle(title);
    await window.show();
  }

  @override
  Future<void> focus(int id) => WindowController.fromWindowId(id).show();

  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) =>
      DesktopMultiWindow.invokeMethod(id, method, arguments);

  @override
  Future<List<int>> windowIds() => DesktopMultiWindow.getAllSubWindowIds();

  @override
  Future<void> close(int id) => WindowController.fromWindowId(id).close();
}

// ── The main window's side ──────────────────────────────────────────────

/// A tab shown in a window of its own, as the main window keeps it: the file
/// as it is reached from here ([source], whose connection is here), what it
/// is written in, which window shows it ([windowId]), and the tab as it was
/// handed until that window takes it ([pending]).
class EditorBridge {
  EditorBridge({required this.source, required this.encoding, required this.lineBreak, this.pending, this.windowId});

  final EditorSource source;
  EditorEncoding encoding;
  EditorLineBreak lineBreak;
  EditorTabSnapshot? pending;
  int? windowId;

  /// The file's name, for what is said when its save or reload fails.
  String get fileName => source.fileName;
  bool get canSave => source.canSave;
  bool get canReload => source.canReload;

  /// Writes [content] (as the window of its own sends it, its lines ended
  /// as the file's are) as the file, in its encoding and line endings.
  Future<void> save(String content) async {
    final text = content.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (source.movesText) {
      await source.writeText(lineBreak == EditorLineBreak.lf ? text : text.replaceAll('\n', lineBreak.chars));
    } else {
      await source.write(EditorCodec.encode(text, encoding, lineBreak));
    }
  }

  /// The file read again, as text.
  Future<String> reload() async =>
      source.movesText ? source.readText() : EditorCodec.decode(await source.read(), as: encoding).text;

  Future<FileVersion?> version() => source.version();
}

/// Where a moved tab went.
enum EditorMoveResult {
  /// It is in the other window now (its tab here closes without asking).
  moved,

  /// The other window asked which tab to close for it and was told Cancel,
  /// or has the file open already (its tab there is in front): it stays.
  refused,

  /// The other window could not be reached or opened: it stays.
  failed,

  /// It was dropped on its own window: nothing to do.
  stayed,
}

/// An editor window a tab can be moved to: the main window's
/// ([kMainWindowId]) or a window of its own, numbered as its title says.
class EditorWindowTarget {
  const EditorWindowTarget(this.id, this.number);

  final int id;
  final int number;
  bool get isMain => id == kMainWindowId;
}

/// The editor's windows, as the main window keeps them (3.4.1).
class EditorWindows {
  EditorWindows._();

  static final EditorWindows instance = EditorWindows._();

  EditorWindowBackend backend = const PluginEditorWindowBackend();

  /// Where a tab dropped outside its window landed ([EditorDropResolver]).
  EditorDropResolver dropResolver = EditorDropResolver.platform();

  /// What the main window's own editor does with a tab moved into it: true
  /// when it took it (set by the app, which has its editor).
  Future<bool> Function(EditorDocument doc)? takeIntoMain;

  /// The drafts of the tabs of the windows of their own (the main window's
  /// encrypted databases; set by the app).
  EditorDraftStore? Function()? drafts;

  /// The profile on screen (its id; null between two, and where the app keeps
  /// no profiles). A window of its own keeps its drafts in the profile that
  /// opened it and no other ([_answerDraft]).
  String? Function() profile = () => Profiles.current?.id;

  /// How the main window masks names while recording mode is on, handed to
  /// each window of its own and kept in step there ([broadcastRecording]).
  Map<String, Object?> Function() recording = Redactor.instance.toWindow;

  final Map<String, EditorBridge> _bridges = {};

  /// Each editor window's number, as its title says ("ZestSSH - Editor 2"):
  /// the title names no host and no file (screen sharing, the taskbar), and
  /// tells the windows apart.
  final Map<int, int> _numbers = {};

  /// The profile each editor window was opened in ([profile] then).
  final Map<int, String?> _profileOf = {};

  /// The editor window used last, for a file opened while the main window
  /// shows no editor.
  int? _lastUsed;

  /// What the last window that could not be opened threw, for the report of
  /// the notice that says so (null after one that could).
  Object? lastDetachError;

  EditorBridge? bridge(String editKey) => _bridges[editKey];

  /// Lets the main window forget the tab [editKey] (its window closed it).
  void forget(String editKey) => _bridges.remove(editKey);

  /// Whether any editor window of its own was opened (it may have closed).
  bool get hasWindows => _numbers.isNotEmpty;

  /// The title of editor window [id].
  String titleOf(int id) => 'ZestSSH - Editor ${_numbers[id] ?? id}';

  int? numberOf(int id) => _numbers[id];

  /// The editor window whose title is [title]; null where none is.
  int? windowTitled(String title) {
    for (final e in _numbers.entries) {
      if (titleOf(e.key) == title) return e.key;
    }
    return null;
  }

  /// Someone is working in window [id] (its 'activity').
  void touched(int id) {
    if (_numbers.containsKey(id)) _lastUsed = id;
  }

  /// The editor windows of their own still open, oldest first; a window that
  /// closed is forgotten, with its tabs.
  Future<List<int>> liveWindows() async {
    if (_numbers.isEmpty) return const [];
    List<int> open;
    try {
      open = await backend.windowIds();
    } catch (e) {
      AppLogger.warning('The windows could not be listed (${errorKind(e)})');
      return const [];
    }
    for (final gone in _numbers.keys.where((id) => !open.contains(id)).toList()) {
      _numbers.remove(gone);
      _profileOf.remove(gone);
      _bridges.removeWhere((_, b) => b.windowId == gone);
      if (_lastUsed == gone) _lastUsed = null;
    }
    return _numbers.keys.toList();
  }

  /// The editor window of its own that shows the file [identity]; null
  /// where none does.
  Future<int?> windowShowing(String identity) async {
    if (_bridges.isEmpty) return null;
    final live = await liveWindows();
    for (final b in _bridges.values) {
      if (b.windowId != null && live.contains(b.windowId) && b.source.identity == identity) return b.windowId;
    }
    return null;
  }

  /// The editor window a file goes to while the main window shows no
  /// editor: the one used last, else the newest; null where none is open.
  Future<int?> windowForNewFile() async {
    final live = await liveWindows();
    if (live.isEmpty) return null;
    final last = _lastUsed;
    return last != null && live.contains(last) ? last : live.last;
  }

  /// Brings window [id] to the front with the file [identity]'s tab in front.
  Future<void> focusTab(int id, String identity) async {
    _lastUsed = id;
    try {
      await backend.invoke(id, 'editorFocusTab', identity);
      await backend.focus(id);
    } catch (e) {
      AppLogger.warning('An editor window could not be brought to the front (${errorKind(e)})');
    }
  }

  /// Moves the main window's [doc] to the editor window [to] (a new one
  /// where null, at [at] on the screen where given). Its text goes with it,
  /// saved or not; its saves, looks and reads are made here, where the
  /// connection is.
  Future<EditorMoveResult> send(EditorDocument doc, {int? to, Offset? at}) {
    final key = const Uuid().v4();
    final snapshot = EditorTabSnapshot.of(doc, editKey: key);
    final bridge = EditorBridge(source: doc.source, encoding: doc.encoding, lineBreak: doc.lineBreak, pending: snapshot);
    return _deliver(bridge, snapshot, to: to, at: at, isNew: true);
  }

  Future<EditorMoveResult> _deliver(
    EditorBridge bridge,
    EditorTabSnapshot snapshot, {
    int? to,
    Offset? at,
    required bool isNew,
  }) async {
    final key = snapshot.editKey;
    final from = bridge.windowId;
    _bridges[key] = bridge;
    if (to != null) {
      Object? answer;
      try {
        // Recording mode as it is now, before the tab's label shows there.
        if (to != kMainWindowId) await backend.invoke(to, 'editorRecording', jsonEncode(recording()));
        answer = await backend.invoke(to, 'editorAddTab', jsonEncode(snapshot.toJson()));
      } catch (e) {
        AppLogger.warning('A tab could not be moved to an editor window (${errorKind(e)})');
        answer = null;
      }
      if (answer == 'ok') {
        bridge
          ..windowId = to
          ..pending = null;
        _lastUsed = to;
        try {
          await backend.focus(to);
        } catch (_) {}
        return EditorMoveResult.moved;
      }
      if (isNew) _bridges.remove(key);
      bridge.windowId = from;
      return answer == 'refused' || answer == 'open' ? EditorMoveResult.refused : EditorMoveResult.failed;
    }
    bridge.pending = snapshot;
    try {
      final number = _nextNumber();
      final payload = jsonEncode(<String, dynamic>{
        'type': 'editor',
        'editKey': key,
        'number': number,
        // The new window has no settings of its own: it is handed them.
        'locale': gl10n.localeName,
        ...windowThemePayload(),
        ...await _settingsPayload(),
      });
      lastDetachError = null;
      final opener = profile();
      final id = await backend.createWindow(payload);
      _numbers[id] = number;
      _profileOf[id] = opener;
      bridge.windowId = id;
      _lastUsed = id;
      final origin = at ?? const Offset(140, 120);
      await backend.place(id, Rect.fromLTWH(origin.dx, origin.dy, 980, 680), titleOf(id));
      AppLogger.info('Opened editor window $id');
      return EditorMoveResult.moved;
    } catch (e, stack) {
      AppLogger.error('An editor window could not be opened', e, stack);
      lastDetachError = e;
      if (isNew) _bridges.remove(key);
      bridge
        ..windowId = from
        ..pending = null;
      return EditorMoveResult.failed;
    }
  }

  int _nextNumber() {
    var n = 2;
    while (_numbers.containsValue(n)) {
      n++;
    }
    return n;
  }

  /// What a window of its own is handed of a person's settings.
  static Future<Map<String, dynamic>> _settingsPayload() async {
    try {
      final prefs = await appPreferences();
      return {
        'copyOnSelect': prefs.getBool('copy_on_select') ?? true,
        'shortcuts': prefs.getString('shortcut_overrides'),
        'nanoKeys': prefs.getBool('editor_nano_keys'),
        'minimap': prefs.getBool('editor_minimap'),
      };
    } catch (_) {
      return const {};
    }
  }

  /// The editor windows a tab in window [from] can be moved to: the main
  /// window's editor and every other editor window of its own still open.
  Future<List<EditorWindowTarget>> targetsFrom(int from) async {
    final live = await liveWindows();
    return [
      if (from != kMainWindowId) const EditorWindowTarget(kMainWindowId, 1),
      for (final id in live)
        if (id != from) EditorWindowTarget(id, _numbers[id]!),
    ];
  }

  /// Where a tab dragged out of window [from] goes: the window under the
  /// pointer, else a new window there.
  Future<({int? to, Offset? at, bool stay})> dropTarget(int from) async {
    final drop = dropResolver.resolve();
    if (drop.main) return (to: kMainWindowId, at: null, stay: from == kMainWindowId);
    final title = drop.windowTitle;
    final id = title == null ? null : windowTitled(title);
    if (id != null) return (to: id, at: null, stay: id == from);
    if (drop.ours) return (to: null, at: null, stay: true);
    return (to: null, at: drop.at, stay: false);
  }

  /// A tab of window [from] ([snapshot]) moved to window [to]: the main
  /// window's editor ([kMainWindowId]), another window of its own, or a new
  /// one (null, at [at]).
  Future<EditorMoveResult> moveFromWindow(EditorTabSnapshot snapshot, int from, {int? to, Offset? at}) async {
    final bridge = _bridges[snapshot.editKey];
    if (bridge == null) return EditorMoveResult.failed;
    if (to == from) return EditorMoveResult.stayed;
    if (to == kMainWindowId) {
      final take = takeIntoMain;
      if (take == null) return EditorMoveResult.failed;
      final doc = snapshot.toDocument(bridge.source);
      bool took;
      try {
        took = await take(doc);
      } catch (e, stack) {
        AppLogger.error('A tab could not be moved into the main window', e, stack);
        took = false;
      }
      if (!took) {
        doc.dispose();
        return EditorMoveResult.refused;
      }
      _bridges.remove(snapshot.editKey);
      return EditorMoveResult.moved;
    }
    return _deliver(bridge, snapshot, to: to, at: at, isNew: false);
  }

  /// Answers a call from an editor window of its own ([from]); null for a
  /// method that is not the editor's.
  Future<Object?> handle(String method, Object? arguments, int from) async {
    switch (method) {
      case 'editorInit':
        // The window's first tab, with its text (too big for the window's
        // command line).
        final bridge = _bridges[arguments as String? ?? ''];
        final pending = bridge?.pending;
        if (pending == null) return '';
        bridge!.pending = null;
        return jsonEncode(pending.toJson());

      case 'editorSave':
        // Fail loud: the window keeps the text and says why, in the app's
        // language with what was thrown for its report.
        final Map<String, dynamic> data;
        try {
          data = jsonDecode(arguments as String) as Map<String, dynamic>;
        } catch (e) {
          return EditorReply.failed(gl10n.sftpErrOperationFailed, e);
        }
        return EditorReply.answerSave(_bridges[data['editKey'] as String? ?? ''], data['content'] as String? ?? '');

      case 'editorReload':
        return EditorReply.answerReload(_bridges[arguments as String? ?? '']);

      case 'editorVersion':
        try {
          final v = await _bridges[arguments as String? ?? '']?.version();
          return v == null ? '' : jsonEncode(versionToJson(v));
        } catch (_) {
          return '';
        }

      case 'editorClosed':
        forget(arguments as String? ?? '');
        return '';

      case 'editorDraft':
        return _answerDraft(arguments, from);

      case 'editorRecordingState':
        // A window of its own, as it opens: how the main window masks names.
        return jsonEncode(recording());

      case 'editorTargets':
        final targets = await targetsFrom(from);
        return jsonEncode([
          for (final t in targets) [t.id, t.number],
        ]);

      case 'editorMove':
        final data = _decode(arguments);
        final snapshot = EditorTabSnapshot.fromJson(data?['tab']);
        if (snapshot == null) return EditorMoveResult.failed.name;
        final to = data!['to'];
        return (await moveFromWindow(snapshot, from, to: to is int && to >= 0 ? to : null)).name;

      case 'editorDraggedOut':
        final snapshot = EditorTabSnapshot.fromJson(_decode(arguments)?['tab']);
        if (snapshot == null) return EditorMoveResult.failed.name;
        final drop = await dropTarget(from);
        if (drop.stay) return EditorMoveResult.stayed.name;
        return (await moveFromWindow(snapshot, from, to: drop.to, at: drop.at)).name;
    }
    return null;
  }

  /// A draft of window [from]'s, read, kept or removed in the profile that
  /// opened that window, and only while that profile is still the one on
  /// screen: a window from before a change of profile (a sign-out, a switch)
  /// reaches no other profile's drafts, and what it sends is dropped, never
  /// moved (found in a security review).
  Future<String> _answerDraft(Object? arguments, int from) async {
    if (!_numbers.containsKey(from) || _profileOf[from] != profile()) return '';
    final data = _decode(arguments);
    final store = drafts?.call();
    if (data == null || store == null) return '';
    final identity = data['identity'];
    if (identity is! String) return '';
    final team = data['team'] is String ? data['team'] as String : null;
    try {
      switch (data['op']) {
        case 'read':
          final draft = await store.read(identity, team: team);
          return draft == null ? '' : jsonEncode(draft.toJson());
        case 'write':
          final draft = EditorDraft.fromJson(data['draft']);
          if (draft != null) await store.write(identity, draft, team: team);
          return 'ok';
        case 'remove':
          await store.remove(identity, team: team);
          return 'ok';
      }
    } catch (_) {
      // The database closed (the app locked): not kept this time.
    }
    return '';
  }

  static Map<String, dynamic>? _decode(Object? arguments) {
    if (arguments is! String) return null;
    try {
      final decoded = jsonDecode(arguments);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// Recording mode as the main window has it now, to every editor window of
  /// its own: each masks host names, paths and the rest as the main window
  /// does, at once. Never throws.
  Future<void> broadcastRecording() async {
    if (_numbers.isEmpty) return;
    final state = jsonEncode(recording());
    for (final id in _numbers.keys.toList()) {
      try {
        await backend.invoke(id, 'editorRecording', state);
      } catch (e) {
        AppLogger.warning('Recording mode did not reach an editor window (${errorKind(e)})');
      }
    }
  }

  /// Closes every editor window of its own and forgets them with their tabs:
  /// at each change of profile (a sign-out, a switch to another account or to
  /// guest data, what did not open after the PIN), as the main window's editor
  /// is emptied then. Their unsaved text goes with them, as the main window's
  /// does; a draft each kept is in the profile that opened it, and one sent
  /// after this is dropped ([_answerDraft]). Forgotten first, so nothing that
  /// window asks for meanwhile is answered. Never
  /// throws.
  Future<void> closeAll() async {
    final ids = _numbers.keys.toList();
    reset();
    for (final id in ids) {
      try {
        await backend.close(id).timeout(const Duration(seconds: 2));
      } catch (e) {
        // Closed already, or it does not answer: nothing here holds it now.
        AppLogger.warning('An editor window was not closed at a change of profile (${errorKind(e)})');
      }
    }
    if (ids.isNotEmpty) AppLogger.info('Closed ${ids.length} editor window(s) at a change of profile');
  }

  /// Forgets every window and tab (tests, and [closeAll]).
  void reset() {
    _bridges.clear();
    _numbers.clear();
    _profileOf.clear();
    _lastUsed = null;
    lastDetachError = null;
  }
}

// ── A window's link to the others ───────────────────────────────────────

/// How an editor's screen reaches the other editor windows: the main
/// window's ([MainEditorLink]) or a window of its own's (in
/// lib/ui/windows/editor_window.dart).
abstract class EditorWindowLink {
  /// This window's id ([kMainWindowId] for the main window).
  int get windowId;

  /// The editor windows a tab here can be moved to.
  Future<List<EditorWindowTarget>> targets();

  /// Moves [doc] to editor window [to] (a new window where null, at [at]).
  Future<EditorMoveResult> moveTo(EditorDocument doc, {int? to, Offset? at});

  /// [doc]'s tab was dragged out of this window and let go: to the window
  /// under the pointer, else a new one there.
  Future<EditorMoveResult> draggedOut(EditorDocument doc);

  /// [doc]'s tab closed here (not moved).
  void closed(EditorDocument doc) {}

  /// The window's last tab closed: a window of its own closes.
  void lastClosed() {}

  /// What went wrong when a window could not be opened, for the report.
  Object? get lastError => null;
}

/// The main window's editor's link.
class MainEditorLink extends EditorWindowLink {
  MainEditorLink([EditorWindows? windows]) : _windows = windows ?? EditorWindows.instance;

  final EditorWindows _windows;

  @override
  int get windowId => kMainWindowId;

  @override
  Future<List<EditorWindowTarget>> targets() => _windows.targetsFrom(kMainWindowId);

  @override
  Future<EditorMoveResult> moveTo(EditorDocument doc, {int? to, Offset? at}) => _windows.send(doc, to: to, at: at);

  @override
  Future<EditorMoveResult> draggedOut(EditorDocument doc) async {
    final drop = await _windows.dropTarget(kMainWindowId);
    if (drop.stay) return EditorMoveResult.stayed;
    return _windows.send(doc, to: drop.to, at: drop.at);
  }

  @override
  Object? get lastError => _windows.lastDetachError;
}

// ── A window of its own's side ──────────────────────────────────────────

/// A file in a window of its own: its bytes are the main window's, which
/// holds the connection; this window saves, reads again and asks how the
/// file is on its host through it, by the tab's key ([editKey]). It is the
/// file it was in the main window ([identity], [host]), so a file is open
/// once across the windows and its draft is the same draft.
class BridgedEditorSource extends EditorSource {
  BridgedEditorSource(this.snapshot, this.backend)
      : host = EditorHost.named(snapshot.hostKey, team: snapshot.team, known: snapshot.hostKnown);

  final EditorTabSnapshot snapshot;
  final EditorWindowBackend backend;

  String get editKey => snapshot.editKey;

  @override
  String get fileName => snapshot.fileName;

  @override
  String get path => snapshot.path;

  @override
  String? get hostLabel => snapshot.hostLabel;

  @override
  final EditorHost host;

  @override
  String get identity => snapshot.identity;

  @override
  bool get movesText => true;

  @override
  bool get keepsDrafts => host.known;

  @override
  bool get canSave => snapshot.canSave;

  @override
  bool get canReload => snapshot.canReload;

  @override
  Future<void> writeText(String text) async => EditorReply.readSave(
        await backend.invoke(kMainWindowId, 'editorSave', jsonEncode({'editKey': editKey, 'content': text})),
      );

  @override
  Future<String> readText() async => EditorReply.readReload(await backend.invoke(kMainWindowId, 'editorReload', editKey));

  @override
  Future<FileVersion?> version() async {
    final answer = await backend.invoke(kMainWindowId, 'editorVersion', editKey);
    if (answer is! String || answer.isEmpty) return null;
    try {
      return versionFromJson(jsonDecode(answer));
    } on FormatException {
      return null;
    }
  }
}

/// The drafts of a window of its own: kept by the main window, in its
/// encrypted databases, as its own tabs' are.
class BridgedDraftStore implements EditorDraftStore {
  BridgedDraftStore(this.backend);

  final EditorWindowBackend backend;

  Future<Object?> _ask(Map<String, Object?> what) => backend.invoke(kMainWindowId, 'editorDraft', jsonEncode(what));

  @override
  Future<EditorDraft?> read(String identity, {String? team}) async {
    final answer = await _ask({'op': 'read', 'identity': identity, 'team': team});
    if (answer is! String || answer.isEmpty) return null;
    try {
      return EditorDraft.fromJson(jsonDecode(answer));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async {
    await _ask({'op': 'write', 'identity': identity, 'team': team, 'draft': draft.toJson()});
  }

  @override
  Future<void> remove(String identity, {String? team}) async {
    await _ask({'op': 'remove', 'identity': identity, 'team': team});
  }

  /// The main window forgets old drafts as its databases open.
  @override
  Future<void> forgetOld({DateTime? now}) async {}
}
