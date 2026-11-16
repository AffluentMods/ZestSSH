import 'package:flutter/material.dart';

/// The spinner a button shows while it works, in the button's own ink at
/// full strength. Where the button is turned off while it works, that is the
/// theme's text, which reads on the button's grey on every theme (a fixed
/// white was white on light grey on a light theme); on a button's fill, the
/// ink that reads on that fill.
class ButtonSpinner extends StatelessWidget {
  const ButtonSpinner({super.key, this.strokeWidth = 2});

  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    final ink = IconTheme.of(context).color;
    return CircularProgressIndicator(strokeWidth: strokeWidth, color: ink?.withValues(alpha: 1));
  }
}
