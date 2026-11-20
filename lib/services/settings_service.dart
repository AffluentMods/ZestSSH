import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// A pause of sync on this device ([SettingsService.syncPause]): until
/// [until], or until its person resumes it where that is null.
class SyncPause {
  const SyncPause({this.until});

  final DateTime? until;

  /// Whether it holds at [now]: until its person resumes it, or until its
  /// time.
  bool at(DateTime now) => until == null || now.isBefore(until!);
}

/// Persists app and terminal settings via [SharedPreferences].
///
/// Terminal theme and app theme are independent systems.
/// Security-sensitive settings (PIN, lock method) use
/// [FlutterSecureStorage] instead - see [SecurityLockService].
class SettingsService {
  final SharedPreferences _prefs;

  SettingsService(this._prefs);

  /// Recording mode's own keys. It must never turn itself off (spec 7c: a crash
  /// or a reset in the middle of a recording must not quietly start leaking),
  /// and the mask salt keeps every stand-in stable for the install. They are
  /// among [keptKeys].
  static const List<String> recordingKeys = [
    'recording_mode_enabled',
    'recording_redact_level',
    'recording_mask_salt',
  ];

  /// What "Reset all settings" puts back to its default: what a person
  /// chooses on a settings screen, and how the app's panels are laid out.
  ///
  /// The store holds much besides, which is no setting: see [keptKeys]. The
  /// reset used to clear the whole store but for recording mode, and with it
  /// what sync knows of the state it last shared, the app lock's switch
  /// (which turned the lock off, with no PIN asked), that the first-run
  /// steps were done, reports waiting to be sent, pins, saved tab groups,
  /// custom themes and a Prometheus server's sign-in.
  ///
  /// A key the app keeps in the store is in this list or in [keptKeys] (or
  /// begins with one of [resetPrefixes] or [keptPrefixes]):
  /// test/services/settings_reset_test.dart reads the code and fails for a
  /// key that is in neither, so that whoever adds one says which it is.
  static const Set<String> resetKeys = {
    'agentless_monitor_enabled', 'app_locale', 'app_theme_id', 'ask_before_trusting_keys', 'auto_backup_interval',
    'auto_execute_snippets', 'auto_reconnect', 'auto_restore_workspace', 'automation_enabled', 'bell_enabled',
    'close_confirmation', 'command_history_enabled', 'command_history_include_sensitive',
    'command_history_suggestions', 'compact_keyboard', 'connection_timeout', 'copy_on_select',
    'cursor_blink', 'cursor_style', 'cursor_visibility', 'custom_accent_color', 'dangerous_command_protection',
    'default_auth_method', 'default_identity_id', 'default_port', 'default_snippet_category', 'default_username',
    'desktop_confirm_close_sessions', 'desktop_host_panel_collapsed_groups', 'desktop_host_panel_visible',
    'desktop_host_panel_width', 'desktop_middle_click_paste', 'desktop_minimize_to_tray',
    'desktop_restore_sessions', 'desktop_right_click_paste', 'desktop_sidebar_collapsed', 'desktop_sidebar_width',
    'desktop_system_notifications',
    'editor_minimap', 'editor_nano_keys', 'editor_terminal_look', 'editor_text_size', 'extra_keyboard_position',
    'follow_system_theme',
    'haptic_feedback', 'health_check_interval',
    'host_card_settings', 'hosts_folded_sections', 'hosts_list_columns', 'hosts_view_list', 'hosts_view_mode',
    'keep_screen_awake', 'keepalive_interval', 'keyboard_incognito',
    'keys_row_auto_hide', 'keys_row_hardware', 'lock_show_sessions', 'lock_sessions_shown',
    'manual_network_override_id', 'monitor_alerts_enabled',
    // A Mac's or Linux computer's choice of the mosh program installed there over the built-in client (4.0).
    'mosh_system_client', 'monitor_chart_series_v1', 'monitor_column_widths_v1',
    'monitor_columns_v1', 'monitor_data_source',
    'monitor_sort_mode', 'monitor_threshold_config_v1', 'notify_connection_lost', 'notify_security_alerts',
    'notify_transfer_complete', 'notify_transfer_failed', 'notify_update_available', 'option_as_meta',
    'osc52_clipboard', 'copy_screen_lines',
    'reachability_checks_enabled', 'scrollback_lines',
    // Remote screens (4.0): a phone's Touch or Mouse pointer, the screen menu's key, a new screen's scaling,
    // what recording mode does to the picture, the clipboard's default for one's own hosts, and whether the
    // strip of a remote's displays is open (4.0: a layout), and whether a phone's bar over a remote
    // screen stays shown, whether a Mac's Command key goes to a remote screen as Ctrl, and which groups of a
    // remote screen's session panel are folded.
    'screen_bar_kept', 'screen_cmd_as_ctrl', 'screen_default_clipboard', 'screen_default_scaling', 'screen_default_touch',
    'screen_display_strip', 'screen_panel_folded',
    'screen_menu_key', 'screen_recording', 'screen_smooth_scaling',
    'session_log_dir', 'session_log_enabled',
    'session_log_timestamps', 'sftp_delete_hold_seconds', 'sftp_dock_follow_terminal', 'sftp_dock_height',
    'sftp_dock_side', 'sftp_dock_two_panes', 'sftp_dock_width',
    'sftp_hidden_level', 'sftp_rail_split', 'sftp_time_format', 'shortcut_overrides', 'show_extra_keyboard',
    'snippet_destructive_confirm', 'soft_keyboard_disabled_keys', 'soft_keyboard_key_size', 'soft_keyboard_row1_order',
    'soft_keyboard_row2_order', 'soft_keyboard_scrollable_mode', 'soft_keyboard_style', 'sync_interval_minutes',
    'sync_off_notice_hidden',
    'tab_source_group', 'tab_source_mode', 'tab_source_vault',
    'terminal_font',
    'terminal_font_size', 'terminal_ligatures', 'terminal_margin', 'terminal_read_aloud', 'terminal_theme', 'tmux_auto_detect',
    'ui_density', 'update_auto_install', 'update_check_enabled', 'volume_keys_enabled', 'workflow_run_panel_fraction',
  };

  /// Beginnings of keys made for one thing each that are settings as well:
  /// where a screen's two halves are divided, each list of hosts' Active
  /// first, a remote screen's Touch or Mouse pointer on a phone and whether
  /// this device shares its clipboard with a host's screen (4.0).
  static const List<String> resetPrefixes = ['zest_split_', 'active_first_', 'screen_touch.', 'screen_clipboard.'];

  /// What the store holds that "Reset all settings" leaves as it is.
  static const Set<String> keptKeys = {
    // The app lock is turned off where it is turned on, with the PIN, and nowhere else.
    'encrypting_lock_enabled', 'security_lock_enabled',
    // The same two under the names they have with profiles (ProfilePreferences.renamed).
    'lock2_app_lock', 'lock2_encrypting',
    // Recording mode must not turn itself off, and its salt keeps every stand-in stable.
    'recording_mask_salt', 'recording_mode_enabled', 'recording_redact_level',
    // What sync knows of the last state it shared: without it the next sync does not know what changed.
    'last_sync_time', 'sync_content_hash', 'sync_dirty', 'sync_dirty_since', 'sync_mode', 'sync_paused_until',
    'sync_recovery_key_set',
    // A sign-out made while the store sync uses could not be read: what it owes is done once the store is known.
    'sync_disconnect_owed',
    // When the stores' rating prompt may be asked for (lib/services/review_prompt.dart): counts on this device only.
    'review_first_seen', 'review_good_sessions', 'review_asked_version',
    'sync_server_version', 'sync_store_updated_at', 'themes_synced',
    // Saved connection details of other services, typed in once: a Prometheus server, backup destinations, password
    // managers that hosts fetch their passwords from.
    'backup_destinations', 'password_managers_v1', 'prometheus_auth_type', 'prometheus_basic_auth_password',
    'prometheus_basic_auth_user', 'prometheus_bearer_token', 'prometheus_custom_header_key',
    'prometheus_url', 'prometheus_verify_ssl',
    // What a person made or collected: themes, pins, tab groups, workspaces, recent things, a name, a picture.
    'custom_app_themes_v1', 'custom_terminal_themes', 'desktop_pinned_connections', 'desktop_saved_tab_groups',
    'desktop_workspaces', 'notification_history', 'pinned_connection_ids', 'profile_custom_avatar_path',
    'quick_connect_recent', 'sftp_local_pins', 'snippet_usage_v1', 'tree_display_name_override',
    'widget_connections', 'widget_locked', 'zest_recent_custom_colors',
    // A host's own alert choices (Server monitor's mute and snooze of its metrics), part of the host as its
    // terminal theme is.
    'monitor_host_alert_prefs_v1',
    // What is open, to come back to it: sessions, tabs and their panes.
    'desktop_pane_layout', 'desktop_pane_layout_preset', 'desktop_work_tabs', 'lastOpenSessions',
    'last_workspace_id', 'persisted_active_tab_index', 'persisted_sessions', 'persisted_tab_snapshots_v1',
    'settings_last_section',
    // What was seen, answered or done once, and is not asked again.
    'acked_policy_version', 'ios_port_forward_intro_shown', 'onboarding_complete', 'pins_migrated_to_db',
    'tmux_intro_seen', 'screen_hints_seen', 'update_dismissed_version', 'update_pill_hidden_on', 'sync_turn_on_asked', 'app_lock_offered', 'passkey_offered', 'step_up_at',
    'recovery_proof_ask_dismissed',
    // What the app keeps for its own work: a host key that changed and waits for its person, reports that wait to be
    // sent, what was bought, when things last ran, what was measured, how far a replacement of team keys has come.
    'cached_server_stats', 'changed_host_keys', 'desktop_entitlement_checked_at',
    'desktop_entitlement_cloud_sync', 'desktop_entitlement_pro', 'feedback_last_sent_at', 'feedback_queue_v1',
    'team_premium_member', 'team_premium_uid',
    'last_auto_backup_time', 'last_change_backup_time', 'monitor_capabilities_v1', 'orchard_key_replacement_v1',
    'sftp_delete_failures',
    // FTPS uploads that broke off, to go on from after a restart (hashes only: lib/services/ftps/ftps_upload_resume.dart).
    'ftps_partial_uploads',
    'update_last_check_ms',
    // An update started just before the app quit for it: the next start says whether it went in.
    'update_pending_v1',
    // The release an update to which did not go in: not installed by itself again.
    'update_auto_failed',
    // On a Mac, the build the notice of macOS's keychain questions after an update was shown for (3.3.2).
    'mac_keychain_told_build',
    // When the Store copy last tried to remove the copy from zestssh.com, or told it is there for every account
    // (store_handover_start.dart): tried a day later; and the older Store copy that copy last said needs updating.
    'store_handover_remove_tried', 'store_handover_older_told',
    // Hosts a device on an older version turned back into SSH: this device's note, said where such a host gives no
    // terminal.
    'sftp_only_turned_back',
    // The id this device gives with a +1 on a public report when nobody is signed in (3.4): a reset must not make
    // the same device a second voter.
    'report_vote_device_id', 'report_vote_device_votes',
  };

