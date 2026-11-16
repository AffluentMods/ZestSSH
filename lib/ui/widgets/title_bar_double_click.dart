import 'dart:io' show Platform, Process;

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/services/window_service.dart';

/// What a double-click on empty title bar space does.
enum TitleBarAction {
  /// Maximize, or restore where the window is maximized (a Mac's zoom).
  zoom,

  /// Minimize to the Dock or the taskbar.
  minimize,

  /// Nothing.
  none,
}

/// A Mac's setting for a double-click on a window's title bar, as
/// `defaults read -g` gives it: [actionOnDoubleClick]
/// (`AppleActionOnDoubleClick`: Maximize, Minimize, None, or Fill on newer
/// systems) and, where that was never set, the older
/// [miniaturizeOnDoubleClick] (`AppleMiniaturizeOnDoubleClick`, 1 for
/// minimize). Nothing set is the system's default, zoom.
TitleBarAction titleBarActionOf(
  String? actionOnDoubleClick,
  String? miniaturizeOnDoubleClick,
) {
  switch (actionOnDoubleClick?.trim().toLowerCase()) {
    case 'minimize':
      return TitleBarAction.minimize;
    case 'none':
      return TitleBarAction.none;
    case 'maximize' || 'fill':
      return TitleBarAction.zoom;
  }
  return miniaturizeOnDoubleClick?.trim() == '1'
      ? TitleBarAction.minimize
      : TitleBarAction.zoom;
}

/// What a double-click on empty title bar space does here: on a Mac what
/// its own setting says (System Settings, Desktop and Dock, "Double-click
/// a window's title bar to"), read at each double-click so that a change
/// counts at once; on Windows and Linux zoom, as their title bars do.
Future<TitleBarAction> titleBarActionHere() async {
  if (!Platform.isMacOS) return TitleBarAction.zoom;
  Future<String?> read(String key) async {
    try {
      final r = await Process.run('defaults', ['read', '-g', key]);
      return r.exitCode == 0 ? '${r.stdout}' : null;
    } catch (_) {
      return null;
    }
  }

  return titleBarActionOf(
    await read('AppleActionOnDoubleClick'),
    await read('AppleMiniaturizeOnDoubleClick'),
  );
}

/// Stands in for the window in tests: what a double-click on empty title
/// bar space was handed to.
@visibleForTesting
void Function()? debugTitleBarDoubleClicked;

/// Does to this window what a double-click on empty title bar space does
/// ([titleBarActionHere]). Not in fullscreen, where a title bar has
/// nothing to zoom.
Future<void> titleBarDoubleClicked() async {
  final stand = debugTitleBarDoubleClicked;
  if (stand != null) return stand();
  if (WindowService.fullscreen.value) return;
  switch (await titleBarActionHere()) {
    case TitleBarAction.zoom:
      if (await windowManager.isMaximized()) {
        await windowManager.unmaximize();
      } else {
        await windowManager.maximize();
      }
    case TitleBarAction.minimize:
      await windowManager.minimize();
    case TitleBarAction.none:
      break;
  }
}

/// A frameless window's title bar answering a double-click on its empty
/// space, as a system title bar does. It goes UNDER the bar's content in a
/// Stack: a click on a tab, a pill or a button lands on that and never
/// reaches it, so a double-click there does nothing to the window, and
/// their single clicks wait for no second one. A double-click on the
/// parent of the whole bar would hold back every tab's click until a
/// double-click was ruled out; and window_manager's DragToMoveArea zoomed
/// on any double-click on the bar, a tab's too, which was why double-click
/// was turned off in 1.7.1 (a Mac's title bar did nothing, 3.3).
class TitleBarDoubleClickLayer extends StatelessWidget {
  const TitleBarDoubleClickLayer({super.key});

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onDoubleTap: titleBarDoubleClicked,
    child: const SizedBox.expand(),
  );
}
