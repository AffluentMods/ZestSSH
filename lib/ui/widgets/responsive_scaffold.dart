import 'package:flutter/material.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/phone_list.dart' show PhonePageColumn;
import 'package:zestssh/utils/platform_utils.dart';

/// A scaffold wrapper that constrains form/content width on desktop.
///
/// On a phone, behaves like a normal [Scaffold]; on a tablet its body is in the
/// one centred column a phone page takes there ([PhonePageColumn]), as
/// Settings' list is (it ran the full width beside it, found by the device run
/// of 13 November 2026).
/// On desktop, centers the body within a [maxWidth] container and
/// adds proper padding for a polished desktop look.
class ResponsiveScaffold extends StatelessWidget {
  final String title;
  final Widget body;
  final List<Widget>? actions;
  final double maxWidth;
  final bool showBackButton;

  const ResponsiveScaffold({
    super.key,
    required this.title,
    required this.body,
    this.actions,
    this.maxWidth = 1100,
    this.showBackButton = true,
  });

  @override
  Widget build(BuildContext context) {
    if (isTouchLayout) {
      return Scaffold(
        appBar: AppBar(
          title: Text(title),
          automaticallyImplyLeading: showBackButton,
          actions: actions,
        ),
        body: PhonePageColumn(child: body),
      );
    }

    // Desktop: centered, constrained content with card-like appearance.
    // Use LayoutBuilder + padding instead of Center > ConstrainedBox so that
    // scroll views inside the body receive pointer events (e.g. mouse-wheel)
    // from the full scaffold width, not just the constrained centre strip.
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(title),
        automaticallyImplyLeading: showBackButton,
        actions: actions,
        centerTitle: false,
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final sidePadding =
              ((constraints.maxWidth - maxWidth) / 2).clamp(0.0, double.infinity);
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: sidePadding),
            child: body,
          );
        },
      ),
    );
  }
}

/// Wraps a [ListView] or [SingleChildScrollView] body with desktop constraints.
///
/// Use this when you already have a Scaffold and just want to constrain
/// the body's width on desktop.
class DesktopContentWrapper extends StatelessWidget {
  final Widget child;
  final double maxWidth;

  const DesktopContentWrapper({
    super.key,
    required this.child,
    this.maxWidth = 1100,
  });

  @override
  Widget build(BuildContext context) {
    if (!isDesktopPlatform) return child;

    return LayoutBuilder(
      builder: (context, constraints) {
        final sidePadding =
            ((constraints.maxWidth - maxWidth) / 2).clamp(0.0, double.infinity);
        return Padding(
          padding: EdgeInsets.symmetric(horizontal: sidePadding),
          child: child,
        );
      },
    );
  }
}
