import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where a screen asks something of ZestSSH Cloud and it does not happen,
/// what stopped it is said as what it is, with its code (3.0, the outage
/// work: every error should say plainly what is
/// happening). These screens said "Check your connection and
/// try again" whatever had happened: the service down, a fault of its own,
/// the device offline. Each now asks first whether the service or the way to
/// it was what stopped it (cloudStopped, lib/services/cloud/cloud_failure.dart)
/// and keeps its old sentence for everything else; and what could not reach
/// a sync store says whose store it is (SyncFailure.ofStore).
///
/// Read from the app's own files: a new call that shows one of these
/// sentences on its own, with no screen of it tested, fails here.
void main() {
  String source(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  final sources = {
    for (final f in Directory('lib').listSync(recursive: true))
      if (f is File &&
          f.path.endsWith('.dart') &&
          !f.path.contains('${Platform.pathSeparator}generated${Platform.pathSeparator}'))
        f.path.replaceAll(Platform.pathSeparator, '/'): source(f.path),
  };

  const profile = 'lib/ui/screens/profile/profile_screen.dart';
  const approvals = 'lib/ui/screens/profile/device_approval_dialogs.dart';

  /// The sentences that give advice about a connection, or say only that
  /// something did not work. For each, the files that may show it, and in
  /// each file how often it stands as what is said once the service was
  /// asked and was not what stopped it (asked), and how often on its own
  /// (bare). The bare ones, each for its reason:
  ///  * approveFailed: a sign-in again that was turned down or failed (no
  ///    error is at hand there), and the dialog's default;
  ///  * askFailed: the dialog's default;
  ///  * shareFailedOffline: nothing is known of what stopped the share, or
  ///    the service was asked since and answered;
  ///  * ticketsOffline: the question was asked on the line above it.
  const sentences = <String, Map<String, ({int asked, int bare})>>{
    'accountReplaceKeysFailed': {profile: (asked: 1, bare: 0)},
    'devicesActionFailed': {
      profile: (asked: 2, bare: 0),
      'lib/ui/screens/sync/cloud_device_room.dart': (asked: 2, bare: 0),
    },
    'accountDeleteFailedNothing': {profile: (asked: 1, bare: 0)},
    'ssoSignInLookupFailed': {'lib/ui/screens/profile/sso_sign_in.dart': (asked: 2, bare: 0)},
    'redeemSvcCouldNotReachServer': {'lib/services/redeem_service.dart': (asked: 1, bare: 0)},
    'syncResetFailedNetwork': {'lib/ui/screens/sync/sync_reset_ui.dart': (asked: 1, bare: 0)},
    'syncResetFailedServer': {'lib/ui/screens/sync/sync_reset_ui.dart': (asked: 1, bare: 0)},
    'twoStepErrorUnavailable': {
      'lib/ui/screens/profile/widgets/two_step_dialogs.dart': (asked: 1, bare: 0),
      'lib/ui/screens/profile/widgets/two_step_words.dart': (asked: 2, bare: 0),
    },
    'approveFailed': {approvals: (asked: 4, bare: 2)},
    'askFailed': {approvals: (asked: 2, bare: 1)},
    'shareFailedOffline': {'lib/features/sharing/share_providers.dart': (asked: 1, bare: 2)},
    'ticketsOffline': {'lib/ui/screens/help/ticket_widgets.dart': (asked: 0, bare: 1)},
  };

  test('each of these sentences is shown only where the service was asked first whether it was what stopped it', () {
    for (final MapEntry(key: name, value: files) in sentences.entries) {
      final use = RegExp('l10n\\.$name\\b');
      // The service asked in the same statement: cloudStopped itself, or
      // the one place that names its question (sync_reset_ui.dart).
      final asked = RegExp(r'(cloudStopped\(|\bstopped\(\))[^;]*\?\?\s*g?l10n\.' + name + r'$');
      final found = <String, ({int asked, int bare})>{};
      for (final MapEntry(key: path, value: text) in sources.entries) {
        for (final match in use.allMatches(text)) {
          expect(files.keys, contains(path), reason: '$name is shown in $path, which is not on the list');
          // The statement it stands in: from the start of the line before,
          // where a long call was wrapped.
          final from = text.lastIndexOf('\n', text.lastIndexOf('\n', match.start) - 1) + 1;
          final guarded = asked.hasMatch(text.substring(from, match.end));
          final so = found[path] ?? (asked: 0, bare: 0);
          found[path] = guarded ? (asked: so.asked + 1, bare: so.bare) : (asked: so.asked, bare: so.bare + 1);
        }
      }
      expect(found, files, reason: '$name: where it is shown, and how');
    }
  });

  test('the two places an action on the signed-in devices fails both ask, one with the status it was answered with',
      () {
    final text = sources[profile]!;
    expect('cloudStopped(l10n, e, status: e.status) ?? l10n.devicesActionFailed'.allMatches(text), hasLength(1));
    expect('cloudStopped(l10n, e) ?? l10n.devicesActionFailed'.allMatches(text), hasLength(1));
  });

  test('a code that could not be redeemed because the service answered with a fault of its own says that', () {
    final text = sources['lib/services/redeem_service.dart']!;
    // What is said of a refusal is one function's, and a fault of the
    // service's own is the first thing it asks about; the service hands it
    // every answer that is no success.
    expect(
        text,
        contains('String redeemRefusal(AppLocalizations l10n, int status, Map<String, dynamic> body) =>\n'
            "    cloudStopped(l10n, 'HTTP \$status', status: status) ??\n"));
    expect('return RedeemResult(ok: false, message: redeemRefusal(gl10n, resp.statusCode, body));'.allMatches(text),
        hasLength(1));
  });

  test('a sync store that could not be asked is said as what it is, whichever screen asked', () {
    const asked = {
      // (The third: the question after a store did not take a new recovery key.)
      profile: ['_backend', 3],
      'lib/ui/screens/profile/recovery_key_check.dart': ['backend', 1],
    };
    for (final MapEntry(key: path, value: [backend as String, times as int]) in asked.entries) {
      expect('SyncFailure.ofStore(e, hosted: $backend.kind.isHosted).message'.allMatches(sources[path]!),
          hasLength(times),
          reason: path);
    }
    // The sentences that said "couldn't reach the sync server, check your
    // connection" for every one of those are gone, in every language.
    for (final f in Directory('lib/l10n').listSync()) {
      if (f is! File || !f.path.endsWith('.arb')) continue;
      final words = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      for (final gone in ['profileSyncServerUnreachable', 'syncSetupServerUnreachable']) {
        expect(words.containsKey(gone), isFalse, reason: '$gone in ${f.path}');
      }
    }
  });

  test('what stopped a request is carried to the screen that says so, at every one of these places', () {
    /// How often [call] stands in [path].
    int times(String path, String call) => call.allMatches(sources[path]!).length;

    // Deleting the account, and resetting cloud sync.
    expect(times(profile, 'accountNotDeletedText(l10n, cause)'), 1);
    expect(
        times(profile,
            '_deletionFailureText(l10n, code, somethingDeleted, orchards: orchards, cause: cause, keptUntil: keptUntil)'),
        1);
    expect(times('lib/services/account/account_deletion_flow.dart', 'cause: e.stopped'), 2);
    expect(times('lib/ui/screens/sync/sync_reset_ui.dart', 'syncResetFailureText(l10n, code, cause: cause)'), 1);
    expect(times('lib/services/account/sync_reset_flow.dart', 'cause: e.stopped'), 1);
    // The second step of a sign-in, on both of its forms.
    expect(
        times('lib/ui/screens/profile/widgets/two_step_dialogs.dart',
            'secondStepErrorText(l10n, error, widget.challenge.cause)'),
        2);
    // A share that does not start, or more people who cannot be asked: one
    // function says it for the three places that show it.
    const share = 'shareStartFailureText(';
    expect(times('lib/features/orchards/watch/watch_gate.dart', share), 1);
    expect(
        times('lib/features/orchards/watch/watch_gate.dart',
            'shareStartFailureText(gl10n, e, notReady: gl10n.watchedNotReady, answersNow: true)'),
        1,
        reason: 'the gate has asked the service since, and it answered');
    expect(
        times('lib/ui/screens/sharing/share_session_dialog.dart',
            'shareStartFailureText(l10n, e, notReady: l10n.shareFailedNotReady)'),
        1);
    expect(
        times('lib/ui/screens/sharing/watch_ui.dart', 'shareStartFailureText(l10n, e, notReady: l10n.watchedNotReady)'),
        1);
    for (final path in sources.keys) {
      if (path == 'lib/features/sharing/share_providers.dart') continue;
      final allowed = const {
        'lib/features/orchards/watch/watch_gate.dart',
        'lib/ui/screens/sharing/share_session_dialog.dart',
        'lib/ui/screens/sharing/watch_ui.dart',
      }.contains(path);
      expect(times(path, share), allowed ? 1 : 0, reason: path);
    }
    // The tickets, in the list and on a ticket's own page.
    expect(times('lib/ui/screens/help/tickets_screen.dart', 'ticketsStaleText(l10n, _stopped)'), 1);
    // A ticket's own page, as it stands in the Help panel and as it stands in
    // the Support Hub.
    expect(times('lib/ui/screens/help/ticket_detail_screen.dart', 'ticketsStaleText(l10n, _stopped)'), 2);
    expect(times('lib/ui/screens/help/support_hub_page.dart', 'ticketsStaleText(l10n, _stopped)'), 1);
    expect(times('lib/ui/screens/help/support_hub_page.dart', 'await checkTickets(ref)'), 1);
    expect(times('lib/ui/screens/help/tickets_screen.dart', 'await checkTickets(ref)'), 1);
    expect(times('lib/ui/screens/help/tickets_screen.dart', 'reached ? null : service.readStopped'), 1);
    expect(times('lib/ui/screens/help/ticket_detail_screen.dart', 'stopped = service.readStopped'), 1);
  });
}
