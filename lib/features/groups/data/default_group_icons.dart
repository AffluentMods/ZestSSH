import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

IconData defaultGroupIcon(String groupName) {
  final lower = groupName.toLowerCase();
  if (lower == 'homelab') return LucideIcons.home;
  if (lower == 'production') return LucideIcons.shield;
  if (lower == 'staging') return LucideIcons.flaskConical;
  if (lower == 'personal') return LucideIcons.user;
  if (lower == 'lab') return LucideIcons.flaskConical;
  if (lower.startsWith('team')) return LucideIcons.users;
  if (lower.startsWith('dev')) return LucideIcons.code2;
  if (lower == 'clients') return LucideIcons.briefcase;
  if (lower == 'testing') return LucideIcons.flaskConical;
  return LucideIcons.folder;
}
