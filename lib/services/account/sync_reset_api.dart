import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

/// Why ZestSSH Cloud did not reset the account's cloud sync, as a stable
/// code the UI maps to its own words.
class SyncResetException implements Exception, HasTypeName {
  const SyncResetException(this.code, this.detail, {this.cause});

  /// What was caught, where the request got no answer (`network`).
  final Object? cause;

  /// What stopped the request, for whoever says how ZestSSH Cloud stands
  /// (cloudStopped): what was caught, or the server's answer with its HTTP
  /// status in it.
  Object get stopped => cause ?? detail;

  /// `recent-sign-in-required`, `account-mismatch`, `server-outdated`,
  /// `server-error` or `network`.
  final String code;

  /// The server's message or the underlying error, for "Copy details" and
  /// the log only.
  final String detail;

  @override
  String toString() => 'SyncResetException($code: $detail)';

  @override
  String get typeName => 'SyncResetException';
}

/// What a reset did.
class SyncResetResult {
  const SyncResetResult({required this.hadData, required this.keptDays});

  /// Whether the account held a cloud copy. False when there was nothing to
  /// reset (it had been reset already, or sync was never set up).
  final bool hadData;

  /// For how many days ZestSSH Cloud keeps the copy it set aside before it
  /// deletes it.
  final int keptDays;
}

/// Resetting cloud sync on ZestSSH Cloud (api.zestssh.com).
///
/// A reset takes the account's cloud copy out of use, so that sync can be
/// set up again with a new master password. It is for the person who can no
/// longer prove the master password, so the server cannot ask for it: it
/// asks for a sign-in made moments ago instead, and it does not destroy the
/// copy but sets it aside for [SyncResetResult.keptDays] days. The account,
/// its purchases and its teams are not touched, and nothing on any device is.
class SyncResetApi {
  SyncResetApi({http.Client? client, String? baseUrl})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  final http.Client _client;
  final String _base;

  /// Resets cloud sync for the account the fresh [token] belongs to.
  /// [confirmUid] is the account the person chose; the server refuses when
  /// the token belongs to another one. Throws [SyncResetException].
  Future<SyncResetResult> reset({required String token, required String confirmUid}) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_base/account/reset-sync'),
            headers: {
              'Authorization': 'Bearer $token',
              ...DeviceSessionHeader.headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'confirm_uid': confirmUid}),
          )
          .timeout(const Duration(seconds: 45));
    } catch (e) {
      throw SyncResetException('network', e.toString(), cause: e);
    }

    final body = _decode(response.body);
    if (response.statusCode == 200 && body['success'] == true) {
      final kept = body['kept_days'];
      return SyncResetResult(
        hadData: body['had_data'] == true,
        keptDays: kept is int && kept > 0 ? kept : 0,
      );
    }
    final error = body['error'] is String ? body['error'] as String : '';
    // A server from before this could be asked for has no such address.
    if (response.statusCode == 404 || response.statusCode == 405) {
      throw SyncResetException('server-outdated', 'HTTP ${response.statusCode}: $error');
    }
    throw SyncResetException(
      body['code'] is String ? body['code'] as String : 'server-error',
      'HTTP ${response.statusCode}: $error',
    );
  }

  static Map<String, dynamic> _decode(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } catch (_) {
      return const {};
    }
  }
}
