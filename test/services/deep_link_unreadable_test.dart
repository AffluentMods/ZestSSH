import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/deep_link_service.dart';

/// `zestssh://x?a=%FF` stopped a cold start (found in a security review):
/// Uri parses it and throws where its query is decoded, out of
/// DeepLinkService.init(), so any page that opened it while the app was closed got
/// the failed-to-start screen, and Try again read the same link again. A link
/// that cannot be read is said once now, and the app starts.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.affluentlabs.zestssh/deeplink');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(DeepLinkService.debugForgetInitialLink);
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    DeepLinkService.debugForgetInitialLink();
  });

  void opensWith(String link) => messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialLink') return link;
        return null;
      });

  const unreadable = [
    'zestssh://settings?a=%FF',
    'zestssh://connect?host=%C0%AF',
    'zestssh://join#%FF',
    'zestssh://connection/edit/%FF',
    'zestssh://x?%FF=1',
  ];

  for (final link in unreadable) {
    test('$link as the app starts: it starts, and it is said once', () async {
      opensWith(link);
      await DeepLinkService.init();
      expect(DeepLinkService.initialLink, isNull, reason: 'nothing is done with it');
      expect(DeepLinkService.takeUnreadableLink(), isTrue);
      expect(DeepLinkService.takeUnreadableLink(), isFalse, reason: 'said once');
    });
  }

  test('on a computer: the same link from the command line does not throw either, and is said', () {
    DeepLinkService.injectLink(Uri.parse('zestssh://settings?a=%FF'));
    expect(DeepLinkService.initialLink, isNull);
    expect(DeepLinkService.takeUnreadableLink(), isTrue);
  });

  test('one that comes while the app runs is said to whoever listens', () async {
    await DeepLinkService.init();
    var said = 0;
    final listening = DeepLinkService.unreadableLinks.listen((_) => said++);
    addTearDown(listening.cancel);
    final message = channel.codec.encodeMethodCall(const MethodCall('onDeepLink', 'zestssh://settings?a=%FF'));
    await messenger.handlePlatformMessage(channel.name, message, (_) {});
    await pumpEventQueue();
    expect(said, 1);
    expect(DeepLinkService.takeUnreadableLink(), isFalse);
  });

  test('a link that reads well is taken as ever, and nothing is said', () async {
    opensWith('zestssh://settings?a=%C3%A9');
    await DeepLinkService.init();
    expect(DeepLinkService.initialLink, Uri.parse('zestssh://settings?a=%C3%A9'));
    expect(DeepLinkService.takeUnreadableLink(), isFalse);
  });
}
