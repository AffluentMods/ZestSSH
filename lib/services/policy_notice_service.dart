import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';

/// Bundled policy version.
///
/// This is a monotonically increasing integer. **Bump it by one whenever the
/// Privacy Policy / Terms of Service date changes** (and update
/// [kPolicyEffectiveDate] + the notice copy below to match). Bumping it makes
/// every existing user - who previously acknowledged the older policy - see
/// the one-time "policies updated" notice again on their next launch.
///
/// Version 1: August 18, 2026. Version 2: September 22, 2026 (the device list,
/// the hosted server keeps no activity log, and two-step sign-in's recovery
/// codes, kept as keyed hashes). Version 3: the 3.0 legal pack (drafted
/// October 23, 2026: a rewritten privacy policy and terms, an acceptable use
/// policy, a data processing addendum, the sub-processors and the account
/// deletion page), in effect from
/// October 23, 2026.
const int kPolicyVersion = 3;

/// Human-readable effective date shown in the notice copy. Keep in sync with
/// [kPolicyVersion] whenever the policies change, and with LEGAL_EFFECTIVE of
/// the website (ZestSSH-Website, src/lib/legal/meta.js, '23 October 2026'),
/// written here the app's way.
///
/// Empty would mean no day is chosen: the notice then says the policies are in
/// effect from this version of ZestSSH (policyUpdatedBodyThisVersion).
const String kPolicyEffectiveDate = 'October 23, 2026';

/// Public Privacy Policy URL opened by the notice's "View" action.
String get kPolicyUrl => kZestPrivacyUrl;

/// SharedPreferences key holding the highest policy version the user has
/// acknowledged (an int). Absent = never acknowledged on this install.
const String _kAckKey = 'acked_policy_version';

/// The notice's words: the effective day when [effectiveDate] names one, and
/// "in effect from this version" when it is empty (see [kPolicyEffectiveDate]).
String policyNoticeBody(AppLocalizations l10n, String effectiveDate) => effectiveDate.trim().isEmpty
    ? l10n.policyUpdatedBodyThisVersion
    : l10n.policyUpdatedBody(effectiveDate);

/// One-time in-app notice that the Privacy Policy & Terms were updated.
///
/// Shown once to users who are *upgrading* across a policy change (they last
/// accepted an older policy version). Genuine fresh installs never see it -
/// a brand-new user is deemed to accept the current policy by installing.
class PolicyNoticeService {
  const PolicyNoticeService._();

  /// Evaluate whether to surface the policy-update notice and, if so, show it.
  ///
  /// Decision logic:
  ///  - stored ack >= [kPolicyVersion] → already up to date, do nothing.
  ///  - no stored ack AND no existing user data (zero saved connections) →
  ///    genuine fresh install; silently record acceptance of the current
  ///    policy, no notice.
  ///  - otherwise (stored ack < [kPolicyVersion], OR no stored ack but the user
  ///    already has saved connections from a pre-versioning build) → this is an
  ///    upgrade across a policy change → show the one-time notice.
  ///
  /// Fully guarded: any failure is logged and swallowed so startup never
  /// blocks or crashes on account of this notice.
  static Future<void> maybeShow(WidgetRef ref) async {
    try {
      final prefs = ref.read(sharedPreferencesProvider);
      final stored = prefs.getInt(_kAckKey);

      // Already acknowledged the current (or a newer) policy - nothing to do.
      if (stored != null && stored >= kPolicyVersion) return;

      // No prior acknowledgement on this install: distinguish a genuine fresh
      // install (no user data yet) from an upgrade off a pre-versioning build.
      if (stored == null) {
        final connectionCount =
            await ref.read(connectionsDaoProvider).countAll();
        if (connectionCount == 0) {
          // Brand-new user - installing accepts the current policy. Record it
          // silently so the notice never fires for them.
          await prefs.setInt(_kAckKey, kPolicyVersion);
          return;
        }
      }

      // A build with no policy page of its own says nothing of one: the
      // release's policy is not this build's.
      if (kPolicyUrl == '') return;

      // Upgrade across a policy change → show the notice exactly once.
      // Persist the acknowledgement up front (before showing), so the notice
      // can never re-appear even if the app is killed before the user dismisses
      // it. Tapping "View" or closing the toast are both non-essential from a
      // "show once" standpoint once this write lands.
      await prefs.setInt(_kAckKey, kPolicyVersion);

      ref.read(notificationCenterProvider.notifier).show(
            AppNotification(
              id: 'policy_update_$kPolicyVersion',
              title: gl10n.policyUpdatedTitle,
              body: policyNoticeBody(gl10n, kPolicyEffectiveDate),
              severity: NotificationSeverity.warning,
              // Sticky - stays until the user closes it, so a one-time legal
              // notice isn't missed by an 8-second auto-dismiss.
              dismissAfter: Duration.zero,
              actionLabel: gl10n.shareInviteNoticeView,
              onAction: _openPolicy,
            ),
          );
    } catch (e) {
      AppLogger.error('Policy notice check failed', e);
    }
  }

  static Future<void> _openPolicy() async {
    try {
      await launchUrl(
        Uri.parse(kPolicyUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      // Fall back to the platform default handler, then give up quietly.
      try {
        await launchUrl(Uri.parse(kPolicyUrl));
      } catch (_) {/* swallow - nothing more we can safely do */}
    }
  }
}
