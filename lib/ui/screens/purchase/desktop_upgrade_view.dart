import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/purchase/restore_purchases.dart';
import 'package:zestssh/utils/around_value.dart';

// ════════════════════════════════════════════════════════════════════
//  Palette (mirrors the redesign's design tokens)
// ════════════════════════════════════════════════════════════════════

// The one theme-following token on this otherwise fixed marketing palette:
// tracks the active theme accent (AppColors.v3AccentPrimary == the scheme's
// primary), so the upgrade screen's accent recolours with the chosen theme
// instead of staying orange. Default Dark's primary IS #FF7A1A, so the default
// look is unchanged. Not const, so const widgets that consume it drop `const`.
Color get _kAccent => AppColors.v3AccentPrimary;
const Color _kGreen = Color(0xFF22C55E);
const Color _kGreenText = Color(0xFF5CD48A);

const Color _t1 = Color(0xFFEDEDED);
const Color _t2 = Color(0xFF9A9A9A);
const Color _t3 = Color(0xFF666666);
const Color _t4 = Color(0xFF4A4A4A);

const Color _bd = Color(0x12FFFFFF); // white .07
const Color _bd2 = Color(0x21FFFFFF); // white .13
const Color _hair = Color(0x0AFFFFFF); // white .04

const Color _surf = Color(0xFF141414);
const Color _valueText = Color(0xFFDADADA);

// ── Feature copy ────────────────────────────────────────────────────

List<String> _squeezedFeatures(AppLocalizations l10n) => [
  l10n.deskUpgSqueezedFeatureSessions,
  l10n.upgradeFeatureJumpServer,
  l10n.deskUpgSqueezedFeatureAutomation,
  l10n.deskUpgSqueezedFeatureSplit,
  l10n.deskUpgSqueezedFeatureTokens,
  l10n.deskUpgSqueezedFeatureThemes,
];
String _squeezedMore(AppLocalizations l10n) => l10n.deskUpgSqueezedMore;

// Juiced is the hosted ZestSSH Cloud storage only. Sync, automatic backups
// and recovery keys are free on every backend, so they are not listed here.
List<String> _juicedFeatures(AppLocalizations l10n) => [
  l10n.deskUpgJuicedFeatureSync,
  l10n.juicedSevenDevices,
  l10n.deskUpgJuicedFeatureShare,
  l10n.deskUpgJuicedFeatureApproval,
];
List<String> _juicedOfferFeatures(AppLocalizations l10n) => [
  l10n.deskUpgJuicedFeatureSync,
  l10n.juicedSevenDevices,
  l10n.deskUpgJuicedOfferFeatureShareRoles,
  l10n.deskUpgJuicedFeatureApproval,
];

String _encryptionDisc(AppLocalizations l10n) => l10n.deskUpgEncryptionDisc;

/// Desktop-native upgrade / license screen.
///
/// One layout per entitlement state, driven by the two ownership
/// booleans ([isProProvider] = Squeezed, [isCloudSyncProvider] = Juiced):
///
/// * **Free (owns nothing)** → two selectable products; the bundle is a
///   running-total discount, not a third card.
/// * **Owns Squeezed** → a single offer for Juiced with the credit math.
/// * **Owns Juiced** → a single offer for Squeezed, completing the bundle.
/// * **Owns both** → the store is gone; a license screen with no prices.
///
/// The aurora + dot-grid backdrop is preserved across all states.
class DesktopUpgradeView extends ConsumerStatefulWidget {
  const DesktopUpgradeView({super.key});

  @override
  ConsumerState<DesktopUpgradeView> createState() =>
      _DesktopUpgradeViewState();
}

