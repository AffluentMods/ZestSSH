import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/public_reports.dart';
import 'package:zestssh/features/tickets/support_diagnostics.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/help/help_form_parts.dart';
import 'package:zestssh/ui/screens/help/support_hub_parts.dart';
import 'package:zestssh/ui/screens/help/support_hub_reports.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/help/ask_astryx_screen.dart';
import 'package:zestssh/ui/screens/help/contact_support_screen.dart';
import 'package:zestssh/ui/screens/help/guide_reader_screen.dart';
import 'package:zestssh/ui/screens/help/guides_screen.dart';
import 'package:zestssh/ui/screens/help/report_issue_screen.dart';
import 'package:zestssh/ui/screens/help/ticket_detail_screen.dart';
import 'package:zestssh/ui/screens/help/tickets_screen.dart';
import 'package:zestssh/ui/widgets/dock_panel.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// The desktop Help panel (help/feedback/support spec, section 2; structure
/// per the fixes spec, section 9): the same right-docked pane component as
/// the docked editors, one level at a time.
///
/// Four groups, each with a header: the questions people actually ask, ways
/// to get in touch, the two things to do before sharing a screenshot, and
/// the rest. Report / Suggest push the form as a second level with a back
/// chevron; Get help pushes the ways to reach support (write here, Discord,
/// email); My tickets pushes the list of what was sent, and a ticket's own
/// conversation from there. A sticky footer shows the version and whether
/// ZestSSH Cloud is up, the two facts that settle most support threads
/// before they start.
class HelpDock extends ConsumerWidget {
  const HelpDock({
    super.key,
    required this.captureScreenshot,
    required this.onCopyRedactedScreenshot,
    required this.onOpenShortcuts,
    required this.onAbout,
  });

  final ScreenshotCapture captureScreenshot;
  final VoidCallback onCopyRedactedScreenshot;
  final VoidCallback onOpenShortcuts;
  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final page = ref.watch(helpDockProvider) ?? HelpPage.home;
    // A tooltip shown on the level being left would otherwise outlive it and
    // sit over the first field of the next one.
    ref.listen<HelpPage?>(helpDockProvider, (prev, next) {
      if (prev != next) Tooltip.dismissAllToolTips();
    });
    void close() => ref.read(helpDockProvider.notifier).state = null;
    void go(HelpPage p) => ref.read(helpDockProvider.notifier).state = p;
    void openTicket(String nonce) {
      ref.read(helpDockTicketProvider.notifier).state = nonce;
      go(HelpPage.ticket);
    }

    void openGuide(String slug) {
      ref.read(helpDockGuideProvider.notifier).state = slug;
      go(HelpPage.guide);
    }

    // The support form is reached from Get help and from My tickets: Back
    // returns to whichever it was.
    void writeToSupport(HelpPage from) {
      ref.read(helpDockSupportOriginProvider.notifier).state = from;
      go(HelpPage.contactSupport);
    }

