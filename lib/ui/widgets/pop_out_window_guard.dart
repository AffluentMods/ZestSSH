import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Guards a pop-out window (a text editor in its own OS window) while the
/// app is locked (3.0): the window runs apart from the main one, so
/// without this it stayed open and editable behind the lock screen. While
/// [locked] is true an opaque cover hides [child] and takes every click and
/// key press; [child] stays built underneath, so unsaved edits are kept for
/// when the app is unlocked in the main window. Input in the window tells the
/// main window someone is there ([onActivity], at most once per
/// [activityEvery]), so working here keeps the idle lock away.
class PopOutWindowGuard extends StatefulWidget {
  const PopOutWindowGuard({
    super.key,
    required this.locked,
    required this.onActivity,
    required this.child,
    this.activityEvery = const Duration(seconds: 20),
  });

  final ValueListenable<bool> locked;
  final VoidCallback onActivity;
  final Widget child;
  final Duration activityEvery;

  @override
  State<PopOutWindowGuard> createState() => _PopOutWindowGuardState();
}

class _PopOutWindowGuardState extends State<PopOutWindowGuard> {
  DateTime? _lastSent;

  @override
  void initState() {
    super.initState();
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  void _onPointer(PointerEvent event) {
    if (event is PointerDownEvent ||
        event is PointerMoveEvent ||
        event is PointerHoverEvent ||
        event is PointerScrollEvent ||
        event is PointerPanZoomUpdateEvent) {
      _active();
    }
  }

  bool _onKey(KeyEvent event) {
    _active();
    return false;
  }

  void _active() {
    final now = DateTime.now();
    final last = _lastSent;
    if (last != null && now.difference(last) < widget.activityEvery) return;
    _lastSent = now;
    widget.onActivity();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: widget.locked,
      child: widget.child,
      builder: (context, locked, child) => Stack(
        fit: StackFit.expand,
        children: [
          // Kept built (edits survive) but out of reach: no focus, no
          // pointer, not read out.
          ExcludeFocus(
            excluding: locked,
            child: AbsorbPointer(
              absorbing: locked,
              child: ExcludeSemantics(excluding: locked, child: child!),
            ),
          ),
          if (locked) const _LockedCover(),
        ],
      ),
    );
  }
}

class _LockedCover extends StatelessWidget {
  const _LockedCover();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Positioned.fill(
      key: const ValueKey('pop-out-locked'),
      child: ColoredBox(
        color: AppColors.v3Background,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.lock, size: 28, color: AppColors.v3TextSecondary),
                const SizedBox(height: 12),
                Text(
                  l10n.popOutLockedTitle,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.popOutLockedBody,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: AppColors.v3TextSecondary),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
