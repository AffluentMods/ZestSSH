import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

/// Why a session could not be shared, in words (3.0, the outage work). Every
/// screen that starts a share, or asks more people into one, said "ZestSSH
/// Cloud could not be reached, so nothing was shared. Check your connection
/// and try again." for whatever had stopped it: the service down, a fault
/// of its own, the device offline. One function says it for all of them now
/// (shareStartFailureText), and says how the service stands where that was
/// the reason.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const refused = SocketException('Connection refused');
  const notReady = 'this screen\'s words for not ready';

  tearDown(() => currentCloudReach = null);

  String said(Object error, {bool answersNow = false}) =>
      shareStartFailureText(l10n, error, notReady: notReady, answersNow: answersNow);

  test('a reason of the share\'s own is said as that, whatever came with it', () {
    expect(said(const ShareStartFailed(ShareStartProblem.tooMany)), l10n.shareFailedTooMany);
    expect(said(const ShareStartFailed(ShareStartProblem.noAccess)), l10n.shareFailedNoAccess);
    expect(said(const ShareStartFailed(ShareStartProblem.notReady)), notReady);
    // What was caught does not change those.
    expect(
        said(const ShareStartFailed(ShareStartProblem.tooMany, cause: OrchardServerException(503, 'too-many-shares'))),
        l10n.shareFailedTooMany);
    expect(said(const ShareStartFailed(ShareStartProblem.noAccess, cause: refused)), l10n.shareFailedNoAccess);
    expect(said(const ShareStartFailed(ShareStartProblem.notReady, cause: refused)), notReady);
  });

  test('ZestSSH Cloud or the way to it: how the service stands, with its code, after "Nothing was shared."', () {
    expect(said(const ShareStartFailed(ShareStartProblem.failed, cause: refused)),
        '${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(said(ShareStartFailed(ShareStartProblem.failed, cause: TimeoutException('no answer'))),
        '${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(said(const ShareStartFailed(ShareStartProblem.failed, cause: OrchardServerException(503, null))),
        '${l10n.shareNothingShared} ${l10n.cloudFault(503)} (ZS-1103)');
    // The device known to be offline: said as the device.
    final reach = CloudReachService(check: () async => 200);
    addTearDown(reach.dispose);
    currentCloudReach = reach;
    reach.networkChanged(up: false);
    expect(said(const ShareStartFailed(ShareStartProblem.failed, cause: refused)),
        '${l10n.shareNothingShared} ${l10n.cloudDeviceOffline} (ZS-1102)');
  });

  test('anything else is said as it always was', () {
    // Nothing known of what stopped it.
    expect(said(const ShareStartFailed(ShareStartProblem.failed)), l10n.shareFailedOffline);
    // The service answered, and not with a fault of its own.
    expect(said(const ShareStartFailed(ShareStartProblem.failed, cause: OrchardServerException(429, 'rate-limited'))),
        l10n.shareFailedOffline);
    expect(said(ShareStartFailed(ShareStartProblem.failed, cause: StateError('on this device'))),
        l10n.shareFailedOffline);
  });

  test('asking more people into a share that runs: what was caught is read the same way', () {
    expect(said(refused), '${l10n.shareNothingShared} ${l10n.cloudNotResponding} (ZS-1101)');
    expect(said(const OrchardServerException(502, null)), '${l10n.shareNothingShared} ${l10n.cloudFault(502)} (ZS-1103)');
    // Someone picked cannot open the Crate any more: said as that, where it
    // used to send people to check their connection.
    expect(said(const ShareNoAccess(['uid-1'])), l10n.shareFailedNoAccess);
    expect(said(StateError('anything else')), l10n.shareFailedOffline);
    expect(said(const OrchardServerException(404, 'not-found')), l10n.shareFailedOffline);
  });

  test('where the service was asked since and answered, one request that got no answer is not an outage', () {
    expect(said(const ShareStartFailed(ShareStartProblem.failed, cause: refused), answersNow: true),
        l10n.shareFailedOffline);
    expect(said(refused, answersNow: true), l10n.shareFailedOffline);
    // A fault it answered with is still a fault of its own.
    expect(
        said(const ShareStartFailed(ShareStartProblem.failed, cause: OrchardServerException(500, null)),
            answersNow: true),
        '${l10n.shareNothingShared} ${l10n.cloudFault(500)} (ZS-1103)');
    // And a reason of the share's own is what it was.
    expect(said(const ShareStartFailed(ShareStartProblem.tooMany), answersNow: true), l10n.shareFailedTooMany);
    expect(said(const ShareNoAccess(['uid-1']), answersNow: true), l10n.shareFailedNoAccess);
  });

  test('the new sentence is in every language, and names no connection to check', () {
    final seen = <String>{};
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale).shareNothingShared;
      expect(words.trim(), isNotEmpty, reason: '$locale');
      seen.add(words);
    }
    expect(seen, hasLength(AppLocalizations.supportedLocales.length), reason: 'each language has its own');
    expect(l10n.shareNothingShared, 'Nothing was shared.');
  });
}
