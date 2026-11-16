import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart' show isOrchardSsoProvider;
import 'package:zestssh/services/account/sign_in_ways.dart' show SignInWay;
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// A sign-in for an address that already has a ZestSSH account that signs in
/// another way: Google, Apple, Microsoft or a company sign-in ("Sign in with
/// SSO", 3.0). One address is one account (3.0): the person signs
/// in to that account the usual way, then [AuthService.addSsoToAccount] adds
/// the way they tried to it.
class SsoAccountExists implements Exception, HasTypeName {
  const SsoAccountExists({required this.email, required this.credential});

  final String email;

  /// The way they tried, waiting to be added to the account.
  final AuthCredential credential;

  @override
  String toString() => 'SsoAccountExists';

  @override
  String get typeName => 'SsoAccountExists';
}

/// Handles Firebase Authentication with Google and Apple sign-in.
///
/// All auth state is managed by Firebase - we just provide sign-in flows
/// and expose the current user / JWT token.
///
/// On platforms where Firebase is not configured (e.g. desktop without
/// `flutterfire configure`), all methods gracefully return null / empty.
class AuthService {
  static bool? _firebaseAvailable;

  /// Whether Firebase was successfully initialised.
  static bool get isFirebaseAvailable {
    if (_firebaseAvailable != null) return _firebaseAvailable!;
    try {
      Firebase.app();
      _firebaseAvailable = true;
      return true;
    } catch (e) {
      AppLogger.warning('Firebase not available: $e');
      _firebaseAvailable = false;
      return false;
    }
  }

  static FirebaseAuth? get _authOrNull =>
      isFirebaseAvailable ? FirebaseAuth.instance : null;

  static FirebaseAuth get _auth => FirebaseAuth.instance;

  /// Current Firebase user (null if signed out or Firebase unavailable).
  static User? get currentUser => _authOrNull?.currentUser;

  /// Whether the user is currently signed in.
  static bool get isSignedIn => _authOrNull?.currentUser != null;

  /// Stream of auth state changes.
  /// Returns a stream of `null` if Firebase is not available.
  static Stream<User?> get authStateChanges =>
      _authOrNull?.authStateChanges() ?? Stream.value(null);

  static Future<void>? _firstReport;

  /// Done once Firebase has said who is signed in, or that nobody is. Until then
  /// [currentUser] reads as nobody, whoever it is: it restores a sign-in a while
  /// after the app starts.
  static Future<void> firstReport() =>
      _firstReport ??= isFirebaseAvailable ? authStateChanges.first.then((_) {}) : Future<void>.value();

  /// Get a fresh Firebase ID token for API calls.
  ///
  /// Always force-refreshes the token to avoid using a stale/expired
  /// cached token (Firebase ID tokens expire after 1 hour).
  static Future<String?> getIdToken({bool forceRefresh = true}) async {
    final user = _authOrNull?.currentUser;
    if (user == null) return null;
    return user.getIdToken(forceRefresh);
  }

  /// Force-reload the current Firebase user from the auth server.
  /// Used by [SyncService._authedRequest] when a backend rejects the
  /// previously-issued token - `getIdToken(true)` doesn't always
  /// invalidate the cache if Firebase considers the token "recent
  /// enough." `reload()` makes the next getIdToken go all the way
  /// back to the server.
  static Future<void> reloadCurrentUser() async {
    final user = _authOrNull?.currentUser;
    if (user == null) return;
    await user.reload();
  }

  // ── Two-step sign-in ──────────────────────────────────────────
  //
  // An account with an authenticator set up (3.0) finishes every
  // sign-in, and every confirming sign-in, with its second step: each method
  // below takes the [SecondStepPrompt] that asks the person for it
  // (lib/services/account/two_step.dart). Backing out of it returns null,
  // like backing out of the first step.

  // ── Google Sign-In ────────────────────────────────────────────

