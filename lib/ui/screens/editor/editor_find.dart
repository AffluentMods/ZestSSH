import 'package:flutter/material.dart';
import 'package:re_editor/re_editor.dart';

/// Find and replace for the file editor (3.4): match case, whole word,
/// regex and in the selection, which the editor widget's own find has only
/// the first and third of. It searches in this isolate as the text changes
/// (a 4 MB file is searched in milliseconds), and Replace all is one step
/// to undo.
///
/// The editor widget paints what this finds ([allMatchSelections],
/// [currentMatchSelection]) as it paints its own.
class EditorFindController extends ValueNotifier<CodeFindValue?> implements CodeFindController {
  EditorFindController(this._controller) : super(null) {
    _controller.addListener(_onTextChanged);
    _findInput.addListener(_onPatternChanged);
  }

  final CodeLineEditingController _controller;
  final TextEditingController _findInput = TextEditingController();
  final TextEditingController _replaceInput = TextEditingController();
  final FocusNode _findFocus = FocusNode(debugLabel: 'editor-find');
  final FocusNode _replaceFocus = FocusNode(debugLabel: 'editor-replace');

  bool _wholeWord = false;
  bool _inSelection = false;

  /// The part of the text searched with [inSelection]: from where to where,
  /// as offsets into the whole text, fixed when it was turned on.
  (int, int)? _scope;
  CodeLines? _searched;

  bool get wholeWord => _wholeWord;
  bool get inSelection => _inSelection;
  bool get isOpen => value != null;
  bool get caseSensitive => value?.option.caseSensitive ?? false;
  bool get regex => value?.option.regex ?? false;

  /// Whether the pattern is a regex that does not read as one.
  bool get badPattern => regex && _findInput.text.isNotEmpty && _regExp() == null;

  int get matchCount => value?.result?.matches.length ?? 0;
  int get currentIndex => value?.result?.index ?? -1;

  @override
  TextEditingController get findInputController => _findInput;

  @override
  TextEditingController get replaceInputController => _replaceInput;

  @override
  FocusNode get findInputFocusNode => _findFocus;

