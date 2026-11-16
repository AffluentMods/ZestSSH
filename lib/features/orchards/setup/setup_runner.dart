import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_reader.dart';
import 'package:zestssh/features/orchards/setup/setup_snapshot.dart';

// What the Team page's "Setup file" and the command line both work with
// (3.0): the Orchard as a file is compared with, and what makes a
// plan's steps, on this device and with the account signed in here.

class SetupRunner {
  const SetupRunner({required this.snapshot, required this.actions});

  /// The Orchard as it is now, brought up to date first.
  final Future<OrchardSnapshot> Function(String orchardId) snapshot;

  /// What makes a plan's steps in that Orchard.
  final SetupActions Function(String orchardId) actions;
}

final setupRunnerProvider = Provider<SetupRunner>((ref) {
  final service = ref.watch(orchardServiceProvider);
  final sync = ref.watch(orchardSyncProvider);
  Future<void> syncOne(String orchardId) async {
    await sync.syncOne(orchardId);
  }

  return SetupRunner(
    snapshot: (orchardId) async {
      ({bool on, int minutes})? lock;
      try {
        lock = await ref.read(deviceLockProvider.future);
      } catch (_) {
        // The plan then says nothing of this device's lock.
      }
      return readSetupSnapshot(service, orchardId,
          sync: () => syncOne(orchardId), lock: lock, provenDomains: () => ref.read(orchardProvenDomainsProvider(orchardId).future));
    },
    actions: (orchardId) => OrchardSetupActions(service, orchardId, sync: () => syncOne(orchardId)),
  );
});
