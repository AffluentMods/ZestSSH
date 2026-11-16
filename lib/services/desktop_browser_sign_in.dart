import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart' show SsoTestSignIn, isOrchardSsoProvider;
import 'package:zestssh/services/away_for_sign_in.dart';
import 'package:zestssh/services/browser_sign_in_code.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/sign_in_code.dart';

/// What a sign-in in the browser on a computer hands back: the session, and
/// what ZestSSH Cloud and the website say of the account.
class BrowserSession {
  const BrowserSession({required this.token, this.email, this.name, this.picture, this.uid});

  /// The ZestSSH session token.
  final String token;
  final String? email;
  final String? name;
  final String? picture;

  /// The Firebase UID of the account signed in to.
  final String? uid;
}

/// What the browser sign-in hands back.
class BrowserSignInResult {
  const BrowserSignInResult({
    required this.token,
    required this.uid,
    required this.email,
  });

  /// The ZestSSH session token the website exchanged for this sign-in. It
  /// records when the person signed in, which account deletion checks.
  final String token;

  /// The Firebase UID of the account signed in to.
  final String uid;

  /// Its email, for matching a session saved before the UID was.
  final String email;
}

/// A sign-in in the browser on a computer: the website signs in and sends
/// the browser back to this app (a server on 127.0.0.1 for two minutes,
/// [DesktopAuthServer]) with the link's CSRF state. The link carries this
/// app's challenge, and the browser comes back with a one-time code that
/// only this app, with its secret, can trade for the session (N5,
/// [SignInCode]): the session token used to come back in the address
/// itself, and stayed in the browser's history.
class DesktopBrowserSignIn {
  DesktopBrowserSignIn._();

  /// The sign-in page this app is waiting on, while it waits: for Open
  /// again and Copy link (BrowserSignInHelp). Null otherwise.
  static final pending = ValueNotifier<BrowserSignInPage?>(null);

  /// The listener of the sign-in waited on, for [cancel]. One at a time: a wait that
  /// starts ends the one before it ([_waitOn]), whose page, shown nowhere any more and
  /// out of reach of [cancel], would still sign in up to [waitFor] later, closing
  /// whatever is open by then.
  static DesktopAuthServer? _waiting;

  /// Stops waiting for the browser: the sign-in that waits throws
  /// [BrowserSignInCancelled]. Nothing while none waits.
  static void cancel() {
    _waiting?.cancel();
    _waiting = null;
  }

  static void _waitOn(DesktopAuthServer server) {
    cancel();
    pending.value = null;
    _waiting = server;
  }

  /// The wait on [server] is over. The page of a later one stays up.
  static void _waitOver(DesktopAuthServer server) {
    if (identical(_waiting, server)) _waiting = null;
    if (_waiting == null) pending.value = null;
  }

  /// How long the browser is given to come back: long enough for a
  /// company sign-in with its second factor, or for making an account
  /// and confirming its address. (It was two minutes, and an Okta sign-in
  /// came back to a listener that had gone: 28 October 2026.)
  static const waitFor = Duration(minutes: 15);

  static String get _authUrl => kZestAuthPage;

  /// The sign-in page's address for [nonce], this app's [challenge] and
  /// [callbackUrl], with [extra] query parameters. code=1 tells the page that
  /// this app shows the challenge's code ([BrowserSignInPage.signInCode]),
  /// which it asks for before anything is signed in; it tells an app
  /// without the mark to update.
  static String authUrl(String nonce, String challenge, String callbackUrl, [Map<String, String> extra = const {}]) {
    final more = [for (final e in extra.entries) '&${e.key}=${Uri.encodeComponent(e.value)}'].join();
    return '$_authUrl&state=$nonce&challenge=$challenge&code=1&redirect=${Uri.encodeComponent(callbackUrl)}$more';
  }

