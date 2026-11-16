import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A clipboard history manager that tracks recently copied text snippets.
///
/// Stores up to [maxEntries] clipboard items in memory for quick re-paste
/// in the terminal. Items are ordered newest-first.
class ClipboardManager extends StateNotifier<List<ClipboardEntry>> {
  static const maxEntries = 20;

  ClipboardManager() : super([]);

  /// Add a new clipboard entry. Deduplicates - if the same text exists,
  /// it's moved to the top.
  void add(String text) {
    if (text.trim().isEmpty) return;

    final existing = state.indexWhere((e) => e.text == text);
    final entry = ClipboardEntry(
      text: text,
      copiedAt: DateTime.now(),
    );

    if (existing >= 0) {
      // Move to top
      final updated = [entry, ...state]..removeAt(existing + 1);
      state = updated;
    } else {
      state = [entry, ...state];
      if (state.length > maxEntries) {
        state = state.sublist(0, maxEntries);
      }
    }
  }

  /// Remove a specific entry.
  void remove(int index) {
    if (index >= 0 && index < state.length) {
      state = [...state]..removeAt(index);
    }
  }

  /// Clear all history.
  void clear() {
    state = [];
  }
}

class ClipboardEntry {
  final String text;
  final DateTime copiedAt;

  const ClipboardEntry({required this.text, required this.copiedAt});
}

/// Provider for the clipboard history manager.
final clipboardManagerProvider =
    StateNotifierProvider<ClipboardManager, List<ClipboardEntry>>(
  (ref) => ClipboardManager(),
);
