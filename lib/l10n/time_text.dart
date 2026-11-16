import 'package:intl/intl.dart';

/// The narrow no-break space (U+202F) that intl 0.20.3 (CLDR 48, which Flutter 3.50's
/// localizations require) writes between a time and AM or PM ("3:30 PM"), where intl 0.20.2
/// wrote a plain space. The app's fonts (GeistSans, JetBrains Mono) have no glyph for it, so
/// it was drawn in the system's font, and a time copied or searched for held a character
/// nobody types.
const narrowNoBreakSpace = ' ';

/// [text] with intl's narrow no-break spaces made plain spaces: for a time the app did not
/// format through [PlainTimeFormat] (a translated sentence that formats its own, or Material's
/// formatTimeOfDay).
String plainTimeSpaces(String text) => text.replaceAll(narrowNoBreakSpace, ' ');

/// How the app writes every time of day: [DateFormat.format] with plain spaces.
extension PlainTimeFormat on DateFormat {
  /// [time] as this format writes it, with plain spaces ([plainTimeSpaces]).
  String formatPlain(DateTime time) => plainTimeSpaces(format(time));
}
