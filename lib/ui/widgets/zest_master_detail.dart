import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// ZestSSH 1.7 master/detail SHELL primitive.
///
/// A two-pane split: a fixed-width [listPane] on the left, a [detailPane] that
/// fills the rest on the right, with a draggable 1px divider between them. The
/// divider's position is PERSISTED per [screenId] via `shared_preferences`
/// (key `zest_split_<screenId>`), so a user's chosen balance survives app
/// restarts and is independent for every screen that uses the shell.
///
/// ## Narrow collapse
/// Below [ZestSizing.singleColumnBreakpoint] (1000px TOTAL width) the shell
/// collapses to a SINGLE column: only [listPane] is rendered, full-width, and
/// the divider is hidden. The persisted split value is left UNTOUCHED so the
/// wide layout is exactly restored when the window grows back.
///
/// In that narrow mode the caller is responsible for presenting the detail as
/// its OWN route - the shell will not show [detailPane] inline. On selection,
/// callers push the detail with [ZestMasterDetail.pushDetail], which gives a
/// full-screen route with a back affordance. (The widget itself stays simple:
/// wide = split, narrow = list-only.)
class ZestMasterDetail extends StatefulWidget {
  const ZestMasterDetail({
    super.key,
    required this.screenId,
    required this.listPane,
    required this.detailPane,
    this.initialRatio = ZestSizing.defaultSplitRatio,
  });

  /// Stable per-screen identity. Drives the persistence key so each screen
  /// remembers its own divider position.
  final String screenId;

  /// The left-hand list. Should be independently scrollable.
  final Widget listPane;

  /// The right-hand detail. Ignored in the narrow single-column layout -
  /// present it via [pushDetail] there.
  final Widget detailPane;

  /// List-side fraction the split first opens at, before any persisted value
  /// is restored or the divider is dragged.
  final double initialRatio;

  /// Width of the invisible divider grab area. The visible rule is 1px,
  /// centered inside this.
  static const double dividerHitWidth = 8;

  /// The `shared_preferences` key a given [screenId] persists its split to.
  static String prefsKeyFor(String screenId) => 'zest_split_$screenId';

  /// Push [detail] as a full-screen route with a back affordance. Callers
  /// invoke this on selection when the shell has collapsed to a single column
  /// (window width below [ZestSizing.singleColumnBreakpoint]).
  static Future<T?> pushDetail<T>(BuildContext context, Widget detail) {
    return Navigator.of(context).push<T>(
      MaterialPageRoute<T>(builder: (_) => _ZestDetailRoute(child: detail)),
    );
  }

  @override
  State<ZestMasterDetail> createState() => _ZestMasterDetailState();
}

class _ZestMasterDetailState extends State<ZestMasterDetail> {
  late double _ratio;
  bool _dragging = false;
  double _lastTotal = 1;

  String get _prefsKey => ZestMasterDetail.prefsKeyFor(widget.screenId);

  @override
  void initState() {
    super.initState();
    _ratio = widget.initialRatio;
    _restore();
  }

  /// Restore the persisted split. Robust to a missing key (getDouble → null)
  /// and to any storage failure - on either it simply keeps [initialRatio].
  Future<void> _restore() async {
    try {
      final prefs = await appPreferences();
      final stored = prefs.getDouble(_prefsKey);
      if (stored != null && mounted) {
        setState(() => _ratio = stored);
      }
    } catch (_) {
      // Persistence is a nicety, never a hard dependency - ignore.
    }
  }

  Future<void> _persist(double ratio) async {
    try {
      final prefs = await appPreferences();
      await prefs.setDouble(_prefsKey, ratio);
    } catch (_) {
      // Ignore - a failed save just means the next open uses the default.
    }
  }

  /// Fraction the list may occupy, given [total], while honouring both pane
  /// minimums and the divider width.
  ({double min, double max}) _fractionBounds(double total) {
    final minFrac = ZestSizing.listPaneMinWidth / total;
    final maxFrac =
        (total - ZestSizing.detailPaneMinWidth - ZestMasterDetail.dividerHitWidth) /
            total;
    return (min: minFrac, max: maxFrac);
  }

