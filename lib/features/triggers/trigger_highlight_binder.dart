import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/features/triggers/trigger_runtime.dart';

/// Applies HIGHLIGHT-action trigger rules to a live terminal.
///
/// Wrap a [TerminalView] with this. It listens to the terminal (output) and the
/// rule set, and, debounced, re-scans the recent buffer for each highlight
/// rule's pattern, drawing an anchored [TerminalHighlight] in the rule's colour
/// over every match. It renders nothing itself; the highlights are painted by
/// the TerminalView from the controller. A complete no-op unless the host has
/// highlight rules, so it is safe to mount on every terminal.
class TriggerHighlightBinder extends ConsumerStatefulWidget {
  final Terminal terminal;
  final TerminalController controller;

  /// The session's host, so per-host rules apply only where they should.
  final String? connectionId;

  final Widget child;

  const TriggerHighlightBinder({
    super.key,
    required this.terminal,
    required this.controller,
    required this.connectionId,
    required this.child,
  });

  @override
  ConsumerState<TriggerHighlightBinder> createState() =>
      _TriggerHighlightBinderState();
}

class _TriggerHighlightBinderState
    extends ConsumerState<TriggerHighlightBinder> {
  final List<TerminalHighlight> _highlights = [];
  Timer? _debounce;
  TriggerRuntime? _runtime;

  /// Only the most recent lines are scanned: highlights matter for what the
  /// user is looking at, and this bounds the cost on a huge scrollback.
  static const int _scanLineWindow = 2000;

  /// Hard cap on simultaneous highlights so a pathological pattern can't create
  /// tens of thousands of anchors.
  static const int _maxHighlights = 300;

  @override
  void initState() {
    super.initState();
    widget.terminal.addListener(_scheduleRefresh);
    _runtime = ref.read(triggerRuntimeProvider);
    _runtime!.revision.addListener(_scheduleRefresh);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  void _scheduleRefresh() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 220), _refresh);
  }

  void _refresh() {
    if (!mounted) return;
    final rules = _runtime?.highlightRulesFor(widget.connectionId) ?? const [];

    // Clear the previous pass. Cheap when there were none.
    for (final h in _highlights) {
      h.dispose();
    }
    _highlights.clear();
    if (rules.isEmpty) return;

    final buffer = widget.terminal.buffer;
    final total = buffer.lines.length;
    final start = total > _scanLineWindow ? total - _scanLineWindow : 0;
    var count = 0;
    // Newest lines first, the ones on screen; each rule a share of time for
    // the pass (TriggerWorkBudget), so a slow pattern cannot hold the screen.
    final budget = TriggerWorkBudget();

    for (var i = total - 1; i >= start; i--) {
      if (budget.spent) break; // every rule together used the pass's share
      final String text;
      try {
        text = buffer.lines[i].toString();
      } catch (_) {
        continue;
      }
      if (text.isEmpty) continue;
      for (final rule in rules) {
        if (!budget.allows(rule)) continue;
        final matches = budget.run(rule, () => rule.regex.allMatches(rule.triggerLine(text)).toList());
        for (final m in matches) {
          if (m.start == m.end) continue; // skip zero-width matches
          try {
            final p1 = buffer.createAnchor(m.start, i);
            final p2 = buffer.createAnchor(m.end, i);
            _highlights.add(widget.controller.highlight(
              p1: p1,
              p2: p2,
              color: Color(rule.highlightColor ?? kTriggerDefaultHighlightArgb)
                  .withValues(alpha: 0.32),
            ));
            count++;
            if (count >= _maxHighlights) return;
          } catch (_) {
            // Skip anchors the buffer rejects (e.g. line just trimmed).
          }
        }
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    widget.terminal.removeListener(_scheduleRefresh);
    _runtime?.revision.removeListener(_scheduleRefresh);
    for (final h in _highlights) {
      h.dispose();
    }
    _highlights.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
