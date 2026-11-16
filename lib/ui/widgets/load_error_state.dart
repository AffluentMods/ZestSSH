import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/utils/error_report.dart';

/// What a page or a list shows when what it shows could not be loaded (3.0):
/// what went wrong, Try again, and the details to copy, the
/// report of the failure (scrubbed). The hosts page said so with no details
/// (it printed the error to a console nobody sees), and the phone's lists
/// of hosts, keys and forwarded ports had neither Try again nor details.
class LoadErrorState extends StatelessWidget {
  const LoadErrorState({
    super.key,
    required this.message,
    required this.where,
    required this.error,
    this.stack,
    this.hint,
    this.onRetry,
    this.icon = LucideIcons.alertCircle,
  });

  /// What went wrong, in the app's language.
  final String message;

  /// What the app was loading, in English, for the report.
  final String where;

  final Object error;
  final StackTrace? stack;

  /// A line under the message (what else may help).
  final String? hint;

  /// Loads it again; no button when null.
  final VoidCallback? onRetry;

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: AppColors.v3TextTertiary),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 15, fontWeight: FontWeight.w600),
            ),
            if (hint != null) ...[
              const SizedBox(height: 4),
              Text(
                hint!,
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 12.5),
              ),
            ],
            const SizedBox(height: 14),
            if (onRetry != null)
              FilledButton.icon(
                key: const ValueKey('load-error-retry'),
                onPressed: onRetry,
                icon: const Icon(LucideIcons.refreshCw, size: 18),
                label: Text(l10n.retry),
                style: FilledButton.styleFrom(backgroundColor: AppColors.v3AccentPrimary),
              ),
            const SizedBox(height: 4),
            CopyDetailsButton(
              detail: ErrorReport.build(what: message, where: where, error: error, stack: stack),
            ),
          ],
        ),
      ),
    );
  }
}
