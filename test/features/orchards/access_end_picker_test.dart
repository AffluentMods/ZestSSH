import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:zestssh/features/orchards/export/event_export.dart' show exportTime;
import 'package:zestssh/features/orchards/record/orchard_record.dart' show kMaxDateSeconds, secondsAsDate;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart' show memberEndTooFar;
import 'package:zestssh/features/orchards/setup/setup_file.dart' show setupTime;
import 'package:zestssh/features/orchards/setup/setup_words.dart' show SetupShow;
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// When someone's access ends: a day as before,
/// or a time on it, with quick ends and the time zone the times are in.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  setUpAll(() => initializeDateFormatting('en'));

  int seconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

  test('an end at midnight is a whole day; any other moment is a time', () {
    expect(isWholeDayEnd(endOfDay(DateTime(2026, 11, 3))), isTrue);
    expect(isWholeDayEnd(seconds(DateTime(2026, 11, 3, 15, 30))), isFalse);
  });

  Future<Future<({int? endsAt})?> Function()> open(WidgetTester tester, {int? current, bool requireEnd = false}) async {
    ({int? endsAt})? result;
    var done = false;
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await pickAccessEnd(context, title: 'When access ends for Sam', current: current, requireEnd: requireEnd);
              done = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    return () async => done ? result : null;
  }

  testWidgets('where an end date cannot go (a guest outside the team\'s domains): no such choice, and nothing to save until there is a date', (tester) async {
    final result = await open(tester, current: seconds(DateTime.now().add(const Duration(days: 3))), requireEnd: true);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('end-none')), findsNothing);
    expect(find.text(l10n.orchardEndDateNone), findsNothing);
    // As it was: nothing to save yet.
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect(find.text(l10n.save), findsOneWidget);
    // The day may turn while it runs: the end of either day is right (it
    // failed at midnight).
    final before = DateTime.now();
    await tester.tap(find.byKey(const ValueKey('end-quick-week')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect((await result())!.endsAt, anyOf(endOfDay(before.add(const Duration(days: 7))),
        endOfDay(DateTime.now().add(const Duration(days: 7)))));
  });

  testWidgets('the furthest day it offers is one the server takes (five years), from any day in a leap year\'s way', (tester) async {
    await open(tester, current: seconds(DateTime.now().add(const Duration(days: 3))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('end-pick')));
    await tester.pumpAndSettle();
    final last = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog)).lastDate;
    final now = DateTime.now();
    expect(last, DateTime(now.year + 5, now.month, now.day));
    expect(memberEndTooFar(endOfDay(last), seconds(now)), isFalse);
    // The most days five years can hold, and a day's clock change either way.
    for (final from in [DateTime(2027, 3, 1), DateTime(2028, 2, 29), DateTime(2031, 12, 31), DateTime(2032, 1, 1)]) {
      final end = endOfDay(DateTime(from.year + 5, from.month, from.day));
      expect(memberEndTooFar(end, seconds(from.subtract(const Duration(hours: 13)))), isFalse, reason: '$from');
    }
  });

  group('a date further off than can be picked, from before there was a limit', () {
    for (final (name, at) in [
      ('ten years on', DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3650 * 86400),
      ('year 275,000', 8600000000000),
      ('the most a date can say', kMaxDateSeconds),
      ('the largest whole number', 9007199254740991),
    ]) {
      testWidgets('$name: said, and the dialog and the calendar open, at the furthest day', (tester) async {
        late String said;
        await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(builder: (context) {
              said = accessThrough(at, context);
              return TextButton(
                onPressed: () => pickAccessEnd(context, title: 'When access ends for Sam', current: at),
                child: const Text('open'),
              );
            }),
          ),
        ));
        expect(said, isNotEmpty);
        expect(isWholeDayEnd(at), anyOf(isTrue, isFalse));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byKey(const ValueKey('end-words')), findsOneWidget);
        await tester.tap(find.byKey(const ValueKey('end-pick')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final now = DateTime.now();
        final calendar = tester.widget<DatePickerDialog>(find.byType(DatePickerDialog));
        expect(calendar.initialDate, DateTime(now.year + 5, now.month, now.day));
        // The furthest day taken: the end comes within what can be picked.
        await tester.tap(find.text('OK'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final words = tester.widget<Text>(find.byKey(const ValueKey('end-words'))).data!;
        expect(words, contains('${now.year + 5}'));
      });

      testWidgets('$name: the time opens as well', (tester) async {
        await tester.pumpWidget(MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => pickAccessEnd(context, title: 'When access ends for Sam', current: at),
                child: const Text('open'),
              ),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('end-time')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.byType(TimePickerDialog), findsOneWidget);
      });
    }

    test('a moment is held to what a date can say, both ways', () {
      expect(secondsAsDate(1).millisecondsSinceEpoch, 1000);
      expect(secondsAsDate(9007199254740991).millisecondsSinceEpoch, kMaxDateSeconds * 1000);
      expect(secondsAsDate(-9007199254740991).millisecondsSinceEpoch, -kMaxDateSeconds * 1000);
      expect(secondsAsDate(1, isUtc: true).isUtc, isTrue);
    });

    test('and what else writes one stands', () {
      for (final (at, year) in [(8600000000000, '274493'), (9007199254740991, '275760')]) {
        expect(accessTimeText(at, l10n), isNotEmpty);
        expect(setupTime(at), contains(year));
        expect(exportTime(secondsAsDate(at)), contains(year));
        expect(const SetupShow.onScreen().time(at, l10n), contains(year));
      }
    });
  });

  testWidgets('with none to start from, the same: Save waits for a date', (tester) async {
    await open(tester, requireEnd: true);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect(find.text(l10n.save), findsOneWidget, reason: 'the dialog stays: no date, nothing saved');
  });

  testWidgets('elsewhere an end date can still be taken away', (tester) async {
    await open(tester, current: seconds(DateTime.now().add(const Duration(days: 3))));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('end-none')), findsOneWidget);
  });

  testWidgets('a quick end: an hour from now, said with its time, saved as that moment', (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('end-zone')), findsOneWidget);
    final before = seconds(DateTime.now());
    await tester.tap(find.byKey(const ValueKey('end-quick-hour')));
    await tester.pumpAndSettle();
    final words = tester.widget<Text>(find.byKey(const ValueKey('end-words'))).data!;
    expect(words, startsWith(l10n.orchardMemberEndsOn('').trim()));
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    final ends = (await result())!.endsAt!;
    expect(ends, inInclusiveRange(before + 3600 - 60, before + 3600 + 60));
  });

  testWidgets('a day, then a time on it; a time already gone is said, and not kept', (tester) async {
    final result = await open(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(find.byKey(const ValueKey('end-time'))).onPressed, isNull,
        reason: 'a time goes on a day: none yet');
    await tester.tap(find.byKey(const ValueKey('end-quick-week')));
    await tester.pumpAndSettle();
    final week = DateTime.now().add(const Duration(days: 7));
    expect(find.text(l10n.orchardEndDateOn(accessThrough(endOfDay(week), tester.element(find.byKey(const ValueKey('end-words')))))),
        findsOneWidget);

    // 9:15 on that day, typed in the clock's own fields.
    await tester.tap(find.byKey(const ValueKey('end-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '9');
    await tester.enterText(fields.at(1), '15');
    await tester.tap(find.text('AM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect((await result())!.endsAt, seconds(DateTime(week.year, week.month, week.day, 9, 15)));
  });

  testWidgets('a time earlier today than now is refused with a word', (tester) async {
    final now = DateTime.now();
    // Only where today still has a minute before now to pick.
    if (now.hour == 0 && now.minute < 2) return;
    final result = await open(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('end-quick-today')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('end-time')));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.keyboard_outlined));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '12');
    await tester.enterText(fields.at(1), '00');
    await tester.tap(find.text('AM'));
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text(l10n.orchardEndPast), findsOneWidget);
    await tester.tap(find.text(l10n.save));
    await tester.pumpAndSettle();
    expect((await result())!.endsAt, endOfDay(now), reason: 'the end of today stays');
  });
}
