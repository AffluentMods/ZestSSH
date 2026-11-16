import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/utils/type_name.dart';

/// Why the server did not delete the account, as a stable code the UI maps
/// to its own words.
class AccountDeletionException implements Exception, HasTypeName {
  const AccountDeletionException(this.code, this.detail,
      {this.dataDeleted = false, this.orchards = const [], this.cause, this.keptUntil});

  /// For `sync-reset-kept`: until when the cloud copy that Reset cloud sync
  /// set aside is kept, the day from which the account can be deleted. The
  /// server keeps that copy so that a reset made by someone else can be
  /// undone, and deleting the account would delete it with it.
  final DateTime? keptUntil;

  /// What was caught, where the request got no answer (`network`).
  final Object? cause;

  /// What stopped the request, for whoever says how ZestSSH Cloud stands
  /// (cloudStopped): what was caught, or the server's answer with its HTTP
  /// status in it.
  Object get stopped => cause ?? detail;

  /// `recent-sign-in-required`, `account-mismatch`, `identity-delete-failed`,
  /// `sole-owner`, `sync-reset-kept`, `server-outdated`, `server-error` or
  /// `network`.
  final String code;

  /// For `sole-owner`: the Orchards the account is the only owner of while
  /// others are in them (ids), which it must hand over first.
  final List<String> orchards;

  /// The server's message or the underlying error, for the log only.
  final String detail;

  /// True when the server had already deleted the account's data before the
  /// failure (the sign-in identity could not be removed).
  final bool dataDeleted;

  @override
  String toString() => 'AccountDeletionException($code: $detail)';

  @override
  String get typeName => 'AccountDeletionException';
}

/// Synced data the hosted account holds, and what the app needs to derive
/// the sync password's verification value for it.
class HostedSyncData {
  const HostedSyncData({required this.salt, this.argon2Params});

  final Uint8List salt;
  final Map<String, dynamic>? argon2Params;
}

/// The hosted server's account-deletion endpoints (api.zestssh.com).
///
/// [deleteNow] needs a token from a sign-in made moments ago: the server
/// refuses an older one. On success the server has deleted the account row,
/// everything stored under it (the synced data, logs, avatar) and the
/// Firebase sign-in identity, and checked that none of it is left.
class AccountDeletionApi {
  AccountDeletionApi({http.Client? client, String? baseUrl, this.now})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  /// The time now (a fixed one in tests).
  final DateTime Function()? now;

  static String get _defaultBase => kZestApiBase;

  final http.Client _client;
  final String _base;

  /// Deletes the account the fresh [token] belongs to. [confirmUid] is the
  /// account the person chose to delete; the server refuses when the token
  /// belongs to another one. Throws [AccountDeletionException].
  ///
  /// When the account holds synced data, [passwordHash] (the sync password's
  /// verification value) is required as well; see [hostedSyncData].
  Future<void> deleteNow({
    required String token,
    required String confirmUid,
    Uint8List? passwordHash,
  }) async {
    final http.Response response;
    try {
      response = await _client
          .post(
            Uri.parse('$_base/account/delete'),
            headers: {
              'Authorization': 'Bearer $token',
              ...DeviceSessionHeader.headers,
              'Content-Type': 'application/json',
            },
            body: jsonEncode({
              'confirm_uid': confirmUid,
              if (passwordHash != null)
                'password_hash': base64Encode(passwordHash),
            }),
          )
          .timeout(const Duration(seconds: 45));
    } catch (e) {
      throw AccountDeletionException('network', e.toString(), cause: e);
    }

    final body = _decode(response.body);
    if (response.statusCode == 200) {
      final deleted = body['deleted'];
      final complete = body['success'] == true &&
          deleted is Map &&
          deleted['account'] == true &&
          deleted['sync_data'] == true &&
          deleted['sign_in'] == true;
      if (complete) return;
      // A server from before immediate deletion answers 200 after only
      // scheduling a deletion: not what the person asked for.
      throw const AccountDeletionException(
          'server-outdated', 'HTTP 200 without a deletion report');
    }
    final error = body['error'] is String ? body['error'] as String : '';
    // The same kind of server refuses a request without the old field.
    if (response.statusCode == 400 && error == 'Missing password_hash') {
      throw AccountDeletionException('server-outdated', error);
    }
    final orchards = body['orchards'];
    final keptUntil = body['kept_until'];
    throw AccountDeletionException(
      body['code'] is String ? body['code'] as String : 'server-error',
      'HTTP ${response.statusCode}: $error',
      dataDeleted: body['data_deleted'] == true,
      orchards: [
        if (orchards is List)
          for (final o in orchards)
            if (o is String) o,
      ],
      keptUntil: keptUntil is String ? DateTime.tryParse(keptUntil) : null,
    );
  }

  /// The synced data ZestSSH Cloud holds for the account [token] belongs to,
  /// or null when it holds none. Throws [AccountDeletionException], with
  /// `sync-reset-kept` while a copy Reset cloud sync set aside is kept (the
  /// server would refuse the deletion until then).
  Future<HostedSyncData?> hostedSyncData(String token) async {
    final http.Response response;
    try {
      response = await _client.get(
        Uri.parse('$_base/account'),
        headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw AccountDeletionException('network', e.toString(), cause: e);
    }
    if (response.statusCode != 200) {
      throw AccountDeletionException(
          'server-error', 'HTTP ${response.statusCode} reading the account');
    }
    final body = _decode(response.body);
    // A cloud copy Reset cloud sync set aside is kept its days, and the
    // server deletes the account only after them: said now, before a sync
    // password is asked for or anything (a store of one's own) is deleted.
    final resetAt = body['sync_reset_at'] is String ? DateTime.tryParse(body['sync_reset_at'] as String) : null;
    final keptDays = body['sync_reset_kept_days'];
    if (resetAt != null && keptDays is int) {
      final keptUntil = resetAt.add(Duration(days: keptDays));
      if (keptUntil.isAfter(now?.call() ?? DateTime.now())) {
        throw AccountDeletionException('sync-reset-kept', 'a reset copy is kept until $keptUntil',
            keptUntil: keptUntil);
      }
    }
    if (body['has_sync_data'] != true) return null;
    final salt = body['sync_salt'];
    if (salt is! String) {
      throw const AccountDeletionException(
          'server-error', 'synced data without a salt');
    }
    final params = body['sync_argon2_params'];
    return HostedSyncData(
      salt: base64Decode(salt),
      argon2Params: params is Map<String, dynamic> ? params : null,
    );
  }

  /// Whether the server has stopped knowing the account [token] belongs to:
  /// true only when it answers that there is no such account (401 with code
  /// `account-not-found`, or 404), false while it still serves it. Any other
  /// answer, an unrelated 401 included, throws [AccountDeletionException].
  Future<bool> isGone(String token) async {
    final http.Response response;
    try {
      response = await _client.get(
        Uri.parse('$_base/account'),
        headers: {'Authorization': 'Bearer $token', ...DeviceSessionHeader.headers},
      ).timeout(const Duration(seconds: 30));
    } catch (e) {
      throw AccountDeletionException('network', e.toString(), cause: e);
    }
    if (response.statusCode == 404) return true;
    if (response.statusCode == 401 &&
        _decode(response.body)['code'] == 'account-not-found') {
      return true;
    }
    if (response.statusCode == 200) return false;
    throw AccountDeletionException(
        'server-error', 'HTTP ${response.statusCode} checking the account');
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