  /// Beginnings of keys made for one thing each that are left as they are.
  static const List<String> keptPrefixes = [
    'os_kind_', // a host's system, as it was found
    'terminal_theme_', // a host's own terminal theme, which is part of the host
    'sftp_sync_', // what folder sync knows of a host
    'zest_network_mode_', // a network's mode
    'sftp_folder_visits:', // folders visited on a host
    'sftp_pin_declined:', // a pin that was offered and declined
    'jump_gate_notice_shown:', // a notice shown once for a host
    'team_sync_offer_told_', // an offer made once to an account
  ];

  // ── Whose each key is (accounts on one device, to-do 60) ───────────
  //
  // Each key the app keeps in the store is also said to be a profile's or the
  // device's: a person's setting goes with their profile, into its database, and
  // is locked with it; a device's stays in this store. Read and written through
  // one helper on a computer (ProfilePreferences). A phone keeps them all where
  // they were, for now. test/services/profiles/settings_tags_test.dart fails
  // for a key with neither.

  /// What stays with the computer, whoever uses it: the app lock, the window
  /// and its layout, the keyboard, update checks, recording mode, rendering,
  /// the language until a person picks one, what is asked once per device.
  static const Set<String> deviceKeys = {
    // The app lock, and what its lock screen shows.
    'encrypting_lock_enabled', 'security_lock_enabled', 'lock2_app_lock', 'lock2_encrypting', 'lock_show_sessions',
    'lock_sessions_shown',
    // The home screen widget told that the app lock is on (WidgetService), as the lock itself.
    'widget_locked',
    // Recording mode.
    'recording_mask_salt', 'recording_mode_enabled', 'recording_redact_level',
    // The window and its layout.
    'desktop_host_panel_visible', 'desktop_host_panel_width', 'desktop_minimize_to_tray',
    'desktop_sidebar_collapsed', 'desktop_sidebar_width', 'sftp_dock_height', 'sftp_dock_side', 'sftp_dock_two_panes',
    'sftp_dock_width', 'sftp_rail_split',
    // Whether the SFTP dock follows its terminal's folder (4.0): with the dock's other choices.
    'sftp_dock_follow_terminal', 'settings_last_section', 'workflow_run_panel_fraction',
    // Whether this computer shows the app's notices as its own notifications too (4.0): a phone's
    // always do, and macOS asks each computer.
    'desktop_system_notifications',
    // A keyboard is the device's.
    'compact_keyboard', 'extra_keyboard_position', 'keyboard_incognito', 'keys_row_auto_hide', 'keys_row_hardware',
    'option_as_meta', 'show_extra_keyboard', 'soft_keyboard_disabled_keys', 'soft_keyboard_key_size',
    'soft_keyboard_row1_order', 'soft_keyboard_row2_order', 'soft_keyboard_scrollable_mode', 'soft_keyboard_style',
    'volume_keys_enabled',
    // Whether a screen reader on this device hears a terminal's new lines (4.0).
    'terminal_read_aloud',
    // Whether Mosh hosts open with the mosh program installed on this computer (a Mac or Linux) instead of
    // the built-in client (4.0): it is this computer that has the program or not.
    'mosh_system_client',
    // How big the controls are for this device's inputs (4.0, the density).
    'ui_density',
    // A remote screen's: how a finger on this phone drives it, the key on this computer that opens its menu, and
    // whether recording mode on this device covers it, and whether this computer's strip of a remote's displays
    // is open (4.0).
    'screen_default_touch', 'screen_display_strip', 'screen_menu_key', 'screen_recording',
    // Whether this phone's bar over a remote screen stays shown, and which of the one-time hints over a
    // remote screen were shown on this device (4.0).
    'screen_bar_kept', 'screen_hints_seen',
    // Whether this Mac's Command key goes to a remote screen as Ctrl, and whether a remote screen's
    // picture is smoothed on this device's screen (4.0).
    'screen_cmd_as_ctrl', 'screen_smooth_scaling',
    // Which groups of a remote screen's session panel are folded on this device (4.0).
    'screen_panel_folded',
    // Updates.
    'notify_update_available', 'update_check_enabled', 'update_dismissed_version', 'update_last_check_ms',
    'update_pending_v1', 'mac_keychain_told_build', 'update_auto_install', 'update_pill_hidden_on', 'update_auto_failed',
    // One ZestSSH per Windows PC: the Store copy's try at removing the zestssh.com copy; an older Store copy told of.
    'store_handover_remove_tried', 'store_handover_older_told',
    // Asked or shown once on this device.
    'acked_policy_version', 'app_lock_offered', 'ios_port_forward_intro_shown', 'onboarding_complete',
    'review_asked_version', 'review_first_seen', 'review_good_sessions', 'tmux_intro_seen',
    // The id this device gives with a +1 when nobody is signed in: one per device, whoever uses it.
    'report_vote_device_id', 'report_vote_device_votes',
  };

  /// Beginnings of keys that stay with the computer: how a screen's two halves
  /// are divided, how a finger drives a remote screen's pointer on this
  /// device, and whether this device shares its clipboard with a host's
  /// screen (4.0).
  static const List<String> devicePrefixes = ['zest_split_', 'screen_touch.', 'screen_clipboard.'];

  /// What follows the person: everything else the lists above name. Saved here
  /// by name so that a new key has to say which it is.
  static const Set<String> profileKeys = {
    // Their settings.
    'agentless_monitor_enabled', 'app_locale', 'app_theme_id', 'ask_before_trusting_keys', 'auto_backup_interval',
    'auto_execute_snippets', 'auto_reconnect', 'auto_restore_workspace', 'automation_enabled', 'bell_enabled',
    'close_confirmation', 'command_history_enabled', 'command_history_include_sensitive',
    'command_history_suggestions', 'connection_timeout', 'copy_on_select', 'copy_screen_lines',
    'cursor_blink', 'cursor_style', 'cursor_visibility', 'custom_accent_color', 'dangerous_command_protection',
    'default_auth_method', 'default_identity_id', 'default_port', 'default_snippet_category', 'default_username',
    'desktop_confirm_close_sessions', 'desktop_host_panel_collapsed_groups', 'desktop_middle_click_paste',
    'desktop_restore_sessions', 'desktop_right_click_paste', 'editor_minimap', 'editor_nano_keys', 'editor_terminal_look',
    'editor_text_size', 'follow_system_theme',
    'haptic_feedback', 'health_check_interval', 'host_card_settings', 'hosts_folded_sections', 'hosts_list_columns',
    'hosts_view_list', 'hosts_view_mode', 'keep_screen_awake', 'keepalive_interval', 'manual_network_override_id',
    'monitor_alerts_enabled', 'monitor_chart_series_v1', 'monitor_column_widths_v1', 'monitor_columns_v1',
    'monitor_data_source', 'monitor_sort_mode',
    'monitor_threshold_config_v1', 'notify_connection_lost', 'notify_security_alerts', 'notify_transfer_complete',
    'notify_transfer_failed', 'osc52_clipboard', 'reachability_checks_enabled', 'scrollback_lines',
    // The scaling their new remote screens are saved with, and whether their own hosts' screens share the
    // clipboard by default (4.0).
    'screen_default_clipboard', 'screen_default_scaling',
    'session_log_dir',
    'session_log_enabled', 'session_log_timestamps', 'sftp_delete_hold_seconds', 'sftp_hidden_level',
    'sftp_time_format', 'shortcut_overrides', 'snippet_destructive_confirm', 'sync_interval_minutes',
    'sync_off_notice_hidden', 'tab_source_group', 'tab_source_mode', 'tab_source_vault', 'terminal_font',
    'terminal_font_size', 'terminal_ligatures', 'terminal_margin', 'terminal_theme', 'tmux_auto_detect',
    // What sync knows of the last state it shared with their store.
    'last_sync_time', 'sync_content_hash', 'sync_dirty', 'sync_dirty_since', 'sync_mode', 'sync_paused_until',
    'sync_recovery_key_set', 'sync_server_version', 'sync_store_updated_at', 'themes_synced',
    // Their services, and what they made or collected.
    'backup_destinations', 'password_managers_v1', 'prometheus_auth_type', 'prometheus_basic_auth_password',
    'prometheus_basic_auth_user', 'prometheus_bearer_token', 'prometheus_custom_header_key', 'prometheus_url',
    'prometheus_verify_ssl', 'custom_app_themes_v1', 'custom_terminal_themes', 'desktop_pinned_connections',
    'desktop_saved_tab_groups', 'desktop_workspaces', 'notification_history', 'pinned_connection_ids',
    'profile_custom_avatar_path', 'quick_connect_recent', 'sftp_local_pins', 'snippet_usage_v1',
    'tree_display_name_override', 'widget_connections', 'zest_recent_custom_colors', 'monitor_host_alert_prefs_v1',
    // What they have open.
    'desktop_pane_layout', 'desktop_pane_layout_preset', 'desktop_work_tabs', 'lastOpenSessions', 'last_workspace_id',
    'persisted_active_tab_index', 'persisted_sessions', 'persisted_tab_snapshots_v1',
    // What was answered for this account, and what the app keeps for its work.
    'pins_migrated_to_db', 'sync_turn_on_asked', 'passkey_offered', 'recovery_proof_ask_dismissed', 'step_up_at',
    'sync_disconnect_owed',
    'cached_server_stats',
    'changed_host_keys', 'desktop_entitlement_checked_at', 'desktop_entitlement_cloud_sync', 'desktop_entitlement_pro',
    'feedback_last_sent_at', 'feedback_queue_v1', 'team_premium_member', 'team_premium_uid', 'last_auto_backup_time',
    'last_change_backup_time',
    'monitor_capabilities_v1', 'orchard_key_replacement_v1', 'sftp_delete_failures', 'sftp_only_turned_back',
    // FTPS uploads to this person's hosts that broke off: another profile never goes on with them.
    'ftps_partial_uploads',
  };

