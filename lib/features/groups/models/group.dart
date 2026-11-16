import 'package:flutter/material.dart';
import '../../../core/theme/group_color.dart';

class HostGroup {
  const HostGroup({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.hostCount,
    required this.onlineCount,
    this.colorOverride,
  });
  final String id;
  final String name;
  final GroupColor color;

  /// A custom accent (from `ConnectionGroup.colorValue`) that OVERRIDES [color]
  /// when non-null; null falls back to the [color] token. Use [accentColor].
  final Color? colorOverride;
  final IconData icon;
  final int hostCount;
  final int onlineCount;

  /// The concrete accent to draw: a custom [colorOverride] wins, else [color].
  Color get accentColor => colorOverride ?? color.value;
}
