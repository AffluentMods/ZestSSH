import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';

/// 1.7 button variants. Only [primary] gets a solid [ZestTokens.brand] fill -
/// app-wide rule: at most ONE primary visible per pane at a time.
enum ZestButtonVariant { primary, secondary, ghost, danger }

/// [large] (40px) for pane footers / primary CTAs; [medium] (32px) for
/// toolbars and inline actions.
enum ZestButtonSize { large, medium }

/// The 1.7 button. Rules baked in:
/// * [primary] is the only solid-brand variant.
/// * Disabled (null [onPressed]) renders at 40% opacity AND blocks pointer
///   events - not just a greyed label.
/// * [isLoading] swaps the leading glyph for a 14px spinner and blocks taps.
/// * Focus ring: 2px [ZestTokens.brand] outline at 2px offset, shown on
///   KEYBOARD focus only (never on mouse click), and drawn outside the button
///   bounds so it never shifts layout.
class ZestButton extends StatefulWidget {
  const ZestButton({
    super.key,
    required this.label,
    this.onPressed,
    this.variant = ZestButtonVariant.secondary,
    this.size = ZestButtonSize.medium,
    this.icon,
    this.trailingIcon,
    this.isLoading = false,
  });

  /// Already-localized label.
  final String label;

  /// Null == disabled.
  final VoidCallback? onPressed;
  final ZestButtonVariant variant;
  final ZestButtonSize size;
  final IconData? icon;
  final IconData? trailingIcon;
  final bool isLoading;

  @override
  State<ZestButton> createState() => _ZestButtonState();
}

class _ZestButtonState extends State<ZestButton> {
  bool _hovering = false;
  bool _focusRing = false; // keyboard focus only

  bool get _enabled => widget.onPressed != null && !widget.isLoading;

  void _activate() {
    if (_enabled) widget.onPressed!();
  }

