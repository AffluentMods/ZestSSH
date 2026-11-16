// Remote screens (4.0) on computers: one row of a list of screen actions, as
// the toolbar's two lists (the scaling, the keys to send) show them. The
// screen menu that F8 opened is the session panel since 4.0
// (menu/screen_session_panel.dart), opened by the pane.
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

export 'package:zestssh/features/screens/model/screen_action.dart';

/// One row of the screen's menus: its icon, its words, and a check where it
/// is the scaling in use or a switch that is on.
PopupMenuItem<ScreenAction> screenMenuItem(
  AppLocalizations l10n,
  ScreenAction a, {
  bool checked = false,
  bool enabled = true,
  String? keyPrefix = 'screen-menu',
  ScreenMenuKey menuKey = ScreenMenuKey.f8,
}) {
  final danger = a == ScreenAction.disconnect;
  final color = danger ? ZestColors.statusError : ZestColors.textPrimary;
  return PopupMenuItem<ScreenAction>(
    key: keyPrefix == null ? null : ValueKey('$keyPrefix-${a.name}'),
    value: a,
    enabled: enabled,
    height: 36,
    child: Row(
      children: [
        Icon(a.icon, size: 15, color: danger ? color : ZestColors.textSecondary),
        const SizedBox(width: 10),
        Expanded(
          child: Text(a.labelIn(l10n, menuKey: menuKey),
              maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: color)),
        ),
        if (checked) ...[
          const SizedBox(width: 8),
          Icon(LucideIcons.check, size: 14, color: AppColors.v3AccentInk),
        ],
      ],
    ),
  );
}
