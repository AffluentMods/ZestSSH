import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/window_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/ui/widgets/window_drag_area.dart';
import 'package:zestssh/utils/platform_utils.dart';

// A computer's window has no frame of the system's: the shell's pill bar is its
// title bar. So a screen shown without the shell had none: no way to move the
// window, minimize it or close it, and a locked app could only be force closed.
// [WindowBarOver] goes over such a screen.

/// Over a screen a computer shows without the shell (the lock screen, the
/// welcome, a start that failed): the top of the window moves it, and at its
/// corner are the controls the pill bar has. On a Mac the system's own buttons
/// stay, so only the moving is added; with the system's frame ([kNativeWindowFrame]),
/// on a phone, and where the window could not be set up, it is [child] alone.
class WindowBarOver extends StatelessWidget {
  const WindowBarOver({super.key, required this.child, @visibleForTesting this.shown});

  final Widget child;

  /// What a test says, in place of asking the window.
  final bool? shown;

  @override
  Widget build(BuildContext context) {
    final show = shown ?? (isDesktopPlatform && !kNativeWindowFrame && WindowService.instance != null);
    if (!show) return child;
    return Stack(
      children: [
        child,
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: DesktopDimensions.pillBarHeight,
          child: WindowDragArea(
            child: Row(
              children: [
                const Spacer(),
                if (!Platform.isMacOS) const WindowControls(),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Minimize, maximize or restore, and close, for the frameless title bar. Flush
/// to the top-right corner like native Windows controls, but drawn in the app's
/// dark chrome so they stop clashing with the OS caption bar.
class WindowControls extends StatefulWidget {
  const WindowControls({super.key});

  @override
  State<WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<WindowControls> with WindowListener {
  // Track maximize state so the middle button toggles its glyph/tooltip
  // to "Restore" - previously it was permanently stuck on "Maximize".
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final m = await windowManager.isMaximized();
    if (mounted) setState(() => _maximized = m);
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _maximized = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _maximized = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: LucideIcons.minus,
          tooltip: l10n.pillMinimize,
          onTap: () => windowManager.minimize(),
        ),
        _WindowButton(
          icon: _maximized ? LucideIcons.copy : LucideIcons.square,
          iconSize: 12,
          tooltip: _maximized ? l10n.pillRestore : l10n.pillMaximize,
          onTap: () async {
            if (await windowManager.isMaximized()) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
          },
        ),
        _WindowButton(
          icon: LucideIcons.x,
          tooltip: l10n.close,
          isClose: true,
          onTap: () => windowManager.close(),
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  const _WindowButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
    this.iconSize = 15,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool isClose;
  final double iconSize;

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final hoverBg = widget.isClose
        ? const Color(0xFFE81123) // Windows close-red
        : AppColors.v3TextPrimary.withValues(alpha: 0.08);
    final fg = _hover
        ? (widget.isClose ? Colors.white : AppColors.v3TextPrimary)
        : AppColors.v3TextSecondary;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            width: 44,
            height: DesktopDimensions.pillBarHeight,
            alignment: Alignment.center,
            color: _hover ? hoverBg : Colors.transparent,
            child: Icon(widget.icon, size: widget.iconSize, color: fg),
          ),
        ),
      ),
    );
  }
}
