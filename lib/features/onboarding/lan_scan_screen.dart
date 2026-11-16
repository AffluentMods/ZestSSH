import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/onboarding/widgets/lan_scan_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Standalone local-network scan screen - the same [LanScanView] the first-run
/// flow uses, reachable from the empty host grid so the "scan" path is
/// available after onboarding too.
class LanScanScreen extends StatelessWidget {
  const LanScanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.networkScanTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width =
                constraints.maxWidth < 560 ? constraints.maxWidth : 560.0;
            return Center(
              child: SizedBox(
                width: width,
                height: constraints.maxHeight,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: LanScanView(
                    onAdded: (added, failedLimit) {
                      if (added > 0) {
                        showTopSnackBar(
                          context,
                          l10n.sshImportImportedCount(added),
                          isSuccess: true,
                        );
                        if (context.mounted) context.pop();
                      } else if (failedLimit > 0) {
                        showTopSnackBar(
                          context,
                          l10n.sshImportSomeFailed(failedLimit),
                          isError: true,
                        );
                      }
                    },
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