class _DesktopUpgradeViewState extends ConsumerState<DesktopUpgradeView>
    with TickerProviderStateMixin {
  late final AnimationController _entrance;
  bool _refreshing = false;

  // Screen A selection state.
  bool _pickPro = false;
  bool _pickSync = false;

  @override
  void initState() {
    super.initState();
    _entrance = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
  }

  @override
  void dispose() {
    _entrance.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final isCloudSync = ref.watch(isCloudSyncProvider);
    final user = ref.watch(currentUserProvider);
    final hasBoth = isPro && isCloudSync;
    // The account and this machine are masked by a plain function below:
    // rebuilt when recording mode flips.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);

    // ── State → title + content ────────────────────────────────────
    final String title;
    final String? subtitle;
    final Widget content;

    if (hasBoth) {
      title = l10n.deskUpgLicenseTitle;
      subtitle = null;
      content = _LicenseView(
        user: user,
        refreshing: _refreshing,
        onRestore: _handleRefresh,
        onHelp: _openHelp,
      );
    } else if (isPro) {
      // Owns Squeezed → add Juiced.
      title = l10n.deskUpgAddJuiced;
      subtitle = l10n.deskUpgPayOncePeriod;
      content = _AddOnView(
        offerName: 'Juiced',
        offerTagline: l10n.deskUpgJuicedOfferTagline,
        // Its own price: one at a time, each half costs its own; only the
        // Bundle, bought at once, costs less (the page said $20.00, a
        // credit no checkout ever gave).
        price: '\$24.99',
        features: _juicedOfferFeatures(l10n),
        showEncryptionDisc: true,
        showSqueezedMore: false,
        ctaLabel: l10n.deskUpgAddJuiced,
        onCta: () => _openWebCheckout('cloud_sync'),
        footbarTrailing: l10n.deskUpgWhatsInSqueezed,
      );
    } else if (isCloudSync) {
      // Owns Juiced → add Squeezed (mirrored).
      title = l10n.deskUpgAddSqueezed;
      subtitle = l10n.deskUpgPayOncePeriod;
      content = _AddOnView(
        offerName: 'Squeezed',
        offerTagline: l10n.deskUpgSqueezedOfferTagline,
        price: '\$9.99',
        features: _squeezedFeatures(l10n),
        showEncryptionDisc: false,
        showSqueezedMore: true,
        ctaLabel: l10n.deskUpgAddSqueezed,
        onCta: () => _openWebCheckout('pro'),
        footbarTrailing: l10n.deskUpgWhatsInJuiced,
      );
    } else {
      // Owns nothing → two selectable products.
      title = l10n.deskUpgOwnZestssh;
      subtitle = l10n.deskUpgPayOncePeriod;
      content = _FreeView(
        pickPro: _pickPro,
        pickSync: _pickSync,
        onTogglePro: () => setState(() => _pickPro = !_pickPro),
        onToggleSync: () => setState(() => _pickSync = !_pickSync),
        onContinue: _continueFree,
      );
    }

    return Scaffold(
      backgroundColor: const Color(0xFF0B0C0E),
      body: Stack(
        children: [
          // ── Layer 1: aurora mesh background (unchanged) ───────────
          const _AuroraBackdrop(),

          // ── Layer 2: faint dot-grid overlay (unchanged) ──────────
          const Positioned.fill(
            child: IgnorePointer(child: _DotGrid()),
          ),

          // ── Layer 3: content ──────────────────────────────────────
          SafeArea(
            child: Column(
              children: [
                _TitleBar(
                  title: title,
                  subtitle: subtitle,
                  refreshing: _refreshing,
                  onRestore: _refreshing ? null : _handleRefresh,
                  onHelp: _openHelp,
                  onClose: () => Navigator.of(context).pop(),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(40, 30, 40, 44),
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 860),
                        child: _AnimatedReveal(
                          controller: _entrance,
                          delay: 0,
                          child: content,
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

  void _continueFree() {
    if (_pickPro && _pickSync) {
      _openWebCheckout('everything');
    } else if (_pickPro) {
      _openWebCheckout('pro');
    } else if (_pickSync) {
      _openWebCheckout('cloud_sync');
    }
  }

  void _openWebCheckout(String tier) {
    final url = PurchaseService.buildWebUpgradeUrl(tier: tier);
    launchUrl(url, mode: LaunchMode.externalApplication);
  }

  void _openHelp() {
    launchUrl(
      Uri.parse('mailto:$kZestSupportAddress'),
      mode: LaunchMode.externalApplication,
    );
  }

  Future<void> _handleRefresh() async {
    setState(() => _refreshing = true);
    try {
      // The app's one restore (restore_purchases.dart): on a computer, the
      // account's plans read again, and what came of it.
      await ref.read(purchaseRestorerProvider)(context);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }
}

// ════════════════════════════════════════════════════════════════════
//  Title bar
// ════════════════════════════════════════════════════════════════════

class _TitleBar extends StatelessWidget {
  const _TitleBar({
    required this.title,
    required this.subtitle,
    required this.refreshing,
    required this.onRestore,
    required this.onHelp,
    required this.onClose,
  });

  final String title;
  final String? subtitle;
  final bool refreshing;
  final VoidCallback? onRestore;
  final VoidCallback onHelp;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: Color(0xE60A0A0A),
        border: Border(bottom: BorderSide(color: _bd)),
      ),
      child: Row(
        children: [
          Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: _kAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: _kAccent.withValues(alpha: 0.4)),
            ),
            child: Icon(LucideIcons.zap, size: 13, color: _kAccent),
          ),
          const SizedBox(width: 10),
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
              letterSpacing: -0.1,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(width: 9),
            const _DotSeparator(),
            const SizedBox(width: 9),
            Text(
              subtitle!,
              style: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12,
                color: _t3,
              ),
            ),
          ],
          const Spacer(),
          // Restore stays reachable in EVERY state - critical after a
          // reinstall. It is the same action as "I already purchased".
          _SmallButton(
            label: refreshing ? l10n.deskUpgChecking : l10n.deskUpgRestorePurchases,
            icon: LucideIcons.refreshCw,
            ghost: true,
            onTap: onRestore,
          ),
          const SizedBox(width: 8),
          _SmallButton(
            label: l10n.deskUpgHelp,
            icon: LucideIcons.helpCircle,
            ghost: true,
            onTap: onHelp,
          ),
          const SizedBox(width: 12),
          _CloseButton(onPressed: onClose),
        ],
      ),
    );
  }
}

class _DotSeparator extends StatelessWidget {
  const _DotSeparator();
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 3,
      height: 3,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.25),
      ),
    );
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.close,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 28,
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? const Color(0xFFEF4444).withValues(alpha: 0.18)
                  : Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: _hover
                    ? const Color(0xFFEF4444).withValues(alpha: 0.5)
                    : Colors.white.withValues(alpha: 0.08),
              ),
            ),
            child: Icon(
              LucideIcons.x,
              size: 14,
              color: _hover
                  ? const Color(0xFFEF4444)
                  : Colors.white.withValues(alpha: 0.6),
            ),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Screen A - owns nothing: two selectable products
