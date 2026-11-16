import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/zest_colors.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router/routes.dart';
import '../models/app_notification.dart';
import '../needs_you.dart';
import '../notification_center.dart';

/// The mobile home app-bar bell (mobile notifications).
///
/// Unlike the desktop [NotificationBell] (a popover), the mobile bell PUSHES the
/// notifications route so it can hide the tab bar and the floating home button.
///
/// The bell itself is monochrome; state lives in the badge:
///   - all read  -> no badge, glyph at [ZestColors.textTertiary]
///   - unread    -> badge present, glyph at [ZestColors.textSecondary]
///
/// The badge colour is SEVERITY, never brand: it takes the loudest unread
/// severity (error -> warning -> otherwise a neutral chip). Brand orange never
/// carries state. Counts above nine render as "9+".
class MobileNotificationBell extends ConsumerWidget {
  const MobileNotificationBell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationCenterProvider);
    // The badge counts the unread messages and what needs the person now
    // (3.1: the center's "Needs you" rows), each once; its colour is the
    // loudest of either.
    final needs = ref.watch(needsYouProvider);
    final unread = state.unreadCount + needs.length;
    final loudest = _louder(_loudestUnread(state.history), switch (needsYouCritical(needs)) {
      true => NotificationSeverity.error,
      false => NotificationSeverity.warning,
      null => null,
    });

    return IconButton(
      tooltip: AppLocalizations.of(context)!.notificationsBellTooltip,
      onPressed: () => context.push(Routes.notifications),
      icon: SizedBox(
        width: 24,
        height: 24,
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Center(
              child: Icon(
                LucideIcons.bell,
                size: 22,
                color: unread > 0
                    ? ZestColors.textSecondary
                    : ZestColors.textTertiary,
              ),
            ),
            if (unread > 0 && loudest != null)
              Positioned(
                top: -4,
                right: -5,
                child: _Badge(count: unread, severity: loudest),
              ),
          ],
        ),
      ),
    );
  }

  /// The louder of two badge severities (null: nothing).
  static NotificationSeverity? _louder(NotificationSeverity? a, NotificationSeverity? b) {
    int rank(NotificationSeverity? s) => switch (s) {
          NotificationSeverity.error => 3,
          NotificationSeverity.warning => 2,
          null => 0,
          _ => 1,
        };
    return rank(a) >= rank(b) ? a : b;
  }

  /// The loudest severity among UNREAD entries, or null when nothing is unread.
  /// info and success collapse to [NotificationSeverity.info] ("some unread, but
  /// nothing louder than informational") which renders as the neutral chip.
  static NotificationSeverity? _loudestUnread(List<AppNotification> history) {
    var anyError = false;
    var anyWarning = false;
    var anyOther = false;
    for (final n in history) {
      if (n.isRead) continue;
      switch (n.severity) {
        case NotificationSeverity.error:
          anyError = true;
        case NotificationSeverity.warning:
          anyWarning = true;
        case NotificationSeverity.info:
        case NotificationSeverity.success:
          anyOther = true;
      }
    }
    if (anyError) return NotificationSeverity.error;
    if (anyWarning) return NotificationSeverity.warning;
    if (anyOther) return NotificationSeverity.info;
    return null;
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.count, required this.severity});

  final int count;
  final NotificationSeverity severity;

  @override
  Widget build(BuildContext context) {
    // Severity ramp reuses the app's status tokens (same ones the toast + the
    // desktop bell use) so a failed transfer looks identical everywhere. Only
    // warning/error tint the badge; info/success ride the neutral chip.
    final Color bg;
    final Color fg;
    final Color border;
    switch (severity) {
      case NotificationSeverity.error:
        bg = ZestColors.statusError;
        fg = const Color(0xFF2A0B09);
        border = ZestColors.statusError;
      case NotificationSeverity.warning:
        bg = ZestColors.statusWarning;
        fg = const Color(0xFF241A05);
        border = ZestColors.statusWarning;
      case NotificationSeverity.info:
      case NotificationSeverity.success:
        bg = ZestColors.surfaceChip;
        fg = ZestColors.textPrimary;
        border = ZestColors.borderDefault;
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: border, width: 1),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 9 ? AppLocalizations.of(context)!.notificationsBadgeOverflow : '$count',
        style: TextStyle(
          fontSize: 10,
          height: 1,
          fontWeight: FontWeight.w600,
          color: fg,
        ),
      ),
    );
  }
}
