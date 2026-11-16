import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/l10n/time_text.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/ui/screens/sync/sync_pause.dart';

/// intl 0.20.3 (CLDR 48, Flutter 3.50) writes a narrow no-break space (U+202F) before AM and
/// PM; the app writes every time with a plain space (lib/l10n/time_text.dart).
void main() {
  setUpAll(() => initializeDateFormatting());

  final afternoon = DateTime(2026, 11, 13, 15, 30);

  test('intl itself writes the narrow space, which is why the app needs this', () {
    expect(DateFormat.jm('en').format(afternoon), '3:30${narrowNoBreakSpace}PM');
  });

  test('formatPlain writes a plain space, the rest as intl writes it', () {
    expect(DateFormat.jm('en').formatPlain(afternoon), '3:30 PM');
    expect(DateFormat.yMMMd('en').add_jm().formatPlain(afternoon), 'Nov 13, 2026 3:30 PM');
    expect(DateFormat.Hm('de').formatPlain(afternoon), '15:30');
  });

  test('in no language the app speaks does a time keep a narrow space', () {
    for (final locale in ['ar', 'de', 'en', 'es', 'fr', 'hi', 'it', 'ja', 'ko', 'pt', 'ru', 'zh']) {
      for (final format in [DateFormat.jm(locale), DateFormat.MMMd(locale).add_jm(), DateFormat.Hms(locale)]) {
        expect(format.formatPlain(afternoon), isNot(contains(narrowNoBreakSpace)), reason: locale);
      }
    }
  });

  test('plainTimeSpaces is for a sentence that formats its own time', () {
    expect(plainTimeSpaces('Started 3:30${narrowNoBreakSpace}PM'), 'Started 3:30 PM');
    expect(plainTimeSpaces('no time here'), 'no time here');
  });

  test("the app's own time lines go through it", () {
    expect(syncPausedUntilText(afternoon, 'en', now: DateTime(2026, 11, 13, 9)), '3:30 PM');
    expect(SftpTimeFormat.h12.time(afternoon), '3:30 PM');
  });
}
