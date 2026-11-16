import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// My tickets (tickets handoff, section 3): everything this device has sent
/// to support, newest activity first, each with where it stands. An answer
/// from support that has not been read is the loudest thing on the page.
///
/// Reports still waiting to be sent sit on top, so nothing typed seems to
/// have vanished. Opening the page asks the server how the tickets stand; a
/// device with no ticket asks nothing.
///
/// On desktop it is a level inside the Help pane ([embedded]); on a phone a
/// full-screen route.
class TicketsScreen extends ConsumerStatefulWidget {
  const TicketsScreen({
    super.key,
    this.embedded = false,
    required this.onOpen,
    required this.onContactSupport,
  });

  final bool embedded;

  /// A ticket was tapped (its nonce).
  final ValueChanged<String> onOpen;
  final VoidCallback onContactSupport;

  @override
  ConsumerState<TicketsScreen> createState() => _TicketsScreenState();
}

class _TicketsScreenState extends ConsumerState<TicketsScreen> {
  bool _checking = false;

  /// The last try did not reach the server: what shows is what was read
  /// last.
  bool _stale = false;

  /// What stopped that try, for saying why.
  Object? _stopped;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _check());
  }

  Future<void> _check() async {
    if (_checking || !mounted) return;
    setState(() => _checking = true);
    final (reached, stopped) = await checkTickets(ref);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _stale = !reached;
      _stopped = stopped;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tickets = ref.watch(ticketsProvider).valueOrNull ?? const [];
    final queued = ref.watch(queuedReportsProvider).valueOrNull ?? const [];
    final empty = tickets.isEmpty && queued.isEmpty;

    final list = empty
        ? _Empty(onContactSupport: widget.onContactSupport)
        : ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 4, bottom: 12),
            children: [
              if (_stale)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      Icon(LucideIcons.wifiOff,
                          size: 14, color: AppColors.v3TextTertiary),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(ticketsStaleText(l10n, _stopped),
                            style: TextStyle(
                                fontSize: 12,
                                color: AppColors.v3TextSecondary)),
                      ),
                    ],
                  ),
                ),
              for (final report in queued) _QueuedReportTile(report: report),
              for (final t in tickets)
                _TicketTile(ticket: t, onTap: () => widget.onOpen(t.nonce)),
            ],
          );

    final write = FilledButton.icon(
      onPressed: widget.onContactSupport,
      icon: const Icon(LucideIcons.edit, size: 14),
      label: Text(l10n.supportWrite),
    );
    final refreshIcon = _checking
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2))
        : const Icon(LucideIcons.refreshCw, size: 16);

    if (widget.embedded) {
      return Column(
        children: [
          Expanded(child: list),
          Container(
            padding: const EdgeInsets.fromLTRB(8, 8, 16, 10),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: AppColors.v3BorderSubtle)),
            ),
            child: Row(
              children: [
                IconButton(
                  tooltip: l10n.refresh,
                  onPressed: _checking ? null : _check,
                  color: AppColors.v3TextSecondary,
                  icon: refreshIcon,
                ),
                Expanded(
                  // Shrinks to the room the row leaves it, its label wrapping
                  // (it ran out of the row at a large text size).
                  child: Align(alignment: AlignmentDirectional.centerEnd, child: write),
                ),
              ],
            ),
          ),
        ],
      );
    }
    // A phone: refreshed from the app bar or by pulling the list down; the
    // one way to write across the bottom, in reach of a thumb.
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.ticketsTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            key: const ValueKey('tickets-refresh'),
            tooltip: l10n.refresh,
            onPressed: _checking ? null : _check,
            icon: refreshIcon,
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                Expanded(
                  child: RefreshIndicator(
                    onRefresh: _check,
                    // The empty page is pulled down too.
                    child: empty
                        ? LayoutBuilder(
                            builder: (context, box) => SingleChildScrollView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              child: SizedBox(height: box.maxHeight, child: list),
                            ),
                          )
                        : list,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: SizedBox(width: double.infinity, child: write),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Sends what waits, then asks the server how the tickets here stand. Whether
/// that got through, and what stopped it where it did not.
Future<(bool, Object?)> checkTickets(WidgetRef ref) async {
  try {
    final service = ref.read(ticketServiceProvider);
    // What was written offline goes first, so it shows as sent.
    await ref.read(feedbackServiceProvider).retryQueued();
    if (await service.hasWaiting()) await service.retryPending();
    final reached = (await service.refresh()).reached;
    return (reached, reached ? null : service.readStopped);
  } catch (e) {
    return (false, e);
  }
}

class _Empty extends StatelessWidget {
  const _Empty({required this.onContactSupport});

  final VoidCallback onContactSupport;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.inbox, size: 30, color: AppColors.v3TextTertiary),
            const SizedBox(height: 12),
            Text(l10n.ticketsEmptyTitle,
                style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3TextPrimary)),
            const SizedBox(height: 6),
            Text(
              l10n.ticketsEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 12.5,
                  height: 1.4,
                  color: AppColors.v3TextSecondary),
            ),
          ],
        ),
      ),
    );
  }
}

