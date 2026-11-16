// Remote screens (4.0): the floating bar over a phone's remote screen. Back
// to the list (the screen stays connected), the host's name, Touch or Mouse
// pointer, the soft keyboard, the whole screen again, the session panel (4.0:
// everything the session can do, in its groups, each with a line that
// says what it does; the older menu where the view gives no action list) and
// Disconnect. The touch button asks which mode, each with its line. It hides itself a moment after it was
// last used; a tab at the top brings it back (a tap on the picture is a
// click on the remote, so the picture itself cannot).
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/displays/screen_display_bars.dart';
import 'package:zestssh/features/screens/menu/screen_session_panel.dart';
import 'package:zestssh/features/screens/model/screen_action.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/features/screens/view/screen_viewport.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart' show RedactableDisplay;

/// What the menu's items do.
enum ScreenPhoneMenu {
  fit,
  fill,
  oneToOne,
  viewOnly,
  ctrlAltDel,
  superKey,
  clipboard,
  pasteToRemote;

  /// The row as the action list names it (4.0: the phone's view
  /// acts on [ScreenAction]s, whatever draws them).
  ScreenAction get action => switch (this) {
        fit => ScreenAction.fit,
        fill => ScreenAction.fill,
        oneToOne => ScreenAction.oneToOne,
        viewOnly => ScreenAction.viewOnly,
        ctrlAltDel => ScreenAction.sendCtrlAltDel,
        superKey => ScreenAction.sendSuper,
        clipboard => ScreenAction.clipboard,
        pasteToRemote => ScreenAction.pasteToRemote,
      };
}

class ScreenPhoneToolbar extends ConsumerStatefulWidget {
  const ScreenPhoneToolbar({
    super.key,
    required this.label,
    required this.touchMode,
    required this.fit,
    required this.zoomed,
    required this.viewOnly,
    required this.keyboardShown,
    required this.onBack,
    required this.onToggleMode,
    required this.onToggleKeyboard,
    required this.onWholeScreen,
    required this.onMenu,
    required this.onDisconnect,
    this.clipboardOn = false,
    this.clipboardTogglable = false,
    this.menu,
    this.onAction,
    this.displays,
    this.onDisplay,
  });

  /// The host's name (masked while recording).
  final String label;
  final ScreenTouchMode touchMode;
  final ScreenFit fit;
  final bool zoomed;
  final bool viewOnly;
  final bool keyboardShown;
  final VoidCallback onBack;
  final VoidCallback onToggleMode;
  final VoidCallback onToggleKeyboard;
  final VoidCallback onWholeScreen;
  final ValueChanged<ScreenPhoneMenu> onMenu;

  /// What the session offers now and what acts on a pick, for a bar or a
  /// sheet drawn from the action list (4.0); null where the view
  /// gave none.
  final ScreenMenuState? menu;
  final ValueChanged<ScreenAction>? onAction;

  /// The remote's displays and what picks one (null: all of them): with
  /// both, and more than one display, the bar has the display button and
  /// the panel its Displays group.
  final ValueListenable<ScreenDisplays>? displays;
  final ValueChanged<int?>? onDisplay;
  final VoidCallback onDisconnect;

  /// Whether the clipboard is shared with this screen now.
  final bool clipboardOn;

  /// Whether its person may turn it on or off here (not on a team host whose
  /// editor locked it off: no switch then, and no Paste to remote).
  final bool clipboardTogglable;

  @override
  ConsumerState<ScreenPhoneToolbar> createState() => _ScreenPhoneToolbarState();
}

class _ScreenPhoneToolbarState extends ConsumerState<ScreenPhoneToolbar> {
  /// The session's state for an open panel, moved on as the view rebuilds
  /// this bar.
  late final _menu = ValueNotifier<ScreenMenuState>(widget.menu ?? const ScreenMenuState(offered: {}));

  @override
  void didUpdateWidget(ScreenPhoneToolbar old) {
    super.didUpdateWidget(old);
    final menu = widget.menu;
    if (menu != null) _menu.value = menu;
  }

  @override
  void dispose() {
    _menu.dispose();
    super.dispose();
  }

