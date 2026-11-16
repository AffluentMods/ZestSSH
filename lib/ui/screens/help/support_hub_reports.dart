import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Everyone's bug reports and ideas in the Support Hub:
/// the Known issues and Ideas tabs, and the pieces the Help
/// panel and a new report's "Might already be reported" share with them.
///
/// What is shown is what the server's lists carry: a title, its text, where it
/// stands, how many said "me too", and never who sent it. The lists are read
/// when a tab shows them, and a +1 is the one call that goes with the account.

/// What a report's state says: "Under review", "Planned", "Fix in 3.3.1",
/// "Fixed in 3.2.7", "Shipped in 3.3".
String reportStateLabel(AppLocalizations l10n, ReportState? state, {String? version, bool closed = false}) {
  return switch (state) {
    null => l10n.supportHubStateUnderReview,
    ReportState.planned => l10n.supportHubStatePlanned,
    ReportState.investigating => l10n.supportHubStateInvestigating,
    ReportState.inProgress => l10n.supportHubStateInProgress,
    ReportState.fixed => version == null
        ? l10n.supportHubStateFixed
        : (closed ? l10n.supportHubStateFixedIn(version) : l10n.supportHubStateFixIn(version)),
    ReportState.shipped => version == null ? l10n.supportHubStateShipped : l10n.supportHubStateShippedIn(version),
  };
}

/// A state's colour: amber while it is looked at, the accent once it is
/// planned, green when it is in the works or done.
Color reportStateInk(ReportState? state) => switch (state) {
      null => ZestTokens.textSecondary,
      ReportState.investigating => AppColors.v3Warning,
      ReportState.planned => ZestTokens.brandInk,
      ReportState.inProgress || ReportState.fixed || ReportState.shipped => AppColors.v3Success,
    };

/// A report's state as a small pill.
class ReportStatePill extends StatelessWidget {
  const ReportStatePill({super.key, required this.state, this.version, this.closed = false});

  final ReportState? state;
  final String? version;
  final bool closed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ink = reportStateInk(state);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: state == null ? ZestTokens.surfaceChip : ink.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        reportStateLabel(l10n, state, version: version, closed: closed),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ink),
      ),
    );
  }
}

/// What a +1 that did not go through says.
String voteOutcomeText(AppLocalizations l10n, VoteOutcome outcome) => switch (outcome) {
      VoteOutcome.done => '',
      VoteOutcome.blocked => l10n.supportHubVoteBlocked,
      VoteOutcome.notListed => l10n.supportHubVoteGone,
      VoteOutcome.closed => l10n.supportHubVoteClosed,
      VoteOutcome.rateLimited => l10n.supportHubVoteLimited,
      VoteOutcome.failed => l10n.supportHubVoteFailed,
    };

/// +1 [r] or take it back, and say so where it did not go through.
Future<void> toggleVote(BuildContext context, WidgetRef ref, PublicReport r) async {
  final l10n = AppLocalizations.of(context)!;
  final result = await ref.read(reportVotesProvider.notifier).toggle(r);
  if (!context.mounted || result.outcome == VoteOutcome.done) return;
  showTopSnackBar(context, voteOutcomeText(l10n, result.outcome), isWarning: true);
}

/// The section header of the hub: a short accent bar, the label in
/// capitals, a count, a hairline, and an optional link at the end.
class HubBarHeader extends StatelessWidget {
  const HubBarHeader({super.key, required this.label, this.count, this.action, this.onAction});