// ════════════════════════════════════════════════════════════════════

class _FreeView extends StatelessWidget {
  const _FreeView({
    required this.pickPro,
    required this.pickSync,
    required this.onTogglePro,
    required this.onToggleSync,
    required this.onContinue,
  });

  final bool pickPro;
  final bool pickSync;
  final VoidCallback onTogglePro;
  final VoidCallback onToggleSync;
  final VoidCallback onContinue;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.deskUpgPickWhatYouNeed,
          style: const TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 26,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.5,
            height: 1.2,
          ),
        ),
        const SizedBox(height: 8),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Text(
            l10n.deskUpgFreeExplainer,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13.5,
              height: 1.6,
              color: _t2,
            ),
          ),
        ),
        const SizedBox(height: 22),

        // Two products, equal height.
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _SelectCard(
                  name: 'Squeezed',
                  tagline: l10n.deskUpgSqueezedTagline,
                  price: '\$9.99',
                  selected: pickPro,
                  onTap: onTogglePro,
                  features: _squeezedFeatures(l10n),
                  more: _squeezedMore(l10n),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _SelectCard(
                  name: 'Juiced',
                  tagline: l10n.deskUpgJuicedTagline,
                  price: '\$24.99',
                  selected: pickSync,
                  onTap: onToggleSync,
                  features: _juicedFeatures(l10n),
                  disc: _encryptionDisc(l10n),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 18),
        _buildSummary(l10n),

        const SizedBox(height: 16),
        const _TrustStrip(),

        const SizedBox(height: 18),
        _Footbar(
          icon: LucideIcons.lock,
          text: l10n.deskUpgFreeFootbarText,
          trailing: l10n.deskUpgCompareWithFree,
        ),
      ],
    );
  }

  Widget _buildSummary(AppLocalizations l10n) {
    final both = pickPro && pickSync;
    final any = pickPro || pickSync;

    final lines = <_SumLine>[];
    if (!any) {
      lines.add(_SumLine(
        label: l10n.deskUpgNothingSelected,
        value: l10n.deskUpgChooseOneOrBoth,
        valueColor: _t4,
      ));
      lines.add(_SumLine(
        label: l10n.deskUpgBothTogetherSaves,
        labelColor: _t4),
      );
    } else {
      if (pickPro) {
        lines.add(const _SumLine(label: 'Squeezed', value: '\$9.99'));
      }
      if (pickSync) {
        lines.add(const _SumLine(label: 'Juiced', value: '\$24.99'));
      }
      if (both) {
        lines.add(_SumLine(
          // $9.99 + $24.99 - $4.99 = $29.99 (it said -$5.00, which does not
          // add up).
          label: l10n.deskUpgBundleDiscount,
          value: '-\$4.99',
          valueColor: _kGreenText,
        ));
      } else if (pickPro) {
        lines.add(_SumLine(
          label: l10n.deskUpgAddJuicedToSave,
          labelColor: _kAccent),
        );
      } else {
        lines.add(_SumLine(
          label: l10n.deskUpgAddSqueezedToSave,
          labelColor: _kAccent),
        );
      }
    }

    final String amount;
    if (both) {
      amount = '\$29.99';
    } else if (pickPro) {
      amount = '\$9.99';
    } else if (pickSync) {
      amount = '\$24.99';
    } else {
      amount = '\$0.00';
    }

    return _SummaryBar(
      armed: both,
      lines: lines,
      strike: both ? '\$34.98' : null,
      amount: amount,
      buttonLabel: l10n.deskUpgContinue,
      onPressed: any ? onContinue : null,
    );
  }
}