  /// A new CSRF state for the link.
  static String _nonce() {
    final random = Random.secure();
    return List.generate(32, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
  }

  static Future<void> _launch(Uri page) async {
    var opened = false;
    try {
      opened = await launchUrl(page, mode: LaunchMode.externalApplication);
    } catch (_) {
      opened = false;
    }
    // Said at once where the system opened nothing.
    if (!opened && pending.value?.uri == page) pending.value = BrowserSignInPage(page, opened: false);
  }

  /// Opens the sign-in page with [extra] ([open]: in the default browser
  /// unless given) and waits for the browser to come back: what it came
  /// back with, and the secret of the challenge the link carried.
  static Future<(Map<String, String>, SignInCode)> _browse(
          Map<String, String> extra, Future<void> Function(Uri page)? open, {BrowserConfirm? confirm}) =>
      AwayForSignIn.during(() => _browseNow(extra, open, confirm));

  static Future<(Map<String, String>, SignInCode)> _browseNow(
      Map<String, String> extra, Future<void> Function(Uri page)? open, BrowserConfirm? confirm) async {
    final server = DesktopAuthServer();
    _waitOn(server);
    try {
      final secret = SignInCode.make();
      final nonce = _nonce();
      final callbackUrl = await server.start(nonce: nonce, timeout: waitFor);
      // Ended as its listener started: no page opens for it.
      if (!identical(_waiting, server)) throw const BrowserSignInCancelled();
      final page = Uri.parse('${authUrl(nonce, secret.challenge, callbackUrl, extra)}${confirm?.fragment ?? ''}');
      pending.value = BrowserSignInPage(page);
      await (open ?? _launch)(page);
      return (await server.waitForCallback(), secret);
    } finally {
      _waitOver(server);
      await server.stop();
    }
  }

  /// Signs in in the browser and returns the session the app trades the
  /// browser's code for, with the account ZestSSH Cloud says it is. A callback
  /// with no code is refused: it came back with a token and an account id of
  /// its own choosing, which anyone who reached this computer's loopback port
  /// could make up, and the account named opened with no sign-in of its own
  /// (found in a security review; every website
  /// since 3.0 sends a code to an app that sends a challenge, as this one
  /// always does). [sso] opens the page at "Sign in
  /// with SSO" (3.0), [create] at Create an account (the welcome
  /// screen's button), and with [confirm] says it is to confirm
  /// it is the person. Throws a TimeoutException when the browser
  /// does not come back within two minutes, an [AuthCallbackError] when it
  /// comes back with neither, [SignInCodeRefused] when ZestSSH Cloud does not
  /// take the code, and what [client] throws when ZestSSH Cloud cannot be
  /// reached.
  static Future<BrowserSession> session({
    bool sso = false,
    bool create = false,
    BrowserConfirm? confirm,
    Future<void> Function(Uri page)? open,
    http.Client? client,
    String? baseUrl,
  }) async {
    final (back, secret) = await _browse({if (sso) 'sso': '1', if (create) 'create': '1'}, open, confirm: confirm);
    final code = back['code'];
    if (code == null) throw const AuthCallbackError(AuthCallbackErrorKind.missingToken);
    final traded = await secret.redeem(code, client: client, baseUrl: baseUrl);
    // ZestSSH Cloud's word on the account, which goes with the token: never the
    // callback's, which whoever answered at the loopback port could have written.
    return BrowserSession(
      token: traded.token,
      email: traded.user['email'] ?? back['email'],
      name: traded.user['name'] ?? back['name'],
      picture: back['picture'],
      uid: traded.user['uid'],
    );
  }

  /// A sign-in in the browser that returns its result instead of signing
  /// the app in: used where the person must prove it is them right now,
  /// such as deleting the account. Throws as [session] does, and a
  /// StateError without an account id.
  static Future<BrowserSignInResult> run({
    bool sso = false,
    BrowserConfirm? confirm,
    Future<void> Function(Uri page)? open,
    http.Client? client,
    String? baseUrl,
  }) async {
    final signedIn = await session(sso: sso, confirm: confirm, open: open, client: client, baseUrl: baseUrl);
    final uid = signedIn.uid;
    if (uid == null || uid.isEmpty) {
      throw StateError('The sign-in did not return a session and account id');
    }
    return BrowserSignInResult(token: signedIn.token, uid: uid, email: signedIn.email ?? '');
  }

  /// A fresh sign-in handed to this app for a change on a computer
  /// (purpose=id-token; the two-step contract, sections 3.1 and 7.12): the
  /// website signs the person in again, the second step included, and comes
  /// back to the loopback address with a one-time code for that sign-in
  /// (kind=id-token), which only this app, with its secret, trades at ZestSSH
  /// Cloud for the ID token, within two minutes (TwoStepApi.redeemHandoff).
  /// No session is made. Returns the code and the secret, with the account
  /// the website said. Throws as [session] does, and an [AuthCallbackError]
  /// when the browser came back with anything but such a code.
  static Future<({String code, String verifier, String? uid})> idTokenHandoff({
    BrowserConfirm? confirm,
    Future<void> Function(Uri page)? open,
  }) async {
    final (back, secret) = await _browse(const {'purpose': 'id-token'}, open, confirm: confirm);
    final code = back['code'];
    if (code == null || back['kind'] != 'id-token') {
      throw const AuthCallbackError(AuthCallbackErrorKind.missingToken);
    }
    return (code: code, verifier: secret.verifier, uid: back['uid']);
  }

  /// zestssh.com's security page, on the host the sign-in page is on (a
  /// staging build's AUTH_URL brings its own).
  static String get _securityPage {
    final auth = Uri.parse(_authUrl);
    return Uri(scheme: auth.scheme, host: auth.host, port: auth.hasPort ? auth.port : null, path: '/account/security')
        .toString();
  }

  /// The security page's address for adding a passkey for this app (the
  /// contract 7.12): [state] goes back with the result to [callbackUrl].
  static String addPasskeyUrl(String state, String callbackUrl) =>
      '$_securityPage?purpose=add-passkey&redirect=${Uri.encodeComponent(callbackUrl)}&state=$state';

  /// Adds a passkey in the browser, on a computer whose system makes none
  /// for the app (Linux, the Mac): zestssh.com's security page signs the
  /// person in, runs the passkey's ceremony (a security key, a phone by QR
  /// code, a password manager) and makes the recovery codes where it is the
  /// account's first second step, then comes back with done=1, or
  /// cancelled=1 when the person went back first. Nothing else comes back:
  /// the app reads what changed with its own sign-in. True when one was
  /// added. Throws as [session] does.
  static Future<bool> addPasskeyInBrowser({Future<void> Function(Uri page)? open}) =>
      AwayForSignIn.during(() => _addPasskeyInBrowser(open));

  static Future<bool> _addPasskeyInBrowser(Future<void> Function(Uri page)? open) async {
    final server = DesktopAuthServer();
    _waitOn(server);
    try {
      final nonce = _nonce();
      final callbackUrl = await server.start(nonce: nonce, timeout: waitFor);
      if (!identical(_waiting, server)) throw const BrowserSignInCancelled();
      final page = Uri.parse(addPasskeyUrl(nonce, callbackUrl));
      pending.value = BrowserSignInPage(page);
      await (open ?? _launch)(page);
      final back = await server.waitForCallback();
      return back['done'] == '1';
    } finally {
      _waitOver(server);
      await server.stop();
    }
  }

  /// An Orchard owner's test of its company sign-in [providerId]: the
  /// website signs in through it on a Firebase app of its own (so nothing
  /// is signed in there) and hands back a one-time code for that sign-in,
  /// which the test sends with this app's secret (N5): the ID token itself,
  /// good for an hour, used to stay in the browser's history. Same timeouts
  /// and errors as [session], and a StateError without a code.
  static Future<SsoTestSignIn> ssoTest(String providerId, {Future<void> Function(Uri page)? open}) async {
    if (!isOrchardSsoProvider(providerId)) throw ArgumentError.value(providerId, 'providerId');
    final (back, secret) = await _browse({'mode': 'sso-test', 'provider': providerId}, open);
    final code = back['code'];
    if (code == null) throw StateError('The test did not return a sign-in');
    return SsoTestSignIn.code(code, secret.verifier);
  }
}

/// What the sign-in page is told when it is to confirm it is the person
/// (from a security review): the account's address and how it signs in, after the #
/// of its address, so no server's log holds them. The page says its own words.
class BrowserConfirm {
  const BrowserConfirm(this.email, {this.way});

