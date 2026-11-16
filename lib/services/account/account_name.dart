import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/type_name.dart';

// The account's name (password accounts have none,
// and nothing could give them one). A phone or tablet holds a Firebase user and
// sets it there: the next ID token carries it, and ZestSSH Cloud takes the name
// from the token. A computer signs in through the browser and has no Firebase
// user, so it asks ZestSSH Cloud:
//
//   PATCH /v1/account/profile   {"display_name": "..."}  ->  {"display_name": "..."}
//
// which sets it on the account and on Firebase (a later sign-in's token would
// put the old name back otherwise). It answers 400 invalid-name for a name it
// will not take, and 502 identity-update-failed where it could not reach
// Firebase: nothing has changed then.

/// The longest name the app sends; what ZestSSH Cloud holds to as well.
const int kAccountNameMax = 100;

/// What a name may not hold: control characters, and what is invisible or changes
/// the direction of what is drawn after it, which can make one name read as
/// another. What ZestSSH Cloud takes out of one (routes/account.js), and the C1
/// controls: a phone sets the name on Firebase, with no server to clean it.
final RegExp kAccountNameRefuses = RegExp(
  '[\x00-\x1f\x7f-\x9f\u00ad\u061c\u200b-\u200f\u2028-\u202e\u2060-\u206f\ufeff]',
);

/// [typed] as the account's name: what it may not hold gone, on one line.
String cleanAccountName(String typed) =>
    typed.replaceAll(RegExp(r'[\r\n\t]+'), ' ').replaceAll(kAccountNameRefuses, '').trim();

/// A name refused or not delivered by ZestSSH Cloud.
class AccountNameRefusal implements Exception, HasTypeName {
  const AccountNameRefusal(this.status, {this.code});

  final int status;
  final String? code;

  /// ZestSSH Cloud will not take the name.
  bool get invalidName => code == 'invalid-name';

  /// ZestSSH Cloud could not reach the sign-in service: nothing has changed.
  bool get signInServiceDown => code == 'identity-update-failed';

  @override
  String get typeName => 'AccountNameRefusal';

  @override
  String toString() => 'AccountNameRefusal($status${code == null ? '' : ', $code'})';
}

/// PATCH /v1/account/profile with this device's sign-in.
class AccountNameApi {
  AccountNameApi({http.Client? client, String? baseUrl, required this.bearer})
      : _client = client ?? PinnedHttpClient.client,
        _base = baseUrl ?? _defaultBase;

  static String get _defaultBase => kZestApiBase;

  static const _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String _base;
  final Future<String?> Function() bearer;

  /// Sets the account's name; the name ZestSSH Cloud kept.
  Future<String> setName(String name) async {
    final token = await bearer();
    if (token == null) throw const AccountNameRefusal(401, code: 'signed-out');
    final response = await _client
        .patch(
          Uri.parse('$_base/account/profile'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
            ...DeviceSessionHeader.headers,
          },
          body: jsonEncode({'display_name': name}),
        )
        .timeout(_timeout);
    Map<String, dynamic> body = const {};
    try {
      final decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) body = decoded;
    } on FormatException {
      // No JSON: what the status says is all there is.
    }
    if (response.statusCode != 200) {
      throw AccountNameRefusal(response.statusCode, code: body['code'] as String?);
    }
    final kept = body['display_name'];
    return kept is String && kept.isNotEmpty ? kept : name;
  }
}

/// ZestSSH Cloud's route for a computer's sign-in (its session token).
final accountNameApiProvider = Provider<AccountNameApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return AccountNameApi(bearer: () => AccountSecret.sessionToken.read(storage));
});

/// Sets the signed-in account's name, on this device at once: the Firebase
/// user's where there is one, else through ZestSSH Cloud and the session kept
/// on this computer. A test's own stands in.
final accountNameChangerProvider = Provider<Future<void> Function(String typed)>((ref) {
  return (typed) async {
    final name = cleanAccountName(typed);
    if (name.isEmpty) throw const AccountNameRefusal(400, code: 'invalid-name');
    final firebase = AuthService.currentUser;
    if (firebase != null) {
      await firebase.updateDisplayName(name);
      await firebase.reload();
      // The token ZestSSH Cloud reads the name from, and the app's own view:
      // Firebase's sign-in stream says nothing of a change of name.
      await firebase.getIdToken(true);
      ref.invalidate(authStateProvider);
      return;
    }
    final kept = await ref.read(accountNameApiProvider).setName(name);
    await ref.read(secureStorageProvider).write(key: 'session_name', value: kept);
    final session = ref.read(desktopSessionProvider);
    if (session != null) {
      ref.read(desktopSessionProvider.notifier).state = UserProfile(
        uid: session.uid,
        email: session.email,
        displayName: kept,
        photoUrl: session.photoUrl,
      );
    }
  };
});