  static Future<UserCredential?> signInWithGoogle(
      {SecondStepPrompt? secondStep}) async {
    if (!isFirebaseAvailable) {
      throw StateError(
        'Firebase is not configured on this platform. '
        'Run "flutterfire configure" to enable sign-in.',
      );
    }

    try {
      final googleUser = await GoogleSignIn().signIn();
      if (googleUser == null) return null; // User cancelled

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      final result = await signInWithSecondStep(
        () => accountExists(() => _auth.signInWithCredential(credential), email: googleUser.email),
        secondStep: secondStep,
        email: googleUser.email,
      );
      if (result == null) {
        await GoogleSignIn().signOut();
        return null;
      }
      AppLogger.info('Google sign-in successful');
      return result;
    } on SsoAccountExists {
      // (Google is added once they are signed in the usual way: the next
      // Google sign-in picks an account again.)
      await GoogleSignIn().signOut();
      rethrow;
    } catch (e) {
      AppLogger.error('Google sign-in failed', e);
      rethrow;
    }
  }

  /// Runs [signIn]; an address that already has an account that signs in
  /// another way comes out as [SsoAccountExists] (Firebase keeps one account
  /// per address: a way it does not trust for that address is not added to
  /// the account by itself).
  @visibleForTesting
  static Future<UserCredential> accountExists(Future<UserCredential> Function() signIn, {String? email}) async {
    try {
      return await signIn();
    } on FirebaseAuthException catch (e) {
      final credential = e.credential;
      if (e.code == 'account-exists-with-different-credential' && credential != null) {
        throw SsoAccountExists(email: e.email ?? email ?? '', credential: credential);
      }
      rethrow;
    }
  }

  // ── Apple Sign-In ─────────────────────────────────────────────

  static Future<UserCredential?> signInWithApple(
      {SecondStepPrompt? secondStep}) async {
    if (!isFirebaseAvailable) {
      throw StateError(
        'Firebase is not configured on this platform. '
        'Run "flutterfire configure" to enable sign-in.',
      );
    }

    try {
      final AuthorizationCredentialAppleID appleCredential;
      try {
        appleCredential = await SignInWithApple.getAppleIDCredential(
          scopes: [
            AppleIDAuthorizationScopes.email,
            AppleIDAuthorizationScopes.fullName,
          ],
        );
      } on SignInWithAppleAuthorizationException catch (e) {
        // Closing Apple's sheet is no failure.
        if (e.code == AuthorizationErrorCode.canceled) return null;
        rethrow;
      }

      final oauthCredential = OAuthProvider('apple.com').credential(
        idToken: appleCredential.identityToken,
        accessToken: appleCredential.authorizationCode,
      );

      final result = await signInWithSecondStep(
        () => accountExists(() => _auth.signInWithCredential(oauthCredential), email: appleCredential.email),
        secondStep: secondStep,
        email: appleCredential.email,
      );
      if (result == null) return null;

      // Apple only sends the name on first sign-in - save it
      if (result.user != null &&
          result.user!.displayName == null &&
          appleCredential.givenName != null) {
        await result.user!.updateDisplayName(
          '${appleCredential.givenName} ${appleCredential.familyName ?? ''}'
              .trim(),
        );
      }

      AppLogger.info('Apple sign-in successful');
      return result;
    } on SsoAccountExists {
      rethrow;
    } catch (e) {
      AppLogger.error('Apple sign-in failed', e);
      rethrow;
    }
  }

  // ── Company sign-in (3.0) ─────────────────────────────

  /// The provider for an Orchard's company sign-in [providerId]. On phones
  /// SAML and OIDC both go through OAuthProvider with the provider id, as
  /// Identity Platform's Android and iOS SDKs take them; an OIDC provider
  /// is told which address to expect.
  static OAuthProvider _ssoProvider(String providerId, String? email) {
    final provider = OAuthProvider(providerId);
    if (providerId.startsWith('oidc.') && email != null && email.isNotEmpty) {
      provider.setCustomParameters({'login_hint': email});
    }
    return provider;
  }

  /// Whether [e] only says the person closed the sign-in tab.
  static bool _cancelled(FirebaseAuthException e) =>
      e.code == 'web-context-canceled' || e.code == 'canceled' || e.code == 'web-context-already-presented';

