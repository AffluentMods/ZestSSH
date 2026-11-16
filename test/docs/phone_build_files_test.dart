import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// What a phone's build files have to say for two things of 4.0 to hold,
/// read as text (neither can be run here):
///
/// - An Android build from a clone of the repository, which has no
///   google-services.json: the Google services
///   plugin is applied only where the file is there, and a build made as the
///   release stops where it is missing, so the release is never built without
///   Firebase.
/// - A FIDO2 security key held to the phone or plugged into it
///   (lib/services/fido/): Android asks for NFC and requires neither NFC nor
///   a USB port to install; an iPhone's build says why it uses NFC, names
///   the FIDO applet, and asks for the NFC capability.
void main() {
  String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');

  group('Android builds with no Firebase file', () {
    final gradle = read('android/app/build.gradle.kts');

    test('the Google services plugin is not among the plugins applied always', () {
      final plugins = RegExp(r'plugins\s*\{(.*?)\n\}', dotAll: true).firstMatch(gradle)!.group(1)!;
      expect(plugins, isNot(contains('google-services')));
      expect(plugins, contains('dev.flutter.flutter-gradle-plugin'));
    });

    test('it is applied where the file is there, and a build made as the release stops without it', () {
      expect(gradle, contains('if (file("google-services.json").exists())'));
      expect(gradle, contains('apply(plugin = "com.google.gms.google-services")'));
      expect(gradle, contains('it.trim() == "ZEST_OFFICIAL=true"'));
      expect(gradle, contains('throw GradleException('));
    });

    test('the file itself is not in the repository', () {
      expect(read('.gitignore'), contains('google-services.json'));
    });
  });

  group('a security key on a phone', () {
    test('Android: NFC is asked for, and neither NFC nor USB host is needed to install', () {
      final manifest = read('android/app/src/main/AndroidManifest.xml');
      expect(manifest, contains('<uses-permission android:name="android.permission.NFC" />'));
      expect(manifest, contains('<uses-feature android:name="android.hardware.nfc" android:required="false" />'));
      expect(manifest, contains('<uses-feature android:name="android.hardware.usb.host" android:required="false" />'));
      // No USB device filter: plugging a security key in must not start the app.
      expect(manifest, isNot(contains('USB_DEVICE_ATTACHED')));
    });

    test('Android and iPhone answer the same channel as the app asks on', () {
      const channel = 'zestssh/fido';
      expect(read('lib/services/fido/fido_platform.dart'), contains("MethodChannel('$channel')"));
      expect(read('android/app/src/main/kotlin/com/affluentlabs/zestssh/fido/FidoChannel.kt'),
          contains('const val CHANNEL = "$channel"'));
      expect(read('ios/Runner/FidoChannel.swift'), contains('FlutterMethodChannel(name: "$channel"'));
      expect(read('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt'), contains('FidoChannel(this,'));
      expect(read('ios/Runner/AppDelegate.swift'), contains('FidoChannel(messenger:'));
    });

    test('iPhone: why NFC is used, the FIDO applet, the capability, and the file in the project', () {
      final plist = read('ios/Runner/Info.plist');
      expect(plist, contains('<key>NFCReaderUsageDescription</key>'));
      expect(
        RegExp(r'<key>com\.apple\.developer\.nfc\.readersession\.iso7816\.select-identifiers</key>\s*<array>\s*'
                r'<string>A0000006472F0001</string>\s*</array>')
            .hasMatch(plist),
        isTrue,
      );
      final entitlements = read('ios/Runner/Runner.entitlements');
      expect(
        RegExp(r'<key>com\.apple\.developer\.nfc\.readersession\.formats</key>\s*<array>\s*<string>TAG</string>\s*</array>')
            .hasMatch(entitlements),
        isTrue,
      );
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect('FidoChannel.swift in Sources'.allMatches(project).length, 2, reason: 'a build file and a Sources entry');
      expect(RegExp(r'path = FidoChannel\.swift;').hasMatch(project), isTrue);
    });
  });
}
