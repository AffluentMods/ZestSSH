import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:purchases_flutter/purchases_flutter.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/purchase/desktop_upgrade_view.dart';
import 'package:zestssh/ui/screens/purchase/restore_purchases.dart';
import 'package:zestssh/ui/screens/purchase/widgets/plan_comparison_table.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/purchase/no_plans_here.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/button_box.dart';

/// Upgrade screen: what it offers depends on what is owned.
///
/// Products (RevenueCat), each bought once:
///   zestssh-pro ($9.99) → Squeezed: the Pro features
///   zestssh-cloud-sync ($24.99) → Juiced: ZestSSH Cloud, hosted sync storage
///     only (sync itself is free to storage of one's own)
///   zestssh-everything ($29.99) → the Bundle: Squeezed + Juiced
///
/// Display states:
///   Nothing owned:  Squeezed and the Bundle
///   Squeezed only:  Juiced
///   Juiced only:    Squeezed
///   Both:           "You have everything!"
class UpgradeScreen extends ConsumerStatefulWidget {
  const UpgradeScreen({super.key});

  /// A test's word on whether the app shows a computer's upgrade page; null
  /// asks the system the app runs on.
  @visibleForTesting
  static bool? debugDesktop;

  @override
  ConsumerState<UpgradeScreen> createState() => _UpgradeScreenState();
}

class _UpgradeScreenState extends ConsumerState<UpgradeScreen> {
  bool _isPurchasing = false;
  String? _purchasingTier; // 'pro', 'cloud_sync', 'everything'
  bool _showComparison = false;

  /// True when one package belongs to `tier`, judged on BOTH the store
  /// product identifier and the RevenueCat package identifier. Either can
  /// carry the tier name depending on how the dashboard is set up, and
  /// checking only the product id is what made a correctly-configured
  /// package look missing.
  bool _packageMatchesTier(Package pkg, String tier) {
    final ids = [
      pkg.storeProduct.identifier.toLowerCase(),
      pkg.identifier.toLowerCase(),
    ];
    bool any(bool Function(String) test) => ids.any(test);
    final isBundle = any((id) => id.contains('everything') || id.contains('bundle'));
    switch (tier) {
      case 'pro':
        return any((id) => id.contains('pro')) && !isBundle;
      case 'cloud_sync':
        return any((id) => id.contains('cloud') || id.contains('sync')) && !isBundle;
      case 'everything':
        return isBundle;
    }
    return false;
  }

  /// Resolve the package for `tier`, widening the search so a reasonable
  /// dashboard layout still works: the current offering first, then an
  /// offering named for the tier, then any remaining offering.
  Package? _findPackage(Offerings offerings, String tier) {
    final current = offerings.current;
    if (current != null) {
      for (final pkg in current.availablePackages) {
        if (_packageMatchesTier(pkg, tier)) return pkg;
      }
    }
    final named = offerings.all[tier];
    if (named != null) {
      for (final pkg in named.availablePackages) {
        if (_packageMatchesTier(pkg, tier)) return pkg;
      }
      // An offering named for the tier that holds exactly one package is
      // unambiguous even if neither identifier spells the tier out.
      if (named.availablePackages.length == 1) return named.availablePackages.first;
    }
    for (final offering in offerings.all.values) {
      if (identical(offering, current) || identical(offering, named)) continue;
      for (final pkg in offering.availablePackages) {
        if (_packageMatchesTier(pkg, tier)) return pkg;
      }
    }
    return null;
  }

  /// Localized price for a tier, resolved through the SAME matcher the
  /// purchase uses, so the price on the button and the product charged can
  /// never come from different packages.
  String _priceForTier(String tier, AsyncValue<Offerings> offeringsAsync, String fallback) {
    final offerings = offeringsAsync.valueOrNull;
    if (offerings == null) return fallback;
    final pkg = _findPackage(offerings, tier);
    return pkg?.storeProduct.priceString ?? fallback;
  }

