import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/shortcuts/default_bindings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/paste_question.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// The one paste path for every terminal surface (the main terminal, tmux
/// panes, a right click on a computer, a phone and a tablet, a phone's paste
/// keys):
/// reads the clipboard as a paste may type it ([Terminal.pasteable]: no
/// control character but a tab and a line break), asks first where the
/// shell would run its lines as they arrive ([askBeforeLinesRun]), runs the
/// dangerous-command guard when the user has it on, then hands the text to
/// xterm's `paste()`, which wraps it in bracketed-paste escapes when the
/// shell supports it and normalises line endings.
Future<void> pasteClipboardIntoTerminal(
  BuildContext context,
  WidgetRef ref,
  Terminal terminal,
) async {
  final data = await Clipboard.getData(Clipboard.kTextPlain);
  final raw = data?.text;
  if (raw == null || raw.isEmpty || !context.mounted) return;
  await pasteTextIntoTerminal(context, ref, terminal, raw);
}

/// [raw] pasted into [terminal] by the one paste path
/// ([pasteClipboardIntoTerminal]): also what a phone's keyboard commits from
/// its clipboard ([TerminalView.onKeyboardPaste]), which is a paste whichever
/// way it comes.
Future<void> pasteTextIntoTerminal(
  BuildContext context,
  WidgetRef ref,
  Terminal terminal,
  String raw,
) async {
  final text = Terminal.pasteable(raw);
  if (text.isEmpty) return;
  if (!context.mounted || !await askBeforeLinesRun(context, terminal, text)) return;

  // The guard fires only when the protection toggle is on (Settings ->
  // Security). The dialog exposes a "don't ask again" checkbox that flips
  // the setting off.
  if (ref.read(dangerousCommandProtectionProvider)) {
    final dangerMatches = DangerousCommandService.checkFilled(text);
    if (dangerMatches.isNotEmpty && context.mounted) {
      final result = await showDangerousCommandDialog(
        context,
        command: text,
        matches: dangerMatches,
        isPaste: true,
      );
      if (result.dontAskAgain) {
        await ref
            .read(settingsUpdaterProvider)
            .setDangerousCommandProtection(false);
      }
      if (!result.proceed) return;
    }
  }

  terminal.paste(text);
}

/// The keys a terminal keeps for itself, on every terminal one types into (a
/// computer's panes and its windows of their own, tmux's panes, a phone's and
/// a tablet's terminal, a live view of another's session): Ctrl+Shift+C, V
/// and A copy, paste and select all, as a Linux terminal has them, so the
/// plain Ctrl chords reach the shell as they are typed (Ctrl+A to the start
/// of the line, Ctrl+V a key as it is, tmux's and screen's prefix); on a Mac,
/// an iPad and an iPhone Cmd+C, V and A as well, as Terminal.app has them
/// (Cmd reaches no shell). A paste by them is [paste]: the app's one paste of
/// a terminal ([pasteClipboardIntoTerminal]), which asks first where the text
/// looks dangerous, where the terminal has it.
///
/// The terminal widget's own keys took Ctrl+A and Ctrl+V from the shell in
/// a phone's terminal on Android and in a live view and a window of its own
/// on Windows and Linux; tmux's panes and a computer's had no Cmd on a Mac
/// and an iPad; and a paste by keys went in unasked, dangerous or not.
///
/// On a computer, given the keys Settings binds ([bindings], Keyboard
/// shortcuts), copy and paste are the keys bound to Copy and Paste
/// (Ctrl+Shift+C and V unless changed there; none for one cleared there): a
/// key chosen there did nothing in a terminal, where they are used. A key of
/// Copy's own, any but Ctrl+Shift+C, copies what is selected ([selected]
/// says whether something is), and with nothing selected is the terminal's,
/// typed into it as any key is: Ctrl+C given to Copy still stops a program,
/// as a terminal's Copy does at that key.
Map<ShortcutActivator, Intent> terminalKeys({
  required VoidCallback paste,
  ShortcutBindings? bindings,
  bool Function()? selected,
}) {
  final apple = defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;
  final pasteNow = VoidCallbackIntent(paste);
  const copy = CopySelectionTextIntent.copy;
  const all = SelectAllTextIntent(SelectionChangedCause.keyboard);
  const ctrlShiftC = SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true);
  ShortcutActivator? copyKey = ctrlShiftC;
  ShortcutActivator? pasteKey = const SingleActivator(LogicalKeyboardKey.keyV, control: true, shift: true);
  if (bindings != null) {
    final copyBinding = bindings.bindingFor(ShortcutAction.copySelection);
    final pasteBinding = bindings.bindingFor(ShortcutAction.paste);
    copyKey = copyBinding == null
        ? null
        : copyBinding == defaultShortcutBindings[ShortcutAction.copySelection]
            ? ctrlShiftC
            : _WhileSelected(_activatorOf(copyBinding), selected ?? () => true);
    pasteKey = pasteBinding == null ? null : _activatorOf(pasteBinding);
  }
  return {
    ?copyKey: copy,
    ?pasteKey: pasteNow,
    const SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true): all,
    if (apple) ...{
      const SingleActivator(LogicalKeyboardKey.keyC, meta: true): copy,
      const SingleActivator(LogicalKeyboardKey.keyV, meta: true): pasteNow,
      const SingleActivator(LogicalKeyboardKey.keyA, meta: true): all,
    },
  };
}

