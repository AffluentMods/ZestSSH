import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';

// Where the app notes what its person does with a team's items (3.0):
// the service keeps a note only while the team's owners record
// activity (its record says so), and nothing otherwise. A key's secrets
// opened on screen count once in ten minutes per key, so clicking through
// the key list is not a stream of notes; copying, exporting and connecting
// count each time.

/// How long a key's secrets opened again count as the same opening.
const kRevealNoteWindow = Duration(minutes: 10);

final _lastReveal = <String, DateTime>{};

/// What was revealed lately is one account's: a change of profile.
void forgetLastReveals() => _lastReveal.clear();

/// Whether a reveal of [itemKey] in [orchardId] was noted within
/// [kRevealNoteWindow] of [now]; notes this one when not.
bool _revealedLately(String orchardId, String itemKind, String itemKey, DateTime now) {
  final k = '$orchardId|$itemKind|$itemKey';
  final last = _lastReveal[k];
  if (last != null && now.difference(last) < kRevealNoteWindow) return true;
  _lastReveal[k] = now;
  return false;
}

/// Forgets which reveals were noted (tests).
void resetRevealNotes() => _lastReveal.clear();

/// Notes that this account did [kind] with the item [itemKey] of [itemKind]
/// in the space on screen, when that is an Orchard. Never throws.
Future<void> noteScreenActivity(
  WidgetRef ref,
  ActivityKind kind, {
  required String itemKind,
  required String itemKey,
  String? name,
}) async {
  final space = ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return;
  try {
    final db = await ref.read(orchardDatabasesProvider.notifier).open(space.orchardId);
    await noteActivityIn(ref.read(orchardServiceProvider), db, kind, itemKind: itemKind, itemKey: itemKey, name: name);
  } catch (e) {
    AppLogger.info('Orchards: activity not noted ($e)');
  }
}

/// Notes that this account did [kind] with the item [itemKey] of [itemKind]
/// of [db], the database of the Orchard it is in (a session's, which has no
/// screen of its own). Nothing for your Tree's. Never throws.
Future<void> noteActivityIn(
  OrchardService service,
  AppDatabase db,
  ActivityKind kind, {
  required String itemKind,
  required String itemKey,
  String? name,
  DateTime? now,
}) async {
  if (!db.isOrchard) return;
  try {
    final info = await db.customSelect('SELECT orchard_id FROM orchard_info WHERE id = 1').getSingleOrNull();
    final orchardId = info?.read<String>('orchard_id');
    if (orchardId == null) return;
    // Nothing is noted, not even as seen, while the team records no activity.
    if (!(await LocalRecord.load(db, orchardId)).latest.tracking.activity) return;
    if (kind == ActivityKind.reveal && _revealedLately(orchardId, itemKind, itemKey, now ?? DateTime.now())) return;
    final crateId = await CratePlacement(db).crateOf(itemKind, itemKey);
    await service.recordActivity(orchardId, kind, crateId: crateId, itemKind: itemKind, itemKey: itemKey, name: name);
  } catch (e) {
    AppLogger.info('Orchards: activity not noted ($e)');
  }
}
