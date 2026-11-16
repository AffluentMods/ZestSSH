// Remote screens (4.0): whether a phone's floating bar over a
// remote screen stays shown (Keep the bar shown, in the session panel)
// instead of hiding itself. A layout of this device: kept on it, not synced,
// and put back by Reset all settings.
import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart' show sharedPreferencesProvider;

/// The key in SharedPreferences.
const kScreenBarKeptKey = 'screen_bar_kept';

final screenBarKeptProvider = NotifierProvider<ScreenBarKeptNotifier, bool>(ScreenBarKeptNotifier.new);

class ScreenBarKeptNotifier extends Notifier<bool> {
  @override
  bool build() => ref.watch(sharedPreferencesProvider).getBool(kScreenBarKeptKey) ?? false;

  void set({required bool kept}) {
    state = kept;
    unawaited(ref.read(sharedPreferencesProvider).setBool(kScreenBarKeptKey, kept));
  }
}
