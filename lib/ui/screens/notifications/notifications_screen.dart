import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/zest_colors.dart';
import '../../../features/notifications/models/app_notification.dart';
import '../../../features/notifications/needs_you.dart';
import '../../../features/notifications/notification_center.dart';
import '../../../features/notifications/notification_permission_provider.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../router/routes.dart';
import '../../../models/redactable.dart';
import '../../../services/notification_service.dart';
import '../../widgets/copy_details_button.dart';
import '../../widgets/redacted_text.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/time_ago.dart';

// NOTE (Slice 2): the overflow "Notification settings" opens the existing prefs
// sheet; the dedicated settings screen (spec Step 5) and the OS-permission
// banner (Step 6) are separate follow-ups (both need work beyond these screens:
// new prefs / a new dependency). Deep-link destinations depend on each
// notification's action, set by whoever posts it.

/// The Today / Yesterday / Earlier buckets, kept as a stable enum so the
/// grouping does not depend on a localised label.
enum _Bucket { today, yesterday, earlier }

/// Mobile notifications history (Design: mobile notifications, Steps 2-4).
///
/// A pushed route (its own AppBar with a back chevron), so it covers the tab bar
/// and the floating home button. Reads the shared [notificationCenterProvider];
/// tapping a row marks it read (and runs its action if any), swiping dismisses
/// one row.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Request the OS permission at most once per app session, the first time the
  /// user opens this screen.
  static bool _permissionRequestedThisSession = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance
        .addPostFrameCallback((_) => _ensurePermissionRequested());
  }

  Future<void> _ensurePermissionRequested() async {
    if (_permissionRequestedThisSession) return;
    _permissionRequestedThisSession = true;
    if (await NotificationService.areEnabled()) return;
    // Not yet granted: show the standard OS prompt instead of sending a fresh
    // user straight to system settings. iOS prompts only while notDetermined;
    // Android 13+ prompts until a permanent denial. Re-check after so the banner
    // appears only on a REAL denial, never on first launch.
    await NotificationService.requestPermission();
    if (mounted) ref.invalidate(notificationsEnabledProvider);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final state = ref.watch(notificationCenterProvider);
    final center = ref.read(notificationCenterProvider.notifier);
    final items = [...state.history]
      ..sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return Scaffold(
      backgroundColor: ZestColors.surfacePanel,
      appBar: AppBar(
        leading: const BackButton(),
        title: Text(l10n.notificationsTitle),
        actions: [
          PopupMenuButton<String>(
            tooltip: l10n.notificationsMore,
            icon: const Icon(LucideIcons.moreVertical),
            color: ZestColors.chromeElevated,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: BorderSide(color: ZestColors.borderStrong),
            ),
            onSelected: (v) {
              switch (v) {
                case 'read':
                  center.markAllRead();
                case 'clear':
                  center.clearAll();
                case 'settings':
                  context.push(Routes.notificationSettings);
              }
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'read',
                enabled: state.anyUnseen,
                child: Text(l10n.notificationsMarkAllRead),
              ),
              PopupMenuItem(
                value: 'clear',
                enabled: state.history.isNotEmpty,
                child: Text(l10n.notificationsClearAll),
              ),
              const PopupMenuDivider(),
              PopupMenuItem(
                value: 'settings',
                child: Text(l10n.notificationsSettingsTitle),
              ),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          // Permission-denied banner (only on a real OS denial). In-app history
          // still works, so the list stays below it.
          if (ref.watch(notificationsEnabledProvider).maybeWhen(
              data: (enabled) => !enabled, orElse: () => false))
            const _PermissionBanner(),
          // What needs the person now heads the screen (3.1); the past
          // messages follow as they were. With no message, and something
          // that needs them, the section alone.
          Expanded(
            child: items.isEmpty
                ? (ref.watch(needsYouProvider).isEmpty
                    ? const _EmptyState()
                    : ListView(children: const [NeedsYouSection()]))
                : _buildList(context, l10n, center, items),
          ),
        ],
      ),
    );
  }

  Widget _buildList(
    BuildContext context,
    AppLocalizations l10n,
    NotificationCenter center,
    List<AppNotification> items,
  ) {
    final now = DateTime.now();
    final groups = <_Bucket, List<AppNotification>>{
      _Bucket.today: [],
      _Bucket.yesterday: [],
      _Bucket.earlier: [],
    };
    for (final n in items) {
      groups[_bucketFor(n.createdAt, now)]!.add(n);
    }

    String labelFor(_Bucket b) => switch (b) {
          _Bucket.today => l10n.notificationsGroupToday,
          _Bucket.yesterday => l10n.notificationsGroupYesterday,
          _Bucket.earlier => l10n.notificationsGroupEarlier,
        };

    final children = <Widget>[const NeedsYouSection()];
    for (final bucket in _Bucket.values) {
      final group = groups[bucket]!;
      if (group.isEmpty) continue;
      children.add(_SectionHeader(
        label: labelFor(bucket),
        markReadLabel: l10n.notificationsMarkRead,
        // Only the Today group carries a "Mark read" action, and only when it
        // has something unread.
        onMarkRead: bucket == _Bucket.today && group.any((n) => !n.isRead)
            ? () => center.markReadWhere(
                (n) => _bucketFor(n.createdAt, DateTime.now()) == _Bucket.today)
            : null,
      ));
      for (final n in group) {
        children.add(_NotificationRow(
          notification: n,
          onTap: () {
            center.markRead(n.id);
            n.onAction?.call();
          },
          onDismiss: () => center.remove(n.id),
        ));
      }
    }

    return ListView(padding: const EdgeInsets.only(top: 8), children: children);
  }

  static _Bucket _bucketFor(DateTime t, DateTime now) {
    final day = DateTime(t.year, t.month, t.day);
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return _Bucket.today;
    if (diff == 1) return _Bucket.yesterday;
    return _Bucket.earlier;
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.label,
    required this.markReadLabel,
    this.onMarkRead,
  });

  final String label;
  final String markReadLabel;
  final VoidCallback? onMarkRead;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 8),
      child: Row(
        children: [
          Container(
            width: 2,
            height: 10,
            decoration: BoxDecoration(
              color: ZestColors.accentPrimary,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.88, // .08em at 11px
              color: ZestColors.textMuted,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
              child: Divider(height: 1, color: ZestColors.borderDefault)),
          if (onMarkRead != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: onMarkRead,
              behavior: HitTestBehavior.opaque,
              child: Text(
                markReadLabel,
                style: TextStyle(
                    fontSize: 11.5, color: ZestColors.textSecondary),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _NotificationRow extends StatelessWidget {
  const _NotificationRow({
    required this.notification,
    required this.onTap,
    required this.onDismiss,
  });

  final AppNotification notification;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final n = notification;
    final unread = !n.isRead;

    return Dismissible(
      key: ValueKey(n.id),
      direction: DismissDirection.endToStart,
      onDismissed: (_) => onDismiss(),
      background: Container(
        color: ZestColors.chromeElevated,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 20),
        child: Icon(LucideIcons.x, size: 18, color: ZestColors.textTertiary),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: unread ? ZestColors.chromeElevated : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: unread
                  ? const Color(0x0BFFFFFF) // --edge, ~4.5% white hairline
                  : ZestColors.borderDefault,
              width: 1,
            ),
          ),
        ),
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 40),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(_glyphFor(n.severity),
                        size: 16, color: _colorFor(n.severity)),
                  ),
                  const SizedBox(width: 11),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Recording mode: a notification title can name a host,
                        // an identity or an address (`The certificate of Alex
                        // has run out`, `prod-db cannot be reached`), so it
                        // goes through the free-text rule, which masks any
                        // registered name or address-shaped token embedded in
                        // it.
                        RedactedText(
                          Redactable.freeText(n.title),
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.35,
                            fontWeight:
                                unread ? FontWeight.w500 : FontWeight.w400,
                            color: unread
                                ? ZestColors.textPrimary
                                : ZestColors.textSecondary,
                          ),
                        ),
                        if (n.body != null && n.body!.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: RedactedText(
                              Redactable.freeText(n.body!),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.45,
                                color: ZestColors.textMuted,
                              ),
                            ),
                          ),
                        if (n.actionLabel != null && n.onAction != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text(
                              n.actionLabel!,
                              style: TextStyle(
                                  fontSize: 12, color: ZestColors.textSecondary),
                            ),
                          ),
                        // What stands behind an error, for as long as the
                        // app runs (it is not kept with the history).
                        if (n.details != null)
                          Align(
                            alignment: AlignmentDirectional.centerStart,
                            child: CopyDetailsButton(detail: n.details!),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      timeAgoShort(AppLocalizations.of(context)!, n.createdAt),
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 10.5,
                        color: ZestColors.textMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static IconData _glyphFor(NotificationSeverity s) {
    switch (s) {
      case NotificationSeverity.info:
        return LucideIcons.info;
      case NotificationSeverity.success:
        return LucideIcons.checkCircle2;
      case NotificationSeverity.warning:
        return LucideIcons.alertTriangle;
      case NotificationSeverity.error:
        return LucideIcons.alertCircle;
    }
  }

  static Color _colorFor(NotificationSeverity s) {
    switch (s) {
      case NotificationSeverity.info:
        return ZestColors.textTertiary;
      case NotificationSeverity.success:
        return ZestColors.statusSuccess;
      case NotificationSeverity.warning:
        return ZestColors.statusWarning;
      case NotificationSeverity.error:
        return ZestColors.statusError;
    }
  }

}

