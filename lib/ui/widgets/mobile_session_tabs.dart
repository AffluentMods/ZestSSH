import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/os_icon.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/session_status_mark.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Horizontally scrollable session tab strip for mobile.
///
/// Shown below the terminal toolbar when 2+ sessions are active.
/// Each tab displays:
/// - OS icon (from detection cache) or generic terminal icon
/// - Connection name
/// - Status dot (green/amber/red)
/// - Orange underline on the active tab
///
/// Tap to switch sessions. Long-press to close.
class MobileSessionTabs extends ConsumerStatefulWidget {
  final String currentSessionId;
  final ValueChanged<String> onSessionSelected;
  final ValueChanged<String> onSessionClose;

  const MobileSessionTabs({
    super.key,
    required this.currentSessionId,
    required this.onSessionSelected,
    required this.onSessionClose,
  });

  @override
  ConsumerState<MobileSessionTabs> createState() => _MobileSessionTabsState();
}

class _MobileSessionTabsState extends ConsumerState<MobileSessionTabs> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(activeSessionsProvider);

    // Only show tabs that are connected or connecting
    final activeSessions = sessions.entries
        .where((e) =>
            e.value.status == SessionStatus.connected ||
            e.value.status == SessionStatus.connecting)
        .toList();

    // Don't render if fewer than 2 sessions
    if (activeSessions.length < 2) return const SizedBox.shrink();

    return Container(
      // 48 high: each tab's target is (4.0 accessibility pass; 28 before),
      // its pill drawn as it was.
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.surfaceDark,
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.06),
            width: 0.5,
          ),
        ),
      ),
      child: ListView.builder(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        itemCount: activeSessions.length,
        itemBuilder: (context, index) {
          final entry = activeSessions[index];
          final sessionId = entry.key;
          final sessionState = entry.value;
          final isActive = sessionId == widget.currentSessionId;

          return _MobileSessionTab(
            sessionId: sessionId,
            sessionState: sessionState,
            isActive: isActive,
            onTap: () => widget.onSessionSelected(sessionId),
            onLongPress: () => _confirmClose(sessionId, sessionState),
          );
        },
      ),
    );
  }

  Future<void> _confirmClose(String sessionId, SessionState sessionState) async {
    final l10n = AppLocalizations.of(context)!;
    haptic(ref, Haptic.medium);
    // The app's own question (it was a plain dialog built here).
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.mobileSessionTabsCloseSession,
      body: l10n.mobileSessionTabsDisconnectConfirm(Redactable.host(sessionState.connectionLabel).display),
      confirmLabel: l10n.close,
    );
    if (sure == true) widget.onSessionClose(sessionId);
  }
}

class _MobileSessionTab extends ConsumerWidget {
  final String sessionId;
  final SessionState sessionState;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const _MobileSessionTab({
    required this.sessionId,
    required this.sessionState,
    required this.isActive,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connectionId = sessionState.connectionId;
    final osKind = connectionId != null
        ? ref.watch(detectedOsProvider(connectionId))
        : null;

    final label = sessionState.connectionLabel.isNotEmpty
        ? sessionState.connectionLabel
        : (sessionState.host ?? l10n.mobileSessionTabsSessionFallback);

    // One control to a screen reader: its name and state in words (the dot's
    // colour said the state to the eye only), selected while in front, and
    // Close session as an action (a long press, which nothing said).
    return Semantics(
      container: true,
      button: true,
      label:
          '${l10n.mobileSessionTabsSessionTabSemantic(Redactable.host(label).display)}, ${sessionStatusWord(l10n, sessionState.status)}',
      selected: isActive,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: {CustomSemanticsAction(label: l10n.mobileSessionTabsCloseSession): onLongPress},
      child: GestureDetector(
        // The margin round the pill takes the press too: a target 48 high.
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 10),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.brandOrange.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(6),
            border: Border(
              bottom: BorderSide(
                color: isActive ? AppColors.brandOrange : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // OS icon or generic icon
              if (osKind != null && osKind != OsKind.unknown)
                OsIconWidget(kind: osKind, size: 14)
              else
                Icon(
                  LucideIcons.terminal,
                  size: 14,
                  color: isActive
                      ? AppColors.onSurface
                      : AppColors.textSecondary,
                ),
              const SizedBox(width: 6),

              // Connection name
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 120),
                child: RedactedText(
                  Redactable.host(label),
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                    color: isActive
                        ? AppColors.onSurface
                        : AppColors.textSecondary,
                  ),
                ),
              ),
              const SizedBox(width: 6),

              // Its state by its shape too: a dot while connected, a ring
              // while connecting.
              SessionStatusMark(status: sessionState.status, size: 6),
            ],
          ),
        ),
      ),
    );
  }
}
