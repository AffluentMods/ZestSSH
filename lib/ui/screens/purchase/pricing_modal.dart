import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

/// Desktop-oriented pricing modal with three tiers (Free, Pro, Strongbox)
/// plus a teams upsell row.
///
/// Show via [PricingModal.show].
class PricingModal extends ConsumerWidget {
  const PricingModal({super.key});

  /// Entry point for every "upgrade" / "unlock with Pro" CTA in the
  /// app.
  ///
  /// On desktop we skip this intermediate dialog entirely and route
  /// straight to the full [DesktopUpgradeView] (via [Routes.upgrade]
  /// → [UpgradeScreen] which delegates) - the new view IS the pricing
  /// surface, and showing this 780-px modal first was just a
  /// confusing extra click for the user.
  ///
  /// On mobile this still opens as a bottom-anchored dialog because
  /// the legacy [UpgradeScreen] mobile layout is a full route push
  /// that interrupts the user's flow; a quick pricing peek-before-
  /// committing UX is the right call on a phone.
  static void show(BuildContext context) {
    // (A build with no plans to buy: the upgrade page says so, on a phone too.)
    if (isDesktopPlatform || !zestHasPlans) {
      context.push(Routes.upgrade);
      return;
    }
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      builder: (_) => const PricingModal(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isPro = ref.watch(isProProvider);
    final hasCloudSync = ref.watch(isCloudSyncProvider);
    final hasBundle = isPro && hasCloudSync;

    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 780,
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.9,
          ),
          decoration: BoxDecoration(
            color: AppColors.v3Elevated,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppColors.v3BorderDefault),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 40,
                spreadRadius: 4,
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildHeader(context),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(32, 8, 32, 0),
                    child: _buildTierCards(
                      context,
                      isPro: isPro,
                      hasCloudSync: hasCloudSync,
                      hasBundle: hasBundle,
                    ),
                  ),
                  const SizedBox(height: 24),
                  _buildTagline(context),
                  const SizedBox(height: 16),
                  _buildTeamsRow(context),
                  const SizedBox(height: 28),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Header ───────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 24, 24, 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              l10n.pricingTitle,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppColors.v3TextPrimary,
              ),
            ),
          ),
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(LucideIcons.x, size: 20),
            color: AppColors.v3TextSecondary,
            splashRadius: 18,
            tooltip: l10n.close,
          ),
        ],
      ),
    );
  }

  // ── Tier cards row ───────────────────────────────────────────────

  Widget _buildTierCards(
    BuildContext context, {
    required bool isPro,
    required bool hasCloudSync,
    required bool hasBundle,
  }) {
    final l10n = AppLocalizations.of(context)!;
    // Determine the user's current highest tier for button states.
    final _TierOwnership ownership;
    if (hasBundle) {
      ownership = _TierOwnership.strongbox;
    } else if (hasCloudSync) {
      // Cloud sync without pro is an edge case; treat as strongbox-level.
      ownership = _TierOwnership.strongbox;
    } else if (isPro) {
      ownership = _TierOwnership.pro;
    } else {
      ownership = _TierOwnership.free;
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Free
        Expanded(
          child: _TierCard(
            tierName: l10n.pricingTierFree,
            priceLabel: l10n.pricingTierFree,
            priceSubtitle: l10n.pricingForever,
            features: [
              l10n.pricingFeatureSessionLimit(freeSessionLimitDesktop, freeSessionLimitMobile),
              l10n.pricingFeatureBasicSsh,
              l10n.pricingFeatureJetBrainsMono,
            ],
            isCurrent: ownership == _TierOwnership.free,
            isRecommended: false,
            onUpgrade: null,
          ),
        ),
        const SizedBox(width: 16),

        // Pro
        Expanded(
          child: _TierCard(
            tierName: l10n.pricingTierSqueezed,
            priceLabel: '\$9.99',
            priceSubtitle: l10n.pricingOneTime,
            features: [
              l10n.pricingFeatureUnlimitedSessions,
              l10n.pricingFeatureSnippetsLibrary,
              l10n.pricingFeatureAutomationEngine,
              l10n.pricingFeatureSftpBrowser,
              l10n.pricingFeatureCustomThemes,
              l10n.pricingFeaturePerConnectionThemes,
              l10n.pricingFeatureJumpHosts,
            ],
            isCurrent: ownership == _TierOwnership.pro,
            isRecommended: true,
            onUpgrade: ownership.index < _TierOwnership.pro.index
                ? () => _handleUpgrade(context, 'zestssh_pro')
                : null,
          ),
        ),
        const SizedBox(width: 16),

        // Bundle (bundle)
        Expanded(
          child: _TierCard(
            tierName: l10n.pricingTierBundle,
            priceLabel: '\$29.99',
            priceSubtitle: l10n.pricingOneTime,
            strikethroughPrice: '\$34.98',
            features: [
              l10n.pricingFeatureEverythingSqueezed,
              l10n.pricingFeatureJuicedCloud,
              l10n.pricingFeatureZeroKnowledge,
              // No priority support here: the terms give it to Business.
            ],
            isCurrent: ownership == _TierOwnership.strongbox,
            isRecommended: false,
            onUpgrade: ownership.index < _TierOwnership.strongbox.index
                ? () => _handleUpgrade(context, 'zestssh_bundle')
                : null,
          ),
        ),
      ],
    );
  }

  // ── Tagline ──────────────────────────────────────────────────────

  Widget _buildTagline(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Text(
      l10n.pricingTagline,
      style: TextStyle(
        fontSize: 13,
        color: AppColors.v3TextSecondary,
      ),
    );
  }

  // ── Teams row ────────────────────────────────────────────────────

  Widget _buildTeamsRow(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 32),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.v3BorderSubtle),
        color: AppColors.v3Surface,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            l10n.pricingTeamsPrice,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '\u00b7',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.v3TextDisabled,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            l10n.pricingTeamsComingSoon,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.v3AccentInk,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ── Upgrade handler ──────────────────────────────────────────────

  /// Routes the user to the right purchase flow for their platform.
  ///
  /// - **Mobile (Android / iOS)**: close this modal, push the real
  ///   [UpgradeScreen] which talks to RevenueCat.  Previously this
  ///   was a stubbed `"Opening store…"` snackbar that did nothing
  ///   - that's the broken UX the user reported.
  /// - **Desktop**: show the dedicated "purchases are mobile-only"
  ///   dialog (matches what the upgrade screen shows on restore /
  ///   buy attempts), with a link to the web upgrade page and an
  ///   explanation of the Cloud Sync entitlement-mirror path.
  void _handleUpgrade(BuildContext context, String productId) {
    // Always close the pricing modal first, then push the upgrade
    // screen.  UpgradeScreen now detects desktop internally and
    // renders [DesktopUpgradeView] - a proper window with tier
    // cards, account-linking banner, web checkout, and the
    // "I already purchased" refresh path baked in.  Mobile pushes
    // the same screen and gets the RevenueCat purchase flow.
    Navigator.of(context).pop();
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const UpgradeScreen()),
    );
  }

}

