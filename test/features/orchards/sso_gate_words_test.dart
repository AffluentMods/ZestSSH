import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/account/sso_gate_refusal.dart';
import 'package:zestssh/ui/screens/profile/sso_sign_in.dart';

// The sign-in gate of company sign-in: a sign-in it
// stopped reaches the app as Firebase's internal error, with the gate's
// words and their mark inside (the backend's functions/gate.js); the app
// says what happened in the person's language, where it said only that the
// sign-in did not complete. And ZestSSH Cloud's two new answers to an
// owner have words of their own.
void main() {
  // As Identity Platform hands a blocking function's refusal over.
  FirebaseAuthException blocked(String mark) => FirebaseAuthException(
        code: 'internal-error',
        message: 'HTTP Cloud Function returned an error: {"error":{"message":"This company sign-in '
            "doesn't answer for this address. [$mark]\",\"status\":\"PERMISSION_DENIED\"}}",
      );

  test("the gate's marks are read, and nothing else is taken for them", () {
    expect(ssoGateRefusalOf(blocked('sso-gate-refused')), SsoGateRefusal.outsideDomains);
    expect(ssoGateRefusalOf(blocked('sso-gate-unreachable')), SsoGateRefusal.notChecked);
    expect(ssoGateRefusalOf(FirebaseAuthException(code: 'internal-error', message: 'An internal error has occurred.')),
        isNull);
    expect(ssoGateRefusalOf(FirebaseAuthException(code: 'network-request-failed')), isNull);
    expect(ssoGateRefusalOf(FirebaseAuthException(code: 'internal-error', message: 'sso-gate-refused')), isNull,
        reason: 'only the mark as the gate writes it');
  });

  for (final locale in AppLocalizations.supportedLocales) {
    test('in $locale, a sign-in the gate stopped says why, and the server\'s answers to an owner have words', () {
      final l10n = lookupAppLocalizations(locale);

      // Signing in.
      expect(ssoSignInFailureText(blocked('sso-gate-refused'), l10n), l10n.ssoSignInOutside);
      expect(ssoSignInFailureText(blocked('sso-gate-unreachable'), l10n), l10n.ssoSignInGateUnreachable);
      expect(ssoSignInFailureText(FirebaseAuthException(code: 'internal-error'), l10n), l10n.ssoSignInFailed);

      // An owner's test sign-in, and setting it up.
      expect(ssoErrorMessage(blocked('sso-gate-refused'), l10n), l10n.ssoErrorDomainMismatch);
      expect(ssoErrorMessage(blocked('sso-gate-unreachable'), l10n), l10n.ssoSignInGateUnreachable);
      expect(ssoErrorMessage(const OrchardServerException(503, 'sso-gate-off'), l10n), l10n.ssoErrorGateOff);
      expect(ssoErrorMessage(const OrchardServerException(409, 'sso-gate-not-seen'), l10n), l10n.ssoErrorGateNotSeen);
      expect(ssoErrorMessage(const OrchardServerException(409, 'domain-required'), l10n), l10n.ssoNeedsDomain);

      final said = {l10n.ssoSignInGateUnreachable, l10n.ssoErrorGateOff, l10n.ssoErrorGateNotSeen,
          l10n.ssoSignInFailed, l10n.ssoErrorDomainMismatch};
      expect(said.length, 5, reason: 'each says its own thing');
      if (locale.languageCode != 'en') {
        final en = lookupAppLocalizations(const Locale('en'));
        expect(l10n.ssoSignInGateUnreachable, isNot(en.ssoSignInGateUnreachable));
        expect(l10n.ssoErrorGateOff, isNot(en.ssoErrorGateOff));
        expect(l10n.ssoErrorGateNotSeen, isNot(en.ssoErrorGateNotSeen));
      }
    });
  }
}
