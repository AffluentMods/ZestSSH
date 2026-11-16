import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/profile/account_switch.dart' show showAtControl;
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/utils/help_links.dart' show kZestPlansUrl;
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform, isTouchLayout;

// A plan name that explains itself (4.0): wherever the app shows
// Squeezed,
// Juiced or the Bundle, a tap says what this account has and what each plan
// is. Juiced is ZestSSH Cloud only and the Bundle is Squeezed and Juiced;
// sync itself is free with storage of one's own. A team's seat is said in
// plain words, never by the fruit names. Every chip that names a plan opens
// it: the rail's foot, the account's badge on Settings (Account, Plan,
// About) and a phone's Account and About, the space menu, and the tag a
// feature needs its plan by.

/// What each plan is called: the fruit names are names, the same in every
/// language; a team's seat is said in plain words.
extension AccountPlanName on AccountPlan {
  String nameIn(AppLocalizations l10n) => switch (this) {
        AccountPlan.free => l10n.narrowSidebarTierFree,
        AccountPlan.squeezed => l10n.narrowSidebarTierSqueezed,
        AccountPlan.juiced => l10n.narrowSidebarTierJuiced,
        AccountPlan.bundle => l10n.pricingTierBundle,
        AccountPlan.teamSeat => l10n.planTeamSeat,
      };
}

/// What a computer's checkout charges for each (zestssh.com, in US dollars),
/// as its upgrade page says it. A phone's store sets its own, so a phone's
/// button names no price.
const _squeezedPrice = '\$9.99';
const _juicedPrice = '\$24.99';

/// Opens a page in the browser (Compare plans). Tests stand in.
final planPageOpenerProvider = Provider<Future<void> Function(Uri page)>(
    (ref) => (page) async {
          await launchUrl(page, mode: LaunchMode.externalApplication);
        });

/// Opens the app's way of buying a plan ([PricingModal.show]: a computer's
/// upgrade page, a phone's pricing). Tests stand in.
final planPurchaseOpenerProvider = Provider<void Function(BuildContext context)>((ref) => PricingModal.show);

/// The plan's chip: its name and an info mark, a button that opens
/// [showPlanPopover] beside it. The account's own plan (the rail's foot on a
/// computer, the account beside its name on Settings, Account, Plan and
/// About, the space menu), or a plan a feature needs ([plan]: Squeezed beside
/// Custom theme, on a locked page, Juiced beside ZestSSH Cloud), each
/// explaining itself the same way.
class PlanChip extends ConsumerWidget {
  const PlanChip({super.key, this.anchorOf, this.plan});

  /// What the popover stands beside, from the chip's own rectangle: the
  /// chip itself where null (the rail gives its own edge, so the popover
  /// stands beside the rail, not over it).
  final Rect Function(Rect chip)? anchorOf;

  /// The plan this chip names, where a feature needs it; the account's own
  /// where null. A team's seat has the full app and is never shown the
  /// fruit names: a named plan draws nothing
  /// for it.
  final AccountPlan? plan;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A build with no plans names none: no chip, anywhere it stands.
    if (!zestHasPlans) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final yours = ref.watch(accountPlanProvider);
    final named = plan;
    if (named != null && yours == AccountPlan.teamSeat && named != AccountPlan.teamSeat) {
      return const SizedBox.shrink();
    }
    final name = (named ?? yours).nameIn(l10n);
    final ink = ZestTokens.brandInk;
    void open() => unawaited(openPlanPopover(context, anchorOf: anchorOf));
    final touch = isTouchLayout;
    final pill = Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 6, 2),
      decoration: BoxDecoration(
        color: ZestTokens.brandBadge,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: ink, height: 1.3),
            ),
          ),
          const SizedBox(width: 4),
          Icon(LucideIcons.info, size: 12, color: ink),
        ],
      ),
    );
    // A button of its own to a screen reader, apart from what it sits in
    // (the rail's account row, which opens the account).
    return Semantics(
      container: true,
      button: true,
      label: named == null ? l10n.planPopoverTitle(name) : name,
      hint: l10n.planChipTip,
      onTap: open,
      excludeSemantics: true,
      child: Tooltip(
        message: l10n.planChipTip,
        waitDuration: const Duration(milliseconds: 500),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            key: named == null ? const ValueKey('plan-chip') : ValueKey('plan-chip-${named.name}'),
            borderRadius: BorderRadius.circular(999),
            onTap: open,
            // 48 high to a thumb on a phone or a tablet, drawn as small.
            child: touch
                ? ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
                    child: Center(widthFactor: 1, heightFactor: 1, child: pill),
                  )
                : pill,
          ),
        ),
      ),
    );
  }
}

