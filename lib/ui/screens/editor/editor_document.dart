import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_find.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';

/// One file open in the editor (a tab): its text in a code editor's
/// controller, how it is written back (encoding, line breaks), its language
/// and indentation, what it was when last read or saved, and the file on its
/// host as it was then ([baseline]), to tell whether someone else changed it.
class EditorDocument extends ChangeNotifier {
  EditorDocument._({
    required this.source,
    required String text,
    required this.encoding,
    required this.lineBreak,
    required this.mixedLineBreaks,
    required this.openedNotUtf8,
    required this.baseline,
  })  : savedText = text,
        _savedEncoding = encoding,
        _savedLineBreak = lineBreak {
    language = EditorLanguages.detect(source.fileName, path: source.path, firstLine: _firstLine(text));
    indent = EditorIndent.detect(text, language);
    controller = CodeLineEditingController.fromText(text, _options);
    find = EditorFindController(controller);
    _lines = controller.codeLines;
    controller.addListener(_onValue);
  }

  /// A file read as [bytes] (in [as], else as its bytes say), at [version].
  factory EditorDocument.fromBytes(EditorSource source, Uint8List bytes, {EditorEncoding? as, FileVersion? version}) {
    final decoded = EditorCodec.decode(bytes, as: as);
    return EditorDocument._(
      source: source,
      text: decoded.text,
      encoding: decoded.encoding,
      lineBreak: decoded.lineBreak,
      mixedLineBreaks: decoded.mixedLineBreaks,
      openedNotUtf8: decoded.notUtf8,
      baseline: version ?? FileVersion.of(bytes),
    );
  }

  /// A file read as [text] from a source that [EditorSource.movesText]; its
  /// line breaks are kept, as [encodingLabel] says what it is in.
  factory EditorDocument.fromText(EditorSource source, String text, {FileVersion? version, EditorEncoding? encoding}) {
    final crlf = text.contains('\r\n');
    final cr = !crlf && text.contains('\r');
    return EditorDocument._(
      source: source,
      text: text.replaceAll('\r\n', '\n').replaceAll('\r', '\n'),
      encoding: encoding ?? EditorEncoding.utf8,
      lineBreak: crlf
          ? EditorLineBreak.crlf
          : cr
              ? EditorLineBreak.cr
              : EditorLineBreak.lf,
      mixedLineBreaks: false,
      openedNotUtf8: false,
      baseline: version,
    );
  }

  /// A tab moved from another of the app's windows, as it was there: the
  /// text as last saved or read ([savedText]) and what is typed over it
  /// ([text], unsaved), what it is written in, the file on its host as it was
  /// then ([baseline]), its language and indentation, and where the caret
  /// was ([selection]). Nothing typed is lost in a move.
  factory EditorDocument.moved(
    EditorSource source, {
    required String savedText,
    required String text,
    required EditorEncoding encoding,
    required EditorLineBreak lineBreak,
    bool mixedLineBreaks = false,
    bool encodingChanged = false,
    FileVersion? baseline,
    EditorLanguage? language,
    EditorIndent? indent,
    CodeLineSelection? selection,
  }) {
    final doc = EditorDocument._(
      source: source,
      text: savedText,
      encoding: encoding,
      lineBreak: lineBreak,
      mixedLineBreaks: mixedLineBreaks,
      openedNotUtf8: false,
      baseline: baseline,
    );
    if (language != null) doc.language = language;
    if (indent != null) doc.indent = indent;
    doc._encodingChanged = encodingChanged;
    if (text != savedText) doc.restoreText(text);
    if (selection != null) {
      try {
        doc.controller.selection = selection;
      } catch (_) {
        // A caret past the text's end: at its start then.
      }
    }
    return doc;
  }

  final EditorSource source;
  late final CodeLineEditingController controller;
  late final EditorFindController find;

  EditorEncoding encoding;
  EditorLineBreak lineBreak;
  bool mixedLineBreaks;

  /// It was not UTF-8 and opened in the closest match: the notice says so
  /// until it is closed.
  bool openedNotUtf8;

  late EditorLanguage language;
  late EditorIndent indent;

  /// The text as last saved or read ('\n' between lines).
  String savedText;

  /// What it was written in when last saved or read.
  EditorEncoding _savedEncoding;
  EditorLineBreak _savedLineBreak;

  /// Its changes were thrown away on purpose (Don't save): its draft goes
  /// with them.
  bool discarded = false;