/// A selectable product card with a leading checkbox (Screen A).
class _SelectCard extends StatefulWidget {
  const _SelectCard({
    required this.name,
    required this.tagline,
    required this.price,
    required this.selected,
    required this.onTap,
    required this.features,
    this.more,
    this.disc,
  });

  final String name;
  final String tagline;
  final String price;
  final bool selected;
  final VoidCallback onTap;
  final List<String> features;
  final String? more;
  final String? disc;

  @override
  State<_SelectCard> createState() => _SelectCardState();
}

class _SelectCardState extends State<_SelectCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF161310) : _surf,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected
                  ? _kAccent.withValues(alpha: 0.55)
                  : (_hover ? _bd2 : _bd),
            ),
            boxShadow: selected
                ? [
                    BoxShadow(
                      color: _kAccent.withValues(alpha: 0.14),
                      blurRadius: 0,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: _Checkbox(on: selected),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.name,
                          style: const TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.1,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          widget.tagline,
                          style: const TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 12,
                            color: _t3,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _PriceBlock(price: widget.price),
                ],
              ),
              const SizedBox(height: 15),
              for (final f in widget.features) ...[
                _FeatureLine(text: f),
                const SizedBox(height: 8),
              ],
              if (widget.more != null)
                Padding(
                  padding: const EdgeInsets.only(left: 22, top: 1),
                  child: Text(
                    widget.more!,
                    style: const TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 11.5,
                      color: _t3,
                    ),
                  ),
                ),
              if (widget.disc != null) _DiscRow(text: widget.disc!),
            ],
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Screen B (and mirror) - a single add-on offer
// ════════════════════════════════════════════════════════════════════

class _AddOnView extends StatelessWidget {
  const _AddOnView({
    required this.offerName,
    required this.offerTagline,
    required this.price,
    required this.features,
    required this.showEncryptionDisc,
    required this.showSqueezedMore,
    required this.ctaLabel,
    required this.onCta,
    required this.footbarTrailing,
  });

  final String offerName;
  final String offerTagline;
  final String price;
  final List<String> features;
  final bool showEncryptionDisc;
  final bool showSqueezedMore;
  final String ctaLabel;
  final VoidCallback onCta;
  final String footbarTrailing;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The owned product is stated exactly once, as a single line.
    final ownedName = offerName == 'Juiced' ? 'Squeezed' : 'Juiced';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _OwnedStrip(productName: ownedName),
        const SizedBox(height: 22),
        _OfferCard(
          name: offerName,
          tagline: offerTagline,
          price: price,
          features: features,
          disc: showEncryptionDisc ? _encryptionDisc(l10n) : null,
          more: showSqueezedMore ? _squeezedMore(l10n) : null,
        ),
        const SizedBox(height: 18),
        _SummaryBar(
          armed: true,
          lines: [_SumLine(label: offerName, value: price)],
          amount: price,
          buttonLabel: ctaLabel,
          onPressed: onCta,
        ),
        const SizedBox(height: 14),
        _Callout(
          title: l10n.deskUpgAddonAllYouNeed(offerName),
          body: l10n.deskUpgAddonNotTheBundle(ownedName, offerName),
        ),
        const SizedBox(height: 18),
        _Footbar(
          text: l10n.deskUpgAddonFootbarText,
          trailing: footbarTrailing,
        ),
      ],
    );
  }
}

