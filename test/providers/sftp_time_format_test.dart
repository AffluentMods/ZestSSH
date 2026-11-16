import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';

/// SFTP shows file times in 24-hour form unless the person picks 12-hour.
void main() {
  final afternoon = DateTime(2026, 9, 24, 14, 5);
  final morning = DateTime(2026, 9, 24, 9, 30);

  test('24-hour, the default', () {
    expect(SftpTimeFormat.h24.time(afternoon), '14:05');
    expect(SftpTimeFormat.h24.time(morning), '09:30');
    expect(SftpTimeFormat.h24.dateTime(afternoon), '2026-09-24 14:05');
  });

  test('12-hour with AM/PM', () {
    expect(SftpTimeFormat.h12.time(afternoon), '2:05 PM');
    expect(SftpTimeFormat.h12.time(morning), '9:30 AM');
    expect(SftpTimeFormat.h12.time(DateTime(2026, 9, 24, 0, 15)), '12:15 AM');
    expect(SftpTimeFormat.h12.dateTime(afternoon), '2026-09-24 2:05 PM');
  });

  test('the Properties sheet keeps the locale date and adds the time', () {
    expect(SftpTimeFormat.h24.localeDateTime(afternoon), '9/24/2026 14:05');
    expect(SftpTimeFormat.h12.localeDateTime(afternoon), '9/24/2026 2:05 PM');
  });

  group('the setting', () {
    Future<ProviderContainer> container(Map<String, Object> saved) async {
      SharedPreferences.setMockInitialValues(saved);
      final prefs = await SharedPreferences.getInstance();
      final c = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
      addTearDown(c.dispose);
      return c;
    }

    test('defaults to 24-hour, and an unknown value reads as 24-hour', () async {
      expect((await container({})).read(sftpTimeFormatProvider), SftpTimeFormat.h24);
      expect((await container({'sftp_time_format': 'x'})).read(sftpTimeFormatProvider),
          SftpTimeFormat.h24);
    });

    test('a choice is saved and read back', () async {
      final c = await container({});
      c.read(sftpTimeFormatProvider.notifier).set(SftpTimeFormat.h12);
      expect(c.read(sftpTimeFormatProvider), SftpTimeFormat.h12);
      final saved = await SharedPreferences.getInstance();
      expect(saved.getString('sftp_time_format'), 'h12');
      final again = ProviderContainer(
          overrides: [sharedPreferencesProvider.overrideWithValue(saved)]);
      addTearDown(again.dispose);
      expect(again.read(sftpTimeFormatProvider), SftpTimeFormat.h12);
    });
  });
}
