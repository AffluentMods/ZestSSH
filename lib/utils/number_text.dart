import 'package:intl/intl.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';

/// [value] as the app's language writes it, with exactly [digits] decimals:
/// "0.52" in English, "0,52" in German and French. Every number the app shows
/// goes through here or [formatByteSize]; `toStringAsFixed` writes a decimal
/// point in every language. [l10n] is the
/// language (the app's current one when left out); [locale] wins over it, for
/// tests.
///
/// Not for what a machine reads back (logs, files, a field parsed with
/// `double.parse`): those keep the point.
String formatDecimal(num value, {int digits = 1, AppLocalizations? l10n, String? locale}) =>
    _format(locale ?? (l10n ?? gl10n).localeName, (l) => NumberFormat.decimalPatternDigits(locale: l, decimalDigits: digits))
        .format(value);

/// [value] with at most [maxDigits] decimals and no trailing zeros: "14" for
/// 14.0 and "14.5" ("14,5" in German) for 14.5.
String formatDecimalUpTo(num value, {int maxDigits = 1, AppLocalizations? l10n, String? locale}) =>
    _format(locale ?? (l10n ?? gl10n).localeName, (l) {
      return NumberFormat.decimalPattern(l)
        ..minimumFractionDigits = 0
        ..maximumFractionDigits = maxDigits;
    }).format(value);

/// A percentage written as the app has always drawn it, the number then "%"
/// with no space ("92%"), the number in the language's own digits and
/// grouping. [value] is already out of 100.
String formatPercentNumber(num value, {int digits = 0, AppLocalizations? l10n, String? locale}) =>
    '${formatDecimal(value, digits: digits, l10n: l10n, locale: locale)}%';

/// The format in [locale], or in the default one where intl has no symbols
/// for it (it has them for all twelve of the app's languages).
NumberFormat _format(String locale, NumberFormat Function(String locale) make) {
  try {
    return make(locale);
  } catch (_) {
    return make(Intl.defaultLocale ?? 'en');
  }
}