/// One ticket: its kind, its subject, its number and when something last
/// happened, and where it stands.
class _TicketTile extends ConsumerStatefulWidget {
  const _TicketTile({required this.ticket, required this.onTap});

  final SupportTicketRow ticket;
  final VoidCallback onTap;

  @override
  ConsumerState<_TicketTile> createState() => _TicketTileState();
}

class _TicketTileState extends ConsumerState<_TicketTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final t = widget.ticket;
    final standing = ticketStanding(l10n, t);
    final meta = [
      ticketTypeLabel(l10n, t.ticketType),
      if (t.number != null) ticketNumberLabel(t.number),
      ticketRelativeTime(l10n, t.lastActivity.toLocal()),
    ].join(' · ');
    // A subject is what the person typed: it can name a host, so recording
    // mode hides it like any other free text of theirs.
    final title = Redactable.freeText(t.title).displayIn(ref);
    return Semantics(
      button: true,
      label: '$title, ${standing.label}',
      child: MouseRegion(
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            color: _hover ? AppColors.v3Hover : Colors.transparent,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(ticketTypeIcon(t.ticketType),
                      size: 16,
                      color: t.hasUnreadReply
                          ? AppColors.accentInk
                          : AppColors.v3TextTertiary),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: t.hasUnreadReply
                              ? FontWeight.w600
                              : FontWeight.w500,
                          color: AppColors.v3TextPrimary,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.v3TextTertiary)),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          TicketPill(
                              label: standing.label,
                              tone: standing.tone,
                              icon: standing.icon),
                          if (t.tagNames.isNotEmpty)
                            TicketTags(tags: t.tagNames),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(LucideIcons.chevronRight,
                      size: 14, color: AppColors.v3TextTertiary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A bug report or suggestion that has not reached the server yet. It is
/// sent the next time the server can be reached, and becomes a ticket then.
class _QueuedReportTile extends ConsumerWidget {
  const _QueuedReportTile({required this.report});

  final FeedbackReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final type = report.type == FeedbackType.bug
        ? TicketType.bug
        : TicketType.suggestion;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(ticketTypeIcon(type),
                size: 16, color: AppColors.v3TextTertiary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  Redactable.freeText(report.threadTitle).displayIn(ref),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.v3TextPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    ticketTypeLabel(l10n, type),
                    ticketRelativeTime(l10n, report.createdAt),
                  ].join(' · '),
                  style: TextStyle(
                      fontSize: 11.5, color: AppColors.v3TextTertiary),
                ),
                const SizedBox(height: 6),
                TicketPill(
                    label: l10n.ticketStatusWaiting,
                    icon: LucideIcons.clock),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
