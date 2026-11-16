import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/review_prompt.dart';
import 'package:in_app_review/in_app_review.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/help_links.dart' show kZestDiscordUrl, kZestFaqUrl;
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/features/feedback/feedback_report.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/screens/settings/licenses_screen.dart';

/// Dedicated About screen for ZestSSH.
///
/// Layout: hero (logo + name + version + tagline) → quick links grid
/// → resources section → footer. Designed to read clean on desktop
/// but still scale down to mobile via a max-width constraint.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.aboutScreenTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: FutureBuilder<PackageInfo>(
        future: PackageInfo.fromPlatform(),
        builder: (context, snapshot) {
          final version = snapshot.data?.version ?? '…';
          final buildNumber = snapshot.data?.buildNumber ?? '';
          final gutter = MediaQuery.sizeOf(context).width < 600 ? 16.0 : 24.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(gutter, 16, gutter, 48),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Hero(
                      version: version,
                      buildNumber: buildNumber,
                    ),
                    const SizedBox(height: 36),
                    _SectionHeader(label: l10n.aboutScreenResources),
                    const SizedBox(height: 12),
                    _LinksGrid(version: version, buildNumber: buildNumber),
                    // Rating in the store, where the app came from (a phone).
                    if (ReviewPrompt.onThisDevice && ReviewPrompt.hasStorePage) ...[
                      const SizedBox(height: 12),
                      const _RateRow(),
                    ],
                    const SizedBox(height: 28),
                    _SectionHeader(label: l10n.aboutScreenLegal),
                    const SizedBox(height: 12),
                    _LegalRow(version: version),
                    const SizedBox(height: 36),
                    _Footer(),
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
// Hero - icon + name + version + tagline
// ══════════════════════════════════════════════════════════════════

class _Hero extends StatelessWidget {
  const _Hero({
    required this.version,
    required this.buildNumber,
  });
  final String version;
  final String buildNumber;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: EdgeInsets.all(MediaQuery.sizeOf(context).width < 600 ? 20 : 28),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      // The words beside the icon where they keep room, and under it
      // on a phone's narrow page.
      child: _IconBesideWords(
        // App icon - large + soft glow ring so it reads as the
        // visual anchor on desktop.
        icon: Container(
          width: 96,
          height: 96,
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                AppColors.brandOrange.withValues(alpha: 0.55),
                AppColors.brandOrange.withValues(alpha: 0.05),
              ],
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(20),
            child: Image.asset(
              'assets/ZestSSH.png',
              fit: BoxFit.contain,
            ),
          ),
        ),
        words: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Wrap (not Row) so the version + tier badges flow onto a
            // second line on a narrow phone instead of overflowing the card.
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                Text(
                  'ZestSSH',
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w700,
                    color: AppColors.onBackground,
                    letterSpacing: -0.5,
                  ),
                ),
                // The plan, matching desktop's About: a tap says what
                // each plan is (the plan popover, 4.0). It said Juiced for
                // the Bundle.
                const PlanChip(key: ValueKey('about-tier')),
              ],
            ),
            // The release and its build, whole, as a line of its own (a
            // chip beside the name was cut to "v..." on a phone).
            const SizedBox(height: 4),
            Text(
              l10n.settingsVersion(buildNumber.isEmpty ? version : '$version ($buildNumber)'),
              key: const ValueKey('about-version'),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            // Which build this is, where it is not the release: the
            // builder's own name for it, or "Community build".
            if (!zestOfficial) ...[
              const SizedBox(height: 4),
              Text(
                zestBuildNameShown != '' ? zestBuildNameShown : l10n.communityBuild,
                key: const ValueKey('about-build-kind'),
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              l10n.productStatement,
              style: TextStyle(
                fontSize: 15,
                color: AppColors.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _MetaPill(
                    icon: LucideIcons.shield,
                    label: l10n.aboutScreenMetaEndToEndEncrypted),
                _MetaPill(
                    icon: LucideIcons.cpu,
                    label: l10n.aboutScreenMetaNativeOnEveryDesktop),
                _MetaPill(
                    icon: LucideIcons.gitBranch,
                    label: l10n.aboutScreenMetaOpenStandards),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// The About card's icon, with its words beside it where they keep room to
/// be read and under it where they would not: beside it on a phone's narrow
/// page, a pill ran off the card in every language, and at a larger text
/// size the app's name lost its last letter (found 17 October 2026).
class _IconBesideWords extends StatelessWidget {
  const _IconBesideWords({required this.icon, required this.words});
  final Widget icon;
  final Widget words;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      if (constraints.maxWidth - 96 - 24 >= 240 * scale) {
        return Row(children: [icon, const SizedBox(width: 24), Expanded(child: words)]);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [icon, const SizedBox(height: 20), words],
      );
    });
  }
}


class _MetaPill extends StatelessWidget {
  const _MetaPill({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: AppColors.onSurfaceVariant),
          const SizedBox(width: 6),
          // A label longer than the card wraps in its pill.
          Flexible(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                color: AppColors.onSurface,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Section header
// ══════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: ZestSectionHeader(label: label),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Quick links grid (3 columns on desktop, 2 on narrower)
// ══════════════════════════════════════════════════════════════════

class _LinksGrid extends StatelessWidget {
  const _LinksGrid({required this.version, required this.buildNumber});
  final String version;
  final String buildNumber;

  static Future<void> _launch(String url) async {
    try {
      await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      try {
        await launchUrl(Uri.parse(url));
      } catch (_) {/* swallow - caller doesn't have a snackbar here */}
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return LayoutBuilder(
      builder: (context, c) {
        final cols = c.maxWidth >= 600 ? 3 : (c.maxWidth >= 380 ? 2 : 1);
        final links = <({IconData icon, String title, String detail, VoidCallback onTap, bool leaves})>[
          // (Only what the build has: a community build names no website, no
          // Discord and no service to send a report to.)
          if (kZestWebsite != '')
            (icon: LucideIcons.globe, title: l10n.aboutScreenLinkWebsite, detail: kZestWebsiteHost,
                onTap: () => _launch(kZestWebsite), leaves: true),
          if (kZestFaqUrl != '')
            (icon: LucideIcons.helpCircle, title: l10n.aboutScreenLinkDocsFaq, detail: l10n.aboutScreenLinkDocsFaqDetail,
                onTap: () => _launch(kZestFaqUrl), leaves: true),
          if (kZestDiscordUrl != '')
            (icon: LucideIcons.messageCircle, title: 'Discord', detail: l10n.aboutScreenLinkDiscordDetail,
                onTap: () => _launch(kZestDiscordUrl), leaves: true),
          if (zestHasCloud)
            (icon: LucideIcons.bug, title: l10n.aboutScreenLinkReportBug, detail: l10n.aboutScreenLinkReportBugDetail,
                onTap: () => context.push(Routes.report, extra: FeedbackType.bug), leaves: false),
          (icon: LucideIcons.gift, title: l10n.aboutScreenLinkWhatsNew, detail: l10n.aboutScreenLinkChangelogDetail,
              onTap: () => showWhatsNewDialog(context), leaves: false),
          // Rating is the stores' (_RateRow, on a phone or a tablet): a
          // computer has no page to rate the app on, so no Rate link (it
          // opened the website's home page).
        ];
        if (c.maxWidth < 600) {
          return Container(
            key: const ValueKey('about-links-card'),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  for (var i = 0; i < links.length; i++) ...[
                    if (i > 0) Divider(height: 1, thickness: 1, indent: 62, color: AppColors.v3BorderSubtle),
                    InkWell(
                      onTap: links[i].onTap,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        child: Row(
                          children: [
                            PhoneIconTile(links[i].icon),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(links[i].title, style: PhoneListRow.titleStyle),
                                  const SizedBox(height: 2),
                                  Text(links[i].detail,
                                      style: TextStyle(fontSize: 12.5, height: 1.35, color: AppColors.textSecondary)),
                                ],
                              ),
                            ),
                            Icon(links[i].leaves ? LucideIcons.externalLink : LucideIcons.chevronRight,
                                size: links[i].leaves ? 16 : 18, color: ZestTokens.textTertiary),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        }
        final tiles = <Widget>[
          if (kZestWebsite != '')
            _LinkTile(
              icon: LucideIcons.globe,
              title: l10n.aboutScreenLinkWebsite,
              detail: kZestWebsiteHost,
              onTap: () => _launch(kZestWebsite),
            ),
          if (kZestFaqUrl != '')
            _LinkTile(
              icon: LucideIcons.helpCircle,
              title: l10n.aboutScreenLinkDocsFaq,
              detail: l10n.aboutScreenLinkDocsFaqDetail,
              onTap: () => _launch(kZestFaqUrl),
            ),
          if (kZestDiscordUrl != '')
            _LinkTile(
              icon: LucideIcons.messageCircle,
              title: 'Discord',
              detail: l10n.aboutScreenLinkDiscordDetail,
              onTap: () => _launch(kZestDiscordUrl),
            ),
          if (zestHasCloud)
          _LinkTile(
            icon: LucideIcons.bug,
            title: l10n.aboutScreenLinkReportBug,
            detail: l10n.aboutScreenLinkReportBugDetail,
            // The in-app report form attaches the build info itself (and an
            // optional redacted screenshot), so this no longer leaves the app.
            onTap: () => context.push(Routes.report, extra: FeedbackType.bug),
          ),
          _LinkTile(
            icon: LucideIcons.gift,
            title: l10n.aboutScreenLinkWhatsNew,
            detail: l10n.aboutScreenLinkChangelogDetail,
            onTap: () => showWhatsNewDialog(context),
          ),
        ];

        // Manual grid (instead of GridView) so the cells size to
        // their content rather than to a fixed ratio.
        final rows = <Widget>[];
        for (var i = 0; i < tiles.length; i += cols) {
          rows.add(Row(
            children: [
              for (var j = 0; j < cols; j++) ...[
                Expanded(
                  child: i + j < tiles.length
                      ? tiles[i + j]
                      : const SizedBox.shrink(),
                ),
                if (j < cols - 1) const SizedBox(width: 10),
              ],
            ],
          ));
          if (i + cols < tiles.length) {
            rows.add(const SizedBox(height: 10));
          }
        }
        return Column(children: rows);
      },
    );
  }
}

class _LinkTile extends StatefulWidget {
  const _LinkTile({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;

  @override
  State<_LinkTile> createState() => _LinkTileState();
}

class _LinkTileState extends State<_LinkTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: _hover ? AppColors.surfaceLight : AppColors.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: _hover
                  ? AppColors.brandOrange.withValues(alpha: 0.45)
                  : AppColors.divider,
              width: _hover ? 1.0 : 0.5,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppColors.brandOrange.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(widget.icon,
                    size: 16, color: AppColors.accentInk),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: AppColors.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.detail,
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                LucideIcons.externalLink,
                size: 13,
                color: _hover
                    ? AppColors.accentInk
                    : AppColors.onSurfaceDim,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Legal row - privacy / terms / licenses
// ══════════════════════════════════════════════════════════════════

/// "Rate ZestSSH": its page in the App Store or the Play Store, always
/// there for whoever wants it (the stores' own prompt comes by itself only
/// now and then: lib/services/review_prompt.dart).
class _RateRow extends StatelessWidget {
  const _RateRow();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: _LegalRowItem(
        key: const ValueKey('about-rate-app'),
        icon: LucideIcons.star,
        label: l10n.aboutRateApp,
        sublabel: l10n.aboutRateAppDesc,
        onTap: () async {
          try {
            await InAppReview.instance.openStoreListing(appStoreId: kZestAppStoreId);
          } catch (_) {
            // No store on this device (a test, a phone without one): the
            // website's download page instead, where the build has one.
            if (kZestDownloadPage != '') {
              await launchUrl(Uri.parse(kZestDownloadPage), mode: LaunchMode.externalApplication);
            }
          }
        },
      ),
    );
  }
}

class _LegalRow extends StatelessWidget {
  const _LegalRow({required this.version});
  final String version;

  static Future<void> _launch(String url) async {
    try {
      await launchUrl(Uri.parse(url),
          mode: LaunchMode.externalApplication);
    } catch (_) {/* fall through silently */}
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider, width: 0.5),
      ),
      child: Column(
        children: [
          // (The release's policy and terms say nothing about another build:
          // a build shows its own website's, or none.)
          if (kZestPrivacyUrl != '') ...[
            _LegalRowItem(
              icon: LucideIcons.fileText,
              label: l10n.aboutScreenLegalPrivacy,
              onTap: () => _launch(kZestPrivacyUrl),
            ),
            Divider(height: 1, color: AppColors.divider),
            _LegalRowItem(
              icon: LucideIcons.fileText,
              label: l10n.aboutScreenLegalTerms,
              onTap: () => _launch(kZestTermsUrl),
            ),
            Divider(height: 1, color: AppColors.divider),
          ],
          _LegalRowItem(
            icon: LucideIcons.scale,
            label: l10n.aboutScreenLegalLicenses,
            sublabel: l10n.aboutScreenLegalLicensesSublabel,
            onTap: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => LicensesScreen(version: version),
            )),
          ),
        ],
      ),
    );
  }
}

class _LegalRowItem extends StatefulWidget {
  const _LegalRowItem({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.sublabel,
  });
  final IconData icon;
  final String label;
  final String? sublabel;
  final VoidCallback onTap;

  @override
  State<_LegalRowItem> createState() => _LegalRowItemState();
}

class _LegalRowItemState extends State<_LegalRowItem> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          color: _hover ? AppColors.surfaceLight : Colors.transparent,
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 16, color: AppColors.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.label,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppColors.onSurface,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (widget.sublabel != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        widget.sublabel!,
                        style: TextStyle(
                            fontSize: 11,
                            color: AppColors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
              Icon(LucideIcons.chevronRight,
                  size: 14, color: AppColors.onSurfaceDim),
            ],
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Footer
// ══════════════════════════════════════════════════════════════════

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Column(
        children: [
          Text(
            l10n.aboutScreenCopyright(DateTime.now().year),
            style: TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.aboutScreenFooterTagline,
            style: TextStyle(
              fontSize: 11,
              color: AppColors.onSurfaceDim,
            ),
          ),
        ],
      ),
    );
  }
}
