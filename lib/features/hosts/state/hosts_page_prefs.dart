import 'package:shared_preferences/shared_preferences.dart';

/// How the Hosts page shows its hosts: a list, a grid of compact cards, or
/// the grid of full cards.
enum HostsViewMode { list, compact, grid }

/// The Hosts list's columns that can be hidden (the host's own column is
/// always shown), in the order they stand.
enum HostsListColumn { address, group, health, status, lastUsed, tags }

/// The sections of the Hosts page that fold away.
enum HostsSection { workspaces, groups, hosts }

/// The Hosts page's own choices on this device (never synced): how it shows
/// the hosts, the sections folded away, the list's columns. Each is a
/// setting that "Reset all settings" puts back (SettingsService.resetKeys).
class HostsPagePrefs {
  HostsPagePrefs._();

  static const viewKey = 'hosts_view_mode';

  /// The key of the cards-or-list toggle before the compact grid came: read
  /// where [viewKey] was never written, so the page opens as it was left.
  static const legacyListKey = 'hosts_view_list';
  static const foldedKey = 'hosts_folded_sections';
  static const columnsKey = 'hosts_list_columns';

  /// The columns shown until the person picks: all but the tags.
  ///
  static const defaultColumns = {
    HostsListColumn.address,
    HostsListColumn.group,
    HostsListColumn.health,
    HostsListColumn.status,
    HostsListColumn.lastUsed,
  };

  static HostsViewMode view(SharedPreferences prefs) {
    final saved = prefs.getString(viewKey);
    for (final m in HostsViewMode.values) {
      if (m.name == saved) return m;
    }
    return (prefs.getBool(legacyListKey) ?? false) ? HostsViewMode.list : HostsViewMode.grid;
  }

  static Future<void> setView(SharedPreferences prefs, HostsViewMode mode) async {
    await prefs.setString(viewKey, mode.name);
    await prefs.remove(legacyListKey);
  }

  static Set<HostsSection> folded(SharedPreferences prefs) {
    final saved = prefs.getStringList(foldedKey) ?? const [];
    return {for (final s in HostsSection.values) if (saved.contains(s.name)) s};
  }

  static Future<void> setFolded(SharedPreferences prefs, HostsSection section, bool fold) {
    final next = folded(prefs);
    fold ? next.add(section) : next.remove(section);
    return prefs.setStringList(foldedKey, [for (final s in next) s.name]);
  }

  static Set<HostsListColumn> columns(SharedPreferences prefs) {
    final saved = prefs.getStringList(columnsKey);
    if (saved == null) return defaultColumns;
    return {for (final c in HostsListColumn.values) if (saved.contains(c.name)) c};
  }

  static Future<void> setColumns(SharedPreferences prefs, Set<HostsListColumn> columns) =>
      prefs.setStringList(columnsKey, [for (final c in HostsListColumn.values) if (columns.contains(c)) c.name]);
}
