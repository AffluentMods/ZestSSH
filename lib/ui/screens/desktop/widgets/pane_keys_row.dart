import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart' show Terminal;
import 'package:zestssh/features/terminal/terminal_dictation.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/terminal/hardware_keyboard_use.dart';
import 'package:zestssh/ui/screens/terminal/widgets/soft_key_catalog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart';

/// The row of keys a touch keyboard lacks (Esc, Ctrl, Alt, Tab, the arrows),
/// under a terminal of the computer's shell on a phone's or a tablet's large
/// screen (4.0), as the phone's terminal has it under
/// its own: shown where Settings shows it (its switch, its place not Off),
/// and while a hardware keyboard is typed on only where Settings keeps it
/// then. Ctrl and Alt held on it go with the next key of the on-screen
/// keyboard too (mobileSoftKeyModifierProvider, as on the phone).
class PaneKeysRow extends ConsumerStatefulWidget {
  const PaneKeysRow(
      {super.key, required this.sessionId, required this.sessionState, required this.terminal, required this.onShowKeyboard});

  /// The session typed into: speech to text's, by the row's mic.
  final String sessionId;

  final SessionState sessionState;

  /// Where the keys are typed.
  final Terminal terminal;

  /// Brings up the on-screen keyboard (the row's keyboard key).
  final VoidCallback onShowKeyboard;

  @override
  ConsumerState<PaneKeysRow> createState() => _PaneKeysRowState();
}

class _PaneKeysRowState extends ConsumerState<PaneKeysRow> {
  final _modifier = ValueNotifier<SoftKeyModifier>(SoftKeyModifier.none);

  @override
  void initState() {
    super.initState();
    _modifier.value = ref.read(mobileSoftKeyModifierProvider);
    // Ctrl or Alt picked here goes with the on-screen keyboard's next key,
    // and lets go once used there.
    _modifier.addListener(() {
      if (mounted && ref.read(mobileSoftKeyModifierProvider) != _modifier.value) {
        ref.read(mobileSoftKeyModifierProvider.notifier).state = _modifier.value;
      }
    });
    ref.listenManual(mobileSoftKeyModifierProvider, (_, next) {
      if (_modifier.value != next) _modifier.value = next;
    });
  }

  @override
  void dispose() {
    _modifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.sessionState;
    final hardware = ref.watch(hardwareKeyboardUseProvider);
    final hardwareRow = ref.watch(keysRowHardwareProvider) ?? HardwareKeysRow.defaultFor(tablet: true);
    final shown =
        state.status == SessionStatus.connected &&
        ref.watch(showExtraKeyboardRowProvider) &&
        ref.watch(extraKeyboardPositionProvider) != 'disabled' &&
        !(hardwareRow == HardwareKeysRow.hide && hardware.rowHidden);
    if (!shown) return const SizedBox.shrink();
    return Listener(
      // A key of the row used: a tap brings the on-screen keyboard up again.
      onPointerUp: (_) => ref.read(hardwareKeyboardUseProvider.notifier).wantSoftKeyboard(),
      child: TerminalSoftKeyboard(
        onKey: (key) => typeSoftKey(widget.terminal, key),
        modifierNotifier: _modifier,
        // The phone's mic key (4.0): speech to text into this terminal, where
        // something listens.
        mic: ref.watch(voiceInputSupportedProvider),
        onMicPressed: () => toggleDictation(context, ref, widget.sessionId),
        isListening: ref.watch(dictationProvider.select((s) => s.listening && s.sessionId == widget.sessionId)),
        onShowKeyboard: hardware.keyboardOnTap ? null : widget.onShowKeyboard,
        onlyMissingKeys: hardwareRow == HardwareKeysRow.missingOnly && hardware.rowHidden,
      ),
    );
  }
}
