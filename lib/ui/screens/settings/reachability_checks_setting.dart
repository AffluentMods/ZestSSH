import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/settings/widgets/choice_sheet.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Turns the checks of whether hosts can be reached on or off, from every
/// switch there is for them.
///
/// Turning them on asks first, and says what a check is: a connection to
/// the host that is closed without signing in, which the host sees, an SSH
/// server logs, and a server that bans addresses for such connections may
/// ban this device for them (as fail2ban's sshd
/// jail in its ddos mode did). Nothing is turned on unless its person says
/// so there. Turning them off asks nothing.
Future<void> setReachabilityChecks(BuildContext context, WidgetRef ref, bool on) async {
  final updater = ref.read(settingsUpdaterProvider);
  if (!on) {
    await updater.setHealthChecksEnabled(false);
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  final yes = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.reachChecksAskTitle,
    body: l10n.reachChecksAskBody,
    bullets: [
      l10n.reachChecksAskSeen,
      l10n.reachChecksAskSkipped,
      l10n.reachChecksAskMonitor,
    ],
    // The one sentence that warns, in amber (3.4): it was a bullet like the
    // others.
    warning: l10n.reachChecksAskBan,
    confirmLabel: l10n.reachChecksAskTurnOn,
  );
  if (yes == true) await updater.setHealthChecksEnabled(true);
}

/// How often the checks run, offered alike on every device, in seconds. A
/// phone offered no 2 minutes, which a computer's setting, synced, holds.
const reachabilityCheckIntervals = [30, 60, 120, 300];

/// [seconds] between checks as a person reads it: 30 seconds, 1, 2 or 5
/// minutes, whatever it is. A phone said 5 minutes for 2.
String reachabilityCheckIntervalLabel(AppLocalizations l10n, int seconds) => seconds % 60 == 0
    ? l10n.settingsInlineMinutesOption(seconds ~/ 60)
    : l10n.settingsInlineSecondsOption(seconds);

/// A phone's choice of how often the checks run, from either page that has
/// it: the intervals a computer offers, the one set checked, in the app's
/// sheet (a centred dialog of radio buttons before).
Future<void> showReachabilityIntervalPicker(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final picked = await showSettingsChoice<int>(
    context,
    title: l10n.settingsInlineCheckInterval,
    icon: LucideIcons.timer,
    current: ref.read(healthCheckIntervalProvider),
    choices: [for (final seconds in reachabilityCheckIntervals) (seconds, reachabilityCheckIntervalLabel(l10n, seconds))],
    keyOf: (seconds) => ValueKey('reach-interval-$seconds'),
  );
  if (picked != null) await ref.read(settingsUpdaterProvider).setHealthCheckInterval(picked.$1);
}