/// [showPlanPopover] beside the widget [context] draws, or beside what
/// [anchorOf] makes of its rectangle.
Future<void> openPlanPopover(BuildContext context, {Rect Function(Rect own)? anchorOf}) {
  final box = context.findRenderObject();
  if (box is! RenderBox || !box.hasSize) return Future.value();
  final own = box.localToGlobal(Offset.zero) & box.size;
  return showPlanPopover(context, anchor: anchorOf?.call(own) ?? own);
}

/// What this account's plan is and what each plan gives ([PlanPopover]),
/// beside [anchor] (to its right where there is room, else to its left; on a
/// window too narrow for either, a phone's, under it or over it) and pointing
/// at it; a click beside it or Escape closes it. A popover at its control, as
/// the account row's list is, on the same route ([showAtControl]).
Future<void> showPlanPopover(BuildContext context, {required Rect anchor}) {
  final l10n = AppLocalizations.of(context)!;
  return showAtControl<void>(
    context,
    label: l10n.close,
    build: (dialogContext) => LayoutBuilder(
      builder: (_, box) {
        final width = math.min(PlanPopover.width, box.maxWidth - 16);
        final side = anchor.right + _gap + width <= box.maxWidth - 8
            ? _Side.right
            : anchor.left - _gap - width >= 8
                ? _Side.left
                // Under it where at least half the window is below it.
                : anchor.bottom <= box.maxHeight / 2
                    ? _Side.below
                    : _Side.above;
        return CustomMultiChildLayout(
          delegate: _PopoverLayout(anchor: anchor, width: width, side: side),
          children: [
            LayoutId(
              id: _Part.body,
              child: PlanPopover(onClose: () => Navigator.of(dialogContext).pop()),
            ),
            LayoutId(id: _Part.arrow, child: _Arrow(side: side)),
          ],
        );
      },
    ),
  );
}

/// Between the anchor and the popover, where the arrow is.
const double _gap = 12;

enum _Part { body, arrow }

/// Where the popover stands, from its anchor.
enum _Side { right, left, below, above }

/// The popover beside its anchor, its top a little above the anchor's middle
/// and kept on the screen, and the arrow at the anchor's middle; under or
/// over it, the popover kept in the window and the arrow at the anchor's
/// middle across.
class _PopoverLayout extends MultiChildLayoutDelegate {
  _PopoverLayout({required this.anchor, required this.width, required this.side});

  final Rect anchor;
  final double width;
  final _Side side;

  @override
  void performLayout(Size size) {
    final arrow = layoutChild(_Part.arrow, BoxConstraints.tight(_Arrow.sizeFor(side)));
    switch (side) {
      case _Side.right:
      case _Side.left:
        final onRight = side == _Side.right;
        final body =
            layoutChild(_Part.body, BoxConstraints(maxWidth: width, minWidth: width, maxHeight: size.height - 16));
        final x = onRight ? anchor.right + _gap : math.max(8.0, anchor.left - _gap - width);
        final y = (anchor.center.dy - 28).clamp(8.0, math.max(8.0, size.height - body.height - 8)).toDouble();
        positionChild(_Part.body, Offset(x, y));
        final top = (anchor.center.dy - arrow.height / 2)
            .clamp(y + 10, math.max(y + 10, y + body.height - arrow.height - 10))
            .toDouble();
        positionChild(_Part.arrow, Offset(onRight ? x - arrow.width + 1 : x + body.width - 1, top));
      case _Side.below:
      case _Side.above:
        final below = side == _Side.below;
        final room = below ? size.height - anchor.bottom - _gap - 8 : anchor.top - _gap - 8;
        final body =
            layoutChild(_Part.body, BoxConstraints(maxWidth: width, minWidth: width, maxHeight: math.max(0, room)));
        final x = (anchor.center.dx - width / 2).clamp(8.0, math.max(8.0, size.width - width - 8)).toDouble();
        final y = below ? anchor.bottom + _gap : anchor.top - _gap - body.height;
        positionChild(_Part.body, Offset(x, y));
        final left = (anchor.center.dx - arrow.width / 2)
            .clamp(x + 12, math.max(x + 12, x + body.width - arrow.width - 12))
            .toDouble();
        positionChild(_Part.arrow, Offset(left, below ? y - arrow.height + 1 : y + body.height - 1));
    }
  }

