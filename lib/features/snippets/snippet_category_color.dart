import 'package:flutter/material.dart';

import 'package:zestssh/database/database.dart' show SnippetCategory;
import 'package:zestssh/theme/app_colors.dart';

/// The accent colour for a snippet category, matching the mobile snippet list:
/// a user-picked custom ARGB (`colorValue`) or palette index (`colorIndex`)
/// wins; otherwise a stable name-derived default. Shared by the mobile list and
/// the desktop quick-picker so the two never drift.
Color snippetCategoryColor(String name, [SnippetCategory? meta]) {
  final value = meta?.colorValue;
  if (value != null) return Color(value);
  final idx = meta?.colorIndex;
  if (idx != null && idx >= 0) {
    return AppColors.v3GroupColors[idx % AppColors.v3GroupColors.length];
  }
  return _nameColor(name);
}

/// Stable default colour derived from the category name, so the seeded default
/// folders (System, Docker, Network, ...) always read the same colour.
Color _nameColor(String name) {
  switch (name.toLowerCase()) {
    case 'system':
      return AppColors.categorySystem;
    case 'services':
      return AppColors.categoryServices;
    case 'docker':
      return AppColors.categoryDocker;
    case 'network':
      return AppColors.categoryNetwork;
    case 'files':
      return AppColors.categoryFiles;
    case 'security':
      return AppColors.categorySecurity;
    case 'packages':
      return AppColors.categoryPackages;
    case 'git':
      return AppColors.categoryGit;
    case 'database':
      return AppColors.categoryDatabase;
    case 'logs':
      return AppColors.categoryLogs;
    default:
      return AppColors.brandOrange;
  }
}
