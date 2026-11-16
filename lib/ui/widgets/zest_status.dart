import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/core/widgets/status_pill.dart';
import 'package:zestssh/features/monitoring/monitor_status.dart' show HostSeverity;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// ZestSSH 1.7 unified status vocabulary.
///
/// One enum, one colour per role, three rendering channels. Screens that
/// today reach for a bespoke pill / dot / coloured cell should migrate to
/// these so "critical" looks the same everywhere. This is the FOUNDATION -
/// the legacy [StatusPill] / [HostStatus] / `MonitorStateInfo` widgets keep
/// working untouched; adoption is a later, staged sweep.
///
/// Colour is never the ONLY signal: [ZestStatusPill] always carries a leading
/// icon so `critical` and `healthy` remain distinguishable under red/green
/// colour-blindness (deuteranopia).
enum ZestStatusKind {
  /// Hard failure - unreachable, auth failed, fatal error.
  critical,

  /// Degraded / needs attention but still functioning.
  warning,

  /// All good - connected, reachable, nominal.
  healthy,

  /// In-progress - connecting, polling, work underway.
  pending,

  /// No signal / not applicable - a neutral, unconfigured baseline.
  neutral,

  /// Data is old / last result is no longer trustworthy - a dimmed,
  /// deliberately de-emphasised greyed-out treatment.
  stale,
}

/// The single kind → colour mapping. Every colour resolves to a
/// [ZestTokens] status role (no raw hex), so a palette change is one edit.
///
/// `stale` is intentionally a *dimmed* grey (a faded [ZestTokens.textTertiary])
/// so a stale row reads as "was fine, now unsure" rather than a fresh signal.
Color zestStatusColor(ZestStatusKind kind) => switch (kind) {
      ZestStatusKind.critical => ZestTokens.statusCritical,
      ZestStatusKind.warning => ZestTokens.statusWarning,
      ZestStatusKind.healthy => ZestTokens.statusHealthy,
      ZestStatusKind.pending => ZestTokens.statusPending,
      ZestStatusKind.neutral => ZestTokens.statusNeutral,
      ZestStatusKind.stale => ZestTokens.textTertiary.withValues(alpha: 0.55),
    };

/// Default leading glyph per kind, used by [ZestStatusPill] when the caller
/// does not supply an explicit [ZestStatusPill.icon]. Outlined glyphs keep the
/// pill light; each shape is distinct so it reads without colour.
IconData zestStatusIcon(ZestStatusKind kind) => switch (kind) {
      ZestStatusKind.critical => LucideIcons.alertCircle,
      ZestStatusKind.warning => LucideIcons.alertTriangle,
      ZestStatusKind.healthy => LucideIcons.checkCircle2,
      ZestStatusKind.pending => LucideIcons.refreshCw,
      ZestStatusKind.neutral => LucideIcons.minusCircle,
      ZestStatusKind.stale => LucideIcons.history,
    };

/// Map the legacy [HostStatus] onto the unified vocabulary so screens can
/// adopt [ZestStatusKind] without rewiring their state. Non-breaking: this is
/// an additive convenience - the old [StatusPill] mapping is left as-is.
///
/// Note the semantics differ slightly from [hostStatusColor] (which paints
/// `offline` red): here "no session" is [ZestStatusKind.neutral], not a fault.
ZestStatusKind zestStatusFromHostStatus(HostStatus status) => switch (status) {
      HostStatus.online => ZestStatusKind.healthy,
      HostStatus.connecting => ZestStatusKind.pending,
      HostStatus.disconnected => ZestStatusKind.warning,
      HostStatus.error => ZestStatusKind.critical,
      HostStatus.offline => ZestStatusKind.neutral,
      HostStatus.unknown => ZestStatusKind.neutral,
    };

/// Map the Server-Monitor [HostSeverity] onto the unified vocabulary so the
/// desktop table + mobile cards render "critical" the same as everywhere else
/// in 1.7.
///
/// `offline` and `critical` are both hard failures → [ZestStatusKind.critical];
/// `warning` → warning; `stale` → the dimmed [ZestStatusKind.stale]; `healthy`
/// → healthy; and `unknown` (unmonitored / no signal) → the neutral baseline.
ZestStatusKind zestStatusFromSeverity(HostSeverity severity) =>
    switch (severity) {
      HostSeverity.offline => ZestStatusKind.critical,
      HostSeverity.critical => ZestStatusKind.critical,
      HostSeverity.warning => ZestStatusKind.warning,
      HostSeverity.stale => ZestStatusKind.stale,
      HostSeverity.healthy => ZestStatusKind.healthy,
      HostSeverity.unknown => ZestStatusKind.neutral,
    };

/// A pill with a LEADING ICON + label - the primary, labelled status channel.
///
/// Hard rule: this pill **never ellipsizes or truncates**. It sizes to its
/// content ([MainAxisSize.min], no [Flexible]/[Expanded] around the label, no
/// `overflow: TextOverflow.ellipsis`). Callers are responsible for giving it
/// room; in exchange the full label is always readable. The leading icon is
/// always present so the state does not rely on hue alone.
class ZestStatusPill extends StatelessWidget {
  const ZestStatusPill({
    super.key,
    required this.kind,
    required this.label,
    this.icon,
    this.busy = false,
  });

  final ZestStatusKind kind;

  /// Already-localized label. Rendered in full, verbatim, always.
  final String label;

  /// Optional override for the leading glyph; falls back to
  /// [zestStatusIcon] for [kind]. The icon is never dropped.
  final IconData? icon;

  /// Under way: a small spinner in the kind's colour stands in the glyph's
  /// place (one sign that it is moving, not a spinner beside a pill).
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fill = zestStatusColor(kind);
    // Its words and glyph in the nearest shade of the kind's colour that
    // reads on the pill's wash (the 4.0 accessibility pass).
    final color = zestInkOnTint(fill, 0.14);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        // ~14% tinted fill of the kind colour.
        color: fill.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      // mainAxisSize.min + a bare (unwrapped) Text is what guarantees the
      // pill hugs its content and the label can never be clipped/ellipsized.
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy)
            SizedBox(
              width: 13,
              height: 13,
              child: Padding(
                padding: const EdgeInsets.all(1.5),
                child: CircularProgressIndicator(strokeWidth: 1.6, color: color),
              ),
            )
          else
            Icon(icon ?? zestStatusIcon(kind), size: 13, color: color),
          const SizedBox(width: 5),
          Text(
            label,
            softWrap: false,
            // Deliberately NO TextOverflow.ellipsis - see class doc.
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.0,
            ),
          ),
        ],
      ),
    );
  }
}

/// An 8px filled dot - the compact connection-state channel (dense cards,
/// list leading edges) where there is no room for a label.
class ZestStatusDot extends StatelessWidget {
  const ZestStatusDot({super.key, required this.kind});

  final ZestStatusKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        color: zestStatusColor(kind),
        shape: BoxShape.circle,
      ),
    );
  }
}

/// A 3px-wide left accent bar - the table-row severity channel. Sits flush on
/// the leading edge of a row and stretches to the row's height (it takes its
/// height from the parent, so place it in a stretched [Row] or an
/// [IntrinsicHeight]).
class ZestStatusBar extends StatelessWidget {
  const ZestStatusBar({super.key, required this.kind});

  final ZestStatusKind kind;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      decoration: BoxDecoration(
        color: zestStatusColor(kind),
        borderRadius: BorderRadius.circular(1.5),
      ),
    );
  }
}
