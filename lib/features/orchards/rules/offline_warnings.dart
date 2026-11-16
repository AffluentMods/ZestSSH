import 'package:flutter/foundation.dart' show VoidCallback;
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show cloudIsWhatIsAway;
import 'package:zestssh/features/orchards/rules/offline_pass.dart' show kAllOfOrchard;
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';

// A device says so before an offline limit closes something on it (3.0,
// the outage work: a warning before it closes). Until
// now a limit was noticed when it had closed an Orchard, or a Crate: the
// hosts did not connect, and the person found out by trying. In the last
// quarter of a limit (offlineWarningBefore) the app now says what is about
// to close, when, since when the device has not reached ZestSSH Cloud, and
// what keeps it open; where the service is the one that does not answer,
// that nothing needs doing on the device.

/// The id of the notice for the Orchard [orchardId]: one notice per
/// Orchard, said anew when more is about to close, and taken down when
/// nothing is.
String offlineClosingNoticeId(String orchardId) => 'orchard-closing-$orchardId';

/// The notice that says what offline limits are about to close on this
/// device in one Orchard: [all] is the last second (since the epoch) at
/// which all of the Orchard is open, where its own limit is near, and
/// [crates] the Crates their own limits are about to close, each by its
/// name with the last second it is open. They are listed soonest first.
/// [lastContact] is when the device last reached ZestSSH Cloud, and [reach]
/// what the app knows of how the service stands. With [onAskPass] the
/// notice offers "Offline pass from an owner", the way on where there is no
/// internet to connect to, and calls it when that is pressed.
AppNotification offlineClosingNotice({
  required String orchardId,
  required String orchard,
  required int? all,
  required List<({String name, int end})> crates,
  required int lastContact,
  required CloudReach? reach,
  required AppLocalizations l10n,
  VoidCallback? onAskPass,
  DateTime? now,
}) {
  String at(int seconds) => accessTimeText(seconds, l10n, now: now);
  final closing = [
    if (all != null) (name: l10n.offlineClosingAll, end: all),
    ...crates,
  ]..sort((a, b) => a.end != b.end ? a.end.compareTo(b.end) : a.name.compareTo(b.name));
  final items = [for (final c in closing) l10n.offlineClosingItem(c.name, at(c.end))].join(l10n.listSeparator);
  final since = at(lastContact);
  final cloudAway = cloudIsWhatIsAway(reach);
  return AppNotification(
    id: offlineClosingNoticeId(orchardId),
    title: l10n.offlineClosingTitle(orchard),
    body: cloudAway ? l10n.offlineClosingBodyCloud(items, since) : l10n.offlineClosingBody(items, since),
    // On a computer's toast, two lines: what closes first and when ("+N"
    // for the rest), and what keeps it open. The paragraph above stood there
    // cut at "This devi…" with Show more;
    // it is whole in the bell.
    summary: [
      if (closing.isNotEmpty)
        [
          l10n.offlineClosingItem(closing.first.name, at(closing.first.end)),
          if (closing.length > 1) '+${closing.length - 1}',
        ].join(' · '),
      cloudAway ? l10n.offlineClosingSummaryCloud : l10n.offlineClosingSummary,
    ],
    severity: NotificationSeverity.warning,
    actionLabel: onAskPass == null ? null : l10n.passAskButton,
    onAction: onAskPass,
    // It has a time on it: it stays until it is read, or no longer true.
    dismissAfter: Duration.zero,
  );
}

/// What a pass asked for from the notice is for, where [near] is about to
/// close in an Orchard (the Orchard itself as '', a Crate by its id) and
/// [closed] are the Crates of it that are closed on this device already:
/// the one Crate where nothing else is at stake, and all of the Orchard
/// otherwise, since one pass for all of it holds every Crate open and a
/// pass for one Crate would leave the others as they are.
String passToAskFor(Map<String, int> near, Set<String> closed) =>
    near.length == 1 && !near.containsKey('') && closed.isEmpty ? near.keys.single : kAllOfOrchard;
