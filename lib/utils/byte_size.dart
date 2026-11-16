import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// How many decimals a size shows.
enum SizeDigits {
  /// One from KB up: "1.5 MB", "12.0 MB".
  one,

  /// One, and two from GB up: "1.25 GB".
  oneThenTwo,

  /// One below 10, none from 10: "1.5 GB", "234 GB".
  belowTen,

  /// One below 100, none from 100: "23.5 GB", "234 GB".
  belowHundred,
}

/// A size in bytes as the app's language writes it: the number with the
/// language's own decimal mark ("1,5" in German), and the unit as the
/// language writes it ("Mo" in French, "МБ" in Russian). Powers of 1024, as
/// the app has always counted. (3.0: every screen wrote "1.5 MB"
/// its own way, in English.)
String formatByteSize(int bytes, {SizeDigits digits = SizeDigits.one, AppLocalizations? l10n}) {
  final t = l10n ?? gl10n;
  if (bytes < 1024) return t.sizeBytes(_number(t, bytes.toDouble(), 0));
  var value = bytes / 1024;
  var unit = 0; // 0 KB, 1 MB, 2 GB, 3 TB
  while (value >= 1024 && unit < 3) {
    value /= 1024;
    unit++;
  }
  final decimals = switch (digits) {
    SizeDigits.one => 1,
    SizeDigits.oneThenTwo => unit >= 2 ? 2 : 1,
    SizeDigits.belowTen => value >= 10 ? 0 : 1,
    SizeDigits.belowHundred => value >= 100 ? 0 : 1,
  };
  final number = _number(t, value, decimals);
  return switch (unit) {
    0 => t.sizeKilobytes(number),
    1 => t.sizeMegabytes(number),
    2 => t.sizeGigabytes(number),
    _ => t.sizeTerabytes(number),
  };
}

/// A rate, so many bytes a second, the same way: "2.3 MB/s".
String formatByteRate(num bytesPerSecond, {SizeDigits digits = SizeDigits.one, AppLocalizations? l10n}) {
  final t = l10n ?? gl10n;
  return t.sizePerSecond(formatByteSize(bytesPerSecond.round(), digits: digits, l10n: t));
}

String _number(AppLocalizations t, double value, int decimals) =>
    NumberFormat.decimalPatternDigits(locale: t.localeName, decimalDigits: decimals).format(value);
