import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/models/host_network_override.dart';
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';

/// "(direct)" chosen as the jump host of a network's Override row (the
/// host's Networks section) means no jump on that network, whatever jump
/// host the host itself has (it was saved as no chain at
/// all, which means "as the host has it", so the host went through its own
/// jump host there anyway).
void main() {
  final now = DateTime.utc(2026, 10, 22);
  // A host reached through a jump host of its own.
  final host = Connection(
    id: 'h1',
    label: 'db',
    host: 'db.internal',
    port: 22,
    connectViaId: 'bastion',
    colorIndex: 0,
    protocol: 'ssh',
    zlibCompression: false,
    keepAliveSeconds: 0,
    envVars: '',
    forwardAgent: false,
    compatibilityMode: false,
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: now,
    updatedAt: now,
  );
  const office = Network(
    id: 'office',
    name: 'Office',
    color: GroupColor.blue,
    icon: LucideIcons.building,
    triggers: [AlwaysTrigger()],
    isFallback: false,
  );

  List<String> jumpsOn(HostNetworkOverride? override) => ConnectionResolver.mergeFromInputs(
        host: host,
        identity: null,
        override: override,
        network: office,
      ).jumpChain;

  test('(direct) chosen on a network: the host connects directly there, not through its jump host', () {
    final saved = bakeOverrideAfterPicks(null, hostId: 'h1', networkId: 'office', picks: const [(0, null)]);
    expect(saved, isNotNull, reason: 'an override that says "no jump" is kept');
    expect(saved!.jumpHostChain, isEmpty);
    expect(saved.jumpHostChain, isNotNull);
    expect(jumpsOn(saved), isEmpty);
    // Without the override, the host's own jump host.
    expect(jumpsOn(null), ['bastion']);
  });

  test('a host chosen, then (direct): direct; (direct), then a host: through that host', () {
    final direct = bakeOverrideAfterPicks(null,
        hostId: 'h1', networkId: 'office', picks: const [(0, 'other-jump'), (0, null)]);
    expect(jumpsOn(direct), isEmpty);
    final via = bakeOverrideAfterPicks(null,
        hostId: 'h1', networkId: 'office', picks: const [(0, null), (0, 'other-jump')]);
    expect(via!.jumpHostChain, ['other-jump']);
    expect(jumpsOn(via), ['other-jump']);
  });

  test('(direct), then "As the host has it": the host goes through its own jump host there again', () {
    const existing = HostNetworkOverride(id: 'o3', hostId: 'h1', networkId: 'office', port: 2222, jumpHostChain: []);
    final back = bakeOverrideAfterPicks(existing, hostId: 'h1', networkId: 'office', asHostAfter: true);
    expect(back!.jumpHostChain, isNull);
    expect(jumpsOn(back), ['bastion']);
    final picked = bakeOverrideAfterPicks(null,
        hostId: 'h1', networkId: 'office', picks: const [(0, null)], asHostAfter: true);
    expect(picked?.jumpHostChain, isNull, reason: 'nothing else set: no override kept, or one without a chain');
  });

  test('a saved (direct) stays direct when the host is saved again', () {
    const existing = HostNetworkOverride(id: 'o1', hostId: 'h1', networkId: 'office', jumpHostChain: []);
    final again = bakeOverrideAfterPicks(existing, hostId: 'h1', networkId: 'office');
    expect(again!.jumpHostChain, isNotNull);
    expect(again.jumpHostChain, isEmpty);
    expect(again.id, 'o1');
    expect(jumpsOn(again), isEmpty);
  });

  test('an override that chooses no jump host keeps the host\'s own', () {
    const existing = HostNetworkOverride(id: 'o2', hostId: 'h1', networkId: 'office', port: 2222);
    final again = bakeOverrideAfterPicks(existing, hostId: 'h1', networkId: 'office');
    expect(again!.jumpHostChain, isNull);
    expect(jumpsOn(again), ['bastion']);
    expect(overrideJumpChain(const [], direct: false), isNull);
    expect(overrideJumpChain(const [], direct: true), isEmpty);
    expect(overrideJumpChain(const ['a'], direct: true), ['a']);
  });
}
