import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';

/// The files open in the editor, as tabs (3.4): several files, from several
/// hosts, in one editor. At most [maxTabs]; opening one more asks which to
/// close.
class EditorWorkspace extends ChangeNotifier {
  static const int maxTabs = 12;

  final List<EditorDocument> _docs = [];
  int _active = 0;

  /// The editor's screen showing it, where one is (a file opened while one
  /// is shows as a new tab there, else the screen is opened). A screen that
  /// is not this one any more (it was minimized) leaves the tabs alone as it
  /// goes.
  Object? shownBy;

  /// Whether the editor's screen is showing it.
  bool get shown => shownBy != null;

  /// On a computer, the main window's editor put away to the status bar
  /// (3.4.1, so the editor can be minimized): its tabs, their
  /// unsaved text, caret and scrolling are all kept, and a file opened now
  /// joins them and shows the editor again.
  bool _minimized = false;
  bool get minimized => _minimized;
  set minimized(bool on) {
    if (on == _minimized) return;
    _minimized = on;
    notifyListeners();
  }

  /// On a computer (4.0.1) the editor is shown in the workspace area of the
  /// main window, where a terminal shows, with the sidebar and the session
  /// tabs beside it; the desktop shell says so while it is up.
  bool hostedInShell = false;

  /// Where [hostedInShell]: the editor is the one in front (its tab in the
  /// strip is). Choosing a session tab or a page puts it behind, its tabs,
  /// their unsaved text, caret and scrolling all kept.
  bool _front = false;
  bool get front => _front && _docs.isNotEmpty;
  set front(bool on) {
    if (on == _front) return;
    _front = on;
    notifyListeners();
  }

  /// The hosted editor's own close (it asks about unsaved changes): what the
  /// close button of its tab in the strip runs.
  Future<void> Function()? closeAsked;

  List<EditorDocument> get docs => List.unmodifiable(_docs);
  int get length => _docs.length;
  bool get isEmpty => _docs.isEmpty;
  bool get isFull => _docs.length >= maxTabs;
  int get activeIndex => _active;
  EditorDocument? get current => _docs.isEmpty ? null : _docs[_active.clamp(0, _docs.length - 1)];

  /// The tabs with changes not saved.
  List<EditorDocument> get unsaved => [for (final d in _docs) if (d.modified) d];

  /// The open tab of the file named [identity] ([EditorSource.identity]).
  EditorDocument? byIdentity(String identity) {
    for (final d in _docs) {
      if (d.source.identity == identity) return d;
    }
    return null;
  }

  /// Adds [doc] as a tab after the current one and shows it. The caller has
  /// made room ([isFull]).
  void add(EditorDocument doc) {
    final at = _docs.isEmpty ? 0 : _active + 1;
    _docs.insert(at, doc);
    _active = at;
    doc.addListener(notifyListeners);
    notifyListeners();
  }

  void activate(EditorDocument doc) {
    final i = _docs.indexOf(doc);
    if (i < 0 || i == _active) return;
    _active = i;
    notifyListeners();
  }

  void activateIndex(int i) {
    if (i < 0 || i >= _docs.length || i == _active) return;
    _active = i;
    notifyListeners();
  }

  /// Moves the tab at [from] to [to].
  void move(int from, int to) {
    if (from == to || from < 0 || from >= _docs.length) return;
    final current = this.current;
    final doc = _docs.removeAt(from);
    _docs.insert(to.clamp(0, _docs.length), doc);
    _active = current == null ? 0 : _docs.indexOf(current);
    notifyListeners();
  }

  /// Takes [doc]'s tab out without letting it go: it moved to another
  /// window, which holds its text now (the caller lets it go after).
  bool take(EditorDocument doc) {
    final i = _docs.indexOf(doc);
    if (i < 0) return false;
    _docs.removeAt(i);
    doc.removeListener(notifyListeners);
    if (_active > i || _active >= _docs.length) _active = (_active - 1).clamp(0, _docs.length);
    if (_docs.isEmpty) _minimized = false;
    notifyListeners();
    return true;
  }

  /// Closes [doc]'s tab, whatever it holds (the caller has asked), and lets
  /// it go.
  void remove(EditorDocument doc) {
    final i = _docs.indexOf(doc);
    if (i < 0) return;
    _docs.removeAt(i);
    doc.removeListener(notifyListeners);
    if (_active > i || _active >= _docs.length) _active = (_active - 1).clamp(0, _docs.length);
    if (_docs.isEmpty) {
      _minimized = false;
      _front = false;
    }
    notifyListeners();
    doc.dispose();
  }

  /// Closes every tab; [quietly] tells no one (the editor's screen, going
  /// away, which is the only one that shows them).
  void clear({bool quietly = false}) {
    for (final d in List.of(_docs)) {
      d.removeListener(notifyListeners);
      d.dispose();
    }
    _docs.clear();
    _active = 0;
    _minimized = false;
    _front = false;
    if (!quietly) notifyListeners();
  }

  /// Its tabs go with it (the profile changed: nothing of the one before
  /// stays in memory).
  @override
  void dispose() {
    clear(quietly: true);
    super.dispose();
  }
}

/// The editor's tabs, for the whole app (a window of its own has its own).
final editorWorkspaceProvider = ChangeNotifierProvider<EditorWorkspace>((ref) => EditorWorkspace());