  Future<void> _openPanel() async {
    final onAction = widget.onAction;
    if (onAction == null) return;
    await showScreenPanel(context,
        state: _menu, onAction: onAction, displays: widget.displays, onDisplay: widget.onDisplay);
  }

  Future<void> _askTouchMode() async {
    final onAction = widget.onAction;
    if (onAction == null) {
      widget.onToggleMode();
      return;
    }
    final picked = await showScreenTouchModeQuestion(context, current: widget.touchMode);
    if (picked == null || !mounted) return;
    if (picked != widget.touchMode) onAction(ScreenAction.ofTouch(picked));
    announceScreenTouchMode(context, picked);
  }

  static const _ink = Color(0xFFEDEBE6);

  /// The screen's width from which the bar has a place for the display
  /// button at all, and from which it has room for its words.
  static const _displayButtonFrom = 360.0;
  static const _displayWordsFrom = 430.0;

  /// The fill of a button that is on, and what it paints as over the bar.
  static final _onFill = AppColors.brandOrange.withValues(alpha: 0.85);
  static final _onFillPainted = Color.alphaBlend(_onFill, const Color(0xFF151412));

  /// The height of each of the menu's rows (a finger's 48), and the width a
  /// tick and the gap after it take at the start of one.
  static const _menuRowHeight = 48.0;
  static const _menuTickSlot = 36.0;

  @override
  Widget build(BuildContext context) {
    final w = widget;
    final barWidth = MediaQuery.sizeOf(context).width;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final label = w.label, touchMode = w.touchMode, fit = w.fit, zoomed = w.zoomed, viewOnly = w.viewOnly;
    final keyboardShown = w.keyboardShown, onBack = w.onBack, onToggleKeyboard = w.onToggleKeyboard;
    final onWholeScreen = w.onWholeScreen, onMenu = w.onMenu, onDisconnect = w.onDisconnect;
    final clipboardOn = w.clipboardOn, clipboardTogglable = w.clipboardTogglable;
    final l10n = AppLocalizations.of(context)!;
    final touch = touchMode == ScreenTouchMode.touch;

    Widget button(String key, IconData icon, String tip, VoidCallback onPressed, {bool on = false, Color? color}) =>
        IconButton(
          key: ValueKey(key),
          tooltip: tip,
          onPressed: onPressed,
          // A finger's 48 square (the 4.0 accessibility pass; they were 40).
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 48, height: 48),
          isSelected: on,
          style: IconButton.styleFrom(
            backgroundColor: on ? _onFill : null,
          ),
          // On its orange fill the bar's light ink read 2.9 to 1: the ink that
          // reads on that fill is used there.
          icon: Icon(icon, size: 19, color: color ?? (on ? ZestColors.onFill(_onFillPainted) : _ink)),
        );

    CheckedPopupMenuItem<ScreenPhoneMenu> check(ScreenPhoneMenu value, String text, bool checked) =>
        CheckedPopupMenuItem<ScreenPhoneMenu>(
          key: ValueKey('screen-phone-menu-${value.name}'),
          value: value,
          checked: checked,
          height: _menuRowHeight,
          child: Text(text),
        );

    // An entry with no tick: its words start where a ticked entry's do (they
    // started at the menu's edge, a tick's width to the left of the others).
    PopupMenuItem<ScreenPhoneMenu> plain(ScreenPhoneMenu value, String text, {required bool enabled}) =>
        PopupMenuItem<ScreenPhoneMenu>(
          key: ValueKey('screen-phone-menu-${value.name}'),
          value: value,
          enabled: enabled,
          height: _menuRowHeight,
          child: Padding(
            padding: const EdgeInsetsDirectional.only(start: _menuTickSlot),
            child: Text(text),
          ),
        );