  /// The file on its host as last read or written; null where that cannot
  /// be told (no check before saving then).
  FileVersion? baseline;

  /// Who may write it, once asked ([loadAccess]).
  FileAccess? access;

  bool saving = false;
  DateTime? savedAt;

  // What the editor's screen shows of it, kept with it, so that an editor
  // minimized and shown again, or a tab moved to another window, shows it as
  // it was.

  /// A draft of it is kept on this device now.
  bool drafted = false;

  /// Its draft was put back: when it was kept, and whether the file on its
  /// host changed since (null where that cannot be told).
  ({DateTime keptAt, bool? hostChanged})? draftRestored;

  /// The notices about it that were closed.
  bool draftNoticeHidden = false;
  bool encodingNoticeHidden = false;

  /// Where its code was scrolled to when its screen last let it go.
  double scrollTop = 0;
  double scrollLeft = 0;

  /// Whether its encoding or line endings were changed to save with (for a
  /// move to another window, which keeps that unsaved).
  bool get encodingChanged => _encodingChanged;

  /// The encoding was changed to save with: unsaved until saved.
  bool _encodingChanged = false;

  CodeLines? _lines;
  bool _modified = false;

  /// Whether the text differs from what was last saved or read.
  bool get modified => _modified || _encodingChanged;

  int? _changedCache;
  CodeLines? _changedFor;

  /// The lines (from 0, a range end not included) that differ from the saved
  /// text, for the bar beside them; null when nothing differs.
  (int, int)? get changedRange {
    if (changedLines == 0 && !_modified) return null;
    return _changedRangeCache;
  }

  (int, int)? _changedRangeCache;

  /// Within [changedRange], where its lines are as many as before: the
  /// lines that differ, one by one (two edits apart mark their own lines,
  /// not every line between them).
  Set<int>? _changedSet;

  /// Whether [line] (from 0) differs from the saved text.
  bool isChangedLine(int line) {
    final range = changedRange;
    if (range == null || line < range.$1 || line >= range.$2) return false;
    final set = _changedSet;
    return set == null || set.contains(line);
  }

  CodeLineOptions get _options => CodeLineOptions(indentSize: indent.tabs ? 4 : indent.size);

  static String _firstLine(String text) {
    final nl = text.indexOf('\n');
    return nl < 0 ? text : text.substring(0, nl);
  }

  /// Whether a tab (rather than spaces) is what Tab types in it.
  bool get typesTabs => indent.tabs && language.allowsTabs;

  void _onValue() {
    final lines = controller.codeLines;
    if (identical(lines, _lines)) return;
    _lines = lines;
    final now = controller.text != savedText;
    if (now != _modified) {
      _modified = now;
      notifyListeners();
    } else {
      // The count of changed lines in the status bar.
      notifyListeners();
    }
  }

  /// How many lines differ from the saved text: those between the lines
  /// that are the same at its start and at its end (cheap, and exact for
  /// one change in one place).
  int get changedLines {
    if (!modified) return 0;
    final lines = controller.codeLines;
    if (identical(lines, _changedFor) && _changedCache != null) return _changedCache!;
    final now = controller.text.split('\n');
    final before = savedText.split('\n');
    var head = 0;
    while (head < now.length && head < before.length && now[head] == before[head]) {
      head++;
    }
    var tail = 0;
    while (tail < now.length - head && tail < before.length - head && now[now.length - 1 - tail] == before[before.length - 1 - tail]) {
      tail++;
    }
    final n = now.length - head - tail;
    final m = before.length - head - tail;
    _changedFor = lines;
    // Lines only taken away leave no line of their own: the bar marks the
    // line where they were.
    _changedRangeCache = n > 0 ? (head, head + n) : (head.clamp(0, now.length - 1), (head + 1).clamp(1, now.length));
    _changedSet = null;
    if (n == m && n > 0) {
      _changedSet = {
        for (var i = head; i < head + n; i++)
          if (now[i] != before[i]) i,
      };
      _changedCache = _changedSet!.length;
      return _changedCache!;
    }
    _changedCache = n > m ? n : (m == 0 && n == 0 ? (_encodingChanged ? 0 : 1) : m);
    return _changedCache!;
  }

  /// The file's bytes as they would be saved now. Throws
  /// [EditorEncodeException] where a character has no byte in [encoding].
  Uint8List encoded() => EditorCodec.encode(controller.text, encoding, lineBreak);

