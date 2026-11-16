import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/providers/core_providers.dart';

/// SharedPreferences key. Single string blob - the settings object
/// is small (~7 fields) so a JSON-encoded string keeps the prefs
/// surface clean instead of one key per field.
const _prefsKey = 'host_card_settings';

/// Riverpod surface for [HostCardSettings].  Reads on init from
/// SharedPreferences, writes on every update.
final hostCardSettingsProvider =
    NotifierProvider<HostCardSettingsNotifier, HostCardSettings>(
  HostCardSettingsNotifier.new,
);

class HostCardSettingsNotifier extends Notifier<HostCardSettings> {
  @override
  HostCardSettings build() {
    final prefs = ref.read(sharedPreferencesProvider);
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) {
      return const HostCardSettings();
    }
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return const HostCardSettings();
      return HostCardSettings.fromJson(decoded);
    } catch (_) {
      // Corrupt blob - fall back to defaults so the app keeps booting.
      return const HostCardSettings();
    }
  }

  Future<void> _persist(HostCardSettings next) async {
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setString(_prefsKey, jsonEncode(next.toJson()));
  }

  Future<void> setDensity(HostCardDensity density) =>
      _persist(state.copyWith(density: density));

  Future<void> setColumns(HostCardColumns columns) =>
      _persist(state.copyWith(columns: columns));

  Future<void> setAccentMode(HostCardAccentMode accentMode) =>
      _persist(state.copyWith(accentMode: accentMode));

  Future<void> setShowStatusPill(bool v) =>
      _persist(state.copyWith(showStatusPill: v));

  Future<void> setShowOsIcon(bool v) =>
      _persist(state.copyWith(showOsIcon: v));

  Future<void> setShowSubtitle(bool v) =>
      _persist(state.copyWith(showSubtitle: v));

  Future<void> setShowHoverEdit(bool v) =>
      _persist(state.copyWith(showHoverEdit: v));

  Future<void> setShowTags(bool v) =>
      _persist(state.copyWith(showTags: v));

  Future<void> reset() async {
    final prefs = ref.read(sharedPreferencesProvider);
    state = const HostCardSettings();
    await prefs.remove(_prefsKey);
  }
}