    return Material(
      key: const ValueKey('screen-phone-toolbar'),
      color: const Color(0xE6151412),
      elevation: 4,
      borderRadius: BorderRadius.circular(12),
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
        child: Row(
          children: [
            button('screen-phone-back', LucideIcons.chevronLeft, l10n.screenPhoneBack, onBack),
            Expanded(
              child: Text(
                Redactable.host(label).displayIn(ref),
                key: const ValueKey('screen-phone-label'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: _ink, fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            // Which of the remote's displays is shown (nothing for one display):
            // with its words where the bar has the room, as an icon on a narrow
            // phone or at large text, and on the narrowest phones not in the bar
            // at all (five buttons leave it no place there): the panel's Displays
            // group and three fingers sideways are still there.
            if (w.displays != null && w.onDisplay != null && barWidth >= _displayButtonFrom)
              if (barWidth >= _displayWordsFrom && textScale <= 1.3)
                ScreenDisplayButton(displays: w.displays!, onDisplay: w.onDisplay!, ink: _ink)
              else
                ValueListenableBuilder<ScreenDisplays>(
                  valueListenable: w.displays!,
                  builder: (context, d, _) => d.several
                      ? button(
                          'screen-display-button',
                          LucideIcons.monitor,
                          d.shown == null ? l10n.screenDisplayAll : l10n.screenDisplayOf(d.shown! + 1, d.list.length),
                          () => unawaited(showScreenDisplayPicker(context, displays: w.displays!, onDisplay: w.onDisplay!)),
                        )
                      : const SizedBox.shrink(),
                ),
            button(
              'screen-phone-mode',
              touch ? LucideIcons.pointer : LucideIcons.touchpad,
              touch ? l10n.screenPhoneUseMouse : l10n.screenPhoneUseTouch,
              () => unawaited(_askTouchMode()),
            ),
            button('screen-phone-keyboard', LucideIcons.keyboard, l10n.screenPhoneKeyboard, onToggleKeyboard,
                on: keyboardShown),
            if (zoomed) button('screen-phone-whole', LucideIcons.minimize2, l10n.screenViewWholeScreen, onWholeScreen),
            if (w.menu != null && w.onAction != null)
              button('screen-phone-more', LucideIcons.slidersHorizontal, l10n.screenPanelTitle,
                  () => unawaited(_openPanel()))
            else
              // The menu's rows at one height, a finger's (44), and a tick's
            // slot of one width in each: a ticked row drew a list tile 56
            // high beside rows of 48, with its words further in.
            ListTileTheme.merge(
              dense: true,
              minTileHeight: _menuRowHeight,
              minVerticalPadding: 0,
              minLeadingWidth: 20,
              horizontalTitleGap: _menuTickSlot - 24,
              contentPadding: EdgeInsets.zero,
              titleTextStyle: Theme.of(context).textTheme.labelLarge,
              child: PopupMenuButton<ScreenPhoneMenu>(
              key: const ValueKey('screen-phone-more'),
              tooltip: l10n.screenPhoneMore,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(minimumSize: const Size(48, 48), fixedSize: const Size(48, 48)),
              icon: const Icon(LucideIcons.moreVertical, size: 19, color: _ink),
              onSelected: onMenu,
              itemBuilder: (context) => [
                check(ScreenPhoneMenu.fit, l10n.connectionEditScreenScalingFit, fit == ScreenFit.fit),
                check(ScreenPhoneMenu.fill, l10n.screenPhoneScalingFill, fit == ScreenFit.fill),
                check(ScreenPhoneMenu.oneToOne, l10n.connectionEditScreenScalingOneToOne, fit == ScreenFit.oneToOne),
                const PopupMenuDivider(),
                check(ScreenPhoneMenu.viewOnly, l10n.connectionEditScreenViewOnly, viewOnly),
                plain(ScreenPhoneMenu.ctrlAltDel, l10n.screenPhoneCtrlAltDel, enabled: !viewOnly),
                // By itself (Start on Windows, the overview on GNOME): the key
                // bar's Super is held for the next key, and cannot be tapped alone.
                plain(ScreenPhoneMenu.superKey, l10n.screenSendSuper, enabled: !viewOnly),
                if (clipboardTogglable) ...[
                  const PopupMenuDivider(),
                  check(ScreenPhoneMenu.clipboard, l10n.connectionEditScreenClipboard, clipboardOn),
                  plain(ScreenPhoneMenu.pasteToRemote, l10n.screenPasteToRemote, enabled: clipboardOn && !viewOnly),
                ],
              ],
            ),
            ),
            button('screen-phone-disconnect', LucideIcons.power, l10n.terminalDisconnect, onDisconnect,
                color: AppColors.error),
          ],
        ),
      ),
    );
  }
}