  /// Signs in with Microsoft (work, school or personal accounts), in a
  /// browser tab. Null when the person closes it. Throws [SsoAccountExists]
  /// when the address already has an account that signs in another way.
  static Future<UserCredential?> signInWithMicrosoft({SecondStepPrompt? secondStep}) async {
    if (!isFirebaseAvailable) {
      throw StateError('Firebase is not configured on this platform.');
    }
    try {
      final result = await signInWithSecondStep(
        () => _auth.signInWithProvider(MicrosoftAuthProvider()..setCustomParameters({'prompt': 'select_account'})),
        secondStep: secondStep,
      );
      if (result != null) AppLogger.info('Microsoft sign-in successful');
      return result;
    } on FirebaseAuthException catch (e) {
      final credential = e.credential;
      if (e.code == 'account-exists-with-different-credential' && credential != null) {
        throw SsoAccountExists(email: e.email ?? '', credential: credential);
      }
      if (_cancelled(e)) return null;
      rethrow;
    }
  }

  /// Signs in through an Orchard's company sign-in ([providerId], found by
  /// "Sign in with SSO"), in a browser tab. Null when the person closes it.
  /// Throws [SsoAccountExists] when the address already has an account that
  /// signs in another way.
  static Future<UserCredential?> signInWithSso(String providerId,
      {String? email, SecondStepPrompt? secondStep}) async {
    if (!isFirebaseAvailable) {
      throw StateError('Firebase is not configured on this platform.');
    }
    try {
      final result = await signInWithSecondStep(
        () => _auth.signInWithProvider(_ssoProvider(providerId, email)),
        secondStep: secondStep,
        email: email,
      );
      if (result != null) AppLogger.info('Company sign-in successful');
      return result;
    } on FirebaseAuthException catch (e) {
      final credential = e.credential;
      if (e.code == 'account-exists-with-different-credential' && credential != null) {
        throw SsoAccountExists(email: e.email ?? email ?? '', credential: credential);
      }
      if (_cancelled(e)) return null;
      rethrow;
    }
  }

  /// Adds the company sign-in waiting in [pending] to the account signed in
  /// now (its address must be the one [pending] is for), then signs in once
  /// more through it, so the session counts as a company sign-in (an
  /// Orchard can require one). Null when the person closes that tab; the
  /// company sign-in is added either way.
  static Future<UserCredential?> addSsoToAccount(SsoAccountExists pending, String providerId,
      {SecondStepPrompt? secondStep}) async {
    final user = _authOrNull?.currentUser;
    if (user == null) throw StateError('Not signed in');
    if (pending.email.isNotEmpty && (user.email ?? '').toLowerCase() != pending.email.toLowerCase()) {
      throw FirebaseAuthException(code: 'user-mismatch');
    }
    final linked = await user.linkWithCredential(pending.credential);
    // Only a company sign-in has a rule that wants the session to come
    // through it (Microsoft is simply added).
    if (!isOrchardSsoProvider(providerId)) return linked;
    try {
      return await signInWithSecondStep(
        () => user.reauthenticateWithProvider(_ssoProvider(providerId, pending.email)),
        secondStep: secondStep,
        email: user.email,
      );
    } on FirebaseAuthException catch (e) {
      if (_cancelled(e)) return null;
      rethrow;
    }
  }

  /// Makes this device's session a company sign-in through [providerId]
  /// (an Orchard's rule can require one): the company sign-in is added to
  /// the account first when it is not part of it yet, then the person signs
  /// in through it. False when they close the tab.
  static Future<bool> switchToSso(String providerId, {SecondStepPrompt? secondStep}) async {
    final user = _authOrNull?.currentUser;
    if (user == null) throw StateError('Not signed in');
    try {
      if (!user.providerData.any((p) => p.providerId == providerId)) {
        await user.linkWithProvider(_ssoProvider(providerId, user.email));
      }
      final again = await signInWithSecondStep(
        () => user.reauthenticateWithProvider(_ssoProvider(providerId, user.email)),
        secondStep: secondStep,
        email: user.email,
      );
      return again != null;
    } on FirebaseAuthException catch (e) {
      if (_cancelled(e)) return false;
      rethrow;
    }
  }

