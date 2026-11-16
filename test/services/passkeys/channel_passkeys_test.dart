import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/passkeys/channel_passkeys.dart';
import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

import 'passkey_fixtures.dart';

/// The phones' passkey ceremonies (3.3, A3 Android and A4 iOS), through the
/// channel zestssh/passkeys with the native side played here: what each is
/// handed (ZestSSH Cloud's options, cleaned, as JSON text), what comes back
/// (the system's response, as the server reads it, held field by field to
/// what the server's own software authenticator writes), and what each
/// failure the native side answers comes out as. The native code itself is
/// read at the end: every code it answers is one this side knows.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(kPasskeyChannel, null));

  /// The native side, played: [answer] is given each call and its result
  /// returned; the calls are kept.
  List<MethodCall> play(Object? Function(MethodCall call) answer) {
    final calls = <MethodCall>[];
    messenger.setMockMethodCallHandler(kPasskeyChannel, (call) async {
      calls.add(call);
      return answer(call);
    });
    return calls;
  }

  group('isAvailable', () {
    test('is what the native side says (Android 9 and Credential Manager there, iOS 16)', () async {
      play((_) => true);
      expect(await ChannelPasskeys().isAvailable(), isTrue);
      play((_) => false);
      expect(await ChannelPasskeys().isAvailable(), isFalse);
    });

    test('is false where the native side fails or is not there', () async {
      play((_) => throw PlatformException(code: 'failed'));
      expect(await ChannelPasskeys().isAvailable(), isFalse);
      messenger.setMockMethodCallHandler(kPasskeyChannel, null);
      expect(await ChannelPasskeys().isAvailable(), isFalse);
    });
  });

  group('create', () {
    test('hands over the server\'s options as JSON text, and answers the new passkey as the server reads it',
        () async {
      final fixture = softAuthenticator();
      final options = at(fixture, ['creation_options']);
      final registration = at(fixture, ['android', 'registration']);
      final calls = play((_) => jsonEncode(registration));
      final made = await ChannelPasskeys().create(options);

      expect(calls.single.method, 'create');
      final handed = jsonDecode((calls.single.arguments as Map)['options'] as String);
      expectSameFields(handed, creationOptionsForPlatform(options));
      // What the server reads: the response its own authenticator wrote,
      // field by field, the origin the system wrote for the app's key.
      expectSameFields(made, registration);
      final clientData = jsonDecode(utf8.decode(bytesOf(at(made, ['response'])['clientDataJSON']! as String)));
      expect(clientData['origin'], fixture['android_origin']);
    });

    test('answers a provider\'s padded, standard-alphabet response as the server reads it', () async {
      final fixture = softAuthenticator();
      final registration = at(fixture, ['android', 'registration']);
      final inner = registration['response']! as Map<String, Object?>;
      String padded(String b64u) => b64u.padRight((b64u.length + 3) ~/ 4 * 4, '=');
      play((_) => jsonEncode({
            ...registration,
            'id': padded(registration['id']! as String),
            'rawId': padded(registration['rawId']! as String).replaceAll('-', '+').replaceAll('_', '/'),
            'response': {...inner, 'attestationObject': padded(inner['attestationObject']! as String)},
          }));
      expectSameFields(await ChannelPasskeys().create(at(fixture, ['creation_options'])), registration);
    });

    test('options without a challenge never reach the native side', () async {
      final calls = play((_) => fail('called'));
      final options = at(softAuthenticator(), ['creation_options'])..remove('challenge');
      await expectLater(ChannelPasskeys().create(options), throwsA(isA<PasskeyError>()));
      expect(calls, isEmpty);
    });

    test('an answer for another challenge, or none, is refused', () async {
      final fixture = softAuthenticator();
      play((_) => jsonEncode(at(fixture, ['android', 'authentication'])));
      await expectLater(
        ChannelPasskeys().create(at(fixture, ['creation_options'])),
        throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'failed')),
      );
      play((_) => null);
      await expectLater(
        ChannelPasskeys().create(at(fixture, ['creation_options'])),
        throwsA(isA<PasskeyError>().having((e) => e.detail, 'detail', contains('none'))),
      );
    });
  });

  group('get', () {
    test('hands over the server\'s sign-in options, and answers the passkey\'s answer as the server reads it',
        () async {
      final fixture = softAuthenticator();
      final options = at(fixture, ['android', 'request']);
      final authentication = at(fixture, ['android', 'authentication']);
      final calls = play((_) => jsonEncode(authentication));
      final used = await ChannelPasskeys().get(options);

      expect(calls.single.method, 'get');
      expectSameFields(
          jsonDecode((calls.single.arguments as Map)['options'] as String), requestOptionsForPlatform(options));
      expectSameFields(used, authentication);
    });
  });

  group('what the native side answers when it fails', () {
    Future<Object?> failure(String code, [String? message]) async {
      play((_) => throw PlatformException(code: code, message: message));
      try {
        await ChannelPasskeys().get(at(softAuthenticator(), ['web', 'request']));
      } catch (e) {
        return e;
      }
      return null;
    }

    test('the person closed the sheet, or it timed out: cancelled, no error', () async {
      expect(await failure('cancelled'), isA<PasskeyCancelled>());
    });

    test('each code a screen is written for comes out as itself, the system\'s words its detail', () async {
      for (final code in ['no-credential', 'invalid-state', 'security', 'unsupported', 'failed']) {
        final error = await failure(code, 'androidx.credentials.TYPE_SOMETHING');
        expect(error, isA<PasskeyError>().having((e) => e.code, 'code', code), reason: code);
        expect((error! as PasskeyError).detail, 'androidx.credentials.TYPE_SOMETHING');
      }
    });

    test('any other code is failed, with the code kept for Copy details; a long detail is cut', () async {
      final error = await failure('busy', 'x' * 1000);
      expect(error, isA<PasskeyError>().having((e) => e.code, 'code', 'failed'));
      expect((error! as PasskeyError).detail, startsWith('busy: xxx'));
      expect((error as PasskeyError).detail!.length, lessThan(320));
    });

    test('no native side at all: unsupported', () async {
      messenger.setMockMethodCallHandler(kPasskeyChannel, null);
      await expectLater(
        ChannelPasskeys().create(at(softAuthenticator(), ['creation_options'])),
        throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'unsupported')),
      );
    });
  });

  group('the native sides', () {
    // As checked out on any machine (Windows' checkouts end lines with CR LF).
    String read(String path) => File(path).readAsStringSync().replaceAll('\r\n', '\n');
    final kotlin = read('android/app/src/main/kotlin/com/affluentlabs/zestssh/passkeys/PasskeyChannel.kt');
    final swift = read('ios/Runner/PasskeyChannel.swift');
    const known = {'cancelled', 'no-credential', 'invalid-state', 'security', 'unsupported', 'failed'};

    test('answer on this channel', () {
      expect(kPasskeyChannel.name, 'zestssh/passkeys');
      expect(kotlin, contains('const val CHANNEL = "zestssh/passkeys"'));
      expect(swift, contains('static let name = "zestssh/passkeys"'));
      for (final method in ['"isAvailable"', '"create"', '"get"']) {
        expect(kotlin, contains(method));
        expect(swift, contains(method));
      }
    });

    test('answer only codes this side knows', () {
      final kotlinCodes = {
        ...RegExp(r'result\.error\("([a-z-]+)"').allMatches(kotlin).map((m) => m[1]!),
        ...RegExp(r'-> "([a-z-]+)"').allMatches(kotlin).map((m) => m[1]!),
        ...RegExp(r'"([a-z-]+)" to e\.type').allMatches(kotlin).map((m) => m[1]!),
      };
      final swiftCodes = {
        ...RegExp(r'FlutterError\(code: "([a-z-]+)"').allMatches(swift).map((m) => m[1]!),
        ...RegExp(r'fail\("([a-z-]+)"').allMatches(swift).map((m) => m[1]!),
      };
      expect(kotlinCodes, containsAll(['cancelled', 'no-credential', 'invalid-state', 'security', 'unsupported']));
      expect(swiftCodes, containsAll(['cancelled', 'no-credential', 'invalid-state', 'security', 'unsupported']));
      expect(known.containsAll(kotlinCodes), isTrue, reason: '$kotlinCodes');
      expect(known.containsAll(swiftCodes), isTrue, reason: '$swiftCodes');
    });

    test('Android: Credential Manager, the cancels and the missing passkey told apart, from Android 9', () {
      expect(kotlin, contains('CreatePublicKeyCredentialRequest(options)'));
      expect(kotlin, contains('GetPublicKeyCredentialOption(options)'));
      expect(kotlin, contains('is CreateCredentialCancellationException -> "cancelled"'));
      expect(kotlin, contains('is GetCredentialCancellationException -> "cancelled"'));
      expect(kotlin, contains('is NoCredentialException -> "no-credential"'));
      expect(kotlin, contains('is InvalidStateError -> "invalid-state"'));
      expect(kotlin, contains('is SecurityError -> "security"'));
      expect(kotlin, contains('Build.VERSION_CODES.P'));
      final activity = read('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt');
      expect(activity, contains('PasskeyChannel(this, flutterEngine.dartExecutor.binaryMessenger)'));
      expect(activity, contains('passkeys?.dispose()'));
      final gradle = read('android/app/build.gradle.kts');
      expect(gradle, contains('implementation("androidx.credentials:credentials:'));
      expect(gradle, contains('implementation("androidx.credentials:credentials-play-services-auth:'));
      expect(gradle, contains('minSdk = 26'));
      // A release build keeps the provider Android 9 to 13 find by reflection.
      expect(read('android/app/proguard-rules.pro'), contains('-keep class androidx.credentials.playservices.** {'));
    });

    test('the Mac (4.0): the iPhone\'s ceremony, from macOS 13, only in a build macOS shows the sheet for', () {
      final mac = read('macos/Runner/PasskeyChannel.swift');
      expect(mac, contains('static let name = "zestssh/passkeys"'));
      for (final method in ['"isAvailable"', '"create"', '"get"']) {
        expect(mac, contains(method));
      }
      final macCodes = {
        ...RegExp(r'FlutterError\(code: "([a-z-]+)"').allMatches(mac).map((m) => m[1]!),
        ...RegExp(r'fail\("([a-z-]+)"').allMatches(mac).map((m) => m[1]!),
      };
      expect(macCodes, containsAll(['cancelled', 'no-credential', 'invalid-state', 'security', 'unsupported']));
      expect(known.containsAll(macCodes), isTrue, reason: '$macCodes');

      // The same requests as a phone's, and nothing of UIKit.
      expect(mac, contains('ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)'));
      expect(mac, contains('ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)'));
      expect(mac, contains('import FlutterMacOS'));
      expect(mac, isNot(contains('UIKit')));
      expect(mac, isNot(contains('UIWindow')));
      expect(mac, contains('#available(macOS 13.0, *)'));
      expect(mac, isNot(contains('#available(iOS')));
      // What reads the options and writes the answer is the phone's, to the letter.
      String helpers(String text) => text.substring(text.indexOf('/// What the options lacked.'));
      expect(helpers(mac), helpers(swift));
      // The Mac app is built for macOS 11, and three of those helpers name
      // types the system has only from macOS 12: each carries the mark, or
      // the Mac build stops (found by a type check on a Mac:
      // the file had gone to master without one).
      const mark = '@available(macOS 13.0, iOS 16.0, *)';
      for (final declaration in const [
        '  var keyTransports: [ASAuthorizationSecurityKeyPublicKeyCredentialDescriptor.Transport] {',
        'private func userVerificationOf(',
        'private func residentKeyOf(',
      ]) {
        final at = mac.indexOf(declaration);
        expect(at, greaterThan(0), reason: declaration);
        expect(mac.substring(0, at).trimRight(), endsWith(mark), reason: declaration);
      }
      expect(read('macos/Runner.xcodeproj/project.pbxproj'), contains('MACOSX_DEPLOYMENT_TARGET = 11.0;'));

      // A build with no associated domains entitlement has no passkeys here:
      // macOS would refuse it before any sheet, so the app is told so and
      // goes through the website, as every Mac did before 4.0.
      expect(mac, contains('result(PasskeyChannel.mayAskForPasskeys)'));
      expect(mac, contains('guard PasskeyChannel.mayAskForPasskeys else {'));
      expect(mac, contains('SecTaskCopyValueForEntitlement('));
      expect(mac, contains('"com.apple.developer.associated-domains"'));
      expect(mac, contains('hasPrefix("webcredentials:zestssh.com")'));

      // Compiled into the app and started with its window.
      final project = read('macos/Runner.xcodeproj/project.pbxproj');
      expect('PasskeyChannel.swift in Sources'.allMatches(project).length, 2);
      expect(read('macos/Runner/MainFlutterWindow.swift'), contains('passkeys = PasskeyChannel(messenger:'));
    });

    test('iOS: passkeys and security keys for the RP ID asked, from iOS 16, in a file the app compiles', () {
      expect(swift, contains('ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)'));
      expect(swift, contains('ASAuthorizationSecurityKeyPublicKeyCredentialProvider(relyingPartyIdentifier: rpId)'));
      expect(swift, contains('guard #available(iOS 16.0, *)'));
      // A security key's passkey, made or used, is another device's.
      expect('attachment: "cross-platform"'.allMatches(swift).length, 2);
      expect(swift, contains('case ASAuthorizationError.Code.canceled.rawValue:\n'
          '      return FlutterError(code: "cancelled"'));
      final delegate = read('ios/Runner/AppDelegate.swift');
      expect(delegate, contains('passkeys = PasskeyChannel(messenger: controller.binaryMessenger)'));
      expect(read('ios/Runner/Runner.entitlements'), contains('<string>webcredentials:zestssh.com</string>'));
      // In the Runner target's sources (a file in the folder alone is not
      // compiled): its build file, and that build file in the Sources phase.
      final project = read('ios/Runner.xcodeproj/project.pbxproj');
      expect('/* PasskeyChannel.swift in Sources */'.allMatches(project).length, 2);
      expect('/* PasskeyChannel.swift */'.allMatches(project).length, 3);
    });
  });
}