  /// Beginnings of keys that follow the person: a host's own, a network's own.
  static const List<String> profilePrefixes = [
    'active_first_',
    'os_kind_',
    'terminal_theme_',
    'sftp_sync_',
    'zest_network_mode_',
    'sftp_folder_visits:',
    'sftp_pin_declined:',
    'jump_gate_notice_shown:',
    'team_sync_offer_told_',
  ];

  /// Whether [key] follows the person ([profileKeys]) rather than staying with
  /// the computer. A key neither list knows stays with the computer: what is
  /// not known to be a person's is not moved or locked away, and a test fails
  /// for such a key in the code.
  static bool isProfileKey(String key) => profileKeys.contains(key) || profilePrefixes.any(key.startsWith);

  /// Whether "Reset all settings" removes [key] from the store.
  static bool isResetKey(String key) => resetKeys.contains(key) || resetPrefixes.any(key.startsWith);

  /// Puts every setting back to its default: removes [resetKeys] (and what
  /// begins with [resetPrefixes]) from the store, and nothing else. A key
  /// that is in neither list is left alone: what is not known to be a
  /// setting is not thrown away. Connections, identities, keys and the
  /// encrypted database live elsewhere and are untouched. Settings are read
  /// live through providers, so the caller should prompt a restart for the
  /// reset to take effect across the running UI.
  Future<void> resetAllToDefaults() async {
    for (final key in _prefs.getKeys().toList()) {
      if (isResetKey(key)) await _prefs.remove(key);
    }
  }

  // ── Terminal settings ────────────────────────────────────────────

  String get terminalThemeId =>
      _prefs.getString('terminal_theme') ?? 'zest_night';
  Future<void> setTerminalThemeId(String id) =>
      _prefs.setString('terminal_theme', id);

  TerminalFontFamily get terminalFontFamily {
    final value = _prefs.getString('terminal_font');
    if (value == null) return TerminalFontFamily.jetBrainsMono;
    return TerminalFontFamily.values.firstWhere(
      (f) => f.name == value,
      orElse: () => TerminalFontFamily.jetBrainsMono,
    );
  }

  Future<void> setTerminalFontFamily(TerminalFontFamily family) =>
      _prefs.setString('terminal_font', family.name);

  double get terminalFontSize =>
      _prefs.getDouble('terminal_font_size') ?? 14.0;
  Future<void> setTerminalFontSize(double size) =>
      _prefs.setDouble('terminal_font_size', size);

  // Default 50k matches the value the terminal was previously hard-pinned to,
  // so honoring this setting (it used to be ignored) doesn't shrink anyone's
  // scrollback. <= 0 is treated as unlimited by the terminal (see
  // [terminalScrollbackLines]).
  int get scrollbackLines =>
      _prefs.getInt('scrollback_lines') ?? 50000;
  Future<void> setScrollbackLines(int lines) =>
      _prefs.setInt('scrollback_lines', lines);

  /// "Don't show this again" on the notice that a host was saved on this
  /// device only, while sync is off.
  /// Whether this sign-in was asked to bring this device back into the
  /// account's sync (syncAfterSignIn): once for each sign-in, forgotten when
  /// the account signs out.
  bool get syncTurnOnAsked => _prefs.getBool('sync_turn_on_asked') ?? false;
  Future<void> setSyncTurnOnAsked(bool asked) =>
      asked ? _prefs.setBool('sync_turn_on_asked', true) : _prefs.remove('sync_turn_on_asked');

  /// A sign-out was made while the store sync uses could not be read (3.4.2):
  /// whether ZestSSH Cloud's sync was to be forgotten here was not known, so
  /// no key was deleted then. Done once the store is read: forgotten where it
  /// is ZestSSH Cloud (and set aside for the account named here first, where
  /// one is), nothing where it is a store of the person's own. Null where
  /// nothing is owed; empty where nothing is set aside.
  String? get syncDisconnectOwed => _prefs.getString('sync_disconnect_owed');
  Future<void> setSyncDisconnectOwed(String? keepFor) =>
      keepFor == null ? _prefs.remove('sync_disconnect_owed') : _prefs.setString('sync_disconnect_owed', keepFor);

  /// Whether the app lock was offered on this phone (maybeOfferAppLock): once.
  bool get appLockOffered => _prefs.getBool('app_lock_offered') ?? false;
  Future<void> setAppLockOffered() => _prefs.setBool('app_lock_offered', true);

  /// Whether a passkey was offered after a sign-in that "Confirm it's you" asked
  /// for: once.
  bool get passkeyOffered => _prefs.getBool('passkey_offered') ?? false;
  Future<void> setPasskeyOffered() => _prefs.setBool('passkey_offered', true);

  /// "Not now" on the Security card's ask for the sync password, so that a
  /// recovery of the account keeps its data (3.3.1): not asked again here.
  bool get recoveryProofAskDismissed => _prefs.getBool('recovery_proof_ask_dismissed') ?? false;
  Future<void> setRecoveryProofAskDismissed() => _prefs.setBool('recovery_proof_ask_dismissed', true);

  /// When a passkey last confirmed it is the person on this device (seconds
  /// since the epoch), or null: read only to say in time when a team's Sign-in
  /// lasts runs out. Forgotten when the account signs out.
  int? get stepUpAt => _prefs.getInt('step_up_at');
  Future<void> setStepUpAt(int? seconds) =>
      seconds == null ? _prefs.remove('step_up_at') : _prefs.setInt('step_up_at', seconds);

  bool get syncOffNoticeHidden => _prefs.getBool('sync_off_notice_hidden') ?? false;
  Future<void> setSyncOffNoticeHidden(bool hidden) => _prefs.setBool('sync_off_notice_hidden', hidden);

  bool get bellEnabled => _prefs.getBool('bell_enabled') ?? true;
  Future<void> setBellEnabled(bool enabled) =>
      _prefs.setBool('bell_enabled', enabled);

  /// Render programming ligatures (FiraCode / Cascadia Code: -> => != >= ===).
  /// Default OFF: the ligature paint path only activates when this is on, so
  /// the terminal renders byte-identically until a user opts in.
  bool get terminalLigatures =>
      _prefs.getBool('terminal_ligatures') ?? false;
  Future<void> setTerminalLigatures(bool enabled) =>
      _prefs.setBool('terminal_ligatures', enabled);

  /// Notify when a monitored host changes into Critical / Warning / offline.
  bool get monitorAlertsEnabled =>
      _prefs.getBool('monitor_alerts_enabled') ?? true;
  Future<void> setMonitorAlertsEnabled(bool enabled) =>
      _prefs.setBool('monitor_alerts_enabled', enabled);

  /// Whether the app checks the website for a newer release and shows the
  /// update banner. Default on. Off = no network call is ever made. The key
  /// is shared with `update_providers.dart` (`updateCheckEnabledProvider`),
  /// which owns the reactive state; this accessor is for the settings UI.
  bool get updateCheckEnabled =>
      _prefs.getBool('update_check_enabled') ?? true;
  Future<void> setUpdateCheckEnabled(bool enabled) =>
      _prefs.setBool('update_check_enabled', enabled);

  bool get hapticFeedback => _prefs.getBool('haptic_feedback') ?? true;
  Future<void> setHapticFeedback(bool enabled) =>
      _prefs.setBool('haptic_feedback', enabled);

  /// Recording (presenter) mode: mask host addresses, usernames and key
  /// fingerprints in the app chrome so a screen recording or screenshot leaks
  /// nothing real. Device-local (never synced) and defaults off.
  bool get recordingModeEnabled =>
      _prefs.getBool('recording_mode_enabled') ?? false;
  Future<void> setRecordingModeEnabled(bool enabled) =>
      _prefs.setBool('recording_mode_enabled', enabled);

