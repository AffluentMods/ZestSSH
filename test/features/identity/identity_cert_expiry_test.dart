// When a certificate runs out (3.0): what is said of it, and when its
// person is reminded.
//
// What was said went by whole days of twenty-four hours, and was English in
// every language: a certificate that had run out three hours earlier
// "expires today", one that ends tomorrow morning "expires today" the
// evening before, and one that ends the day after tomorrow "expires
// tomorrow".

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/identity/identity_cert_expiry.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A key with a certificate that runs out at [runsOut], issued at [issued]
/// where that is known.
Identity key({DateTime? runsOut, DateTime? issued}) => Identity(
      id: 'key-prod',
      label: 'prod certificate',
      username: 'deploy',
      authMethod: 'certificate',
      colorIndex: 0,
      isDefault: false,
      usesAgent: false,
      allowUnattended: false,
      passwordAfterKey: false,
      certValidAfter: issued,
      certValidBefore: runsOut,
      createdAt: DateTime.utc(2025),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  group('what is said of when a certificate runs out', () {
    // Eight in the evening, on this device's clock.
    final now = DateTime(2026, 10, 10, 20);
    String? said(DateTime? runsOut, {DateTime? at}) => certExpirySaid(key(runsOut: runsOut), en, now: at ?? now);

    test('one that has run out has run out, however lately', () {
      expect(said(now), 'Certificate has run out');
      expect(said(now.subtract(const Duration(seconds: 1))), 'Certificate has run out');
      expect(said(now.subtract(const Duration(hours: 3))), 'Certificate has run out');
      expect(said(now.subtract(const Duration(hours: 30))), 'Certificate has run out');
      expect(said(DateTime(2024)), 'Certificate has run out');
    });

    test('the days are days of the calendar: today, tomorrow, and from there by their number', () {
      expect(said(now.add(const Duration(seconds: 1))), 'Certificate runs out today');
      expect(said(DateTime(2026, 10, 10, 23, 59)), 'Certificate runs out today');
      // Less than a day to go, and tomorrow all the same.
      expect(said(DateTime(2026, 10, 11)), 'Certificate runs out tomorrow');
      expect(said(DateTime(2026, 10, 11, 10)), 'Certificate runs out tomorrow');
      expect(said(DateTime(2026, 10, 11, 23, 59)), 'Certificate runs out tomorrow');
      // Less than two days to go.
      expect(said(DateTime(2026, 10, 12, 9)), 'Certificate runs out in 2 days');
      expect(said(DateTime(2026, 10, 15, 21)), 'Certificate runs out in 5 days');
      expect(said(DateTime(2026, 10, 24, 19)), 'Certificate runs out in 14 days');
      // Over the end of a month and of a year.
      expect(said(DateTime(2026, 11, 2, 6)), 'Certificate runs out in 23 days');
      expect(said(DateTime(2027, 1, 1), at: DateTime(2026, 12, 30, 23)), 'Certificate runs out in 2 days');
      // Asked in the first minute of a day, of a certificate that ends in its last.
      expect(said(DateTime(2026, 10, 10, 23, 59), at: DateTime(2026, 10, 10, 0, 1)), 'Certificate runs out today');
    });

    test('a time is the same time, whichever way it is written down', () {
      // What a certificate holds is a time of UTC; what the database gives back is one of this device's clock.
      // (Early and late in a day: wherever this is run but in UTC itself, one of the two is another day there.)
      for (final hour in [1, 23]) {
        final asked = DateTime(2026, 10, 10, hour);
        for (final runsOut in [
          DateTime(2026, 10, 11, 1),
          DateTime(2026, 10, 11, 23),
          DateTime(2026, 10, 13, 0, 30),
          DateTime(2026, 10, 13, 23, 30),
        ]) {
          final words = said(runsOut, at: asked);
          expect(words, runsOut.day == 11 ? 'Certificate runs out tomorrow' : 'Certificate runs out in 3 days');
          expect(said(runsOut.toUtc(), at: asked), words, reason: '$runsOut at $asked');
          expect(said(runsOut, at: asked.toUtc()), words, reason: '$runsOut at $asked');
          expect(said(runsOut.toUtc(), at: asked.toUtc()), words, reason: '$runsOut at $asked');
        }
      }
    });

    test('a certificate with no end, and a key with none, have nothing said of them', () {
      expect(said(null), isNull);
    });

    test('in every language, with the number of days', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final l = lookupAppLocalizations(locale);
        String at(DateTime runsOut) => certExpirySaid(key(runsOut: runsOut), l, now: now)!;
        final each = <String>[
          at(now.subtract(const Duration(hours: 3))),
          at(DateTime(2026, 10, 10, 23)),
          at(DateTime(2026, 10, 11, 10)),
          for (final days in [2, 3, 5, 11, 14]) at(DateTime(2026, 10, 10 + days, 12)),
        ];
        expect(each.toSet(), hasLength(each.length), reason: '$locale: each its own');
        for (final (i, days) in [3, 5, 11, 14].indexed) {
          expect(each[4 + i], contains('$days'), reason: '$locale');
        }
        if (locale.languageCode == 'en') continue;
        final english = [
          en.certSaidRanOut,
          en.certSaidRunsOutToday,
          en.certSaidRunsOutTomorrow,
          for (final days in [2, 3, 5, 11, 14]) en.certSaidRunsOutInDays(days),
        ];
        for (final (i, words) in each.indexed) {
          expect(words, isNot(english[i]), reason: '$locale');
          expect(words, isNot(contains('Certificate')), reason: '$locale');
        }
      }
    });
  });

  group('when the person of a key is reminded of its certificate', () {
    final runsOut = DateTime(2026, 10, 10, 12);
    CertReminder? at(Duration before, {Duration? issuedFor}) => key(
          runsOut: runsOut,
          issued: issuedFor == null ? null : runsOut.subtract(issuedFor),
        ).certReminder(now: runsOut.subtract(before));

    test('in its last fourteen days it runs out soon', () {
      const year = Duration(days: 365);
      expect(at(const Duration(days: 60), issuedFor: year), isNull);
      expect(at(const Duration(days: 14, minutes: 1), issuedFor: year), isNull);
      expect(at(const Duration(days: 14), issuedFor: year), CertReminder.runsOutSoon);
      expect(at(const Duration(days: 3), issuedFor: year), CertReminder.runsOutSoon);
      expect(at(const Duration(seconds: 1), issuedFor: year), CertReminder.runsOutSoon);
      // The same where it is not known when it was issued.
      expect(at(const Duration(days: 14, minutes: 1)), isNull);
      expect(at(const Duration(days: 14)), CertReminder.runsOutSoon);
    });

    test('one that was issued for a short time runs out soon in the last quarter of it', () {
      // For a day, as short-lived certificates are: in its last six hours, and not from its first minute.
      const day = Duration(days: 1);
      expect(at(const Duration(hours: 23, minutes: 59), issuedFor: day), isNull);
      expect(at(const Duration(hours: 6, minutes: 1), issuedFor: day), isNull);
      expect(at(const Duration(hours: 6), issuedFor: day), CertReminder.runsOutSoon);
      expect(at(const Duration(minutes: 5), issuedFor: day), CertReminder.runsOutSoon);
      // For thirty days: in its last seven and a half.
      const month = Duration(days: 30);
      expect(at(const Duration(days: 8), issuedFor: month), isNull);
      expect(at(const Duration(days: 7, hours: 12), issuedFor: month), CertReminder.runsOutSoon);
      // For eight weeks its last quarter is fourteen days, and from there it is fourteen days.
      expect(at(const Duration(days: 14, minutes: 1), issuedFor: const Duration(days: 56)), isNull);
      expect(at(const Duration(days: 14), issuedFor: const Duration(days: 56)), CertReminder.runsOutSoon);
      expect(at(const Duration(days: 20), issuedFor: const Duration(days: 90)), isNull);
    });

    test('one that has run out is reminded of for fourteen days, and then no more', () {
      expect(at(Duration.zero), CertReminder.ranOut);
      expect(at(-const Duration(hours: 3)), CertReminder.ranOut);
      expect(at(-const Duration(days: 13, hours: 23, minutes: 59)), CertReminder.ranOut);
      expect(at(-const Duration(days: 14)), isNull);
      expect(at(-const Duration(days: 400)), isNull);
      // Whatever it was issued for.
      expect(at(-const Duration(days: 2), issuedFor: const Duration(days: 1)), CertReminder.ranOut);
    });

    test('a certificate with no end is never reminded of, and neither is a key with none', () {
      expect(key().certReminder(now: runsOut), isNull);
      expect(key(issued: DateTime(2026)).certReminder(now: DateTime(2040)), isNull);
    });
  });

  test('the fourteen days in which the page of a key says when its certificate runs out', () {
    final runsOut = DateTime(2026, 10, 10, 12);
    final k = key(runsOut: runsOut, issued: runsOut.subtract(const Duration(days: 1)));
    bool soon(Duration before) => k.certExpiringSoon(now: runsOut.subtract(before));
    bool gone(Duration before) => k.certExpired(now: runsOut.subtract(before));
    expect(soon(const Duration(days: 14, minutes: 1)), isFalse);
    // (Whatever it was issued for: the page says what is so, and reminds nobody.)
    expect(soon(const Duration(days: 14)), isTrue);
    expect(soon(const Duration(seconds: 1)), isTrue);
    expect(soon(Duration.zero), isFalse);
    expect(gone(const Duration(seconds: 1)), isFalse);
    expect(gone(Duration.zero), isTrue);
    expect(gone(-const Duration(days: 400)), isTrue);
    expect(key().certExpired(now: runsOut), isFalse);
    expect(key().certExpiringSoon(now: runsOut), isFalse);
  });
}
