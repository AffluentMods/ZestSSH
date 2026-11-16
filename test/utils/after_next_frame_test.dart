import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';
import 'package:zestssh/utils/after_next_frame.dart';

/// Work put after the next frame from outside a frame (a timer, a stream, a
/// provider's listener, the tray, the system) asks for that frame: with no
/// status bar ticking once a second any more, a
/// plain post-frame callback waited until the mouse moved.
void main() {
  /// A second goes by with no frame drawn: is one asked for?
  Future<bool> frameAskedWithin(WidgetTester tester) async {
    await tester.binding.delayed(const Duration(milliseconds: 300));
    return tester.binding.hasScheduledFrame;
  }

  testWidgets('from a timer: a plain post-frame callback waits, afterNextFrame asks for its frame', (tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    var plain = false;
    Timer(const Duration(milliseconds: 10), () => WidgetsBinding.instance.addPostFrameCallback((_) => plain = true));
    expect(await frameAskedWithin(tester), isFalse, reason: 'nothing asks for a frame: it would wait');
    await tester.pump();
    expect(plain, isFalse, reason: 'with no frame asked for, none is drawn and it still waits');
    tester.binding.scheduleFrame();
    await tester.pump();
    expect(plain, isTrue, reason: 'the next frame runs it');

    var ran = false;
    Timer(const Duration(milliseconds: 10), () => afterNextFrame((_) => ran = true));
    expect(await frameAskedWithin(tester), isTrue);
    await tester.pump();
    expect(ran, isTrue);
  });

  // Looked at and not a case: its listener is the view's own, and a frame
  // follows the change (kept as the check that it does).
  testWidgets("a jump asked of the open Settings from elsewhere (its provider's listener) gets its frame",
      (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({kSettingsLastSectionKey: 'terminal'});
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = const Size(1100, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SettingsInlineView()),
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(seconds: 1));
    c.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.security;
    expect(await frameAskedWithin(tester), isTrue, reason: 'the jump waited for a frame nothing asked for');
    await tester.pump();
    expect(c.read(settingsJumpProvider), isNull, reason: 'taken');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  testWidgets('the quick connect field asked for the keyboard from elsewhere asks for its frame', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: QuickConnectBar()),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    quickConnectFocusWanted.value = true;
    expect(await frameAskedWithin(tester), isTrue);
    await tester.pump();
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: 'the field has the keyboard');
    await tester.pumpWidget(const SizedBox());
  });

  test('the post-frame work started off a frame asks for its frame', () {
    // Each reached from a timer, a stream, a future, a listener, the tray or
    // the system, with nothing else drawing (the list of a review's
    // follow-up): each uses afterNextFrame.
    const sites = {
      'lib/app.dart': ['didChangeAppLifecycleState', '_runStartupTasks', '_handleDeepLinks'],
      'lib/main.dart': ["case 'reattachSession'"],
      'lib/ui/screens/desktop/desktop_shell.dart': [
        'onQuickConnect = ',
        'onConnectHost = ',
        'Future<void> _restoreSavedSessions',
        'void _checkLastUpdate',
        'void _pushTrayHealth',
        'void _selectSessionTab',
      ],
      'lib/ui/screens/home/widgets/quick_connect_bar.dart': ['void _takeFocusAsk'],
      'lib/ui/screens/identity/identity_edit_screen.dart': ['onKeyLoaded: (privatePem, fingerprint, keyType, [passphrase]) {'],
    };
    for (final MapEntry(key: path, value: starts) in sites.entries) {
      final text = File(path).readAsStringSync().replaceAll('\r\n', '\n');
      for (final start in starts) {
        final at = text.indexOf(start);
        expect(at, greaterThanOrEqualTo(0), reason: '$path: $start');
        final after = text.substring(at);
        final next = after.indexOf(RegExp(r'afterNextFrame\(|addPostFrameCallback\('));
        expect(next, greaterThan(0), reason: '$path: $start');
        expect(after.substring(next).startsWith('afterNextFrame('), isTrue, reason: '$path: $start waits for a frame nothing asks for');
      }
    }
  });
}