  /// An Orchard owner's test sign-in through [providerId], on a Firebase
  /// app of its own so this device's account stays signed in: the ID token
  /// for ZestSSH Cloud to check (null when the person closes the tab). The
  /// test account is signed out again straight away.
  static Future<String?> ssoTestToken(String providerId) async {
    if (!isFirebaseAvailable) {
      throw StateError('Firebase is not configured on this platform.');
    }
    FirebaseApp? app;
    for (final a in Firebase.apps) {
      if (a.name == 'sso-test') app = a;
    }
    app ??= await Firebase.initializeApp(name: 'sso-test', options: Firebase.app().options);
    final auth = FirebaseAuth.instanceFor(app: app);
    try {
      final result = await auth.signInWithProvider(OAuthProvider(providerId));
      return await result.user?.getIdToken();
    } on FirebaseAuthException catch (e) {
      if (_cancelled(e)) return null;
      rethrow;
    } finally {
      await auth.signOut().catchError((_) {});
    }
  }

  // ── Email / Password ──────────────────────────────────────────

  /// Create an account with email + password and immediately send a
  /// verification email. The account stays UNVERIFIED - and inert, because the
  /// backend refuses sync/entitlements for an unverified password account -
  /// until the user clicks the link. That gate is what stops drive-by / spam
  /// account creation: an unverified email buys nothing.
  static Future<UserCredential?> signUpWithEmail(
      String email, String password) async {
    if (!isFirebaseAvailable) {
      throw StateError('Firebase is not configured on this platform.');
    }
    final result = await _auth.createUserWithEmailAndPassword(
      email: email.trim(),
      password: password,
    );
    try {
      final user = result.user;
      if (user != null) await _sendVerification(user);
    } catch (e) {
      // Non-fatal: the account exists; the user can re-send from the
      // verification screen.
      AppLogger.warning('Failed to send verification email: $e');
    }
    AppLogger.info('Email sign-up successful (verification sent)');
    return result;
  }