  /// The address, to fill in.
  final String email;

  /// How this sign-in came ('google.com', 'password', ...), to show that way
  /// first; null where it is not known.
  final String? way;

  /// What goes after the page's address.
  String get fragment =>
      '#confirm=1&email=${Uri.encodeComponent(email)}${way == null || way!.isEmpty ? '' : '&via=${Uri.encodeComponent(way!)}'}';
}

/// How a desktop session token says it signed in (the `provider` claim ZestSSH
/// Cloud puts in it), or null. Only a hint for which way to show first.
String? sessionSignInWay(String? sessionToken) {
  if (sessionToken == null) return null;
  final parts = sessionToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final provider = payload is Map ? payload['provider'] : null;
    return provider is String && provider.isNotEmpty ? provider : null;
  } catch (_) {
    return null;
  }
}

/// The company sign-in a desktop session token says it came through (the
/// `provider` claim ZestSSH Cloud puts in it), or null. Only a hint for
/// which way to offer signing in again: the server checks the token.
String? sessionSsoProvider(String? sessionToken) {
  if (sessionToken == null) return null;
  final parts = sessionToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final provider = payload is Map ? payload['provider'] : null;
    return provider is String && isOrchardSsoProvider(provider) ? provider : null;
  } catch (_) {
    return null;
  }
}

