import 'dart:async';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;

/// Find-in-terminal search overlay.
///
/// Renders as a floating bar above the terminal, searches through the
/// terminal buffer, highlights matches, and allows navigating between them.
class TerminalSearchBar extends StatefulWidget {
  final Terminal terminal;
  final TerminalController controller;
  final TerminalTheme theme;
  final VoidCallback onClose;

  /// Brings the current match's buffer line into view (the terminal's
  /// TerminalViewState.scrollToLine), each time the current match changes:
  /// a match was highlighted and counted, and left wherever it was.
  final ValueChanged<int>? onShowLine;

  /// The search field's focus, where its owner gives the keyboard back to
  /// it (a computer's Find asked for again); the bar's own otherwise.
  final FocusNode? focusNode;

  const TerminalSearchBar({
    super.key,
    required this.terminal,
    required this.controller,
    required this.theme,
    required this.onClose,
    this.onShowLine,
    this.focusNode,
  });

  @override
  State<TerminalSearchBar> createState() => _TerminalSearchBarState();
}

class _TerminalSearchBarState extends State<TerminalSearchBar> {
  final _searchController = TextEditingController();
  FocusNode? _ownFocus;
  FocusNode get _focusNode => widget.focusNode ?? (_ownFocus ??= FocusNode());
  final _highlights = <TerminalHighlight>[];
  Timer? _debounceTimer;

  /// Hard cap on match highlights. Scanning + highlighting the entire
  /// scrollback on the UI isolate janks badly on huge buffers; stop once we
  /// hit the cap and surface it as "N+" so the user knows to refine.
  static const _maxMatches = 500;

  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _regexError = false;
  bool _capped = false;
  int _currentMatch = -1;
  int _totalMatches = 0;

  /// Stored match positions as (lineIndex, startX, endX).
  final _matchPositions = <_MatchPosition>[];

  @override
  void initState() {
    super.initState();
    _focusNode.requestFocus();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _clearHighlights();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant TerminalSearchBar old) {
    super.didUpdateWidget(old);
    // Another terminal to search (another tmux pane in front): the marks
    // leave the one before, and the same words are looked for in this one.
    if (!identical(old.terminal, widget.terminal) || !identical(old.controller, widget.controller)) {
      _debounceTimer?.cancel();
      _performSearch();
    }
  }

