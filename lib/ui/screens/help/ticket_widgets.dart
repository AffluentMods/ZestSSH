import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/l10n/time_text.dart';

/// What the ticket list and a ticket's own page both show of a ticket: its
/// kind, its number, where it stands.

/// The line over tickets that could not be read anew: what shows is what
/// was read last, and why. [stopped] is what stopped the read
/// (TicketService.readStopped, or what the screen caught). Where that was
/// ZestSSH Cloud or the way to it, which failure it was is said in a few
/// words, with its code; the sentence there always was otherwise.
String ticketsStaleText(AppLocalizations l10n, Object? stopped) {
  final failure = stopped == null ? null : cloudFailureOf(stopped);
  if (failure == null) return l10n.ticketsOffline;
  return l10n.ticketsStaleWhy(failure.label(l10n), failure.code.code);
}

IconData ticketTypeIcon(TicketType type) => switch (type) {
      TicketType.support => LucideIcons.lifeBuoy,
      TicketType.bug => LucideIcons.bug,
      TicketType.suggestion => LucideIcons.lightbulb,
    };

String ticketTypeLabel(AppLocalizations l10n, TicketType type) =>
    switch (type) {
      TicketType.support => l10n.ticketTypeSupport,
      TicketType.bug => l10n.reportTypeBug,
      TicketType.suggestion => l10n.reportTypeSuggestion,
    };

/// "#10042", or nothing while the ticket has no number yet.
String ticketNumberLabel(int? number) => number == null ? '' : '#$number';

/// When a ticket was last active, a line of its own in the shared compact
/// words (Just now, 5m ago, 3h ago, 2d ago), counting on past a week (3w ago,
/// 2mo ago) as it counted days before.
String ticketRelativeTime(AppLocalizations l10n, DateTime when,
        {DateTime? now}) =>
    timeAgoWords(l10n, when, now: now, keepCounting: true);

/// When something happened on a ticket: the time today, the date and time
/// otherwise, the way the device writes them.
String ticketStamp(BuildContext context, DateTime when) {
  final m = MaterialLocalizations.of(context);
  final time = plainTimeSpaces(m.formatTimeOfDay(TimeOfDay.fromDateTime(when),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context)));
  final now = DateTime.now();
  final today = when.year == now.year &&
      when.month == now.month &&
      when.day == now.day;
  return today ? time : '${m.formatShortDate(when)} $time';
}

/// Why the server refused [t], by its code: what a ticket that could not be
/// sent says it with.
ErrorCode ticketNotSentCode(SupportTicketRow t) => switch (t.sendError) {
      'account' => ErrorCodes.ticketNeedsAccount,
      'blocked' => ErrorCodes.ticketBlocked,
      _ => ErrorCodes.ticketRefused,
    };

/// How loud a status is.
enum TicketTone {
  /// An answer is waiting to be read.
  unread,

  /// Open and moving.
  active,

  /// Needs the person to do something (it was not sent).
  problem,

  /// Nothing more will happen (closed, gone) or nothing has yet (waiting).
  quiet,
}

/// Where a ticket stands, in one short label. The most pressing thing wins:
/// an unread answer before anything else.
({String label, TicketTone tone, IconData? icon}) ticketStanding(
    AppLocalizations l10n, SupportTicketRow t) {
  if (t.hasUnreadReply) {
    return (
      label: l10n.ticketReplyFromSupport,
      tone: TicketTone.unread,
      icon: LucideIcons.mail,
    );
  }
  if (t.isRefused) {
    return (
      label: l10n.ticketStatusNotSent,
      tone: TicketTone.problem,
      icon: LucideIcons.alertCircle,
    );
  }
  if (t.isWaiting) {
    return (
      label: l10n.ticketStatusWaiting,
      tone: TicketTone.quiet,
      icon: LucideIcons.clock,
    );
  }
  if (t.isGone) {
    return (label: l10n.ticketStatusGone, tone: TicketTone.quiet, icon: null);
  }
  if (t.isClosed) {
    return (label: l10n.ticketStatusClosed, tone: TicketTone.quiet, icon: null);
  }
  return (
    label: t.awaiting == 'user'
        ? l10n.ticketAwaitingYou
        : l10n.ticketAwaitingSupport,
    // Waiting for you asks something of the reader, in the same tone as the
    // Seats page says it (a design audit).
    tone: t.awaiting == 'user' ? TicketTone.unread : TicketTone.active,
    icon: null,
  );
}

/// A status as a chip, in the one look every chip of a ticket has (radius
/// 6, 22 high, no outline): an unread answer in the accent's wash with its
/// ink, so it reads from across the list; a ticket not sent in amber; the
/// rest neutral, as its forum tags are.
class TicketPill extends StatelessWidget {
  const TicketPill({
    super.key,
    required this.label,
    this.tone = TicketTone.quiet,
    this.icon,
  });

  final String label;
  final TicketTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final (ink, fill) = switch (tone) {
      TicketTone.unread => (ZestTokens.brandInk, ZestTokens.brand.withValues(alpha: 0.14)),
      TicketTone.problem => (ZestTokens.statusWarning, ZestTokens.statusWarning.withValues(alpha: 0.12)),
      TicketTone.active => (ZestTokens.textPrimary, ZestTokens.surfaceChip),
      TicketTone.quiet => (ZestTokens.textSecondary, ZestTokens.surfaceChip),
    };
    return TicketChip(label: label, ink: ink, fill: fill, icon: icon, strong: tone == TicketTone.unread);
  }
}

/// The forum tags of a public report ("Confirmed", "Planned", "Fixed"), as
/// neutral chips.
class TicketTags extends StatelessWidget {
  const TicketTags({super.key, required this.tags});

  final List<String> tags;

  @override
  Widget build(BuildContext context) {
    if (tags.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: [
        for (final tag in tags)
          TicketChip(label: tag, ink: ZestTokens.textSecondary, fill: ZestTokens.surfaceChip),
      ],
    );
  }
}

/// One chip of a ticket: radius 6, at least 22 high, its words and an
/// optional glyph in [ink] on [fill].
class TicketChip extends StatelessWidget {
  const TicketChip({super.key, required this.label, required this.ink, required this.fill, this.icon, this.strong = false});

  final String label;
  final Color ink;
  final Color fill;
  final IconData? icon;

  /// Its words a step heavier (an unread answer).
  final bool strong;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 22),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: fill, borderRadius: BorderRadius.circular(6)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: ink),
            const SizedBox(width: 5),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, height: 1.2, fontWeight: strong ? FontWeight.w600 : FontWeight.w500, color: ink),
            ),
          ),
        ],
      ),
    );
  }
}
