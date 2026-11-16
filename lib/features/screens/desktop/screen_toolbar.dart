// Remote screens (4.0) on computers: the slim bar above a screen's picture.
// The scaling, view only, Ctrl+Alt+Del and the other keys the computer's own
// system would take, a refresh, the clipboard's switch for this host on this
// device (none on a team host whose editor locked it off), full screen; on the
// right how the screen is protected, the screen menu (as F8) and Disconnect.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/displays/screen_display_bars.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/hit_area.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

import 'screen_menu.dart';

/// The bar's height.
const kScreenToolbarHeight = 34.0;

/// The toolbar's height where [context] is: [kScreenToolbarHeight] with a
/// mouse, 48 where the app is touch sized (a large tablet has the
/// computer's shell), so that its buttons are a finger's 48.
double screenToolbarHeightAt(BuildContext context) => touchSizedAt(context) ? 48 : kScreenToolbarHeight;

class ScreenToolbar extends StatelessWidget {
  const ScreenToolbar({
    super.key,
    required this.fit,
    required this.viewOnly,
    required this.fullScreen,
    required this.security,
    required this.onAction,
    required this.onMenu,
    this.clipboardOn = false,
    this.onToggleClipboard,
    this.canResizeRemote = false,
    this.resizingRemote = false,
    this.menuKey = ScreenMenuKey.f8,
    this.menu,
    this.displays,
    this.onDisplay,
  });

  final ScreenFit fit;
  final bool viewOnly;
  final bool fullScreen;

  /// How the screen is protected, said by the lock's tooltip; null before
  /// it is connected.
  final String? security;
  final ValueChanged<ScreenAction> onAction;

  /// Opens the screen menu under [anchor] (the button's box).
  final ValueChanged<Rect> onMenu;

  /// Whether the clipboard is shared with this screen now.
  final bool clipboardOn;

  /// Turns the clipboard on or off for this host on this device; null where
  /// it cannot be (a team host locked off by its editor): no switch then.
  final VoidCallback? onToggleClipboard;

  /// An RDP screen: "Resize the remote" is among the scalings, and whether
  /// it is the one in use.
  final bool canResizeRemote;
  final bool resizingRemote;

  /// The key that opens the screen menu as well (Settings, Remote screens).
  final ScreenMenuKey menuKey;

  /// The remote's displays and what picks one (null: all of them): with
  /// both, and more than one display, the bar has the display segment.
  final ValueListenable<ScreenDisplays>? displays;
  final ValueChanged<int?>? onDisplay;

  /// What the session offers now, for a bar drawn from the action list
  /// (4.0); null where its pane gave none.
  final ScreenMenuState? menu;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final fitAction = resizingRemote ? ScreenAction.remoteResize : ScreenAction.ofFit(fit);
    return Container(
      key: const ValueKey('screen-toolbar'),
      height: screenToolbarHeightAt(context),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: ZestColors.surfacePanel,
        border: Border(bottom: BorderSide(color: ZestColors.borderDefault)),
      ),
      child: Row(
        children: [
          // The scaling: its icon and words, a list of the three.
          _MenuButton(
            key: const ValueKey('screen-toolbar-scaling'),
            tooltip: l10n.connectionEditScreenScaling,
            icon: fitAction.icon,
            label: fitAction.labelIn(l10n),
            items: [
              for (final a in ScreenAction.fits) screenMenuItem(l10n, a, checked: a == fitAction),
              if (canResizeRemote)
                screenMenuItem(l10n, ScreenAction.remoteResize, checked: fitAction == ScreenAction.remoteResize),
            ],
            onSelected: onAction,
          ),
          const SizedBox(width: 2),
          _ToolButton(
            key: const ValueKey('screen-toolbar-viewOnly'),
            icon: viewOnly ? LucideIcons.eye : LucideIcons.mousePointer2,
            tooltip: l10n.connectionEditScreenViewOnly,
            on: viewOnly,
            onTap: () => onAction(ScreenAction.viewOnly),
          ),
          // Which of the remote's displays is shown (nothing for one display).
          if (displays != null && onDisplay != null)
            ValueListenableBuilder<ScreenDisplays>(
              valueListenable: displays!,
              builder: (context, d, _) => d.several
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [_divider(), ScreenDisplaySegment(displays: displays!, onDisplay: onDisplay!)],
                    )
                  : const SizedBox.shrink(),
            ),
          _divider(),
          _ToolButton(
            key: const ValueKey('screen-toolbar-sendCtrlAltDel'),
            icon: ScreenAction.sendCtrlAltDel.icon,
            tooltip: l10n.screenSendCtrlAltDel,
            onTap: viewOnly ? null : () => onAction(ScreenAction.sendCtrlAltDel),
          ),
          _MenuButton(
            key: const ValueKey('screen-toolbar-keys'),
            tooltip: l10n.screenSendKeys,
            icon: LucideIcons.keyboard,
            enabled: !viewOnly,
            items: [
              for (final a in ScreenAction.sends) screenMenuItem(l10n, a, keyPrefix: 'screen-keys', menuKey: menuKey),
            ],
            onSelected: onAction,
          ),
          _divider(),
          _ToolButton(
            key: const ValueKey('screen-toolbar-refresh'),
            icon: LucideIcons.refreshCw,
            tooltip: l10n.screenRefresh,
            onTap: () => onAction(ScreenAction.refresh),
          ),
          if (onToggleClipboard != null)
            _ToolButton(
              key: const ValueKey('screen-toolbar-clipboard'),
              icon: clipboardOn ? LucideIcons.clipboardCheck : LucideIcons.clipboardX,
              tooltip: clipboardOn ? l10n.screenClipboardTurnOff : l10n.screenClipboardTurnOn,
              on: clipboardOn,
              onTap: onToggleClipboard,
            ),
          _ToolButton(
            key: const ValueKey('screen-toolbar-fullScreen'),
            icon: fullScreen ? LucideIcons.minimize : LucideIcons.expand,
            tooltip: l10n.screenFullScreen,
            on: fullScreen,
            onTap: () => onAction(ScreenAction.fullScreen),
          ),
          const Spacer(),
          if (security != null)
            Tooltip(
              message: security!,
              child: Padding(
                key: const ValueKey('screen-toolbar-security'),
                padding: const EdgeInsets.symmetric(horizontal: 6),
                child: Icon(LucideIcons.lock, size: 14, color: ZestColors.statusSuccess),
              ),
            ),
          Builder(
            builder: (context) => _ToolButton(
              key: const ValueKey('screen-toolbar-menu'),
              icon: LucideIcons.moreHorizontal,
              tooltip: l10n.screenMenuTooltipKey(menuKey.label),
              onTap: () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                onMenu(box.localToGlobal(Offset.zero) & box.size);
              },
            ),
          ),
          _ToolButton(
            key: const ValueKey('screen-toolbar-disconnect'),
            icon: LucideIcons.powerOff,
            tooltip: l10n.sessionInfoDisconnect,
            color: ZestColors.statusError,
            onTap: () => onAction(ScreenAction.disconnect),
          ),
        ],
      ),
    );
  }

  Widget _divider() => Container(
        width: 1,
        height: 16,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: ZestColors.borderDefault,
      );
}

