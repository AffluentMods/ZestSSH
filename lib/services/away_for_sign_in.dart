// While a sign-in or a two-step setup that ZestSSH itself opened waits, time
// away from the app does not count toward Auto-lock (found in a security
// review). A phone locks one minute after leaving the app, so leaving for
// the authenticator, the mail link or a company's sign-in locked the app behind
// the person, and with Encrypt data at rest on the PIN had to be typed to finish.
// Every other absence counts as before, and the phone's own screen lock still
// applies.

/// Holds Auto-lock off for the time a sign-in waits, at most [longest].
abstract final class AwayForSignIn {
  /// As long as a sign-in waits for its browser ([DesktopBrowserSignIn]'s own
  /// wait is the same): past it, time away counts again.
  static const longest = Duration(minutes: 15);

  static int _holds = 0;
  static DateTime? _since;

  /// Runs [flow], a sign-in or a setup that may send the person to another app.
  static Future<T> during<T>(Future<T> Function() flow) async {
    if (_holds++ == 0) _since = DateTime.now();
    try {
      return await flow();
    } finally {
      if (--_holds == 0) _since = null;
    }
  }

  /// Whether time away that began at [left] is a sign-in's: one was waiting
  /// already when the person left, and for no longer than [longest] by [now].
  static bool covers(DateTime left, DateTime now) {
    final since = _since;
    return since != null && !left.isBefore(since) && now.difference(since) <= longest;
  }
}
