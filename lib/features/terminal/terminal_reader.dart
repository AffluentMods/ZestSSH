import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/terminal_fonts.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;
import 'package:zestssh/ui/widgets/zest_switch.dart';

/// A terminal for a screen reader (4.0 accessibility pass). A terminal's text
/// is painted, not laid out as text, so a screen reader finds nothing in it.
/// Three things make up for that:
///
/// * The terminal is one node with a name ("Terminal: web-01"), a tap that
///   gives it the keyboard, and an action, Read the screen, that opens
///   [TerminalReaderView].
/// * New lines are read out as they arrive ([TerminalReadAloud]), while a
///   screen reader is on and Read new output aloud is (on until turned off):
///   the lines that came since the last time, once the output has paused, at
///   most [TerminalReadAloud.maxLines] of them, and how many more there are.
///   What is typed is not read again (the line under the cursor alone
///   changing is typing, or a progress line, and the keyboard says what it
///   types). A full-screen program (vim, top, less: the terminal's other
///   screen) is said once when it opens, not line by line.
/// * [TerminalReaderView] lists the screen and its scrollback one line to a
///   node, to go through line by line by swipe or arrow keys.
abstract final class TerminalText {
  /// The rows on screen, each without the spaces at its end.
  static List<String> screen(Terminal terminal) {
    final buffer = terminal.buffer;
    final lines = buffer.lines;
    final first = buffer.scrollBack.clamp(0, lines.length);
    return [
      for (var i = first; i < lines.length; i++) lines[i].getText().trimRight(),
    ];
  }

  /// The terminal's lines, scrollback and all, a line the terminal folded to
  /// fit its width put back together; the last [last] of them where given.
  static List<String> all(Terminal terminal, {int? last}) {
    final lines = terminal.buffer.lines;
    final out = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final text = line.getText();
      if (i > 0 && line.isWrapped && out.isNotEmpty) {
        out[out.length - 1] = out.last + text;
      } else {
        out.add(text);
      }
    }
    for (var i = 0; i < out.length; i++) {
      out[i] = out[i].trimRight();
    }
    while (out.isNotEmpty && out.last.isEmpty) {
      out.removeLast();
    }
    if (last != null && out.length > last) return out.sublist(out.length - last);
    return out;
  }

  /// The lines of [after] that are new since [before], two pictures of the
  /// screen: lines that scrolled in at the bottom and lines that changed,
  /// in their order, without blank ones. The screen may have scrolled
  /// between them by any number of lines; the scroll that lines up the most
  /// of the lines that are not blank is taken. Only [cursorRow] changing,
  /// with nothing scrolled, is typing (or a progress line): nothing new.
  static List<String> newLines(List<String> before, List<String> after, {int? cursorRow}) {
    if (after.isEmpty) return const [];
    if (before.isEmpty) return [for (final l in after) if (l.trim().isNotEmpty) l];
    // A line with text that lines up counts twice a blank one: the blank
    // lines under a prompt line up the screen while nothing has scrolled.
    var bestShift = before.length;
    var bestScore = 0;
    for (var shift = 0; shift < before.length; shift++) {
      var score = 0;
      for (var i = 0; i + shift < before.length && i < after.length; i++) {
        if (after[i] == before[i + shift]) score += after[i].isEmpty ? 1 : 2;
      }
      if (score > bestScore) {
        bestScore = score;
        bestShift = shift;
      }
    }
    final changed = <int>[];
    for (var i = 0; i < after.length; i++) {
      final j = i + bestShift;
      final was = j < before.length ? before[j] : null;
      if (after[i] != was && after[i].trim().isNotEmpty) changed.add(i);
    }
    if (bestShift == 0 && changed.length == 1 && changed.single == cursorRow) return const [];
    return [for (final i in changed) after[i]];
  }
}

/// Reads a terminal's new lines aloud and makes it one named node for a
/// screen reader (see [TerminalText]). Only the terminal [speaks] says its
/// new lines: the one in front, of a split's panes.
class TerminalReadAloud extends ConsumerStatefulWidget {
  const TerminalReadAloud({
    super.key,
    required this.terminal,
    required this.name,
    required this.child,
    this.speaks = true,
    this.onActivate,
  });