  /// Free-tier jump-host gate notice, shown ONCE per host and source (the key
  /// is `<host id>:<network name or "base">`) and remembered here, so a chain
  /// the connect path did not dial is explained on first use but does not nag
  /// on every connect. Device-local.
  bool hasShownJumpGateNotice(String key) =>
      _prefs.getBool('jump_gate_notice_shown:$key') ?? false;
  Future<void> markJumpGateNoticeShown(String key) =>
      _prefs.setBool('jump_gate_notice_shown:$key', true);

  /// Recording-mode level: `layout` (default) keeps the shape of names,
  /// `strict` replaces them with unrelated words (spec section 4).
  String get recordingRedactLevel =>
      _prefs.getString('recording_redact_level') ?? 'layout';
  Future<void> setRecordingRedactLevel(String level) =>
      _prefs.setString('recording_redact_level', level);

  /// The per-install secret recording mode mixes into every hashed stand-in
  /// (`userNN`, `host-NN`, the fake addresses, the Strict words), so a viewer
  /// cannot confirm a guess by hashing a candidate value themselves. Generated
  /// once (16 random bytes, hex) on first use and never synced; a mask stays
  /// the same for the life of the install, which is what the docs promise.
  String get recordingMaskSalt {
    final existing = _prefs.getString('recording_mask_salt');
    if (existing != null && existing.isNotEmpty) return existing;
    final rnd = Random.secure();
    final salt = List<int>.generate(16, (_) => rnd.nextInt(256))
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    unawaited(_prefs.setString('recording_mask_salt', salt));
    return salt;
  }

  bool get keepScreenAwake =>
      _prefs.getBool('keep_screen_awake') ?? true;
  Future<void> setKeepScreenAwake(bool enabled) =>
      _prefs.setBool('keep_screen_awake', enabled);

  // ── Cursor settings ─────────────────────────────────────────────

  TerminalCursorShape get cursorStyle {
    final value = _prefs.getString('cursor_style');
    if (value == null) return TerminalCursorShape.block;
    final shape = TerminalCursorShape.values.firstWhere(
      (s) => s.key == value,
      orElse: () => TerminalCursorShape.block,
    );
    return shape;
  }

  Future<void> setTerminalCursorShape(TerminalCursorShape style) =>
      _prefs.setString('cursor_style', style.key);

  bool get cursorBlink => _prefs.getBool('cursor_blink') ?? true;
  Future<void> setCursorBlink(bool blink) =>
      _prefs.setBool('cursor_blink', blink);

  /// When the terminal draws its cursor (4.0): always until chosen.
  TerminalCursorVisibility get cursorVisibility {
    final value = _prefs.getString('cursor_visibility');
    return TerminalCursorVisibility.values.firstWhere(
      (v) => v.key == value,
      orElse: () => TerminalCursorVisibility.always,
    );
  }

  Future<void> setCursorVisibility(TerminalCursorVisibility visibility) =>
      _prefs.setString('cursor_visibility', visibility.key);

  // ── Security settings ────────────────────────────────────────────

  bool get securityLockEnabled =>
      _prefs.getBool('security_lock_enabled') ?? false;
  Future<void> setSecurityLockEnabled(bool enabled) =>
      _prefs.setBool('security_lock_enabled', enabled);

  /// Whether the app-lock actually ENCRYPTS data at rest (1.8 vault): the
  /// SQLCipher DB key is wrapped behind the PIN / master password, so the
  /// database only opens after unlock. Default OFF = the legacy behavior where
  /// the DB key sits in OS secure storage and the lock is only a UI overlay.
  /// This is DEVICE-LOCAL and never synced (like the PIN itself).
  bool get encryptingLockEnabled =>
      _prefs.getBool('encrypting_lock_enabled') ?? false;
  Future<void> setEncryptingLockEnabled(bool enabled) =>
      _prefs.setBool('encrypting_lock_enabled', enabled);

  /// What ZestSSH's lock screen says of the sessions still connected behind
  /// it (4.0.1): nothing (the default, the safer choice on a screen others
  /// see), how many, or how many and their names. The computer's, not a
  /// person's: the lock screen reads it before any profile is open. A device
  /// that had 4.0's switch on ('lock_show_sessions') shows how many.
  LockSessionsShown get lockSessionsShown => switch (_prefs.getString('lock_sessions_shown')) {
        'count' => LockSessionsShown.count,
        'names' => LockSessionsShown.names,
        'off' => LockSessionsShown.off,
        _ => _prefs.getBool('lock_show_sessions') == true ? LockSessionsShown.count : LockSessionsShown.off,
      };
  Future<void> setLockSessionsShown(LockSessionsShown shown) async {
    await _prefs.setString('lock_sessions_shown', shown.name);
    await _prefs.remove('lock_show_sessions');
  }

  // ── Snippet execution ───────────────────────────────────────────

  bool get autoExecuteSnippets =>
      _prefs.getBool('auto_execute_snippets') ?? false;
  Future<void> setAutoExecuteSnippets(bool enabled) =>
      _prefs.setBool('auto_execute_snippets', enabled);

  // ── Volume key mapping (Android) ────────────────────────────────

  bool get volumeKeysEnabled =>
      _prefs.getBool('volume_keys_enabled') ?? false;
  Future<void> setVolumeKeysEnabled(bool enabled) =>
      _prefs.setBool('volume_keys_enabled', enabled);

  // ── Notification history (mobile persistence) ──────────────────
  //
  // The notifications screen's history survives an app restart. Stored as a
  // JSON array string; the NotificationCenter caps + prunes it on save.

  String? get notificationHistory => _prefs.getString('notification_history');
  Future<void> setNotificationHistory(String json) =>
      _prefs.setString('notification_history', json);

  // ── Auto Backup ────────────────────────────────────────────────

  String get autoBackupInterval =>
      _prefs.getString('auto_backup_interval') ?? 'off';
  Future<void> setAutoBackupInterval(String interval) =>
      _prefs.setString('auto_backup_interval', interval);

  DateTime? get lastAutoBackupTime {
    final iso = _prefs.getString('last_auto_backup_time');
    return iso != null ? DateTime.tryParse(iso) : null;
  }

  Future<void> setLastAutoBackupTime(DateTime time) =>
      _prefs.setString('last_auto_backup_time', time.toIso8601String());

  /// When the last backup on a change was begun (3.4.2): one is begun at most
  /// once an hour (AutoBackupService.changeEvery), made or not, and it never
  /// moves the daily or weekly one ([lastAutoBackupTime]).
  DateTime? get lastChangeBackupTime {
    final iso = _prefs.getString('last_change_backup_time');
    return iso != null ? DateTime.tryParse(iso) : null;
  }

  Future<void> setLastChangeBackupTime(DateTime time) =>
      _prefs.setString('last_change_backup_time', time.toIso8601String());

  // ── Cloud Sync Mode ───────────────────────────────────────────

  // Default is 'auto' so a user who completes sync setup gets automatic
  // push+pull without having to discover a buried toggle. It no-ops until
  // sync credentials exist, so non-sync users are unaffected. (Historically
  // this defaulted to 'manual', which left every set-up user stranded -
  // nothing pushed or pulled automatically.)
  String get syncMode => _prefs.getString('sync_mode') ?? 'auto';
  Future<void> setSyncMode(String mode) =>
      _prefs.setString('sync_mode', mode);

  int get syncIntervalMinutes =>
      _prefs.getInt('sync_interval_minutes') ?? 15;
  Future<void> setSyncIntervalMinutes(int minutes) =>
      _prefs.setInt('sync_interval_minutes', minutes);

  /// Sync paused on this device by its person (3.0): nothing syncs by
  /// itself until [SyncPause.until], or until they resume it where that is
  /// null; Sync now still syncs, and sync stays set up. Null where it is not
  /// paused. Kept on this device only. (A pause whose time has passed is
  /// still read here: [SyncPause.at] says whether it holds.)
  SyncPause? get syncPause {
    final raw = _prefs.getString('sync_paused_until');
    if (raw == null || raw.isEmpty) return null;
    if (raw == _untilResumed) return const SyncPause();
    final until = DateTime.tryParse(raw);
    return until == null ? null : SyncPause(until: until.toLocal());
  }

  Future<void> setSyncPause(SyncPause? pause) => pause == null
      ? _prefs.remove('sync_paused_until')
      : _prefs.setString('sync_paused_until', pause.until?.toUtc().toIso8601String() ?? _untilResumed);

  static const _untilResumed = 'until-resumed';

  DateTime? get lastSyncTime {
    final iso = _prefs.getString('last_sync_time');
    return iso != null ? DateTime.tryParse(iso) : null;
  }

  Future<void> setLastSyncTime(DateTime time) =>
      _prefs.setString('last_sync_time', time.toIso8601String());

  // Last server sync-blob version this device has reconciled with. Used to
  // decide when to pull (server ahead) and as the optimistic-lock
  // `expected_version` on push so a stale device gets a 409 instead of
  // clobbering a newer blob.
  int get syncServerVersion => _prefs.getInt('sync_server_version') ?? 0;

  /// [storeUpdatedAt] is when the store says that version was written, where
  /// whoever sets the version knows it; left out, it is forgotten with the
  /// version it belonged to ([syncStoreUpdatedAt]).
  Future<void> setSyncServerVersion(int v, {DateTime? storeUpdatedAt}) async {
    await _prefs.setInt('sync_server_version', v);
    await setSyncStoreUpdatedAt(storeUpdatedAt);
  }

