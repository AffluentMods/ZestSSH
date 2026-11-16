import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/settings/remote_screens_settings.dart';
import 'package:zestssh/ui/screens/settings/widgets/setting_control_tile.dart';

/// Settings, Remote screens (4.0): a phone's Touch or
/// Mouse pointer (Touch by default), the screen menu's key on a computer (F8
/// by default), a new screen's scaling (Fit), and recording mode covering
/// the picture (by default) or showing it. Each a preference that "Reset all
/// settings" puts back, the device's or the person's.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> container(Map<String, Object> values) async {
    SharedPreferences.setMockInitialValues(values);
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(c.dispose);
    return c;
  }

  test('the defaults: Touch, F8, Fit, cover; what is saved is read, and anything else is the default', () async {
    var c = await container({});
    expect(c.read(screenTouchDefaultProvider), ScreenTouchMode.touch);
    expect(c.read(screenMenuKeyProvider), ScreenMenuKey.f8);
    expect(c.read(screenScalingDefaultProvider), ScreenScaling.fit);
    expect(c.read(screenRecordingBehaviourProvider), ScreenRecordingBehaviour.cover);
    expect(c.read(screenClipboardDefaultProvider), isTrue, reason: "one's own hosts share the clipboard by default");

    c = await container({
      kScreenClipboardDefaultKey: 'off',
      kScreenTouchDefaultKey: 'mouse',
      kScreenMenuKeyKey: 'f11',
      kScreenScalingDefaultKey: 'oneToOne',
      kScreenRecordingKey: 'show',
    });
    expect(c.read(screenTouchDefaultProvider), ScreenTouchMode.mousePointer);
    expect(c.read(screenMenuKeyProvider), ScreenMenuKey.f11);
    expect(c.read(screenScalingDefaultProvider), ScreenScaling.oneToOne);
    expect(c.read(screenRecordingBehaviourProvider), ScreenRecordingBehaviour.show);
    expect(c.read(screenClipboardDefaultProvider), isFalse);

    c = await container({kScreenMenuKeyKey: 'f1', kScreenScalingDefaultKey: 'huge', kScreenRecordingKey: 'blur'});
    expect(c.read(screenMenuKeyProvider), ScreenMenuKey.f8);
    expect(c.read(screenScalingDefaultProvider), ScreenScaling.fit);
    expect(c.read(screenRecordingBehaviourProvider), ScreenRecordingBehaviour.cover);
  });

  test('covered only with recording mode on, Settings saying cover, and not shown for the session', () {
    for (final (recording, behaviour, shown, covered) in [
      (true, ScreenRecordingBehaviour.cover, false, true),
      (true, ScreenRecordingBehaviour.cover, true, false),
      (true, ScreenRecordingBehaviour.show, false, false),
      (false, ScreenRecordingBehaviour.cover, false, false),
    ]) {
      expect(screenCoveredWhileRecording(recording: recording, behaviour: behaviour, shown: shown), covered);
    }
  });

  test('each is put back by Reset all settings; a finger, a keyboard and recording mode are the device\'s, a new '
      'screen\'s scaling the person\'s', () {
    for (final key in [
      kScreenTouchDefaultKey,
      kScreenMenuKeyKey,
      kScreenScalingDefaultKey,
      kScreenRecordingKey,
      kScreenClipboardDefaultKey,
      kScreenDisplayStripKey,
    ]) {
      expect(SettingsService.isResetKey(key), isTrue, reason: key);
    }
    expect(SettingsService.isResetKey('screen_clipboard.host-1'), isTrue);
    expect(SettingsService.isProfileKey(kScreenClipboardDefaultKey), isTrue, reason: "the person's, as their scaling");
    expect(SettingsService.isResetKey('screen_touch.host-1'), isTrue);
    for (final key in [
      kScreenTouchDefaultKey,
      kScreenMenuKeyKey,
      kScreenRecordingKey,
      kScreenDisplayStripKey,
      'screen_touch.host-1',
    ]) {
      expect(SettingsService.isProfileKey(key), isFalse, reason: key);
    }
    expect(SettingsService.isProfileKey(kScreenScalingDefaultKey), isTrue);
  });

  test('the menu keys as the remote takes them: F8 to F12', () {
    expect([for (final k in ScreenMenuKey.values) k.label], ['F8', 'F9', 'F10', 'F11', 'F12']);
    expect(ScreenMenuKey.f9.key.keysym, 0xffc6);
  });

  testWidgets("a phone's page: the three rows with their defaults, and a pick kept", (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (context, state) => const RemoteScreensSettingsScreen())]);
    addTearDown(router.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp.router(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text(en.settingsScreensSection), findsWidgets);
    expect(find.text(en.settingsScreenTouchDefault), findsOneWidget);
    expect(find.text(en.settingsScreenScalingDefault), findsOneWidget);
    expect(find.text(en.settingsScreenRecording), findsOneWidget);
    expect(find.text(en.settingsScreenClipboardDefault), findsOneWidget);
    expect(find.text(en.settingsScreenMenuKey), findsNothing, reason: "a computer's key");
    Finder field(String key) =>
        find.descendant(of: find.byKey(ValueKey(key)), matching: find.byKey(const ValueKey('setting-choice-field')));
    expect(find.descendant(of: field('screen-settings-touch'), matching: find.text(en.settingsScreenTouchModeTouch)),
        findsOneWidget);
    expect(find.descendant(of: field('screen-settings-scaling'), matching: find.text(en.connectionEditScreenScalingFit)),
        findsOneWidget);
    expect(find.descendant(of: field('screen-settings-recording'), matching: find.text(en.settingsScreenRecordingCover)),
        findsOneWidget);
    expect(find.byType(SettingChoiceTile<ScreenTouchMode>), findsOneWidget);

    await tester.tap(field('screen-settings-touch'));
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
        of: find.byKey(const ValueKey('zest-sheet')), matching: find.text(en.settingsScreenTouchModeMouse)));
    await tester.pumpAndSettle();
    expect(prefs.getString(kScreenTouchDefaultKey), 'mouse');
    final clipboard = find.byKey(const ValueKey('screen-settings-clipboard'));
    expect(tester.widget<SwitchListTile>(clipboard).value, isTrue);
    await tester.ensureVisible(clipboard);
    await tester.tap(clipboard);
    await tester.pumpAndSettle();
    expect(prefs.getString(kScreenClipboardDefaultKey), 'off');
    expect(tester.widget<SwitchListTile>(clipboard).value, isFalse);
    expect(find.descendant(of: field('screen-settings-touch'), matching: find.text(en.settingsScreenTouchModeMouse)),
        findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });
}
