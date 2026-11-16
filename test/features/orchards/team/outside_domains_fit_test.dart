import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/members/member_actions.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show accessThrough, endOfDay;
import 'package:zestssh/features/orchards/widgets/outside_domains.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../visual/shots_util.dart';

/// Who a new list of address domains leaves out, in the real fonts, in every
/// language: nothing overflows, with a long address and with an owner among
/// them, in a computer's window and a phone's. With ZEST_SHOTS the pictures
/// land in build/shots/outside-domains-*.png.

const _member = MemberActions(endDate: true, remove: true);

OrchardPerson _person(String uid, String? email,
        {String role = 'r', MemberActions actions = _member, int? endsAt, bool byOwner = false, String? name, bool me = false}) =>
    OrchardPerson(
      uid: uid,
      isMe: me,
      email: email,
      name: name,
      role: role,
      status: MemberStatus.active,
      grants: const {},
      actions: actions,
      endsAt: endsAt,
      endChosenByOwner: byOwner,
    );

const _ends = 1893456000; // 1 January 2030, near enough

final _outside = OutsideDomains(held: [
  _person('u1', 'sam@example.com'),
  _person('u2', 'priya.ramanathan-longsurname@consulting.partners.example.com'),
  _person('u3', 'jordan@example.net'),
  _person('u4', 'alex@example.org', role: FixedRoles.owner, actions: MemberActions.none),
], guests: [
  _person('u5', 'lin@example.net', endsAt: _ends, byOwner: true),
  _person('u6', 'omar.al-rashid-longsurname@consulting.partners.example.com', endsAt: _ends + 86400),
], unknown: [
  _person('u7', null, name: 'Kai'),
]);