  final String label;
  final int? count;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Container(width: 2, height: 12, color: ZestTokens.brand),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              label.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 10.5,
                letterSpacing: 1.4,
                color: ZestTokens.textMuted,
              ),
            ),
          ),
          if (count != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(color: ZestTokens.surfaceChip, borderRadius: BorderRadius.circular(5)),
              child: Text('$count', style: TextStyle(fontSize: 10.5, color: ZestTokens.textSecondary)),
            ),
          ],
          const SizedBox(width: 8),
          Expanded(child: Container(height: 1, color: AppColors.v3BorderSubtle)),
          if (action != null) ...[
            const SizedBox(width: 8),
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                onTap: onAction,
                child: Text(action!, style: TextStyle(fontSize: 12, color: ZestTokens.brandInk)),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The box that says how many +1 a report has and takes one: an arrow over the
/// count, in the accent once this account gave one.
class VoteBox extends ConsumerWidget {
  const VoteBox({super.key, required this.report});

  final PublicReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final votes = ref.watch(reportVotesProvider);
    final r = votes.over(report);
    final mine = votes.hasVoted(r.id);
    final ink = mine ? ZestTokens.brandInk : AppColors.v3TextPrimary;
    final open = !r.closed;
    final box = Semantics(
        button: open,
        toggled: mine,
        label: l10n.supportHubPeopleWantThis(r.votes),
        child: MouseRegion(
          cursor: open ? SystemMouseCursors.click : SystemMouseCursors.basic,
          child: GestureDetector(
            key: ValueKey('hub-vote-${r.id}'),
            behavior: HitTestBehavior.opaque,
            onTap: open || mine ? () => unawaited(toggleVote(context, ref, r)) : null,
            child: Container(
              width: 54,
              height: 60,
              decoration: BoxDecoration(
                color: mine ? ZestTokens.brand.withValues(alpha: 0.10) : ZestTokens.surfaceRaised,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: mine ? ZestTokens.brand : AppColors.v3BorderDefault),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(LucideIcons.arrowUp, size: 15, color: ink),
                  const SizedBox(height: 3),
                  Text(
                    '${r.votes}',
                    style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: ink),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    if (!open && !mine) return box;
    return Tooltip(message: mine ? l10n.supportHubVoteTakeBack : l10n.supportHubVoteFor, child: box);
  }
}

/// "+ Me too" beside a report like the one being written: a +1, and the way
/// to take it back.
class MeTooButton extends ConsumerWidget {
  const MeTooButton({super.key, required this.report});

  final PublicReport report;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final mine = ref.watch(reportVotesProvider).hasVoted(report.id);
    return OutlinedButton.icon(
      key: ValueKey('hub-metoo-${report.id}'),
      onPressed: report.closed && !mine ? null : () => unawaited(toggleVote(context, ref, report)),
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 30),
        padding: const EdgeInsets.symmetric(horizontal: 11),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        foregroundColor: mine ? ZestTokens.brandInk : AppColors.v3TextPrimary,
        side: BorderSide(color: mine ? ZestTokens.brand : AppColors.v3BorderDefault),
      ),
      icon: Icon(mine ? LucideIcons.check : LucideIcons.plus, size: 13),
      label: Text(l10n.supportHubMeToo, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
    );
  }
}

/// A list's filter: a sort or a state.
enum BoardFilter { top, newest, investigating, planned, inProgress, fixed, shipped }

extension on BoardFilter {
  ReportQuery query(TicketType type) => switch (this) {
        BoardFilter.top => ReportQuery(type),
        BoardFilter.newest => ReportQuery(type, newest: true),
        BoardFilter.investigating => ReportQuery(type, state: ReportState.investigating),
        BoardFilter.planned => ReportQuery(type, state: ReportState.planned),
        BoardFilter.inProgress => ReportQuery(type, state: ReportState.inProgress),
        BoardFilter.fixed => ReportQuery(type, state: ReportState.fixed),
        BoardFilter.shipped => ReportQuery(type, state: ReportState.shipped),
      };

  String label(AppLocalizations l10n) => switch (this) {
        BoardFilter.top => l10n.supportHubFilterTop,
        BoardFilter.newest => l10n.supportHubFilterNew,
        BoardFilter.investigating => l10n.supportHubStateInvestigating,
        BoardFilter.planned => l10n.supportHubStatePlanned,
        BoardFilter.inProgress => l10n.supportHubStateInProgress,
        BoardFilter.fixed => l10n.supportHubStateFixed,
        BoardFilter.shipped => l10n.supportHubStateShipped,
      };
}

/// The Known issues tab ([type] bug) or the Ideas tab ([type] suggestion): the
/// filters, the reports as cards with their +1, and beside them the way to add
/// one, what shipped or was fixed lately, and how they are picked.
class HubBoard extends ConsumerStatefulWidget {
  const HubBoard({super.key, required this.type, required this.query, required this.onCompose});

  final TicketType type;

  /// The hub's search: only the reports whose title or text holds it.
  final String query;

  /// "Suggest an idea" / "Report a bug".
  final VoidCallback onCompose;

  @override
  ConsumerState<HubBoard> createState() => _HubBoardState();
}

class _HubBoardState extends ConsumerState<HubBoard> {
  BoardFilter _filter = BoardFilter.top;

  bool get _ideas => widget.type == TicketType.suggestion;

  List<BoardFilter> get _filters => _ideas
      ? const [BoardFilter.top, BoardFilter.newest, BoardFilter.planned, BoardFilter.inProgress, BoardFilter.shipped]
      : const [BoardFilter.top, BoardFilter.newest, BoardFilter.investigating, BoardFilter.inProgress, BoardFilter.fixed];

  @override
  void initState() {
    super.initState();
    // Which of them this account +1'd: read when a list shows, never before.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(ref.read(reportVotesProvider.notifier).load());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, box) {
        final side = box.maxWidth >= 860;
        final list = _list(l10n, compact: box.maxWidth < 560);
        if (!side) {
          return ListView(
            key: ValueKey('hub-board-${widget.type.wire}'),
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            children: [
              _ComposeCta(ideas: _ideas, onTap: widget.onCompose),
              const SizedBox(height: 14),
              ...list,
              const SizedBox(height: 20),
              ..._side(l10n),
            ],
          );
        }
        return Row(
          key: ValueKey('hub-board-${widget.type.wire}'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(padding: const EdgeInsets.fromLTRB(24, 18, 24, 24), children: list),
            ),
            VerticalDivider(width: 1, thickness: 1, color: AppColors.v3BorderSubtle),
            SizedBox(
              width: 320,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
                children: [
                  _ComposeCta(ideas: _ideas, onTap: widget.onCompose),
                  const SizedBox(height: 22),
                  ..._side(l10n),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  List<Widget> _list(AppLocalizations l10n, {required bool compact}) {
    final q = _filter.query(widget.type);
    final async = ref.watch(publicReportsProvider(q));
    final filters = Row(
      children: [
        Expanded(
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final f in _filters)
                _FilterPill(
                  key: ValueKey('hub-board-filter-${f.name}'),
                  label: f.label(l10n),
                  selected: f == _filter,
                  onTap: () => setState(() => _filter = f),
                ),
            ],
          ),
        ),
        if (!compact)
          Text(
            _filter == BoardFilter.newest ? l10n.supportHubSortedByNewest : l10n.supportHubSortedByVotes,
            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextTertiary),
          ),
      ],
    );
    final words = widget.query.trim().toLowerCase();
    final Widget content = async.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(32),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
      ),
      error: (e, _) => _Unavailable(onRetry: () => ref.invalidate(publicReportsProvider(q))),
      data: (all) {
        final shown = [
          for (final r in all)
            if (words.isEmpty || r.title.toLowerCase().contains(words) || r.body.toLowerCase().contains(words)) r,
        ];
        if (shown.isEmpty) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Text(
              all.isEmpty
                  ? (_ideas ? l10n.supportHubBoardEmptyIdeas : l10n.supportHubBoardEmptyBugs)
                  : l10n.supportHubNoMatches,
              key: const ValueKey('hub-board-empty'),
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary),
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final r in shown) ...[
              ReportCard(key: ValueKey('hub-report-${r.id}'), report: r),
              const SizedBox(height: 12),
            ],
          ],
        );
      },
    );
    return [filters, const SizedBox(height: 14), content];
  }

  List<Widget> _side(AppLocalizations l10n) {
    final recent = ref.watch(publicReportsProvider(
        ReportQuery(widget.type, state: _ideas ? ReportState.shipped : ReportState.fixed)));
    final done = [
      for (final r in recent.valueOrNull ?? const <PublicReport>[])
        if (r.closed) r,
    ].take(5).toList();
    return [
      HubBarHeader(label: _ideas ? l10n.supportHubRecentlyShipped : l10n.supportHubRecentlyFixed),
      if (done.isEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Text(
            recent.isLoading ? '' : l10n.supportHubNothingYet,
            style: TextStyle(fontSize: 12.5, color: AppColors.v3TextTertiary),
          ),
        ),
      for (var i = 0; i < done.length; i++)
        _ShippedRow(report: done[i], last: i == done.length - 1),
      const SizedBox(height: 18),
      Container(
        key: const ValueKey('hub-board-how'),
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaised,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _ideas ? l10n.supportHubHowPickedTitle : l10n.supportHubHowFixedTitle,
              style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              _ideas ? l10n.supportHubHowPickedBody : l10n.supportHubHowFixedBody,
              style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 8),
            Text(l10n.supportHubHowPickedBy, style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
          ],
        ),
      ),
    ];
  }
}

