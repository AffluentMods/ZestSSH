import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter/semantics.dart' show Assertiveness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:speech_to_text/speech_recognition_result.dart' as stt show SpeechRecognitionResult;
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' show Terminal;
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/work_tab.dart' show WorkTab;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/command_text.dart';

// Speech to text into a terminal of the computer's shell (4.0, platform parity
// gap 10): the phone's mic key, on Windows and macOS, and on a tablet's large
// screen that shows the computer's shell. As on the phone it is a Squeezed
// feature, recognised on the device only, and what is heard is typed at the
// prompt as if it were typed by hand, its control characters taken out: no
// Enter is ever pressed for it, so nothing runs until the person has seen it
// and pressed Enter themselves.
//
// On a computer it listens until it is turned off (its button, its key, Esc,
// the Inspector's Speech to text, or its session leaving the screen): where
// the recogniser ends a listening by itself (macOS after a pause or a
// silence), a new one is started at once, and only a recogniser that cannot
// listen at all (no microphone, permission withdrawn) stops it, said once.

/// Whether a recogniser is there to listen with: speech_to_text has one on
/// Android, iOS, macOS (the system's speech recognition) and Windows (SAPI's
/// dictation, through speech_to_text_windows); on Linux it has none, so the
/// control is not shown there at all.
final voiceInputSupportedProvider = Provider<bool>(
    (ref) => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows));

/// Whether speech to text listens until it is turned off (a computer), where
/// a recogniser that ends by itself is started again; else (a tablet's large
/// screen, as the phone's mic) a listening ends with the recogniser's.
final dictationKeepsListeningProvider = Provider<bool>((ref) => switch (defaultTargetPlatform) {
      TargetPlatform.windows || TargetPlatform.macOS => true,
      _ => false,
    });

/// What listens: the plugin, behind this seam so that a test hears words.
abstract class DictationEngine {
  /// Gets the recogniser ready (and, on a Mac, asks for the microphone and
  /// speech recognition the first time). False where there is none, or it
  /// was not allowed. [onStatus] has speech_to_text's statuses (listening,
  /// notListening, done), [onError] its error names (error_no_match, ...).
  Future<bool> initialize({required void Function(String status) onStatus, required void Function(String error) onError});

  /// Listens; [onWords] has what is heard: final where it is settled (to be
  /// typed, each piece once), else what the recogniser guesses so far.
  /// Throws where it cannot start.
  Future<void> listen({required void Function(String words, bool isFinal) onWords});

  Future<void> stop();

  /// The language listened in, by its name, where the recogniser says.
  Future<String?> language();
}

/// The speech_to_text plugin.
class SpeechToTextEngine implements DictationEngine {
  SpeechToTextEngine({stt.SpeechToText? speech, bool? rearmAfterFinal, bool? listenInSystemLanguage})
      : _speech = speech ?? stt.SpeechToText(),
        _rearm = rearmAfterFinal ?? (!kIsWeb && Platform.isWindows),
        _inSystemLanguage = listenInSystemLanguage ?? (!kIsWeb && Platform.isMacOS);

  final stt.SpeechToText _speech;

  /// Windows' SAPI dictation goes on listening after a phrase, and sends one
  /// final result for each; speech_to_text takes one final result for a
  /// listen and drops every one after it (its listen is a phone's, which
  /// ends there). So after each final result it is asked to listen again,
  /// which only readies it for the next one: SAPI was never stopped.
  final bool _rearm;

  /// On a Mac it listens in the person's first preferred language, the one
  /// it names (the plugin's own default is the app's locale, which is the
  /// app's development language where the app bundle lists no others).
  final bool _inSystemLanguage;

  String? _localeId;
  String? _languageName;
  bool _languageAsked = false;

  /// Between [listen] and [stop]: a re-arm only then.
  bool _active = false;

  /// The phrases of this listening already handed on as final.
  int _settled = 0;
  void Function(String words, bool isFinal)? _onWords;
  void Function(String error)? _onError;

