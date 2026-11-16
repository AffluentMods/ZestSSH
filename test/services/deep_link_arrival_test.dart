import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/services/deep_link_service.dart';

/// A `zestssh://` link the device hands the app (3.0, found
/// while comparing the five versions). One that came before the app was
/// listening for links (an iPhone hands the link it starts the app for to
/// the app as it starts) was lost; and the app's log had each link whole,
/// an automation link's key and command included.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.affluentlabs.zestssh/deeplink');

  /// The device hands the app [link] while it runs.
  Future<void> handed(String link) async {
    final message = channel.codec.encodeMethodCall(MethodCall('onDeepLink', link));
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(channel.name, message, (_) {});
  }

  setUp(() async {
    DeepLinkService.debugForgetInitialLink();
    await DeepLinkService.init();
  });

  test('a link that comes before the app listens is the one it opens with; once it listens, links come to it',
      () async {
    await handed('zestssh://connect?id=h-1');
    expect(DeepLinkService.initialLink, Uri.parse('zestssh://connect?id=h-1'));
    // Another before it listens leaves the first as it was, and is kept for
    // when it listens (it was lost: a second start of the
    // app on Windows hands its link to this one, which may still be starting).
    await handed('zestssh://connect?id=h-3');
    expect(DeepLinkService.initialLink, Uri.parse('zestssh://connect?id=h-1'));

    final came = <Uri>[];
    final listening = DeepLinkService.linkStream.listen(came.add);
    addTearDown(listening.cancel);
    await pumpEventQueue();
    expect(came, [Uri.parse('zestssh://connect?id=h-3')]);
    await handed('zestssh://connect?id=h-2');
    await pumpEventQueue();
    expect(came, [Uri.parse('zestssh://connect?id=h-3'), Uri.parse('zestssh://connect?id=h-2')]);
    expect(DeepLinkService.initialLink, Uri.parse('zestssh://connect?id=h-1'), reason: 'the first is kept as it was');
  });

  test('links before the app listens are kept to a few, in the order they came', () async {
    for (var i = 1; i <= 12; i++) {
      await handed('zestssh://connect?id=h-$i');
    }
    final came = <Uri>[];
    final listening = DeepLinkService.linkStream.listen(came.add);
    addTearDown(listening.cancel);
    await pumpEventQueue();
    expect(DeepLinkService.initialLink, Uri.parse('zestssh://connect?id=h-1'));
    expect(came, [for (var i = 2; i <= 9; i++) Uri.parse('zestssh://connect?id=h-$i')]);
  });

  test("the command line's link before the app listens is not lost to one handed over meanwhile", () async {
    // Windows: another start handed its link over while this one started,
    // which was itself opened with a link (lib/main.dart, injectLink).
    await handed('zestssh://connect?id=handed');
    DeepLinkService.injectLink(Uri.parse('zestssh://connect?id=command-line'));
    final came = <Uri>[];
    final listening = DeepLinkService.linkStream.listen(came.add);
    addTearDown(listening.cancel);
    await pumpEventQueue();
    expect({DeepLinkService.initialLink, ...came},
        {Uri.parse('zestssh://connect?id=handed'), Uri.parse('zestssh://connect?id=command-line')});
  });

  test("a host's share link longer than the 256 characters any other link's value may have reaches the app; other "
      'links are held to the caps as before', () async {
    final share = ConnectionShareUrlService.buildShareUrl(
      label: 'web 01',
      host: 'web-01.example.com',
      port: 2222,
      user: 'deploy',
      groupHint: 'Prod',
      tags: const ['web', 'eu', 'frontend'],
      forwards: const [
        SharedForward(type: 'local', bindAddress: '127.0.0.1', bindPort: 8080, remoteHost: 'db.internal', remotePort: 80, label: 'web'),
        SharedForward(type: 'local', bindAddress: '127.0.0.1', bindPort: 5432, remoteHost: 'pg.internal', remotePort: 5432, label: 'db'),
      ],
    );
    expect(share.queryParameters['d']!.length, greaterThan(256));
    final came = <Uri>[];
    final listening = DeepLinkService.linkStream.listen(came.add);
    addTearDown(listening.cancel);
    await handed(share.toString());
    // Longer than any share link can be, an add-host link's long value, and
    // another link's: refused as before.
    await handed('zestssh://share?d=${'A' * (ConnectionShareUrlService.maxLinkChars + 1)}');
    await handed('zestssh://add-host?host=web&label=${'x' * 300}');
    await handed('zestssh://connect?id=${'x' * 300}');
    await handed('zestssh://connect?id=${'x' * 10}&pad=${List.filled(30, 'y' * 200).join('&p=')}');
    await pumpEventQueue();
    expect(came, [share]);
    expect(ConnectionShareUrlService.tryParse(came.single)!.forwards, hasLength(2));
  });

  test("the app's log names a link, not what it carries", () async {
    final noted = <String>[];
    final level = Logger.root.level;
    Logger.root.level = Level.ALL;
    final listening = Logger.root.onRecord.listen((r) => noted.add(r.message));
    addTearDown(() {
      Logger.root.level = level;
      return listening.cancel();
    });
    await handed('zestssh://execute?connection=payroll-web&command=cat%20secret.env&key=zk_made-up-key');
    await pumpEventQueue();
    final said = noted.where((m) => m.contains('Deep link')).join('\n');
    expect(said, contains('zestssh://execute'));
    for (final carried in ['payroll-web', 'secret.env', 'zk_made-up-key']) {
      expect(said, isNot(contains(carried)));
    }
  });
}