    switch (page) {
      case HelpPage.home:
        return DockPanel(
          title: l10n.helpTitle,
          onClose: close,
          headerAction: _WhatsNewLink(),
          footer: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              _FooterLinks(onOpenShortcuts: onOpenShortcuts),
              _HelpFooter(onAbout: onAbout),
            ],
          ),
          child: _HelpHome(
            onGuides: () => go(HelpPage.guides),
            onCopyRedactedScreenshot: onCopyRedactedScreenshot,
          ),
        );
      case HelpPage.reportBug:
      case HelpPage.suggest:
        final type = page == HelpPage.reportBug
            ? FeedbackType.bug
            : FeedbackType.suggestion;
        return DockPanel(
          title: type == FeedbackType.bug ? l10n.helpReportBug : l10n.helpSuggest,
          onBack: () => go(HelpPage.home),
          onClose: close,
          child: ReportIssueScreen(
            // A fresh form per level so a half-typed bug never leaks into a
            // suggestion and vice versa.
            key: ValueKey(page),
            initialType: type,
            captureScreenshot: captureScreenshot,
            embedded: true,
            onDone: close,
          ),
        );
      case HelpPage.support:
        return DockPanel(
          title: l10n.helpSupport,
          onBack: () => go(HelpPage.home),
          onClose: close,
          child: _SupportPage(
              onWrite: () => writeToSupport(HelpPage.support)),
        );
      case HelpPage.askAstryx:
        return DockPanel(
          title: l10n.astryxTitle,
          onBack: () => go(HelpPage.home),
          onClose: close,
          headerAction: const AstryxPreviewBadge(),
          child: AskAstryxScreen(
            embedded: true,
            captureScreenshot: captureScreenshot,
            // The filled-in support form, inside the panel; Back returns here.
            onOpenTicket: () => writeToSupport(HelpPage.askAstryx),
            onSearchGuides: () => go(HelpPage.guides),
            onContactSupport: () => writeToSupport(HelpPage.askAstryx),
            onOpenGuide: openGuide,
          ),
        );
      case HelpPage.contactSupport:
        return DockPanel(
          title: l10n.supportWrite,
          onBack: () => go(ref.read(helpDockSupportOriginProvider)),
          onClose: close,
          child: ContactSupportScreen(embedded: true, onDone: openTicket),
        );
      case HelpPage.tickets:
        return DockPanel(
          title: l10n.ticketsTitle,
          onBack: () => go(HelpPage.home),
          onClose: close,
          child: TicketsScreen(
            embedded: true,
            onOpen: openTicket,
            onContactSupport: () => writeToSupport(HelpPage.tickets),
          ),
        );
      case HelpPage.guides:
        return DockPanel(
          title: l10n.helpGuides,
          onBack: () => go(HelpPage.home),
          onClose: close,
          child: GuidesScreen(embedded: true, autofocus: true, onOpen: openGuide),
        );
      case HelpPage.guide:
        final slug = ref.watch(helpDockGuideProvider);
        if (slug == null) {
          // Nothing chosen (the level was set without a guide): the list.
          return DockPanel(
            title: l10n.helpGuides,
            onBack: () => go(HelpPage.home),
            onClose: close,
            child: GuidesScreen(embedded: true, onOpen: openGuide),
          );
        }
        return DockPanel(
          title: l10n.helpGuides,
          onBack: () => go(HelpPage.guides),
          onClose: close,
          child: GuideReaderScreen(
            // A fresh page per guide: one guide's state never shows in another.
            key: ValueKey('guide-$slug'),
            slug: slug,
            embedded: true,
            onOpenGuide: openGuide,
          ),
        );
      case HelpPage.ticket:
        final nonce = ref.watch(helpDockTicketProvider);
        if (nonce == null) {
          // Nothing chosen (the level was set without a ticket): the list.
          return DockPanel(
            title: l10n.ticketsTitle,
            onBack: () => go(HelpPage.home),
            onClose: close,
            child: TicketsScreen(
              embedded: true,
              onOpen: openTicket,
              onContactSupport: () => writeToSupport(HelpPage.tickets),
            ),
          );
        }
        final ticket = ref.watch(ticketProvider(nonce)).valueOrNull;
        return DockPanel(
          title: ticket == null
              ? l10n.ticketsTitle
              : ticketDetailTitle(l10n, ticket),
          onBack: () => go(HelpPage.tickets),
          onClose: close,
          headerAction: TicketMenuButton(
              nonce: nonce, onRemoved: () => go(HelpPage.tickets)),
          child: TicketDetailScreen(
            // A fresh page per ticket: a half-typed reply never leaks into
            // another conversation.
            key: ValueKey(nonce),
            nonce: nonce,
            embedded: true,
            onLeave: () => go(HelpPage.tickets),
            onNewTicket: () => writeToSupport(HelpPage.tickets),
          ),
        );
    }
  }
}

