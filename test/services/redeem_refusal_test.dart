import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/redeem_service.dart';

/// What the account page's "Redeem a code" says of a code that ZestSSH
/// Cloud did not redeem: a code that gives a team seats is told where it
/// goes, in the app's language (the service says it in English); any other
/// refusal is the service's own sentence; a fault of the service's own is
/// said as that.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final de = lookupAppLocalizations(const Locale('de'));

  test('a code that gives a team seats is told where it goes, in the app\'s language', () {
    final body = <String, dynamic>{
      'error': 'This code gives a team seats. An owner enters it in ZestSSH on a computer, under Team, then Seats.',
      'code': 'team-code',
    };
    expect(redeemRefusal(en, 409, body), en.redeemSvcTeamCode);
    expect(redeemRefusal(de, 409, body), de.redeemSvcTeamCode);
    expect(de.redeemSvcTeamCode, isNot(en.redeemSvcTeamCode));
  });

  test('any other refusal is the service\'s own sentence, or that the code could not be redeemed', () {
    const invalid = 'That code is not valid, has expired, or has already been used.';
    expect(redeemRefusal(en, 404, <String, dynamic>{'error': invalid}), invalid);
    expect(redeemRefusal(en, 404, const <String, dynamic>{}), en.redeemSvcCouldNotRedeem);
    // A sentence that is none is not shown, and stops nothing.
    expect(redeemRefusal(en, 400, <String, dynamic>{'error': 7}), en.redeemSvcCouldNotRedeem);
    // Another of the service's codes is not taken for a team's.
    expect(redeemRefusal(en, 409, <String, dynamic>{'error': 'Said by the service', 'code': 'something-else'}),
        'Said by the service');
  });

  test('redeeming paused for everyone after too many wrong codes is said in the language of the app', () {
    final body = <String, dynamic>{
      'error': 'Redeeming codes is paused for a while. Try again in an hour.',
      'code': 'redeem-paused',
    };
    expect(redeemRefusal(en, 429, body), en.redeemPaused);
    expect(redeemRefusal(de, 429, body), de.redeemPaused);
    expect(de.redeemPaused, isNot(en.redeemPaused));
  });

  test('a fault of the service\'s own is said as that, whatever its body says', () {
    final stopped = cloudStopped(en, 'HTTP 503', status: 503);
    expect(stopped, isNotNull);
    expect(redeemRefusal(en, 503, <String, dynamic>{'error': 'Said by the service', 'code': 'team-code'}), stopped);
    expect(stopped, isNot(en.redeemSvcTeamCode));
  });
}