  static Future<UserCredential?> signInWithEmail(
      String email, String password,
      {SecondStepPrompt? secondStep}) async {
    if (!isFirebaseAvailable) {
      throw StateError('Firebase is not configured on this platform.');
    }
    final result = await signInWithSecondStep(
      () => _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      ),
      secondStep: secondStep,
      email: email.trim(),
    );
    if (result != null) AppLogger.info('Email sign-in successful');
    return result;
  }

  /// Emails [email] a link to choose a password: a first one for an account
  /// made through Google or Apple, a new one otherwise (ZestSSH Cloud picks
  /// the words). Works on every device, Firebase or not; false when it could
  /// not be sent. ZestSSH Cloud answers the same whether or not the address
  /// has an account. Where ZestSSH Cloud cannot send it (busy, 429; not
  /// configured or down, 503; out of reach) a device with Firebase sends it through
  /// Firebase; a computer with none has [passwordLinkPage] to go to instead.
  static Future<bool> sendPasswordLink(String email) async {
    final address = email.trim();
    if (address.isEmpty) return false;
    if (await _requestBrandedEmail('password-reset', {'email': address})) return true;
    if (!isFirebaseAvailable) return false;
    try {
      await _auth.sendPasswordResetEmail(email: address);
      return true;
    } catch (e) {
      AppLogger.warning('Password link: $e');
      return false;
    }
  }

  /// The sign-in page, whose Forgot password? reaches Firebase from the browser:
  /// where a computer, which holds no Firebase of its own, sends someone when
  /// ZestSSH Cloud could not send the link. It stands on its own, without a sign-in
  /// waiting in the app, and comes back to the account's security page on the website.
  static Uri get passwordLinkPage => Uri.parse('$kZestWebsite/auth?next=%2Faccount%2Fsecurity');

  static Future<void> sendPasswordResetEmail(String email) async {
    if (!isFirebaseAvailable) return;
    final address = email.trim();
    if (await _requestBrandedEmail('password-reset', {'email': address})) {
      AppLogger.info('Password reset email sent (branded)');
      return;
    }
    await _auth.sendPasswordResetEmail(email: address);
    AppLogger.info('Password reset email sent');
  }

  /// (Re)send the verification email for the signed-in user. No-op if already
  /// verified or signed out.
  static Future<void> sendEmailVerification() async {
    final user = _authOrNull?.currentUser;
    if (user == null || user.emailVerified) return;
    await _sendVerification(user);
    AppLogger.info('Verification email re-sent');
  }

  // ── Branded account emails ─────────────────────────────────────
  //
  // Firebase's own verification / reset emails are plain text. The ZestSSH
  // API sends the same Firebase action links in the ZestSSH template
  // (Resend) instead: `POST /v1/auth/email/verification` proves the account
  // with the ID token, `POST /v1/auth/email/password-reset` takes the
  // address and always answers 200 (no account enumeration). If the API
  // cannot send (not configured, unreachable, rate limited), the Firebase
  // SDK sends its plain email so the user never ends up without a link.

  static String get _apiBase => kZestApiBase;

  static Future<void> _sendVerification(User user) async {
    try {
      final idToken = await user.getIdToken();
      if (idToken != null &&
          await _requestBrandedEmail('verification', {'id_token': idToken})) {
        return;
      }
    } catch (e) {
      AppLogger.warning('Branded verification email failed: $e');
    }
    await user.sendEmailVerification();
  }

  /// True when the API accepted the request. Never throws: any failure means
  /// "fall back to the Firebase email".
  static Future<bool> _requestBrandedEmail(
      String kind, Map<String, String> body) async {
    try {
      final resp = await PinnedHttpClient.client
          .post(
            Uri.parse('$_apiBase/auth/email/$kind'),
            headers: const {'Content-Type': 'application/json'},
            body: jsonEncode(body),
          )
          .timeout(const Duration(seconds: 12));
      if (resp.statusCode == 200) return true;
      AppLogger.warning('Branded $kind email: HTTP ${resp.statusCode}');
      return false;
    } catch (e) {
      AppLogger.warning('Branded $kind email error: $e');
      return false;
    }
  }

  /// Reload the user and report whether their email is now verified. The
  /// verification-pending screen calls this after the user says they clicked
  /// the link.
  static Future<bool> refreshEmailVerified() async {
    final user = _authOrNull?.currentUser;
    if (user == null) return false;
    await user.reload();
    return _authOrNull?.currentUser?.emailVerified ?? false;
  }

  /// Whether the current user signed in with email/password. Google and Apple
  /// accounts are always email-verified, so the verify gate only applies here.
  static bool get isPasswordProvider =>
      _authOrNull?.currentUser?.providerData
          .any((p) => p.providerId == 'password') ??
      false;

  /// Whether the current user's email is verified (true for Google/Apple).
  static bool get isEmailVerified =>
      _authOrNull?.currentUser?.emailVerified ?? false;

  // ── Sign Out ──────────────────────────────────────────────────

  static Future<void> signOut() async {
    if (!isFirebaseAvailable) return;
    await GoogleSignIn().signOut();
    await _auth.signOut();
    AppLogger.info('Signed out');
  }

  // ── Signing in again ──────────────────────────────────────────

  /// Asks the signed-in user to sign in again with the method they use, for
  /// an action the person must confirm right now (deleting the account).
  /// Returns a fresh ID token, whose sign-in time the server checks, or null
  /// when they back out. The Google account picker is always shown: this is
  /// a confirmation, not a silent refresh. [askPassword] supplies the
  /// password of an email account.
  ///
  /// Throws when signing in fails, including a FirebaseAuthException with
  /// code `user-mismatch` when they pick a different account. An account
  /// with two-step sign-in also answers its second step ([secondStep]).
  static Future<String?> signInAgain({
    required Future<String?> Function(String email) askPassword,
    SecondStepPrompt? secondStep,
  }) async {
    final user = _authOrNull?.currentUser;
    if (user == null) return null;
    final providers = {for (final info in user.providerData) info.providerId};

    // Signed in through a company sign-in: again through it, so an
    // Orchard's "Sign in with SSO" rule is still met afterwards.
    final current = (await user.getIdTokenResult()).signInProvider;
    if (isOrchardSsoProvider(current)) {
      try {
        final again = await signInWithSecondStep(
          () => user.reauthenticateWithProvider(OAuthProvider(current!)),
          secondStep: secondStep,
          email: user.email,
        );
        if (again == null) return null;
      } on FirebaseAuthException catch (e) {
        if (_cancelled(e)) return null;
        rethrow;
      }
      return user.getIdToken(true);
    }

    final way = wayToSignInAgain(providers, appleHere: isAppleSignInAvailable);
    if (way == null) {
      // Apple only, on a device without Apple's sign-in.
      if (providers.contains('apple.com')) throw const NoWayHere();
      throw StateError(
          'Signing in again is not supported for ${providers.join(', ')}');
    }

    final AuthCredential credential;
    switch (way) {
      case SignInWay.google:
        final google = GoogleSignIn();
        await google.signOut();
        final account = await google.signIn();
        if (account == null) return null;
        final auth = await account.authentication;
        credential = GoogleAuthProvider.credential(
          accessToken: auth.accessToken,
          idToken: auth.idToken,
        );
      case SignInWay.apple:
        try {
          final apple =
              await SignInWithApple.getAppleIDCredential(scopes: const []);
          credential = OAuthProvider('apple.com').credential(
            idToken: apple.identityToken,
            accessToken: apple.authorizationCode,
          );
        } on SignInWithAppleAuthorizationException catch (e) {
          if (e.code == AuthorizationErrorCode.canceled) return null;
          rethrow;
        }
      case SignInWay.password:
        final email = user.email;
        if (email == null || email.isEmpty) {
          throw StateError('This account has no email to sign in with');
        }
        final password = await askPassword(email);
        if (password == null || password.isEmpty) return null;
        credential =
            EmailAuthProvider.credential(email: email, password: password);
      case SignInWay.company:
        // (Signed in to again through itself, above.)
        throw StateError('A company sign-in is signed in to again through itself');
      case SignInWay.microsoft:
        try {
          final again = await signInWithSecondStep(
            () => user.reauthenticateWithProvider(MicrosoftAuthProvider()),
            secondStep: secondStep,
            email: user.email,
          );
          if (again == null) return null;
        } on FirebaseAuthException catch (e) {
          if (_cancelled(e)) return null;
          rethrow;
        }
        return user.getIdToken(true);
    }

    final confirmed = await signInWithSecondStep(
      () => user.reauthenticateWithCredential(credential),
      secondStep: secondStep,
      email: user.email,
    );
    if (confirmed == null) return null;
    return user.getIdToken(true);
  }

  /// The way to sign in again on this device for an account that signs in
  /// with [providers] (Firebase provider ids), or null when none of them is
  /// here. Google first, then Apple where Apple's own sign-in is
  /// ([appleHere]: on Apple's devices), then the password, then Microsoft.
  /// (A company sign-in is signed in to again through itself, before this
  /// is asked.)
  @visibleForTesting
  static SignInWay? wayToSignInAgain(Set<String> providers, {required bool appleHere}) {
    if (providers.contains('google.com')) return SignInWay.google;
    if (appleHere && providers.contains('apple.com')) return SignInWay.apple;
    if (providers.contains('password')) return SignInWay.password;
    if (providers.contains('microsoft.com')) return SignInWay.microsoft;
    return null;
  }

  // ── Helpers ───────────────────────────────────────────────────

  /// Whether Apple Sign-In is available on this device.
  static bool get isAppleSignInAvailable => Platform.isIOS || Platform.isMacOS;
}

/// The account signs in only in a way this device does not offer (Apple's
/// own sign-in, away from Apple's devices).
class NoWayHere implements Exception, HasTypeName {
  const NoWayHere();

  @override
  String toString() => 'NoWayHere';

  @override
  String get typeName => 'NoWayHere';
}
