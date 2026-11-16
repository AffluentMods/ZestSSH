import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/dart_calls.dart';

// When something was is said in one place, lib/l10n/time_ago.dart (3.0):
// each screen with time words of its own said them its own
// way, in English on some and with a capital inside a sentence on others.
// How long is left and how long something lasted are said there too, in one
// compact style ("4m ago", "2h ago", "1h
// 59m left"), as a design review found "2 mins ago",
// "4m ago", "1 h 59 min left" and "2h" side by side. A screen here may keep
// its own only for a reason this list names.
const _allowed = <String, String>{};

final _timeWords = RegExp(r'\.(timeSecondsAgo|timeMinutesAgo|timeHoursAgo|timeDaysAgo|timeWeeksAgo|timeMonthsAgo|'
    r'timeLeft\w+|duration(?:Seconds|Minutes|MinutesSeconds|HoursMinutes|DaysHours)|'
    r'notificationsRelativeMinutes|notificationsRelativeHours|'
    r'notificationsRelativeDays|'
    r'(?:schedTask|cmdh|workflowList|identityList|homeLastUsed|desktopHome|welcomeHome|connectionCard)'
    r'(?:MinutesAgo|HoursAgo|DaysAgo|WeeksAgo|MonthsAgo)|settingsInline(?:MinAgo|HoursAgoShort|DaysAgoShort)|'
    r'accessLeft(?:Days|Hours|Minutes)|sftpEta\w+|connectionCardDuration\w+|sessionInfoUptime\w+|'
    r'homeConnected(?:Minutes|HoursMinutes|DaysHours))\(');

void main() {
  test('no screen keeps time words of its own but those this test names, and each of those still does', () {
    final found = <String, List<int>>{};
    for (final f in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = f.path.replaceAll(String.fromCharCode(92), '/');
      if (!path.endsWith('.dart') || path.startsWith('lib/l10n/generated/') || path == 'lib/l10n/time_ago.dart') {
        continue;
      }
      final calls = callsIn(f.readAsStringSync(), _timeWords);
      if (calls.isNotEmpty) found[path] = [for (final c in calls) c.line];
    }
    expect({for (final e in found.entries) if (!_allowed.containsKey(e.key)) e.key: e.value}, isEmpty,
        reason: 'say when something was with lib/l10n/time_ago.dart');
    expect([for (final f in _allowed.keys) if (!found.containsKey(f)) f], isEmpty,
        reason: 'a screen that no longer needs its place on the list');
  });
}