/// The single-line "you already own X" strip.
class _OwnedStrip extends StatelessWidget {
  const _OwnedStrip({required this.productName});
  final String productName;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
      decoration: BoxDecoration(
        color: _kGreen.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _kGreen.withValues(alpha: 0.2)),
      ),
      child: Row(
        children: [
          const _Checkbox(on: false, owned: true),
          const SizedBox(width: 11),
          Text.rich(
            TextSpan(
              style: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12.5,
                color: _t1,
              ),
              children: [
                TextSpan(text: aroundValue(l10n.deskUpgYouOwn(aroundValueMarker)).$1),
                TextSpan(
                  text: productName,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
                TextSpan(text: aroundValue(l10n.deskUpgYouOwn(aroundValueMarker)).$2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The single always-highlighted offer card (Screen B).
class _OfferCard extends StatelessWidget {
  const _OfferCard({
    required this.name,
    required this.tagline,
    required this.price,
    required this.features,
    this.disc,
    this.more,
  });

  final String name;
  final String tagline;
  final String price;
  final List<String> features;
  final String? disc;
  final String? more;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 17, 18, 18),
      decoration: BoxDecoration(
        color: const Color(0xFF161310),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _kAccent.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: _kAccent.withValues(alpha: 0.14),
            blurRadius: 0,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          name,
                          style: const TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                            letterSpacing: -0.1,
                          ),
                        ),
                        const SizedBox(width: 9),
                        _AccentBadge(label: l10n.deskUpgCompletesTheBundle),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(
                      tagline,
                      style: const TextStyle(
                        fontFamily: 'GeistSans',
                        fontSize: 12,
                        color: _t3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              _PriceBlock(price: price),
            ],
          ),
          const SizedBox(height: 15),
          for (final f in features) ...[
            _FeatureLine(text: f),
            const SizedBox(height: 8),
          ],
          if (more != null)
            Padding(
              padding: const EdgeInsets.only(left: 22, top: 1),
              child: Text(
                more!,
                style: const TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 11.5,
                  color: _t3,
                ),
              ),
            ),
          if (disc != null) _DiscRow(text: disc!),
        ],
      ),
    );
  }
}

/// Under the add-on offer: the half on offer is all that is needed, as the
/// Bundle would charge for the owned half again.
class _Callout extends StatelessWidget {
  const _Callout({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _bd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.info, size: 13, color: _t2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: _t2,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            body,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 11.5,
              height: 1.6,
              color: _t2,
            ),
          ),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Screen C - owns everything: the license page (no store)
// ════════════════════════════════════════════════════════════════════

class _LicenseView extends StatelessWidget {
  const _LicenseView({
    required this.user,
    required this.refreshing,
    required this.onRestore,
    required this.onHelp,
  });

  final UserProfile? user;
  final bool refreshing;
  final VoidCallback onRestore;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The account is an identifier: masked in recording mode, as everywhere
    // else (the page showed it as it is, on a recording of the screen too).
    final id = user?.email ?? user?.uid;
    final account = id == null ? l10n.deskUpgLocalLicense : Redactable.account(id).display;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Hero - headline generated from the entitlement set.
        Container(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF171310), Color(0xFF121212)],
            ),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: _kAccent.withValues(alpha: 0.3)),
          ),
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.deskUpgYouOwnAll,
                    style: const TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                      letterSpacing: -0.4,
                    ),
                  ),
                  const SizedBox(height: 7),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 520),
                    child: Text(
                      l10n.deskUpgLicenseHeroBody,
                      style: const TextStyle(
                        fontFamily: 'GeistSans',
                        fontSize: 13,
                        height: 1.6,
                        color: _t2,
                      ),
                    ),
                  ),
                ],
              ),
              Positioned(
                top: 0,
                right: 0,
                child: _OwnedBadge(label: l10n.deskUpgEverythingOwned),
              ),
            ],
          ),
        ),

        const SizedBox(height: 16),

        // What you own - derived from the two entitlement booleans, plus
        // the account. No dates or prices: the client has no receipts.
        _LicGrid(account: account),

        const SizedBox(height: 16),

        // This device only - no fabricated device roster.
        _Panel(
          title: l10n.deskUpgThisDevice,
          children: [const _DeviceRow()],
        ),

        const SizedBox(height: 16),

        // Manage - restore + help, the only two real actions here.
        _Panel(
          title: l10n.deskUpgManage,
          children: [
            _PanelRow(
              title: l10n.deskUpgRestoreOnNewDevice,
              subtitle: l10n.deskUpgSignsLicenseIn,
              trailing: _SmallButton(
                label: refreshing ? l10n.deskUpgChecking : l10n.deskUpgRestore,
                onTap: refreshing ? null : onRestore,
              ),
            ),
            _PanelRow(
              title: l10n.deskUpgGetHelp,
              subtitle: l10n.deskUpgEmailSupport,
              trailing: _SmallButton(
                label: l10n.deskUpgContactSupport,
                ghost: true,
                onTap: onHelp,
              ),
            ),
          ],
        ),

        const SizedBox(height: 18),

        _Footbar(
          text: l10n.deskUpgThanksFooter,
        ),
      ],
    );
  }
}