// ═══════════════════════════════════════════════════════════════════
//  Tier ownership enum
// ═══════════════════════════════════════════════════════════════════

enum _TierOwnership { free, pro, strongbox }

// ═══════════════════════════════════════════════════════════════════
//  Individual tier card
// ═══════════════════════════════════════════════════════════════════

class _TierCard extends StatelessWidget {
  final String tierName;
  final String priceLabel;
  final String priceSubtitle;
  final String? strikethroughPrice;
  final List<String> features;
  final bool isCurrent;
  final bool isRecommended;
  final VoidCallback? onUpgrade;

  const _TierCard({
    required this.tierName,
    required this.priceLabel,
    required this.priceSubtitle,
    this.strikethroughPrice,
    required this.features,
    required this.isCurrent,
    required this.isRecommended,
    this.onUpgrade,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isRecommended
              ? AppColors.v3AccentPrimary.withValues(alpha: 0.5)
              : AppColors.v3BorderSubtle,
          width: isRecommended ? 1.5 : 1,
        ),
        boxShadow: isRecommended
            ? [
                BoxShadow(
                  color: AppColors.v3AccentPrimary.withValues(alpha: 0.12),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Recommended badge
          if (isRecommended)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: AppColors.v3AccentPrimary.withValues(alpha: 0.12),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: Text(
                l10n.pricingRecommended,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.6,
                  color: AppColors.v3AccentInk,
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.fromLTRB(18, 20, 18, 20),
            child: Column(
              children: [
                // Tier name
                Text(
                  tierName,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                const SizedBox(height: 10),

                // Price row
                if (strikethroughPrice != null) ...[
                  Text(
                    strikethroughPrice!,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextDisabled,
                      decoration: TextDecoration.lineThrough,
                      decorationColor: AppColors.v3TextDisabled,
                      decorationThickness: 2,
                    ),
                  ),
                  const SizedBox(height: 2),
                ],
                Text(
                  priceLabel,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    color: AppColors.v3TextPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  priceSubtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
                const SizedBox(height: 18),

                // Feature list
                ...features.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            LucideIcons.check,
                            size: 15,
                            color: AppColors.v3Success,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              f,
                              style: TextStyle(
                                fontSize: 12,
                                color: AppColors.v3TextSecondary,
                                height: 1.3,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 14),

                // CTA button
                ButtonBox(
                  width: double.infinity,
                  height: 40,
                  child: isCurrent
                      ? OutlinedButton(
                          onPressed: null,
                          style: OutlinedButton.styleFrom(
                            side: BorderSide(
                              color: AppColors.v3TextDisabled,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                            foregroundColor: AppColors.v3TextDisabled,
                          ),
                          child: Text(
                            l10n.pricingCurrent,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        )
                      : FilledButton(
                          onPressed: onUpgrade,
                          style: FilledButton.styleFrom(
                            backgroundColor: AppColors.v3AccentPrimary,
                            foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: Text(
                            l10n.pricingUpgrade,
                            style: const TextStyle(
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
