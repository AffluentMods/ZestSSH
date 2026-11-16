import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/widgets.dart';
import 'package:flutter/semantics.dart' show Assertiveness;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:speech_to_text/speech_to_text.dart' as stt;
import 'package:xterm/xterm.dart' show Terminal;
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
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

/// Whether a recogniser is there to listen with: speech_to_text has one on
/// Android, iOS, macOS (the system's speech recognition) and Windows (SAPI's
/// dictation, through speech_to_text_windows); on Linux it has none, so the
/// control is not shown there at all.
final voiceInputSupportedProvider = Provider<bool>(
    (ref) => !kIsWeb && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS || Platform.isWindows));

/// What listens: the plugin, behind this seam so that a test hears words.
abstract class DictationEngine {
  /// Gets the recogniser ready (and, on a Mac, asks for the microphone and
  /// speech recognition the first time). False where there is none, or it
  /// was not allowed.
  Future<bool> initialize({required void Function(String status) onStatus, required void Function(String error) onError});

  /// Listens; [onWords] has each result, [isFinal] where it is what was said.
  Future<void> listen({required void Function(String words, bool isFinal) onWords});

  Future<void> stop();
}

/// The speech_to_text plugin.
class SpeechToTextEngine implements DictationEngine {
  final stt.SpeechToText _speech = stt.SpeechToText();

  @override
  Future<bool> initialize({required void Function(String status) onStatus, required void Function(String error) onError}) async {
    final ready = await _speech.initialize();
    // The plugin is one for the app and takes its listeners only at its first
    // initialize: this listening's, set every time.
    _speech.statusListener = onStatus;
    _speech.errorListener = (e) => onError(e.errorMsg);
    return ready;
  }

  @override
  Future<void> listen({required void Function(String words, bool isFinal) onWords}) async {
    await _speech.listen(
      onResult: (result) => onWords(result.recognizedWords, result.finalResult),
      listenOptions: stt.SpeechListenOptions(
        listenMode: stt.ListenMode.dictation,
        // As on the phone: recognised on the device, never by a cloud
        // service (on a Mac without on-device recognition it is not
        // available; Windows' SAPI dictation is on the device anyway).
        onDevice: true,
      ),
    );
  }

  @override
  Future<void> stop() => _speech.stop();
}

final dictationEngineProvider = Provider<DictationEngine>((ref) => SpeechToTextEngine());

/// Where speech to text is listening: the session whose terminal it types
/// into, or none.
@immutable
class DictationState {
  const DictationState({this.sessionId, this.listening = false});

  final String? sessionId;
  final bool listening;
}

/// What [TerminalDictation.toggle] did.
enum DictationOutcome { started, stopped, unavailable, noTerminal }

/// Speech to text for the computer's shell: one terminal at a time.
class TerminalDictation extends Notifier<DictationState> {
  /// Phrases typed in this listening: the next one goes after a space.
  int _typed = 0;

  /// Bumped at every start and stop, so that a result or a status of a
  /// listening that has ended changes nothing.
  int _run = 0;

  @override
  DictationState build() {
    // Its session ended, or lost its terminal: no more listening for it.
    ref.listen(activeSessionsProvider, (_, sessions) {
      final id = state.sessionId;
      if (id != null && sessions[id]?.session == null) unawaited(stop());
    });
    return const DictationState();
  }

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
    if (_target(sessionId) == null) return DictationOutcome.noTerminal;
    final run = ++_run;
    final engine = ref.read(dictationEngineProvider);
    bool ready;
    try {
      ready = await engine.initialize(
        onStatus: (status) {
          // Ended by itself (a phone's recogniser after a pause; Windows'
          // after stop).
          if (run == _run && (status == stt.SpeechToText.doneStatus || status == stt.SpeechToText.notListeningStatus)) {
            _end();
          }
        },
        onError: (_) {
          if (run == _run) _end();
        },
      );
    } catch (_) {
      ready = false;
    }
    if (run != _run) return DictationOutcome.stopped;
    if (!ready) return DictationOutcome.unavailable;
    _typed = 0;
    state = DictationState(sessionId: sessionId, listening: true);
    try {
      await engine.listen(onWords: (words, isFinal) {
        if (run != _run || !isFinal) return;
        _type(sessionId, words);
      });
    } catch (_) {
      // (A Mac without on-device recognition says so here.)
      if (run == _run) _end();
      return DictationOutcome.unavailable;
    }
    return state.listening ? DictationOutcome.started : DictationOutcome.unavailable;
  }

  void _type(String sessionId, String words) {
    final text = CommandText.withoutControlCharacters(words).trim();
    if (text.isEmpty) return;
    final terminal = _target(sessionId);
    if (terminal == null) {
      unawaited(stop());
      return;
    }
    // Every control character taken out (no line end, so no Enter), as the
    // phone's mic types them.
    final sanitized = _typed > 0 ? ' $text' : text;
    terminal.textInput(sanitized);
    _typed++;
  }

  void _end() {
    _run++;
    if (state.listening || state.sessionId != null) state = const DictationState();
  }

  /// Stops listening, where it does.
  Future<void> stop() async {
    if (!state.listening) return;
    _end();
    try {
      await ref.read(dictationEngineProvider).stop();
    } catch (_) {}
  }
}

final dictationProvider = NotifierProvider<TerminalDictation, DictationState>(TerminalDictation.new);

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
/// ending by itself).
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
    return child;
  }
}