  @override
  Widget build(BuildContext context) {
    final isLarge = widget.size == ZestButtonSize.large;
    final height = isLarge ? ZestSizing.buttonLarge : ZestSizing.buttonMedium;
    final padX =
        isLarge ? ZestSizing.buttonLargePaddingX : ZestSizing.buttonMediumPaddingX;
    final fontSize = isLarge ? 14.0 : 13.0;
    final iconSize = isLarge ? 18.0 : 16.0;
    final v = _ZestButtonStyle.of(widget.variant);

    // A disabled PRIMARY must read as clearly "off", not as a muddy translucent
    // orange (the §8 disabled-primary rule). Swap the solid brand fill for
    // the theme's one turned-off fill with muted text, as the theme's
    // disabled filled button: the raised cell it used is as white as
    // Daylight's cards, so there it was a white button on white. Loading is
    // NOT disabled (onPressed is still set), so it keeps the brand fill +
    // spinner.
    final bool primaryDisabled = widget.onPressed == null &&
        widget.variant == ZestButtonVariant.primary;

    final Color fill = primaryDisabled
        ? ZestTokens.disabledFill
        : (_hovering && _enabled ? v.fillHover : v.fill);
    final Color fg =
        primaryDisabled ? ZestTokens.disabledInk : v.foreground;
    final Color? border = primaryDisabled ? null : v.border;

    final children = <Widget>[
      if (widget.isLoading)
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(strokeWidth: 2, color: fg),
        )
      else if (widget.icon != null)
        Icon(widget.icon, size: iconSize, color: fg),
      if (widget.isLoading || widget.icon != null)
        const SizedBox(width: ZestSizing.buttonGap),
      // The label wraps where the button has no room for it on a line (a
      // label longer than its row ran out of it at a large text size).
      Flexible(
        child: Text(
          widget.label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
            color: fg,
            height: 1.0,
          ),
        ),
      ),
      if (widget.trailingIcon != null) ...[
        const SizedBox(width: ZestSizing.buttonGap),
        Icon(widget.trailingIcon, size: iconSize, color: fg),
      ],
    ];

    Widget body = AnimatedContainer(
      duration: zestMotion(context, const Duration(milliseconds: 120)),
      // As tall as before where the label takes a line, taller where it takes
      // more.
      constraints: BoxConstraints(minHeight: height),
      padding: EdgeInsets.symmetric(horizontal: padX, vertical: 4),
      // No alignment: it made the button as wide as whatever held it. It
      // hugs its label now; a parent that sets a width (a row stretched
      // across a sheet) still gets the label centred by the row below.
      decoration: BoxDecoration(
        color: fill,
        borderRadius: BorderRadius.circular(8),
        border: border == null ? null : Border.all(color: border, width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, mainAxisAlignment: MainAxisAlignment.center, children: children),
    );

    // Focus ring drawn OUTSIDE the button (negative inset in a non-clipping
    // Stack) so showing it never reflows the row. The Stack passes its
    // constraints on as they are: a button given a width (full width in a
    // stretched column) fills it with its label centred, one left loose
    // hugs its label. The default loose fit drew a full-width button hugging
    // the top-left corner.
    body = Stack(
      clipBehavior: Clip.none,
      fit: StackFit.passthrough,
      children: [
        body,
        if (_focusRing)
          Positioned(
            left: -4,
            top: -4,
            right: -4,
            bottom: -4,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ZestTokens.brand, width: 2),
                ),
              ),
            ),
          ),
      ],
    );

    // A finger's 48 where the controls are touch sized: the space around the
    // drawn button takes the press (it was its 32 or 40), as Material's
    // padded tap target; a width the button is given it still fills.
    if (touchSizedAt(context)) {
      if (height < 48) body = Padding(padding: EdgeInsets.symmetric(vertical: (48 - height) / 2), child: body);
      body = ConstrainedBox(constraints: const BoxConstraints(minWidth: 48), child: body);
    }

    final detector = FocusableActionDetector(
      enabled: _enabled,
      mouseCursor:
          _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onShowHoverHighlight: (h) => setState(() => _hovering = h),
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
        SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
      },
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      // Said as a button by its label, turned off where it is (to a screen
      // reader it was a bare tap: 4.0, the accessibility pass).
      child: Semantics(
        container: true,
        button: true,
        enabled: _enabled,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: _enabled ? _activate : null,
          child: body,
        ),
      ),
    );

    // Disabled: no pointer events. The primary variant already carries an
    // explicit flat-neutral disabled style (computed above), so it must NOT
    // also be faded to muddy translucency. The other variants keep the 40%
    // fade that reads fine on their non-brand fills.
    if (widget.onPressed == null) {
      final disabledChild = IgnorePointer(child: detector);
      return primaryDisabled
          ? disabledChild
          : Opacity(opacity: 0.4, child: disabledChild);
    }
    return detector;
  }
}

/// Resolved colours for a [ZestButtonVariant].
class _ZestButtonStyle {
  const _ZestButtonStyle({
    required this.fill,
    required this.fillHover,
    required this.foreground,
    this.border,
  });

  final Color fill;
  final Color fillHover;
  final Color foreground;
  final Color? border;

  static _ZestButtonStyle of(ZestButtonVariant v) {
    switch (v) {
      case ZestButtonVariant.primary:
        return _ZestButtonStyle(
          fill: ZestTokens.brand,
          fillHover: ZestColors.accentHover,
          foreground: ZestColors.onBrand, // dark on the orange, every theme
        );
      case ZestButtonVariant.secondary:
        // Neutral outlined, as the theme's OutlinedButton: a grey slab read
        // as a second kind of secondary next to it.
        return _ZestButtonStyle(
          fill: Colors.transparent,
          fillHover: ZestTokens.textPrimary.withValues(alpha: 0.05),
          foreground: ZestTokens.textPrimary,
          border: ZestTokens.borderStrong,
        );
      case ZestButtonVariant.ghost:
        return _ZestButtonStyle(
          fill: Colors.transparent,
          fillHover: ZestTokens.surfaceHover,
          foreground: ZestTokens.textSecondary,
        );
      case ZestButtonVariant.danger:
        return _ZestButtonStyle(
          fill: Colors.transparent,
          fillHover: ZestColors.statusError.withValues(alpha: 0.12),
          foreground: ZestColors.statusError,
          border: ZestColors.statusError.withValues(alpha: 0.55),
        );
    }
  }
}
