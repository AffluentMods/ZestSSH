import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/sync_health.dart';

/// How this device's sync stands, as the status bar and the Account screen
/// show it: off, syncing, up to date, behind (amber) or failing (red).
void main() {
  final now = DateTime(2026, 9, 24, 12);

  SyncHealthState health({
    bool configured = true,
    String mode = 'auto',
    bool running = false,
    String? problem,
    bool paused = false,
    bool retrying = false,
    DateTime? confirmedAt,
    bool dirty = false,
    DateTime? dirtySince,
  }) =>
      syncHealthOf(
        configured: configured,
        mode: mode,
        running: running,
        problem: problem,
        paused: paused,
        retrying: retrying,
        confirmedAt: confirmedAt ?? now.subtract(const Duration(minutes: 3)),
        dirty: dirty,
        dirtySince: dirtySince,
        now: now,
      );

  test('not set up is off, whatever else is true', () {
    expect(health(configured: false).health, SyncHealth.off);
    expect(health(configured: false, running: true, problem: 'x').health, SyncHealth.off);
  });

  test('running shows as syncing, even over an earlier failure', () {
    expect(health(running: true).health, SyncHealth.syncing);
    expect(health(running: true, problem: 'offline').health, SyncHealth.syncing);
  });

  test('a failure, or a pause after failures, is failing, with what went wrong', () {
    final failed = health(problem: 'The sync server could not be reached');
    expect(failed.health, SyncHealth.failing);
    expect(failed.problem, 'The sync server could not be reached');
    expect(health(paused: true).health, SyncHealth.failing);
  });

  // A store that cannot be reached is tried again by the app itself (3.0):
  // whoever shows the failure is told so, and says it.
  test('a failure the app tries again by itself says so, and a pause never does', () {
    final trying = health(problem: 'The sync server could not be reached', retrying: true);
    expect(trying.health, SyncHealth.failing);
    expect(trying.retrying, isTrue);
    expect(health(problem: 'The sync server could not be reached').retrying, isFalse);
    expect(health(problem: 'Keys do not match', paused: true, retrying: true).retrying, isFalse,
        reason: 'a pause is until somebody acts, whatever else is said');
  });

  test('trying again is said of a failure only', () {
    expect(health(retrying: true).health, SyncHealth.upToDate);
    expect(health(retrying: true).retrying, isFalse);
    expect(health(running: true, problem: 'x', retrying: true).retrying, isFalse);
    expect(health(configured: false, problem: 'x', retrying: true).retrying, isFalse);
  });

  test('a recent check with nothing waiting is up to date', () {
    final ok = health();
    expect(ok.health, SyncHealth.upToDate);
    expect(ok.confirmedAt, now.subtract(const Duration(minutes: 3)));
  });

  test('automatic sync: a change is behind only once it has waited too long', () {
    final fresh = health(dirty: true, dirtySince: now.subtract(const Duration(seconds: 20)));
    expect(fresh.health, SyncHealth.upToDate, reason: 'a push on its way');
    final stuck = health(dirty: true, dirtySince: now.subtract(kSyncWaitingGrace));
    expect(stuck.health, SyncHealth.behind);
    expect(stuck.waiting, isTrue);
    expect(health(dirty: true).health, SyncHealth.behind,
        reason: 'waiting since before the time was recorded');
  });

  test('manual sync: any waiting change is behind at once, an old check is not', () {
    final waiting = health(
        mode: 'manual', dirty: true, dirtySince: now.subtract(const Duration(seconds: 5)));
    expect(waiting.health, SyncHealth.behind);
    expect(waiting.waiting, isTrue);
    expect(health(mode: 'manual', confirmedAt: now.subtract(const Duration(days: 10))).health,
        SyncHealth.upToDate);
  });

  test('automatic sync that has not confirmed it is current for a day is behind', () {
    final stale = health(confirmedAt: now.subtract(kSyncStaleAfter));
    expect(stale.health, SyncHealth.behind);
    expect(stale.waiting, isFalse);
    expect(health(confirmedAt: now.subtract(const Duration(hours: 23))).health,
        SyncHealth.upToDate);
    expect(health(mode: 'instant', confirmedAt: now.subtract(const Duration(days: 2))).health,
        SyncHealth.behind);
  });

  test('set up but never synced is behind', () {
    final never = syncHealthOf(
      configured: true,
      mode: 'auto',
      running: false,
      problem: null,
      paused: false,
      confirmedAt: null,
      dirty: false,
      dirtySince: null,
      now: now,
    );
    expect(never.health, SyncHealth.behind);
  });
}
