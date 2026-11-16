import 'dart:convert';

import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/utils/type_name.dart';

// A computer's fresh sign-in for a change to two-step sign-in (the two-step
// contract, sections 3.1 and 7.12). A computer holds no Firebase of its own,
// and some changes need what only Firebase gives: a fresh ID token, with
// which ZestSSH Cloud asks Firebase to enrol the bridge of the account's
// first passkey, or to withdraw the authenticator while passkeys stay. The
// browser signs the person in again (purpose=id-token) and hands this app a
// one-time code, which it trades with its secret within two minutes. The ID
// token is kept in memory for that one change, checked to be the signed-in
// account's, and dropped with it; it is never written anywhere, logged or
// shown.

/// The ID token handed over was another account's than the one signed in
/// here: the person signed in with another in the browser.
class HandoffWrongAccount implements Exception, HasTypeName {
  const HandoffWrongAccount();

  @override
  String toString() => 'The browser signed in to another account';

  @override
  String get typeName => 'HandoffWrongAccount';
}

/// The Firebase account a Firebase ID token is for (its user_id claim, or
/// sub), or null for what is not one. Read only to check it is the signed-in
/// account's: ZestSSH Cloud checks the token itself.
String? idTokenUid(String token) {
  final parts = token.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    if (payload is! Map) return null;
    final uid = payload['user_id'] ?? payload['sub'];
    return uid is String && uid.isNotEmpty ? uid : null;
  } catch (_) {
    return null;
  }
}

/// A fresh ID token for one change on a computer: the browser's hand-off,
/// traded at once at ZestSSH Cloud ([api]) and checked to be the account
/// [accountUid]'s. Throws [HandoffWrongAccount] for another account's, a
/// [TwoStepRefusal] where ZestSSH Cloud refuses the code (it ran out after
/// two minutes, or was used), and what the browser sign-in throws
/// (BrowserSignInCancelled, a TimeoutException). [handoff] and [uidOf]:
/// the browser and the token's reader (tests).
Future<String> handedIdToken({
  required TwoStepApi api,
  required String accountUid,
  Future<({String code, String verifier, String? uid})> Function()? handoff,
  String? Function(String token)? uidOf,
}) async {
  final back = await (handoff ?? DesktopBrowserSignIn.idTokenHandoff)();
  // The website says whose sign-in it handed over: another account's is
  // not traded at all.
  if (back.uid != null && back.uid!.isNotEmpty && back.uid != accountUid) throw const HandoffWrongAccount();
  final String token;
  try {
    token = await api.redeemHandoff(code: back.code, verifier: back.verifier);
  } on TwoStepRefusal catch (e) {
    if (e.code == 'account-mismatch') throw const HandoffWrongAccount();
    rethrow;
  }
  if ((uidOf ?? idTokenUid)(token) != accountUid) throw const HandoffWrongAccount();
  return token;
}
