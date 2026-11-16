import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/features/networks/data/network_repository.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';

/// The stream every live "current network" reads (NetworkDetector.watch and
/// watchMatch: the banner, the status bar, the port forwards that start by
/// network) detected again only when connectivity_plus's list mapped to
/// another single kind. A VPN coming up over Wi-Fi is [wifi, vpn], still
/// "wifi", so nothing was detected again and a "VPN is up" network never
/// became the current one.
class _Repo implements NetworkRepository {
  _Repo(this._networks);
  final List<Network> _networks;

  @override
  Future<List<Network>> list() async => _networks;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('${invocation.memberName}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const methods = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const changes = EventChannel('dev.fluttercommunity.plus/connectivity_status');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<String> now;
  MockStreamHandlerEventSink? sink;

  setUp(() {
    now = ['wifi'];
    sink = null;
    messenger.setMockMethodCallHandler(methods, (call) async => call.method == 'check' ? now : null);
    messenger.setMockStreamHandler(changes, MockStreamHandler.inline(onListen: (arguments, events) => sink = events));
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(methods, null);
    messenger.setMockStreamHandler(changes, null);
  });

  Future<void> until(bool Function() check) async {
    for (var i = 0; i < 400 && !check(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Network network(String id, List<NetworkTrigger> triggers) =>
      Network(id: id, name: id, color: GroupColor.blue, icon: LucideIcons.globe, triggers: triggers, isFallback: false);

  test('a VPN coming up over Wi-Fi, and going down again, changes the current network', () async {
    final detector = NetworkDetector(_Repo([
      network('vpn', const [ConnectivityTrigger(ConnectivityKind.vpn)]),
      Network.systemDefault(),
    ]));
    final seen = <String>[];
    final sub = detector.watchMatch().listen((m) => seen.add(m.network.id));
    // Not waited for: the platform channel's stream does not answer its cancel here.
    addTearDown(() => unawaited(sub.cancel()));
    await until(() => seen.isNotEmpty && sink != null);
    expect(seen, [Network.systemDefault().id]);

    sink!.success(['wifi']); // the platform's first word: Wi-Fi, as it was
    await until(() => seen.length == 2);
    now = ['wifi', 'vpn'];
    sink!.success(now); // the VPN connects, Wi-Fi under it
    await until(() => seen.length == 3);
    expect(seen.last, 'vpn', reason: 'the VPN coming up must make the networks be detected again; seen: $seen');

    now = ['wifi'];
    sink!.success(now); // the VPN goes down
    await until(() => seen.length == 4);
    expect(seen.last, Network.systemDefault().id, reason: 'seen: $seen');
  }, timeout: const Timeout(Duration(seconds: 30)));
}