  @override
  Future<bool> initialize({required void Function(String status) onStatus, required void Function(String error) onError}) async {
    final ready = await _speech.initialize();
    // The plugin is one for the app and takes its listeners only at its first
    // initialize: this listening's, set every time.
    _speech.statusListener = onStatus;
    _speech.errorListener = (e) => onError(e.errorMsg);
    _onError = onError;
    if (ready && !_languageAsked) {
      _languageAsked = true;
      try {
        final locale = await _speech.systemLocale();
        if (locale != null && locale.localeId.isNotEmpty) {
          _languageName = locale.name.trim().isEmpty ? null : locale.name.trim();
          if (_inSystemLanguage) _localeId = locale.localeId;
        }
      } catch (_) {}
    }
    return ready;
  }

  @override
  Future<void> listen({required void Function(String words, bool isFinal) onWords}) async {
    _onWords = onWords;
    _active = true;
    await _listen();
  }

  Future<void> _listen() async {
    _settled = 0;
    try {
      await _speech.listen(onResult: _result, listenOptions: _options());
    } on stt.ListenFailedException {
      // A language the recogniser has not got: in the plugin's own instead,
      // whose name is not known.
      if (_localeId == null) rethrow;
      _localeId = null;
      _languageName = null;
      _settled = 0;
      await _speech.listen(onResult: _result, listenOptions: _options());
    }
  }

  stt.SpeechListenOptions _options() => stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        // As on the phone: recognised on the device, never by a cloud
        // service (on a Mac without on-device recognition it is not
        // available; Windows' SAPI dictation is on the device anyway).
        onDevice: true,
        localeId: _localeId,
      );

  void _result(stt.SpeechRecognitionResult result) {
    final onWords = _onWords;
    if (onWords == null) return;
    final phrases = dictationPhrases(result);
    // A Mac's recogniser sends the phrases before each pause with the one
    // being heard: those before it are settled, and typed as they settle.
    final settle = result.finalResult ? phrases.length : phrases.length - 1;
    while (_settled < settle) {
      onWords(phrases[_settled], true);
      _settled++;
    }
    if (!result.finalResult) {
      onWords(phrases.last, false);
    } else if (_rearm && _active) {
      // Started here, while the plugin is still in this callback: its
      // listening's state is reset before anything more can arrive, so no
      // phrase SAPI sends next is dropped.
      _listen().catchError((Object _) => _onError?.call('error_listen_failed'));
    }
  }

  @override
  Future<void> stop() async {
    _active = false;
    await _speech.stop();
  }

  @override
  Future<String?> language() async => _languageName;
}

/// The phrases of a speech_to_text result, in order: a Mac's recogniser
/// gives those before each pause apart (the plugin keeps them as recognized
/// phrases), every other recogniser one.
@visibleForTesting
List<String> dictationPhrases(stt.SpeechRecognitionResult result) {
  final phrases = result.alternates.isEmpty ? null : result.alternates.first.recognizedPhrases;
  if (phrases != null && phrases.isNotEmpty) return phrases;
  return [result.recognizedWords];
}

final dictationEngineProvider = Provider<DictationEngine>((ref) => SpeechToTextEngine());

/// The time, for how long a listening lasted and how long a stopped one's
/// last words are still typed; a test sets its own.
@visibleForTesting
DateTime Function() dictationClock = DateTime.now;

/// Where speech to text is listening: the session whose terminal it types
/// into, or none; what it hears; the language.
@immutable
class DictationState {
  const DictationState({
    this.sessionId,
    this.listening = false,
    this.hearing = '',
    this.lastTyped = '',
    this.language,
    this.gaveUp = 0,
  });

  final String? sessionId;
  final bool listening;

  /// What is being heard and not typed yet (the recogniser's guess so far,
  /// which can still change).
  final String hearing;

  /// What was typed last, in this listening.
  final String lastTyped;

  /// The language listened in, by its name, once the recogniser has said.
  final String? language;

  /// Goes up each time listening stopped by itself because the recogniser
  /// could not go on (no microphone, permission withdrawn): said once each
  /// time.
  final int gaveUp;

  DictationState copyWith({String? hearing, String? lastTyped, String? language}) => DictationState(
        sessionId: sessionId,
        listening: listening,
        hearing: hearing ?? this.hearing,
        lastTyped: lastTyped ?? this.lastTyped,
        language: language ?? this.language,
        gaveUp: gaveUp,
      );
}

/// What [TerminalDictation.toggle] did.
enum DictationOutcome { started, stopped, unavailable, noTerminal }

/// Speech to text for the computer's shell: one terminal at a time.
class TerminalDictation extends Notifier<DictationState> {
  /// How long a recogniser has to say it listens (or hear something) after
  /// a listen before that listen counts as one that did not start.
  static const startTimeout = Duration(seconds: 8);

