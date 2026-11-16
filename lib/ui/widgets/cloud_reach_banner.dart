import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

// How ZestSSH Cloud stands, where the app shows it while something is in
// the way of it (3.0): in a computer's status bar (StatusBarCloudItem,
// desktop_status_bar.dart) and, on a phone, in the banner below. What both
// share is here, so that they say the same thing of the same situation.

/// Since when, as it is said beside how the service stands: the time of day,
/// and the day with it when that was not today. For an outage that is proven
/// it is since when the service has been down, which may be long before this
/// device noticed.
String? cloudSinceText(CloudReachState state, String locale, {DateTime? now}) {
  final since = (state.outageSince ?? state.since)?.toLocal();
  if (since == null) return null;
  final today = now ?? DateTime.now();
  final sameDay = since.year == today.year && since.month == today.month && since.day == today.day;
  final time = '${since.hour.toString().padLeft(2, '0')}:${since.minute.toString().padLeft(2, '0')}';
  if (sameDay) return time;
  String day;
  try {
    day = DateFormat.MMMd(locale).format(since);
  } catch (_) {
    // A language the date formats were not loaded for: the day in figures.
    day = '${since.year}-${since.month.toString().padLeft(2, '0')}-${since.day.toString().padLeft(2, '0')}';
  }
  return '$day, $time';
}

/// The mark of [failure]: which sign, and red where the service itself is
/// failing (ours), amber where what is in the way is on this side.
(IconData, Color) cloudFailureMark(CloudFailure failure) => (
      switch (failure.kind) {
        CloudFailureKind.down || CloudFailureKind.fault || CloudFailureKind.notResponding => LucideIcons.cloudOff,
        CloudFailureKind.deviceOffline => LucideIcons.wifiOff,
        CloudFailureKind.nothingReached => LucideIcons.globe2,
        CloudFailureKind.blockedHere => LucideIcons.ban,
        CloudFailureKind.notSecure => LucideIcons.shieldAlert,
      },
      failure.onThisSide ? AppColors.v3Warning : AppColors.v3Error,
    );

/// Asks the service how it is, there and then, and says what came of it:
/// the whole of what is wrong, with its code and what was caught to copy,
/// or that it is answering again.
Future<void> checkCloudAgain(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final after = await ref.read(cloudReachProvider).checkNow();
  if (!context.mounted) return;
  final failure = cloudFailureOfReach(after);
  if (failure != null) {
    showTopSnackBar(context, failure.message(l10n), isWarning: true, details: failure.detail);
  } else {
    showTopSnackBar(context, l10n.cloudAnsweringAgain, isSuccess: true);
  }
}

/// On a phone: how ZestSSH Cloud stands, while something is in the way of
/// it ([cloudReachStateProvider]). A computer says it in its status bar; a
/// phone has none, and until this was here it said nothing until something
/// its person asked for failed.
///
/// One line of what is wrong, in the status bar's words, and since when. A
/// tap asks the service again and says the whole of it. Nothing shows, and
/// no room is taken, while all is well or while nothing on this device uses
/// the service.
class CloudReachBanner extends ConsumerStatefulWidget {
  const CloudReachBanner({super.key});

  @override
  ConsumerState<CloudReachBanner> createState() => _CloudReachBannerState();
}

class _CloudReachBannerState extends ConsumerState<CloudReachBanner> {
  bool _checking = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await checkCloudAgain(context, ref);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(cloudReachStateProvider).valueOrNull ?? const CloudReachState.unknown();
    final failure = cloudFailureOfReach(state);
    if (failure == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    final label = failure.label(l10n);
    final (icon, color) = cloudFailureMark(failure);
    final at = cloudSinceText(state, Localizations.localeOf(context).toString());
    final more = at == null ? l10n.cloudBannerTap : l10n.cloudBannerSince(at);
    return Semantics(
      container: true,
      button: true,
      label: '$label. $more',
      child: Material(
        color: AppColors.v3Surface,
        child: InkWell(
          key: const ValueKey('cloud-reach-banner'),
          onTap: _check,
          child: Container(
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle, width: 0.8)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Icon(icon, size: 18, color: color),
                const SizedBox(width: 10),
                Expanded(
                  child: ExcludeSemantics(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          label,
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                        ),
                        const SizedBox(height: 1),
                        Text(more, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextSecondary)),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                if (_checking)
                  const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                else
                  Icon(LucideIcons.refreshCw, size: 14, color: AppColors.v3TextTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
