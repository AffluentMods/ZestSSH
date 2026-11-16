import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/help/guides/guide_providers.dart';
import 'package:zestssh/features/help/guides/guide_search.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// Opens the guide at [slug]: in the Help panel on a computer, as a page of
/// its own on a phone or a tablet.
void openGuide(BuildContext context, WidgetRef ref, String slug) {
  if (ref.read(guidesInHelpPanelProvider)) {
    // The Help panel is part of the window, behind a pop-up (Settings is
    // one): the pop-up closes, through its own guard, and the guide opens
    // where it can be read.
    if (ModalRoute.of(context) is PopupRoute) {
      // ignore: discarded_futures
      Navigator.of(context).maybePop();
    }
    ref.read(helpDockGuideProvider.notifier).state = slug;
    ref.read(helpDockProvider.notifier).state = HelpPage.guide;
  } else {
    GoRouter.of(context).push(Routes.guide, extra: slug);
  }
}

/// Opens Help > Guides, the list and its search.
void openGuides(BuildContext context, WidgetRef ref) {
  if (ref.read(guidesInHelpPanelProvider)) {
    ref.read(helpDockProvider.notifier).state = HelpPage.guides;
  } else {
    GoRouter.of(context).push(Routes.guides);
  }
}

/// The small "?" in a page's header that opens the page's guide (3.0, Help >
/// Guides): the guide whose frontmatter names [feature]. Nothing when no
/// guide does, so a page never shows a "?" that leads nowhere.
class GuideHelpButton extends ConsumerWidget {
  const GuideHelpButton({super.key, required this.feature, this.size = 16});

  /// The app's feature id, as the guides' frontmatter lists it ("networks").
  final String feature;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final guide = guideForFeature(feature);
    // (A guide is fetched from the docs site: a build with none has no button.)
    if (guide == null || kZestDocsOrigin == '') return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return IconButton(
      key: ValueKey('guide-help-$feature'),
      tooltip: l10n.guideHelpTooltip(guide.title),
      onPressed: () => openGuide(context, ref, guide.slug),
      icon: Icon(LucideIcons.helpCircle, size: size),
      color: ZestTokens.textTertiary,
      hoverColor: ZestTokens.surfaceHover,
      // At least a mouse's 32 square, a finger's 48 (4.0, the accessibility
      // pass): the compact density took 8 off, to 24.
      visualDensity: VisualDensity.standard,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(
          width: math.max(size + 16, minTapTarget(context)), height: math.max(size + 16, minTapTarget(context))),
    );
  }
}

/// A page's title with its guide's "?" just after it: the one place the "?"
/// stands on every page, whatever the page has on the right of its header.
/// The title shrinks (and ellipsizes, where it does) before the "?" moves.
class GuideTitle extends StatelessWidget {
  const GuideTitle({super.key, required this.title, required this.feature});

  final Widget title;
  final String feature;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final help = Padding(
        padding: const EdgeInsets.only(left: 4),
        child: GuideHelpButton(feature: feature),
      );
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (box.maxWidth.isFinite) Flexible(child: title) else title,
          help,
        ],
      );
    });
  }
}
