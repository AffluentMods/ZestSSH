// The team's two rules about remote screens (4.0) as a screen's
// session, its host's editor and the editor's Test read them. They are
// rules of the team's record (RecordRules.screensSshOnly and
// screensLockRedirections), set by an owner, and each device holds itself to
// them: the server cannot see a team's hosts. Like the team's other device
// rules they are the app's rules, not cryptography: a changed app could
// ignore them, which is why the whitepaper names who enforces them.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/orchard_rules.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/providers/core_providers.dart';

/// The rules about remote screens in force for one space.
class ScreenTeamRules {
  const ScreenTeamRules({this.sshOnly = false, this.lockRedirections = false});

  /// Your own space, and a team with neither rule.
  static const none = ScreenTeamRules();

  ScreenTeamRules.of(RecordRules? rules)
      : sshOnly = rules?.screensSshOnly ?? false,
        lockRedirections = rules?.screensLockRedirections ?? false;

  /// A remote screen opens through an SSH host only: one that connects
  /// directly does not open (ZS-1821), is not tested, and its editor offers
  /// no direct connection.
  final bool sshOnly;

  /// Nothing of this device is shared with a remote screen: its clipboard is
  /// off and cannot be turned on, whatever the host's own setting says.
  final bool lockRedirections;

  @override
  bool operator ==(Object other) =>
      other is ScreenTeamRules && other.sshOnly == sshOnly && other.lockRedirections == lockRedirections;

  @override
  int get hashCode => Object.hash(sshOnly, lockRedirections);
}

/// The rules in force for the hosts of [db]'s space: none in your own
/// space; in a team's, what its record on this device says, held to at
/// least what the server says while it holds this account back
/// ([rulesInForce]). Read when a screen connects, so a rule an owner sets
/// holds from the next time each screen is opened.
///
/// The record itself is read ([latestRecordIn]: its entries, replayed by
/// this version), not only the copy of the rules kept beside it
/// (orchard_info.rules): that copy is written when a refresh ends well, and
/// one written by a version from before these rules does not name them, so
/// a device just updated, or one whose refresh stopped part way, would have
/// read "no rule" from it until it next synced. Where the record cannot be
/// read here (a problem with it, or none yet), the copy is what there is.
Future<ScreenTeamRules> screenTeamRulesIn(AppDatabase db) async {
  if (!db.isOrchard) return ScreenTeamRules.none;
  final info = await db.customSelect('SELECT rules, held FROM orchard_info WHERE id = 1').getSingleOrNull();
  if (info == null) return ScreenTeamRules.none;
  Object? json(String? raw) {
    if (raw == null) return null;
    try {
      return jsonDecode(raw);
    } catch (_) {
      return null;
    }
  }

  RecordRules? record;
  try {
    record = (await latestRecordIn(db))?.rules;
  } catch (_) {
    record = null;
  }
  final held = json(info.read<String?>('held'));
  return ScreenTeamRules.of(rulesInForce(record?.toBody() ?? json(info.read<String?>('rules')), held));
}

/// The rules in force in the space on screen: what a host's editor shows.
///
/// From the list of teams itself, which keeps what it last read while it is
/// read again (every sync reads it again): through [activeOrchardProvider]
/// the team is nobody for those frames, and the editor would offer a direct
/// connection and a live clipboard switch for as long.
final screenTeamRulesProvider = Provider<ScreenTeamRules>((ref) {
  final space = ref.watch(activeSpaceProvider);
  if (space is! OrchardSpace) return ScreenTeamRules.none;
  final teams = ref.watch(orchardSummariesProvider).valueOrNull ?? const <OrchardSummary>[];
  for (final team in teams) {
    if (team.id == space.orchardId) return ScreenTeamRules.of(team.rules);
  }
  return ScreenTeamRules.none;
});
