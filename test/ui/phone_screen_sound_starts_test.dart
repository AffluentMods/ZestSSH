import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zest_native/screen.dart';
import 'package:zest_native/screen_testing.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/phone/phone_screen_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';

import '../features/screens/view/screen_view_fixture.dart';

/// A phone's remote screen with the remote's sound: the view lets it play as
/// soon as it is seen (in front, not covered, not locked). It stayed silent
/// until the app left the screen and came back, or the lock or recording mode
/// changed: the view said the sound may play only on those changes, never as
/// it opened.
void main() {
  testWidgets('an RDP screen that plays sound, opened on a phone and seen: the engine is told to play', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final native = FakeScreenNative();
    final session = ScreenSession.open(const ScreenConnectOptions.rdp(sound: true, soundOn: false), native: native);
    final engine = native.sessions.single;
    engine.emitJson(ScreenEventKind.connected, {
      'protocol': 'rdp',
      'width': 800,
      'height': 500,
      'sound': {'rate': 48000, 'channels': 2},
    });
    await tester.pump();
    addTearDown(session.close);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(412, 915);
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: PhoneScreenView(
          sessionId: 's1',
          connectionId: 'c1',
          label: 'office pc',
          session: session,
          options: ScreenOptions.defaults,
          rdp: true,
          onBack: () {},
          onDisconnect: () {},
          decodeTile: syncDecode,
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(engine.sounds, [true], reason: 'seen and wanted: it plays without the app having to leave and come back');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