  /// When the store was written, as it said itself the last time this device
  /// was level with it; null while the device does not know (it has not asked
  /// since it last sent something to a server that does not say).
  ///
  /// A count alone does not say that a store is the one the device left: a
  /// store restored from a backup counts on from where the backup was, and
  /// reaches a device's number again with something else under it. The count
  /// and the time together do.
  DateTime? get syncStoreUpdatedAt {
    final ms = _prefs.getInt('sync_store_updated_at');
    return ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  }

  Future<void> setSyncStoreUpdatedAt(DateTime? at) => at == null
      ? _prefs.remove('sync_store_updated_at')
      : _prefs.setInt('sync_store_updated_at', at.millisecondsSinceEpoch);

  // True when local data has changed since the last successful push.
  // Persisted so a force-quit between edit and push doesn't strand the
  // change. Cleared on a successful push.
  bool get syncDirty => _prefs.getBool('sync_dirty') ?? false;

  /// How many times local data was marked as changed ([setSyncDirty] true) in
  /// this run of the app, whichever settings service marked it. A push reads it
  /// before it gathers what it sends, and clears the flag only where nothing
  /// was marked since ([clearSyncDirty]).
  int get syncDirtyMark => _syncDirtyMarks;
  static int _syncDirtyMarks = 0;

  Future<void> setSyncDirty(bool dirty) async {
    if (dirty) _syncDirtyMarks++;
    // When the changes started waiting, so the status can tell a push on
    // its way from one stuck for minutes.
    if (dirty && !syncDirty) {
      await _prefs.setString('sync_dirty_since', DateTime.now().toIso8601String());
    } else if (!dirty) {
      await _prefs.remove('sync_dirty_since');
    }
    await _prefs.setBool('sync_dirty', dirty);
  }

  /// Clears the flag [setSyncDirty] sets, unless local data was marked as
  /// changed after [since] (the [syncDirtyMark] read before what was sent was
  /// gathered): a change saved while a push was on its way is not in that
  /// push, and stays marked for the next. (The flag was cleared over it, and
  /// the change stayed on this device, called synced.) Both values are set
  /// before anything waits, so a mark that comes meanwhile is never undone.
  Future<void> clearSyncDirty({required int since}) async {
    if (_syncDirtyMarks != since) return;
    await Future.wait([_prefs.setBool('sync_dirty', false), _prefs.remove('sync_dirty_since')]);
  }

  /// Since when local changes have been waiting to sync; null when none are
  /// (or they predate this being recorded).
  DateTime? get syncDirtySince {
    final iso = _prefs.getString('sync_dirty_since');
    return iso == null ? null : DateTime.tryParse(iso);
  }

  // Fingerprint (SyncDataService.contentFingerprint) of the content at the
  // last successful push/pull. Used to skip no-op pushes and, importantly,
  // the echo push a pull's own restore writes would otherwise trigger.
  String get syncContentHash => _prefs.getString('sync_content_hash') ?? '';
  Future<void> setSyncContentHash(String h) =>
      _prefs.setString('sync_content_hash', h);

  // Whether the account's sync store holds a recovery key (3.0), as
  // last seen by this device; null until it has looked. Device-local, never
  // synced: the store is the truth, this only saves the Account screen a
  // round trip.
  bool? get syncRecoveryKeySet => _prefs.getBool('sync_recovery_key_set');
  Future<void> setSyncRecoveryKeySet(bool? value) => value == null
      ? _prefs.remove('sync_recovery_key_set')
      : _prefs.setBool('sync_recovery_key_set', value);

  // ── Connection Defaults ──────────────────────────────────────────

  int get defaultPort => _prefs.getInt('default_port') ?? 22;
  Future<void> setDefaultPort(int port) =>
      _prefs.setInt('default_port', port);

  String get defaultUsername => _prefs.getString('default_username') ?? 'root';
  Future<void> setDefaultUsername(String username) =>
      _prefs.setString('default_username', username);

  int get connectionTimeout => _prefs.getInt('connection_timeout') ?? 15;
  Future<void> setConnectionTimeout(int seconds) =>
      _prefs.setInt('connection_timeout', seconds);

  // ── Terminal Margin ────────────────────────────────────────────

  /// Padding (in pixels) around the terminal content.
  /// Useful for phones with curved edges or thick screen protectors.
  /// Room between the pane edge and the text. Desktop panes default to 8px
  /// so text never sits flush against a border; phones keep every column.
  double get terminalMargin =>
      _prefs.getDouble('terminal_margin') ?? (isDesktopPlatform ? 8.0 : 0.0);
  Future<void> setTerminalMargin(double margin) =>
      _prefs.setDouble('terminal_margin', margin);

  // ── Extra Keyboard Position ──────────────────────────────────

  /// Position of the extra keyboard row: 'aboveKeyboard' (default),
  /// 'aboveTerminal', or 'disabled'.
  String get extraKeyboardPosition =>
      _prefs.getString('extra_keyboard_position') ?? 'aboveKeyboard';
  Future<void> setExtraKeyboardPosition(String position) =>
      _prefs.setString('extra_keyboard_position', position);

  // ── Terminal Behaviour (extended) ──────────────────────────────

  // Default ON: ZestSSH is PuTTY-heritage, where highlighting text copies it
  // to the clipboard (and right-click pastes). Users who dislike it can turn
  // it off in Settings > Terminal; the choice then syncs across devices.
  bool get copyOnSelect => _prefs.getBool('copy_on_select') ?? true;
  Future<void> setCopyOnSelect(bool enabled) =>
      _prefs.setBool('copy_on_select', enabled);

  /// Turn a terminal into the native tmux workspace when `tmux -CC` starts
  /// in it (in-band control mode).
  bool get tmuxAutoDetect => _prefs.getBool('tmux_auto_detect') ?? true;

  /// Tabs that say where a host comes from (3.3.0): 'auto' (while tabs from
  /// more than one place are open), 'always' or 'off'; and whether the line
  /// has the vault and the group in it.
  String get tabSourceMode => _prefs.getString('tab_source_mode') ?? 'auto';
  Future<void> setTabSourceMode(String mode) => _prefs.setString('tab_source_mode', mode);
  bool get tabSourceVault => _prefs.getBool('tab_source_vault') ?? true;
  Future<void> setTabSourceVault(bool on) => _prefs.setBool('tab_source_vault', on);
  bool get tabSourceGroup => _prefs.getBool('tab_source_group') ?? true;
  Future<void> setTabSourceGroup(bool on) => _prefs.setBool('tab_source_group', on);
  Future<void> setTmuxAutoDetect(bool enabled) =>
      _prefs.setBool('tmux_auto_detect', enabled);

  /// Mosh hosts open with the mosh program installed on this computer instead
  /// of the app's own client (4.0; a Mac and Linux only, where Settings offers
  /// it: a phone, a tablet and Windows always use the app's own). Off by
  /// default.
  bool get moshSystemClient => _prefs.getBool('mosh_system_client') ?? false;
  Future<void> setMoshSystemClient(bool on) => _prefs.setBool('mosh_system_client', on);

  /// Let a remote program write the local clipboard through OSC 52 (tmux,
  /// Neovim / Vim over SSH). Default OFF: with it on, the remote side decides
  /// what the next paste contains. Reads are refused regardless (see Osc52).
  bool get osc52Clipboard => _prefs.getBool('osc52_clipboard') ?? false;
  Future<void> setOsc52Clipboard(bool enabled) =>
      _prefs.setBool('osc52_clipboard', enabled);

  // ── Session log (device-local: it names a folder on THIS device) ──

  /// Write every session's output to a plain-text file as it happens.
  /// Default OFF: the file holds whatever the session printed, secrets
  /// included, unencrypted so any editor can open it.
  bool get sessionLogEnabled =>
      _prefs.getBool('session_log_enabled') ?? false;
  Future<void> setSessionLogEnabled(bool enabled) =>
      _prefs.setBool('session_log_enabled', enabled);

  /// Folder the logs go to; empty = the app's default log folder.
  String get sessionLogDirectory =>
      _prefs.getString('session_log_dir') ?? '';
  Future<void> setSessionLogDirectory(String path) =>
      _prefs.setString('session_log_dir', path);

  /// Prefix every logged line with the local time it arrived.
  bool get sessionLogTimestamps =>
      _prefs.getBool('session_log_timestamps') ?? false;
  Future<void> setSessionLogTimestamps(bool enabled) =>
      _prefs.setBool('session_log_timestamps', enabled);

  /// Whether the terminal asks the on-screen keyboard not to learn from what
  /// is typed there (Android). On until its person turns it off: commands,
  /// host names and passwords at a prompt are typed there. Kept on this
  /// device and never synced: which keyboard copes with it is a matter of
  /// the device.
  bool get keyboardIncognito => _prefs.getBool('keyboard_incognito') ?? true;
  Future<void> setKeyboardIncognito(bool enabled) => _prefs.setBool('keyboard_incognito', enabled);

  /// Whether the terminal asks the on-screen keyboard for the layout it shows
  /// for a password typed in the open (Android): no word suggestions, and on
  /// many keyboards a smaller row above the keys, so more of the terminal
  /// fits. Off until its person turns it on, as some
  /// keyboards then type only Latin letters. Kept on this device and never
  /// synced: what a keyboard shows is a matter of the device.
  bool get compactKeyboard => _prefs.getBool('compact_keyboard') ?? false;
  Future<void> setCompactKeyboard(bool enabled) => _prefs.setBool('compact_keyboard', enabled);

