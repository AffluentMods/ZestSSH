// zestssh:// links on a Mac, on Linux and from an iPhone's Shortcuts (found
// by the docs check): a Mac had no zestssh:// scheme
// (macos/Runner/Info.plist) and nothing taking a link; Linux's tarball
// registered no handler and every start was a second ZestSSH; and an
// iPhone ran a Shortcut's command on a cold start without the question
// every link gets ("Run this from a link?"), as an automation intent. These
// read the native code for what ties it to the app's Dart side (it cannot
// run here: a Mac, an iPhone, a Linux desktop are needed for that).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
  const channel = 'com.affluentlabs.zestssh/deeplink';

  test('the channel name is the one DeepLinkService listens on', () {
    expect(read('lib/services/deep_link_service.dart'), contains("MethodChannel('$channel')"));
  });

  test('a Mac registers zestssh:// and gives each link to the app, the first as the one it opens with', () {
    final plist = read('macos/Runner/Info.plist');
    expect(plist, contains('<key>CFBundleURLTypes</key>'));
    expect(RegExp(r'<key>CFBundleURLSchemes</key>\s*<array>\s*<string>zestssh</string>').hasMatch(plist), isTrue);
    final window = read('macos/Runner/MainFlutterWindow.swift');
    expect(window, contains('name: "$channel"'));
    expect(window, contains('call.method == "getInitialLink"'));
    expect(window, contains('invokeMethod("onDeepLink", arguments: text)'));
    // Installed as the main window is made, before the launch's own Apple
    // event; only zestssh:// links.
    expect(window, contains('forEventClass: AEEventClass(kInternetEventClass)'));
    expect(window, contains('andEventID: AEEventID(kAEGetURL))'));
    expect(window, contains('url.scheme?.lowercased() == "zestssh"'));
    expect(window.indexOf('setEventHandler('), lessThan(window.indexOf('super.awakeFromNib()')));
  });

  test("an iPhone's Shortcut goes to the app only as its link, asked about first, never as an intent", () {
    final delegate = read('ios/Runner/AppDelegate.swift');
    expect(delegate, isNot(contains('invokeMethod("onAutomation"')));
    expect(delegate, contains('removeObject(forKey: "pending_automation")'));
    // The link the Shortcut opens, on a cold start and while it runs.
    expect(delegate, contains('case "getInitialLink":'));
    expect(delegate, contains('channel.invokeMethod("onDeepLink", arguments: url.absoluteString)'));
    final intents = read('ios/Runner/ZestSSHIntents.swift');
    expect(intents, contains('components.host = "execute"'));
    expect(intents, contains('await UIApplication.shared.open(url)'));
    // And the app asks before a link runs anything.
    expect(read('lib/services/deep_link_service.dart'), contains('if (!await requireConfirmation(\'execute\', command, connectionId)) {'));
  });

  test('Linux runs one ZestSSH a session, hands a second start\'s link to it, and its bundle can register the scheme', () {
    final app = read('linux/runner/my_application.cc');
    expect(app, contains('"flags",\n                                     G_APPLICATION_HANDLES_OPEN, nullptr));'));
    expect(app, isNot(contains('"flags",\n                                     G_APPLICATION_NON_UNIQUE')));
    // A terminal command runs on its own, as lib/main.dart reads it.
    expect(app, contains('strcmp(args[0], "admin") == 0'));
    expect(app, contains('G_APPLICATION_NON_UNIQUE));'));
    expect(app, contains('kDeepLinkChannel[] = "$channel"'));
    expect(app, contains('"getInitialLink"'));
    expect(app, contains('"onDeepLink"'));
    expect(app, contains('G_APPLICATION_CLASS(klass)->open = my_application_open;'));
    expect(app, contains('g_application_get_is_remote(application)'));
    expect(app, contains('gtk_window_present(self->window);'));

    final script = read('linux/packaging/install-desktop-entry.sh');
    expect(script, contains('MimeType=x-scheme-handler/zestssh;'));
    expect(script, contains(r'Exec="$here/zestssh" %u'));
    expect(script, contains('xdg-mime default com.affluentlabs.zestssh.desktop x-scheme-handler/zestssh'));
    expect(read('linux/CMakeLists.txt'), contains('install(PROGRAMS "\${CMAKE_CURRENT_SOURCE_DIR}/packaging/install-desktop-entry.sh"'));
    // The .desktop name is the app's id, which GTK gives its windows.
    expect(read('linux/CMakeLists.txt'), contains('set(APPLICATION_ID "com.affluentlabs.zestssh")'));
  });
}
