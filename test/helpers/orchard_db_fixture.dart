import 'dart:convert';

import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';

/// The Crate [seedOrchardAsOwner] makes, where new items go.
const kFixtureCrateId = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const kFixtureOrchardId = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';

/// What an Orchard's database holds once its record has been read, for a
/// test that writes items into one directly: the Orchard's info, and a
/// Crate where new items go with every switch, as an owner has it. An
/// Orchard's database refuses local writes its Crates do not allow,
/// so a bare one takes none.
Future<void> seedOrchardAsOwner(
  AppDatabase db, {
  String orchardId = kFixtureOrchardId,
  String crateId = kFixtureCrateId,
}) async {
  await db.customStatement(
    'INSERT OR IGNORE INTO orchard_info (id, orchard_id, name, role, key_generation, default_crate_id, can) '
    "VALUES (1, ?, 'Fixture', 'owner', 1, ?, ?)",
    [orchardId, crateId, jsonEncode(RoleCan.all.toList()..sort())],
  );
  await db.customStatement(
    'INSERT OR IGNORE INTO orchard_crates (crate_id, name, level, switches, key_generation) '
    "VALUES (?, 'Fixture', 'manage', ?, 1)",
    [crateId, jsonEncode(CrateSwitches.all.toList()..sort())],
  );
}