/// The account a desktop session token is for (the `firebaseUid` claim
/// ZestSSH Cloud puts in it), or null. For a computer whose session was
/// saved before its account id was: without it, the app took the session as
/// "an unknown account" and sent every account's team keys this device held
/// into its sync data (29 October 2026). The server checks the token itself.
String? sessionAccountUid(String? sessionToken) {
  if (sessionToken == null) return null;
  final parts = sessionToken.split('.');
  if (parts.length != 3) return null;
  try {
    final payload = jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))));
    final uid = payload is Map ? payload['firebaseUid'] : null;
    return uid is String && uid.isNotEmpty && uid.length <= 128 ? uid : null;
  } catch (_) {
    return null;
  }
}

/// The account id of the session this computer keeps for [token]: the one
/// saved with it, else the token's own, saved from now on (a session kept
/// before its id was). Null when neither says.
Future<String?> keptSessionUid(FlutterSecureStorage storage, String token) async {
  final saved = await storage.read(key: 'session_uid');
  if (saved != null && saved.isNotEmpty) return saved;
  final fromToken = sessionAccountUid(token);
  if (fromToken != null) await storage.write(key: 'session_uid', value: fromToken);
  return fromToken;
}

/// The browser sign-in page the app waits on, and whether the system said
/// it opened a browser for it.
class BrowserSignInPage {
  const BrowserSignInPage(this.uri, {this.opened = true});

  final Uri uri;
  final bool opened;

  /// The code the page asks for before it signs anything in: that of
  /// the challenge its link carries, read as the page reads it, in two groups
  /// of three. Null for a page that hands no sign-in to the app (adding a
  /// passkey), whose link has no challenge.
  String? get signInCode {
    final challenge = uri.queryParameters['challenge'];
    return challenge == null || challenge.isEmpty ? null : groupBrowserSignInCode(browserSignInCode(challenge));
  }
}
