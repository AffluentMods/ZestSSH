import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/account_deletion_api.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';

/// What the account page says when the account could not be deleted and
/// nothing was (3.0, the outage work). It said "The server could not delete
/// your account, and nothing was deleted. Check your connection and try
/// again." whatever had stopped the request. Where that was ZestSSH Cloud
/// or the way to it, it says how the service stands now, with its code,
/// after the one thing that matters most there: that nothing was deleted.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const refused = SocketException('Connection refused');

  tearDown(() => currentCloudReach = null);

  test('ZestSSH Cloud gave no answer, or answered with a fault of its own: said as that, after "Nothing was deleted."',
      () {
    expect(accountNotDeletedText(l10n, refused), '${l10n.accountDeleteNothingDeleted} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(accountNotDeletedText(l10n, 'HTTP 503: unavailable'),
        '${l10n.accountDeleteNothingDeleted} ${l10n.cloudFault(503)} (ZS-1103)');
    // What the request was stopped by, as the app's own client carries it.
    expect(accountNotDeletedText(l10n, const AccountDeletionException('network', 'x', cause: refused).stopped),
        '${l10n.accountDeleteNothingDeleted} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(accountNotDeletedText(l10n, const AccountDeletionException('server-error', 'HTTP 500: broke').stopped),
        '${l10n.accountDeleteNothingDeleted} ${l10n.cloudFault(500)} (ZS-1103)');
  });

  test('the device known to be offline: said as the device', () {
    final reach = CloudReachService(check: () async => 200);
    addTearDown(reach.dispose);
    currentCloudReach = reach;
    reach.networkChanged(up: false);
    expect(accountNotDeletedText(l10n, refused), '${l10n.accountDeleteNothingDeleted} ${l10n.cloudDeviceOffline} (ZS-1102)');
  });

  test('anything else is said as it always was', () {
    expect(accountNotDeletedText(l10n, null), l10n.accountDeleteFailedNothing);
    expect(accountNotDeletedText(l10n, 'HTTP 409: something this app does not know'), l10n.accountDeleteFailedNothing);
    expect(accountNotDeletedText(l10n, 'offline'), l10n.accountDeleteFailedNothing);
    expect(accountNotDeletedText(l10n, StateError('on this device')), l10n.accountDeleteFailedNothing);
  });

  test('"Nothing was deleted." leads in every language, and the code stays at the end', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      final said = accountNotDeletedText(words, refused);
      expect(said, startsWith('${words.accountDeleteNothingDeleted} '), reason: '$locale');
      expect(said, endsWith('(ZS-1101)'), reason: '$locale');
    }
  });
}