/// The segmented "what you own" grid (Screen C).
class _LicGrid extends StatelessWidget {
  const _LicGrid({required this.account});
  final String account;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _bd),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _LicCell(
                k: 'SQUEEZED',
                v: l10n.deskUpgOwned,
                sub: l10n.deskUpgProFeatures,
              ),
            ),
            const _VDivider(),
            Expanded(
              child: _LicCell(
                k: 'JUICED',
                v: l10n.deskUpgOwned,
                sub: l10n.deskUpgCloudSync,
              ),
            ),
            const _VDivider(),
            Expanded(
              child: _LicCell(
                k: l10n.deskUpgAccountLabel,
                v: account,
                valueSmall: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LicCell extends StatelessWidget {
  const _LicCell({
    required this.k,
    required this.v,
    this.sub,
    this.valueSmall = false,
  });
  final String k;
  final String v;
  final String? sub;
  final bool valueSmall;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF121212),
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.0,
              color: _t4,
            ),
          ),
          const SizedBox(height: 5),
          Row(
            children: [
              if (!valueSmall) ...[
                const Icon(LucideIcons.check, size: 13, color: _kGreenText),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  v,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: valueSmall ? 12 : 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ],
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(
              sub!,
              style: const TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: _t3,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The one real device we can name: the machine the app is running on.
class _DeviceRow extends StatelessWidget {
  const _DeviceRow();

  String _deviceName(AppLocalizations l10n) {
    try {
      final name = Platform.localHostname.trim();
      // This machine's name, masked in recording mode as the account page
      // masks it (it often names its person).
      if (name.isNotEmpty) return Redactable.account(name).display;
    } catch (_) {}
    return l10n.deskUpgThisDevice;
  }

  String _platformLabel() {
    if (Platform.isWindows) return 'Windows';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isLinux) return 'Linux';
    return 'Desktop';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12),
      child: Row(
        children: [
          Container(
            width: 26,
            height: 26,
            decoration: BoxDecoration(
              color: const Color(0xFF1D1D1D),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _bd),
            ),
            child: const Icon(LucideIcons.monitor, size: 13, color: _t2),
          ),
          const SizedBox(width: 11),
          Flexible(
            child: Text(
              _deviceName(l10n),
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFD5D5D5),
              ),
            ),
          ),
          const SizedBox(width: 9),
          _NeutralBadge(label: _platformLabel()),
          const SizedBox(width: 7),
          _NeutralBadge(label: l10n.deskUpgThisDeviceBadge),
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Shared building blocks
// ════════════════════════════════════════════════════════════════════

class _Checkbox extends StatelessWidget {
  const _Checkbox({required this.on, this.owned = false});
  final bool on;
  final bool owned;

  @override
  Widget build(BuildContext context) {
    final active = on || owned;
    final fill = owned ? _kGreen : _kAccent;
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: active ? fill : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: active ? fill : _bd2,
          width: 1.5,
        ),
      ),
      child: active
          ? const Icon(LucideIcons.check, size: 12, color: Color(0xFF120A02))
          : null,
    );
  }
}

class _PriceBlock extends StatelessWidget {
  const _PriceBlock({required this.price});
  final String price;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(
          price,
          style: const TextStyle(
            fontFamily: 'GeistSans',
            fontSize: 22,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: -0.4,
            height: 1.1,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.deskUpgOnce,
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10.5,
            color: _t4,
          ),
        ),
      ],
    );
  }
}

class _FeatureLine extends StatelessWidget {
  const _FeatureLine({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 2),
          child: Icon(LucideIcons.check, size: 13, color: _t3),
        ),
        const SizedBox(width: 9),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12.5,
              height: 1.4,
              color: Color(0xFFD8D8D8),
            ),
          ),
        ),
      ],
    );
  }
}

class _DiscRow extends StatelessWidget {
  const _DiscRow({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(top: 13),
      padding: const EdgeInsets.only(top: 11),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _bd)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.chevronRight, size: 12, color: _t3),
          ),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11.5,
                height: 1.4,
                color: _t3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A running-total / credit summary bar with a primary action.