  final Terminal terminal;

  /// The session's name, as its tab says it.
  final String name;
  final Widget child;
  final bool speaks;

  /// A screen reader's tap: what gives the terminal the keyboard.
  final VoidCallback? onActivate;

  /// The most lines read out at once; the rest are counted.
  static const maxLines = 12;

  /// How long the output pauses before what came is read.
  static const settle = Duration(milliseconds: 400);

  @override
  ConsumerState<TerminalReadAloud> createState() => _TerminalReadAloudState();
}

class _TerminalReadAloudState extends ConsumerState<TerminalReadAloud> {
  List<String> _before = const [];
  bool _wasFullScreen = false;
  Timer? _settle;

  @override
  void initState() {
    super.initState();
    _snapshot();
    widget.terminal.addListener(_changed);
  }

  @override
  void didUpdateWidget(TerminalReadAloud old) {
    super.didUpdateWidget(old);
    if (old.terminal != widget.terminal) {
      old.terminal.removeListener(_changed);
      widget.terminal.addListener(_changed);
      _snapshot();
    }
    // A pane that comes to the front starts from what it shows now, not from
    // all it was given while another spoke.
    if (!old.speaks && widget.speaks) _snapshot();
  }

  @override
  void dispose() {
    _settle?.cancel();
    widget.terminal.removeListener(_changed);
    super.dispose();
  }

  void _snapshot() {
    _before = TerminalText.screen(widget.terminal);
    _wasFullScreen = widget.terminal.isUsingAltBuffer;
  }

  bool get _listening =>
      widget.speaks &&
      SemanticsBinding.instance.semanticsEnabled &&
      ref.read(terminalReadAloudProvider);

  void _changed() {
    if (!_listening) {
      _settle?.cancel();
      return;
    }
    _settle?.cancel();
    _settle = Timer(TerminalReadAloud.settle, _read);
  }

  void _read() {
    if (!mounted || !_listening) return;
    final l10n = AppLocalizations.of(context)!;
    final terminal = widget.terminal;
    final fullScreen = terminal.isUsingAltBuffer;
    if (fullScreen != _wasFullScreen) {
      _snapshot();
      if (fullScreen) zestAnnounce(context, l10n.terminalReaderFullScreen);
      return;
    }
    if (fullScreen) {
      _snapshot();
      return;
    }
    final after = TerminalText.screen(terminal);
    final lines = TerminalText.newLines(_before, after, cursorRow: terminal.buffer.cursorY);
    _before = after;
    if (lines.isEmpty) return;
    final said = lines.length > TerminalReadAloud.maxLines
        ? [
            ...lines.sublist(lines.length - TerminalReadAloud.maxLines),
            l10n.terminalReaderMore(lines.length - TerminalReadAloud.maxLines),
          ]
        : lines;
    zestAnnounce(context, said.join('\n'));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      container: true,
      label: l10n.terminalReaderName(widget.name),
      hint: l10n.terminalReaderHint,
      onTap: widget.onActivate,
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.terminalReadScreen): () =>
            showTerminalReader(context, terminal: widget.terminal, name: widget.name),
      },
      child: widget.child,
    );
  }
}

/// Opens [TerminalReaderView] over the app for [terminal]: a screen of its
/// own with its own bar (not a dialog), which Close or Back leaves.
Future<void> showTerminalReader(
  BuildContext context, {
  required Terminal terminal,
  required String name,
}) =>
    Navigator.of(context).push<void>(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => TerminalReaderView(terminal: terminal, name: name),
    ));

/// Read the screen: a terminal's lines, the last [maxLines] of its
/// scrollback and its screen, one line to a node, the newest at the bottom
/// and in focus first. A screen reader goes through them line by line, the
/// arrow keys too, each line in focus showing the accent's ring; a blank
/// line says so. It is what was there when it opened; Refresh reads it again.
class TerminalReaderView extends ConsumerStatefulWidget {
  const TerminalReaderView({super.key, required this.terminal, required this.name});

  final Terminal terminal;
  final String name;

  static const maxLines = 1000;

  @override
  ConsumerState<TerminalReaderView> createState() => _TerminalReaderViewState();
}

