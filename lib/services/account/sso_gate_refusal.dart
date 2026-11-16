import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;

/// What the sign-in gate of company sign-in said (3.0 backend review, B1).
/// A blocking function of ZestSSH Cloud's sign-in project stops a sign-in
/// through an Orchard's company sign-in where the Orchard has not proven the
/// address's domain, or where it could not ask ZestSSH Cloud. Identity
/// Platform hands the refusal over as an internal error with the gate's
/// words inside, and each carries a mark of its own (the backend's
/// functions/gate.js), read here so the app says what happened in the
/// person's language.
enum SsoGateRefusal {
  /// The company answered with an address outside the Orchard's proven
  /// domains.
  outsideDomains,

  /// ZestSSH Cloud could not be asked.
  notChecked,
}

/// The gate's refusal that [e] carries, or null for any other failure.
SsoGateRefusal? ssoGateRefusalOf(FirebaseAuthException e) {
  final said = '${e.message ?? ''} ${e.code}';
  if (said.contains('[sso-gate-refused]')) return SsoGateRefusal.outsideDomains;
  if (said.contains('[sso-gate-unreachable]')) return SsoGateRefusal.notChecked;
  return null;
}
