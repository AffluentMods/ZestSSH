import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Which heavy sub-editor is currently docked into the RIGHT pane of the
/// desktop V3 Settings view.
///
/// [none] means nothing is docked - the settings list occupies the whole
/// content area, exactly as it did before docking existed. The other values
/// each render a docked editor panel over the right ~50% (via
/// [ListEditorSplit]) instead of a full-screen route / modal dialog.
enum SettingsDock {
  /// Nothing docked - settings fills the area.
  none,

  /// The app-chrome theme designer ([ThemeDesignerView]).
  appThemeDesigner,

  /// The custom terminal-theme (ANSI palette) builder.
  customThemeBuilder,

  /// The sync-storage backend chooser ([SyncBackendScreen]).
  syncBackend,
}

/// Desktop-only: the sub-editor docked into the right pane of the Settings
/// inline view. Deliberately holds a small [SettingsDock] enum, NOT a widget,
/// so it stays cheap/serialisable and the view owns the actual editor
/// construction.
///
/// Reset to [SettingsDock.none] when the Settings section is left (user
/// switches sidebar nav) or when the inline view is disposed, so a stale
/// editor can never linger.
final settingsDockProvider =
    StateProvider<SettingsDock>((ref) => SettingsDock.none);
