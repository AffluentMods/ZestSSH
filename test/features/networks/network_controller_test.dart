import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/hosts/models/host_network_override.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/state/network_controller.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

Network _net(List<NetworkTrigger> triggers, {bool isFallback = false}) {
  return Network(
    id: 'n1',
    name: 'Home',
    color: GroupColor.blue,
    icon: LucideIcons.home,
    triggers: triggers,
    isFallback: isFallback,
  );
}

HostNetworkOverride _override({String? address, List<String>? jumpChain}) {
  return HostNetworkOverride(
    id: 'o1',
    hostId: 'h1',
    networkId: 'n1',
    address: address,
    jumpHostChain: jumpChain,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  // ── Model invariant (simpleModeBlock) ────────────────────────────
  group('Network.simpleModeBlock', () {
    test('two triggers block Simple (multipleTriggers)', () {
      final net = _net(const [
        SubnetTrigger('10.0.0.0/24'),
        SubnetTrigger('192.168.0.0/24'),
      ]);
      expect(
        net.simpleModeBlock(hasHostOverrides: false, hasHostJumpChain: false),
        SimpleModeBlock.multipleTriggers,
      );
    });

    test('a host override blocks Simple (hostOverrides)', () {
      final net = _net(const [SubnetTrigger('10.0.0.0/24')]);
      expect(
        net.simpleModeBlock(hasHostOverrides: true, hasHostJumpChain: false),
        SimpleModeBlock.hostOverrides,
      );
    });

    test('a jump-host chain blocks Simple (jumpHostChain wins over overrides)',
        () {
      final net = _net(const [SubnetTrigger('10.0.0.0/24')]);
      expect(
        net.simpleModeBlock(hasHostOverrides: true, hasHostJumpChain: true),
        SimpleModeBlock.jumpHostChain,
      );
    });

    test('a single trigger with no overrides fits Simple (null)', () {
      final net = _net(const [SubnetTrigger('10.0.0.0/24')]);
      expect(
        net.simpleModeBlock(hasHostOverrides: false, hasHostJumpChain: false),
        isNull,
      );
    });

    test('the fallback AlwaysTrigger does not count toward the limit', () {
      final net = _net(const [AlwaysTrigger()], isFallback: true);
      expect(
        net.simpleModeBlock(hasHostOverrides: false, hasHostJumpChain: false),
        isNull,
      );
    });
  });

  // ── Current-network detection → suggestion ───────────────────────
  group('suggestCurrentNetwork', () {
    test('full detection: SSID + a /24 from the first IPv4', () {
      final s = suggestCurrentNetwork(const NetworkState(
        localAddresses: ['192.168.1.23'],
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'Home',
      ));
      expect(s.ssid, 'Home');
      expect(s.subnetCidr, '192.168.1.0/24');
      expect(s.hasSsid, isTrue);
      expect(s.hasSubnet, isTrue);
      expect(s.ssidBlockedByPermission, isFalse);
    });

    test('on Wi-Fi with no SSID flags a permission block', () {
      final s = suggestCurrentNetwork(const NetworkState(
        localAddresses: ['10.50.5.7'],
        connectivityKind: ConnectivityKind.wifi,
      ));
      expect(s.hasSsid, isFalse);
      expect(s.subnetCidr, '10.50.5.0/24');
      expect(s.ssidBlockedByPermission, isTrue);
    });

    test('no IPv4 address yields no subnet', () {
      final s = suggestCurrentNetwork(const NetworkState(
        localAddresses: ['fe80::1'],
        connectivityKind: ConnectivityKind.vpn,
      ));
      expect(s.hasSubnet, isFalse);
      expect(s.ssidBlockedByPermission, isFalse); // not on Wi-Fi
    });

    test('link-local addresses are skipped', () {
      final s = suggestCurrentNetwork(const NetworkState(
        localAddresses: ['169.254.1.1', '10.0.0.5'],
        connectivityKind: ConnectivityKind.ethernet,
      ));
      expect(s.subnetCidr, '10.0.0.0/24');
    });
  });

  // ── Derived-artifact expression ──────────────────────────────────
  group('derivedMatchExpression', () {
    test('canonicalises a subnet CIDR', () {
      final t = [TriggerDraft.subnet('10.50.0.0/16')];
      expect(derivedMatchExpression(t), 'ip ∈ 10.50.0.0/16');
    });

    test('empty list renders a dash', () {
      expect(derivedMatchExpression(const []), '-');
    });

    test('fallback renders "always"', () {
      expect(derivedMatchExpression(const [], isFallback: true), 'always');
    });
  });

  // ── preferredEditorMode persistence ──────────────────────────────
  group('NetworkEditModePrefs', () {
    test('defaults to Simple when unset', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await NetworkEditModePrefs.load('n1'), EditorMode.simple);
    });

    test('persists and reloads Advanced per network id', () async {
      SharedPreferences.setMockInitialValues({});
      await NetworkEditModePrefs.save('n1', EditorMode.advanced);
      expect(await NetworkEditModePrefs.load('n1'), EditorMode.advanced);
      // A different network keeps its own (default) preference.
      expect(await NetworkEditModePrefs.load('n2'), EditorMode.simple);
    });
  });

  // ── Controller behaviour ─────────────────────────────────────────
  group('NetworkEditController', () {
    test('applySuggestion fills a single subnet trigger and marks dirty', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);
      expect(c.isDirty, isFalse);

      c.applySuggestion(const CurrentNetworkSuggestion(
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'Home',
        subnetCidr: '192.168.1.0/24',
      ));

      expect(c.triggers.length, 1);
      expect(c.triggers.first.kind, TriggerKind.subnet);
      expect(c.triggers.first.toTrigger(), const SubnetTrigger('192.168.1.0/24'));
      expect(c.isDirty, isTrue);
      expect(c.lastSuggestion?.ssid, 'Home');
      c.dispose();
    });

    test('applySuggestion reports partial detection (permission) and still '
        'fills the subnet', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);

      c.applySuggestion(const CurrentNetworkSuggestion(
        connectivityKind: ConnectivityKind.wifi,
        subnetCidr: '10.50.5.0/24',
      ));

      expect(c.lastSuggestion!.ssidBlockedByPermission, isTrue);
      expect(c.triggers.single.toTrigger(), const SubnetTrigger('10.50.5.0/24'));
      c.dispose();
    });

    test('applySuggestion falls back to an SSID trigger when no subnet', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);

      c.applySuggestion(const CurrentNetworkSuggestion(
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'Cafe',
      ));

      expect(c.triggers.single.toTrigger(), const SsidTrigger('Cafe'));
      c.dispose();
    });

    test('Simple → Advanced is a lossless round-trip', () {
      // Build a network in Simple mode.
      final c1 = NetworkEditController();
      c1.bind(null, overrideRows: const [], mode: EditorMode.simple);
      c1.nameController.text = 'Home';
      c1.setColor(GroupColor.purple);
      c1.setIcon(LucideIcons.building);
      c1.applySuggestion(const CurrentNetworkSuggestion(
        connectivityKind: ConnectivityKind.wifi,
        ssid: 'Home',
        subnetCidr: '10.50.0.0/24',
      ));
      c1.setBringUpVpn('vpn-host');

      final built = c1.buildNetwork('net-1');
      expect(built.name, 'Home');
      expect(built.color, GroupColor.purple);
      expect(built.icon.codePoint, LucideIcons.building.codePoint);
      expect(built.bringUpVpn, 'vpn-host');
      expect(built.triggers.single, const SubnetTrigger('10.50.0.0/24'));
      c1.dispose();

      // Reopen it in Advanced - nothing lost.
      final c2 = NetworkEditController();
      c2.bind(built, overrideRows: const [], mode: EditorMode.advanced);
      expect(c2.mode, EditorMode.advanced);
      expect(c2.nameController.text, 'Home');
      expect(c2.color, GroupColor.purple);
      expect(c2.icon.codePoint, LucideIcons.building.codePoint);
      expect(c2.bringUpVpn, 'vpn-host');
      expect(c2.triggers.length, 1);
      expect(c2.triggers.single.kind, TriggerKind.subnet);
      expect(c2.triggers.single.toTrigger(), const SubnetTrigger('10.50.0.0/24'));
      c2.dispose();
    });

    // Simple holds every rule, how hosts are reached and every host's rule
    // (as designed): no network is too much for it.
    test('Simple holds every network: several rules, host rules, jump chains', () {
      final c = NetworkEditController();
      c.bind(_net(const [SubnetTrigger('10.0.0.0/24')]), overrideRows: const [], mode: EditorMode.simple);
      c.addTrigger(TriggerKind.ssid);
      expect(c.simpleBlock, isNull);
      expect(c.simpleBlockedReason(l10n), isNull);
      c.dispose();

      final rich = NetworkEditController();
      rich.bind(
        _net(const [SubnetTrigger('10.0.0.0/24'), SsidTrigger('X')]),
        overrideRows: [_override(jumpChain: const ['h2', 'h3'])],
        mode: EditorMode.simple,
      );
      expect(rich.mode, EditorMode.simple, reason: 'it opens as it was left');
      rich.setMode(EditorMode.advanced);
      rich.setMode(EditorMode.simple);
      expect(rich.mode, EditorMode.simple);
      rich.dispose();
    });

    test('a network for where this device is: its Wi-Fi as the rule and the name, else its subnet', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);
      c.startFor(const CurrentNetworkSuggestion(
          connectivityKind: ConnectivityKind.wifi, ssid: 'harbor-5G', subnetCidr: '10.50.0.0/24'));
      expect(c.triggers.single.toTrigger(), const SsidTrigger('harbor-5G'));
      expect(c.nameController.text, 'harbor-5G');
      expect(c.isDirty, isTrue);

      final d = NetworkEditController();
      d.bind(null, overrideRows: const [], mode: EditorMode.simple);
      d.startFor(const CurrentNetworkSuggestion(connectivityKind: ConnectivityKind.ethernet, subnetCidr: '10.50.0.0/24'));
      expect(d.triggers.single.toTrigger(), const SubnetTrigger('10.50.0.0/24'));
      expect(d.nameController.text, isEmpty);
      c.dispose();
      d.dispose();
    });

    test('the quick rules: Ethernet, a VPN, Tailscale as its address range', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);
      c.addConnectivity(ConnectivityKind.ethernet);
      c.addConnectivity(ConnectivityKind.vpn);
      c.addSubnet('100.64.0.0/10');
      expect(c.triggers.map((t) => t.toTrigger()), const [
        ConnectivityTrigger(ConnectivityKind.ethernet),
        ConnectivityTrigger(ConnectivityKind.vpn),
        SubnetTrigger('100.64.0.0/10'),
      ]);
      c.dispose();
    });

    test('validation blocks an empty name and empty triggers', () {
      final c = NetworkEditController();
      c.bind(null, overrideRows: const [], mode: EditorMode.simple);
      expect(c.validateName(l10n), isNotNull);
      expect(c.validateTriggers(l10n), isNotNull);

      c.nameController.text = 'Home';
      c.applySuggestion(const CurrentNetworkSuggestion(
        connectivityKind: ConnectivityKind.wifi,
        subnetCidr: '10.0.0.0/24',
      ));
      expect(c.validateName(l10n), isNull);
      expect(c.validateTriggers(l10n), isNull);
      c.dispose();
    });
  });
}
