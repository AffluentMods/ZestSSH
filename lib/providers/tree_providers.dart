import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';

/// SharedPreferences key holding the name the user gave their Tree.
const kTreeNameOverrideKey = 'tree_display_name_override';

/// The name the user gave their Tree with "Rename tree", or null to show the
/// account-derived "{name}'s Tree". Seeded from SharedPreferences and updated
/// by the rename dialog, so the Tree menu and Manage Tree change together.
/// Device-local for now; Team Trees will carry a name of their own.
final treeNameOverrideProvider = StateProvider<String?>((ref) {
  final saved =
      ref.watch(sharedPreferencesProvider).getString(kTreeNameOverrideKey);
  final trimmed = saved?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
});
