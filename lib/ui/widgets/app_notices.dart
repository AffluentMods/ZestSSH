import 'package:flutter/widgets.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Said when the app is back in front and sessions dropped while it was in
/// the background (iOS closes their connections): that they are being
/// connected again, or, when that is off, that they were disconnected; Why?
/// explains. (3.0: it said "Reconnecting" in English whether or
/// not anything was connecting again, and was never shown.)
void showResumeNotice(
  BuildContext context, {
  required int dropped,
  required bool reconnecting,
  required VoidCallback onWhy,
}) {
  final l10n = AppLocalizations.of(context)!;
  showTopSnackBar(
    context,
    reconnecting ? l10n.resumeReconnecting(dropped) : l10n.resumeDisconnected(dropped),
    isInfo: true,
    duration: const Duration(seconds: 5),
    actionLabel: l10n.resumeWhy,
    onAction: onWhy,
  );
}

/// Said when the app is back in front on iOS and the remote screens it closed
/// in the background are connecting again (4.0, ScreenBackgroundKeeper).
void showScreensBackNotice(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  showTopSnackBar(context, l10n.screenBackgroundBack, isInfo: true, duration: const Duration(seconds: 4));
}
