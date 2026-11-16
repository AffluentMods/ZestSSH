// The vendored Windows speech plugin (packages/speech_to_text_windows): a phrase with a quote mark
// reaches the app as it was said, the plugin's native code posts every call into Dart to the
// platform thread and prints nothing, and the app builds against this copy, not pub.dev's.
//
// The native side is checked by reading its source: a real dictation on Windows is a check by hand.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:speech_to_text_windows/speech_to_text_windows.dart';

const _channel = MethodChannel('speech_to_text_windows');
const _pluginDir = 'packages/speech_to_text_windows';

/// What the native plugin sends for one recognition: a map, as SendTextRecognition builds it.
Future<void> _nativeSends(String words, {required bool isFinal}) async {
  final message = const StandardMethodCodec().encodeMethodCall(
    MethodCall('textRecognition', {'recognizedWords': words, 'finalResult': isFinal}),
  );
  await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .handlePlatformMessage(_channel.name, message, (_) {});
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('recognitionJson', () {
    const awkward = <String>[
      'echo "hello world"',
      r'C:\Users\demo\file.txt',
      'say "a \\ b" then\nnext',
      'tab\there',
      'café 日本語 🙂',
      '',
    ];

    for (final words in awkward) {
      test('gives speech_to_text the words as said: ${jsonEncode(words)}', () {
        for (final isFinal in [true, false]) {
          final json = SpeechToTextWindows.recognitionJson({
            'recognizedWords': words,
            'finalResult': isFinal,
          });
          expect(json, isNotNull);
          final result = SpeechRecognitionResult.fromJson(
            jsonDecode(json!) as Map<String, dynamic>,
          );
          expect(result.recognizedWords, words);
          expect(result.finalResult, isFinal);
          expect(result.alternates, hasLength(1));
        }
      });
    }

    test('anything other than a map with words gives nothing', () {
      expect(SpeechToTextWindows.recognitionJson(null), isNull);
      expect(SpeechToTextWindows.recognitionJson(42), isNull);
      expect(SpeechToTextWindows.recognitionJson({'finalResult': true}), isNull);
      expect(SpeechToTextWindows.recognitionJson({'recognizedWords': 3}), isNull);
    });

    test('the unescaped JSON 1.0.1 wrote for a quoted phrase is not JSON at all', () {
      // What 1.0.1 built by pasting the words between quote marks: speech_to_text's jsonDecode
      // throws on it, so the phrase was dropped.
      const words = 'echo "hi"';
      const old = '{"recognizedWords":"$words","finalResult":true,'
          '"alternates":[{"recognizedWords":"$words","confidence":0.85}],"resultType":2}';
      expect(() => jsonDecode(old), throwsFormatException);
    });
  });

  group('through speech_to_text, as the app listens', () {
    final calls = <String>[];

    setUp(() {
      calls.clear();
      SpeechToTextWindows.registerWith();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, (call) async {
        calls.add(call.method);
        switch (call.method) {
          case 'initialize':
          case 'listen':
          case 'hasPermission':
            return true;
          case 'locales':
            return <String>['en-US:English (United States)'];
        }
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_channel, null);
    });

    test('a final phrase with quote marks and a backslash reaches onResult whole', () async {
      final speech = SpeechToText.withMethodChannel();
      expect(await speech.initialize(), isTrue);
      final results = <SpeechRecognitionResult>[];
      await speech.listen(
        onResult: results.add,
        listenOptions: SpeechListenOptions(partialResults: true),
      );
      expect(calls, containsAllInOrder(['initialize', 'listen']));

      await _nativeSends('grep "error" C:\\logs', isFinal: false);
      await _nativeSends('grep "error" C:\\logs\\app.log', isFinal: true);

      expect(results.map((r) => r.recognizedWords), [
        'grep "error" C:\\logs',
        'grep "error" C:\\logs\\app.log',
      ]);
      expect(results.last.finalResult, isTrue);
    });
  });

  group('the native plugin', () {
    final cpp = File('$_pluginDir/windows/speech_to_text_windows_plugin.cpp').readAsStringSync();
    // The code only: comments may name what 1.0.1 did.
    final code = cpp
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
        .split('\n')
        .map((l) => l.replaceFirst(RegExp(r'//.*$'), ''))
        .join('\n');

    test('prints nothing', () {
      for (final printer in ['std::cout', 'std::cerr', 'printf', 'puts(', 'OutputDebugString', '<iostream>']) {
        expect(code.contains(printer), isFalse, reason: 'the plugin uses $printer');
      }
    });

    test('calls into Dart only from a task posted to the platform thread', () {
      final invokes = RegExp(r'InvokeMethod\(').allMatches(code).length;
      final posts = RegExp(r'PostToPlatformThread\(\[').allMatches(code).length;
      expect(invokes, 3, reason: 'textRecognition, notifyError and notifyStatus');
      expect(posts, invokes, reason: 'each InvokeMethod is inside a posted task');
      // No task runner on Flutter 3.50's plugin registrar: the window is how it gets there.
      expect(code, contains('HWND_MESSAGE'));
      expect(code, contains('PostMessageW'));
      expect(code, isNot(contains('.detach()')));
    });

    test('sends a recognition as a map, never JSON written by hand', () {
      expect(code, contains('flutter::EncodableMap recognition'));
      expect(code, isNot(contains(r'\"recognizedWords\"')));
    });
  });

  test('the app builds against the vendored copy, which keeps its licence', () {
    final pubspec = File('pubspec.yaml').readAsStringSync().replaceAll('\r\n', '\n');
    expect(
      pubspec,
      contains('dependency_overrides:\n  speech_to_text_windows:\n    path: $_pluginDir\n'),
    );
    final licence = File('$_pluginDir/LICENSE').readAsStringSync();
    expect(licence, contains('BSD 3-Clause License'));
    expect(licence, contains('Corner Software Development Corp.'));
    final lock = File('pubspec.lock').readAsStringSync().replaceAll('\r\n', '\n');
    expect(lock, contains('path: "$_pluginDir"'));
  });
}
