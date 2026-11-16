// The app's haptic feedback, as Settings says (found while
// comparing the five versions): Settings has a "Haptic feedback" switch, and
// nothing read it; every tap that buzzes (the keys above a phone's keyboard,
// a long press, a wrong passcode) buzzed with it off.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';
import 'package:zestssh/ui/widgets/haptics.dart';

void main() {
  late List<String?> buzzes;

  setUp(() {
    buzzes = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
        (call) async {
      if (call.method == 'HapticFeedback.vibrate') buzzes.add(call.arguments as String?);
      return null;
    });
  });

  tearDown(() =>
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  Future<ProviderContainer> app(WidgetTester tester, Widget child, {required bool on}) async {
    SharedPreferences.setMockInitialValues({'haptic_feedback': on});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: Align(alignment: Alignment.bottomCenter, child: child)),
      ),
    ));
    await tester.pump();
    return container;
  }

  testWidgets('each kind of buzz while the switch is on, and none once it is off', (tester) async {
    late WidgetRef ref;
    final container = await app(tester, Consumer(builder: (_, r, _) {
      ref = r;
      return const SizedBox();
    }), on: true);
    for (final kind in Haptic.values) {
      haptic(ref, kind);
    }
    expect(buzzes, [
      'HapticFeedbackType.lightImpact',
      'HapticFeedbackType.mediumImpact',
      'HapticFeedbackType.heavyImpact',
      'HapticFeedbackType.selectionClick',
    ]);

    buzzes.clear();
    await container.read(settingsUpdaterProvider).setHapticFeedback(false);
    for (final kind in Haptic.values) {
      haptic(ref, kind);
    }
    expect(buzzes, isEmpty);
  });

  for (final on in [true, false]) {
    testWidgets("a key above a phone's keyboard buzzes ${on ? 'with the switch on' : 'not with it off'}",
        (tester) async {
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final typed = <String>[];
      await app(tester, TerminalSoftKeyboard(onKey: typed.add), on: on);
      await tester.tap(find.text('TAB'));
      await tester.pump(const Duration(milliseconds: 500));
      expect(typed, ['\t']);
      expect(buzzes, on ? ['HapticFeedbackType.lightImpact'] : isEmpty);
    });
  }

  test("every buzz of the app goes through the switch: none called around it (a terminal's bell has its own)", () {
    final calling = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll(r'\', '/');
      if (!path.endsWith('.dart') || path.contains('/l10n/generated/')) continue;
      if (path.endsWith('lib/ui/widgets/haptics.dart')) continue;
      final text = file.readAsStringSync();
      final at = RegExp(r'HapticFeedback\.\w+\(').allMatches(text).length;
      if (at == 0) continue;
      calling.add('$path: $at');
    }
    expect(calling, ['lib/providers/terminal_providers.dart: 1'], reason: 'the bell, on its own switch');
  });
}