class _TerminalReaderViewState extends ConsumerState<TerminalReaderView> {
  final _scroll = ScrollController();
  late List<String> _lines;
  late List<FocusNode> _nodes;

  @override
  void initState() {
    super.initState();
    _read();
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  void _read() {
    _lines = TerminalText.all(widget.terminal, last: TerminalReaderView.maxLines);
    _nodes = [for (var i = 0; i < _lines.length; i++) FocusNode(debugLabel: 'terminal line $i')];
  }

  void _refresh() {
    final old = _nodes;
    setState(_read);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final n in old) {
        n.dispose();
      }
      _toEnd();
    });
  }

  void _toEnd() {
    if (!mounted) return;
    if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    if (_nodes.isNotEmpty) _nodes.last.requestFocus();
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final n in _nodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _move(int from, int by) {
    final to = (from + by).clamp(0, _nodes.length - 1);
    _nodes[to].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final speak = ref.watch(terminalReadAloudProvider);
    // Esc leaves it, as it leaves a dialog.
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.of(context).maybePop()},
      child: Scaffold(
      backgroundColor: ZestTokens.surfaceBase,
      // The Scaffold's own bar keeps clear of a phone's status bar, and the
      // body of its navigation bar.
      appBar: AppBar(
        backgroundColor: ZestTokens.surfaceBase,
        title: Text(l10n.terminalReaderTitle(widget.name)),
        leading: IconButton(
          tooltip: l10n.close,
          icon: const Icon(LucideIcons.x),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            key: const ValueKey('terminal-reader-refresh'),
            tooltip: l10n.terminalReaderRefresh,
            icon: const Icon(LucideIcons.refreshCw),
            onPressed: _refresh,
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l10n.terminalReaderSpeakNew,
                      style: TextStyle(fontSize: 14, color: ZestTokens.textPrimary),
                    ),
                  ),
                  ZestSwitch(
                    key: const ValueKey('terminal-reader-speak'),
                    value: speak,
                    onChanged: (on) => ref.read(settingsUpdaterProvider).setTerminalReadAloud(on),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: _lines.isEmpty
                ? Center(
                    child: Text(l10n.terminalReaderEmpty, style: TextStyle(color: ZestTokens.textSecondary)),
                  )
                : ListView.builder(
                    key: const ValueKey('terminal-reader-lines'),
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: _lines.length,
                    itemBuilder: (context, i) => _Line(
                      text: _lines[i],
                      blank: l10n.terminalReaderBlank,
                      focusNode: _nodes[i],
                      onMove: (by) => _move(i, by),
                    ),
                  ),
          ),
        ],
      ),
      ),
      ),
    );
  }
}

class _Line extends StatefulWidget {
  const _Line({required this.text, required this.blank, required this.focusNode, required this.onMove});

  final String text;
  final String blank;
  final FocusNode focusNode;
  final void Function(int by) onMove;

  @override
  State<_Line> createState() => _LineState();
}

class _LineState extends State<_Line> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final empty = widget.text.trim().isEmpty;
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) Scrollable.ensureVisible(context, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowUp) {
          widget.onMove(-1);
        } else if (key == LogicalKeyboardKey.arrowDown) {
          widget.onMove(1);
        } else if (key == LogicalKeyboardKey.pageUp) {
          widget.onMove(-20);
        } else if (key == LogicalKeyboardKey.pageDown) {
          widget.onMove(20);
        } else if (key == LogicalKeyboardKey.home && HardwareKeyboard.instance.isControlPressed) {
          widget.onMove(-1 << 20);
        } else if (key == LogicalKeyboardKey.end && HardwareKeyboard.instance.isControlPressed) {
          widget.onMove(1 << 20);
        } else {
          return KeyEventResult.ignored;
        }
        return KeyEventResult.handled;
      },
      child: Semantics(
        label: empty ? widget.blank : widget.text,
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 24),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: _focused ? ZestTokens.brand : Colors.transparent, width: 2),
          ),
          child: Text(
            empty ? ' ' : widget.text,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              // A prompt's powerline signs and icons, as the terminal
              // draws them (4.0).
              fontFamilyFallback: const [kNerdFontSymbolsFamily],
              fontSize: 13,
              height: 1.4,
              color: ZestTokens.textPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
