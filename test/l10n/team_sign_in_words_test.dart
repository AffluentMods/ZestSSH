import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What a team's company sign-in and Business Services say (found in a docs
/// review). Removing company sign-in ends the
/// sessions made through it on computers too, not on phones alone; a change
/// leaves in those already signed in through it. And Business Services: what
/// needs it is directory sync, changes to company sign-in and the rule that
/// members use it; signing in through company sign-in goes on without it,
/// where the words said it stopped.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  test('removing company sign-in: everyone signed in through it, not those on a phone alone', () {
    expect(en.ssoRemoveBody('Acme SSO'), isNot(contains('phone')));
    expect(en.ssoRemoveBody('Acme SSO'), contains('Anyone signed in through it'));
  });

  test('saving a change: off until tested, and those already signed in through it stay', () {
    expect(en.ssoSaveTurnsOff, contains('anyone already signed in through it stays'));
  });

  test('Business Services: signing in through company sign-in goes on without it', () {
    const date = '2 November 2026';
    for (final words in [en.teamServicesEnds(date), en.teamServicesGraceText(date), en.teamServicesOffText]) {
      expect(words, isNot(contains('Company sign-in and directory sync keep working')), reason: words);
    }
    // Changing company sign-in needs Business paid up (the server's
    // servicesActive): in the 14 days after it ends, or while a payment is
    // due, the rule and directory sync go on, changes do not (the docs
    // check found the words said changes went on too).
    expect(en.teamServicesEnds(date), contains('company sign-in can no longer be changed'));
    expect(en.teamServicesGraceText(date), contains('company sign-in cannot be changed'));
    expect(en.teamServicesOffText, contains('changes to company sign-in'));
    expect(en.teamServicesEnds(date), contains('Signing in with it goes on'));
    expect(en.teamServicesGraceText(date), contains('Signing in with it goes on'));
    expect(en.teamServicesOffText, contains('people still sign in with it'));
  });

  test('in every language: the date where it was, and the new line of team recovery', () {
    const date = '2 November 2026';
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      final ends = words.teamServicesEnds(date);
      final grace = words.teamServicesGraceText(date);
      expect(ends == words.teamServicesEnds('3 January 2027'), isFalse, reason: '$locale: the date is in it');
      expect(grace == words.teamServicesGraceText('3 January 2027'), isFalse, reason: '$locale: the date is in it');
      expect(words.teamRecoveryOneOwnerOn, isNot(words.teamRecoveryNeedsTwoOwners), reason: '$locale');
      expect(words.ssoRemoveBody('Acme SSO'), contains('Acme SSO'), reason: '$locale');
    }
  });
}
