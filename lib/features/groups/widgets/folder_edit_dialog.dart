import 'package:flutter/material.dart';

import 'package:zestssh/database/database.dart' show ConnectionGroup;
import 'package:zestssh/features/groups/widgets/group_editor_panel.dart';

/// Backwards-compatible entry point for editing a connection group (folder).
///
/// The unified folder editor is now the two-tab [GroupEditorPanel] side sheet
/// (§6) - name, accent colour, membership, reorder and delete all live there.
/// This thin shim keeps the old `FolderEditDialog.show(context, group: ...)`
/// call sites working by delegating to that panel, so every "edit group" entry
/// point opens the same editor.
abstract final class FolderEditDialog {
  /// Open the group editor on [group]. Retained for API compatibility.
  static Future<void> show(
    BuildContext context, {
    required ConnectionGroup group,
  }) {
    return GroupEditorPanel.showAdaptive(context, groupId: group.id);
  }
}