void main() {
  Future<void> show(WidgetTester tester, Locale locale,
      {required String shot, Size size = const Size(1000, 860), bool guests = false, OutsideDomains? outside}) async {
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final key = GlobalKey();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        recordingModeProvider.overrideWith((ref) => false),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('default_dark').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: locale,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showOutsideDomains(context,
                    domains: const {'northwind.example', 'northwind.example.net'}, outside: outside ?? _outside, beforeSaving: true),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('outside-domains')), findsOneWidget);
    if (guests) {
      await tester.tap(find.byKey(const ValueKey('outside-all-guest')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('outside-until')), findsOneWidget);
    }
    expect(tester.takeException(), isNull, reason: '$locale');
    if (shotsEnabled) {
      realShadows();
      await tester.pump();
      await saveShot(tester, key, shot);
      plainShadows();
    }
  }

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('$locale: a computer', (tester) async {
      await show(tester, locale, shot: 'outside-domains-$locale');
    });

    testWidgets('$locale: all kept as guests, with the date', (tester) async {
      await show(tester, locale, shot: 'outside-domains-guests-$locale', guests: true);
    });

    testWidgets('$locale: a phone\'s width', (tester) async {
      await show(tester, locale, shot: 'outside-domains-phone-$locale', size: const Size(390, 844));
    });
  }

  testWidgets('while the screen is recorded, no address and no domain can be read: not in the dialog, not in what Members says', (tester) async {
    Redactor.instance
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = true;
    addTearDown(() => Redactor.instance.enabled = false);
    final l10n = lookupAppLocalizations(const Locale('en'));
    late WidgetRef seen;
    tester.view.physicalSize = const Size(1000, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        recordingModeProvider.overrideWith((ref) => true),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            seen = ref;
            return TextButton(
              onPressed: () => showOutsideDomains(context,
                  domains: const {'northwind.example'}, outside: _outside, beforeSaving: true),
              child: const Text('open'),
            );
          }),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final shown = [
      for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
    ].join('\n');
    final notice = '${outsidePeopleWords(_outside.held, seen, l10n)} ${outsideDomainsWords({'northwind.example'}, seen, l10n)}';
    for (final name in ['sam@', 'priya', 'jordan', 'alex@', 'lin@', 'omar', 'Kai', 'example.com', 'example.org', 'example.net', 'northwind']) {
      expect(shown, isNot(contains(name)), reason: 'the dialog: $name');
      expect(notice, isNot(contains(name)), reason: 'the notice: $name');
    }
    expect(shown, contains(l10n.orchardOutsideHold));

    // The question before someone is removed says who, as masked.
    await tester.tap(find.byKey(const ValueKey('outside-choice-u1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('zest-select-item-${OutsideChoice.remove}')).last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const ValueKey('outside-go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('outside-go')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.orchardOutsideRemoveTitle(1)), findsOneWidget);
    final asked = [
      for (final t in tester.widgetList<Text>(find.byType(Text))) t.data ?? t.textSpan?.toPlainText() ?? '',
    ].join('\n');
    expect(asked, isNot(contains('sam@')));
    expect(asked, contains(l10n.orchardRemoveBody));
  });

  group('who has an end date, what they may be, and what comes of it', () {
    /// The dialog open; then what it answered, once it has closed.
    Future<Future<OutsideAnswer?> Function()> openIt(WidgetTester tester, OutsideDomains outside, {Set<String> proven = const {}}) async {
      late Future<OutsideAnswer?> answer;
      tester.view.physicalSize = const Size(1000, 860);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => answer = showOutsideDomains(context,
                    domains: const {'northwind.example'}, outside: outside, beforeSaving: true, proven: proven),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => answer;
    }

    final l10n = lookupAppLocalizations(const Locale('en'));
    Finder k(String key) => find.byKey(ValueKey(key));

    Future<void> choose(WidgetTester tester, String uid, OutsideChoice choice) async {
      await tester.tap(k('outside-choice-$uid'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey('zest-select-item-$choice')).last);
      await tester.pumpAndSettle();
    }

    final byOwner = OutsideDomains(guests: [_person('u5', 'lin@example.net', endsAt: _ends, byOwner: true)]);
    final byOther = OutsideDomains(guests: [_person('u6', 'omar@example.net', endsAt: _ends)]);

    testWidgets('a date an owner gave, kept: nothing to write', (tester) async {
      final answer = await openIt(tester, byOwner);
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.guests, isEmpty);
      expect(d.stays, {'u5': _ends});
      expect(d.changesMembers, isFalse);
    });

    testWidgets('a date no owner gave, kept: the same date, signed by an owner', (tester) async {
      final answer = await openIt(tester, byOther);
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.guests, {'u6': _ends});
      expect(d.changesMembers, isTrue);
    });

    testWidgets('left held back: the date goes', (tester) async {
      final answer = await openIt(tester, byOwner);
      expect(k('outside-date-u5'), findsOneWidget);
      await choose(tester, 'u5', OutsideChoice.hold);
      expect(k('outside-date-u5'), findsNothing, reason: 'no date to change');
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.clear, {'u5'});
      expect(d.guests, isEmpty);
      expect(d.held, 1);
    });

    testWidgets('removed: asked, by name; Cancel goes back to choosing', (tester) async {
      final answer = await openIt(tester, byOwner);
      await choose(tester, 'u5', OutsideChoice.remove);
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      expect(find.text('lin@example.net. ${l10n.orchardRemoveBody}'), findsOneWidget);
      await tester.tap(find.text(l10n.orchardRemoveConfirm).last);
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.remove, {'u5'});
      expect(d.stays, isEmpty);
    });

    testWidgets('the removal question names the first few, then how many more', (tester) async {
      final many = OutsideDomains(held: [for (var i = 0; i < 5; i++) _person('m$i', 'm$i@example.net')]);
      await openIt(tester, many);
      await tester.tap(k('outside-all-remove'));
      await tester.pumpAndSettle();
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      expect(find.text('m0@example.net, m1@example.net, m2@example.net, ${l10n.orchardRulesOutsideMore(2)}. ${l10n.orchardRemoveBody}'), findsOneWidget);
    });

    testWidgets('another date: chosen in the picker, and that is what is written', (tester) async {
      final answer = await openIt(tester, byOwner);
      // The day may turn while it runs: the end of either day is right (it
      // failed at midnight).
      final before = DateTime.now();
      await tester.tap(k('outside-date-u5'));
      await tester.pumpAndSettle();
      await tester.tap(k('end-quick-week'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10n.save).last);
      await tester.pumpAndSettle();
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.guests['u5'], anyOf(endOfDay(before.add(const Duration(days: 7))),
          endOfDay(DateTime.now().add(const Duration(days: 7)))));
      expect(d.guests.keys, ['u5']);
    });

    testWidgets('outside the domains the team proved: an end date stays, so leaving them held back is not offered', (tester) async {
      await openIt(tester, byOwner, proven: {'northwind.example'});
      await tester.tap(k('outside-choice-u5'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('zest-select-item-${OutsideChoice.guest}')), findsWidgets);
      expect(find.byKey(ValueKey('zest-select-item-${OutsideChoice.remove}')), findsWidgets);
      expect(find.byKey(ValueKey('zest-select-item-${OutsideChoice.hold}')), findsNothing);
    });

    testWidgets('inside what was proved, it is', (tester) async {
      await openIt(tester, byOwner, proven: {'example.net'});
      await tester.tap(k('outside-choice-u5'));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey('zest-select-item-${OutsideChoice.hold}')), findsWidgets);
    });

    testWidgets('someone with no date kept as a guest gets the date under the list; one who has theirs needs none', (tester) async {
      final both = OutsideDomains(held: [_person('u1', 'sam@example.com')], guests: [_person('u5', 'lin@example.net', endsAt: _ends, byOwner: true)]);
      final answer = await openIt(tester, both);
      expect(k('outside-until'), findsNothing);
      expect(k('outside-guest-note'), findsOneWidget);
      await choose(tester, 'u1', OutsideChoice.guest);
      expect(k('outside-until'), findsOneWidget);
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      final d = await answer() as OutsideDecided;
      expect(d.guests.keys, ['u1']);
      expect(d.stays.keys, unorderedEquals(['u1', 'u5']));
    });

    testWidgets('whose address this device does not know: listed, said, and held back unless chosen', (tester) async {
      final answer = await openIt(tester, OutsideDomains(unknown: [_person('u7', null, name: 'Kai')]));
      expect(k('outside-unknown-u7'), findsOneWidget);
      expect(find.text(l10n.orchardOutsideAddressUnknown), findsOneWidget);
      expect(k('outside-happens'), findsOneWidget);
      await tester.tap(k('outside-go'));
      await tester.pumpAndSettle();
      expect((await answer() as OutsideDecided).held, 1);
    });

    testWidgets('what Confirm it is you says: each date with how many, who goes, who is held', (tester) async {
      late BuildContext at;
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(builder: (context) {
          at = context;
          return const SizedBox();
        }),
      ));
      final said = outsideEffects(
          const OutsideDecided(stays: {'a': _ends, 'b': _ends, 'c': _ends + 86400}, remove: {'d'}, held: 2), at, l10n);
      expect(said, [
        l10n.orchardOutsideEffectGuests(2, accessThrough(_ends, at)),
        l10n.orchardOutsideEffectGuests(1, accessThrough(_ends + 86400, at)),
        l10n.orchardOutsideEffectRemoved(1),
        l10n.orchardOutsideEffectHeld(2),
      ]);
    });
  });

  test('who is which', () {
    final people = OrchardPeople(me: 'me', record: OrchardRecord('o'), members: [
      _person('me', 'me@other.example', me: true),
      _person('held', 'held@other.example'),
      _person('inside', 'inside@northwind.example'),
      _person('insideDated', 'dated@northwind.example', endsAt: _ends),
      _person('dated', 'dated@other.example', endsAt: _ends),
      _person('datedByOwner', 'owners@other.example', endsAt: _ends, byOwner: true),
      _person('unknown', null),
      _person('unknownDated', null, endsAt: _ends),
      _person('over', 'over@other.example', endsAt: 1000),
    ], roles: const [], stepDown: false, leave: false);
    final o = outsideDomainsOf(people, {'northwind.example'}, nowSeconds: 2000);
    expect([for (final p in o.held) p.uid], ['held']);
    expect([for (final p in o.guests) p.uid], ['dated', 'datedByOwner']);
    expect([for (final p in o.unseen) p.uid], ['dated']);
    expect([for (final p in o.unknown) p.uid], ['unknown']);
    expect(o.isEmpty, isFalse);
    expect(outsideDomainsOf(people, const {}, nowSeconds: 2000).isEmpty, isTrue);
  });

  testWidgets('right to left, a row and the date under the list are laid out the same from the other side', (tester) async {
    final people = OutsideDomains(held: [_person('u1', 'sam@example.com'), _person('u2', 'jordan@example.net')]);
    Future<(double, double)> measure(Locale locale) async {
      await show(tester, locale, shot: 'outside-domains-side-$locale', outside: people, guests: true);
      final rtl = locale.languageCode == 'ar';
      final row = tester.getRect(find.byKey(const ValueKey('outside-u1')));
      final who = tester.getRect(find.descendant(of: find.byKey(const ValueKey('outside-u1')), matching: find.byType(RedactedText)).first);
      final until = tester.getRect(find.byKey(const ValueKey('outside-until')));
      final words = tester.getRect(find.descendant(of: find.byKey(const ValueKey('outside-until')), matching: find.byType(Column)).first);
      final at = (
        rtl ? row.right - who.right : who.left - row.left,
        rtl ? until.right - words.right : words.left - until.left,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      return at;
    }

    final ltr = await measure(const Locale('en'));
    final rtl = await measure(const Locale('ar'));
    expect(rtl, ltr);
    expect(ltr.$1, greaterThan(0));
  });

  testWidgets('all of them: an owner keeps what can be chosen for them, and only what can', (tester) async {
    await show(tester, const Locale('en'), shot: 'outside-domains-all', guests: true);
    final l10n = lookupAppLocalizations(const Locale('en'));
    expect(find.byKey(const ValueKey('outside-fixed-u4')), findsOneWidget);
    expect(find.text(l10n.orchardOutsideOwner), findsOneWidget);
    expect(find.byKey(const ValueKey('outside-choice-u4')), findsNothing);
    expect(find.byKey(const ValueKey('outside-ends-u5')), findsOneWidget);
    expect(find.byKey(const ValueKey('outside-ends-u6')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('outside-choice-u1')), matching: find.text(l10n.orchardOutsideKeepGuest)), findsOneWidget);
  });
}
