import 'package:flutter/material.dart';

/// A see-through Material for the inside of a coloured box (a card, a dialog's card, a sheet):
/// list tiles and other ink inside draw their hover, press and background on it, where the
/// box's colour hid them on the Material under the box. Flutter 3.44 and later report a
/// ListTile under such a box as an error in debug builds and tests. The text style inside stays
/// the one the box's contents had.
class InkLayer extends StatelessWidget {
  const InkLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      textStyle: DefaultTextStyle.of(context).style,
      child: child,
    );
  }
}