  /// Whether a terminal's new lines are read out while a screen reader is on
  /// (4.0 accessibility pass, TerminalReadAloud). On until its person turns
  /// it off in Read the screen. Kept on this device: a screen reader is.
  bool get terminalReadAloud => _prefs.getBool('terminal_read_aloud') ?? true;
  Future<void> setTerminalReadAloud(bool enabled) => _prefs.setBool('terminal_read_aloud', enabled);

  /// Whether Option (Alt) held with a key sends ESC and the key's character
  /// to the terminal, as Meta (an iPad's, an iPhone's and a Mac's keyboard).
  /// On until changed on an iPad and an iPhone, where Option types nothing a
  /// terminal needs; off on a Mac, where it types the layout's special
  /// characters (Terminal.app's and iTerm2's default). Kept on this device
  /// and never synced: a Mac and an iPad of one person want it otherwise.
  bool get optionAsMeta => _prefs.getBool('option_as_meta') ?? defaultTargetPlatform != TargetPlatform.macOS;
  Future<void> setOptionAsMeta(bool enabled) => _prefs.setBool('option_as_meta', enabled);

  /// What a phone's and a tablet's row of keys over the keyboard does while
  /// a hardware keyboard is typed on: hides (`hide`), stays (`always`) or
  /// keeps only the keys such a keyboard lacks (`missingOnly`, 3.2.1);
  /// HardwareKeysRow's names. Null until chosen: the device's default then
  /// (HardwareKeysRow.defaultFor). Before 3.2.1 a switch (keys_row_auto_hide)
  /// said hide or always, and is read as that. Kept on this device and never
  /// synced: a keyboard is the device's.
  String? get keysRowHardware =>
      _prefs.getString('keys_row_hardware') ??
      switch (_prefs.getBool('keys_row_auto_hide')) {
        true => 'hide',
        false => 'always',
        null => null,
      };
  Future<void> setKeysRowHardware(String mode) => _prefs.setString('keys_row_hardware', mode);

  bool get showExtraKeyboardRow =>
      _prefs.getBool('show_extra_keyboard') ?? true;
  Future<void> setShowExtraKeyboardRow(bool enabled) =>
      _prefs.setBool('show_extra_keyboard', enabled);

  /// When true, the soft keyboard's extra row is rendered as a single
  /// horizontally-scrollable strip with every key directly tappable
  /// (no FN modifier toggle). When false, the legacy two-row + FN-mode
  /// layout is used. Default: false (preserve existing behaviour).
  bool get softKeyboardScrollableMode =>
      _prefs.getBool('soft_keyboard_scrollable_mode') ?? false;
  Future<void> setSoftKeyboardScrollableMode(bool enabled) =>
      _prefs.setBool('soft_keyboard_scrollable_mode', enabled);

  /// How the two-row key row is drawn: `grouped` (the default), `flat` or
  /// `compact` (SoftKeyRowStyle's names).
  String get softKeyboardStyle =>
      _prefs.getString('soft_keyboard_style') ?? 'grouped';
  Future<void> setSoftKeyboardStyle(String style) =>
      _prefs.setString('soft_keyboard_style', style);

  /// How big the row's keys are: `small`, `medium` or `large` (SoftKeySize's
  /// names, 3.2.1). Until chosen, 3.1's Compact style is `small` and anything
  /// else `medium`. Kept on this device, as the row's other settings are.
  String get softKeyboardKeySize =>
      _prefs.getString('soft_keyboard_key_size') ??
      (_prefs.getString('soft_keyboard_style') == 'compact' ? 'small' : 'medium');
  Future<void> setSoftKeyboardKeySize(String size) =>
      _prefs.setString('soft_keyboard_key_size', size);

  /// Stable ids of soft-keyboard keys the user has hidden. Lets users
  /// declutter the row by disabling keys they never use (e.g. F11/F12,
  /// the tilde, the pipe). Stored as a comma-separated string in prefs.
  Set<String> get softKeyboardDisabledKeys {
    final raw = _prefs.getString('soft_keyboard_disabled_keys') ?? '';
    if (raw.isEmpty) return const <String>{};
    return raw.split(',').where((s) => s.isNotEmpty).toSet();
  }

  Future<void> setSoftKeyboardDisabledKeys(Set<String> ids) =>
      _prefs.setString(
        'soft_keyboard_disabled_keys',
        ids.toList().join(','),
      );

  /// The hosts that were SFTP only here until a device on an older version of
  /// ZestSSH, which knows no such type, sent them back as SSH hosts
  /// ([SyncDataService.restoreAll] sees it). This device's own note, never
  /// synced, said on the screen of such a host when it gives no terminal.
  List<String> get sftpOnlyTurnedBack =>
      _prefs.getStringList('sftp_only_turned_back') ?? const <String>[];

  /// Notes [hostId] as turned back; the latest 200 are kept.
  Future<void> noteSftpOnlyTurnedBack(String hostId) async {
    final noted = sftpOnlyTurnedBack;
    if (noted.contains(hostId)) return;
    final all = [...noted, hostId];
    await _prefs.setStringList('sftp_only_turned_back', all.sublist(all.length > 200 ? all.length - 200 : 0));
  }

  /// [hostId] is SFTP only again, or was changed by the person: nothing to say
  /// of it any more.
  Future<void> forgetSftpOnlyTurnedBack(String hostId) async {
    final noted = sftpOnlyTurnedBack;
    if (!noted.contains(hostId)) return;
    await _prefs.setStringList('sftp_only_turned_back', [
      for (final id in noted)
        if (id != hostId) id,
    ]);
  }

  /// User-defined key order for the scrollable soft-keyboard's two rows.
  /// Returns an empty list when the user hasn't customised it - the caller
  /// (provider) fills in the catalog defaults, and reconciles against the
  /// current catalog so version drift never loses or duplicates keys.
  List<String> get softKeyboardRow1Order =>
      _prefs.getStringList('soft_keyboard_row1_order') ?? const <String>[];
  Future<void> setSoftKeyboardRow1Order(List<String> ids) =>
      _prefs.setStringList('soft_keyboard_row1_order', ids);

  List<String> get softKeyboardRow2Order =>
      _prefs.getStringList('soft_keyboard_row2_order') ?? const <String>[];
  Future<void> setSoftKeyboardRow2Order(List<String> ids) =>
      _prefs.setStringList('soft_keyboard_row2_order', ids);

  /// How many of the last lines Copy from screen shows: 100 (the default),
  /// 250, 500, 1000, a count of the person's own (Custom), or 0 for all of
  /// them. Kept on this device.
  int get copyScreenLines => _prefs.getInt('copy_screen_lines') ?? 100;
  Future<void> setCopyScreenLines(int lines) => _prefs.setInt('copy_screen_lines', lines);

  bool get closeConfirmation =>
      _prefs.getBool('close_confirmation') ?? true;
  Future<void> setCloseConfirmation(bool enabled) =>
      _prefs.setBool('close_confirmation', enabled);

  // Default 30s (S2): this global is now the effective keepalive for any
  // connection that doesn't set its own (see terminal_providers SshService
  // construction). Read-fallback only - no migration write - so users who
  // never touched it auto-adopt 30s, while an explicit stored value (incl. 0
  // = disabled) is preserved.
  int get keepaliveIntervalSeconds =>
      _prefs.getInt('keepalive_interval') ?? 30;
  Future<void> setKeepaliveIntervalSeconds(int seconds) =>
      _prefs.setInt('keepalive_interval', seconds);

  // ── Connection Defaults (extended) ──────────────────────────────

  /// Default auth method: 'password', 'publicKey', or 'ask'.
  String get defaultAuthMethod =>
      _prefs.getString('default_auth_method') ?? 'ask';
  Future<void> setDefaultAuthMethod(String method) =>
      _prefs.setString('default_auth_method', method);

  /// Default identity ID to pre-select for new connections (nullable).
  String? get defaultIdentityId =>
      _prefs.getString('default_identity_id');
  Future<void> setDefaultIdentityId(String? id) async {
    if (id == null) {
      await _prefs.remove('default_identity_id');
    } else {
      await _prefs.setString('default_identity_id', id);
    }
  }

  // ── Snippet Settings ──────────────────────────────────────────

  /// Require confirmation before running destructive commands
  /// (rm, shutdown, reboot, etc.).
  bool get snippetDestructiveConfirmation =>
      _prefs.getBool('snippet_destructive_confirm') ?? true;
  Future<void> setSnippetDestructiveConfirmation(bool enabled) =>
      _prefs.setBool('snippet_destructive_confirm', enabled);

  /// Default category for newly created snippets (nullable).
  String? get defaultSnippetCategory =>
      _prefs.getString('default_snippet_category');
  Future<void> setDefaultSnippetCategory(String? category) async {
    if (category == null) {
      await _prefs.remove('default_snippet_category');
    } else {
      await _prefs.setString('default_snippet_category', category);
    }
  }

  // ── Notifications ─────────────────────────────────────────────

  bool get notifyConnectionLost =>
      _prefs.getBool('notify_connection_lost') ?? true;
  Future<void> setNotifyConnectionLost(bool enabled) =>
      _prefs.setBool('notify_connection_lost', enabled);

  bool get notifyTransferComplete =>
      _prefs.getBool('notify_transfer_complete') ?? true;
  Future<void> setNotifyTransferComplete(bool enabled) =>
      _prefs.setBool('notify_transfer_complete', enabled);

  bool get notifyTransferFailed =>
      _prefs.getBool('notify_transfer_failed') ?? true;
  Future<void> setNotifyTransferFailed(bool enabled) =>
      _prefs.setBool('notify_transfer_failed', enabled);

