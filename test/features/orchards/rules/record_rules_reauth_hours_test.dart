import 'dart:convert';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Sign in again in hours: the rule was in days;
/// reauth_hours adds a window shorter than a day. In the record only when
/// set, so rules from before keep their bytes and older apps read them;
/// where days and hours are both set, the shorter one holds. In a setup file
/// the two are one rule: naming either sets both.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  (int, int) reauth(RecordRules r) => (r.reauthDays, r.reauthHours);

  test('in the record only when set, read back either way', () {
    expect(RecordRules.none.toBody().containsKey('reauth_hours'), isFalse);
    const eight = RecordRules(reauthHours: 8);
    expect(eight.toBody()['reauth_hours'], 8);
    expect(eight.isNone, isFalse);
    expect(RecordRules.fromStored(eight.toBody()).reauthHours, 8);
    expect(RecordRules.fromStored(RecordRules.none.toBody()).reauthHours, 0);
    expect(eight.copyWith(noExport: true).reauthHours, 8);
    expect(eight.copyWith(reauthHours: 0).isNone, isTrue);
    expect(rulesOn(eight), 1);
    expect(rulesOn(const RecordRules(reauthDays: 1, reauthHours: 8)), 1, reason: 'one rule');
  });

  test('how long a sign-in counts: the shorter of the days and the hours that are set', () {
    expect(RecordRules.none.reauthSeconds, 0);
    expect(const RecordRules(reauthHours: 8).reauthSeconds, 8 * 3600);
    expect(const RecordRules(reauthDays: 30).reauthSeconds, 30 * 86400);
    expect(const RecordRules(reauthDays: 1, reauthHours: 4).reauthSeconds, 4 * 3600);
    expect(const RecordRules(reauthDays: 1, reauthHours: 48).reauthSeconds, 86400);
  });

  test('in words: off, whole days as days, the rest in hours; in every language', () {
    expect(reauthSpanWords(l10n, 0), l10n.orchardRulesReauthOff);
    expect(reauthSpanWords(l10n, 1), '1 hour');
    expect(reauthSpanWords(l10n, 8), '8 hours');
    expect(reauthSpanWords(l10n, 24), '1 day');
    expect(reauthSpanWords(l10n, 36), '36 hours');
    expect(reauthSpanWords(l10n, 168), '7 days');
    // What a choice costs shows where it counts.
    expect(reauthChoiceNote(l10n, 1), 'About 8 sign-ins a working day');
    expect(reauthChoiceNote(l10n, 4), 'About 2 sign-ins a working day');
    expect(reauthChoiceNote(l10n, 8), 'About one sign-in a working day');
    expect(reauthChoiceNote(l10n, 120), isNull);
    expect(reauthChoiceNote(l10n, 720), 'Recommended');
    expect(reauthChoiceNote(l10n, 0), isNull);
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final hours in [1, 4, 8, 12]) {
        final words = reauthSpanWords(l, hours);
        expect(words.trim(), isNotEmpty, reason: '$locale $hours');
        expect(words, isNot(reauthSpanWords(l, hours * 24)), reason: '$locale $hours: hours are not days');
        if (hours > 1) expect(words, contains('$hours'), reason: '$locale $hours');
      }
    }
  });

  group('in a setup file', () {
    SetupFileRead readRules(Map<String, Object?> rules) =>
        readSetupFile(jsonEncode({kSetupFileMarker: 1, 'rules': rules}));

    test('a whole number of hours up to a year', () {
      expect(readRules({'reauth_hours': 0}).file!.rules!.reauthHours, 0);
      expect(readRules({'reauth_hours': 8760}).file!.rules!.reauthHours, 8760);
      final over = readRules({'reauth_hours': 8761});
      expect(over.file, isNull);
      expect([for (final p in over.problems) '$p'], ['outOfRange rules.reauth_hours min 0 max 8760']);
      expect(readRules({'reauth_hours': 'eight'}).file, isNull);
      expect(SetupRules.of(const RecordRules(reauthHours: 8)).toJson()['reauth_hours'], 8);
    });

    test('a team without hours writes none, so apps from before hours still read its file', () {
      final json = SetupRules.of(const RecordRules(reauthDays: 30)).toJson();
      expect(json['reauth_days'], 30);
      expect(json.containsKey('reauth_hours'), isFalse);
    });

    test('one rule with the days: naming either sets both, the one left out to 0', () {
      const now = RecordRules(reauthDays: 30, reauthHours: 8, noExport: true);
      expect(reauth(const SetupRules(reauthHours: 4).over(now)), (0, 4));
      expect(reauth(const SetupRules(reauthDays: 7).over(now)), (7, 0));
      expect(reauth(const SetupRules(reauthDays: 1, reauthHours: 4).over(now)), (1, 4));
      expect(reauth(const SetupRules(noExport: false).over(now)), (30, 8), reason: 'not named: as it is');
      expect(const SetupRules(reauthHours: 4).over(now).noExport, isTrue);
    });

    test('a step that sets it says the window once', () {
      String said(SetupRules parts) =>
          setupStepWords(SetRules(parts: parts, rules: parts.over(RecordRules.none)), l10n).details.single;
      String pair(String words) => l10n.setupPair(l10n.orchardRulesReauth, words);
      expect(said(const SetupRules(reauthHours: 8)), pair(l10n.orchardRulesReauthHours(8)));
      expect(said(const SetupRules(reauthDays: 1, reauthHours: 4)), pair(l10n.orchardRulesReauthHours(4)));
      expect(said(const SetupRules(reauthDays: 30)), pair(l10n.orchardRulesReauthDays(30)));
      expect(said(const SetupRules(reauthDays: 0)), pair(l10n.orchardRulesReauthOff));
    });
  });
}
