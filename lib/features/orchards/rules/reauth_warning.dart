import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_words.dart' show reauthSpanWords;
import 'package:zestssh/l10n/generated/app_localizations.dart';

// A team's "Sign-in lasts" rule warns before it bites (found in a security
// review). When the span ran out, the team simply stopped syncing, and only
// then did a banner say to sign in again. In its last tenth the app now says so,
// with the moment and a way to sign in where the person is. ZestSSH Cloud enforces
// the rule as before; this only says it in time.

/// How long before a sign-in stops counting for a team the app says so: the last
/// tenth of [windowSeconds], at least a quarter of an hour and at most a day.
Duration reauthWarningBefore(int windowSeconds) {
  final tenth = windowSeconds ~/ 10;
  return Duration(seconds: tenth.clamp(15 * 60, 24 * 60 * 60));
}

/// The id of the notice for the Orchard [orchardId]: one for each team, taken down
/// once the account has signed in again or the time has passed (the team's banner
/// says it from there).
String reauthSoonNoticeId(String orchardId) => 'orchard-reauth-$orchardId';

/// The notice that a sign-in stops counting for [team] at [ends] (seconds since the
/// epoch), under a rule of [windowSeconds].
AppNotification reauthSoonNotice({
  required String orchardId,
  required String team,
  required int windowSeconds,
  required int ends,
  required AppLocalizations l10n,
  required VoidCallback onSignIn,
  DateTime? now,
}) =>
    AppNotification(
      id: reauthSoonNoticeId(orchardId),
      title: l10n.orchardReauthSoonTitle(team),
      body: l10n.orchardReauthSoonBody(reauthSpanWords(l10n, windowSeconds ~/ 3600), accessTimeText(ends, l10n, now: now)),
      severity: NotificationSeverity.warning,
      actionLabel: l10n.orchardReauthSoonAction,
      onAction: onSignIn,
      // It has a time on it: it stays until it is read, or no longer true.
      dismissAfter: Duration.zero,
    );

/// A team with a Sign-in lasts of [seconds]. [signInOnly]: it requires company
/// sign-in, so only a sign-in counts, never a passkey's confirmation.
typedef ReauthTeam = ({String id, String name, int seconds, bool signInOnly});

/// Looks at the teams of this account, at each tick of the scheduler's clock: tells
/// of a sign-in about to stop counting, once for each moment it stops, and takes the
/// notice down when that is no longer so.
class ReauthWatch {
  ReauthWatch({
    required this.signedInAt,
    Future<int?> Function()? confirmedAt,
    required this.tell,
    required this.takeDown,
    DateTime Function()? now,
  })  : confirmedAt = confirmedAt ?? signedInAt,
        _now = now ?? DateTime.now;

  /// When this account last really signed in (seconds since the epoch), or null
  /// where that cannot be told: then nothing is said. What a team that requires
  /// company sign-in counts from ([ReauthTeam.signInOnly]).
  final Future<int?> Function() signedInAt;

  /// The later of that and a passkey's confirmation on this device: what the
  /// others count from.
  final Future<int?> Function() confirmedAt;
  final void Function(ReauthTeam team, int ends) tell;
  final void Function(String orchardId) takeDown;
  final DateTime Function() _now;

  /// What was told, by Orchard: the moment it stops counting.
  final _told = <String, int>{};

  Future<void> check(Iterable<ReauthTeam> teams) async {
    final asking = [
      for (final t in teams)
        if (t.seconds > 0) t,
    ];
    final signedIn = asking.any((t) => t.signInOnly) ? await signedInAt() : null;
    final confirmed = asking.any((t) => !t.signInOnly) ? await confirmedAt() : null;
    final now = _now().millisecondsSinceEpoch ~/ 1000;
    final soon = <String>{};
    for (final t in asking) {
      final at = t.signInOnly ? signedIn : confirmed;
      if (at == null) continue;
      final ends = at + t.seconds;
      if (now < ends - reauthWarningBefore(t.seconds).inSeconds || now >= ends) continue;
      soon.add(t.id);
      if (_told[t.id] == ends) continue;
      _told[t.id] = ends;
      tell(t, ends);
    }
    for (final id in _told.keys.toList()) {
      if (soon.contains(id)) continue;
      _told.remove(id);
      takeDown(id);
    }
  }

  /// Nothing more is said (the account signed out): what was told comes down.
  void forget() {
    for (final id in _told.keys.toList()) {
      _told.remove(id);
      takeDown(id);
    }
  }
}