  bool get notifySecurityAlerts =>
      _prefs.getBool('notify_security_alerts') ?? true;
  Future<void> setNotifySecurityAlerts(bool enabled) =>
      _prefs.setBool('notify_security_alerts', enabled);

  bool get notifyUpdateAvailable =>
      _prefs.getBool('notify_update_available') ?? true;
  Future<void> setNotifyUpdateAvailable(bool enabled) =>
      _prefs.setBool('notify_update_available', enabled);

  /// Whether a computer shows the app's notices (connection lost, a
  /// workflow's, an alert with a sound, a reply from support) as the
  /// system's notifications as well (4.0). Off at first; this computer's
  /// alone (not synced).
  bool get desktopSystemNotifications =>
      _prefs.getBool('desktop_system_notifications') ?? false;
  Future<void> setDesktopSystemNotifications(bool enabled) =>
      _prefs.setBool('desktop_system_notifications', enabled);

  // ── Server Health Checks ─────────────────────────────────────

  /// Whether saved hosts are checked for being reachable (a connection to
  /// each at an interval, closed without signing in). Off until its person
  /// turns it on: a server sees and logs every check, and one that bans
  /// addresses for connections that end before sign-in bans this device for
  /// them.
  ///
  /// Kept under a name of its own. The one before it ('health_checks_enabled')
  /// was on unless turned off, and was chosen under words that called a
  /// check a ping: what it holds is not taken for a choice to be checked.
  /// This device's own: an address is banned, not an account.
  bool get serverHealthChecksEnabled =>
      _prefs.getBool('reachability_checks_enabled') ?? false;
  Future<void> setServerHealthChecksEnabled(bool enabled) =>
      _prefs.setBool('reachability_checks_enabled', enabled);

  int get healthCheckIntervalSeconds =>
      _prefs.getInt('health_check_interval') ?? 60;
  Future<void> setHealthCheckIntervalSeconds(int seconds) =>
      _prefs.setInt('health_check_interval', seconds);

  // ── Auto Reconnect ──────────────────────────────────────────

  /// Whether sessions automatically reconnect after an unexpected disconnect.
  bool get autoReconnectEnabled =>
      _prefs.getBool('auto_reconnect') ?? true;
  Future<void> setAutoReconnectEnabled(bool enabled) =>
      _prefs.setBool('auto_reconnect', enabled);

  /// Whether to warn before pasting or executing dangerous commands.
  bool get dangerousCommandProtection =>
      _prefs.getBool('dangerous_command_protection') ?? true;
  Future<void> setDangerousCommandProtection(bool enabled) =>
      _prefs.setBool('dangerous_command_protection', enabled);

  // ── Host Key Settings ────────────────────────────────────────

  /// Whether to show a confirmation dialog for new (unknown) host keys.
  bool get askBeforeTrustingNewKeys =>
      _prefs.getBool('ask_before_trusting_keys') ?? true;
  Future<void> setAskBeforeTrustingNewKeys(bool enabled) =>
      _prefs.setBool('ask_before_trusting_keys', enabled);

  // ── Server Monitor / Prometheus ──────────────────────────────────

  /// Data source for server monitor: 'ssh' (default) or 'prometheus'.
  String get monitorDataSource =>
      _prefs.getString('monitor_data_source') ?? 'ssh';
  Future<void> setMonitorDataSource(String source) =>
      _prefs.setString('monitor_data_source', source);

  /// Persisted sort mode for the Server Monitor list. Stores a `_SortMode`
  /// enum name; defaults to 'severity' (worst-first). Unknown
  /// values fall back to the default at the call site.
  String get monitorSortMode =>
      _prefs.getString('monitor_sort_mode') ?? 'severity';
  Future<void> setMonitorSortMode(String mode) =>
      _prefs.setString('monitor_sort_mode', mode);

  /// Prometheus base URL (e.g., http://192.0.2.21:9090).
  String? get prometheusUrl => _prefs.getString('prometheus_url');
  Future<void> setPrometheusUrl(String? url) async {
    if (url == null || url.isEmpty) {
      await _prefs.remove('prometheus_url');
    } else {
      // Security: warn when using plain HTTP with a non-localhost host,
      // as credentials and metrics data will be transmitted unencrypted.
      final uri = Uri.tryParse(url);
      if (uri != null &&
          uri.scheme == 'http' &&
          uri.host != 'localhost' &&
          uri.host != '127.0.0.1' &&
          uri.host != '::1') {
        AppLogger.warning(
          'Prometheus URL uses plain HTTP with remote host '
          '(${uri.host}). Credentials and data will be sent unencrypted.',
        );
      }
      await _prefs.setString('prometheus_url', url);
    }
  }

  /// Prometheus auth type key (see [PrometheusAuthType.key]).
  String get prometheusAuthType =>
      _prefs.getString('prometheus_auth_type') ?? 'none';
  Future<void> setPrometheusAuthType(String type) =>
      _prefs.setString('prometheus_auth_type', type);

  /// Whether to verify the Prometheus server's SSL certificate.
  /// Default true. Disable only for debugging with self-signed certs
  /// where no CA has been imported.
  bool get prometheusVerifySsl =>
      _prefs.getBool('prometheus_verify_ssl') ?? true;
  Future<void> setPrometheusVerifySsl(bool verify) =>
      _prefs.setBool('prometheus_verify_ssl', verify);

  /// Custom DNS server IP for resolving internal hostnames
  /// (e.g. "192.168.10.53") through the VPN tunnel.

  /// Custom header name for the "Custom Header" auth type
  /// (e.g. "X-Authelia-Token").
  String? get prometheusCustomHeaderKey =>
      _prefs.getString('prometheus_custom_header_key');
  Future<void> setPrometheusCustomHeaderKey(String? key) async {
    if (key == null || key.isEmpty) {
      await _prefs.remove('prometheus_custom_header_key');
    } else {
      await _prefs.setString('prometheus_custom_header_key', key);
    }
  }

  // ── Legacy Prometheus fields (migrated to secure storage) ────────
  // Kept for one-time migration reads. Do not use for new code.

  /// @deprecated Use [PrometheusSecureSettings.getBearerToken] instead.
  String? get prometheusBearerToken =>
      _prefs.getString('prometheus_bearer_token');
  Future<void> clearLegacyPrometheusBearerToken() =>
      _prefs.remove('prometheus_bearer_token');

  /// @deprecated Use [PrometheusSecureSettings.getBasicAuthUser] instead.
  String? get prometheusBasicAuthUser =>
      _prefs.getString('prometheus_basic_auth_user');
  Future<void> clearLegacyPrometheusBasicAuthUser() =>
      _prefs.remove('prometheus_basic_auth_user');

  /// @deprecated Use [PrometheusSecureSettings.getBasicAuthPassword] instead.
  String? get prometheusBasicAuthPassword =>
      _prefs.getString('prometheus_basic_auth_password');
  Future<void> clearLegacyPrometheusBasicAuthPassword() =>
      _prefs.remove('prometheus_basic_auth_password');

  // ── Workspace Persistence ────────────────────────────────────────

  /// Which workspace was last active (nullable).
  String? get lastWorkspaceId => _prefs.getString('last_workspace_id');
  Future<void> setLastWorkspaceId(String? id) async {
    if (id == null) {
      await _prefs.remove('last_workspace_id');
    } else {
      await _prefs.setString('last_workspace_id', id);
    }
  }

  /// Whether to automatically restore the last workspace on launch.
  bool get autoRestoreWorkspace =>
      _prefs.getBool('auto_restore_workspace') ?? true;
  Future<void> setAutoRestoreWorkspace(bool enabled) =>
      _prefs.setBool('auto_restore_workspace', enabled);

  // ── Automation ──────────────────────────────────────────────────

  /// Whether external automation (Tasker, Shortcuts, intents) is allowed.
  /// Default OFF - user must explicitly opt in (Pro feature).
  bool get automationEnabled =>
      _prefs.getBool('automation_enabled') ?? false;
  Future<void> setAutomationEnabled(bool enabled) =>
      _prefs.setBool('automation_enabled', enabled);

  // ── Networks ─────────────────────────────────────────────────────

  /// Manually forced network profile id, overriding auto-detection. Null
  /// means "Auto" (detect from the current connection). Persisted so a
  /// forced profile survives an app restart. Consumed by the resolver via
  /// [manualNetworkOverrideProvider] and surfaced in the current-network
  /// banner's override control.
  String? get manualNetworkOverrideId =>
      _prefs.getString('manual_network_override_id');
  Future<void> setManualNetworkOverrideId(String? id) async {
    if (id == null) {
      await _prefs.remove('manual_network_override_id');
    } else {
      await _prefs.setString('manual_network_override_id', id);
    }
  }

  // ── Import/Export ────────────────────────────────────────────────

  /// Whether the first-run "get connected" experience (F1) has been shown.
  /// Set once the user finishes or skips it so it never reappears. The router
  /// also treats onboarding as complete when any connection already exists.
  bool get hasCompletedOnboarding =>
      _prefs.getBool('onboarding_complete') ?? false;
  Future<void> setOnboardingComplete() =>
      _prefs.setBool('onboarding_complete', true);

