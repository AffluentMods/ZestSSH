import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';

/// A2 - the shared "list + slide-in editor" split view used by Networks, Keys,
/// Port Forwarding and Automation.
///
/// This is a SPLIT VIEW, not a modal: the list stays fully visible and
/// interactive while the editor is open, so the user can click between items
/// and compare them without dismissing anything. The editor slides in from the
/// right whenever [editor] is non-null.
///
/// When nothing is selected ([editor] == null) the list occupies the FULL
/// width of the content area - so a big list of items uses all the space.
/// The moment an item is opened for edit (or a new one is created) the view
/// collapses to an even **50/50** split: the list takes the left half and the
/// editor slides into the right half. A draggable divider lets the user
/// rebalance for edge cases, clamped so neither pane drops below a usable
/// minimum.
class ListEditorSplit extends StatefulWidget {
  /// The left-hand list. Should be independently scrollable.
  final Widget list;

  /// The right-hand editor, or null when no item is selected.
  final Widget? editor;

  /// Max list width while the editor is CLOSED (left-aligned, capped so it
  /// doesn't stretch indefinitely on wide monitors).
  final double listMaxWidth;

  /// Fraction of the available width the list takes when the editor first
  /// opens, before the user drags the divider. 0.5 = an even 50/50 split.
  final double initialListFraction;

  const ListEditorSplit({
    super.key,
    required this.list,
    this.editor,
    this.listMaxWidth = 760,
    this.initialListFraction = 0.5,
  });

  @override
  State<ListEditorSplit> createState() => _ListEditorSplitState();
}

class _ListEditorSplitState extends State<ListEditorSplit> {
  /// Absolute readability floors - neither pane may shrink below these,
  /// regardless of the drag fraction, so both stay usable on smaller windows.
  static const double _minListWidth = 300;
  static const double _minEditorWidth = 400;

  /// Fraction bounds the divider drag is clamped to on normal-width windows.
  static const double _minFraction = 0.28;
  static const double _maxFraction = 0.70;

  static const double _dividerWidth = 12;

  late double _fraction;
  bool _dragging = false;
  double _avail = 1;

  @override
  void initState() {
    super.initState();
    _fraction = widget.initialListFraction;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final hasEditor = widget.editor != null;
        final total = constraints.maxWidth;
        _avail = (total - _dividerWidth).clamp(1.0, double.infinity);

        // Fraction-derived list width, then the absolute-floor safety net so a
        // narrow window can't crush either pane below its minimum.
        double listW = _avail * _fraction;
        final maxListW = _avail - _minEditorWidth;
        if (maxListW >= _minListWidth) {
          listW = listW.clamp(_minListWidth, maxListW);
        } else {
          // Window too narrow to satisfy both minimums - split evenly.
          listW = _avail * 0.5;
        }

        // Kept as the FIRST child of the Row in both states so the list's
        // Element (and its scroll position) survives opening/closing the
        // editor. Width animates on open/close but is immediate while
        // dragging so the divider tracks the cursor 1:1.
        // Each pane is its own traversal unit. Reading-order traversal runs
        // over the whole window, so without this a Tab from an editor field
        // lands on a list row (or a sidebar entry) that happens to sit in the
        // same horizontal band. The list keeps its rows contiguous; the
        // editor is a form and gets a scope of its own so Tab wraps inside it.
        final listColumn = AnimatedContainer(
          duration:
              _dragging ? Duration.zero : const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          // Editor CLOSED → the list fills the whole content area (100%).
          // Editor OPEN → the list takes ~half; the editor gets the rest.
          width: hasEditor ? listW : total,
          child: FocusTraversalGroup(child: widget.list),
        );

        return Row(
          children: [
            listColumn,
            if (hasEditor) ...[
              _ResizeHandle(
                onStart: () => setState(() => _dragging = true),
                onUpdate: (dx) => setState(() {
                  _fraction = (_fraction + dx / _avail)
                      .clamp(_minFraction, _maxFraction);
                }),
                onEnd: () => setState(() => _dragging = false),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 240),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) {
                    return SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.06, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  // Key by the editor's OWN key (every caller passes a stable
                  // per-selection ValueKey) so switching selection re-runs the
                  // slide, while an incidental parent rebuild does NOT. Keying
                  // on widget.editor.hashCode instead re-keyed on every rebuild,
                  // tearing down + re-inflating editors that hold local State
                  // (e.g. the snippet form's TextEditingControllers) - a
                  // background sync-pull rebuild would silently wipe unsaved
                  // edits.
                  child: KeyedSubtree(
                    key: widget.editor!.key,
                    child: FocusScope(
                      debugLabel: 'ListEditorSplit editor',
                      child: widget.editor!,
                    ),
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// The draggable divider between the list and the editor. Manages its own
/// hover/active highlight and reports horizontal drag deltas to the parent.
class _ResizeHandle extends StatefulWidget {
  const _ResizeHandle({
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hover = false;
  bool _active = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _hover || _active;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) {
          setState(() => _active = true);
          widget.onStart();
        },
        onHorizontalDragUpdate: (d) => widget.onUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) {
          setState(() => _active = false);
          widget.onEnd();
        },
        child: SizedBox(
          width: 12,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: highlight ? 3 : 1,
              decoration: BoxDecoration(
                color: highlight
                    ? AppColors.v3AccentPrimary
                    : AppColors.v3BorderSubtle,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