/// The "What's new" link in the Help panel header, between the title and the
/// X, in the header's quiet grey (it was the accent's, a second loud thing
/// beside the title). Opens the in-app changelog dialog.
class _WhatsNewLink extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextButton.icon(
      onPressed: () => showWhatsNewDialog(context),
      icon: const Icon(LucideIcons.sparkles, size: 14),
      label: Text(l10n.helpWhatsNew),
      style: TextButton.styleFrom(
        foregroundColor: AppColors.v3TextSecondary,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w500),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _HelpHome extends ConsumerWidget {
  const _HelpHome({
    required this.onGuides,
    required this.onCopyRedactedScreenshot,
  });

  final VoidCallback onGuides;
  final VoidCallback onCopyRedactedScreenshot;

  /// The Support Hub on [tab]; with [compose] a new ticket in it, with
  /// [ticket] that conversation. The panel closes: the hub is the whole page.
  void _toHub(WidgetRef ref, HubTab tab, {TicketType? compose, String? ticket}) {
    ref.read(helpDockProvider.notifier).state = null;
    ref.read(supportHubTabProvider.notifier).state = tab;
    ref.read(supportHubComposeProvider.notifier).state = compose;
    if (ticket != null) ref.read(supportHubTicketProvider.notifier).state = ticket;
    ref.read(supportHubOpenProvider.notifier).state = true;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final recording = ref.watch(recordingModeProvider);
    final tickets = ref.watch(ticketsProvider).valueOrNull ?? const <SupportTicketRow>[];
    final needsReply = tickets.where(hubWaitsForYou).length;
    SupportTicketRow? replied;
    for (final t in tickets) {
      if (t.hasUnreadReply) {
        replied = t;
        break;
      }
    }
    // Everyone's known issues: read when the panel shows, never before, and
    // not at all in a build with no service to ask.
    final known =
        zestHasCloud ? ref.watch(publicReportsProvider(const ReportQuery(TicketType.bug))).valueOrNull : null;
    final open = [
      for (final r in known ?? const <PublicReport>[])
        if (!r.closed || r.state == ReportState.fixed) r,
    ];
    return ListView(
      padding: const EdgeInsets.only(top: 6, bottom: 12),
      children: [
        // The search over the guides, as the field it opens. (The guides are
        // fetched from the docs site: a build with none shows no search.)
        if (kZestDocsOrigin != '')
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: _SearchRow(onTap: onGuides),
          ),
        if (replied != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 2, 16, 6),
            child: _RepliedBanner(
              ticket: replied,
              onOpen: () => _toHub(ref, HubTab.myTickets, ticket: replied!.nonce),
            ),
          ),
        // Ask Astryx (4.0, a named preview): its own group at the top. Every
        // account sees it; the level says who it is for.
        if (zestHasCloud) ...[
          _SectionLabel(l10n.astryxTitle),
          _HelpRow(
            key: const ValueKey('help-ask-astryx'),
            icon: LucideIcons.sparkles,
            iconColor: ZestTokens.brand,
            title: l10n.astryxTitle,
            subtitle: l10n.astryxRowSub,
            trailingWidget: const AstryxPreviewBadge(),
            chevron: true,
            onTap: () => ref.read(helpDockProvider.notifier).state = HelpPage.askAstryx,
          ),
        ],
        if (kZestDocsOrigin != '') ...[
          _SectionLabel(l10n.helpGroupCommonQuestions),
          _HelpRow(
            icon: LucideIcons.shieldCheck,
            title: l10n.helpFaqHostKeyChanged,
            onTap: () => _open(kZestDocsConnectionIssues),
          ),
          _HelpRow(
            icon: LucideIcons.key,
            title: l10n.helpFaqKeyRejected,
            onTap: () => _open(kZestDocsConnectionIssues),
          ),
          _HelpRow(
            icon: LucideIcons.fileText,
            title: l10n.helpFaqImport,
            onTap: () => _open(kZestDocsImporting),
          ),
          _HelpRow(
            icon: LucideIcons.fileText,
            title: l10n.helpFaqSyncHosts,
            onTap: () => _open(kZestDocsSyncNotWorking),
          ),
        ],
        if (open.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: HubBarHeader(
              label: l10n.supportHubTabKnownIssues,
              count: open.length,
              action: l10n.helpSeeAll,
              onAction: () => _toHub(ref, HubTab.knownIssues),
            ),
          ),
          for (final r in open.take(2))
            _HelpRow(
              key: ValueKey('help-known-${r.id}'),
              icon: LucideIcons.bug,
              title: r.title,
              trailingWidget: ReportStatePill(state: r.state, version: r.stateVersion, closed: r.closed),
              onTap: () => _toHub(ref, HubTab.knownIssues),
            ),
        ],
        if (zestHasCloud || kZestDiscordUrl != '') _SectionLabel(l10n.helpGroupGetInTouch),
        if (zestHasCloud) ...[
        _HelpRow(
          // The whole page for all of these;
          // the panel stays for quick things.
          key: const ValueKey('help-open-hub'),
          icon: LucideIcons.lifeBuoy,
          title: l10n.helpContactSupport,
          subtitle: l10n.helpContactSupportSub,
          chevron: true,
          onTap: () => _toHub(ref, HubTab.myTickets, compose: TicketType.support),
        ),
        _HelpRow(
          key: const ValueKey('help-my-tickets'),
          // Every way in touch in one quiet grey; the accent is the count's
          // alone.
          icon: LucideIcons.inbox,
          title: l10n.ticketsTitle,
          subtitle: needsReply > 0 ? l10n.helpNeedsYourReply(needsReply) : l10n.ticketsSub,
          badge: needsReply,
          chevron: true,
          onTap: () => _toHub(ref, HubTab.myTickets),
        ),
        _HelpRow(
          key: const ValueKey('help-ideas'),
          icon: LucideIcons.lightbulb,
          title: l10n.helpIdeasBoard,
          chevron: true,
          onTap: () => _toHub(ref, HubTab.ideas),
        ),
        ],
        if (kZestDiscordUrl != '')
          _HelpRow(
            icon: LucideIcons.messageCircle,
            title: l10n.helpDiscord,
            external: true,
            onTap: () => _open(kZestDiscordUrl),
          ),
        _SectionLabel(l10n.helpGroupBeforeShare),
        _HelpRow(
          icon: LucideIcons.video,
          iconColor: recording ? AppColors.sftpCrit : null,
          title: l10n.recModeName,
          subtitle: l10n.helpRecordingModeLong,
          trailingWidget: ZestSwitch(value: recording, onChanged: (v) =>
                ref.read(settingsUpdaterProvider).setRecordingMode(v)),
          onTap: () =>
              ref.read(settingsUpdaterProvider).setRecordingMode(!recording),
        ),
        _HelpRow(
          // A frame, not a second camera: the two rows must tell apart with
          // their labels covered.
          icon: LucideIcons.crop,
          title: l10n.recModeCopyScreenshot,
          onTap: onCopyRedactedScreenshot,
        ),
      ],
    );
  }

  void _open(String url) {
    if (url.isEmpty) return;
    // ignore: discarded_futures
    launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}