  // ── Cross-device settings sync ───────────────────────────────────
  //
  // A curated allowlist of preference keys that travel with the encrypted
  // sync blob so a user's terminal look-and-feel and connection defaults
  // follow them between devices. Everything NOT on this list stays
  // device-local by design: sync bookkeeping (`sync_*`), auto-backup timers,
  // the security lock / PIN, the update-check toggle, Prometheus endpoint +
  // monitor data-source (per-device infrastructure), onboarding + workspace
  // state, and the `default_identity_id` / `default_snippet_category` /
  // `manual_network_override_id` ids (they reference per-device rows).
  //
  // The list is deliberately kept SORTED and the export emits keys in this
  // order so a pull -> restore -> gather round-trip is byte-stable and never
  // triggers an echo push. Keep it additive.
  static const List<String> _syncedBoolKeys = [
    'ask_before_trusting_keys',
    'auto_reconnect',
    'bell_enabled',
    'close_confirmation',
    'copy_on_select',
    'cursor_blink',
    'dangerous_command_protection',
    'haptic_feedback',
    'keep_screen_awake',
    'monitor_alerts_enabled',
    'notify_connection_lost',
    // Since 3.0 (16 October 2026): a phone has the switch of security alerts
    // now, and one device's choice of these two holds on every other, as the
    // two beside them did.
    'notify_security_alerts',
    'notify_transfer_complete',
    'notify_transfer_failed',
    'osc52_clipboard',
    'snippet_destructive_confirm',
    'tmux_auto_detect',
    'terminal_ligatures',
  ];
  static const List<String> _syncedIntKeys = [
    'connection_timeout',
    'default_port',
    'keepalive_interval',
    'scrollback_lines',
  ];
  static const List<String> _syncedDoubleKeys = [
    'terminal_font_size',
    'terminal_margin',
  ];
  static const List<String> _syncedStringKeys = [
    'cursor_style',
    'default_auth_method',
    'default_username',
    // The shortcut-override map (JSON) lives in this same prefs store under
    // its own key (see shortcut_overrides_provider). Round-tripping the raw
    // string keeps rebinds in sync; the notifier re-reads it on next launch.
    'shortcut_overrides',
    'terminal_font',
    'terminal_theme',
  ];
  // The extra key row's settings (whether it shows, where, its style, the
  // scrollable rows, their keys and order) stay on each device since 3.2: a
  // phone's and a tablet's rows differ, and a change on one changed the other.
  // A device keeps what it had.
  static const List<String> _syncedStringListKeys = [];

  /// Every synced key in a single, stable, alphabetical order. Both
  /// [exportSyncedSettings] and [importSyncedSettings] iterate this so the
  /// emitted JSON object has a deterministic key order.
  static final List<String> _syncedSettingKeysSorted = [
    ..._syncedBoolKeys,
    ..._syncedIntKeys,
    ..._syncedDoubleKeys,
    ..._syncedStringKeys,
    ..._syncedStringListKeys,
  ]..sort();

  static const int _maxSyncedStringLen = 16384;
  static const int _maxSyncedListItemLen = 128;
  static const int _maxSyncedListItems = 200;

  /// C0/C1 control characters (minus tab/newline/carriage-return, which some
  /// values legitimately contain) plus the Unicode bidi/RTL-override and
  /// zero-width/format characters used for homoglyph/spoofing. Stripped from
  /// every imported synced string.
  static final RegExp _syncedStringUnsafe = RegExp(
    r'[\u0000-\u001F\u007F-\u009F\u200B-\u200F\u202A-\u202E\u2066-\u2069\uFEFF]',
  );

  /// What keeps each setting safe that a backup could weaken, by its key: the
  /// value it is safe at.
  static const Map<String, bool> _safeSettings = {
    'ask_before_trusting_keys': true,
    'dangerous_command_protection': true,
    'notify_security_alerts': true,
    'osc52_clipboard': false,
    'snippet_destructive_confirm': true,
  };

  /// The keys, in [incoming] settings from a backup, whose values would leave
  /// this device less safe than it is now: ones not at their safe value that are
  /// at it here (unset counts as the default each has). A backup is a file from
  /// anywhere: a stranger's, with its password, turned the questions off with
  /// nothing said (found in a security audit). Sync from the person's own
  /// account does not ask this.
  List<String> settingsThatWeaken(Map<dynamic, dynamic> incoming) {
    bool now(String key) => switch (key) {
          'ask_before_trusting_keys' => askBeforeTrustingNewKeys,
          'dangerous_command_protection' => dangerousCommandProtection,
          'notify_security_alerts' => notifySecurityAlerts,
          'osc52_clipboard' => osc52Clipboard,
          'snippet_destructive_confirm' => snippetDestructiveConfirmation,
          _ => throw ArgumentError.value(key),
        };
    return [
      for (final e in _safeSettings.entries)
        if (incoming[e.key] is bool && incoming[e.key] != e.value && now(e.key) == e.value) e.key,
    ];
  }

  /// True if [key] is one of the cross-device synced preference keys. Used by
  /// the settings updater to nudge the sync engine only when a change actually
  /// belongs in the sync blob (a device-local toggle must not trigger a push).
  static bool isSyncedSettingKey(String key) =>
      _syncedSettingKeysSorted.contains(key);

  /// Snapshot of the allowlisted settings for the sync blob. Emits only keys
  /// that are actually set (an unset key is omitted, not defaulted), with each
  /// value validated to match its declared type. Deterministic key order.
  Map<String, Object?> exportSyncedSettings() {
    final out = <String, Object?>{};
    for (final key in _syncedSettingKeysSorted) {
      if (!_prefs.containsKey(key)) continue;
      final value = _prefs.get(key);
      if (value == null) continue;
      if (_syncedBoolKeys.contains(key)) {
        if (value is bool) out[key] = value;
      } else if (_syncedIntKeys.contains(key)) {
        if (value is int) out[key] = value;
      } else if (_syncedDoubleKeys.contains(key)) {
        if (value is num) out[key] = value.toDouble();
      } else if (_syncedStringKeys.contains(key)) {
        if (value is String) out[key] = value;
      } else if (_syncedStringListKeys.contains(key)) {
        if (value is List) out[key] = value.whereType<String>().toList();
      }
    }
    return out;
  }

  /// Apply allowlisted settings pulled from another device. Type-checks and
  /// bounds-clamps every value (a hostile or corrupt blob can't write a wrong
  /// type, an out-of-range number, or an unbounded string / list). Unknown
  /// keys and keys absent from [data] are left untouched. Best-effort per key:
  /// one bad entry never aborts the rest.
  ///
  /// Reactivity note: settings read fresh per use (scrollback, keepalive, bell)
  /// take effect on the next new terminal / session; provider-cached ones
  /// (shortcut overrides, theme) apply on next app launch.
  Future<void> importSyncedSettings(Map<String, dynamic> data) async {
    for (final key in _syncedSettingKeysSorted) {
      if (!data.containsKey(key)) continue;
      final value = data[key];
      if (value == null) continue;
      try {
        if (_syncedBoolKeys.contains(key)) {
          if (value is bool) await _prefs.setBool(key, value);
        } else if (_syncedIntKeys.contains(key)) {
          if (value is num) {
            await _prefs.setInt(key, _clampSyncedInt(key, value.toInt()));
          }
        } else if (_syncedDoubleKeys.contains(key)) {
          if (value is num) {
            await _prefs.setDouble(
                key, _clampSyncedDouble(key, value.toDouble()));
          }
        } else if (_syncedStringKeys.contains(key)) {
          if (value is String) {
            // Strip C0/C1 control + Unicode bidi/format chars BEFORE storing:
            // a synced blob is attacker-influenced (a hostile sync server /
            // WebDAV endpoint), and values like `default_username` flow into
            // the live SSH username + connection logs/dialogs, where an RTL
            // override or embedded newline would enable the same UI/log
            // spoofing the app strips everywhere else. Then length-cap.
            final sanitized = value.replaceAll(_syncedStringUnsafe, '');
            final capped = sanitized.length > _maxSyncedStringLen
                ? sanitized.substring(0, _maxSyncedStringLen)
                : sanitized;
            await _prefs.setString(key, capped);
          }
        } else if (_syncedStringListKeys.contains(key)) {
          if (value is List) {
            final list = value
                .whereType<String>()
                .where((s) => s.length <= _maxSyncedListItemLen)
                .take(_maxSyncedListItems)
                .toList();
            await _prefs.setStringList(key, list);
          }
        }
      } catch (e) {
        AppLogger.warning('Failed to import synced setting "$key": $e');
      }
    }
  }

  int _clampSyncedInt(String key, int v) {
    switch (key) {
      case 'default_port':
        return v.clamp(1, 65535);
      case 'connection_timeout':
        return v.clamp(1, 600);
      case 'keepalive_interval':
        return v.clamp(0, 3600);
      case 'scrollback_lines':
        return v.clamp(0, 5000000);
      default:
        return v;
    }
  }

  double _clampSyncedDouble(String key, double v) {
    switch (key) {
      case 'terminal_font_size':
        return v.clamp(6.0, 48.0);
      case 'terminal_margin':
        return v.clamp(0.0, 200.0);
      default:
        return v;
    }
  }
}

/// The most lines a terminal keeps: what "unlimited" scrollback (0) means.
const int kScrollbackMostLines = 1000000;

/// The lines a terminal keeps for the scrollback setting [setting]: 0 (or
/// less) is "unlimited", [kScrollbackMostLines], and so is any larger number.
/// A phone's dialog takes any whole number; a terminal asked for more than
/// this was given it (found in a code audit).
int terminalScrollbackLines(int setting) =>
    setting <= 0 || setting > kScrollbackMostLines ? kScrollbackMostLines : setting;

/// What ZestSSH's lock screen says of the sessions still connected behind it.
enum LockSessionsShown { off, count, names }
