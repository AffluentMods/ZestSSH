# Cloud Sync: Tombstones + "Newest Wins" (design brief)

Status: **decided, not built.** Own release, multi-device QA. Rides inside the
existing E2E-encrypted blob (no new crypto).

## Problem

The merge is a **union by id**: `restoreAll` only ever `UPDATE`s or `INSERT`s a
record by id ([sync_data_service.dart:420](../lib/services/sync_data_service.dart#L420)),
never deletes one that's absent from the blob. So a deletion (an *absence*)
never propagates: a host deleted on device A is re-added from device B's blob
on the next merge. Deletes don't stick.

## Decisions (settled)

1. **Tombstones**: a delete is recorded as an explicit "this id died at T"
   marker that travels in the sync blob, so other devices remove the record and
   don't re-add it.
2. **Newest wins, ALWAYS**: one universal rule for *every* conflict, not just
   delete-vs-edit. Every synced record carries a trustworthy `lastModified`;
   every tombstone carries `deletedAt`. Per id, the event with the newest
   timestamp wins:
   - `record.lastModified > tombstone.deletedAt` → record **lives** (edit wins).
   - `tombstone.deletedAt > record.lastModified` → record **removed** (delete wins).
   - record-vs-record → newer `lastModified` wins (this **replaces** today's
     push-order last-writer-wins).
3. **Clock caveat (accepted):** "newest wins" trusts device wall clocks; a badly
   skewed clock can mis-resolve a conflict. Matches the existing whole-blob LWW
   model. Logical clocks / HLC deferred: not worth it.

## Work

### 1. Make `lastModified` trustworthy: the core rework
The current timestamp is useless for arbitration: `restoreAll` stamps
`updatedAt = now()` on every merged row
([sync_data_service.dart:631](../lib/services/sync_data_service.dart#L631) and the
sibling `updatedAt: Value(DateTime.now())` sites). Fix:
- Set `lastModified = now()` on every genuine **local** create/edit (DAO write
  paths + `AutoSyncService.notifyLocalChanged`-style hooks).
- **Stop resetting it on merge**: `restoreAll` must PRESERVE the incoming
  blob's `lastModified` instead of overwriting with `now()`.
- Serialize `lastModified` in `gatherAll`, read it in `restoreAll`, for every
  synced entity. (Most tables already have `updatedAt`; audit each and add where
  missing.)

### 2. Schema: DB migration → v28
- New synced table `tombstones(entity_type TEXT, entity_id TEXT,
  deleted_at INTEGER /*ms epoch*/, PRIMARY KEY(entity_type, entity_id))`.
- Any synced table missing a real modification column gets `lastModified`.
- Use the **idempotent** `_addColumnIfAbsent` / `createTable` migration pattern
  (the one hardened in the color_value fix) so old-schema upgraders don't crash.
- Add a migration test seeding an old version through to v28.

### 3. Capture every deletion
Write a tombstone `(entityType, id, deletedAt = now())` in the **same
transaction** as each delete. Centralize as `TombstoneDao.mark(type, id, tx)`
called from every delete method. Points to cover:
- connections (single + **bulk multi-select**)
- connection_groups (+ whatever happens to reassigned/child connections)
- identities
- snippets, snippet_categories
- networks, host_network_overrides
- port_forward_rules, port_forward_network_overrides
- connection_tags (child of connection)
- workflows / scheduled_tasks *if synced*: audit `gatherAll` for the exact
  synced set before implementing.

**Cascade note (the usual trap, and here it's easy):** child deletes must be
tombstoned too, or children resurrect. Good news: FKs are declared WITHOUT
`onDelete: cascade` and drift isn't enforcing FK actions at the DB level
([connections.dart:18](../lib/database/tables/connections.dart#L18),
[port_forward_rules.dart:12](../lib/database/tables/port_forward_rules.dart#L12)),
so cascades are already done in **Dart**, not by SQLite: every child delete
runs through a DAO where the tombstone can be written. No hidden DB-level cascade
skips capture.

**Exclude:** purge / sign-out / local-reset / "delete all sync data" must NOT
write tombstones: those are wipes, not user deletes.

### 4. Merge changes (`sync_data_service`)
- **gatherAll:** include the `tombstones` list and every record's
  `lastModified`. Do NOT emit a live record whose id has a **newer** tombstone.
- **restoreAll:**
  - Merge the tombstone set: union, and per id keep `max(deletedAt)`.
  - Per incoming record: apply only if no newer tombstone exists for that id;
    when both sides have the record, keep the one with newer `lastModified`
    (newest-wins **replaces** the current always-overwrite).
  - Per merged tombstone: if a local record exists with `lastModified <
    deletedAt`, delete it locally.
  - Persist merged tombstones locally so this device re-propagates them.
- **Content fingerprint** (`SyncDataService.contentFingerprint`) must include the
  tombstone set, so a new delete triggers a push and an applied pulled delete
  doesn't echo-push.
- Ids are UUIDs, so a re-created record gets a NEW id: an old tombstone never
  wrongly suppresses a genuinely new record.

### 5. Rollout gate: already built
Bump the sync blob `schema_version`. Old clients hit the existing fail-closed
refuse ([sync_data_service.dart:427](../lib/services/sync_data_service.dart#L427)),
so they can't pull, silently strip the tombstones, and re-push a resurrecting
blob. That's what forces the all-devices update; without it tombstones are
pointless. We have it.

### 6. Garbage collection
Prune tombstones with `deletedAt` older than RETENTION (recommend 6 to 12 months);
bounds the blob against the 10 MB cap. Run on the sync cycle or app start.
Documented tradeoff: a device offline **longer** than RETENTION never saw the
tombstone and re-resurrects that one item once.

### 7. Tests + QA
- delete propagates (A deletes → B loses it, no resurrection)
- edit-vs-delete both directions (newer edit keeps; newer delete removes)
- edit-vs-edit → newer `lastModified` wins (replaces push-order)
- cascade child tombstones (delete group/host → children don't resurrect)
- GC prune + offline-past-retention resurrection (documented, asserted)
- v27→v28 migration (idempotent) + a real **multi-device e2e**

## Suggested build order
1. Schema (v28) + `lastModified` rework + tombstone capture: no sync behavior
   change yet (blob schema NOT bumped).
2. Merge honors tombstones + gatherAll emits them + **bump blob schema_version**
   (the switch-on).
3. GC.

Ship as its own release with multi-device QA (same bar as the recovery-key e2e).
