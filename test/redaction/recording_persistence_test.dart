import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/services/settings_service.dart';

/// Recording mode never turns itself off (spec 7c): the flag, its level and
/// the install's mask salt survive a "reset all settings", and the salt is
/// generated exactly once.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a settings reset keeps recording mode, its level and the mask salt',
      () async {
    SharedPreferences.setMockInitialValues({
      'recording_mode_enabled': true,
      'recording_redact_level': 'strict',
      'recording_mask_salt': 'abc123',
      'terminal_font_size': 18.0,
      'bell_enabled': false,
    });
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);
    await settings.resetAllToDefaults();
    expect(settings.recordingModeEnabled, isTrue);
    expect(settings.recordingRedactLevel, 'strict');
    expect(settings.recordingMaskSalt, 'abc123');
    expect(settings.terminalFontSize, 14.0,
        reason: 'everything else is back to its default');
    expect(settings.bellEnabled, isTrue);
  });

  test('the mask salt is generated once and is then stable', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final settings = SettingsService(prefs);
    final first = settings.recordingMaskSalt;
    expect(first, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(settings.recordingMaskSalt, first);
    expect(prefs.getString('recording_mask_salt'), first);
  });
}