/// [key] as a key of a terminal's [Shortcuts].
SingleActivator _activatorOf(ShortcutKey key) => SingleActivator(
      LogicalKeyboardKey.findKeyByKeyId(key.keyId) ?? LogicalKeyboardKey(key.keyId),
      control: key.ctrl,
      shift: key.shift,
      alt: key.alt,
      meta: key.meta,
    );

/// [key], taken only while [selected] says something is selected: otherwise
/// no shortcut takes it, and the terminal types it as any other key.
class _WhileSelected extends ShortcutActivator {
  const _WhileSelected(this.key, this.selected);

  final SingleActivator key;
  final bool Function() selected;

  @override
  Iterable<LogicalKeyboardKey>? get triggers => key.triggers;

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) => key.accepts(event, state) && selected();

  @override
  String debugDescribeKeys() => key.debugDescribeKeys();
}

/// The clipboard into [terminal], for a terminal with no settings to read (a
/// computer's window of its own): as a paste may type it, and asked first,
/// as every other paste is, where the shell would run its lines as they
/// arrive ([askBeforeLinesRun]); the dangerous-command question, which reads
/// a setting, is not asked there. (It pasted several lines unasked.)
Future<void> pasteClipboardAsIs(BuildContext context, Terminal terminal) async {
  final raw = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  if (raw == null || raw.isEmpty || !context.mounted) return;
  await pasteTextAsIs(context, terminal, raw);
}

/// [raw] into [terminal] as [pasteClipboardAsIs] puts the clipboard there: for
/// what a keyboard commits from its clipboard, in the same window.
Future<void> pasteTextAsIs(BuildContext context, Terminal terminal, String raw) async {
  final text = Terminal.pasteable(raw);
  if (text.isEmpty || !context.mounted || !await askBeforeLinesRun(context, terminal, text)) return;
  terminal.paste(text);
}

/// The paths of files dropped on a terminal typed into [terminal], for the
/// person to enter: each in single quotes, so that a shell takes `$`, a
/// backtick or a `!` in a name for what they are. A name that holds a control
/// character is typed by no one ([CommandText.mayBeTyped]): it would act as a
/// key on the way in, and such a name is what a file from somewhere else can
/// have. The person is told, with the name as it is.
void typeDroppedPaths(BuildContext context, Terminal terminal, List<String> paths) {
  final typed = CommandText.quotedPaths(paths);
  if (typed == null) {
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.terminalNameNotTyped,
      isError: true,
      details: paths.where((p) => !CommandText.mayBeTyped(p)).map(withHiddenCharactersShown).join('\n'),
    );
    return;
  }
  if (typed.isNotEmpty) terminal.textInput(typed);
}

/// Copy-on-select (PuTTY style): copies the current selection to the
/// clipboard and clears it, when the setting is on. Returns whether anything
/// was copied.
bool copySelectionIfEnabled(
  WidgetRef ref,
  Terminal terminal,
  TerminalController controller,
) {
  if (!ref.read(copyOnSelectProvider)) return false;
  return copySelectionAndClear(terminal, controller);
}

/// What copy-on-select does, for every terminal surface (also the pop-out
/// window, which has no settings provider): the selection goes to the
/// clipboard and its highlight goes. A selection of nothing (a drag over
/// empty cells) is dropped as well, and the clipboard is left alone: it used
/// to stay highlighted, since nothing had been copied. Returns whether
/// anything was copied.
bool copySelectionAndClear(Terminal terminal, TerminalController controller) {
  final range = controller.selection;
  if (range == null) {
    // One whose text is gone since is forgotten.
    if (controller.selectionEnded) controller.clearSelection();
    return false;
  }
  final text = terminal.buffer.getText(range).trim();
  controller.clearSelection();
  if (text.isEmpty) return false;
  Clipboard.setData(ClipboardData(text: text));
  return true;
}

/// Copy on select, told from raw pointer events, for a surface that listens
/// to those: a selection is copied as the mouse button that made it is let go
/// ([copySelectionIfEnabled] then, where copy on select is on). Never at a
/// right click's release, the paste gesture, which reads the clipboard right
/// after; and never at a finger's or a pen's: touch selects to show its own
/// Copy (a phone's selection bar), and a selection copied and taken away as
/// the finger lifted was gone as soon as it was made (a phone's tmux panes
/// did that, while its main terminal copied a mouse's selection never).
class CopyOnRelease {
  int _buttons = 0;
  PointerDeviceKind? _kind;

  /// Notes what [event] pressed, and with what.
  void down(PointerDownEvent event) {
    _buttons = event.buttons;
    _kind = event.kind;
  }

  /// True when [event] lets go of a press a selection is copied at: a
  /// mouse's, with no right button in it.
  bool up(PointerUpEvent event) {
    final copies = _kind == PointerDeviceKind.mouse && event.kind == PointerDeviceKind.mouse && _buttons & kSecondaryButton == 0;
    _kind = null;
    _buttons = 0;
    return copies;
  }
}