  @override
  bool shouldRelayout(_PopoverLayout old) => old.anchor != anchor || old.width != width || old.side != side;
}

/// The popover's point toward its anchor: its fill, and its border on the two
/// sides that stand out.
class _Arrow extends StatelessWidget {
  const _Arrow({required this.side});

  /// Where the popover stands from its anchor: the point is on its other
  /// side.
  final _Side side;

  static Size sizeFor(_Side side) =>
      side == _Side.right || side == _Side.left ? const Size(8, 16) : const Size(16, 8);

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: sizeFor(side),
        painter: _ArrowPainter(
          side: side,
          fill: ZestTokens.surfaceRaisedAlt,
          line: ZestTokens.border,
        ),
      );
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter({required this.side, required this.fill, required this.line});

  final _Side side;
  final Color fill;
  final Color line;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    // The base's two ends (on the popover's edge) and the tip.
    final (Offset a, Offset tip, Offset b) = switch (side) {
      _Side.right => (Offset(w, 0), Offset(0, h / 2), Offset(w, h)),
      _Side.left => (Offset.zero, Offset(w, h / 2), Offset(0, h)),
      _Side.below => (Offset(0, h), Offset(w / 2, 0), Offset(w, h)),
      _Side.above => (Offset.zero, Offset(w / 2, h), Offset(w, 0)),
    };
    final path = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(b.dx, b.dy)
      ..close();
    canvas.drawPath(path, Paint()..color = fill);
    final edge = Path()
      ..moveTo(a.dx, a.dy)
      ..lineTo(tip.dx, tip.dy)
      ..lineTo(b.dx, b.dy);
    canvas.drawPath(
      edge,
      Paint()
        ..color = line
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.side != side || old.fill != fill || old.line != line;
}

/// What the account's plan is ("Your plan: Juiced", paid once), a line for
/// each of Squeezed, Juiced and the Bundle with what this account has marked
/// with a check and Yours, that sync itself is free with storage of one's
/// own, Compare plans, and a quiet button for what is missing. A team's seat:
/// what it gives, in plain words.
class PlanPopover extends ConsumerWidget {
  const PlanPopover({super.key, this.onClose});

  /// Closes the popover, before what a button opens.
  final VoidCallback? onClose;

  static const double width = 418;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final plan = ref.watch(accountPlanProvider);
    final name = plan.nameIn(l10n);
    final hasSqueezed = plan == AccountPlan.squeezed || plan == AccountPlan.bundle;
    final hasJuiced = plan == AccountPlan.juiced || plan == AccountPlan.bundle;
    final seat = plan == AccountPlan.teamSeat;

    void close() => onClose?.call();
    Future<void> compare() async {
      final open = ref.read(planPageOpenerProvider);
      close();
      await open(Uri.parse(kZestPlansUrl));
    }

    void buy() {
      final open = ref.read(planPurchaseOpenerProvider);
      // Where the popover was opened from, once it has closed.
      final opener = Navigator.of(context, rootNavigator: true).context;
      close();
      open(opener);
    }

    // What is missing, and what it costs on a computer.
    final missing = switch (plan) {
      AccountPlan.squeezed => (l10n.narrowSidebarTierJuiced, _juicedPrice),
      AccountPlan.juiced => (l10n.narrowSidebarTierSqueezed, _squeezedPrice),
      _ => null,
    };
    final String? buyLabel = switch (plan) {
      // Both are missing: the purchase page offers each.
      AccountPlan.free => l10n.narrowSidebarUpgradeRow,
      AccountPlan.squeezed || AccountPlan.juiced =>
        isDesktopPlatform ? l10n.planGetWithPrice(missing!.$1, missing.$2) : l10n.planGet(missing!.$1),
      _ => null,
    };