class _SummaryBar extends StatelessWidget {
  const _SummaryBar({
    required this.armed,
    required this.lines,
    required this.amount,
    required this.buttonLabel,
    required this.onPressed,
    this.strike,
  });

  final bool armed;
  final List<_SumLine> lines;
  final String amount;
  final String buttonLabel;
  final VoidCallback? onPressed;
  final String? strike;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = onPressed != null;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: armed ? const Color(0xFF14110E) : const Color(0xFF111111),
        borderRadius: BorderRadius.circular(11),
        border: Border.all(
          color: armed ? _kAccent.withValues(alpha: 0.4) : _bd2,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < lines.length; i++) ...[
                  if (i > 0) const SizedBox(height: 4),
                  _buildLine(lines[i]),
                ],
              ],
            ),
          ),
          const SizedBox(width: 18),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (strike != null)
                Text(
                  strike!,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 12,
                    color: _t4,
                    decoration: TextDecoration.lineThrough,
                  ),
                ),
              Text(
                amount,
                style: TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: enabled ? Colors.white : _t4,
                  height: 1.05,
                ),
              ),
              if (enabled)
                Text(
                  l10n.deskUpgOnce,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10.5,
                    color: _t4,
                  ),
                ),
            ],
          ),
          const SizedBox(width: 16),
          _WideButton(
            label: buttonLabel,
            onPressed: onPressed,
          ),
        ],
      ),
    );
  }

  Widget _buildLine(_SumLine line) {
    final labelStyle = TextStyle(
      fontFamily: 'GeistSans',
      fontSize: 12.5,
      height: 1.4,
      color: line.labelColor ?? _t3,
    );
    if (line.value == null) {
      return Text(line.label, style: labelStyle);
    }
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 186, child: Text(line.label, style: labelStyle)),
        const SizedBox(width: 9),
        Text(
          line.value!,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12,
            color: line.valueColor ?? _valueText,
          ),
        ),
      ],
    );
  }
}

class _SumLine {
  const _SumLine({
    required this.label,
    this.value,
    this.labelColor,
    this.valueColor,
  });
  final String label;
  final String? value;
  final Color? labelColor;
  final Color? valueColor;
}

/// The primary orange action on a summary bar (or a disabled slug).
class _WideButton extends StatefulWidget {
  const _WideButton({required this.label, required this.onPressed});
  final String label;
  final VoidCallback? onPressed;

  @override
  State<_WideButton> createState() => _WideButtonState();
}

class _WideButtonState extends State<_WideButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: enabled
                ? (_hover ? _kAccent : _kAccent.withValues(alpha: 0.92))
                : const Color(0xFF111111),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: enabled ? _kAccent : _bd,
            ),
          ),
          child: Text(
            widget.label,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: enabled ? const Color(0xFF1B0E02) : _t4,
            ),
          ),
        ),
      ),
    );
  }
}

/// Small ghost / neutral button used in the title bar and panels.
class _SmallButton extends StatefulWidget {
  const _SmallButton({
    required this.label,
    required this.onTap,
    this.icon,
    this.ghost = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool ghost;

  @override
  State<_SmallButton> createState() => _SmallButtonState();
}

class _SmallButtonState extends State<_SmallButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onTap == null;
    final ghost = widget.ghost;

    final Color bg;
    final Color fg;
    final Color border;
    if (disabled) {
      bg = const Color(0xFF111111);
      fg = _t4;
      border = _bd;
    } else if (ghost) {
      bg = _hover ? Colors.white.withValues(alpha: 0.05) : Colors.transparent;
      fg = _hover ? _t1 : _t2;
      border = _bd2;
    } else {
      bg = _hover ? const Color(0xFF1F1F1F) : const Color(0xFF171717);
      fg = const Color(0xFFE4E4E4);
      border = _bd2;
    }

    return MouseRegion(
      cursor: disabled ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 11),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(7),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 12, color: fg),
                const SizedBox(width: 6),
              ],
              Text(
                widget.label,
                style: TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: fg,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccentBadge extends StatelessWidget {
  const _AccentBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _kAccent.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _kAccent.withValues(alpha: 0.32)),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: _kAccent,
        ),
      ),
    );
  }
}

class _OwnedBadge extends StatelessWidget {
  const _OwnedBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: _kGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _kGreen.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: _kGreenText,
        ),
      ),
    );
  }
}

class _NeutralBadge extends StatelessWidget {
  const _NeutralBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFF131313),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: _bd),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 10,
          color: _t3,
        ),
      ),
    );
  }
}