  /// A listening that ends sooner than this with nothing heard ended
  /// quickly: five in a row and the recogniser is taken to be unable to
  /// listen (a restart loop is never made of them).
  static const quickEnd = Duration(milliseconds: 1500);
  static const quickEndsToGiveUp = 5;

  /// Listens that did not start, in a row, before it stops.
  static const failedStartsToGiveUp = 3;

  /// After the last words of a stopped listening, kept for this long: a
  /// recogniser gives what it heard last when it is stopped.
  static const lastWordsWindow = Duration(seconds: 3);

  /// Phrases typed in this listening: the next one goes after a space.
  int _typed = 0;

  /// Bumped at every start and stop, so that a result or a status of a
  /// listening that has ended changes nothing.
  int _run = 0;

  Timer? _restart;
  Timer? _watchdog;
  DateTime _listenedAt = DateTime(0);
  bool _heard = false;
  int _quickEnds = 0;
  int _failedStarts = 0;

  /// The stopped listening whose last words are still typed, until when.
  int? _lastWordsRun;
  DateTime _lastWordsUntil = DateTime(0);

  @override
  DictationState build() {
    // Its session ended, or lost its terminal: no more listening for it.
    ref.listen(activeSessionsProvider, (_, sessions) {
      final id = state.sessionId;
      if (id != null && sessions[id]?.session == null) unawaited(stop());
    });
    ref.onDispose(_cancelTimers);
    return const DictationState();
  }

  DictationEngine get _engine => ref.read(dictationEngineProvider);

  /// Where the words go: tmux's pane in front where tmux shows in the
  /// terminal's place, as the phone's.
  Terminal? _target(String sessionId) {
    final tmux = ref.read(tmuxHostProvider(sessionId));
    if (tmux.active) return tmux.live ? tmux.controller?.activeWindow?.activePane?.terminal : null;
    return ref.read(activeSessionsProvider)[sessionId]?.session?.terminal;
  }

  /// Starts listening for [sessionId], or stops where it listens already
  /// (for any session).
  Future<DictationOutcome> toggle(String sessionId) async {
    if (state.listening) {
      await stop();
      return DictationOutcome.stopped;
    }
    return start(sessionId);
  }

  /// Starts listening for [sessionId], where it does not listen already.
  Future<DictationOutcome> start(String sessionId) async {
    if (state.listening) return DictationOutcome.started;
    if (_target(sessionId) == null) return DictationOutcome.noTerminal;
    final run = ++_run;
    final engine = _engine;
    final keepOn = ref.read(dictationKeepsListeningProvider);
    bool ready;
    try {
      ready = await engine.initialize(
        onStatus: (status) => _status(run, status, keepOn),
        onError: (error) => _error(run, error, keepOn),
      );
    } catch (_) {
      ready = false;
    }
    if (run != _run) return DictationOutcome.stopped;
    if (!ready) return DictationOutcome.unavailable;
    _typed = 0;
    _quickEnds = 0;
    _failedStarts = 0;
    state = DictationState(sessionId: sessionId, listening: true, language: state.language, gaveUp: state.gaveUp);
    if (!await _listen(run, sessionId)) {
      // (A Mac without on-device recognition says so here.)
      if (run == _run) _end();
      return DictationOutcome.unavailable;
    }
    // Asked once it listens: the language it listens in is known by then.
    unawaited(_askLanguage(run));
    return state.listening ? DictationOutcome.started : DictationOutcome.unavailable;
  }

  Future<void> _askLanguage(int run) async {
    String? language;
    try {
      language = await _engine.language();
    } catch (_) {}
    if (language != null && run == _run) state = state.copyWith(language: language);
  }

  /// One listen of the recogniser for [run]; false where it would not start.
  Future<bool> _listen(int run, String sessionId) async {
    _heard = false;
    _listenedAt = dictationClock();
    _watchdog?.cancel();
    _watchdog = Timer(startTimeout, () => _didNotStart(run));
    try {
      await _engine.listen(onWords: (words, isFinal) => _words(run, sessionId, words, isFinal));
      return true;
    } catch (_) {
      _watchdog?.cancel();
      return false;
    }
  }

