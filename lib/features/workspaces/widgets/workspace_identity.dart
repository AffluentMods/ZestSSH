import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// Presentational atoms unique to the workspace PLACEMENT surfaces (Hosts
/// drawer section, Hosts-page section, Split-tab empty state).
///
/// Shared dialog/preview pieces - the pane thumbnail, the `n tabs · n panes`
/// label, the "opened …" label, the Ctrl+N label, the member-name resolver,
/// and the kbd chip - live in `workspace_dialog_common.dart` and are reused
/// from there so both the dialogs and these surfaces read identically. This
/// file only holds what those don't cover: the segmented identity bar, the
/// compact member chips, and the dashed empty-state box.
///
/// §2 colour invariant: everything colour-carrying here is IDENTITY only
/// (member colours the provider already resolved), never status.

// ── Segmented identity bar ──────────────────────────────────────────

/// One contiguous colour band of the segmented identity bar, weighted by how
/// many member panes carry that colour.
typedef WorkspaceColorSegment = ({Color color, double weight});

/// Collapse a workspace's member colours into weighted, distinct segments in
/// first-occurrence (pane) order. `[acc, cyan, cyan, brown]` becomes
/// `acc:1, cyan:2, brown:1` so the middle band is twice as tall - matching the
/// design's segmented rule.
List<WorkspaceColorSegment> workspaceColorSegments(List<Color> memberColors) {
  if (memberColors.isEmpty) {
    return [(color: AppColors.neutralLabelColor, weight: 1)];
  }
  final order = <int>[]; // argb values, first-occurrence order
  final counts = <int, int>{};
  for (final c in memberColors) {
    final key = c.toARGB32();
    if (!counts.containsKey(key)) order.add(key);
    counts[key] = (counts[key] ?? 0) + 1;
  }
  return [
    for (final key in order)
      (color: Color(key), weight: counts[key]!.toDouble()),
  ];
}

/// A thin vertical identity bar built from a workspace's member colours.
/// Renders hard-edged colour bands (segment per distinct colour) so the bar
/// reads as "which hosts is this" at a glance.
class WorkspaceSegmentedBar extends StatelessWidget {
  const WorkspaceSegmentedBar({
    super.key,
    required this.memberColors,
    this.width = 3,
    this.borderRadius,
  });

  final List<Color> memberColors;
  final double width;
  final BorderRadius? borderRadius;

  @override
  Widget build(BuildContext context) {
    final segments = workspaceColorSegments(memberColors);
    final radius = borderRadius ?? BorderRadius.circular(2);

    if (segments.length == 1) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: segments.first.color,
          borderRadius: radius,
        ),
        child: SizedBox(width: width, height: double.infinity),
      );
    }

    // Build hard-edged gradient stops: each segment contributes its colour
    // twice (at its start and end fraction) so bands don't blend.
    final total = segments.fold<double>(0, (a, s) => a + s.weight);
    final colors = <Color>[];
    final stops = <double>[];
    var acc = 0.0;
    for (final s in segments) {
      final start = acc / total;
      acc += s.weight;
      final end = acc / total;
      colors.add(s.color);
      stops.add(start);
      colors.add(s.color);
      stops.add(end);
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: colors,
          stops: stops,
        ),
      ),
      child: SizedBox(width: width, height: double.infinity),
    );
  }
}

// ── Member colour chips ─────────────────────────────────────────────

/// A member host rendered as a chip: identity-colour dot + name.
typedef WorkspaceChipMember = ({String name, Color color});

/// A wrapping row of member chips, truncating to `+n` once [maxVisible] is
/// exceeded so a long member list can't blow out the row.
///
/// Chip names are host names and are masked HERE, in the one widget that
/// paints them, so every placement surface (drawer, Hosts page) is covered
/// without each caller remembering to. The localised deleted-host placeholder
/// is the only non-identifier a caller can hand in and is left as it is.
class WorkspaceMemberChips extends ConsumerWidget {
  const WorkspaceMemberChips({
    super.key,
    required this.members,
    this.maxVisible = 3,
    this.spacing = 4,
  });

  final List<WorkspaceChipMember> members;
  final int maxVisible;
  final double spacing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Read colours from the Material theme (context-reactive) so the chips
    // repaint the instant the app theme changes, rather than staying on the
    // near-black chrome colour they used before (which never varied by theme).
    final cs = Theme.of(context).colorScheme;
    final placeholder = AppLocalizations.of(context)!.workspaceDeletedHost;
    final visible = members.take(maxVisible).toList();
    final overflow = members.length - visible.length;
    String shown(String name) =>
        name == placeholder ? name : Redactable.host(name).displayIn(ref);
    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: [
        for (final m in visible)
          _chip(cs, dotColor: m.color, label: shown(m.name)),
        if (overflow > 0)
          _chip(cs, dotColor: null, label: '+$overflow', muted: true),
      ],
    );
  }

  Widget _chip(
    ColorScheme cs, {
    required Color? dotColor,
    required String label,
    bool muted = false,
  }) {
    return Container(
      padding: EdgeInsets.only(
        left: dotColor != null ? 6 : 8,
        right: 8,
        top: 2,
        bottom: 2,
      ),
      decoration: BoxDecoration(
        color: cs.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant, width: 0.6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (dotColor != null) ...[
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
            ),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontFamily: 'JetBrainsMono',
              color: muted
                  ? cs.onSurfaceVariant.withValues(alpha: 0.5)
                  : cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

// ── Dashed empty-state container ────────────────────────────────────

/// A rounded box with a dashed border - the shared shell for the "nothing
/// saved yet" workspace empty states in the drawer and on the Hosts page.
class WorkspaceDashedBox extends StatelessWidget {
  const WorkspaceDashedBox({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(13),
    this.color,
    this.radius = 9,
  });

  final Widget child;
  final EdgeInsets padding;
  final Color? color;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedRRectPainter(
        color: color ?? AppColors.v3BorderDefault,
        radius: radius,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _DashedRRectPainter extends CustomPainter {
  _DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    const dash = 4.0;
    const gap = 3.0;
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      while (distance < metric.length) {
        canvas.drawPath(
          metric.extractPath(distance, distance + dash),
          paint,
        );
        distance += dash + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedRRectPainter old) =>
      old.color != color || old.radius != radius;
}
