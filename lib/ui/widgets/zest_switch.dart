import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;

/// The app's one on/off switch (3.0:
/// four were drawn, Material's 52 by 32 among them): a white thumb on the
/// brand's track when on, a muted thumb in a hairline track when off. 34 by
/// 20 on a computer, 42 by 24 on a phone or tablet, where a thumb presses it.
///
/// Reached with Tab it shows the accent ring the app's buttons show (on
/// keyboard focus only, never after a click), and Space or Enter turns it.
class ZestSwitch extends StatefulWidget {
  const ZestSwitch({super.key, required this.value, required this.onChanged, this.semanticLabel});

  final bool value;

  /// What it turns on, to a screen reader ("Bell"); left out, the name of the
  /// row it stands in ([ZestControlLabel]), where it is in one.
  final String? semanticLabel;

  /// Null: shown, and turned off.
  final ValueChanged<bool>? onChanged;

  @override
  State<ZestSwitch> createState() => _ZestSwitchState();
}

class _ZestSwitchState extends State<ZestSwitch> {
  bool _focusRing = false; // keyboard focus only

  @override
  Widget build(BuildContext context) {
    final value = widget.value;
    // Touch sized where the app's controls are (the density setting, Auto by
    // the platform).
    final touch = touchSizedAt(context);
    final w = touch ? 42.0 : 34.0;
    final h = touch ? 24.0 : 20.0;
    final enabled = widget.onChanged != null;
    final brand = ZestTokens.brand;
    final track = value ? brand : ZestTokens.surfaceSunken;
    final thumb = value ? Colors.white : ZestTokens.textTertiary;
    void toggle() {
      if (!enabled) return;
      hapticIn(context, Haptic.selection);
      widget.onChanged!(!value);
    }

    Widget drawing = Opacity(
      opacity: enabled ? 1 : 0.45,
      child: AnimatedContainer(
        duration: zestMotion(context, const Duration(milliseconds: 140)),
        curve: Curves.easeOut,
        width: w,
        height: h,
        padding: const EdgeInsets.all(3),
        alignment: value ? AlignmentDirectional.centerEnd : AlignmentDirectional.centerStart,
        decoration: BoxDecoration(
          color: track,
          borderRadius: BorderRadius.circular(h / 2),
          border: Border.all(color: value ? brand : ZestTokens.border),
        ),
        child: Container(
          width: h - 8,
          height: h - 8,
          decoration: BoxDecoration(
            color: thumb,
            shape: BoxShape.circle,
            boxShadow: value
                ? [BoxShadow(color: Colors.black.withValues(alpha: 0.25), blurRadius: 3, offset: const Offset(0, 1))]
                : null,
          ),
        ),
      ),
    );

    // The focus ring is drawn outside the track (a non-clipping Stack), so
    // showing it never moves the row.
    drawing = Stack(
      clipBehavior: Clip.none,
      children: [
        drawing,
        if (_focusRing)
          Positioned(
            left: -3,
            top: -3,
            right: -3,
            bottom: -3,
            child: IgnorePointer(
              child: DecoratedBox(
                key: const ValueKey('zest-switch-focus-ring'),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(h / 2 + 3),
                  border: Border.all(color: brand, width: 2),
                ),
              ),
            ),
          ),
      ],
    );

    return Semantics(
      toggled: value,
      enabled: enabled,
      label: widget.semanticLabel ?? ZestControlLabel.maybeOf(context),
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: (f) => setState(() => _focusRing = f),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => toggle())},
        child: GestureDetector(
          onTap: toggle,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            // A larger target than the drawing, as a thumb needs: 48 square
            // on a phone or a tablet, 32 high with a mouse (40 by 28 before).
            padding: touch ? const EdgeInsets.symmetric(horizontal: 3, vertical: 12) : const EdgeInsets.symmetric(vertical: 6),
            child: drawing,
          ),
        ),
      ),
    );
  }
}