  void _status(int run, String status, bool keepOn) {
    if (run != _run) return;
    if (status == stt.SpeechToText.listeningStatus) {
      _watchdog?.cancel();
      _failedStarts = 0;
      return;
    }
    if (!keepOn) {
      // Ended by itself (a phone's recogniser after a pause).
      if (status == stt.SpeechToText.doneStatus || status == stt.SpeechToText.notListeningStatus) _end();
      return;
    }
    // The recogniser's listening is over once it is done (a Mac's after a
    // pause or a silence, with its last words given); notListening comes
    // before it, while words may still come.
    if (status == stt.SpeechToText.doneStatus) _listeningEnded(run);
  }

  void _error(int run, String error, bool keepOn) {
    if (run != _run) return;
    if (!keepOn) {
      _end();
      return;
    }
    if (dictationCannotListen(error)) {
      _giveUp();
    } else {
      // Nothing heard, a time limit, the recogniser busy for a moment: a new
      // listening.
      _listeningEnded(run);
    }
  }

  /// The recogniser's listening for [run] ended by itself while the person
  /// has it on: a new one, at once where words were heard, else after a
  /// wait that grows while listenings end as soon as they start; a fifth
  /// of those in a row and it stops.
  void _listeningEnded(int run) {
    if (!state.listening || _restart != null) return;
    _watchdog?.cancel();
    if (_heard || dictationClock().difference(_listenedAt) >= quickEnd) {
      _quickEnds = 0;
    } else if (++_quickEnds >= quickEndsToGiveUp) {
      _giveUp();
      return;
    }
    final wait = _quickEnds == 0
        ? const Duration(milliseconds: 150)
        : Duration(milliseconds: 250 * (1 << (_quickEnds - 1)));
    _restart = Timer(wait, () {
      _restart = null;
      if (run == _run && state.listening) unawaited(_listenAgain(run));
    });
  }

  Future<void> _listenAgain(int run) async {
    final id = state.sessionId;
    if (id == null) return;
    if (_target(id) == null) {
      unawaited(stop());
      return;
    }
    if (!await _listen(run, id) && run == _run) _didNotStart(run);
  }

  /// A listen that would not start, or never said it listens: tried again,
  /// and after the third in a row it stops.
  void _didNotStart(int run) {
    if (run != _run || !state.listening) return;
    if (++_failedStarts >= failedStartsToGiveUp) {
      _giveUp();
      return;
    }
    _restart?.cancel();
    _restart = Timer(Duration(milliseconds: 500 * _failedStarts), () {
      _restart = null;
      if (run == _run && state.listening) unawaited(_listenAgain(run));
    });
  }

  void _words(int run, String sessionId, String words, bool isFinal) {
    final lastWords = isFinal && run == _lastWordsRun && dictationClock().isBefore(_lastWordsUntil);
    if (run != _run && !lastWords) return;
    final current = run == _run && state.listening;
    if (current && words.trim().isNotEmpty) {
      _heard = true;
      _watchdog?.cancel();
    }
    if (!isFinal) {
      if (current) state = state.copyWith(hearing: words);
      return;
    }
    final typed = _type(sessionId, words);
    if (current) state = state.copyWith(hearing: '', lastTyped: typed ?? state.lastTyped);
  }

  /// Types [words] at [sessionId]'s prompt; what was typed, or null.
  String? _type(String sessionId, String words) {
    final text = CommandText.withoutControlCharacters(words).trim();
    if (text.isEmpty) return null;
    final terminal = _target(sessionId);
    if (terminal == null) {
      unawaited(stop());
      return null;
    }
    // Every control character taken out (no line end, so no Enter), as the
    // phone's mic types them.
    final sanitized = _typed > 0 ? ' $text' : text;
    terminal.textInput(sanitized);
    _typed++;
    return text;
  }

  void _cancelTimers() {
    _restart?.cancel();
    _restart = null;
    _watchdog?.cancel();
    _watchdog = null;
  }

  void _end({bool gaveUp = false}) {
    _run++;
    _cancelTimers();
    if (state.listening || state.sessionId != null || state.hearing.isNotEmpty || gaveUp) {
      state = DictationState(language: state.language, gaveUp: state.gaveUp + (gaveUp ? 1 : 0));
    }
  }

  /// The recogniser cannot listen: stopped, and said once.
  void _giveUp() {
    _end(gaveUp: true);
    unawaited(_engine.stop().catchError((Object _) {}));
  }

