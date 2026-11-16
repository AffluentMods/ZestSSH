import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// The upgrade page of a build with no plans to buy (a community build:
/// lib/config/official_identity.dart, `zestHasPlans`). Whatever in the app
/// says a feature needs a plan leads to the upgrade page, so this is the one
/// place that says there is none here, and offers nothing.
class NoPlansHere extends StatelessWidget {
  const NoPlansHere({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      key: const ValueKey('no-plans-here'),
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.noPlansTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 440),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExcludeSemantics(child: Icon(LucideIcons.packageOpen, size: 36, color: ZestTokens.textSecondary)),
                const SizedBox(height: 16),
                Text(
                  l10n.noPlansBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, height: 1.5, color: ZestTokens.textPrimary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
