import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/assistant/assistant_region.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/help_dock_provider.dart' show HubTab;
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimitDesktop, freeSessionLimitMobile;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/help_links.dart';
import 'package:zestssh/utils/redactor.dart';

/// The mobile Help screen (help/feedback/support spec, section 2), laid out
/// as the desktop Help panel is (help_dock.dart), in the rows a phone's
/// Settings has: the questions people actually ask, the ways to get in
/// touch, what to do before sharing a screenshot, and the rest; then the
/// longer offline FAQ and the version footer. Pushed as a page of its own,
/// so its app bar has the way back.
class HelpSupportScreen extends ConsumerWidget {
  const HelpSupportScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.helpTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          // What's new, in the app bar's own quiet grey (it was the
          // accent's, louder than the title).
          TextButton.icon(
            key: const ValueKey('help-whats-new'),
            onPressed: () => showWhatsNewDialog(context),
            icon: const Icon(LucideIcons.sparkles, size: 16),
            label: Text(l10n.helpWhatsNew),
            style: TextButton.styleFrom(
              foregroundColor: ZestTokens.textSecondary,
              minimumSize: const Size(44, 44),
              textStyle:
                  const TextStyle(fontFamily: 'GeistSans', fontSize: 14, fontWeight: FontWeight.w500),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final version = snapshot.data?.version ?? '...';
          final buildNumber = snapshot.data?.buildNumber ?? '';

          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 600),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // ── The feature guides: most questions are "how do I" ──
                    // (A build with no docs site has none to fetch: neither the
                    // guides nor the questions that link into the docs are shown.)
                    if (kZestDocsOrigin != '') ...[
                      PhoneListGroup(l10n.helpGuides),
                      PhoneListCard(
                        children: [
                          _HelpRow(
                            key: const ValueKey('help-guides'),
                            icon: LucideIcons.search,
                            title: l10n.guidesSearchHint,
                            subtitle: l10n.helpGuidesSub,
                            onTap: () => context.push(Routes.guides),
                          ),
                        ],
                      ),
                    ],

                    // ── Common questions, above the buttons on purpose ──
                    if (kZestDocsOrigin != '') ...[
                      PhoneListGroup(l10n.helpGroupCommonQuestions),
                      _CommonQuestionsCard(l10n: l10n),
                    ],

                    // ── Report / suggest / get help / tickets / Discord ──
                    // (Reports, tickets and the Support Hub are the account
                    // service's: a build with none, and no Discord, has nobody
                    // to get in touch with here.)
                    if (zestHasCloud || kZestDiscordUrl != '') ...[
                      PhoneListGroup(l10n.helpGroupGetInTouch),
                      _GetInTouchCard(l10n: l10n),
                    ],

                    // ── Recording mode ─────────────────────────────
                    PhoneListGroup(l10n.helpGroupBeforeScreenshot),
                    const _ScreenshotCard(),

                    // ── Email, website, a review ─────────────────
                    if (_MoreCard.hasAnything) ...[
                      PhoneListGroup(l10n.helpGroupMore),
                      _MoreCard(l10n: l10n),
                    ],

                    // ── Offline FAQ ────────────────────────────────
                    PhoneListGroup(l10n.helpFaqTitle),
                    _FaqCard(l10n: l10n),
                    const SizedBox(height: 32),

                    // ── Version & branding footer ─────────────────
                    _Footer(
                        l10n: l10n, version: version, buildNumber: buildNumber),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Common questions: the few that are most of the support volume, each a
// link into the docs, then all of them.
// ══════════════════════════════════════════════════════════════════

class _CommonQuestionsCard extends StatelessWidget {
  final AppLocalizations l10n;
  const _CommonQuestionsCard({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return PhoneListCard(
      children: [
        _HelpRow(
          icon: LucideIcons.fileText,
          title: l10n.helpFaqImport,
          onTap: () => _launch(kZestDocsImporting),
        ),
        _HelpRow(
          icon: LucideIcons.fileText,
          title: l10n.helpFaqKeyRejected,
          onTap: () => _launch(kZestDocsConnectionIssues),
        ),
        _HelpRow(
          icon: LucideIcons.fileText,
          title: l10n.helpFaqSyncHosts,
          onTap: () => _launch(kZestDocsSyncNotWorking),
        ),
        _HelpRow(
          icon: LucideIcons.bookOpen,
          title: l10n.helpAllDocumentation,
          trailing: const _External(),
          onTap: () => _launch(kZestDocsUrl),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Get in touch: report, suggest, support, tickets, Discord
// ══════════════════════════════════════════════════════════════════

class _GetInTouchCard extends ConsumerWidget {
  final AppLocalizations l10n;

  const _GetInTouchCard({required this.l10n});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unread = ref.watch(ticketUnreadCountProvider);
    return PhoneListCard(
      children: [
        if (zestHasCloud) ...[
        _HelpRow(
          icon: LucideIcons.bug,
          title: l10n.helpReportBug,
          subtitle: l10n.helpReportBugSub,
          trailing: const _Chevron(),
          onTap: () => context.push(Routes.report, extra: FeedbackType.bug),
        ),
        _HelpRow(
          icon: LucideIcons.lightbulb,
          title: l10n.helpSuggest,
          subtitle: l10n.helpSuggestSub,
          trailing: const _Chevron(),
          onTap: () =>
              context.push(Routes.report, extra: FeedbackType.suggestion),
        ),
        // Support is a conversation: a private ticket written here, a
        // private Discord ticket or email.
        _HelpRow(
          icon: LucideIcons.lifeBuoy,
          title: l10n.helpSupport,
          subtitle: l10n.helpSupportSub,
          trailing: const _Chevron(),
          onTap: () => _showSupportSheet(context),
        ),
        // What was sent, and the answers. An unread answer is counted here,
        // the one thing in the accent on the page.
        _HelpRow(
          icon: LucideIcons.inbox,
          title: l10n.ticketsTitle,
          subtitle:
              unread > 0 ? l10n.ticketReplyFromSupport : l10n.ticketsSub,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (unread > 0) ...[_CountPill(unread), const SizedBox(width: 6)],
              const _Chevron(),
            ],
          ),
          onTap: () => context.push(Routes.tickets),
        ),
        // Everyone's bug reports and ideas, with +1 (3.4): the Support Hub.
        _HelpRow(
          key: const ValueKey('help-known-issues'),
          icon: LucideIcons.listChecks,
          title: l10n.supportHubTabKnownIssues,
          subtitle: l10n.helpKnownIssuesSub,
          trailing: const _Chevron(),
          onTap: () => context.push(Routes.supportHub, extra: HubTab.knownIssues),
        ),
        _HelpRow(
          key: const ValueKey('help-ideas-board'),
          icon: LucideIcons.lightbulb,
          title: l10n.helpIdeasBoard,
          subtitle: l10n.helpIdeasBoardSub,
          trailing: const _Chevron(),
          onTap: () => context.push(Routes.supportHub, extra: HubTab.ideas),
        ),
        ],
        if (kZestDiscordUrl != '')
        _HelpRow(
          icon: LucideIcons.messageCircle,
          title: l10n.helpDiscord,
          trailing: const _External(),
          onTap: () => _launch(kZestDiscordUrl),
        ),
        // Ask Astryx (4.0, a named preview): every account sees it; its screen
        // says who it is for, and carries the Preview label.
        if (zestHasCloud && ref.watch(assistantOfferedHereProvider).valueOrNull != false)
        _HelpRow(
          key: const ValueKey('help-ask-astryx'),
          icon: LucideIcons.sparkles,
          iconColor: ZestTokens.brand,
          title: l10n.astryxTitle,
          subtitle: l10n.astryxRowSub,
          trailing: const _Chevron(),
          onTap: () => context.push(Routes.askAstryx),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Before you share a screenshot: recording mode and its level
// ══════════════════════════════════════════════════════════════════

class _ScreenshotCard extends ConsumerWidget {
  const _ScreenshotCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final recording = ref.watch(recordingModeProvider);
    final level = ref.watch(recordingRedactLevelProvider);
    void set(bool v) => ref.read(settingsUpdaterProvider).setRecordingMode(v);
    return PhoneListCard(
      children: [
        // Recording mode lives here on mobile (the desktop has the pill-bar
        // control): mask names and addresses before taking a screenshot.
        _HelpRow(
          key: const ValueKey('help-recording-mode'),
          icon: LucideIcons.video,
          // Red while it is on: the screen is being made ready to be shown.
          iconColor: recording ? AppColors.error : null,
          title: l10n.recModeName,
          subtitle: l10n.recModeTooltipOff,
          trailing: ZestSwitch(value: recording, onChanged: set),
          onTap: () => set(!recording),
        ),
        // The level, same two choices as the desktop menu. Strict also hides
        // Command history; Layout keeps its shape with stand-in commands.
        if (recording)
          RadioGroup<RedactLevel>(
            groupValue: level,
            onChanged: (value) {
              if (value != null) ref.read(settingsUpdaterProvider).setRecordingRedactLevel(value);
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _LevelTile(
                  key: const ValueKey('help-recording-layout'),
                  label: l10n.recModeLevelLayout,
                  desc: l10n.recModeLevelLayoutDesc,
                  value: RedactLevel.layout,
                  group: level,
                ),
                _LevelTile(
                  key: const ValueKey('help-recording-strict'),
                  label: l10n.recModeLevelStrict,
                  desc: l10n.recModeLevelStrictDesc,
                  value: RedactLevel.strict,
                  group: level,
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One of recording mode's two levels, in the [RadioGroup] around both: the
/// dot the app's pick-one choices have (a check is for where several can be
/// picked: a UI review), its words in line with the words
/// of the rows above it. As a Settings choice (SettingsRadioRow) the row is
/// the one control, by tap, Enter or Space, and the arrows move between rows.
class _LevelTile extends StatelessWidget {
  const _LevelTile({
    super.key,
    required this.label,
    required this.desc,
    required this.value,
    required this.group,
  });

  final String label;
  final String desc;
  final RedactLevel value;
  final RedactLevel group;

  @override
  Widget build(BuildContext context) {
    final selected = value == group;
    final radios = RadioGroup.maybeOf<RedactLevel>(context);
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.arrowDown): DirectionalFocusIntent(TraversalDirection.down),
        SingleActivator(LogicalKeyboardKey.arrowUp): DirectionalFocusIntent(TraversalDirection.up),
      },
      child: MergeSemantics(
        child: InkWell(
          onTap: () => radios?.onChanged(value),
          child: Padding(
            // The dot in the icon's column: 32 + 20 + 10 puts the words at 62,
            // where the rows above have theirs.
            padding: const EdgeInsets.fromLTRB(32, 10, 14, 10),
            child: Row(
              children: [
                SizedBox(
                  width: 20,
                  height: 20,
                  child: ExcludeFocus(
                    child: IgnorePointer(
                      child: Radio<RedactLevel>(
                        value: value,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(label,
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                              color: ZestTokens.textPrimary)),
                      const SizedBox(height: 2),
                      Text(desc, style: _subtitleStyle),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An unread count on a row, before its chevron.
class _CountPill extends StatelessWidget {
  const _CountPill(this.count);

  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 22),
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: ZestTokens.brand,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        count > 99 ? '99+' : '$count',
        textAlign: TextAlign.center,
        style: TextStyle(
            fontSize: 12, fontWeight: FontWeight.w700, color: ZestTokens.onBrand),
      ),
    );
  }
}

/// "Get help" (spec 5c, tickets handoff section 3): write to support here,
/// or a Discord ticket or email, with the line that keeps the security story
/// honest, in the app's bottom sheet so it never leaves the screen.
void _showSupportSheet(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  // As tall as what it holds, scrolling when that is more than the screen
  // (long translations, large text, a short phone).
  showZestSheet<void>(
    context: context,
    child: Builder(
      builder: (ctx) => ZestSheetFrame(
        child: SingleChildScrollView(
          key: const ValueKey('help-support-sheet'),
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.helpSupport,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: ZestTokens.textPrimary,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.helpSupportBody,
                style: TextStyle(
                    fontSize: 15, height: 1.45, color: ZestTokens.textSecondary),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.helpSupportResponseTime,
                style: TextStyle(
                    fontSize: 13, height: 1.4, color: ZestTokens.textTertiary),
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: () {
                  Navigator.of(ctx).pop();
                  context.push(Routes.contactSupport);
                },
                icon: const Icon(LucideIcons.pencil, size: 18),
                label: Text(l10n.supportWrite),
              ),
              const SizedBox(height: 6),
              Text(
                l10n.supportWriteSub,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary),
              ),
              if (kZestDiscordUrl != '') ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => _launch(kZestDiscordUrl),
                  icon: const Icon(LucideIcons.messagesSquare, size: 18),
                  label: Text(l10n.helpOpenDiscord),
                ),
              ],
              if (kZestSupportEmail != '') ...[
                const SizedBox(height: 12),
                _EmailRow(l10n: l10n),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}

/// The support address with a copy button next to the mail link (spec 8):
/// a share of phones and desktops have no mail client, and a dead mailto
/// reads as a broken app. A step up from the sheet it sits on, with a
/// hairline (it was darker than the sheet, a hole in it).
class _EmailRow extends StatelessWidget {
  final AppLocalizations l10n;
  const _EmailRow({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(left: 14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.mail, size: 18, color: ZestTokens.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              kZestSupportEmail,
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13),
            ),
          ),
          IconButton(
            tooltip: l10n.copy,
            color: ZestTokens.textSecondary,
            icon: const Icon(LucideIcons.copy, size: 18),
            onPressed: () => _copyEmail(context),
          ),
          IconButton(
            tooltip: l10n.helpEmail,
            color: ZestTokens.textSecondary,
            icon: const Icon(LucideIcons.externalLink, size: 18),
            onPressed: () => _launch(kZestSupportMailto),
          ),
        ],
      ),
    );
  }
}

Future<void> _copyEmail(BuildContext context) async {
  final l10n = AppLocalizations.of(context)!;
  await Clipboard.setData(ClipboardData(text: kZestSupportEmail));
  if (context.mounted) {
    showTopSnackBar(context, l10n.helpEmailCopied, isSuccess: true);
  }
}

// ══════════════════════════════════════════════════════════════════
// More: email, the website, a review. (The docs are under Common
// questions and Discord under Get in touch, each once.)
// ══════════════════════════════════════════════════════════════════

class _MoreCard extends StatelessWidget {
  final AppLocalizations l10n;

  const _MoreCard({required this.l10n});

  /// The store page a phone's "Rate" opens: the build's own, or none.
  static String get _storePage => Platform.isAndroid ? kZestPlayStoreUrl : (Platform.isIOS ? kZestAppStoreUrl : '');

  /// Whether the build has any of them: a support address, a website, a
  /// store page. The card is not drawn empty.
  static bool get hasAnything => kZestSupportEmail != '' || kZestWebsite != '' || _storePage != '';

  @override
  Widget build(BuildContext context) {
    final isMobile = Platform.isAndroid || Platform.isIOS;

    return PhoneListCard(
      children: [
        if (kZestSupportEmail != '')
        _HelpRow(
          icon: LucideIcons.mail,
          title: l10n.helpEmail,
          subtitle: kZestSupportEmail,
          trailing: IconButton(
            tooltip: l10n.copy,
            icon: Icon(LucideIcons.copy, size: 18, color: ZestTokens.textSecondary),
            onPressed: () => _copyEmail(context),
          ),
          onTap: () => _launch(kZestSupportMailto),
        ),
        if (kZestWebsite != '')
        _HelpRow(
          icon: LucideIcons.globe,
          title: l10n.helpWebsite,
          subtitle: l10n.helpWebsiteSub,
          trailing: const _External(),
          onTap: () => _launch(kZestWebsite),
        ),
        // Rate/Review - different for mobile vs desktop
        if (isMobile && _storePage != '')
          _HelpRow(
            icon: LucideIcons.star,
            title: l10n.helpRateApp,
            subtitle: l10n.helpRateAppSub,
            trailing: const _External(),
            onTap: () => _launch(_storePage),
          )
        else if (!isMobile && kZestWebsite != '')
          _HelpRow(
            icon: LucideIcons.messageSquare,
            title: l10n.helpReviewDesktop,
            subtitle: l10n.helpReviewDesktopSub,
            trailing: const _External(),
            onTap: () => _launch(kZestWebsite),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// FAQ Card - expandable rows
// ══════════════════════════════════════════════════════════════════

class _FaqCard extends StatelessWidget {
  final AppLocalizations l10n;

  const _FaqCard({required this.l10n});

  @override
  Widget build(BuildContext context) {
    return PhoneListCard(
      children: [
        _FaqTile(
          icon: LucideIcons.shield,
          title: l10n.helpFaqDataSafeTitle,
          body: l10n.helpFaqDataSafeBody,
        ),
        _FaqTile(
          icon: LucideIcons.eyeOff,
          title: l10n.helpFaqDataCollectTitle,
          body: l10n.helpFaqDataCollectBody,
        ),
        _FaqTile(
          icon: LucideIcons.cloudCog,
          title: l10n.helpFaqCloudSyncTitle,
          body: l10n.helpFaqCloudSyncBody,
        ),
        _FaqTile(
          icon: LucideIcons.lock,
          title: l10n.helpFaqSshSecurityTitle,
          body: l10n.helpFaqSshSecurityBody,
        ),
        _FaqTile(
          icon: LucideIcons.keyRound,
          title: l10n.helpFaqPasswordsTitle,
          body: l10n.helpFaqPasswordsBody,
        ),
        _FaqTile(
          icon: LucideIcons.trash2,
          title: l10n.helpFaqDeleteAccountTitle,
          body: l10n.helpFaqDeleteAccountBody,
        ),
        _FaqTile(
          icon: LucideIcons.code,
          title: l10n.helpFaqOpenSourceTitle,
          body: l10n.helpFaqOpenSourceBody,
        ),
        _FaqTile(
          icon: LucideIcons.download,
          title: l10n.helpFaqImportTitle,
          body: l10n.helpFaqImportBody,
        ),
        _FaqTile(
          icon: LucideIcons.award,
          title: l10n.helpFaqTiersTitle,
          body: l10n.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Footer
// ══════════════════════════════════════════════════════════════════

class _Footer extends StatelessWidget {
  final AppLocalizations l10n;
  final String version;
  final String buildNumber;

  const _Footer({
    required this.l10n,
    required this.version,
    required this.buildNumber,
  });

  @override
  Widget build(BuildContext context) {
    final quiet = TextStyle(fontSize: 13, color: ZestTokens.textSecondary);
    return Center(
      child: Column(
        children: [
          Divider(color: ZestTokens.borderSubtle),
          const SizedBox(height: 16),
          Text(l10n.helpVersionInfo(version, buildNumber), style: quiet),
          const SizedBox(height: 6),
          Text(l10n.helpMadeBy, style: quiet),
          if (kZestMakerUrl != '') ...[
            const SizedBox(height: 4),
            GestureDetector(
              onTap: () => _launch(kZestMakerUrl),
              child: Text(
                '${l10n.helpCompany} · ${l10n.helpCompanyUrl}',
                style: TextStyle(fontSize: 12, color: ZestTokens.brandInk),
              ),
            ),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Shared Widgets
// ══════════════════════════════════════════════════════════════════

/// What a row's words under its name look like, as a phone's Settings rows.
TextStyle get _subtitleStyle =>
    TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textSecondary);

/// One row of the page, as a phone's Settings draws its own
/// (lib/ui/widgets/phone_list.dart): an icon tile, the name, what it holds
/// under it, and what is at its end (a chevron for a page of the app, the
/// outbound glyph for a browser, a switch, a count). The tiles are the quiet
/// grey: every way in touch alike, the accent left to the unread count.
class _HelpRow extends StatelessWidget {
  const _HelpRow({
    super.key,
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
    this.trailing,
    this.iconColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;
  final Widget? trailing;

  /// The tile's colour where it says a state (recording on); grey otherwise.
  final Color? iconColor;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 52),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          child: Row(
            children: [
              PhoneIconTile(icon, color: iconColor ?? ZestTokens.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: PhoneListRow.titleStyle),
                    if (subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(subtitle!, style: _subtitleStyle),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 8),
                trailing!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The end of a row that opens a page of the app.
class _Chevron extends StatelessWidget {
  const _Chevron();

  @override
  Widget build(BuildContext context) =>
      Icon(LucideIcons.chevronRight, size: 18, color: ZestTokens.textTertiary);
}

/// The end of a row that opens a browser.
class _External extends StatelessWidget {
  const _External();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 2),
        child: Icon(LucideIcons.externalLink, size: 16, color: ZestTokens.textTertiary),
      );
}

/// An FAQ row that opens to its answer, its chevron turning.
class _FaqTile extends StatefulWidget {
  final IconData icon;
  final String title;
  final String body;

  const _FaqTile({
    required this.icon,
    required this.title,
    required this.body,
  });

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HelpRow(
          icon: widget.icon,
          title: widget.title,
          trailing: AnimatedRotation(
            turns: _expanded ? 0.25 : 0,
            duration: const Duration(milliseconds: 200),
            child: const _Chevron(),
          ),
          onTap: () => setState(() => _expanded = !_expanded),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(62, 0, 16, 14),
            child: Text(
              widget.body,
              style: TextStyle(
                fontSize: 14,
                height: 1.5,
                color: ZestTokens.textSecondary,
              ),
            ),
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 200),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// URL Launcher Helper
// ══════════════════════════════════════════════════════════════════

Future<void> _launch(String url) async {
  // (A build with no such page: nothing to open.)
  if (url.isEmpty) return;
  final uri = Uri.parse(url);
  try {
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    try {
      await launchUrl(uri);
    } catch (_) {
      // URL couldn't be launched - ignore silently
    }
  }
}
