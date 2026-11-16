import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// History suggestions show only while history is a feature here (Squeezed),
/// kept on this device, switched on, and the screen is not being recorded.

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  Future<ProviderContainer> container({
    bool pro = true,
    bool history = true,
    bool? suggestions,
    bool recording = false,
  }) async {
    SharedPreferences.setMockInitialValues({
      'command_history_enabled': history,
      'command_history_suggestions': ?suggestions,
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      recordingModeProvider.overrideWith((ref) => recording),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  test('on by default where history is kept', () async {
    expect((await container()).read(historySuggestionsActiveProvider), isTrue);
  });

  test('off without Squeezed, without history, when switched off, and while recording', () async {
    expect((await container(pro: false)).read(historySuggestionsActiveProvider), isFalse);
    expect((await container(history: false)).read(historySuggestionsActiveProvider), isFalse);
    expect((await container(suggestions: false)).read(historySuggestionsActiveProvider), isFalse);
    expect((await container(recording: true)).read(historySuggestionsActiveProvider), isFalse);
  });

  test('follows the switches as they change', () async {
    final c = await container();
    expect(c.read(historySuggestionsActiveProvider), isTrue);
    c.read(recordingModeProvider.notifier).state = true;
    expect(c.read(historySuggestionsActiveProvider), isFalse, reason: 'recording started');
    c.read(recordingModeProvider.notifier).state = false;
    expect(c.read(historySuggestionsActiveProvider), isTrue);
    await c.read(historySuggestionsProvider.notifier).set(false);
    expect(c.read(historySuggestionsActiveProvider), isFalse, reason: 'switched off');
  });
}
