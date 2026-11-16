// One ZestSSH on Windows: a zestssh:// link
// opened in a browser started a second ZestSSH instead of handing the link to
// the one running. Now the second start finds the running one (a mutex per
// session, its main window marked), hands its link over (WM_COPYDATA),
// brings that window to the front and ends; the running one gives the link to
// Dart on the deep link channel, keeping what comes while Dart is not yet
// listening. The C++ runner cannot run here: these read its code for what
// ties it to the app's Dart side, and drive that side as the runner does.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/services/deep_link_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.affluentlabs.zestssh/deeplink');
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group("the Windows runner's code", () {
    final main = read('windows/runner/main.cpp');
    final window = read('windows/runner/flutter_window.cpp');
    final single = read('windows/runner/single_instance.cpp');
    final header = read('windows/runner/single_instance.h');

    test('talks to Dart on the channel DeepLinkService listens on, with the calls it knows', () {
      final dart = read('lib/services/deep_link_service.dart');
      final name = RegExp(r"MethodChannel\('([^']+)'\)").firstMatch(dart)!.group(1);
      expect(name, channel.name);
      expect(window, contains('kDeepLinkChannel[] = "${channel.name}"'));
      expect(window, contains('call.method_name() == "getInitialLink"'));
      expect(dart, contains("'getInitialLink'"));
      expect(window, contains('"onDeepLink"'));
      expect(dart, contains("case 'onDeepLink':"));
      // Dart's other calls on the channel are not Windows': answered as not
      // there, which Dart takes as before (MissingPluginException).
      expect(window, contains('result->NotImplemented();'));
    });

    test('decides before any window or engine is made, and a terminal command runs on its own', () {
      final decide = main.indexOf('single_instance::AnotherIsRunning()');
      expect(decide, greaterThan(0));
      expect(decide, lessThan(main.indexOf('FlutterWindow window(project);')));
      expect(decide, lessThan(main.indexOf('flutter::DartProject project')));
      expect(main, contains('!single_instance::RunsOnItsOwn(command_line_arguments) &&'));
      expect(single, contains('return !args.empty() && args.front() == "admin";'));
      // As lib/main.dart reads its command line.
      expect(read('lib/main.dart'), contains("args.first == 'admin'"));
      // Where the running one does not take the link, this one starts as
      // before (the link on its command line).
      expect(main, contains('single_instance::HandToRunningInstance(\n          single_instance::LinkArgument(command_line_arguments))) {\n    return EXIT_SUCCESS;'));
    });

    test('only the main window is found: one mark, set where the main engine is made, none on detached windows', () {
      expect(RegExp(r'MarkMainWindow\(').allMatches(window).length, 1);
      final created = window.indexOf('bool FlutterWindow::OnCreate()');
      final multi = window.indexOf('DesktopMultiWindowSetWindowCreatedCallback');
      final mark = window.indexOf('single_instance::MarkMainWindow(GetHandle());');
      expect(mark, greaterThan(created));
      expect(mark, lessThan(multi), reason: "not in the detached windows' callback");
      expect(window, contains('single_instance::UnmarkMainWindow(GetHandle());'));
      // One mutex per session (Local\), a debug build apart from an installed one.
      expect(single, contains(r'L"Local\\ZestSSH.SingleInstance"'));
      expect(single, contains(r'L"Local\\ZestSSH.SingleInstance.Debug"'));
      expect(read('windows/runner/CMakeLists.txt'), contains('"single_instance.cpp"'));
    });

    // Found in a security review: any program
    // on the desktop can mark a window. test/windows_runner builds and runs it.
    test('hands a link only to a window of a ZestSSH, named as the hand-over names the two copies', () {
      expect(single, contains('if (::GetPropW(hwnd, kWindowTag) != nullptr && IsZestSsh(hwnd)) {'));
      expect(single, contains('QueryFullProcessImageNameW'));
      expect(single, contains('theirs >= mine'));
      expect(single, contains('TokenIsAppContainer'));
      final store = read('lib/services/store_handover.dart');
      final family = RegExp(r"packageFamily = '([^']+)'").firstMatch(store)![1];
      expect(single, contains('kStorePackageFamily[] = L"$family"'));
      final key = RegExp(r"uninstallKey =\s*r'([^']+)'").firstMatch(store)![1]!;
      final cKey = RegExp(r'kUninstallKey\[\] =\s*L"([^"]+)"\s*L"([^"]+)"').firstMatch(single)!;
      expect('${cKey[1]}${cKey[2]}'.replaceAll(r'\\', r'\'), key);
    });

    test('takes only its own message, a link no longer than a share link, and only a zestssh:// one on to Dart', () {
      expect(header, contains('kMaxLinkChars = 12 * 1024;'));
      expect(ConnectionShareUrlService.maxLinkChars, 12 * 1024);
      expect(single, contains('data->dwData != kLinkCopyDataId'));
      expect(single, contains('data->cbData > (kMaxLinkChars + 1) * sizeof(wchar_t)'));
      expect(single, contains('if (!StartsWithScheme(link)) {\n    return std::string();'));
      // To the front: from minimised, from the tray, with the right the
      // second start (the person's click) passes on.
      expect(single, contains('::ShowWindow(hwnd, SW_RESTORE);'));
      expect(single, contains('::ShowWindow(hwnd, SW_SHOW);'));
      expect(single, contains('::AllowSetForegroundWindow(pid);'));
      expect(single, contains('::SetForegroundWindow(hwnd);'));
      // Kept until Dart listens, then given to it.
      expect(window, contains('pending_links_.push_back(link);'));
      expect(window, contains('dart_listening_ = true;'));
    });
  });

  group('the Dart side, as the runner drives it', () {
    setUp(DeepLinkService.debugForgetInitialLink);
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));

    Future<void> handed(String link) async {
      final message = channel.codec.encodeMethodCall(MethodCall('onDeepLink', link));
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(channel.name, message, (_) {});
    }

    test('links handed over while the app started, given when Dart asks getInitialLink, all reach the app', () async {
      final share = ConnectionShareUrlService.buildShareUrl(label: 'web 01', host: 'web-01.example.com', port: 22).toString();
      // The runner: what it kept goes to Dart once Dart asks, after the
      // answer (none: the link this start was opened with is on its command
      // line); the automation call is not Windows'.
      final kept = ['zestssh://connect?id=h-1', share];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'getInitialLink') {
          Future<void>(() async {
            for (final link in kept) {
              await handed(link);
            }
          });
          return null;
        }
        throw MissingPluginException();
      });
      await DeepLinkService.init();
      await pumpEventQueue();
      final came = <Uri>[];
      final listening = DeepLinkService.linkStream.listen(came.add);
      addTearDown(listening.cancel);
      await pumpEventQueue();
      expect([DeepLinkService.initialLink, ...came], [Uri.parse(kept[0]), Uri.parse(share)]);

      // Once it listens, a link handed over goes to it at once.
      await handed('zestssh://connect?id=h-2');
      await pumpEventQueue();
      expect(came.last, Uri.parse('zestssh://connect?id=h-2'));
    });
  });
}