/// The search over the guides, drawn as the field it opens.
class _SearchRow extends StatelessWidget {
  const _SearchRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      label: l10n.guidesSearchHint,
      child: MouseRegion(
        cursor: SystemMouseCursors.text,
        child: GestureDetector(
          key: const ValueKey('help-guides'),
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            height: 38,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: AppColors.v3Surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.v3BorderDefault),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.search, size: 15, color: AppColors.v3TextTertiary),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    l10n.guidesSearchHint,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.v3TextTertiary),
                  ),
                ),
                const HubKbd('/'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// "Support replied, 2h ago": the newest answer not read yet, and Open.
class _RepliedBanner extends ConsumerWidget {
  const _RepliedBanner({required this.ticket, required this.onOpen});

  final SupportTicketRow ticket;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('help-replied'),
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
      decoration: BoxDecoration(
        color: AppColors.v3Warning.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: AppColors.v3Warning.withValues(alpha: 0.55)),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.messageSquare, size: 17, color: AppColors.v3Warning),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.helpSupportReplied(ticketRelativeTime(l10n, ticket.lastActivity.toLocal())),
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.v3TextPrimary),
                ),
                Text(
                  Redactable.freeText(ticket.title).displayIn(ref),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, color: AppColors.v3TextSecondary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          OutlinedButton(
            key: const ValueKey('help-replied-open'),
            onPressed: onOpen,
            style: OutlinedButton.styleFrom(minimumSize: const Size(0, 30), padding: const EdgeInsets.symmetric(horizontal: 12)),
            child: Text(l10n.helpOpen, style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }
}

/// The links at the foot of the panel: all the docs, the keyboard shortcuts,
/// and the diagnostics a report would send, on the clipboard.
class _FooterLinks extends ConsumerWidget {
  const _FooterLinks({required this.onOpenShortcuts});

  final VoidCallback onOpenShortcuts;

  Future<void> _copyDiagnostics(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final facts = await collectFeedbackContext(context, ref);
    if (facts == null || !context.mounted) return;
    await Clipboard.setData(ClipboardData(text: supportDiagnostics(facts.$1)));
    if (context.mounted) showTopSnackBar(context, l10n.helpDiagnosticsCopied, isSuccess: true);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    Widget link(String label, VoidCallback onTap, {Key? key}) => TextButton(
          key: key,
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            minimumSize: const Size(0, 26),
            foregroundColor: AppColors.v3TextSecondary,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          child: Text(label, style: const TextStyle(fontSize: 12)),
        );
    return Wrap(
      spacing: 2,
      children: [
        if (kZestDocsUrl != '')
          link(l10n.helpAllDocs, () => launchUrl(Uri.parse(kZestDocsUrl), mode: LaunchMode.externalApplication)),
        link(l10n.helpShortcuts, onOpenShortcuts),
        link(l10n.helpCopyDiagnostics, () => _copyDiagnostics(context, ref), key: const ValueKey('help-copy-diagnostics')),
      ],
    );
  }
}

/// Version and service status, always visible (fixes spec, section 9): the
/// version answers the first question of any bug report and the status
/// answers "is it me or is it them" before anyone files a ticket. About is a
/// link here rather than a row whose only content was the version.
class _HelpFooter extends ConsumerWidget {
  const _HelpFooter({required this.onAbout});

  final VoidCallback onAbout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final version = ref.watch(appVersionLabelProvider).valueOrNull ?? '';
    final status = ref.watch(cloudStatusProvider);
    final String line;
    final Color dot;
    switch (status.valueOrNull) {
      case CloudStatus.ok:
        line = l10n.helpFooterStatus(version);
        dot = AppColors.v3Success;
      case CloudStatus.degraded:
        line = l10n.helpFooterStatusDegraded(version, l10n.helpStatusDegraded);
        dot = AppColors.v3Warning;
      case CloudStatus.unreachable:
        // Which kind of "no answer" it is, as far as the app knows, in the
        // words the status bar has for it: what is on this side is amber.
        final failure = cloudNoAnswerNow();
        line = l10n.helpFooterStatusDegraded(version, failure.label(l10n));
        dot = failure.onThisSide ? AppColors.v3Warning : AppColors.v3Error;
      case null:
        line = l10n.helpFooterStatusChecking(version);
        dot = AppColors.v3TextTertiary;
    }
    return Row(
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            line,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'JetBrainsMono',
              color: AppColors.v3TextTertiary,
            ),
          ),
        ),
        TextButton(
          onPressed: onAbout,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            minimumSize: const Size(0, 28),
            foregroundColor: AppColors.v3TextSecondary,
          ),
          child: Text(l10n.helpAbout, style: const TextStyle(fontSize: 12)),
        ),
      ],
    );
  }
}