  /// Stops listening, where it does. What the recogniser still gives of what
  /// was said before (a Mac's last phrase, when it is stopped) is typed.
  Future<void> stop() async {
    if (!state.listening) return;
    _lastWordsRun = _run;
    _lastWordsUntil = dictationClock().add(lastWordsWindow);
    _end();
    try {
      await _engine.stop();
    } catch (_) {}
  }
}

/// Whether speech_to_text's [error] says the recogniser cannot listen at all
/// (no microphone, not allowed, not set up), rather than that one listening
/// ended (nothing heard, a time limit).
bool dictationCannotListen(String error) => const {
      'error_permission',
      'error_insufficient_permissions',
      'error_audio_error',
      'error_listen_failed',
      'error_speech_recognizer_disabled',
      'error_speech_recognizer_request_not_authorized',
      'error_assets_not_installed',
      'error_language_not_supported',
      'error_language_unavailable',
    }.contains(error);

final dictationProvider = NotifierProvider<TerminalDictation, DictationState>(TerminalDictation.new);

/// Whether [sessionId] is shown in [tab], the tab in front: a terminal of
/// one of its panes (SFTP's beside it is not one). Speech to text stops for
/// a session that is not: its words would go where they are not seen.
bool dictationSessionShown(WorkTab? tab, String sessionId) =>
    tab != null && tab.paneTree.allLeaves.any((l) => l.type != 'sftp' && l.sessionIdOrNull == sessionId);

/// Speech to text from a control or a key, for [sessionId] (null: no
/// terminal in front): Squeezed's question first where the account has not
/// got it, as the phone's mic asks; then listening, or stopped, said to a
/// screen reader; and why not, where it cannot.
Future<void> toggleDictation(BuildContext context, WidgetRef ref, String? sessionId) async {
  final l10n = AppLocalizations.of(context)!;
  final dictation = ref.read(dictationProvider.notifier);
  if (ref.read(dictationProvider).listening) {
    await dictation.stop();
    return;
  }
  if (!ref.read(voiceInputSupportedProvider)) return;
  if (sessionId == null) {
    showTopSnackBar(context, l10n.dictationOpenTerminal);
    return;
  }
  if (!ref.read(isProProvider)) {
    final upgrade = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.sparkles,
      title: l10n.terminalProGateTitle(l10n.terminalSpeechToText),
      body: l10n.terminalProGateMsg(l10n.terminalSpeechToText),
      confirmLabel: l10n.upgrade,
      cancelLabel: l10n.notNow,
    );
    if (upgrade == true && context.mounted) unawaited(context.push(Routes.upgrade));
    return;
  }
  final outcome = await dictation.toggle(sessionId);
  if (!context.mounted) return;
  switch (outcome) {
    case DictationOutcome.unavailable:
      showTopSnackBar(context, dictationUnavailableMessage(l10n), isError: true);
    case DictationOutcome.noTerminal:
      showTopSnackBar(context, l10n.dictationOpenTerminal);
    case DictationOutcome.started || DictationOutcome.stopped:
      break;
  }
}

/// Why speech to text cannot listen, and where that is changed, on this
/// computer.
String dictationUnavailableMessage(AppLocalizations l10n) => switch (defaultTargetPlatform) {
      TargetPlatform.windows => l10n.dictationUnavailableWindows,
      TargetPlatform.macOS => l10n.dictationUnavailableMac,
      _ => l10n.terminalSpeechUnavailable,
    };

/// Says to a screen reader when speech to text starts and stops listening,
/// whatever started or stopped it (its button, its key, the recogniser
/// ending by itself); and, where it stopped because the recogniser cannot
/// listen, why, once.
class DictationAnnouncer extends ConsumerWidget {
  const DictationAnnouncer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen<bool>(dictationProvider.select((s) => s.listening), (was, now) {
      if (was == now) return;
      final l10n = AppLocalizations.of(context)!;
      zestAnnounce(context, now ? l10n.dictationAnnounceListening : l10n.dictationAnnounceStopped,
          assertiveness: Assertiveness.polite);
    });
    ref.listen<int>(dictationProvider.select((s) => s.gaveUp), (was, now) {
      if (was == null || now <= was) return;
      showTopSnackBar(context, dictationUnavailableMessage(AppLocalizations.of(context)!), isError: true);
    });
    return child;
  }
}