/// "Suggest an idea" / "Report a bug": the big accent button over the side.
class _ComposeCta extends StatelessWidget {
  const _ComposeCta({required this.ideas, required this.onTap});

  final bool ideas;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ButtonBox(
      height: 40,
      child: FilledButton.icon(
        key: const ValueKey('hub-board-compose'),
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: ZestTokens.brand,
          foregroundColor: ZestTokens.onBrand,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        icon: Icon(ideas ? LucideIcons.lightbulb : LucideIcons.bug, size: 16),
        label: Text(
          ideas ? l10n.supportHubSuggestIdea : l10n.helpReportBug,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _ShippedRow extends StatelessWidget {
  const _ShippedRow({required this.report, required this.last});

  final PublicReport report;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 9),
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.checkCircle, size: 15, color: AppColors.v3Success),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              report.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: AppColors.v3TextPrimary),
            ),
          ),
          if (report.stateVersion != null) ...[
            const SizedBox(width: 8),
            Text(
              report.stateVersion!,
              textDirection: TextDirection.ltr,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextTertiary),
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterPill extends StatelessWidget {
  const _FilterPill({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? ZestTokens.brand.withValues(alpha: 0.10) : ZestTokens.surfaceRaised,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: selected ? ZestTokens.brand : AppColors.v3BorderDefault),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                color: AppColors.v3TextPrimary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A report on a board: its +1, its title and state, its text, and how much
/// was said on it and when it was opened. Its forum post opens on a tap,
/// where it has one.
class ReportCard extends ConsumerStatefulWidget {
  const ReportCard({super.key, required this.report});

  final PublicReport report;

  @override
  ConsumerState<ReportCard> createState() => _ReportCardState();
}

class _ReportCardState extends ConsumerState<ReportCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final r = widget.report;
    final link = r.discordUrl;
    final meta = TextStyle(fontSize: 12, color: AppColors.v3TextTertiary);
    return MouseRegion(
      cursor: link == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: link == null ? null : () => launchUrl(Uri.parse(link), mode: LaunchMode.externalApplication),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          decoration: BoxDecoration(
            color: _hover ? AppColors.v3Hover : AppColors.v3Surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              VoteBox(report: r),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 10,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        // Other people's words, shown inside everyone's app:
                        // masked like free text while the screen is recorded.
                        Text(
                          Redactable.freeText(r.title).displayIn(ref),
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                        ),
                        ReportStatePill(state: r.state, version: r.stateVersion, closed: r.closed),
                      ],
                    ),
                    if (r.body.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        Redactable.freeText(r.body).displayIn(ref),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13.5, height: 1.45, color: AppColors.v3TextSecondary),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(LucideIcons.messageSquare, size: 13, color: AppColors.v3TextTertiary),
                        const SizedBox(width: 6),
                        Flexible(
                          child: Text(
                            '${l10n.supportHubComments(r.comments)}  ·  ${ticketRelativeTime(l10n, r.createdAt.toLocal())}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: meta,
                          ),
                        ),
                        if (link != null) ...[
                          const SizedBox(width: 8),
                          Icon(LucideIcons.externalLink, size: 12, color: AppColors.v3TextTertiary),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Unavailable extends StatelessWidget {
  const _Unavailable({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28),
      child: Column(
        children: [
          Icon(LucideIcons.wifiOff, size: 22, color: AppColors.v3TextTertiary),
          const SizedBox(height: 8),
          Text(
            l10n.supportHubBoardUnavailable,
            key: const ValueKey('hub-board-unavailable'),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary),
          ),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: onRetry, child: Text(l10n.retry, style: const TextStyle(fontSize: 12.5))),
        ],
      ),
    );
  }
}

/// Opens the hub on [tab]: for the Help panel's Known issues and Ideas board.
void openHubOn(WidgetRef ref, HubTab tab) {
  ref.read(supportHubTabProvider.notifier).state = tab;
  ref.read(supportHubComposeProvider.notifier).state = null;
  ref.read(supportHubOpenProvider.notifier).state = true;
}