/// "Get help" (spec 5c, tickets handoff section 3): write to support here,
/// where the answer arrives in the app, or use a private Discord ticket or
/// email. The body keeps the security story honest: none of the three is
/// encrypted the way the vault is. The address is shown with a copy button
/// next to the link.
class _SupportPage extends StatelessWidget {
  const _SupportPage({required this.onWrite});

  final VoidCallback onWrite;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
      children: [
        Text(
          l10n.helpSupportBody,
          style: TextStyle(
              fontSize: 13, height: 1.45, color: AppColors.v3TextPrimary),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.helpSupportResponseTime,
          style: TextStyle(
              fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: onWrite,
          icon: const Icon(LucideIcons.edit, size: 16),
          label: Text(l10n.supportWrite),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.supportWriteSub,
          style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary),
        ),
        if (kZestDiscordUrl != '') ...[
          const SizedBox(height: 18),
          _SectionLabel(l10n.supportOtherWays, padded: false),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: () => launchUrl(Uri.parse(kZestDiscordUrl),
                mode: LaunchMode.externalApplication),
            icon: const Icon(LucideIcons.messageCircle, size: 16),
            label: Text(l10n.helpOpenDiscord),
          ),
        ],
        if (kZestSupportEmail != '') ...[
        const SizedBox(height: 14),
        _SectionLabel(l10n.helpEmail, padded: false),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
          // A step up from the panel, never down into it.
          decoration: BoxDecoration(
            color: ZestTokens.surfaceRaisedAlt,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppColors.v3BorderSubtle),
          ),
          child: Row(
            children: [
              Expanded(
                child: SelectableText(
                  kZestSupportEmail,
                  style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: l10n.copy,
                icon: const Icon(LucideIcons.copy, size: 16),
                onPressed: () async {
                  await Clipboard.setData(
                      ClipboardData(text: kZestSupportEmail));
                  if (context.mounted) {
                    showTopSnackBar(context, l10n.helpEmailCopied,
                        isSuccess: true);
                  }
                },
              ),
              IconButton(
                tooltip: l10n.helpEmail,
                icon: const Icon(LucideIcons.mail, size: 16),
                onPressed: () => launchUrl(Uri.parse(kZestSupportMailto),
                    mode: LaunchMode.externalApplication),
              ),
            ],
          ),
        ),
        ],
      ],
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text, {this.padded = true});
  final String text;
  final bool padded;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padded
          ? const EdgeInsets.fromLTRB(16, 12, 16, 4)
          : EdgeInsets.zero,
      child: ZestSectionHeader(label: text),
    );
  }
}