/// Bordered panel with an uppercase header and stacked rows (Screen C).
class _Panel extends StatelessWidget {
  const _Panel({required this.title, required this.children, this.trailing});
  final String title;
  final List<Widget> children;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    for (var i = 0; i < children.length; i++) {
      if (i > 0) {
        rows.add(const Divider(height: 1, thickness: 1, color: _hair));
      }
      rows.add(children[i]);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: _surf,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: _bd),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: _bd)),
            ),
            child: Row(
              children: [
                Text(
                  title.toUpperCase(),
                  style: const TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 10.5,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.0,
                    color: _t3,
                  ),
                ),
                const Spacer(),
                if (trailing != null) trailing!,
              ],
            ),
          ),
          ...rows,
        ],
      ),
    );
  }
}

class _PanelRow extends StatelessWidget {
  const _PanelRow({
    required this.title,
    required this.subtitle,
    this.trailing,
  });
  final String title;
  final String subtitle;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _t1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10.5,
                    color: _t4,
                  ),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Four-cell trust strip (Screen A).
class _TrustStrip extends StatelessWidget {
  const _TrustStrip();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: _bd),
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: _TrustCell(
                title: l10n.deskUpgTrustNoSub,
                detail: l10n.deskUpgTrustNoSubDetail,
              ),
            ),
            const _VDivider(),
            Expanded(
              child: _TrustCell(
                title: l10n.deskUpgTrustEveryPlatform,
                detail: 'win · mac · linux · ios · android',
              ),
            ),
            const _VDivider(),
            Expanded(
              child: _TrustCell(
                title: l10n.deskUpgTrustZeroTracking,
                detail: l10n.deskUpgTrustZeroTrackingDetail,
              ),
            ),
            const _VDivider(),
            Expanded(
              child: _TrustCell(
                title: l10n.deskUpgTrust30DayRefund,
                detail: l10n.deskUpgTrust30DayRefundDetail,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustCell extends StatelessWidget {
  const _TrustCell({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF111111),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            detail,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: _t3,
            ),
          ),
        ],
      ),
    );
  }
}

class _VDivider extends StatelessWidget {
  const _VDivider();
  @override
  Widget build(BuildContext context) {
    return const SizedBox(width: 1, child: ColoredBox(color: _bd));
  }
}

/// Footer strip with a top hairline (per-screen).
class _Footbar extends StatelessWidget {
  const _Footbar({required this.text, this.icon, this.trailing});
  final String text;
  final IconData? icon;
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.only(top: 14),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: _bd)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: _t3),
            const SizedBox(width: 9),
          ],
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11.5,
                height: 1.6,
                color: _t3,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 14),
            Text(
              trailing!,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: _kAccent,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Decorative - aurora + dot grid (UNCHANGED, per requirement)
// ════════════════════════════════════════════════════════════════════

class _AuroraBackdrop extends StatelessWidget {
  const _AuroraBackdrop();
  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(-0.6, -0.7),
          radius: 1.4,
          colors: [
            Color(0x25FF7A1A),
            Color(0x00000000),
          ],
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0.8, -0.4),
            radius: 1.2,
            colors: [
              Color(0x144A9EF5),
              Color(0x00000000),
            ],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.0, 1.0),
              radius: 1.2,
              colors: [
                Color(0x108B5CF6),
                Color(0x00000000),
              ],
            ),
          ),
          child: SizedBox.expand(),
        ),
      ),
    );
  }
}

class _DotGrid extends StatelessWidget {
  const _DotGrid();
  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _DotGridPainter());
  }
}

class _DotGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.025);
    const spacing = 28.0;
    for (var x = 0.0; x < size.width; x += spacing) {
      for (var y = 0.0; y < size.height; y += spacing) {
        canvas.drawCircle(Offset(x, y), 0.7, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_) => false;
}

// ════════════════════════════════════════════════════════════════════
//  Staggered entrance reveal
// ════════════════════════════════════════════════════════════════════

class _AnimatedReveal extends StatelessWidget {
  const _AnimatedReveal({
    required this.controller,
    required this.delay,
    required this.child,
  });

  final AnimationController controller;
  final int delay; // ms
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (_, _) {
        final total = controller.duration!.inMilliseconds;
        final localT = ((controller.value * total) - delay) / (total - delay);
        final t = localT.clamp(0.0, 1.0);
        final eased = Curves.easeOutCubic.transform(t);
        return Opacity(
          opacity: eased,
          child: Transform.translate(
            offset: Offset(0, 18 * (1 - eased)),
            child: child,
          ),
        );
      },
      child: child,
    );
  }
}
