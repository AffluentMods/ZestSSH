import 'package:flutter/material.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// 1.7 page header: a 24px semibold [title] with a required 13px [metaLine]
/// context line beneath it, plus optional right-aligned [actions] on the title
/// row.
///
/// [metaLine] is `required` and **non-nullable** on purpose. Every 1.7 page
/// must state its context ("12 hosts · 3 groups", "Last synced 2m ago"), so a
/// missing meta line is a *compile-time* error here - it can never silently
/// regress to absent the way an optional `String?` could.
class ZestPageHeader extends StatelessWidget {
  const ZestPageHeader({
    super.key,
    required this.title,
    required this.metaLine,
    this.actions,
  });

  /// Already-localized page title.
  final String title;

  /// Already-localized context line. REQUIRED, non-nullable (see class doc).
  final String metaLine;

  /// Right-aligned actions on the title row (each carries its own focus).
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    // The title and its line are one block, and the actions stand centred
    // beside the whole of it: a page with a button there has its title where
    // a page without one has it (the button made the title row taller and
    // moved the title down on some pages).
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 42),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                    color: ZestTokens.textPrimary,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  metaLine,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    color: ZestTokens.textMuted,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          if (actions != null && actions!.isNotEmpty) ...[
            const SizedBox(width: 16),
            Wrap(
              spacing: ZestSizing.buttonGap,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions!,
            ),
          ],
        ],
      ),
    );
  }
}

/// The band a page's head sits in (3.0, the Blueprint): a step above the
/// panel, its own rule along the bottom, and the brand line fading along it.
class ZestPageBand extends StatelessWidget {
  const ZestPageBand({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: ZestTokens.band,
        border: Border(bottom: BorderSide(color: ZestTokens.bandLine)),
      ),
      child: Stack(
        children: [
          child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: 1,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [ZestTokens.brand.withValues(alpha: 0.32), ZestTokens.brand.withValues(alpha: 0)],
                    stops: const [0, 0.55],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