  @override
  FocusNode get replaceInputFocusNode => _replaceFocus;

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _findInput.removeListener(_onPatternChanged);
    _findInput.dispose();
    _replaceInput.dispose();
    _findFocus.dispose();
    _replaceFocus.dispose();
    super.dispose();
  }

  // ── Opening and options ───────────────────────────────────────────

  @override
  void findMode() => _open(replace: false);

  @override
  void replaceMode() => _open(replace: true);

  void _open({required bool replace}) {
    final picked = _controller.selection;
    if (!picked.isCollapsed && picked.isSameLine) {
      final text = _controller.selectedText;
      if (text.isNotEmpty && !text.contains('\n')) {
        _findInput.removeListener(_onPatternChanged);
        _findInput.text = text;
        _findInput.addListener(_onPatternChanged);
      }
    }
    _findInput.selection = TextSelection(baseOffset: 0, extentOffset: _findInput.text.length);
    final pre = value ?? const CodeFindValue.empty();
    value = CodeFindValue(
      option: pre.option.copyWith(pattern: _findInput.text),
      replaceMode: replace || pre.replaceMode,
    );
    _search();
    (replace ? _replaceFocus : _findFocus).requestFocus();
  }

  @override
  void focusOnFindInput() {
    _findFocus.requestFocus();
    _findInput.selection = TextSelection(baseOffset: 0, extentOffset: _findInput.text.length);
  }

  @override
  void focusOnReplaceInput() {
    _replaceFocus.requestFocus();
    _replaceInput.selection = TextSelection(baseOffset: 0, extentOffset: _replaceInput.text.length);
  }

  @override
  void toggleMode() {
    final pre = value;
    if (pre == null) return;
    value = CodeFindValue(option: pre.option, replaceMode: !pre.replaceMode, result: pre.result);
  }

  @override
  void close() {
    value = null;
    _scope = null;
    _inSelection = false;
  }

  @override
  void toggleRegex() => _setOption(regex: !regex);

  @override
  void toggleCaseSensitive() => _setOption(caseSensitive: !caseSensitive);

  void toggleWholeWord() {
    _wholeWord = !_wholeWord;
    _setOption();
  }

  /// Search only the text selected now, or the whole text again.
  void toggleInSelection() {
    _inSelection = !_inSelection;
    _scope = null;
    if (_inSelection) {
      final sel = _controller.unfoldLineSelection;
      if (!sel.isCollapsed) {
        final starts = _lineStarts(_lines());
        _scope = (starts[sel.startIndex] + sel.startOffset, starts[sel.endIndex] + sel.endOffset);
      }
    }
    _setOption();
  }

  void _setOption({bool? caseSensitive, bool? regex}) {
    final pre = value;
    if (pre == null) return;
    value = CodeFindValue(
      option: pre.option.copyWith(caseSensitive: caseSensitive, regex: regex),
      replaceMode: pre.replaceMode,
    );
    _search();
  }

  void _onPatternChanged() {
    final pre = value;
    if (pre == null || pre.option.pattern == _findInput.text) return;
    value = CodeFindValue(option: pre.option.copyWith(pattern: _findInput.text), replaceMode: pre.replaceMode);
    _search();
  }

  void _onTextChanged() {
    if (value == null || identical(_searched, _controller.codeLines)) return;
    _search(keepIndex: true);
  }

  // ── Searching ─────────────────────────────────────────────────────

  RegExp? _regExp() {
    final option = value?.option;
    if (option == null || option.pattern.isEmpty) return null;
    var source = option.regex ? option.pattern : RegExp.escape(option.pattern);
    if (_wholeWord) source = r'\b(?:' + source + r')\b';
    try {
      return RegExp(source, caseSensitive: option.caseSensitive, multiLine: true);
    } on FormatException {
      return null;
    }
  }

  /// Every line, folded ones too.
  List<String> _lines() => [for (final line in _controller.codeLines.toList()) ...line.flat()];

  static List<int> _lineStarts(List<String> lines) {
    final starts = List<int>.filled(lines.length + 1, 0);
    for (var i = 0; i < lines.length; i++) {
      starts[i + 1] = starts[i] + lines[i].length + 1;
    }
    return starts;
  }

  static CodeLinePosition _position(List<int> starts, int offset) {
    var lo = 0;
    var hi = starts.length - 2;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return CodeLinePosition(index: lo, offset: offset - starts[lo]);
  }

  void _search({bool keepIndex = false}) {
    final pre = value;
    if (pre == null) return;
    _searched = _controller.codeLines;
    final re = _regExp();
    if (re == null) {
      value = CodeFindValue(option: pre.option, replaceMode: pre.replaceMode);
      return;
    }
    final lines = _lines();
    final starts = _lineStarts(lines);
    final text = lines.join('\n');
    final (from, to) = _scope ?? (0, text.length);
    final matches = <CodeLineSelection>[];
    for (final m in re.allMatches(text, from.clamp(0, text.length))) {
      if (m.end > to) break;
      if (m.end == m.start) continue;
      final a = _position(starts, m.start);
      final b = _position(starts, m.end);
      matches.add(CodeLineSelection(baseIndex: a.index, baseOffset: a.offset, extentIndex: b.index, extentOffset: b.offset));
      if (matches.length >= 100000) break;
    }
    var index = -1;
    if (matches.isNotEmpty) {
      final old = pre.result?.index ?? -1;
      if (keepIndex && old >= 0) {
        index = old.clamp(0, matches.length - 1);
      } else {
        final caret = _controller.unfoldLineSelection.start;
        index = matches.indexWhere((s) =>
            s.startIndex > caret.index || (s.startIndex == caret.index && s.startOffset >= caret.offset));
        if (index < 0) index = 0;
      }
    }
    value = CodeFindValue(
      option: pre.option,
      replaceMode: pre.replaceMode,
      result: CodeFindResult(
        index: index,
        matches: matches,
        option: pre.option,
        codeLines: _controller.codeLines,
        dirty: false,
      ),
    );
    _reveal();
  }

  void _reveal() {
    final current = currentMatchSelection;
    if (current != null) {
      try {
        _controller.makePositionCenterIfInvisible(current.start);
      } catch (_) {
        // Not laid out yet: it shows when it is.
      }
    }
  }

  @override
  List<CodeLineSelection>? get allMatchSelections {
    final matches = value?.result?.matches;
    if (matches == null) return null;
    return [
      for (final m in matches)
        ?convertMatchToSelection(m),
    ];
  }

  @override
  CodeLineSelection? get currentMatchSelection {
    final current = value?.result?.currentMatch;
    return current == null ? null : convertMatchToSelection(current);
  }

  @override
  CodeLineSelection? convertMatchToSelection(CodeLineSelection match) {
    final lines = _controller.codeLines;
    final base = lines.lineIndex2Index(match.baseIndex);
    if (base.chunkIndex >= 0) return null;
    final extent = match.isSameLine ? base : lines.lineIndex2Index(match.extentIndex);
    if (extent.chunkIndex >= 0) return null;
    return match.copyWith(baseIndex: base.index, extentIndex: extent.index);
  }

  @override
  void nextMatch() => _step(1);

  @override
  void previousMatch() => _step(-1);

  void _step(int by) {
    final pre = value;
    final result = pre?.result;
    if (pre == null || result == null || result.matches.isEmpty) return;
    final n = result.matches.length;
    value = CodeFindValue(
      option: pre.option,
      replaceMode: pre.replaceMode,
      result: result.copyWith(index: (result.index + by + n) % n),
    );
    _reveal();
  }

  // ── Replacing ─────────────────────────────────────────────────────

  @override
  void replaceMatch() {
    final current = currentMatchSelection;
    if (current == null) return;
    _controller.replaceSelection(_replaceInput.text, current);
    _search(keepIndex: true);
  }

  /// Every match replaced, as one step to undo.
  @override
  void replaceAllMatches() {
    final re = _regExp();
    if (re == null || matchCount == 0) return;
    // Folded lines are opened first, so what is replaced is in view.
    final lines = _lines();
    final text = lines.join('\n');
    final (from, to) = _scope ?? (0, text.length);
    final part = text.substring(from, to);
    final replaced = part.replaceAll(re, _replaceInput.text);
    if (replaced == part) return;
    final starts = _lineStarts(lines);
    final a = _position(starts, from);
    final b = _position(starts, to);
    _expandAll();
    _controller.replaceSelection(
      replaced,
      CodeLineSelection(baseIndex: a.index, baseOffset: a.offset, extentIndex: b.index, extentOffset: b.offset),
    );
    if (_scope != null) _scope = (from, from + replaced.length);
    _search();
  }

  void _expandAll() {
    for (var i = _controller.codeLines.length - 1; i >= 0; i--) {
      if (_controller.codeLines[i].chunks.isNotEmpty) _controller.expandChunk(i);
    }
  }
}
