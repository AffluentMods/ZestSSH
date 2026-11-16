import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// What its time makes of a certificate that its person is reminded of.
enum CertReminder {
  /// It runs out soon.
  runsOutSoon,

  /// It has run out.
  ranOut,
}

/// How long before its end a certificate "runs out soon", and for how long
/// after it a certificate that has run out is still reminded of.
const _fortnight = Duration(days: 14);

/// Cert-expiry helpers for an [Identity] that carries an OpenSSH certificate.
///
/// The certificate's `valid before` time is mirrored onto the identity row as
/// [Identity.certValidBefore] (null = no certificate, or a cert with no
/// expiry). These getters turn that into the "expired / expiring soon" signal
/// the UI shows so a soon-to-expire cert is a visible reminder, not a 3am
/// outage.
extension IdentityCertExpiry on Identity {
  /// The certificate's expiry has already passed.
  bool certExpired({DateTime? now}) {
    final expiry = certValidBefore;
    if (expiry == null) return false;
    return !(now ?? DateTime.now()).isBefore(expiry);
  }

  /// The certificate expires within fourteen days but hasn't yet: the window
  /// in which the key's own page says when.
  bool certExpiringSoon({DateTime? now}) {
    final expiry = certValidBefore;
    if (expiry == null) return false;
    final ref = now ?? DateTime.now();
    return ref.isBefore(expiry) && !ref.add(_fortnight).isBefore(expiry);
  }

  /// What the key's person is reminded of at [now]; null where there is
  /// nothing to remind of.
  ///
  /// A certificate runs out soon in its last fourteen days, or in the last
  /// quarter of its time where that is shorter: one that was issued for a
  /// day, as short-lived certificates are, would otherwise run out "soon"
  /// from its first minute, and be told of at every start of the app. One
  /// that has run out is reminded of for fourteen days and then no more: the
  /// key's own page still says it, and so does a session that is refused.
  CertReminder? certReminder({DateTime? now}) {
    final end = certValidBefore;
    if (end == null) return null;
    final at = now ?? DateTime.now();
    if (!at.isBefore(end)) {
      return at.difference(end) < _fortnight ? CertReminder.ranOut : null;
    }
    var before = _fortnight;
    final from = certValidAfter;
    if (from != null && end.difference(from) ~/ 4 < before) {
      before = end.difference(from) ~/ 4;
    }
    return at.isBefore(end.subtract(before)) ? null : CertReminder.runsOutSoon;
  }
}

/// What is said of when the certificate of [identity] runs out, in the
/// app's language: that it has, or that it does today, tomorrow or in so
/// many days. Null where the certificate has no end (or there is none).
///
/// The days are days of the calendar on this device's clock: a certificate
/// that ends tomorrow morning runs out tomorrow, also when it is asked about
/// the evening before, with less than a day to go.
String? certExpirySaid(Identity identity, AppLocalizations l10n, {DateTime? now}) {
  final end = identity.certValidBefore;
  if (end == null) return null;
  final at = now ?? DateTime.now();
  if (!at.isBefore(end)) return l10n.certSaidRanOut;
  return switch (_calendarDays(at, end)) {
    0 => l10n.certSaidRunsOutToday,
    1 => l10n.certSaidRunsOutTomorrow,
    final days => l10n.certSaidRunsOutInDays(days),
  };
}

/// The days of the calendar from the day of [from] to the day of [to], each
/// as this device's clock has it.
int _calendarDays(DateTime from, DateTime to) {
  final a = from.toLocal();
  final b = to.toLocal();
  // (Both as days of UTC, which has no day of 23 or 25 hours.)
  return DateTime.utc(b.year, b.month, b.day).difference(DateTime.utc(a.year, a.month, a.day)).inDays;
}
