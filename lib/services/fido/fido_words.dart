// What a security key's failure is said as, in the person's language, with
// its code where it has one (docs/ERROR-CODES.md).
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/fido/fido_signer.dart';

/// The words for [failure].
String fidoFailureText(AppLocalizations l10n, FidoFailure failure) => switch (failure.kind) {
      FidoFailureKind.cancelled => l10n.fidoFailTimedOut,
      FidoFailureKind.noWay => ErrorCodes.withCode(l10n.fidoFailNoWay, ErrorCodes.fidoNoWay),
      FidoFailureKind.nfcOff => l10n.fidoFailNfcOff,
      FidoFailureKind.keyLeft => ErrorCodes.withCode(l10n.fidoFailKeyLeft, ErrorCodes.fidoKeyLeft),
      FidoFailureKind.notASecurityKey => l10n.fidoFailNotKey,
      FidoFailureKind.wrongKey => ErrorCodes.withCode(l10n.fidoFailWrongKey, ErrorCodes.fidoWrongKey),
      FidoFailureKind.pinNotSet => l10n.fidoFailPinNotSet,
      FidoFailureKind.pinBlocked => ErrorCodes.withCode(l10n.fidoFailPinBlocked, ErrorCodes.fidoPinBlocked),
      FidoFailureKind.pinLocked => l10n.fidoFailPinLocked,
      FidoFailureKind.timedOut => l10n.fidoFailTimedOut,
      FidoFailureKind.cannotMakeKind => l10n.fidoFailCannotMake,
      FidoFailureKind.keyFull => l10n.fidoFailKeyFull,
      FidoFailureKind.denied => l10n.fidoFailDenied,
      FidoFailureKind.refused => l10n.fidoFailRefused,
      FidoFailureKind.misbehaved => ErrorCodes.withCode(l10n.fidoFailMisbehaved, ErrorCodes.fidoAnswerNotTrusted),
    };

/// The words for a sign-in that ended because the security key did not
/// sign: [fidoFailureText], and that nothing else was tried in its place.
String fidoSignInEndedText(AppLocalizations l10n, FidoFailure failure) =>
    l10n.fidoSignInEnded(fidoFailureText(l10n, failure));