    final title = Text(
      l10n.planPopoverTitle(name),
      style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary, height: 1.3),
    );
    final subtitle = Text(
      seat ? l10n.planTeamSeatBody : (plan == AccountPlan.free ? l10n.planFreeNote : l10n.planPaidOnce),
      style: TextStyle(fontSize: 12.5, color: ZestTokens.textMuted, height: 1.4),
    );

    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: l10n.planPopoverTitle(name),
      child: Material(
        key: const ValueKey('plan-popover'),
        color: ZestTokens.surfaceRaisedAlt,
        elevation: 10,
        shadowColor: Colors.black.withValues(alpha: 0.5),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: ZestTokens.border),
        ),
        clipBehavior: Clip.antiAlias,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [title, const SizedBox(height: 2), subtitle],
                ),
              ),
              // A seat: what it gives is the line above, in plain words.
              if (!seat) ...[
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Column(
                    children: [
                      _PlanLine(
                        key: const ValueKey('plan-row-squeezed'),
                        name: l10n.narrowSidebarTierSqueezed,
                        line: l10n.planSqueezedLine,
                        yours: hasSqueezed,
                      ),
                      _PlanLine(
                        key: const ValueKey('plan-row-juiced'),
                        name: l10n.narrowSidebarTierJuiced,
                        line: l10n.planJuicedLine,
                        yours: hasJuiced,
                      ),
                      _PlanLine(
                        key: const ValueKey('plan-row-bundle'),
                        name: l10n.pricingTierBundle,
                        line: switch (plan) {
                          AccountPlan.juiced => l10n.planBundleHasJuiced,
                          AccountPlan.squeezed => l10n.planBundleHasSqueezed,
                          _ => l10n.planBundleLine,
                        },
                        yours: plan == AccountPlan.bundle,
                      ),
                    ],
                  ),
                ),
                // Sync itself is free: Juiced is storage.
                Container(
                  key: const ValueKey('plan-sync-free'),
                  margin: const EdgeInsets.fromLTRB(18, 6, 18, 0),
                  padding: const EdgeInsets.fromLTRB(0, 10, 0, 12),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Icon(LucideIcons.info, size: 15, color: ZestTokens.textMuted),
                      ),
                      const SizedBox(width: 9),
                      Expanded(
                        child: Text(
                          l10n.planSyncFreeNote,
                          style: TextStyle(fontSize: 12.5, color: ZestTokens.textMuted, height: 1.45),
                        ),
                      ),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.fromLTRB(10, 10, 18, 12),
                  decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
                  child: Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      Semantics(
                        link: true,
                        child: ZestButton(
                          key: const ValueKey('plan-compare'),
                          label: l10n.planComparePlans,
                          trailingIcon: LucideIcons.arrowRight,
                          variant: ZestButtonVariant.ghost,
                          onPressed: () => unawaited(compare()),
                        ),
                      ),
                      if (buyLabel != null)
                        ZestButton(
                          key: const ValueKey('plan-buy'),
                          label: buyLabel,
                          onPressed: buy,
                        ),
                    ],
                  ),
                ),
              ] else
                const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }
}

/// One plan in the popover: a check where this account has it, a dash where
/// it has not (in shape, not by colour alone), its name with Yours, and what
/// it is.
class _PlanLine extends StatelessWidget {
  const _PlanLine({super.key, required this.name, required this.line, required this.yours});

  final String name;
  final String line;
  final bool yours;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final ok = ZestTokens.statusHealthy;
    // The green words on a light page, a third of the way to the text.
    final okInk = Theme.of(context).brightness == Brightness.light ? Color.lerp(ok, ZestTokens.textPrimary, 0.35)! : ok;
    return Semantics(
      container: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 11),
        decoration: BoxDecoration(
          color: yours ? ZestTokens.surfaceRaised : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 20,
              height: 20,
              margin: const EdgeInsets.only(top: 1),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: yours ? ok : Colors.transparent,
                border: yours ? null : Border.all(color: ZestTokens.borderStrong, width: 1.5),
              ),
              child: Icon(
                yours ? LucideIcons.check : LucideIcons.minus,
                size: 12,
                color: yours ? ZestTokens.surfaceBase : ZestTokens.textPlaceholder,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                        ),
                      ),
                      if (yours)
                        Text(
                          l10n.planYours,
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: okInk),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    line,
                    style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary, height: 1.45),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
