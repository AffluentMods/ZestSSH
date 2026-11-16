import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// How a phone hands the app what it was opened for, how a release build is
/// signed, and what is kept out of the repository (found in
/// a security review).
///
/// Android's, iOS's and Gradle's files do not run here: they are read.
void main() {
  final activity =
      File('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt').readAsStringSync();
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
  final mainActivity = manifest
      .split('<activity')
      .firstWhere((part) => part.contains('android:name=".MainActivity"'))
      .split('</activity>')
      .first;

  test("a link reaches the app through its own channel alone: Flutter's deep linking is off", () {
    // Flutter's own deep linking, on by default, handed any zestssh://
    // link's path to the router as a page to open, past the channel that
    // asks before anything acts.
    expect(mainActivity,
        matches(RegExp(r'<meta-data\s+android:name="flutter_deeplinking_enabled"\s+android:value="false"\s*/>')));
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    expect(plist, matches(RegExp(r'<key>FlutterDeepLinkingEnabled</key>\s*<false/>')));
  });

  test('what the app was started for is answered once: not again from Recents, nor once Android made it again', () {
    expect(activity,
        contains('(intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY) != 0'));
    expect(activity, contains('launchAnswered = savedInstanceState != null || launchedFromHistory(intent)'));
    expect(activity, contains('initialLink = if (launchAnswered) null else intent?.data?.toString()'));
    // The automation once, and none for a launch answered before.
    expect(activity,
        matches(RegExp(r'"getInitialAutomation" -> \{[^}]*?'
            r'val automationData = if \(launchAnswered\) null else buildAutomationPayload\(intent\)\s*'
            r'launchAnswered = true\s*'
            r'result\.success\(automationData\)')));
    // Set before the activity is made (super.onCreate), where the link is read.
    final onCreate = activity.substring(activity.indexOf('override fun onCreate('));
    expect(onCreate.indexOf('launchAnswered = '), lessThan(onCreate.indexOf('super.onCreate(savedInstanceState)')));
  });

  test('a release build is signed with the upload key, or by name with the debug key, never quietly with it', () {
    final gradle = File('android/app/build.gradle.kts').readAsStringSync().replaceAll('\r\n', '\n');
    final release = RegExp(r'buildTypes \{\s*release \{(.*?)\n        \}', dotAll: true).firstMatch(gradle)!.group(1)!;
    expect(
        release,
        matches(RegExp(r'signingConfig = if \(!keystorePropertiesFile\.exists\(\) && '
            r'project\.hasProperty\("debugSignedRelease"\)\) \{\s*'
            r'signingConfigs\.getByName\("debug"\)\s*'
            r'\} else \{\s*'
            r'signingConfigs\.getByName\("release"\)\s*\}')));
    expect('getByName("debug")'.allMatches(gradle), hasLength(1));
  });

  test('signing material of every platform is kept out of the repository', () {
    final ignored = File('.gitignore').readAsLinesSync().map((line) => line.trim()).toSet();
    expect(
        ignored,
        containsAll([
          'android/key.properties',
          '*.jks',
          '*.keystore',
          '*.pfx',
          '*.p12',
          '*.p8',
          '*.mobileprovision',
          '*.provisionprofile',
          'android/app/google-services.json',
          'ios/Runner/GoogleService-Info.plist',
          'macos/Runner/GoogleService-Info.plist',
          '.env',
        ]));
  });
}
