import 'package:flutter/material.dart';

/// What a dropdown shows in its field, given as its `selectedItemBuilder`
/// (every dropdown of the app is given it).
///
/// In a field a line tall (a dense one, or one whose items have a height),
/// each value is on one line, ending in an ellipsis where it is longer than
/// the field: a value of two lines was cut at its top and bottom there (in
/// Russian, the host editor's "Use global default"; at a large text size, key
/// generation's "Ed25519 (Recommended)"). In a field that grows with its value
/// (not dense, and its items given no height), each value is whole. The open
/// menu shows each choice whole either way.
List<Widget> dropdownValues(BuildContext context) {
  // The dropdown asks with its own context.
  final button = context.widget;
  if (button is! DropdownButton<Object?>) {
    throw FlutterError("dropdownValues is a dropdown's selectedItemBuilder, asked by ${button.toStringShort()}");
  }
  final items = button.items ?? const <DropdownMenuItem<Object?>>[];
  if (!button.isDense && button.itemHeight == null) return [...items];
  return [
    for (final item in items) DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, child: item),
  ];
}
