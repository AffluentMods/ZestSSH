import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';

/// SFTP's file times are said in the app's language (found in a
/// review): they were formatted with no locale, so every language read
/// "2:30 PM" and the US date order.
void main() {
  final at = DateTime(2026, 9, 24, 14, 30);

  setUpAll(() async {
    await initializeDateFormatting('de');
    await initializeDateFormatting('ja');
  });
  tearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  test('the short date and AM / PM follow the language the app is in', () {
    expect(SftpTimeFormat.h12.time(at), '2:30 PM');
    expect(SftpTimeFormat.h24.localeDateTime(at), '9/24/2026 14:30');
    L10nGlobal.update(lookupAppLocalizations(const Locale('de')));
    expect(SftpTimeFormat.h24.localeDateTime(at), '24.9.2026 14:30');
    L10nGlobal.update(lookupAppLocalizations(const Locale('ja')));
    expect(SftpTimeFormat.h12.time(at), isNot(contains('PM')));
    expect(SftpTimeFormat.h24.dateTime(at), '2026-09-24 14:30', reason: 'the column keeps its sortable form');
  });

  test('a language can be given', () {
    expect(SftpTimeFormat.h24.localeDateTime(at, 'de'), '24.9.2026 14:30');
  });
}