/// One row of the panel. Hover lifts the fill one step up the surface
/// ladder and the label to the primary text colour; the fill is never a
/// text token (fixes spec, section 1).
class _HelpRow extends StatefulWidget {
  const _HelpRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailingWidget,
    this.chevron = false,
    this.external = false,
    this.iconColor,
    this.badge = 0,
  });

  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;

  final Widget? trailingWidget;
  final bool chevron;

  /// Opens a browser; shows the outbound glyph.
  final bool external;

  /// A count shown as a filled pill before the chevron (unread answers).
  /// Nothing at zero.
  final int badge;
  final VoidCallback onTap;

  @override
  State<_HelpRow> createState() => _HelpRowState();
}

class _HelpRowState extends State<_HelpRow> {
  bool _hover = false;
  bool _focusRing = false;

  @override
  Widget build(BuildContext context) {
    // As designed: a row reads in the primary ink; hover
    // lifts its fill.
    final label = AppColors.v3TextPrimary;
    // A button to a screen reader and a stop for the keyboard, with the
    // accent ring (rows were reached by a pointer only). A row with a switch
    // is said by the switch, with the row's name.
    final toggles = widget.trailingWidget is ZestSwitch;
    return Semantics(
      container: true,
      button: !toggles,
      child: ZestHover(onHover: (h) => setState(() => _hover = h), child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onTap();
          return null;
        }),
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: _hover ? AppColors.v3Hover : Colors.transparent,
          // The ring drawn over the row, so it moves nothing.
          foregroundDecoration:
              _focusRing ? BoxDecoration(border: Border.all(color: ZestTokens.brand, width: 2)) : null,
          padding: EdgeInsets.symmetric(
              horizontal: 16, vertical: widget.subtitle == null ? 8 : 9),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 16,
                  color: widget.iconColor ?? AppColors.v3TextTertiary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: label)),
                    if (widget.subtitle != null)
                      Text(widget.subtitle!,
                          style: TextStyle(
                              fontSize: 11.5,
                              color: AppColors.v3TextTertiary)),
                  ],
                ),
              ),
              if (widget.trailingWidget != null)
                toggles
                    ? ZestControlLabel(label: widget.title, child: ExcludeFocus(child: widget.trailingWidget!))
                    : widget.trailingWidget!,
              if (widget.badge > 0)
                Container(
                  constraints: const BoxConstraints(minWidth: 18),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                  decoration: BoxDecoration(
                    color: ZestTokens.brand,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    widget.badge > 99 ? '99+' : '${widget.badge}',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: ZestTokens.onBrand),
                  ),
                ),
              if (widget.chevron) ...[
                const SizedBox(width: 4),
                Icon(LucideIcons.chevronRight,
                    size: 14, color: AppColors.v3TextTertiary),
              ],
              if (widget.external) ...[
                const SizedBox(width: 4),
                Icon(LucideIcons.externalLink,
                    size: 12, color: AppColors.v3TextTertiary),
              ],
            ],
          ),
        ),
      ),
      )),
    );
  }
}