/// Shown above the list when the OS notification permission is denied. In-app
/// history still works, so this explains the gap and offers the one fix. The
/// only place on the screen where a sentence is the content, not an action.
class _PermissionBanner extends StatelessWidget {
  const _PermissionBanner();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 2),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: ColoredBox(
          color: ZestColors.chromeElevated,
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(width: 2, color: ZestColors.statusWarning),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 11, 12, 11),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.notificationsPermissionOff,
                          style: TextStyle(
                            fontSize: 12.5,
                            height: 1.45,
                            color: ZestColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 7),
                        GestureDetector(
                          onTap: NotificationService.openSystemSettings,
                          behavior: HitTestBehavior.opaque,
                          child: Text(
                            l10n.notificationsOpenSystemSettings,
                            style: TextStyle(
                                fontSize: 12, color: ZestColors.textPrimary),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.bell,
                size: 44, color: ZestColors.textMuted),
            const SizedBox(height: 16),
            Text(
              l10n.notificationsEmptyTitle,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: ZestColors.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l10n.notificationsEmptyMessage,
              textAlign: TextAlign.center,
              style: TextStyle(
                  fontSize: 13, height: 1.5, color: ZestColors.textTertiary),
            ),
            const SizedBox(height: 22),
            FilledButton(
              onPressed: () => context.push(Routes.notificationSettings),
              child: Text(l10n.notificationsSettingsTitle),
            ),
          ],
        ),
      ),
    );
  }
}