class _ToolButton extends StatelessWidget {
  const _ToolButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.on = false,
    this.color,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool on;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final ink = !enabled
        ? ZestColors.textTertiary.withValues(alpha: 0.5)
        : on
            ? AppColors.v3AccentInk
            : color ?? ZestColors.textSecondary;
    // A pointer's target of 32 square, a finger's of 48 (the 4.0
    // accessibility pass): the box is as wide as that, and as high as the
    // toolbar leaves it, with the rest of the height taken above and below
    // it, where the toolbar has nothing of its own.
    final target = minTapTarget(context);
    final high = target > 32 ? 40.0 : 26.0;
    return Tooltip(
      message: tooltip,
      child: HitArea(
        grow: EdgeInsets.symmetric(vertical: (target - high) / 2),
        child: Semantics(
          button: true,
          enabled: enabled,
          toggled: on ? true : null,
          label: tooltip,
          // What is under it is left out of what is read, and its press went
          // with it: a screen reader read the button and could not press it.
          onTap: onTap,
          excludeSemantics: true,
          child: InkWell(
            onTap: onTap,
            // Never the keyboard's: a click here leaves it where it was.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: target,
              height: high,
              decoration: BoxDecoration(
                color: on ? ZestColors.accentPrimary.withValues(alpha: 0.14) : null,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(icon, size: 15, color: ink),
            ),
          ),
        ),
      ),
    );
  }
}

class _MenuButton extends StatelessWidget {
  const _MenuButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.items,
    required this.onSelected,
    this.label,
    this.enabled = true,
  });

  final String tooltip;
  final IconData icon;
  final String? label;
  final List<PopupMenuEntry<ScreenAction>> items;
  final ValueChanged<ScreenAction> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ink = enabled ? ZestColors.textSecondary : ZestColors.textTertiary.withValues(alpha: 0.5);
    // As a tool button: 32 square for a pointer, 48 for a finger.
    final target = minTapTarget(context);
    final high = target > 32 ? 40.0 : 26.0;
    return HitArea(
      grow: EdgeInsets.symmetric(vertical: (target - high) / 2),
      child: PopupMenuButton<ScreenAction>(
        tooltip: tooltip,
        enabled: enabled,
        onSelected: onSelected,
        color: ZestColors.chromeElevated,
        position: PopupMenuPosition.under,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: ZestColors.borderDefault),
        ),
        constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
        itemBuilder: (_) => items,
        child: Container(
          height: high,
          constraints: BoxConstraints(minWidth: target),
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 15, color: ink),
              if (label != null) ...[
                const SizedBox(width: 6),
                Text(label!, style: TextStyle(fontSize: 12, color: ink)),
              ],
              const SizedBox(width: 2),
              Icon(LucideIcons.chevronDown, size: 12, color: ink),
            ],
          ),
        ),
      ),
    );
  }
}
