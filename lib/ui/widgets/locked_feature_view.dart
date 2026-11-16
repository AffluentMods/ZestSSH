import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';
import 'package:zestssh/ui/screens/purchase/restore_purchases.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform, isTouchLayout;

/// One thing a locked feature gives, said plainly beside its icon.
class LockedFeatureBenefit {
  const LockedFeatureBenefit(this.icon, this.text);

  final IconData icon;
  final String text;
}

/// A page of Squeezed's before it is bought (4.0):
/// the page itself, faded and out of reach, with
/// made-up demo data ([preview]), behind a card in its middle that says what
/// the feature is part of ([title]), three true things it gives
/// ([benefits]), one button to buy Squeezed (a computer's price, paid once;
/// a phone's store says its own), What is Squeezed? (the plan popover) and
/// Restore purchases for someone who bought it already. It was a line and an
/// Upgrade button on an empty page. A team's seat has the full app, so never
/// sees it.
class LockedFeatureView extends ConsumerWidget {
  const LockedFeatureView({
    super.key,
    required this.icon,
    required this.title,
    required this.benefits,
    required this.preview,
  });

  /// The feature's icon, at the card's top left.
  final IconData icon;

  /// "Command history is part of Squeezed".
  final String title;

  /// Three short, true things the feature gives.
  final List<LockedFeatureBenefit> benefits;

  /// The page as it looks in use, with made-up demo data: drawn faded, out
  /// of reach of the pointer, the keyboard and a screen reader.
  final Widget preview;

  /// What a computer's checkout charges for Squeezed (zestssh.com), as the
  /// plan popover and the upgrade page say it.
  static const squeezedPrice = '\$9.99';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final squeezed = AccountPlan.squeezed.nameIn(l10n);
    final touch = isTouchLayout;
    void buy() => ref.read(planPurchaseOpenerProvider)(context);
    Future<void> restore() => ref.read(purchaseRestorerProvider)(context);

    final card = Container(
      key: const ValueKey('locked-card'),
      constraints: const BoxConstraints(maxWidth: 468),
      padding: EdgeInsets.fromLTRB(touch ? 20 : 28, touch ? 20 : 24, touch ? 20 : 28, touch ? 14 : 18),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: ZestTokens.border),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 32, offset: const Offset(0, 12)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceChip,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ZestTokens.border),
                ),
                child: Icon(icon, size: 19, color: ZestTokens.textSecondary),
              ),
              const Spacer(),
              // What Squeezed is, as every plan's name says it.
              const PlanChip(key: ValueKey('locked-plan-chip'), plan: AccountPlan.squeezed),
            ],
          ),
          const SizedBox(height: 18),
          Semantics(
            header: true,
            child: Text(
              title,
              key: const ValueKey('locked-title'),
              style: TextStyle(
                fontSize: touch ? 19 : 20,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.3,
                height: 1.25,
                color: ZestTokens.textPrimary,
              ),
            ),
          ),
          const SizedBox(height: 14),
          for (final b in benefits) _Benefit(benefit: b),
          const SizedBox(height: 10),
          // A build with no plans to buy says so, and offers nothing.
          if (!zestHasPlans)
            Text(
              l10n.noPlansBody,
              key: const ValueKey('locked-no-plans'),
              style: TextStyle(fontSize: 13.5, height: 1.45, color: ZestTokens.textSecondary),
            )
          else ...[
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: ZestButton(
              key: const ValueKey('locked-buy'),
              size: ZestButtonSize.large,
              variant: ZestButtonVariant.primary,
              // A computer's price, paid once; a phone's store says its own
              // on its page.
              label: isDesktopPlatform ? l10n.lockedGetPlanOnce(squeezed, squeezedPrice) : l10n.planGet(squeezed),
              onPressed: buy,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 0,
            children: [
              Builder(
                builder: (linkContext) => _Link(
                  key: const ValueKey('locked-what-is'),
                  icon: LucideIcons.info,
                  label: l10n.settingsInlineWhatIsSqueezed,
                  onTap: () => unawaited(openPlanPopover(linkContext)),
                ),
              ),
              _Link(
                key: const ValueKey('locked-restore'),
                lead: l10n.lockedBoughtAlready,
                label: l10n.upgradeRestorePurchases,
                onTap: () => unawaited(restore()),
              ),
            ],
          ),
          ],
        ],
      ),
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        // The page in use, faded: nothing in it is reached by the pointer,
        // the keyboard or a screen reader.
        ExcludeSemantics(
          child: ExcludeFocus(
            child: IgnorePointer(
              child: Opacity(
                key: const ValueKey('locked-preview'),
                opacity: 0.32,
                // A picture of the page: at the size the app is drawn at,
                // whatever the text size (its words are not read).
                child: ClipRect(child: MediaQuery.withNoTextScaling(child: preview)),
              ),
            ),
          ),
        ),
        // A veil over it, so the card reads on its own.
        IgnorePointer(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                radius: 0.9,
                colors: [
                  ZestTokens.surfaceBase.withValues(alpha: 0.55),
                  ZestTokens.surfaceBase.withValues(alpha: 0.15),
                ],
              ),
            ),
          ),
        ),
        Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.all(touch ? 16 : 24),
            child: card,
          ),
        ),
      ],
    );
  }
}

class _Benefit extends StatelessWidget {
  const _Benefit({required this.benefit});

  final LockedFeatureBenefit benefit;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZestTokens.border),
            ),
            child: Icon(benefit.icon, size: 16, color: ZestTokens.textSecondary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              benefit.text,
              style: TextStyle(fontSize: 14, height: 1.4, color: ZestTokens.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// A quiet link at the card's foot: [lead] in muted words before it, then
/// [label] in the text's own colour. 48 high to a thumb on a phone; Enter or
/// Space on a computer.
class _Link extends StatelessWidget {
  const _Link({super.key, this.icon, this.lead, required this.label, required this.onTap});

  final IconData? icon;
  final String? lead;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final muted = ZestTokens.textMuted;
    return Semantics(
      button: true,
      label: [?lead, label].join(' '),
      excludeSemantics: true,
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: isTouchLayout ? 48 : 34),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: muted),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text.rich(
                    TextSpan(children: [
                      if (lead != null) TextSpan(text: '$lead ', style: TextStyle(color: muted)),
                      TextSpan(
                        text: label,
                        style: TextStyle(color: ZestTokens.textPrimary, fontWeight: FontWeight.w600),
                      ),
                    ]),
                    style: const TextStyle(fontSize: 13),
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