  /// A keyboard's Enter goes to the next match and Shift+Enter to the one
  /// before, the field keeping the keyboard (a search field gives it up at
  /// its first Enter); Escape closes the bar. An Enter that ends a word an
  /// input method is composing is the input method's.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape) {
      if (event is KeyDownEvent) _close();
      return KeyEventResult.handled;
    }
    if (key != LogicalKeyboardKey.enter && key != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }
    final composing = _searchController.value.composing;
    if (composing.isValid && !composing.isCollapsed) return KeyEventResult.ignored;
    if (_debounceTimer?.isActive ?? false) {
      // Typed and not yet looked for: looked for now, at its last match.
      _debounceTimer!.cancel();
      _performSearch();
    } else if (HardwareKeyboard.instance.isShiftPressed) {
      _previousMatch();
    } else {
      _nextMatch();
    }
    return KeyEventResult.handled;
  }

  void _onSearchChanged() {
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _performSearch();
    });
  }

  void _performSearch() {
    _clearHighlights();
    _matchPositions.clear();

    final query = _searchController.text;
    if (query.isEmpty) {
      setState(() {
        _currentMatch = -1;
        _totalMatches = 0;
      });
      return;
    }

    final buffer = widget.terminal.buffer;
    _capped = false;
    _regexError = false;

    // Whole-word search goes through RegExp over an ESCAPED literal (so the
    // query can never be a raw user pattern - that avoids catastrophic-
    // backtracking ReDoS on untrusted terminal output); a plain search keeps
    // the faster indexOf scan. Free-form regex find is deferred to a future
    // release where it runs in a timeout-guarded background isolate.
    if (_wholeWord) {
      var pattern = RegExp.escape(query);
      pattern = '\\b(?:$pattern)\\b';
      RegExp re;
      try {
        re = RegExp(pattern, caseSensitive: _caseSensitive, unicode: true);
      } catch (_) {
        setState(() {
          _regexError = true;
          _currentMatch = -1;
          _totalMatches = 0;
        });
        return;
      }
      for (var lineIdx = 0; lineIdx < buffer.lines.length; lineIdx++) {
        final lineText = buffer.lines[lineIdx].toString();
        for (final m in re.allMatches(lineText)) {
          if (m.end <= m.start) continue; // skip zero-width matches (e.g. "a*")
          _matchPositions.add(_MatchPosition(
            line: lineIdx,
            startX: m.start,
            endX: m.end),
          );
          if (_matchPositions.length >= _maxMatches) {
            _capped = true;
            break;
          }
        }
        if (_capped) break;
      }
    } else {
      final searchQuery = _caseSensitive ? query : query.toLowerCase();
      // Scan buffer lines for matches, stopping at [_maxMatches] to keep the
      // UI isolate responsive on very large scrollbacks.
      for (var lineIdx = 0; lineIdx < buffer.lines.length; lineIdx++) {
        final lineText = buffer.lines[lineIdx].toString();
        final searchLine = _caseSensitive ? lineText : lineText.toLowerCase();

        var startPos = 0;
        while (true) {
          final matchIdx = searchLine.indexOf(searchQuery, startPos);
          if (matchIdx == -1) break;

          _matchPositions.add(_MatchPosition(
            line: lineIdx,
            startX: matchIdx,
            endX: matchIdx + query.length,
          ));

          startPos = matchIdx + 1;

          if (_matchPositions.length >= _maxMatches) {
            _capped = true;
            break;
          }
        }
        if (_capped) break;
      }
    }

    _totalMatches = _matchPositions.length;

    if (_totalMatches > 0) {
      // Start at the last match (most recent output)
      _currentMatch = _matchPositions.length - 1;
      _highlightMatches();
      _showCurrent();
    } else {
      _currentMatch = -1;
    }

    setState(() {});
  }

  void _highlightMatches() {
    _clearHighlights();

    final buffer = widget.terminal.buffer;

    for (var i = 0; i < _matchPositions.length; i++) {
      final match = _matchPositions[i];
      final isCurrent = i == _currentMatch;

      final color = isCurrent
          ? widget.theme.searchHitBackgroundCurrent
          : widget.theme.searchHitBackground;

      try {
        final p1 = buffer.createAnchor(match.startX, match.line);
        final p2 = buffer.createAnchor(match.endX, match.line);

        final highlight = widget.controller.highlight(
          p1: p1,
          p2: p2,
          color: color,
        );
        _highlights.add(highlight);
      } catch (_) {
        // Skip invalid ranges
      }
    }
  }

  void _clearHighlights() {
    for (final h in _highlights) {
      h.dispose();
    }
    _highlights.clear();
  }

  void _nextMatch() {
    if (_totalMatches == 0) return;
    setState(() {
      _currentMatch = (_currentMatch + 1) % _totalMatches;
    });
    _highlightMatches();
    _showCurrent();
  }

  void _previousMatch() {
    if (_totalMatches == 0) return;
    setState(() {
      _currentMatch = (_currentMatch - 1 + _totalMatches) % _totalMatches;
    });
    _highlightMatches();
    _showCurrent();
  }

  /// The current match's line, brought into view.
  void _showCurrent() {
    if (_currentMatch < 0 || _currentMatch >= _matchPositions.length) return;
    widget.onShowLine?.call(_matchPositions[_currentMatch].line);
  }

  void _toggleCaseSensitive() {
    setState(() {
      _caseSensitive = !_caseSensitive;
    });
    _performSearch();
  }

  void _toggleWholeWord() {
    setState(() {
      _wholeWord = !_wholeWord;
    });
    _performSearch();
  }


  Widget _searchToggle({
    required String glyph,
    required bool active,
    required VoidCallback onPressed,
    required String tooltip,
  }) {
    return Semantics(
      label: tooltip,
      button: true,
      toggled: active,
      // Its name once, not its glyph after it.
      excludeSemantics: true,
      onTap: onPressed,
      child: SizedBox(
        width: _side,
        height: _side,
        child: IconButton(
          icon: Text(
            glyph,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.bold,
              color: active ? AppColors.accentInk : AppColors.onSurfaceDim,
            ),
          ),
          onPressed: onPressed,
          tooltip: tooltip,
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ),
    );
  }

  void _close() {
    _clearHighlights();
    widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final queryNotEmpty = _searchController.text.isNotEmpty;

    return Container(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 0),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.brandOrange.withValues(alpha: 0.3),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      // Where a finger taps it, on a narrow screen, the field has a line of
      // its own and the buttons, 48 square, the line under it (4.0
      // accessibility pass: in one line the field was left some 50 wide).
      child: LayoutBuilder(builder: (context, box) {
        final field = <Widget>[
          // Search icon
          Icon(
            LucideIcons.search,
            size: 20,
            color: queryNotEmpty && _totalMatches > 0
                ? AppColors.accentInk
                : AppColors.onSurfaceDim,
          ),
          const SizedBox(width: 8),

          // Search input
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onKeyEvent: _onKey,
              child: TextField(
              controller: _searchController,
              focusNode: _focusNode,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 14,
                color: AppColors.onSurface,
              ),
              decoration: InputDecoration(
                hintText: l10n.terminalSearchHint,
                hintStyle: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 14,
                  color: AppColors.onSurfaceDim,
                ),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                filled: false,
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: isTouchLayout ? 15 : 12),
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _nextMatch(),
            ),
            ),
          ),

          // Match count
          if (queryNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              // Said as it changes, in words ("Match 1 of 3"; "1/3" to the
              // eye).
              child: Semantics(
                liveRegion: true,
                label: _regexError
                    ? l10n.terminalSearchInvalidRegex
                    : _totalMatches > 0
                        ? l10n.a11yFindMatch(_currentMatch + 1, '$_totalMatches${_capped ? '+' : ''}')
                        : l10n.terminalSearchNoResults,
                excludeSemantics: true,
                child: Text(
                _regexError
                    ? l10n.terminalSearchInvalidRegex
                    : _totalMatches > 0
                        ? '${_currentMatch + 1}/$_totalMatches${_capped ? '+' : ''}'
                        : l10n.terminalSearchNoResults,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  color: _totalMatches > 0 && !_regexError
                      ? AppColors.onSurfaceVariant
                      : AppColors.error,
                ),
              ),
              ),
            ),

        ];
        final buttons = <Widget>[
          // Case-sensitive toggle
          Semantics(
            label: l10n.terminalSearchToggleCaseSensitiveLabel,
            button: true,
            toggled: _caseSensitive,
            // Its name once, not "Aa" after it.
            excludeSemantics: true,
            onTap: _toggleCaseSensitive,
            child: SizedBox(
              width: _side,
              height: _side,
              child: IconButton(
                icon: Text(
                  'Aa',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                    color: _caseSensitive
                        ? AppColors.accentInk
                        : AppColors.onSurfaceDim,
                  ),
                ),
                onPressed: _toggleCaseSensitive,
                tooltip: l10n.terminalSearchCaseSensitive,
                padding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),

          // Whole-word toggle
          _searchToggle(
            glyph: r'\b',
            active: _wholeWord,
            onPressed: _toggleWholeWord,
            tooltip: l10n.terminalSearchWholeWord,
          ),

          // Previous match
          SizedBox(
            width: _side,
            height: _side,
            child: IconButton(
              icon: const Icon(LucideIcons.chevronUp, size: 22),
              onPressed: _totalMatches > 0 ? _previousMatch : null,
              tooltip: l10n.terminalSearchPreviousMatch,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),

          // Next match
          SizedBox(
            width: _side,
            height: _side,
            child: IconButton(
              icon: const Icon(LucideIcons.chevronDown, size: 22),
              onPressed: _totalMatches > 0 ? _nextMatch : null,
              tooltip: l10n.terminalSearchNextMatch,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),

          // Close
          SizedBox(
            width: _side,
            height: _side,
            child: IconButton(
              icon: const Icon(LucideIcons.x, size: 20),
              onPressed: _close,
              tooltip: l10n.terminalSearchClose,
              padding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ];
        if (isTouchLayout && box.maxWidth < 480) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(children: field),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: buttons),
            ],
          );
        }
        return Row(children: [...field, ...buttons]);
      }),
    );
  }
}

/// The bar's buttons: 48 square where a finger taps them (4.0 accessibility
/// pass; 36 there too before), 36 to a mouse.
double get _side => isTouchLayout ? 48 : 36;

class _MatchPosition {
  final int line;
  final int startX;
  final int endX;

  const _MatchPosition({
    required this.line,
    required this.startX,
    required this.endX,
  });
}
