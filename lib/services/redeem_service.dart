import 'dart:convert';

import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/account_bearer.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/services/account/device_sessions.dart';

/// Outcome of a redeem attempt. [ok] true means the licence was applied (or was
/// already applied); [message] is user-facing either way.
class RedeemResult {
  final bool ok;
  final List<String> granted;
  final bool alreadyRedeemed;
  final String message;

  /// The code gives a team seats, not this account anything: [code] goes to
  /// a team (one this account owns, or a new one), not under the field.
  final bool teamCode;
  final String code;

  const RedeemResult({
    required this.ok,
    this.granted = const [],
    this.alreadyRedeemed = false,
    required this.message,
    this.teamCode = false,
    this.code = '',
  });
}

/// What is said of a code that ZestSSH Cloud did not redeem, having
/// answered with [status] and [body]. A fault of the service's own is said
/// as that, with its code, and not as a code that could not be redeemed; a
/// code that gives a team seats is told where it goes, in the app's
/// language, and so is redeeming paused for everyone after too many wrong
/// codes ('redeem-paused', a 429 of its own); anything else is the
/// service's own sentence.
String redeemRefusal(AppLocalizations l10n, int status, Map<String, dynamic> body) =>
    cloudStopped(l10n, 'HTTP $status', status: status) ??
    (body['code'] == 'redeem-paused' ? l10n.redeemPaused : null) ??
    (body['code'] == 'team-code' ? l10n.redeemSvcTeamCode : null) ??
    (body['error'] is String ? body['error'] as String : null) ??
    l10n.redeemSvcCouldNotRedeem;

/// Redeems a licence/giveaway code against the hosted backend (POST
/// /v1/redeem). Authenticated with the ZestSSH account bearer (mobile Firebase
/// ID token, or the desktop session JWT) - the same credential rule as avatar
/// upload, never sent anywhere but api.zestssh.com. The grant itself is a
/// RevenueCat lifetime entitlement applied server-side, so after a success the
/// caller should force-refresh the entitlement providers.
class RedeemService {
  static String get _base => kZestApiBase;

  static Future<RedeemResult> redeem(String code) async {
    final trimmed = code.trim();
    if (trimmed.isEmpty) {
      return RedeemResult(ok: false, message: gl10n.redeemSvcEnterCode);
    }

    final token = await accountBearer();
    if (token == null) {
      return RedeemResult(
        ok: false,
        message: gl10n.redeemSvcSignInToRedeem,
      );
    }

    try {
      final resp = await PinnedHttpClient.client.post(
        Uri.parse('$_base/redeem'),
        headers: {
          'Authorization': 'Bearer $token',
          ...DeviceSessionHeader.headers,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'code': trimmed}),
      // A time of its own, as every other ZestSSH Cloud call has: a server
      // that never answered held Redeem for good (found in a code audit).
      ).timeout(const Duration(seconds: 30));

      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(resp.body);
        body = decoded is Map<String, dynamic> ? decoded : const {};
      } catch (_) {
        body = const {};
      }

      if (resp.statusCode == 200) {
        return RedeemResult(
          ok: true,
          granted: (body['granted'] as List?)
                  ?.map((e) => e.toString())
                  .toList() ??
              const [],
          alreadyRedeemed: body['alreadyRedeemed'] == true,
          message: (body['message'] as String?) ??
              gl10n.redeemSvcLicenceApplied,
        );
      }

      if (resp.statusCode == 409 && body['code'] == 'team-code') {
        return RedeemResult(ok: false, teamCode: true, code: trimmed, message: redeemRefusal(gl10n, resp.statusCode, body));
      }
      return RedeemResult(ok: false, message: redeemRefusal(gl10n, resp.statusCode, body));
    } catch (e) {
      AppLogger.warning('Redeem failed: $e');
      return RedeemResult(
        ok: false,
        // How ZestSSH Cloud stands, where it or the way to it was the
        // reason.
        message: cloudStopped(gl10n, e) ?? gl10n.redeemSvcCouldNotReachServer,
      );
    }
  }
}
