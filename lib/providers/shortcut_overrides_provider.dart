import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/providers/core_providers.dart';

/// SharedPreferences key holding user overrides as JSON.
const _prefsKey = 'shortcut_overrides';

/// State exposed by [shortcutBindingsProvider].
class ShortcutBindings {
  ShortcutBindings(this._overrides);

  /// The bindings kept in [prefs]: read so by [shortcutBindingsProvider], and
  /// by a computer's terminal in a window of its own, which has no provider.
  factory ShortcutBindings.fromPrefs(SharedPreferences prefs) => ShortcutBindings.fromRaw(prefs.getString(_prefsKey));

  /// The bindings as they are kept, for a window of its own, which is handed
  /// them by the main window ([keptOverrides]).
  factory ShortcutBindings.fromRaw(String? raw) {
    if (raw == null || raw.isEmpty) {
      return ShortcutBindings(<ShortcutAction, ShortcutKey>{});
    }
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final overrides = <ShortcutAction, ShortcutKey>{};
      for (final entry in decoded.entries) {
        final action = _actionByName(entry.key);
        if (action == null) continue; // forward-compat: unknown action
        final key = ShortcutKey.fromJson(entry.value as Map<String, dynamic>);
        if (key != null) overrides[action] = key;
      }
      return ShortcutBindings(overrides);
    } catch (_) {
      // Corrupt prefs - start fresh rather than crashing.
      return ShortcutBindings(<ShortcutAction, ShortcutKey>{});
    }
  }

  /// User-specified overrides. An action without an entry in this
  /// map uses the default from [defaultShortcutBindings].
  final Map<ShortcutAction, ShortcutKey> _overrides;

  /// The effective binding for [action] - override > default.
  /// Returns null when the user has explicitly UNBOUND the action
  /// (sentinel: `keyId == 0`), and when the default's key is one the person
  /// gave another action: a key of their own wins over a default that came
  /// after it (F1, the Support Hub's since 3.3, on someone who had it already).
  ShortcutKey? bindingFor(ShortcutAction action) {
    final override = _overrides[action];
    if (override != null) {
      if (override.keyId == 0) return null; // explicit unbind
      return override;
    }
    final byDefault = defaultShortcutBindings[action];
    if (byDefault != null && _overrides.values.contains(byDefault)) return null;
    return byDefault;
  }

  /// True if [event] matches the binding for [action].
  bool matches(KeyEvent event, ShortcutAction action) {
    if (event is! KeyDownEvent) return false;
    final binding = bindingFor(action);
    if (binding == null) return false;
    return binding.matches(event);
  }

  /// Find every action that conflicts (i.e. shares the same binding)
  /// with [target]. Used by the rebind UI to warn the user before
  /// they overwrite a binding that another action depends on.
  List<ShortcutAction> conflicts(ShortcutKey newBinding,
      {ShortcutAction? excluding}) {
    final out = <ShortcutAction>[];
    for (final a in ShortcutAction.values) {
      if (a == excluding) continue;
      if (bindingFor(a) == newBinding) out.add(a);
    }
    return out;
  }

  /// True if the action has a user override (vs. using the default).
  bool isCustomised(ShortcutAction action) => _overrides.containsKey(action);

  /// Snapshot of overrides - used by serialisation and the settings
  /// page. Never mutate the returned map.
  Map<ShortcutAction, ShortcutKey> get overrides =>
      Map.unmodifiable(_overrides);
}

/// Riverpod surface for shortcut bindings. Reads on init from
/// SharedPreferences; writes on every set / clear.
final shortcutBindingsProvider =
    NotifierProvider<ShortcutBindingsNotifier, ShortcutBindings>(
  ShortcutBindingsNotifier.new,
);

/// The clean, render-time API every display site should use to show a
/// shortcut hint.
///
/// Returns the formatted, platform-correct label for [action]'s current
/// binding, or `null` when the action has been unbound. `null` means
/// "render nothing" - never a stale default and never the word "None":
///
/// ```dart
/// final combo = ref.watch(shortcutBindingProvider(ShortcutAction.closeTab));
/// if (combo != null) Kbd(combo); // else: show nothing
/// ```
///
/// Because it `watch`es [shortcutBindingsProvider], any surface that reads
/// it re-renders the instant the user changes a binding in Settings - no
/// restart, no reconnect. This is the single entry point other features
/// (tab context menu, context menus, launch pills, tooltips) should call.
final shortcutBindingProvider =
    Provider.family<String?, ShortcutAction>((ref, action) {
  final key = ref.watch(shortcutBindingsProvider).bindingFor(action);
  return key == null ? null : formatShortcutKey(key);
});

class ShortcutBindingsNotifier extends Notifier<ShortcutBindings> {
  @override
  ShortcutBindings build() =>
      ShortcutBindings.fromPrefs(ref.read(sharedPreferencesProvider));

  Future<void> _persist(Map<ShortcutAction, ShortcutKey> overrides) async {
    final prefs = ref.read(sharedPreferencesProvider);
    if (overrides.isEmpty) {
      await prefs.remove(_prefsKey);
    } else {
      final encoded = <String, dynamic>{
        for (final entry in overrides.entries)
          entry.key.name: entry.value.toJson(),
      };
      await prefs.setString(_prefsKey, jsonEncode(encoded));
    }
    // `shortcut_overrides` is a synced setting: nudge the sync engine so a
    // rebind travels to the user's other devices (debounced; no-op without
    // Cloud Sync). Best-effort ONLY: the rebind is already persisted above, and
    // the sync engine reaches the encrypted DB - which may be closed (app
    // locked / vault engaged). A closed DB must never fail a settings write, so
    // swallow it; the change still syncs on the next successful nudge.
    try {
      ref.read(autoSyncServiceProvider).notifyLocalChange();
    } catch (_) {
      // Sync unavailable (e.g. DB closed behind the vault lock) - ignore.
    }
  }

  /// Set [action] to [binding]. Writing the same value as the
  /// default removes the override (so the prefs stay clean).
  Future<void> setBinding(
      ShortcutAction action, ShortcutKey binding) async {
    final next = Map<ShortcutAction, ShortcutKey>.from(state.overrides);
    final defaultBinding = defaultShortcutBindings[action];
    if (binding == defaultBinding) {
      next.remove(action);
    } else {
      next[action] = binding;
    }
    state = ShortcutBindings(next);
    await _persist(next);
  }

  /// Mark [action] as explicitly unbound. The dispatcher then never
  /// fires for this action, regardless of what the default would do.
  Future<void> unbind(ShortcutAction action) async {
    final next = Map<ShortcutAction, ShortcutKey>.from(state.overrides);
    next[action] = const ShortcutKey(keyId: 0); // sentinel
    state = ShortcutBindings(next);
    await _persist(next);
  }

  /// Reset a single action to its default.
  Future<void> resetBinding(ShortcutAction action) async {
    final next = Map<ShortcutAction, ShortcutKey>.from(state.overrides);
    next.remove(action);
    state = ShortcutBindings(next);
    await _persist(next);
  }

  /// Reset every action to its default in one shot.
  Future<void> resetAll() async {
    state = ShortcutBindings(<ShortcutAction, ShortcutKey>{});
    await _persist(<ShortcutAction, ShortcutKey>{});
  }
}

/// Lookup helper: name string → enum value. Tolerates unknown names
/// (returns null) so prefs from a future build don't blow up an
/// older one.
ShortcutAction? _actionByName(String name) {
  for (final a in ShortcutAction.values) {
    if (a.name == name) return a;
  }
  return null;
}
