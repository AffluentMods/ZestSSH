import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:speech_to_text_platform_interface/speech_to_text_platform_interface.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart';

/// The speech_to_text plugin as the app's speech to text uses it on a
/// computer, over a platform that sends what a test says: Windows' SAPI
/// dictation, which sends one final result for each phrase and goes on
/// listening, and a Mac's recogniser, which sends the phrases before each
/// pause apart. The plugin itself (its SpeechToText) is the real one.

/// A speech_to_text platform that hears what a test says.
class _Platform extends SpeechToTextPlatform {
  String? language = 'en-US:English (United States)';
  final listens = <SpeechListenOptions?>[];
  int stops = 0;
  bool failWithLocale = false;

  @override
  Future<bool> hasPermission() async => true;

  @override
  Future<bool> initialize({debugLogging = false, List<SpeechConfigOption>? options}) async => true;

  @override
  Future<bool> listen(
      {String? localeId,
      partialResults = true,
      onDevice = false,
      int listenMode = 0,
      sampleRate = 0,
      SpeechListenOptions? options}) async {
    listens.add(options);
    if (failWithLocale && options?.localeId != null) {
      throw PlatformException(code: 'noRecognizerError', message: 'Failed to create speech recognizer');
    }
    onStatus?.call(stt.SpeechToText.listeningStatus);
    return true;
  }

  @override
  Future<void> stop() async => stops++;

  @override
  Future<void> cancel() async {}

  @override
  Future<List<dynamic>> locales() async => [?language];

  /// A result as the platform sends it: [phrases] apart where a Mac's
  /// recogniser has them, else one phrase.
  void send(String words, {bool isFinal = true, List<String>? phrases}) {
    onTextRecognition!(jsonEncode({
      'alternates': [
        {'recognizedWords': words, 'recognizedPhrases': ?phrases, 'confidence': 0.9},
      ],
      'resultType': isFinal ? 2 : 0,
    }));
  }
}

void main() {
  late _Platform platform;
  late List<(String, bool)> heard;

  setUp(() {
    platform = _Platform();
    SpeechToTextPlatform.instance = platform;
    heard = [];
  });

  Future<SpeechToTextEngine> started({bool rearm = false, bool systemLanguage = false}) async {
    final engine = SpeechToTextEngine(
        speech: stt.SpeechToText.withMethodChannel(), rearmAfterFinal: rearm, listenInSystemLanguage: systemLanguage);
    expect(await engine.initialize(onStatus: (_) {}, onError: (_) {}), isTrue);
    await engine.listen(onWords: (words, isFinal) => heard.add((words, isFinal)));
    return engine;
  }

  group("Windows' SAPI dictation: a final result for each phrase, and it goes on listening", () {
    test('the cause of the one word stop: the plugin takes one final result for a listen, and drops the rest',
        () async {
      // As it was: nothing asked the plugin to listen again.
      await started(rearm: false);
      platform.send('git');
      platform.send('status');
      platform.send('dash dash short');
      expect(heard, [('git', true)]);
    });

    test('asked to listen again after each final result, every phrase comes through, once', () async {
      await started(rearm: true);
      platform.send('git');
      platform.send('status');
      platform.send('dash dash short');
      await pumpEventQueue();
      expect(heard, [('git', true), ('status', true), ('dash dash short', true)]);
      // (SAPI was never stopped: the plugin's own listen was readied again.)
      expect(platform.stops, 0);
      expect(platform.listens, hasLength(4));
    });

    test('what SAPI guesses on the way comes as what is being heard, then the phrase once', () async {
      await started(rearm: true);
      platform.send('git', isFinal: false);
      platform.send('git stat', isFinal: false);
      platform.send('git status');
      platform.send('ls', isFinal: false);
      platform.send('ls');
      await pumpEventQueue();
      expect(heard, [('git', false), ('git stat', false), ('git status', true), ('ls', false), ('ls', true)]);
    });

    test('stopped, it is not asked to listen again', () async {
      final engine = await started(rearm: true);
      platform.send('uptime');
      await pumpEventQueue();
      final listens = platform.listens.length;
      await engine.stop();
      expect(platform.stops, 1);
      expect(platform.listens, hasLength(listens));
    });

    test("the language is the recogniser's, as the plugin names it", () async {
      final engine = await started(rearm: true);
      expect(await engine.language(), 'English (United States)');
      // (Windows' recogniser listens in its own: none is asked for.)
      expect(platform.listens.first?.localeId, isNull);
    });
  });

  group("a Mac's recogniser: the phrases before each pause apart", () {
    test('each phrase is handed on once, as it settles; the one being heard is a guess', () async {
      await started();
      platform.send('ssh', isFinal: false, phrases: ['ssh']);
      platform.send('ssh web', isFinal: false, phrases: ['ssh web']);
      platform.send('ssh web 01 tail', isFinal: false, phrases: ['ssh web 01', 'tail']);
      platform.send('ssh web 01 tail dash f', isFinal: false, phrases: ['ssh web 01', 'tail dash f']);
      platform.send('ssh web 01 tail dash f syslog', phrases: ['ssh web 01', 'tail dash f', 'syslog']);
      expect(heard.where((h) => h.$2).map((h) => h.$1), ['ssh web 01', 'tail dash f', 'syslog']);
      expect(heard.where((h) => !h.$2).map((h) => h.$1), ['ssh', 'ssh web', 'tail', 'tail dash f']);
    });

    test("it listens in the person's first language, the one it names", () async {
      final engine = await started(systemLanguage: true);
      expect(platform.listens.single?.localeId, 'en-US');
      expect(platform.listens.single?.onDevice, isTrue);
      expect(await engine.language(), 'English (United States)');
    });

    test('where the recogniser has not got that language, in its own, unnamed', () async {
      platform.failWithLocale = true;
      final engine = await started(systemLanguage: true);
      expect(platform.listens.map((o) => o?.localeId), ['en-US', null]);
      expect(await engine.language(), isNull);
    });
  });

  test('a result with no phrases is its words', () {
    final result = SpeechRecognitionResult(const [SpeechRecognitionWords('df -h', null, 0.9)], ResultType.finalResult.value);
    expect(dictationPhrases(result), ['df -h']);
  });
}