  @override
  Widget build(BuildContext context) {
    // A build with no plans to buy (a community build): the page says so.
    // Every "unlock" in the app leads here, so this is the one place.
    if (!zestHasPlans) return const NoPlansHere();
    // Desktop gets a dedicated, native-feeling layout (bento tiers,
    // aurora background, account-status banner, web-checkout flow).
    // The mobile build below is unchanged - it's tuned for portrait
    // and uses the real RevenueCat purchase path.
    if (UpgradeScreen.debugDesktop ?? isDesktopPlatform) {
      return const DesktopUpgradeView();
    }

    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    final offeringsAsync = ref.watch(offeringsProvider);
    final hasBoth = isPro && isCloudSync;
    final hasNothing = !isPro && !isCloudSync;

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.upgradeChooseYourPlan),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: Column(
              children: [
                // ── Header ──────────────────────────────────────
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        AppColors.brandOrange.withValues(alpha: 0.18),
                        AppColors.brandOrange.withValues(alpha: 0.03),
                      ],
                      stops: const [0.4, 1.0],
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.brandOrange.withValues(alpha: 0.15),
                        blurRadius: 24,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: Icon(LucideIcons.rocket,
                      size: 40, color: AppColors.accentInk),
                ),
                const SizedBox(height: 16),
                Text(
                  l10n.upgradeUnlockZestSsh,
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppColors.onBackground,
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.upgradeOneTimePurchase,
                  style: TextStyle(
                      color: AppColors.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 24),

                // ── State-dependent content ─────────────────────
                if (hasBoth)
                  _buildEverythingOwnedState(l10n)
                else if (hasNothing)
                  _buildNothingOwnedState(l10n, offeringsAsync)
                else if (isPro && !isCloudSync)
                  _buildProOnlyState(l10n, offeringsAsync)
                else if (!isPro && isCloudSync)
                  _buildCloudOnlyState(l10n, offeringsAsync),

                const SizedBox(height: 20),

                // ── Compare All Features toggle ─────────────────
                if (!hasBoth) ...[
                  TextButton.icon(
                    onPressed: () =>
                        setState(() => _showComparison = !_showComparison),
                    icon: Icon(
                      _showComparison
                          ? LucideIcons.chevronUp
                          : LucideIcons.chevronDown,
                      size: 18,
                      color: AppColors.accentInk,
                    ),
                    label: Text(
                      _showComparison
                          ? l10n.upgradeHideComparison
                          : l10n.upgradeCompareAllFeatures,
                      style: TextStyle(color: AppColors.accentInk),
                    ),
                  ),
                  if (_showComparison) ...[
                    const SizedBox(height: 12),
                    const PlanComparisonTable(),
                  ],
                ],

                const SizedBox(height: 20),

                // ── Restore purchases ───────────────────────────
                TextButton(
                  onPressed: _isPurchasing ? null : _restorePurchases,
                  child: Text(
                    l10n.upgradeRestorePurchases,
                    style: TextStyle(color: AppColors.textSecondary),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.upgradeOneTimeNoSub,
                  style: TextStyle(
                      color: AppColors.onSurfaceDim, fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  State 1 - User has NOTHING: Show Squeezed + Juiced
  // ═══════════════════════════════════════════════════════════════

  Widget _buildNothingOwnedState(
      AppLocalizations l10n, AsyncValue<Offerings> offeringsAsync) {
    return Column(
      children: [
        // ── Squeezed (Pro) card ───────────────────────────
        _ProductCard(
          title: l10n.upgradeSqueezedTitle,
          subtitle: l10n.upgradeSqueezedSubtitle,
          price: _priceForTier('pro', offeringsAsync, '\$9.99'),
          priceSubtitle: l10n.upgradeLifetime,
          accentColor: AppColors.brandOrange,
          features: [
            l10n.upgradeFeatureUnlimitedConnections,
            l10n.upgradeFeatureAllThemes,
            // (It said unlimited snippets and variable substitution, which
            // every tier has.)
            l10n.deskUpgSqueezedFeatureAutomation,
            l10n.upgradeFeatureUnlimitedMonitors,
            l10n.upgradeFeatureJumpServer,
            l10n.upgradeFeatureSpeechToText,
          ],
          buttonLabel: l10n.upgradeGetSqueezed,
          isPurchasing: _isPurchasing && _purchasingTier == 'pro',
          onPressed: () => _purchase('pro', offeringsAsync),
        ),

        const SizedBox(height: 16),

        // ── Juiced (Everything) card ──────────────────────
        _ProductCard(
          title: l10n.upgradeEverythingTitle,
          subtitle: l10n.upgradeEverythingSubtitle,
          originalPrice: '\$35',
          price: _priceForTier('everything', offeringsAsync, '\$29.99'),
          priceSubtitle: l10n.upgradeLifetime,
          accentColor: AppColors.brandOrange,
          isHighlighted: true,
          badge: l10n.upgradeBestValue,
          headerNote: l10n.upgradeEverythingInSqueezed,
          features: [
            l10n.upgradeFeatureE2ESync,
            l10n.upgradeFeatureSyncConnections,
            l10n.upgradeFeatureSyncSnippets,
            l10n.upgradeFeatureMultiDevice,
            l10n.juicedSevenDevices,
            l10n.upgradeFeatureAutoBackups,
          ],
          buttonLabel: l10n.upgradeGetEverything,
          isPurchasing: _isPurchasing && _purchasingTier == 'everything',
          onPressed: () => _purchase('everything', offeringsAsync),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  State 2 - User has PRO only: Show Cloud Sync upgrade
  // ═══════════════════════════════════════════════════════════════

  Widget _buildProOnlyState(
      AppLocalizations l10n, AsyncValue<Offerings> offeringsAsync) {
    return Column(
      children: [
        // Owned badge
        _OwnedBadge(
          label: l10n.upgradeSqueezedTitle,
          color: AppColors.brandOrange,
        ),
        const SizedBox(height: 16),

        // Cloud Sync upgrade card
        _ProductCard(
          title: l10n.upgradeFeatureCloudSync,
          subtitle: l10n.upgradeAlreadyHavePro,
          price: _priceForTier('cloud_sync', offeringsAsync, '\$24.99'),
          priceSubtitle: l10n.upgradeLifetime,
          accentColor: AppColors.brandOrange,
          isHighlighted: true,
          features: [
            l10n.upgradeFeatureE2ESync,
            l10n.upgradeFeatureSyncConnections,
            l10n.upgradeFeatureSyncSnippets,
            l10n.upgradeFeatureMultiDevice,
            l10n.juicedSevenDevices,
            l10n.upgradeFeatureAutoBackups,
          ],
          buttonLabel: l10n.upgradeAddCloudSync,
          isPurchasing: _isPurchasing && _purchasingTier == 'cloud_sync',
          onPressed: () => _purchase('cloud_sync', offeringsAsync),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  State 3 - User has CLOUD SYNC only: Show Squeezed
  // ═══════════════════════════════════════════════════════════════

  Widget _buildCloudOnlyState(
      AppLocalizations l10n, AsyncValue<Offerings> offeringsAsync) {
    return Column(
      children: [
        // Owned badge
        _OwnedBadge(
          label: l10n.upgradeFeatureCloudSync,
          color: AppColors.brandOrange,
        ),
        const SizedBox(height: 16),

        // Squeezed (Pro) card
        _ProductCard(
          title: l10n.upgradeSqueezedTitle,
          subtitle: l10n.upgradeSqueezedSubtitle,
          price: _priceForTier('pro', offeringsAsync, '\$9.99'),
          priceSubtitle: l10n.upgradeLifetime,
          accentColor: AppColors.brandOrange,
          isHighlighted: true,
          features: [
            l10n.upgradeFeatureUnlimitedConnections,
            l10n.upgradeFeatureAllThemes,
            // (It said unlimited snippets and variable substitution, which
            // every tier has.)
            l10n.deskUpgSqueezedFeatureAutomation,
            l10n.upgradeFeatureUnlimitedMonitors,
            l10n.upgradeFeatureJumpServer,
            l10n.upgradeFeatureSpeechToText,
          ],
          buttonLabel: l10n.upgradeGetSqueezed,
          isPurchasing: _isPurchasing && _purchasingTier == 'pro',
          onPressed: () => _purchase('pro', offeringsAsync),
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  State 4 - User has BOTH: Celebration screen
  // ═══════════════════════════════════════════════════════════════

  Widget _buildEverythingOwnedState(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 32),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.success.withValues(alpha: 0.15),
            ),
            child: Icon(
              LucideIcons.checkCircle2,
              size: 48,
              color: AppColors.success,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.upgradeYouHaveEverything,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.upgradeYouHaveEverythingDesc,
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 14,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),

          // Owned badges
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _OwnedChip(
                  label: l10n.upgradeSqueezedTitle,
                  color: AppColors.brandOrange),
              const SizedBox(width: 10),
              _OwnedChip(
                  label: l10n.upgradeFeatureCloudSync,
                  color: AppColors.brandOrange),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════
  //  Purchase logic
  // ═══════════════════════════════════════════════════════════════

  Future<void> _purchase(
      String tier, AsyncValue<Offerings> offeringsAsync) async {
    // Desktop short-circuit - same reason as [_restorePurchases].
    // Without this, clicking Buy on Windows triggers the offerings
    // fetch which hangs forever ("Opening store…" with no resolution)
    // because RevenueCat isn't initialised.
    if (!PurchaseService.isPlatformSupported) {
      _showDesktopPurchaseUnavailable();
      return;
    }

    final l10n = AppLocalizations.of(context)!;
    final offerings = offeringsAsync.valueOrNull;
    if (offerings == null) {
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.upgradeStoreNotAvailable,
          isError: true,
        );
      }
      return;
    }

    // Find the package for this tier. Searched in widening order so a
    // reasonable RevenueCat dashboard layout still resolves:
    //   1. the current offering, matched on product id OR package id
    //   2. an offering literally named for the tier
    //   3. any other offering's packages
    // Matching on the PACKAGE identifier as well as the product identifier
    // matters: a dashboard that names its package "pro" but attaches a
    // differently-named product used to fall all the way through to the
    // "not found" error even though the package was sitting right there.
    final package = _findPackage(offerings, tier);

    if (package == null) {
      // No package resolved. This is a store/dashboard condition, not
      // something the user did, so log the detail for us and show them
      // plain, actionable copy instead of developer jargon (an App Store
      // reviewer sees this screen too).
      AppLogger.warning(
        'purchase: no package for tier "$tier". '
        'current=${offerings.current?.identifier ?? "(none)"} '
        'offerings=${offerings.all.keys.toList()} '
        'products=${offerings.current?.availablePackages.map((p) => p.storeProduct.identifier).toList() ?? const []}',
      );
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.upgradePackageNotFound,
          isError: true,
        );
      }
      return;
    }

    setState(() {
      _isPurchasing = true;
      _purchasingTier = tier;
    });

    try {
      await PurchaseService.purchasePackage(package);
      await ref.read(isProProvider.notifier).refresh();
      await ref.read(isCloudSyncProvider.notifier).refresh();

      if (mounted) {
        final label = switch (tier) {
          'pro' => l10n.upgradeSqueezedPro,
          'cloud_sync' => l10n.upgradeJuicedCloudSync,
          'everything' => l10n.upgradeSqueezedPlusJuiced,
          _ => l10n.appName,
        };
        showTopSnackBar(
          context,
          l10n.upgradeUnlocked(label),
          isSuccess: true,
        );
        Navigator.of(context).pop(true);
      }
    } on PlatformException catch (e) {
      AppLogger.error('Purchase failed', e);
      if (mounted) {
        final isUserCancelled = e.code == '1' ||
            e.message?.contains('cancelled') == true ||
            e.message?.contains('canceled') == true;

        if (!isUserCancelled) {
          showTopSnackBar(
            context,
            l10n.upgradePurchaseNotDone,
            isError: true,
            details: 'The store: ${e.code}: ${e.message ?? ''}',
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPurchasing = false;
          _purchasingTier = null;
        });
      }
    }
  }

  Future<void> _restorePurchases() async {
    // Desktop short-circuit - RevenueCat's Flutter SDK doesn't
    // support Windows / Linux / macOS, so we can't actually talk
    // to the store from here.  Surface a clear explanation instead
    // of the generic "Store not available" error the SDK throws,
    // and offer the cross-device workaround (sign into Cloud Sync
    // to inherit the entitlement from mobile).
    if (!PurchaseService.isPlatformSupported) {
      _showDesktopPurchaseUnavailable();
      return;
    }

    setState(() => _isPurchasing = true);
    try {
      // The app's one restore (restore_purchases.dart), as a locked page's
      // card offers it too.
      await ref.read(purchaseRestorerProvider)(context);
    } finally {
      if (mounted) setState(() => _isPurchasing = false);
    }
  }

  /// Show a dialog explaining the desktop purchase flow:
  ///   1) Buy on the web - opens `zestssh.com/upgrade`, where the
  ///      purchase goes to the account signed in on the website.
  ///      The website redirects back to
  ///      `zestssh://upgrade-complete` once payment captures.
  ///   2) Buy on mobile - open Android/iOS, purchase, then sign
  ///      into Cloud Sync on desktop and the entitlement mirrors.
  ///   3) "I already purchased" - manual refresh that re-queries
  ///      the backend (for users who killed the browser tab before
  ///      the deep-link redirect could fire, or who paid on a
  ///      different device entirely).
  void _showDesktopPurchaseUnavailable() {
    final l10n = AppLocalizations.of(context)!;
    // In the app's dialog (the dialog rules, 3.4): I already purchased is the
    // side option, a link bottom left (it stood in the body), and the one
    // warning in its amber sentence.
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Consumer(builder: (ctx, dialogRef, _) {
        final user = dialogRef.watch(currentUserProvider);
        final signedIn = user != null;

        Future<void> alreadyPurchased() async {
          await dialogRef.read(isProProvider.notifier).refresh();
          await dialogRef.read(isCloudSyncProvider.notifier).refresh();
          if (!ctx.mounted || !mounted) return;
          final hasPro = dialogRef.read(isProProvider);
          final hasSync = dialogRef.read(isCloudSyncProvider);
          if (hasPro || hasSync) {
            Navigator.pop(ctx);
            showTopSnackBar(context, l10n.upgradePurchaseConfirmed, isSuccess: true);
          } else {
            showTopSnackBar(context, l10n.upgradeNoPurchaseForAccountYet);
          }
        }

        return ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.sparkles,
          title: l10n.upgradeUnlockDialogTitle,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.upgradeDesktopPurchaseExplanation,
                style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
              ),
              const SizedBox(height: 12),
              if (!signedIn)
                ZestCallout(l10n.upgradeSignIntoCloudSyncFirst)
              else
                Text(
                  // The account masked in recording mode, as everywhere
                  // else (it was shown as it is).
                  l10n.upgradeSignedInAs(Redactable.account(user.email ?? user.uid).displayIn(dialogRef)),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3TextSecondary),
                ),
            ],
          ),
          // Manual refresh - for users who already paid on a different
          // device or whose browser didn't bounce back via the
          // upgrade-complete deep link.
          tertiaryKey: const ValueKey('upgrade-already-purchased'),
          tertiaryAction: (label: l10n.upgradeIAlreadyPurchased, onPressed: signedIn ? alreadyPurchased : null),
          secondaryAction: (label: l10n.close, onPressed: () => Navigator.pop(ctx)),
          primaryAction: (
            label: l10n.upgradeOpenWebUpgrade,
            icon: LucideIcons.externalLink,
            onPressed: () {
              Navigator.pop(ctx);
              final url = PurchaseService.buildWebUpgradeUrl();
              launchUrl(url, mode: LaunchMode.externalApplication);
            },
          ),
        );
      }),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Product Card - a single purchasable tier
// ═══════════════════════════════════════════════════════════════════

class _ProductCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String price;
  final String? originalPrice;
  final String priceSubtitle;
  final Color accentColor;
  final bool isHighlighted;
  final String? badge;
  final String? headerNote;
  final List<String> features;
  final String buttonLabel;
  final bool isPurchasing;
  final VoidCallback? onPressed;

  const _ProductCard({
    required this.title,
    required this.subtitle,
    required this.price,
    this.originalPrice,
    required this.priceSubtitle,
    required this.accentColor,
    this.isHighlighted = false,
    this.badge,
    this.headerNote,
    required this.features,
    required this.buttonLabel,
    this.isPurchasing = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isHighlighted
              ? accentColor.withValues(alpha: 0.5)
              : AppColors.divider,
          width: isHighlighted ? 1.5 : 1,
        ),
        color: AppColors.surface,
        boxShadow: isHighlighted
            ? [
                BoxShadow(
                  color: accentColor.withValues(alpha: 0.1),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, 4),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.2),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Column(
        children: [
          // ── Badge bar ───────────────────────────────────
          if (badge != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 6),
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.15),
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(14)),
              ),
              child: Text(
                badge!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: accentColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ),

          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              children: [
                // ── Title + subtitle ──────────────────────
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: accentColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 12),

                // ── Price ─────────────────────────────────
                _PriceLine(
                  original: originalPrice == null
                      ? null
                      : Text(
                          originalPrice!,
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textSecondary.withValues(alpha: 0.7),
                            decoration: TextDecoration.lineThrough,
                            decorationColor: AppColors.textSecondary.withValues(alpha: 0.7),
                            decorationThickness: 2,
                          ),
                        ),
                  price: Text(
                    price,
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: AppColors.onBackground,
                    ),
                  ),
                  words: Text(
                    priceSubtitle,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // ── Header note (e.g. "Everything in Squeezed, plus:") ──
                if (headerNote != null) ...[
                  Text(
                    headerNote!,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: accentColor.withValues(alpha: 0.8),
                    ),
                  ),
                  const SizedBox(height: 10),
                ],

                // ── Features ──────────────────────────────
                ...features.map((f) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        children: [
                          Icon(
                            LucideIcons.checkCircle2,
                            size: 18,
                            color: accentColor.withValues(alpha: 0.8),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              f,
                              style: TextStyle(
                                fontSize: 13,
                                color: AppColors.onSurface,
                              ),
                            ),
                          ),
                        ],
                      ),
                    )),

                const SizedBox(height: 12),

                // ── CTA button ────────────────────────────
                ButtonBox(
                  width: double.infinity,
                  height: 50,
                  child: isPurchasing
                      ? const Center(
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              colors: [
                                accentColor,
                                AppColors.orangeLight,
                              ],
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: accentColor.withValues(alpha: 0.35),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: FilledButton(
                            onPressed: onPressed,
                            style: FilledButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              padding:
                                  const EdgeInsets.symmetric(vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              buttonLabel,
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                                color: Colors.white,
                              ),
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

// ═══════════════════════════════════════════════════════════════════
//  Owned Badge - shows what the user already has
// ═══════════════════════════════════════════════════════════════════

class _OwnedBadge extends StatelessWidget {
  final String label;
  final Color color;

  const _OwnedBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        color: color.withValues(alpha: 0.1),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.checkCircle2, size: 18, color: color),
          const SizedBox(width: 8),
          Text(
            l10n.upgradeOwnedBadge(label),
            style: TextStyle(
              color: color,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Owned Chip - small badge for the celebration state
// ═══════════════════════════════════════════════════════════════════

class _OwnedChip extends StatelessWidget {
  final String label;
  final Color color;

  const _OwnedChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: color.withValues(alpha: 0.12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.checkCircle2, size: 14, color: color),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// A plan's price, the one it replaces and its words ("lifetime"): on their
/// baseline on one line where they fit, and where they do not, wrapped onto
/// the next (on one line they ran out of the card from 1.3 times the text
/// size, in German, Spanish, Russian and Arabic).
class _PriceLine extends StatelessWidget {
  const _PriceLine({required this.original, required this.price, required this.words});

  final Text? original;
  final Text price;
  final Text words;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      double width(Text text) {
        final painter = TextPainter(
          text: TextSpan(text: text.data, style: DefaultTextStyle.of(context).style.merge(text.style)),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final w = painter.width;
        painter.dispose();
        return w;
      }

      final line = (original == null ? 0 : width(original!) + 8) + width(price) + 4 + width(words);
      if (line <= box.maxWidth) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            if (original != null) ...[original!, const SizedBox(width: 8)],
            price,
            const SizedBox(width: 4),
            words,
          ],
        );
      }
      return Wrap(
        key: const ValueKey('upgrade-price-wrapped'),
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.end,
        spacing: 4,
        runSpacing: 2,
        children: [
          if (original != null) Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: original),
          price,
          words,
        ],
      );
    });
  }
}
