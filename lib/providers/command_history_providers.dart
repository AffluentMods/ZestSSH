import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// Whether command history is being recorded on this device. OPT-IN: default
/// OFF, so recording only happens after the user turns it on. Device-local: a
/// per-device privacy switch, not a synced setting. Read on the hot input path,
/// so it's a cached StateNotifier rather than an async prefs read.
class CommandHistoryEnabledNotifier extends StateNotifier<bool> {
  CommandHistoryEnabledNotifier(this._prefs)
      : super(_prefs.getBool(_key) ?? false);

  static const _key = 'command_history_enabled';
  final SharedPreferences _prefs;

  Future<void> set(bool value) async {
    state = value;
    await _prefs.setBool(_key, value);
  }
}

final commandHistoryEnabledProvider =
    StateNotifierProvider<CommandHistoryEnabledNotifier, bool>((ref) {
  return CommandHistoryEnabledNotifier(ref.watch(sharedPreferencesProvider));
});

/// Whether to ALSO record commands whose arguments look like they carry a secret
/// (e.g. `mysql -psecret`, `export TOKEN=...`). OPT-IN within opt-in: default
/// OFF, and only meaningful when recording is enabled. This never affects the
/// echo check: a password typed at a hidden prompt (echo off) is never captured
/// regardless of this switch. Device-local.
class CommandHistoryIncludeSensitiveNotifier extends StateNotifier<bool> {
  CommandHistoryIncludeSensitiveNotifier(this._prefs)
      : super(_prefs.getBool(_key) ?? false);

  static const _key = 'command_history_include_sensitive';
  final SharedPreferences _prefs;

  Future<void> set(bool value) async {
    state = value;
    await _prefs.setBool(_key, value);
  }
}

final commandHistoryIncludeSensitiveProvider =
    StateNotifierProvider<CommandHistoryIncludeSensitiveNotifier, bool>((ref) {
  return CommandHistoryIncludeSensitiveNotifier(
      ref.watch(sharedPreferencesProvider));
});

/// Whether the terminal suggests, as someone types, the newest matching
/// command from their history (3.0). On by default, where history is kept;
/// device-local. Read on the hot input path.
class HistorySuggestionsNotifier extends StateNotifier<bool> {
  HistorySuggestionsNotifier(this._prefs) : super(_prefs.getBool(_key) ?? true);

  static const _key = 'command_history_suggestions';
  final SharedPreferences _prefs;

  Future<void> set(bool value) async {
    state = value;
    await _prefs.setBool(_key, value);
  }
}

final historySuggestionsProvider = StateNotifierProvider<HistorySuggestionsNotifier, bool>((ref) {
  return HistorySuggestionsNotifier(ref.watch(sharedPreferencesProvider));
});

/// Whether history suggestions show now: history is a Squeezed feature and
/// kept on this device, suggestions are switched on, and the screen is not
/// being recorded (a recording never shows what someone ran before).
final historySuggestionsActiveProvider = Provider<bool>((ref) =>
    ref.watch(isProProvider) &&
    ref.watch(commandHistoryEnabledProvider) &&
    ref.watch(historySuggestionsProvider) &&
    !ref.watch(recordingModeProvider));

/// The most-recent history entries (drives the history screen's default view).
final recentCommandHistoryProvider =
    StreamProvider<List<CommandHistoryEntry>>((ref) {
  return ref.watch(commandHistoryDaoProvider).watchRecent();
});
