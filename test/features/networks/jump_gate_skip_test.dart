import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';

/// The Free-tier jump-host gate: jump routing is a Squeezed feature, for the
/// base Connect Via chain and for a per-network override chain alike. This is
/// the pure decision the connect path (and the Server Monitor's silent poll)
/// applies at the one place a chain is dialed. Before it, only the base field
/// was locked in the editor, so an override chain routed freely.
void main() {
  group('ConnectionResolver.jumpGateSkip', () {
    test('Squeezed never skips, whatever the chain source', () {
      expect(
        ConnectionResolver.jumpGateSkip(
          isPro: true,
          baseHasConnectVia: true,
          overrideChangedJump: true,
          overrideChain: const ['bastion'],
          networkName: 'Home',
        ),
        isNull,
      );
      expect(
        ConnectionResolver.jumpGateSkip(
          isPro: true,
          baseHasConnectVia: true,
          overrideChangedJump: false,
          overrideChain: const [],
        ),
        isNull,
      );
    });

    test('Free: an override chain is skipped and named by its network', () {
      final skip = ConnectionResolver.jumpGateSkip(
        isPro: false,
        baseHasConnectVia: false,
        overrideChangedJump: true,
        overrideChain: const ['bastion'],
        networkName: 'Home',
      );
      expect(skip, isNotNull);
      expect(skip!.fromOverride, isTrue);
      expect(skip.networkName, 'Home');
    });

    test('Free: a multi-hop override chain is skipped the same way', () {
      final skip = ConnectionResolver.jumpGateSkip(
        isPro: false,
        baseHasConnectVia: true,
        overrideChangedJump: true,
        overrideChain: const ['edge', 'core'],
        networkName: 'Office',
      );
      expect(skip?.fromOverride, isTrue);
      expect(skip?.networkName, 'Office');
    });

    test('Free: an override that clears the jump is direct, never gated', () {
      // The override explicitly says "no jump on this network" (an empty,
      // non-null chain): a direct connection, nothing to gate, no notice.
      expect(
        ConnectionResolver.jumpGateSkip(
          isPro: false,
          baseHasConnectVia: true,
          overrideChangedJump: true,
          overrideChain: const [],
          networkName: 'Home',
        ),
        isNull,
      );
    });

    test('Free: the base Connect Via chain is skipped (synced or imported)', () {
      final skip = ConnectionResolver.jumpGateSkip(
        isPro: false,
        baseHasConnectVia: true,
        overrideChangedJump: false,
        overrideChain: const [],
      );
      expect(skip, isNotNull);
      expect(skip!.fromOverride, isFalse);
      expect(skip.networkName, isNull);
    });

    test('Free: no chain anywhere is not gated', () {
      expect(
        ConnectionResolver.jumpGateSkip(
          isPro: false,
          baseHasConnectVia: false,
          overrideChangedJump: false,
          overrideChain: const [],
        ),
        isNull,
      );
    });
  });
}
