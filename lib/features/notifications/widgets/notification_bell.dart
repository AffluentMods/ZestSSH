import 'package:zestssh/features/notifications/widgets/notification_prefs_sheet.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../core/theme/zest_colors.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/redactable.dart';
import '../../../ui/widgets/copy_details_button.dart';
import '../../../ui/widgets/redacted_text.dart';
import '../../../ui/widgets/zest_empty_state.dart';
import '../models/app_notification.dart';
import '../notification_center.dart';
import 'notification_toast_overlay.dart' show NotificationCount;
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Bell icon with unread badge for the desktop chrome strip. Click
/// opens a popover with the full notification history (most recent
/// first) - IntelliJ-style.
class NotificationBell extends ConsumerStatefulWidget {
  const NotificationBell({super.key});

  @override
  ConsumerState<NotificationBell> createState() => _NotificationBellState();
}

class _NotificationBellState extends ConsumerState<NotificationBell> {
  final GlobalKey _anchorKey = GlobalKey();
  bool _hover = false;
  OverlayEntry? _entry;

  @override
  void dispose() {
    _entry?.remove();
    super.dispose();
  }

  void _toggle() {
    if (_entry != null) {
      _close();
      return;
    }
    final ctx = _anchorKey.currentContext;
    if (ctx == null) return;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return;
    final origin = box.localToGlobal(Offset.zero);

    _entry = OverlayEntry(builder: (overlayContext) {
      return _BellOverlay(
        anchorRight: MediaQuery.of(overlayContext).size.width -
            origin.dx -
            box.size.width,
        anchorTop: origin.dy + box.size.height + 6,
        onDismiss: _close,
      );
    });
    Overlay.of(context).insert(_entry!);
  }

  void _close() {
    _entry?.remove();
    _entry = null;
    // Mark everything read on close so the badge clears.
    ref.read(notificationCenterProvider.notifier).markAllRead();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(notificationCenterProvider);
    final unread = state.unreadCount;
    // In the app's language (it was English), and what the count is: the
    // warnings and errors not yet seen.
    final l10n = AppLocalizations.of(context)!;
    final label = unread > 0 ? l10n.notifBellUnreadTooltip(unread) : l10n.notificationsBellTooltip;
    final touch = touchSizedAt(context);

    return Tooltip(
      message: label,
      child: Semantics(
        button: true,
        label: label,
        child: MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        key: _anchorKey,
        onTap: _toggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          // A finger's 48 where the controls are touch sized (4.0).
          constraints: touch ? const BoxConstraints(minWidth: 48, minHeight: 48) : null,
          alignment: touch ? Alignment.center : null,
          decoration: BoxDecoration(
            color:
                _hover ? ZestColors.bgSurface : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              Icon(LucideIcons.bell,
                  size: touch ? 20 : 16, color: ZestColors.textSecondary),
              if (unread > 0)
                Positioned(
                  top: -4,
                  right: -6,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 14),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: ZestColors.accentPrimary,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      unread > 9 ? '9+' : '$unread',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.0,
                      ),
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
}

/// Full-screen tap-catcher + the actual popover. Clicking anywhere
/// outside closes the overlay.
class _BellOverlay extends ConsumerWidget {
  const _BellOverlay({
    required this.anchorRight,
    required this.anchorTop,
    required this.onDismiss,
  });

  final double anchorRight;
  final double anchorTop;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        // Click-outside dismiss
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: onDismiss,
            // Not a control to a screen reader (an unnamed button the size
            // of the window): Esc and the bell close the panel.
            excludeFromSemantics: true,
          ),
        ),
        Positioned(
          right: anchorRight,
          top: anchorTop,
          child: _BellPopover(onDismiss: onDismiss),
        ),
      ],
    );
  }
}