  void _onDragUpdate(double dx) {
    final total = _lastTotal;
    final bounds = _fractionBounds(total);
    // Only clamp when both minimums actually fit; otherwise leave the ratio be
    // (build falls back to an even split at sub-minimum widths).
    if (bounds.max <= bounds.min) return;
    setState(() {
      _ratio = (_ratio + dx / total).clamp(bounds.min, bounds.max);
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final total = constraints.maxWidth;

        // Narrow: single column. Only the list, full-width. Divider hidden and
        // the persisted value untouched.
        if (total < ZestSizing.singleColumnBreakpoint) {
          return SizedBox.expand(child: widget.listPane);
        }

        _lastTotal = total;

        // Fraction-derived list width, then an absolute-floor safety net so
        // neither pane can be crushed below its minimum.
        double listW = total * _ratio;
        final maxListW =
            total - ZestSizing.detailPaneMinWidth - ZestMasterDetail.dividerHitWidth;
        if (maxListW >= ZestSizing.listPaneMinWidth) {
          listW = listW.clamp(ZestSizing.listPaneMinWidth, maxListW);
        } else {
          // Too narrow to satisfy both minimums (shouldn't happen above the
          // breakpoint, but stay safe) - split the usable space evenly.
          listW = (total - ZestMasterDetail.dividerHitWidth) * 0.5;
        }

        // Each pane is its own traversal unit. Reading-order traversal runs
        // over the whole window, so without this a Tab from a detail field
        // lands on a list row that sits in the same horizontal band. The list
        // keeps its rows contiguous; the detail is a form and gets a scope of
        // its own so Tab wraps inside it.
        return Row(
          children: [
            SizedBox(
              width: listW,
              child: FocusTraversalGroup(child: widget.listPane),
            ),
            _SplitHandle(
              active: _dragging,
              onStart: () => setState(() => _dragging = true),
              onUpdate: _onDragUpdate,
              onEnd: () {
                setState(() => _dragging = false);
                _persist(_ratio);
              },
            ),
            Expanded(
              child: FocusScope(
                debugLabel: 'ZestMasterDetail detail',
                child: widget.detailPane,
              ),
            ),
          ],
        );
      },
    );
  }
}

/// The draggable divider: an 8px invisible grab area with a resize cursor and a
/// 1px centered rule that brightens to [ZestTokens.brand] while hovered/active.
class _SplitHandle extends StatefulWidget {
  const _SplitHandle({
    required this.active,
    required this.onStart,
    required this.onUpdate,
    required this.onEnd,
  });

  final bool active;
  final VoidCallback onStart;
  final ValueChanged<double> onUpdate;
  final VoidCallback onEnd;

  @override
  State<_SplitHandle> createState() => _SplitHandleState();
}

class _SplitHandleState extends State<_SplitHandle> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final highlight = _hover || widget.active;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => widget.onStart(),
        onHorizontalDragUpdate: (d) => widget.onUpdate(d.delta.dx),
        onHorizontalDragEnd: (_) => widget.onEnd(),
        child: SizedBox(
          width: ZestMasterDetail.dividerHitWidth,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: highlight ? 2 : 1,
              color: highlight ? ZestTokens.brand : ZestTokens.borderStrong,
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen host for a detail pushed via [ZestMasterDetail.pushDetail] in the
/// narrow single-column layout. A minimal top bar provides the back affordance.
class _ZestDetailRoute extends StatelessWidget {
  const _ZestDetailRoute({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: ZestTokens.surfaceBase,
      body: SafeArea(
        child: Column(
          children: [
            SizedBox(
              height: ZestSizing.buttonLarge,
              child: Align(
                alignment: Alignment.centerLeft,
                child: IconButton(
                  tooltip: MaterialLocalizations.of(context).backButtonTooltip,
                  icon: const Icon(LucideIcons.arrowLeft, size: 20),
                  color: ZestTokens.textSecondary,
                  onPressed: () => Navigator.of(context).maybePop(),
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
