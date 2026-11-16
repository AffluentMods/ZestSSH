// Remote screens (4.0): a session's details, live. What comes in
// and goes out each second over the last minute as two small graphs, the
// frames drawn a second, the round trip once it is measured, the whole remote
// desktop's size, the protocol and what draws the picture. On a computer a
// small card over the picture's top end corner that never takes the keyboard
// (the picture keeps it); on a phone the app's sheet. Both draw whatever the
// session hands them ([ScreenSessionDetails], sampled only while they show)
// and read nothing themselves; closing either is the switch going off, so
// the sampling stops.
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart' show ZestDialogShell, ZestDialogTone;
import 'package:zestssh/ui/widgets/zest_modal.dart' show ZestModalSize, showZestModal, zestDialogPop;
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/number_text.dart';

import 'package:zestssh/features/screens/model/screen_session_details.dart';

export 'package:zestssh/features/screens/model/screen_session_details.dart';

/// The card's width on a computer.
const kScreenDetailsCardWidth = 280.0;

/// A computer's card, over the picture. [onClose] turns the details off.
class ScreenSessionDetailsCard extends StatelessWidget {
  const ScreenSessionDetailsCard({super.key, required this.details, required this.onClose});

  final ValueListenable<ScreenSessionDetails> details;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Clicked, the card keeps the keyboard where it was: on the picture.
    return ExcludeFocus(
      child: Material(
        key: const ValueKey('screen-details-card'),
        color: ZestColors.chromeElevated,
        elevation: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestColors.borderDefault),
        ),
        // Wider with larger text (up to 440), and scrolled where it is taller
        // than most of the picture.
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.7,
          ),
          child: SizedBox(
          width: math.min(MediaQuery.textScalerOf(context).scale(kScreenDetailsCardWidth), 440),
          child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(14, 6, 4, 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          l10n.screenDetailsTitle,
                          style: TextStyle(color: ZestColors.textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('screen-details-close'),
                      tooltip: l10n.close,
                      onPressed: onClose,
                      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
                      padding: EdgeInsets.zero,
                      icon: Icon(LucideIcons.x, size: 15, color: ZestColors.textSecondary),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 10),
                  child: ScreenSessionDetailsBody(details: details),
                ),
              ],
            ),
          ),
          ),
          ),
        ),
      ),
    );
  }
}

/// A phone's sheet. [onClosed] runs once it is gone, however it was closed,
/// to turn the details off.
Future<void> showScreenSessionDetailsSheet(
  BuildContext context, {
  required ValueListenable<ScreenSessionDetails> details,
  required VoidCallback onClosed,
}) async {
  final l10n = AppLocalizations.of(context)!;
  await showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (dialogContext) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.activity,
        title: l10n.screenDetailsTitle,
        body: ScreenSessionDetailsBody(key: const ValueKey('screen-details-sheet'), details: details),
        primaryAction: (label: l10n.close, onPressed: () => zestDialogPop(dialogContext), icon: null),
      ),
    ),
  );
  onClosed();
}

/// What the card and the sheet both show.
class ScreenSessionDetailsBody extends StatelessWidget {
  const ScreenSessionDetailsBody({super.key, required this.details});

  final ValueListenable<ScreenSessionDetails> details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<ScreenSessionDetails>(
      valueListenable: details,
      builder: (context, d, _) {
        final last = d.last.isEmpty ? null : d.last.last;
        Widget graph(String id, String label, int Function(ScreenSessionSample) of, Color color) => _RateGraph(
              key: ValueKey('screen-details-$id'),
              label: label,
              value: last == null ? null : formatByteRate(of(last), l10n: l10n),
              points: [for (final s in d.last) of(s)],
              color: color,
            );
        final facts = <(String, String, String)>[
          if (last != null) ('frames', l10n.screenDetailsFrames, formatDecimal(last.frames, digits: 0, l10n: l10n)),
          if (d.roundTripMs case final ms?) ('roundTrip', l10n.screenDetailsRoundTrip, l10n.screenDetailsMilliseconds(ms)),
          if (d.width > 0 && d.height > 0) ('size', l10n.screenDetailsSize, l10n.screenDisplaySize(d.width, d.height)),
          if (d.protocol.isNotEmpty) ('protocol', l10n.screenDetailsProtocol, d.protocol),
          if (d.drawnWith.isNotEmpty) ('drawnWith', l10n.screenDetailsDrawnWith, d.drawnWith),
        ];
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (last == null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  l10n.screenDetailsCounting,
                  key: const ValueKey('screen-details-counting'),
                  style: TextStyle(color: ZestColors.textMuted, fontSize: 12),
                ),
              ),
            graph('in', l10n.screenDetailsReceived, (s) => s.bytesIn, AppColors.brandOrange),
            const SizedBox(height: 10),
            graph('out', l10n.screenDetailsSent, (s) => s.bytesOut, ZestColors.textSecondary),
            if (facts.isNotEmpty) const SizedBox(height: 10),
            for (final (id, name, value) in facts)
              Padding(
                key: ValueKey('screen-details-$id'),
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: MergeSemantics(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: Text(name, style: TextStyle(color: ZestColors.textMuted, fontSize: 12)),
                      ),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          value,
                          textAlign: TextAlign.end,
                          style: TextStyle(
                            color: ZestColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// One rate over the last minute: its name and latest value, and the graph.
class _RateGraph extends StatelessWidget {
  const _RateGraph({super.key, required this.label, required this.value, required this.points, required this.color});

  final String label;
  final String? value;
  final List<int> points;
  final Color color;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MergeSemantics(
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(color: color, shape: BoxShape.circle),
                ),
                const SizedBox(width: 6),
                Expanded(child: Text(label, style: TextStyle(color: ZestColors.textMuted, fontSize: 12))),
                if (value != null)
                  Flexible(
                    child: Text(
                    value!,
                    textAlign: TextAlign.end,
                    style: TextStyle(
                      color: ZestColors.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          // The numbers are read out above; the drawing says nothing more.
          ExcludeSemantics(
            child: SizedBox(
              height: 36,
              child: CustomPaint(painter: _SparkPainter(points, color, ZestColors.borderDefault)),
            ),
          ),
        ],
      );
}

/// A minute of a rate: the area under it, its line, the last point marked, a
/// faint base line. Its own scale, from nothing to the most in the minute; a
/// minute of nothing is a flat line on the base.
class _SparkPainter extends CustomPainter {
  _SparkPainter(this.points, this.color, this.grid);

  final List<int> points;
  final Color color;
  final Color grid;

  /// A minute, one point a second: the graph always spans it, so a new
  /// session's line grows from the start end.
  static const span = 60;

  @override
  void paint(Canvas canvas, Size size) {
    final base = size.height - 1;
    canvas.drawLine(Offset(0, base), Offset(size.width, base), Paint()..color = grid);
    if (points.isEmpty) return;
    final top = points.fold<int>(0, math.max);
    final step = size.width / (span - 1);
    final start = (span - points.length).clamp(0, span) * step;
    Offset at(int i) =>
        Offset(start + i * step, top == 0 ? base : base - (points[i] / top) * (size.height - 4));
    final line = Path()..moveTo(at(0).dx, at(0).dy);
    for (var i = 1; i < points.length; i++) {
      line.lineTo(at(i).dx, at(i).dy);
    }
    final area = Path.from(line)
      ..lineTo(at(points.length - 1).dx, base)
      ..lineTo(start, base)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.16));
    canvas.drawPath(
      line,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(at(points.length - 1), 2.5, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.points != points || old.color != color || old.grid != grid;
}