class _BellPopover extends ConsumerWidget {
  const _BellPopover({required this.onDismiss});
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationCenterProvider);
    final history = state.history;

    // Collapse duplicates (same severity + title + body) into one row with a
    // ×N count so a flapping event doesn't bury the list (A5). Order follows
    // the most-recent occurrence; dismissing a group removes every instance.
    final groups = <({AppNotification rep, List<String> ids})>[];
    // How many times each was said: one that was said again while it stood
    // on screen counts for as many ([AppNotification.repeats]).
    final said = <int>[];
    final idxByKey = <String, int>{};
    for (final n in history) {
      final key = '${n.severity.index}|${n.title}|${n.body ?? ''}';
      final i = idxByKey[key];
      if (i != null) {
        groups[i].ids.add(n.id);
        said[i] += n.repeats;
      } else {
        idxByKey[key] = groups.length;
        groups.add((rep: n, ids: [n.id]));
        said.add(n.repeats);
      }
    }

    return CallbackShortcuts(
      // Keyboard path: Esc closes the popover.
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): onDismiss,
      },
      child: Focus(
        autofocus: true,
        child: Material(
      color: Colors.transparent,
      child: Container(
        width: 360,
        constraints: const BoxConstraints(maxHeight: 480),
        decoration: BoxDecoration(
          // A menu's surface, as every pop-over's: its words read on it (the
          // strong border's grey it was drawn on held the muted words at
          // 3.3:1, and the empty bell's glyph at 2:1).
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestColors.borderDefault, width: 0.6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _Header(
              count: groups.length,
              onClearAll: history.isEmpty
                  ? null
                  : () {
                      ref
                          .read(notificationCenterProvider.notifier)
                          .clearAll();
                      onDismiss();
                    },
              // The gear lands on Settings > Notifications (the page that
              // owns these toggles); legacy layouts without inline Settings
              // keep the modal sheet.
              onManage: () {
                if (jumpToDesktopSettings(
                    ref, SettingsJumpTarget.notifications)) {
                  onDismiss();
                } else {
                  showNotificationPrefsSheet(context);
                }
              },
            ),
            Divider(
                height: 1, color: ZestColors.borderSubtle, thickness: 0.5),
            Flexible(
              child: groups.isEmpty
                  ? const _EmptyState()
                  : ListView.separated(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: groups.length,
                      separatorBuilder: (_, _) => Divider(
                        height: 1,
                        color: ZestColors.borderSubtle,
                        thickness: 0.4,
                        indent: 12,
                        endIndent: 12,
                      ),
                      itemBuilder: (_, i) => _Row(
                        notification: groups[i].rep,
                        count: said[i],
                        onRemove: () {
                          final notifier = ref
                              .read(notificationCenterProvider.notifier);
                          for (final id in groups[i].ids) {
                            notifier.remove(id);
                          }
                        },
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

class _Header extends StatelessWidget {
  const _Header(
      {required this.count, required this.onClearAll, required this.onManage});
  final int count;
  final VoidCallback? onClearAll;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      child: Row(
        children: [
          Text(
            AppLocalizations.of(context)!.notificationsTitle,
            style: TextStyle(
              color: ZestColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          if (count > 0)
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: ZestColors.bgSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  color: ZestColors.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const Spacer(),
          // Quick-manage what gets sent here, without leaving the panel.
          IconButton(
            onPressed: onManage,
            icon: const Icon(LucideIcons.slidersHorizontal, size: 16),
            color: ZestColors.textSecondary,
            tooltip: AppLocalizations.of(context)!.notificationsSettingsTitle,
            // A mouse's 32 square at least, a finger's 48 (the compact
            // density drew it 28 by 20).
            visualDensity: VisualDensity.standard,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            constraints: BoxConstraints(minWidth: minTapTarget(context), minHeight: minTapTarget(context)),
          ),
          if (onClearAll != null)
            TextButton(
              onPressed: onClearAll,
              style: TextButton.styleFrom(
                foregroundColor: ZestColors.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size(0, minTapTarget(context)),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text(
                AppLocalizations.of(context)!.notificationsClearAll,
                style: const TextStyle(fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Notifications are received, never created by the user - this is a
    // passive informational state, so it carries no call to action.
    return ZestEmptyState(
      icon: LucideIcons.bellOff,
      iconSize: 32,
      title: l10n.notificationsEmptyTitle,
      message: l10n.notificationsEmptyMessage,
    );
  }
}

class _Row extends StatefulWidget {
  const _Row({
    required this.notification,
    required this.onRemove,
    this.count = 1,
  });
  final AppNotification notification;
  final VoidCallback onRemove;

  /// How many collapsed duplicates this row represents (A5). >1 shows a ×N.
  final int count;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.notification;
    final accent = _accentForSeverity(n.severity);
    final l10n = AppLocalizations.of(context)!;

    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        color: _hover
            ? ZestColors.bgSurface.withValues(alpha: 0.5)
            : Colors.transparent,
        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(
                _iconForSeverity(n.severity),
                size: 14,
                color: accent,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        // A title or body routinely names the host it is
                        // about: free-text redaction (recording mode).
                        child: RedactedText(
                          Redactable.freeText(n.title),
                          style: TextStyle(
                            color: ZestColors.textPrimary,
                            fontSize: 12,
                            fontWeight:
                                n.isRead ? FontWeight.w500 : FontWeight.w600,
                          ),
                          // The panel shows the full message (unlike the toast,
                          // which stays terse) so nothing is cut off.
                        ),
                      ),
                      if (widget.count > 1) ...[
                        const SizedBox(width: 6),
                        NotificationCount(
                          key: const ValueKey('bell-count'),
                          count: widget.count,
                          accent: accent,
                        ),
                      ],
                      const SizedBox(width: 6),
                      // Relative time by default; hover for the absolute
                      // timestamp (A5).
                      Tooltip(
                        message: '${DateFormat.yMMMd(l10n.localeName).format(n.createdAt)} · '
                            '${DateFormat.Hms(l10n.localeName).formatPlain(n.createdAt)}',
                        waitDuration: const Duration(milliseconds: 300),
                        child: Text(
                          timeAgoShort(l10n, n.createdAt),
                          style: TextStyle(
                            color: ZestColors.textTertiary,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (n.body != null) ...[
                    const SizedBox(height: 2),
                    RedactedText(
                      Redactable.freeText(n.body!),
                      style: TextStyle(
                        color: ZestColors.textSecondary,
                        fontSize: 11,
                        height: 1.35,
                      ),
                    ),
                  ],
                  // Actionable fix-action (A5) - the model + toasts already
                  // support onAction/actionLabel; surface it in the persistent
                  // panel too so a warning like "Host key changed → Review"
                  // stays actionable after its toast has gone.
                  if (n.actionLabel != null && n.onAction != null) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: _RowAction(
                        label: n.actionLabel!,
                        accent: accent,
                        onTap: () {
                          // A bell notification can outlive the widget that
                          // registered its onAction, so the captured closure
                          // may touch a disposed State. Guard exactly like the
                          // toast does, then clear the resolved notification.
                          try {
                            n.onAction?.call();
                          } catch (_) {/* stale closure - ignore */}
                          widget.onRemove();
                        },
                      ),
                    ),
                  ],
                  // What stands behind an error stays to be copied for as
                  // long as the entry does (until the app is closed).
                  if (n.details != null) ...[
                    const SizedBox(height: 2),
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: CopyDetailsButton(detail: n.details!, color: accent),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 4),
            // Always rendered + hit-testable (was hover-only, so it was
            // unreachable by touch / keyboard); hover just raises its opacity.
            Semantics(
              button: true,
              label: AppLocalizations.of(context)!.desktopDismiss,
              child: Tooltip(
                message: AppLocalizations.of(context)!.desktopDismiss,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 120),
                  opacity: _hover ? 1 : 0.35,
                  child: GestureDetector(
                    onTap: widget.onRemove,
                    child: Padding(
                      padding: const EdgeInsets.all(4),
                      child: Icon(
                        LucideIcons.x,
                        size: 12,
                        color: ZestColors.textTertiary,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact accent-coloured action button for a bell row (A5). Mirrors the
/// toast's action affordance so the two surfaces feel identical.
class _RowAction extends StatelessWidget {
  const _RowAction({
    required this.label,
    required this.accent,
    required this.onTap,
  });

  final String label;
  final Color accent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(6),
            hoverColor: accent.withValues(alpha: 0.12),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: accent.withValues(alpha: 0.35),
                  width: 0.5,
                ),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: accent,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

Color _accentForSeverity(NotificationSeverity s) {
  switch (s) {
    case NotificationSeverity.info:
      return ZestColors.accentPrimary;
    case NotificationSeverity.success:
      return ZestColors.statusSuccess;
    case NotificationSeverity.warning:
      return ZestColors.statusWarning;
    case NotificationSeverity.error:
      return ZestColors.statusError;
  }
}

IconData _iconForSeverity(NotificationSeverity s) {
  switch (s) {
    case NotificationSeverity.info:
      return LucideIcons.info;
    case NotificationSeverity.success:
      return LucideIcons.checkCircle2;
    case NotificationSeverity.warning:
      return LucideIcons.alertTriangle;
    case NotificationSeverity.error:
      return LucideIcons.xCircle;
  }
}