  /// Who may write it: asked of its host once, for the owner chip and Save
  /// as root.
  Future<void> loadAccess() async {
    try {
      access = await source.access();
    } catch (_) {
      access = null;
    }
    notifyListeners();
  }

  /// Whether the file on its host is not the one last read or saved here;
  /// false where that cannot be told (a failed look never blocks a save).
  Future<bool> changedOnHost() async {
    final before = baseline;
    if (before == null) return false;
    try {
      final now = await source.version();
      return now != null && now.changedSince(before);
    } catch (_) {
      return false;
    }
  }

  /// Writes the text as the file (as root with [rootPassword]), and makes it
  /// the saved text. The text written is the text when this started; what is
  /// typed meanwhile stays unsaved.
  Future<void> save({String? rootPassword}) async {
    final text = controller.text;
    saving = true;
    notifyListeners();
    try {
      Uint8List? bytes;
      if (source.movesText) {
        await source.writeText(lineBreak == EditorLineBreak.lf ? text : text.replaceAll('\n', lineBreak.chars));
      } else {
        bytes = EditorCodec.encode(text, encoding, lineBreak);
        if (rootPassword != null) {
          await source.writeAsRoot(bytes, rootPassword);
        } else {
          await source.write(bytes);
        }
      }
      savedText = text;
      _encodingChanged = false;
      _savedEncoding = encoding;
      _savedLineBreak = lineBreak;
      mixedLineBreaks = false;
      savedAt = DateTime.now();
      _modified = controller.text != savedText;
      // What the file is now, for the next save's check: asked of the host,
      // else what was written.
      FileVersion? now;
      try {
        now = await source.version();
      } catch (_) {
        now = null;
      }
      baseline = now ?? (bytes == null ? baseline : FileVersion.of(bytes));
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  /// Reads the file again (in [as] where given, else its encoding now) and
  /// puts it in place of the text, which becomes the saved text.
  Future<void> reload({EditorEncoding? as}) async {
    String text;
    if (source.movesText) {
      text = (await source.readText()).replaceAll('\r\n', '\n').replaceAll('\r', '\n');
      FileVersion? now;
      try {
        now = await source.version();
      } catch (_) {
        now = null;
      }
      baseline = now ?? baseline;
    } else {
      final bytes = await source.read();
      final decoded = EditorCodec.decode(bytes, as: as ?? encoding);
      text = decoded.text;
      encoding = decoded.encoding;
      lineBreak = decoded.lineBreak;
      mixedLineBreaks = decoded.mixedLineBreaks;
      openedNotUtf8 = false;
      baseline = FileVersion.of(bytes, modified: (await _versionOrNull())?.modified);
    }
    savedText = text;
    _encodingChanged = false;
    _savedEncoding = encoding;
    _savedLineBreak = lineBreak;
    _modified = false;
    controller.text = text;
    _lines = controller.codeLines;
    notifyListeners();
  }

  Future<FileVersion?> _versionOrNull() async {
    try {
      return await source.version();
    } catch (_) {
      return null;
    }
  }

  /// Saves with [to] from now on (unsaved until saved).
  void saveWith(EditorEncoding to) {
    if (to == encoding) return;
    encoding = to;
    openedNotUtf8 = false;
    _encodingChanged = true;
    notifyListeners();
  }

  /// Writes its lines with [to] from now on (unsaved until saved).
  void setLineBreak(EditorLineBreak to) {
    if (to == lineBreak && !mixedLineBreaks) return;
    lineBreak = to;
    mixedLineBreaks = false;
    _encodingChanged = true;
    notifyListeners();
  }

  /// Colours it as [to].
  void setLanguage(EditorLanguage to) {
    language = to;
    notifyListeners();
  }

  /// Indents it with [to] from now on.
  void setIndent(EditorIndent to) {
    indent = to;
    notifyListeners();
  }

  /// Takes [text] as unsaved text in place of what it holds (a draft put
  /// back).
  void restoreText(String text) {
    controller.text = text;
  }

  /// Back to the text, the encoding and the line endings as last saved or
  /// read (a draft thrown away).
  void discardChanges() {
    encoding = _savedEncoding;
    lineBreak = _savedLineBreak;
    _encodingChanged = false;
    if (controller.text != savedText) controller.text = savedText;
    _modified = false;
    notifyListeners();
  }

  @override
  void dispose() {
    controller.removeListener(_onValue);
    find.dispose();
    controller.dispose();
    super.dispose();
  }
}
