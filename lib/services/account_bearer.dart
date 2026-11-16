import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/keychain.dart';

FlutterSecureStorage get _storage => appKeychain;

/// The account bearer when the user happens to be signed in: the mobile
/// Firebase ID token, else the desktop session JWT. Null when signed out.
/// Never throws. Mirrors the avatar upload's credential rule: this is only
/// ever sent to api.zestssh.com.
Future<String?> accountBearer({FlutterSecureStorage? storage}) async {
  try {
    var token = await AuthService.getIdToken(forceRefresh: false);
    token ??= await AccountSecret.sessionToken.read(storage ?? _storage);
    return token;
  } catch (_) {
    return null;
  }
}
