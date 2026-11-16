import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show SemanticsValidationResult;
import 'package:flutter/services.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';

import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_surfaces.dart' show readableShade;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/keyboard_lock_warning.dart';
import 'package:zestssh/ui/widgets/ink_layer.dart';
import 'package:zestssh/ui/widgets/zest_in_place.dart';
import 'package:zestssh/ui/widgets/zest_modal.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart' show ZestFieldLabel;
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;

export 'package:zestssh/ui/widgets/zest_modal.dart'
    show ZestModalSize, showZestModal, showZestInPlace, zestDialogPop;

/// What a dialog means, for [ZestDialogShell] and [ZestConfirmDialog].
///
/// The dialog itself is neutral; colour says only what it means (the app's
/// dialog rules, 3.4):
///   * [success]: a green tick, for something done;
///   * [destructive]: red, for what deletes or exposes something, and its
///     main button is red;
///   * [warning], [info], [neutral]: the neutral frame. A warning says itself
///     in one amber sentence inside ([ZestCallout], or a confirm's `warning`),
///     never in the whole dialog: its big yellow tile made an ordinary
///     question look like an alarm.
/// The main button is the brand orange, red where the tone is destructive.
enum ZestDialogTone {
  destructive(icon: LucideIcons.alertTriangle, confirmFilled: true),
  warning(icon: LucideIcons.alertCircle, confirmFilled: true),
  info(icon: LucideIcons.info, confirmFilled: true),
  neutral(icon: LucideIcons.helpCircle, confirmFilled: true),

  /// Something went through: green, where a done step showed the orange of
  /// a question (found in a design audit).
  success(icon: LucideIcons.checkCircle2, confirmFilled: true);

  const ZestDialogTone({required this.icon, required this.confirmFilled});

  final IconData icon;
  final bool confirmFilled;

  /// The colour this tone means, or null for the neutral frame: red for
  /// destructive, green for success. Resolved at access time because
  /// [AppColors.v3*] follow the active app theme.
  Color? get meaning {
    switch (this) {
      case ZestDialogTone.destructive:
        return AppColors.v3Error;
      case ZestDialogTone.success:
        return AppColors.v3Success;
      case ZestDialogTone.warning:
      case ZestDialogTone.info:
      case ZestDialogTone.neutral:
        return null;
    }
  }

  /// The main button's colour: the brand's, but red for what cannot be
  /// undone. A warning says itself in its callout, not in a mustard button.
  Color get buttonAccent =>
      this == ZestDialogTone.destructive ? AppColors.v3Error : AppColors.v3AccentPrimary;
}

/// The amber of a warning sentence ([ZestCallout]): the theme's warning
/// colour, which is the only place a dialog shows it.
Color get _amber => AppColors.v3Warning;

/// One warning sentence inside a dialog, set apart in amber: the only amber a
/// dialog has (rule 1 of the dialog rules, 3.4). "Without a password, anyone
/// who gets the file can read your SSH keys and passwords."
class ZestCallout extends StatelessWidget {
  const ZestCallout(this.text, {super.key, this.icon = LucideIcons.alertTriangle});

  final String text;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('zest-callout'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: _amber.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: _amber.withValues(alpha: 0.38)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            // The theme's amber, darkened where it would not show on the
            // dialog (a light theme's).
            child: Icon(icon, size: 16, color: ZestColors.inkOn(_amber, AppColors.v3Elevated)),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 13,
                height: 1.45,
                color: AppColors.v3TextPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A destructive button's fill: a deeper red than the error colour, which is
/// a text colour (salmon as a fill, with dark words on it).
Color _dangerFill(Color error) =>
    // White words on it at 4.5:1 or better, whatever the theme's red (a
    // lighter red, made readable as words on a dark theme, made the fill too
    // light for them).
    readableShade(Color.lerp(error, const Color(0xFFB4232A), 0.55)!, const [Colors.white]);

/// The words on a filled button: white on the danger red, else as on the
/// brand everywhere (AppColors.onBrand).
Color _onFill(Color accent) => accent == AppColors.v3Error ? Colors.white : AppColors.onBrand(accent);

/// Polished, desktop-feeling confirmation / info dialog.
///
/// Replaces the generic Material [AlertDialog] for any prompt where
/// the user is being asked to confirm or acknowledge an action:
/// "Delete X?", "Sign out?", "Discard changes?", etc. It is a
/// [ZestDialogShell], so it keeps the dialog rules (3.4):
///
///   * A small icon, neutral; red only for [ZestDialogTone.destructive],
///     green only for [ZestDialogTone.success]
///   * Bold title + measured body copy, an optional bullet list
///   * An optional [warning]: the one amber sentence ([ZestCallout])
///   * One footer, bottom right: Cancel, then the main button, which says
///     what it does
///   * Entrance: scale 0.96 to 1 + fade, 200ms emphasized curve
///
/// Usage:
/// ```dart
/// final ok = await ZestConfirmDialog.show(
///   context,
///   tone: ZestDialogTone.destructive,
///   title: 'Delete "${identity.label}"?',
///   body: 'This identity will be removed from every connection '
///       'that uses it.  This cannot be undone.',
///   confirmLabel: 'Delete',
/// );
/// if (ok == true) { ... }
/// ```
class ZestConfirmDialog extends StatelessWidget {
  const ZestConfirmDialog({
    super.key,
    required this.tone,
    required this.title,
    required this.body,
    this.bullets,
    this.warning,
    this.confirmLabel,
    this.cancelLabel,
    this.showCancel = true,
    this.icon,
    this.autofocusConfirm,
    this.confirmValue = true,
    this.cancelValue = false,
  });

  /// What the question means ([ZestDialogTone]): its icon and main button.
  final ZestDialogTone tone;

  /// Bold title.  Single line, ~36-48 chars max.
  final String title;

  /// Body copy.  Plain text, may be multi-line.  Keep under ~3
  /// sentences - anything longer belongs in [bullets].
  final String body;

  /// Optional bullet list of consequences / details, rendered below
  /// the body with a quiet dot per item.
  final List<String>? bullets;

  /// The one sentence that warns, in amber under the body ([ZestCallout]):
  /// the only place a question shows amber.
  final String? warning;

  /// Confirm-button label.  Defaults to the localized "Confirm" - override
  /// with the actual verb ("Delete", "Sign out", "Discard").
  final String? confirmLabel;

  /// Cancel-button label.  Defaults to the localized "Cancel".
  final String? cancelLabel;

  /// Whether to render the Cancel button. Set false for a pure
  /// acknowledgement ("Backup exported") where the only sensible action is
  /// to dismiss - a Cancel next to Close is redundant. The top-right X still
  /// dismisses either way.
  final bool showCancel;

  /// Override the tone's default icon.  Rarely needed - the tones
  /// already ship sensible icons.
  final IconData? icon;

  /// Whether the confirm button takes the keyboard as the dialog opens, so
  /// that Enter answers it. False for a question that something outside the
  /// app can raise (a link): what was being typed as it came up answers nothing.
  /// Null: it does, but for a destructive question, where Enter answers
  /// nothing and the safe choice stands (the 3.4 security review, L8).
  final bool? autofocusConfirm;

  /// What the confirm button answers, and the cancel button ([ask]).
  final Object confirmValue;
  final Object cancelValue;

  /// Show the dialog and resolve with `true` if the user confirmed, `false` if
  /// they pressed the cancel button, and null if they closed it without an answer
  /// (the X, Escape, outside it). A cancel button that does something of its own
  /// ([cancelLabel] says what) is told from closing by that null: where both
  /// buttons do something, [ask] says which by name.
  static Future<bool?> show(
    BuildContext context, {
    required ZestDialogTone tone,
    required String title,
    required String body,
    List<String>? bullets,
    String? warning,
    String? confirmLabel,
    String? cancelLabel,
    bool showCancel = true,
    IconData? icon,
    bool? autofocusConfirm,
  }) {
    final dialog = ZestConfirmDialog(
      tone: tone,
      title: title,
      body: body,
      bullets: bullets,
      warning: warning,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      showCancel: showCancel,
      icon: icon,
      autofocusConfirm: autofocusConfirm,
    );
    // Asked from a dialog: in its place (rule 4, no dialog over a dialog).
    final host = ZestInPlaceHost.maybeOf(context);
    if (host != null) return host.show<bool>((_) => dialog);
    // A phone: a bottom sheet (3.0 UI).
    if (zestUsesSheets(context)) return showZestSheet<bool>(context: context, child: dialog);
    return showDialog<bool>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => ZestInPlaceHost(child: dialog),
    );
  }

  /// A question whose two buttons each do something: resolves with [confirm] or
  /// [cancel], which cannot be taken for each other, and with null where it was
  /// closed without an answer (the X, Escape, outside it). Nothing is to be done
  /// on null. (The X of a guest data question answered false, which meant Bring:
  /// found in a review.)
  static Future<T?> ask<T extends Object>(
    BuildContext context, {
    required ZestDialogTone tone,
    required String title,
    required String body,
    required String confirmLabel,
    required T confirm,
    required String cancelLabel,
    required T cancel,
    List<String>? bullets,
    String? warning,
    IconData? icon,
    bool? autofocusConfirm,
  }) {
    final dialog = ZestConfirmDialog(
      tone: tone,
      title: title,
      body: body,
      bullets: bullets,
      warning: warning,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel,
      icon: icon,
      autofocusConfirm: autofocusConfirm,
      confirmValue: confirm,
      cancelValue: cancel,
    );
    final host = ZestInPlaceHost.maybeOf(context);
    if (host != null) return host.show<T>((_) => dialog);
    if (zestUsesSheets(context)) return showZestSheet<T>(context: context, child: dialog);
    return showDialog<T>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (_) => ZestInPlaceHost(child: dialog),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The shell's anatomy, as every dialog has it (3.0: a confirmation was a
    // layout of its own, its body indented under the title, with no lines).
    return ZestDialogShell(
      tone: tone,
      icon: icon,
      title: title,
      maxWidth: 480,
      bodyKey: const ValueKey('zest-confirm-body'),
      autofocusPrimary: autofocusConfirm ?? tone != ZestDialogTone.destructive,
      // The X, like Escape and a tap outside it, is no answer: null.
      onClose: () => zestDialogPop(context),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (body.isNotEmpty)
            Text(
              body,
              style: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 13.5,
                height: 1.55,
                color: AppColors.v3TextSecondary.withValues(alpha: 0.9),
              ),
            ),
          if (bullets != null && bullets!.isNotEmpty) ...[
            if (body.isNotEmpty) const SizedBox(height: 10),
            for (final b in bullets!) ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 7),
                    child: Container(
                      width: 4,
                      height: 4,
                      // A quiet dot: colour is for what a dialog means.
                      decoration: BoxDecoration(color: AppColors.v3TextTertiary, shape: BoxShape.circle),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      b,
                      style: TextStyle(
                        fontFamily: 'GeistSans',
                        fontSize: 13,
                        height: 1.5,
                        color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
            ],
          ],
          if (warning != null) ...[
            if (body.isNotEmpty || (bullets?.isNotEmpty ?? false)) const SizedBox(height: 12),
            ZestCallout(warning!),
          ],
        ],
      ),
      primaryAction: (
        label: confirmLabel ?? l10n.zestDialogConfirm,
        icon: null,
        onPressed: () => zestDialogPop(context, confirmValue),
      ),
      secondaryAction: showCancel
          ? (label: cancelLabel ?? l10n.cancel, onPressed: () => zestDialogPop(context, cancelValue))
          : null,
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  ZestTextField - themed text field used inside ZestDialogShell
// ════════════════════════════════════════════════════════════════════

/// A pre-styled text field that matches the dialog chrome.  Use
/// inside [ZestDialogShell] bodies for rename / save-as / form
/// inputs - saves callers from rebuilding the InputDecoration
/// boilerplate every time.
///
/// Auto-focuses on first build and Enter submits via [onSubmit].
class ZestTextField extends StatefulWidget {
  const ZestTextField({
    super.key,
    required this.controller,
    this.focusNode,
    this.label,
    this.hintText,
    this.onSubmit,
    this.onChanged,
    this.autofocus = true,
    this.maxLength,
    this.helperText,
    this.errorText,
    this.obscureText = false,
    this.selectOnFocus = ZestFieldSelect.all,
    this.keyboardType,
    this.inputFormatters,
    this.minLines,
    this.maxLines = 1,
    this.autofillHints,
    this.likeSelect = false,
    this.literal = false,
  });

  /// One line drawn as a [ZestSelect] is (its height, box, fill and text
  /// size), for a field under selects: the access dialogs' Note was taller,
  /// lighter edged and in larger type than the choices above it (found in a design
  /// audit).
  final bool likeSelect;

  /// What a password manager takes this field for.
  final Iterable<String>? autofillHints;

  /// What is typed goes as it is typed: a keyboard does not correct it,
  /// suggest from it or learn it (an account's name, which a correction
  /// would change before it is sent, and which a suggestion strip would show
  /// while the field is masked for recording).
  final bool literal;

  final TextEditingController controller;

  /// Optional externally-owned focus node. When null the field owns its
  /// own node (backward-compatible). Pass one when a parent dialog needs
  /// to re-focus the field after a failed validation.
  final FocusNode? focusNode;
  final String? label;
  final String? hintText;
  final VoidCallback? onSubmit;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final int? maxLength;
  final String? helperText;

  /// Inline validation error. When non-null the border turns red and the
  /// message renders below the field (replacing [helperText]). This is how
  /// single-input dialogs surface validation without a toast (UX audit A1).
  final String? errorText;

  /// Mask input (password prompts).
  final bool obscureText;

  /// What to preselect when the field autofocuses.
  final ZestFieldSelect selectOnFocus;

  /// The keyboard a phone shows (a PIN's is numbers), and what may be typed.
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// Lines shown: one by default; a reason or a note takes several
  /// (minLines 3, maxLines 6). In a field of several lines Enter is a new
  /// line and never submits; in one of one line it calls [onSubmit].
  final int? minLines;
  final int? maxLines;

  @override
  State<ZestTextField> createState() => _ZestTextFieldState();
}

/// Preselection behaviour for [ZestTextField] on autofocus.
enum ZestFieldSelect {
  /// Select the entire value (default - good for "replace what's here").
  all,

  /// Select only the filename stem, leaving the extension unselected -
  /// matches platform file-manager rename behaviour (UX audit A1).
  stem,

  /// Place the caret at the end, select nothing.
  end,
}

class _ZestTextFieldState extends State<ZestTextField> {
  FocusNode? _ownedNode;
  FocusNode get _focusNode => widget.focusNode ?? (_ownedNode ??= FocusNode());

  /// Live obscure state - starts matching [ZestTextField.obscureText] and
  /// flips when the user taps the reveal (eye) affordance shown on password
  /// fields, so converting a prompt to this field never loses show/hide.
  late bool _obscured = widget.obscureText;

  /// The box's border follows the keyboard (the accent while typed in): the
  /// field is redrawn as its focus comes and goes. The inner TextField draws
  /// no border, so this box is the only one that shows focus.
  void _focusChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ZestTextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownedNode)?.removeListener(_focusChanged);
      _focusNode.addListener(_focusChanged);
    }
    // An error that came up (or changed) is said to a screen reader as it
    // shows: drawn under the field alone, nobody heard that Save did not go.
    final error = widget.errorText;
    if (error != null && error != oldWidget.errorText) zestAnnounce(context, error);
  }

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_focusChanged);
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _focusNode.requestFocus();
          widget.controller.selection = _initialSelection();
        }
      });
    }
  }

  TextSelection _initialSelection() {
    final text = widget.controller.text;
    switch (widget.selectOnFocus) {
      case ZestFieldSelect.all:
        return TextSelection(baseOffset: 0, extentOffset: text.length);
      case ZestFieldSelect.end:
        return TextSelection.collapsed(offset: text.length);
      case ZestFieldSelect.stem:
        // Select up to the final dot so the extension stays untouched.
        // A leading dot (dotfiles like ".bashrc") is not an extension, so
        // fall back to selecting everything.
        final dot = text.lastIndexOf('.');
        if (dot > 0) {
          return TextSelection(baseOffset: 0, extentOffset: dot);
        }
        return TextSelection(baseOffset: 0, extentOffset: text.length);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_focusChanged);
    _ownedNode?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final hasError = widget.errorText != null;
    final borderColor = hasError
        ? AppColors.v3Error.withValues(alpha: 0.7)
        : _focusNode.hasFocus
            // The theme's focus ring: the accent at 1.2 (it was the inner
            // field's second box that showed it).
            ? AppColors.v3AccentPrimary
            : AppColors.v3BorderSubtle;
    final multiline = !widget.obscureText &&
        (widget.maxLines == null || widget.maxLines! > 1 || (widget.minLines ?? 1) > 1);
    final select = widget.likeSelect && !multiline;
    final themed = Theme.of(context).inputDecorationTheme;
    final edge = themed.enabledBorder;
    final selectEdge = edge is OutlineInputBorder ? edge.borderSide.color : ZestTokens.border;
    final textSize = select ? 13.0 : 14.0;

    // In a field of several lines Enter goes to the text, not to a shortcut
    // above it (a modal's Enter that submits it): the key is handed straight
    // to the text input, which makes it a new line.
    Widget enterTypesNewLine(Widget field) => multiline
        ? Shortcuts(
            shortcuts: const <ShortcutActivator, Intent>{
              SingleActivator(LogicalKeyboardKey.enter): DoNothingAndStopPropagationTextIntent(),
              SingleActivator(LogicalKeyboardKey.numpadEnter): DoNothingAndStopPropagationTextIntent(),
            },
            child: field,
          )
        : field;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (widget.label != null) ...[
          // Said with the field it names, below, not as words of their own.
          ExcludeSemantics(child: ZestFieldLabel(widget.label!, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 6),
        ],
        Container(
          // The edge is drawn over the field, not around it: the input
          // inside is the whole box, so the box's height is the input's own
          // target (4.0 accessibility pass: a select-like field's input was
          // 31 high in its 34 or 48, and a field 45 high on a phone).
          decoration: BoxDecoration(
            color: select ? themed.fillColor ?? AppColors.v3Background : AppColors.v3Background,
            borderRadius: BorderRadius.circular(8),
          ),
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: select && !hasError && !_focusNode.hasFocus ? selectEdge : borderColor,
              width: (_focusNode.hasFocus || hasError) ? 1.2 : 1,
            ),
          ),
          // The field by its name to a screen reader ("Host name, edit box"),
          // and said not to be right while its error shows.
          child: Semantics(
            label: widget.label,
            validationResult: hasError ? SemanticsValidationResult.invalid : SemanticsValidationResult.none,
            child: enterTypesNewLine(TextField(
            controller: widget.controller,
            focusNode: _focusNode,
            // Desktop platforms select everything when a one-line field
            // gains focus, which would undo a stem or caret-at-end
            // preselection (it runs just after initState's). Leave the
            // selection to us unless we want all of it anyway.
            selectAllOnFocus:
                widget.selectOnFocus == ZestFieldSelect.all ? null : false,
            obscureText: _obscured,
            // A password field (shown or not) is no text a keyboard may
            // correct, suggest from or learn: as before the dialog remake
            // (the 3.4 security review, L11).
            autocorrect: !widget.obscureText && !widget.literal,
            enableSuggestions: !widget.obscureText && !widget.literal,
            enableIMEPersonalizedLearning: !widget.obscureText && !widget.literal,
            autofillHints: widget.autofillHints,
            // Several lines: Enter is a new line, on a phone's keyboard as
            // on a computer's, and never submits.
            keyboardType: multiline ? TextInputType.multiline : widget.keyboardType,
            textInputAction: multiline ? TextInputAction.newline : null,
            inputFormatters: widget.inputFormatters,
            minLines: widget.obscureText ? null : widget.minLines,
            maxLines: widget.obscureText ? 1 : widget.maxLines,
            onChanged: widget.onChanged,
            // Its line in the middle of a box made taller than it.
            textAlignVertical: multiline ? null : TextAlignVertical.center,
            onSubmitted: widget.onSubmit == null || multiline
                ? null
                : (_) => widget.onSubmit!(),
            maxLength: widget.maxLength,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: textSize,
              color: AppColors.v3TextPrimary,
            ),
            decoration: InputDecoration(
              hintText: widget.hintText,
              hintStyle: TextStyle(
                fontFamily: 'GeistSans',
                fontSize: textSize,
                color: AppColors.v3TextTertiary,
              ),
              isDense: true,
              filled: false,
              // 13 (6 like a select) and the edge's 1 that the box no longer
              // adds: the box as tall as before with a mouse. At least as
              // tall as a select beside it, 48 where a finger presses it, 34
              // with a mouse; one line of a field at least a finger's 48.
              contentPadding: EdgeInsets.symmetric(
                  horizontal: 12, vertical: select ? 7 : 13),
              constraints: BoxConstraints(
                minHeight: zestUsesSheets(context) || touchSizedAt(context) ? 48 : (select ? 34 : 0),
              ),
              // The container above is the field's one box: the theme's
              // outlines (enabled, focused, error) would draw a second one
              // inside it, so every state is borderless here.
              border: InputBorder.none,
              enabledBorder: InputBorder.none,
              focusedBorder: InputBorder.none,
              disabledBorder: InputBorder.none,
              errorBorder: InputBorder.none,
              focusedErrorBorder: InputBorder.none,
              counterText: '',
              // Reveal toggle for password fields - excluded from the focus
              // traversal so Tab still moves to the dialog's buttons, not the
              // eye.
              suffixIcon: widget.obscureText
                  ? ExcludeFocus(
                      child: IconButton(
                        splashRadius: 18,
                        iconSize: 16,
                        padding: EdgeInsets.zero,
                        // 48 where a finger presses it.
                        constraints: BoxConstraints(
                            minWidth: touchSizedAt(context) ? 48 : 40, minHeight: touchSizedAt(context) ? 48 : 40),
                        icon: Icon(
                          _obscured
                              ? LucideIcons.eye
                              : LucideIcons.eyeOff,
                          color: AppColors.v3TextTertiary,
                        ),
                        tooltip:
                            _obscured ? l10n.zestDialogShow : l10n.zestDialogHide,
                        onPressed: () async {
                          // Revealing a secret while recording mode is on: spec 5.
                          if (_obscured &&
                              !await confirmRevealWhileRecording(context)) {
                            return;
                          }
                          if (!mounted) return;
                          setState(() => _obscured = !_obscured);
                        },
                      ),
                    )
                  : null,
            ),
          )),
          ),
        ),
        // Caps/Num-lock advisory - only rendered for password fields, and only
        // when a lock is actually on (physical keyboards only).
        if (widget.obscureText) const KeyboardLockWarning(),
        if (hasError) ...[
          const SizedBox(height: 7),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(
                  LucideIcons.alertCircle,
                  size: 13,
                  color: AppColors.v3Error,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  widget.errorText!,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12,
                    color: AppColors.v3Error,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ] else if (widget.helperText != null) ...[
          const SizedBox(height: 8),
          Text(
            widget.helperText!,
            style: TextStyle(
              fontFamily: 'GeistSans',
              fontSize: 12,
              color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
              height: 1.5,
            ),
          ),
        ],
      ],
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  ZestDialogShell - reusable mini-screen wrapper
// ════════════════════════════════════════════════════════════════════

/// Reusable wrapper for content-rich dialogs (Hardware Token,
/// Cert Import, Save-As-Name prompts, etc).  Provides the same
/// chrome as [ZestConfirmDialog] - small icon, bold title, subtitle,
/// close button, action footer - but the body is arbitrary widgets
/// you supply.
///
/// It keeps the app's dialog rules (3.4):
///   1. a neutral dialog, colour only by meaning ([ZestDialogTone]): a green
///      tick for done, red for destructive (with a red main button), amber
///      only on a warning sentence ([ZestCallout]), orange only for the main
///      button;
///   2. one footer, bottom right: [secondaryAction] (Cancel), then
///      [primaryAction]; a side option ([tertiaryAction]) bottom left, as a
///      link; no buttons in the body;
///   3. a small 30 px icon, and no lines under the header or over the footer;
///   4. no dialog over a dialog: a follow-up changes this one in place;
///   5. buttons say what they do ("Export unencrypted", "Done"), never "OK"
///      for an action, no "..." unless a picker opens next;
///   6. paths in the system's own style, the file name first
///      ([FileSavedBody]).
///
/// Use over plain `AlertDialog` whenever the dialog has form fields,
/// a multi-state body, or any custom layout - keeps the visual
/// vocabulary consistent across the app.
///
/// ```dart
/// showDialog(
///   context: context,
///   builder: (_) => ZestDialogShell(
///     tone: ZestDialogTone.info,
///     icon: LucideIcons.keyRound,
///     title: 'Import certificate',
///     subtitle: 'Paste your OpenSSH-signed certificate to enable...',
///     body: MyFormWidget(),
///     primaryAction: (label: 'Import', onPressed: handleImport),
///     secondaryAction: (label: 'Cancel', onPressed: () => Navigator.pop(ctx)),
///   ),
/// );
/// ```
class ZestDialogShell extends StatelessWidget {
  const ZestDialogShell({
    super.key,
    required this.tone,
    required this.title,
    required this.body,
    this.icon,
    this.subtitle,
    this.primaryAction,
    this.secondaryAction,
    this.tertiaryAction,
    this.maxWidth = 560,
    this.maxHeight = 720,
    this.size,
    this.onClose,
    this.bodyKey,
    this.autofocusPrimary = false,
    this.primaryKey,
    this.secondaryKey,
    this.tertiaryKey,
    this.primaryDanger = false,
    this.primaryBrand = false,
    this.secondaryDanger = false,
    this.tertiaryDanger = false,
    this.bodyScrolls = true,
    this.footerLeading,
  });

  /// Show this shell as a size-classed modal with the full desktop contract
  /// (Escape closes - guarded by [onDismissAttempt] when there's unsaved
  /// input - Enter submits via [onSubmit], scrim dismiss, focus trap+return).
  /// Prefer this over hand-rolled `showDialog` + `ZestDialogShell`.
  static Future<T?> showModal<T>(
    BuildContext context, {
    required ZestModalSize size,
    required ZestDialogTone tone,
    required String title,
    required Widget body,
    String? subtitle,
    IconData? icon,
    ({String label, VoidCallback? onPressed, IconData? icon})? primaryAction,
    ({String label, VoidCallback? onPressed})? secondaryAction,
    ({String label, VoidCallback? onPressed})? tertiaryAction,
    bool barrierDismissible = true,
    Future<bool> Function()? onDismissAttempt,
    VoidCallback? onSubmit,
    bool primaryDanger = false,
    bool primaryBrand = false,
    bool secondaryDanger = false,
  }) {
    return showZestModal<T>(
      context: context,
      size: size,
      barrierDismissible: barrierDismissible,
      onDismissAttempt: onDismissAttempt,
      onSubmit: onSubmit,
      child: ZestDialogShell(
        size: size,
        tone: tone,
        title: title,
        subtitle: subtitle,
        icon: icon,
        body: body,
        primaryAction: primaryAction,
        secondaryAction: secondaryAction,
        tertiaryAction: tertiaryAction,
        primaryDanger: primaryDanger,
        primaryBrand: primaryBrand,
        secondaryDanger: secondaryDanger,
      ),
    );
  }

  /// What the dialog means ([ZestDialogTone]): the icon's colour (neutral,
  /// red or green) and the main button's (orange, or red).
  final ZestDialogTone tone;

  /// Bold title shown next to the icon.
  final String title;

  /// Optional secondary line shown directly under the title.  One
  /// or two short sentences max - anything longer goes in [body].
  final String? subtitle;

  /// Override the tone's default icon (rarely needed).
  final IconData? icon;

  /// Arbitrary body widget - form, list, status panel, etc. No buttons in
  /// it: they go in the footer (a side option as [tertiaryAction]).
  final Widget body;

  /// Primary action button on the right of the footer, its label what it
  /// does. Filled orange, red where the tone is destructive. Null = no
  /// primary button (rare; useful for status-only dialogs).
  final ({String label, VoidCallback? onPressed, IconData? icon})?
      primaryAction;

  /// Secondary action button (outlined).  Usually "Cancel".
  final ({String label, VoidCallback? onPressed})? secondaryAction;

  /// A side option, a link at the left of the footer ("No password",
  /// "Use a password", "Learn more").
  final ({String label, VoidCallback? onPressed})? tertiaryAction;

  /// Hard width cap.  Default 560 fits most form dialogs without
  /// stretching across an ultra-wide window.
  final double maxWidth;

  /// Hard height cap. Body scrolls if it would exceed this.
  final double maxHeight;

  /// When set, the dialog's width/height come from this size class instead of
  /// [maxWidth]/[maxHeight] - the desktop modal-system source of truth.
  final ZestModalSize? size;

  /// Callback for the close (×) button.  Defaults to popping the
  /// route with `null`.
  final VoidCallback? onClose;

  /// The key of the body's scroll view (tests find the words by it).
  final Key? bodyKey;

  /// Keys for the footer's buttons, where a dialog names them itself
  /// (zest-dialog-primary, -secondary and -tertiary otherwise).
  final Key? primaryKey;
  final Key? secondaryKey;
  final Key? tertiaryKey;

  /// The main button ends or takes something away (Stop sharing, Turn
  /// off, End access): red, whatever the dialog's tone.
  final bool primaryDanger;

  /// The main button in the accent whatever the tone: a dialog that says
  /// something went wrong (red) and offers to try again.
  final bool primaryBrand;

  /// The second button refuses or raises an alarm (Decline, They do not
  /// match, This was not me): red outlined.
  final bool secondaryDanger;

  /// The third button (on the left) refuses (Decline): red outlined.
  final bool tertiaryDanger;

  /// The main button takes the keyboard as the dialog opens, so Enter
  /// answers it (a confirmation's).
  final bool autofocusPrimary;

  /// The body scrolls as one, up to the dialog's height. False: the body is
  /// given that height to fill, and scrolls what it wants to itself (a list
  /// under a search that stays, two panes that scroll apart).
  final bool bodyScrolls;

  /// A line of words at the left of a computer's footer, before its buttons
  /// (Import hosts: "Need to import something else? Let us know"). A phone's
  /// sheet does not show it: a dialog that gives one says it in its body
  /// there.
  final Widget? footerLeading;

  @override
  Widget build(BuildContext context) {
    final meaning = tone.meaning;
    final iconData = icon ?? tone.icon;
    final hasFooter = primaryAction != null || secondaryAction != null || tertiaryAction != null;

    final spec = size?.spec;
    final screenH = MediaQuery.maybeOf(context)?.size.height;
    final effMaxHeight = (spec != null && screenH != null)
        ? screenH * spec.maxHeightFraction
        : maxHeight;

    final sheet = ZestSheetScope.of(context);
    // On a phone's sheet the subtitle opens the body, which scrolls, instead
    // of the header, which does not: with the keyboard up, a long one (Create
    // a team's) left no room for the field under it.
    final headerSubtitle = sheet ? null : subtitle;
    final subtitleStyle = TextStyle(
      fontFamily: 'GeistSans',
      fontSize: 13,
      height: 1.45,
      color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
    );
    final bodyWithSubtitle = sheet && subtitle != null
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(subtitle!, style: subtitleStyle),
              const SizedBox(height: 14),
              if (bodyScrolls) body else Flexible(child: body),
            ],
          )
        : body;
    // A sheet with little height (a phone on its side, the keyboard up): its
    // head comes down to one line of title, with no icon, and where it is wide
    // its buttons stand in a row. They took what there was, and left the body a
    // slit between them, or overflowed. (A confirm whose name is in its title
    // keeps it: with no head at all it read "This cannot be undone. [Delete]",
    // of nothing. And the body keeps its place in the tree: a keyboard that comes
    // up must not take away the field it came up for.)
    final media = MediaQuery.maybeOf(context);
    final short = sheet && media != null && media.size.height - media.viewInsets.bottom < _kSheetShortUnder;
    final buttonsInRow = short && media.size.width >= _kSheetRowOfButtonsFrom;
    return _DialogFrame(
      constraints: BoxConstraints(
        minWidth: spec?.minWidth ?? 0,
        maxWidth: spec?.maxWidth ?? maxWidth,
        maxHeight: effMaxHeight,
      ),
      insetPadding: 28,
      // Its title said where it shows in another's place, or comes back.
      child: ZestInPlaceTitle(
        title: title,
        child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ───────────────────────────────────
                if (short) Padding(
                  key: const ValueKey('zest-dialog-short-title'),
                  padding: const EdgeInsets.fromLTRB(22, 8, 22, 4),
                  // The dialog's name to a screen reader, and its heading.
                  child: Semantics(
                    header: true,
                    namesRoute: true,
                    child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'GeistSans',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.v3TextPrimary,
                      height: 1.3,
                    ),
                  ),
                  ),
                ) else Padding(
                  padding: const EdgeInsets.fromLTRB(22, 20, 14, 4),
                  child: Row(
                    // A title alone sits on the icon's middle line.
                    crossAxisAlignment: headerSubtitle == null ? CrossAxisAlignment.center : CrossAxisAlignment.start,
                    children: [
                      // A small icon, neutral; green for done, red for what
                      // deletes or exposes something (no big tinted tile).
                      ExcludeSemantics(child: Container(
                        key: const ValueKey('zest-dialog-icon'),
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: meaning?.withValues(alpha: 0.14) ?? AppColors.v3TextPrimary.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Icon(
                          iconData,
                          size: 17,
                          color: meaning == null ? AppColors.v3TextSecondary : ZestColors.inkOn(meaning, AppColors.v3Elevated),
                        ),
                      )),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(top: headerSubtitle == null ? 0 : 5),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // The dialog's name to a screen reader, said as
                              // it opens, and its heading.
                              Semantics(
                                header: true,
                                namesRoute: true,
                                child: Text(
                                  title,
                                  style: TextStyle(
                                    fontFamily: 'GeistSans',
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.v3TextPrimary,
                                    letterSpacing: -0.2,
                                    height: 1.3,
                                  ),
                                ),
                              ),
                              if (headerSubtitle != null) ...[
                                const SizedBox(height: 3),
                                Text(headerSubtitle, style: subtitleStyle),
                              ],
                            ],
                          ),
                        ),
                      ),
                      _CloseButton(
                        // In a follow-up shown in place, back to its dialog.
                        onPressed: onClose ?? () => zestDialogPop(context),
                      ),
                    ],
                  ),
                ),
                // (No line under the header nor over the footer: space. The
                // sides keep the inset every dialog's body had, so nothing in
                // one is laid out at a new width.)
                // ── Body (scrolls if too tall, fading at an edge with more
                // beyond it rather than cutting a line in half) ──────
                Flexible(
                  child: bodyScrolls
                      ? _FadingScroll(
                          scrollKey: bodyKey,
                          padding: EdgeInsets.fromLTRB(22, 14, 22, hasFooter ? 4 : 20),
                          child: bodyWithSubtitle,
                        )
                      : Padding(
                          key: bodyKey,
                          padding: EdgeInsets.fromLTRB(22, 14, 22, hasFooter ? 4 : 20),
                          child: bodyWithSubtitle,
                        ),
                ),
                // ── Footer ───────────────────────────────────
                if (hasFooter) ...[
                  if (sheet)
                    // A phone: the buttons across the width, the main
                    // one first.
                    Padding(
                      padding: short ? const EdgeInsets.fromLTRB(16, 8, 16, 8) : const EdgeInsets.fromLTRB(16, 12, 16, 16),
                      child: Flex(
                        direction: buttonsInRow ? Axis.horizontal : Axis.vertical,
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: buttonsInRow ? CrossAxisAlignment.center : CrossAxisAlignment.stretch,
                        // Beside each other, the main one stands last, as on a
                        // computer; over each other, first.
                        textDirection: buttonsInRow && Directionality.of(context) == TextDirection.ltr
                            ? TextDirection.rtl
                            : (buttonsInRow ? TextDirection.ltr : null),
                        children: [
                          for (final (i, button) in <Widget>[
                            if (primaryAction != null)
                              _DialogButtonWithIcon(
                                key: primaryKey ?? const ValueKey('zest-dialog-primary'),
                                label: primaryAction!.label,
                                icon: primaryAction!.icon,
                                onPressed: primaryAction!.onPressed,
                                accent: primaryDanger ? AppColors.v3Error : (primaryBrand ? AppColors.v3AccentPrimary : tone.buttonAccent),
                                filled: true,
                                expand: true,
                              ),
                            if (secondaryAction != null)
                              _DialogButton(
                                key: secondaryKey ?? const ValueKey('zest-dialog-secondary'),
                                label: secondaryAction!.label,
                                onPressed: secondaryAction!.onPressed,
                                filled: false,
                                accent: secondaryDanger ? AppColors.v3Error : AppColors.v3TextSecondary,
                                expand: true,
                              ),
                            if (tertiaryAction != null)
                              _DialogButton(
                                key: tertiaryKey ?? const ValueKey('zest-dialog-tertiary'),
                                label: tertiaryAction!.label,
                                onPressed: tertiaryAction!.onPressed,
                                filled: false,
                                accent: tertiaryDanger ? AppColors.v3Error : AppColors.v3TextSecondary,
                                expand: true,
                                borderless: true,
                              ),
                          ].indexed) ...[
                            if (i > 0) SizedBox(width: buttonsInRow ? 8 : 0, height: buttonsInRow ? 0 : 8),
                            if (buttonsInRow) Expanded(child: button) else button,
                          ],
                        ],
                      ),
                    )
                  else
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 16, 22, 18),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // A line of words, level with the buttons, where the
                        // body's words start; the buttons keep the right half.
                        if (footerLeading != null)
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsetsDirectional.only(start: 8, end: 12, bottom: 6),
                              child: footerLeading,
                            ),
                          ),
                        // The side option: a quiet link, bottom left.
                        if (tertiaryAction != null)
                          _DialogButton(
                            key: tertiaryKey ?? const ValueKey('zest-dialog-tertiary'),
                            label: tertiaryAction!.label,
                            onPressed: tertiaryAction!.onPressed,
                            filled: false,
                            accent: tertiaryDanger ? AppColors.v3Error : AppColors.v3TextSecondary,
                            borderless: true,
                            link: true,
                          ),
                        // A row where the labels fit; stacked, the main
                        // one on top, where a long label (or a longer
                        // language) does not.
                        Expanded(
                          child: OverflowBar(
                            alignment: MainAxisAlignment.end,
                            spacing: 8,
                            overflowSpacing: 8,
                            overflowAlignment: OverflowBarAlignment.end,
                            overflowDirection: VerticalDirection.up,
                            children: [
                              if (secondaryAction != null)
                                _DialogButton(
                                  key: secondaryKey ?? const ValueKey('zest-dialog-secondary'),
                                  label: secondaryAction!.label,
                                  onPressed: secondaryAction!.onPressed,
                                  filled: false,
                                  accent: secondaryDanger ? AppColors.v3Error : AppColors.v3TextSecondary,
                                ),
                              if (primaryAction != null)
                                _DialogButtonWithIcon(
                                  key: primaryKey ?? const ValueKey('zest-dialog-primary'),
                                  label: primaryAction!.label,
                                  icon: primaryAction!.icon,
                                  onPressed: primaryAction!.onPressed,
                                  accent: primaryDanger ? AppColors.v3Error : (primaryBrand ? AppColors.v3AccentPrimary : tone.buttonAccent),
                                  filled: true,
                                  autofocus: autofocusPrimary,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
      ),
    );
  }
}

/// Under this much height, a sheet's head gives up its room ([ZestDialogShell]).
const double _kSheetShortUnder = 340;

/// From this width, a short sheet's buttons stand in a row.
const double _kSheetRowOfButtonsFrom = 480;

/// A dialog's card: centred with its halo on desktops and tablets, a bottom
/// sheet on phones ([ZestSheetScope]).
class _DialogFrame extends StatelessWidget {
  const _DialogFrame({
    required this.constraints,
    required this.insetPadding,
    required this.child,
  });

  final BoxConstraints constraints;
  final double insetPadding;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (ZestSheetScope.of(context)) return ZestSheetFrame(child: child);
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: EdgeInsets.all(insetPadding),
      child: ConstrainedBox(
        constraints: constraints,
        child: _AnimatedScale(
          child: Container(
            // Neutral: no halo in the tone's colour. The theme's line, which
            // shows on a light theme too (a white one did not).
            decoration: BoxDecoration(
              color: AppColors.v3Elevated,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppColors.v3BorderSubtle),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.45),
                  blurRadius: 24,
                  spreadRadius: -4,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            // Ink inside draws on the card, not on the Dialog's Material under it.
            // To a screen reader, a route of its own, named by its title.
            child: Semantics(scopesRoute: true, explicitChildNodes: true, child: InkLayer(child: child)),
          ),
        ),
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  Compact single-input dialog  (UX audit A1)
// ════════════════════════════════════════════════════════════════════

/// Show a **Compact** single-input dialog: one text field inside the full
/// desktop modal chrome (titled header + close control, 380-440px wide,
/// focus trapped on the field and returned to the opener on close, Enter
/// submits, Escape cancels, footer right-aligned with the primary rightmost).
///
/// This is the single class every rename / new-file / new-folder / password
/// prompt routes through, so none of them read as a bare system alert.
///
/// Validation is **inline** - never a toast:
///   * [validator] runs synchronously on submit; return an error string to
///     keep the dialog open with the message under the field, or null to
///     proceed.
///   * [onConfirm] runs asynchronously after [validator] passes (e.g. verify
///     a password, hit the filesystem). Return an error string to surface it
///     inline and keep the dialog open, or null to close with the value.
///     While it runs the buttons disable and [busyLabel] shows with a spinner.
///
/// Resolves with the entered value on success, or null on cancel / dismiss.
Future<String?> showZestInputDialog({
  required BuildContext context,
  required String title,
  String? subtitle,
  IconData? icon,
  ZestDialogTone tone = ZestDialogTone.neutral,
  String? fieldLabel,
  String? hintText,
  String initialValue = '',
  // What the button does ("Rename", "Unlock"), never OK (the dialog
  // rules, 3.4): required, so none is left to a default.
  required String confirmLabel,
  String? cancelLabel,
  bool obscureText = false,
  int? maxLength,
  ZestFieldSelect selectOnFocus = ZestFieldSelect.all,
  String? Function(String value)? validator,
  Future<String?> Function(String value)? onConfirm,
  String? Function()? errorDetails,
  String? busyLabel,
  String? initialError,
  TextInputType? keyboardType,
  List<TextInputFormatter>? inputFormatters,
  Iterable<String>? autofillHints,
}) {
  final l10n = AppLocalizations.of(context)!;
  final key = GlobalKey<_ZestInputDialogState>();
  // Asked from a dialog, in its place (rule 4 of the dialog rules, 3.4).
  return showZestInPlace<String>(
    context: context,
    size: ZestModalSize.compact,
    // Enter anywhere in the modal routes to the same submit path as the
    // primary button and the field's own onSubmitted.
    onSubmit: () => key.currentState?.submit(),
    // Block Escape / scrim dismissal while an async onConfirm is in flight,
    // consistent with the disabled buttons and no-op close control.
    onDismissAttempt: () async => !(key.currentState?.isBusy ?? false),
    builder: (_) => _ZestInputDialog(
      key: key,
      title: title,
      subtitle: subtitle,
      icon: icon,
      tone: tone,
      fieldLabel: fieldLabel,
      hintText: hintText,
      initialValue: initialValue,
      confirmLabel: confirmLabel,
      cancelLabel: cancelLabel ?? l10n.cancel,
      obscureText: obscureText,
      maxLength: maxLength,
      selectOnFocus: selectOnFocus,
      validator: validator,
      onConfirm: onConfirm,
      errorDetails: errorDetails,
      busyLabel: busyLabel ?? l10n.zestDialogWorking,
      initialError: initialError,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      autofillHints: autofillHints,
    ),
  );
}

class _ZestInputDialog extends StatefulWidget {
  const _ZestInputDialog({
    super.key,
    required this.title,
    required this.tone,
    required this.confirmLabel,
    required this.cancelLabel,
    required this.initialValue,
    required this.obscureText,
    required this.selectOnFocus,
    required this.busyLabel,
    this.subtitle,
    this.icon,
    this.fieldLabel,
    this.hintText,
    this.maxLength,
    this.validator,
    this.onConfirm,
    this.errorDetails,
    this.initialError,
    this.keyboardType,
    this.inputFormatters,
    this.autofillHints,
  });

  final Iterable<String>? autofillHints;
  final String title;
  final String? subtitle;
  final IconData? icon;
  final ZestDialogTone tone;
  final String? fieldLabel;
  final String? hintText;
  final String initialValue;
  final String confirmLabel;
  final String cancelLabel;
  final bool obscureText;
  final int? maxLength;
  final ZestFieldSelect selectOnFocus;
  final String busyLabel;
  final String? Function(String value)? validator;
  final Future<String?> Function(String value)? onConfirm;

  /// What is behind the error [onConfirm] said, for Copy details under the
  /// field. Null where there is nothing more.
  final String? Function()? errorDetails;

  /// Seed the inline error slot (e.g. "Wrong passphrase" from a prior
  /// attempt when the caller re-opens the prompt to retry).
  final String? initialError;

  /// The keyboard a phone shows, and what may be typed (a PIN: digits).
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  @override
  State<_ZestInputDialog> createState() => _ZestInputDialogState();
}

class _ZestInputDialogState extends State<_ZestInputDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.initialValue);
  final FocusNode _fieldFocus = FocusNode();
  late String? _error = widget.initialError;
  bool _submitting = false;

  /// One-shot guard: on desktop a single Enter dispatches submit() TWICE
  /// (the modal's Enter Shortcut AND the field's onSubmitted), so an
  /// unguarded Navigator.pop would fire twice - closing the dialog AND
  /// popping the screen beneath it. Route every close through _finish so
  /// only the first pop takes effect.
  bool _closing = false;

  /// True while an async [onConfirm] is running - the modal blocks Escape /
  /// scrim dismissal during this window (in lockstep with the disabled
  /// buttons) so a mid-operation dismiss can't make the caller skip its
  /// post-success refresh.
  bool get isBusy => _submitting;

  @override
  void dispose() {
    _controller.dispose();
    _fieldFocus.dispose();
    super.dispose();
  }

  void _finish(String? value) {
    if (_closing || !mounted) return;
    _closing = true;
    zestDialogPop(context, value);
  }

  Future<void> submit() async {
    if (_submitting || _closing) return;
    final value = _controller.text;

    final syncError = widget.validator?.call(value);
    if (syncError != null) {
      setState(() => _error = syncError);
      _fieldFocus.requestFocus();
      return;
    }

    if (widget.onConfirm != null) {
      setState(() {
        _submitting = true;
        _error = null;
      });
      final asyncError = await widget.onConfirm!(value);
      if (!mounted) return;
      if (asyncError != null) {
        setState(() {
          _error = asyncError;
          _submitting = false;
        });
        _fieldFocus.requestFocus();
        return;
      }
      _finish(value);
      return;
    }

    _finish(value);
  }

  @override
  Widget build(BuildContext context) {
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: widget.tone,
      icon: widget.icon,
      title: widget.title,
      subtitle: widget.subtitle,
      onClose: _submitting ? () {} : () => zestDialogPop(context),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          ZestTextField(
            controller: _controller,
            focusNode: _fieldFocus,
            label: widget.fieldLabel,
            hintText: widget.hintText,
            obscureText: widget.obscureText,
            maxLength: widget.maxLength,
            selectOnFocus: widget.selectOnFocus,
            keyboardType: widget.keyboardType,
            inputFormatters: widget.inputFormatters,
            autofillHints: widget.autofillHints,
            errorText: _error,
            onSubmit: submit,
            onChanged: (_) {
              if (_error != null) setState(() => _error = null);
            },
          ),
          if (_error != null && widget.errorDetails?.call() != null)
            CopyDetailsButton(detail: widget.errorDetails!()!),
          if (_submitting) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.v3AccentPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  widget.busyLabel,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 12.5,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
      secondaryAction: (
        label: widget.cancelLabel,
        onPressed: _submitting ? null : () => zestDialogPop(context),
      ),
      primaryAction: (
        label: widget.confirmLabel,
        icon: null,
        onPressed: _submitting ? null : submit,
      ),
    );
  }
}

// ════════════════════════════════════════════════════════════════════
//  A choice, and work under way (the dialog rules, 3.4)
// ════════════════════════════════════════════════════════════════════

/// One of the choices [showZestChoice] offers.
class ZestChoice<T> {
  const ZestChoice({required this.value, required this.label, this.detail, this.icon, this.key});

  final T value;
  final String label;

  /// A quieter line under the label.
  final String? detail;
  final IconData? icon;

  /// The row's key (tests find a choice by it).
  final Key? key;
}

/// One of a few choices (how long to pause sync for, an interval, a
/// category), in the shell: each a row with a dot radio, the one in use
/// picked (a dot radio for one of a few,
/// a check only where several can be picked); a tap (or Enter) on a row
/// chooses it and closes the dialog, and Cancel is in the footer. (It was a
/// Material SimpleDialog, which kept none of the dialog rules of 3.4.)
///
/// Resolves with the chosen value, or null where it was closed without one,
/// so a choice whose value is null cannot be told from that: give "None" a
/// value of its own.
Future<T?> showZestChoice<T>(
  BuildContext context, {
  required String title,
  String? subtitle,
  IconData? icon,
  required List<ZestChoice<T>> choices,
  T? selected,
  String? cancelLabel,
  Key? key,
}) {
  final l10n = AppLocalizations.of(context)!;
  // Asked from a dialog, in its place (rule 4 of the dialog rules, 3.4).
  return showZestInPlace<T>(
    context: context,
    size: ZestModalSize.compact,
    builder: (ctx) => ZestDialogShell(
      key: key,
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: icon ?? LucideIcons.listChecks,
      title: title,
      subtitle: subtitle,
      body: RadioGroup<T>(
        groupValue: selected,
        onChanged: (value) {
          if (value != null) zestDialogPop(ctx, value);
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final c in choices)
              _ChoiceRow(
                key: c.key,
                label: c.label,
                detail: c.detail,
                icon: c.icon,
                radio: Radio<T>(value: c.value),
                selected: selected != null && c.value == selected,
                onTap: () => zestDialogPop(ctx, c.value),
              ),
          ],
        ),
      ),
      secondaryAction: (label: cancelLabel ?? l10n.cancel, onPressed: () => zestDialogPop(ctx)),
    ),
  );
}

class _ChoiceRow extends StatelessWidget {
  const _ChoiceRow({
    super.key,
    required this.label,
    required this.radio,
    required this.selected,
    required this.onTap,
    this.detail,
    this.icon,
  });

  final String label;
  final String? detail;
  final IconData? icon;
  final Widget radio;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MergeSemantics(
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onTap,
          child: Container(
            constraints: BoxConstraints(minHeight: zestUsesSheets(context) ? 48 : 38),
            padding: const EdgeInsetsDirectional.fromSTEB(2, 4, 10, 4),
            child: Row(
              children: [
                // The dot radio, as every one-of-a-few in the app.
                ExcludeFocus(child: radio),
                const SizedBox(width: 4),
                if (icon != null) ...[
                  Icon(icon, size: 16, color: AppColors.v3TextSecondary),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontFamily: 'GeistSans',
                          fontSize: 13.5,
                          height: 1.35,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                          color: AppColors.v3TextPrimary,
                        ),
                      ),
                      if (detail != null && detail!.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          detail!,
                          style: TextStyle(
                            fontFamily: 'GeistSans',
                            fontSize: 12,
                            height: 1.4,
                            color: AppColors.v3TextSecondary.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Work under way that is waited for (deletes finishing, files going to the
/// bin, an account being deleted): a spinner and what is being done, in the
/// app's dialog frame, with no close button; Escape, back and a tap outside
/// leave it where it is. Returns what closes it, which may be called more
/// than once. [label] is what is being done; [updates], where given, says it
/// as it changes. [cancel]: where the work can be stopped, its button, in
/// the footer (it stops the work; the caller closes this when the work ends).
///
/// It opens on the app's own navigator, as the dialogs it replaces did, and
/// closes exactly the dialog it opened, whatever opened over it since.
VoidCallback showZestBusy(
  BuildContext context, {
  required String label,
  ValueListenable<String>? updates,
  ({String label, VoidCallback onPressed})? cancel,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = true;
  Route<Object?>? route;
  unawaited(showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    barrierDismissible: false,
    onDismissAttempt: () async => false,
    useRootNavigator: true,
    child: PopScope(
      canPop: false,
      child: Builder(builder: (ctx) {
        route ??= ModalRoute.of(ctx);
        return _ZestBusyCard(label: label, updates: updates, cancel: cancel);
      }),
    ),
  ).whenComplete(() => open = false));
  return () {
    if (!open) return;
    open = false;
    final shown = route;
    if (shown == null || shown.isCurrent) {
      navigator.pop();
    } else if (shown.isActive) {
      navigator.removeRoute(shown);
    }
  };
}

class _ZestBusyCard extends StatelessWidget {
  const _ZestBusyCard({required this.label, this.updates, this.cancel});

  final String label;
  final ValueListenable<String>? updates;
  final ({String label, VoidCallback onPressed})? cancel;

  @override
  Widget build(BuildContext context) {
    final words = TextStyle(
      fontFamily: 'GeistSans',
      fontSize: 13.5,
      height: 1.45,
      color: AppColors.v3TextPrimary,
    );
    return _DialogFrame(
      constraints: const BoxConstraints(minWidth: 300, maxWidth: 440),
      insetPadding: 28,
      child: Padding(
        padding: EdgeInsets.fromLTRB(22, 20, 22, cancel == null ? 20 : 14),
        child: Column(
          key: const ValueKey('zest-busy'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ExcludeSemantics(
                  child: SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3TextSecondary),
                  ),
                ),
                const SizedBox(width: 14),
                // Said to a screen reader as it shows and as it changes.
                Expanded(
                  child: Semantics(
                    liveRegion: true,
                    child: updates == null
                        ? Text(label, style: words)
                        : ValueListenableBuilder<String>(
                            valueListenable: updates!,
                            builder: (_, value, _) => Text(value, style: words),
                          ),
                  ),
                ),
              ],
            ),
            if (cancel != null) ...[
              const SizedBox(height: 14),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: _DialogButton(
                  key: const ValueKey('zest-busy-cancel'),
                  label: cancel!.label,
                  onPressed: cancel!.onPressed,
                  filled: false,
                  accent: AppColors.v3TextSecondary,
                  expand: zestUsesSheets(context),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _DialogButtonWithIcon extends StatefulWidget {
  const _DialogButtonWithIcon({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    required this.accent,
    required this.filled,
    this.expand = false,
    this.autofocus = false,
  });

  /// Takes the keyboard as it appears: Enter or Space presses it.
  final bool autofocus;

  final String label;
  final IconData? icon;
  final VoidCallback? onPressed;
  final Color accent;
  final bool filled;

  /// Across the width, taller (a phone's sheet).
  final bool expand;

  @override
  State<_DialogButtonWithIcon> createState() => _DialogButtonWithIconState();
}

class _DialogButtonWithIconState extends State<_DialogButtonWithIcon> {
  bool _hover = false;
  bool _pressed = false;
  bool _focusRing = false; // keyboard focus only
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusNode.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final disabled = widget.onPressed == null;
    final danger = widget.accent == AppColors.v3Error;
    final accent = danger ? _dangerFill(widget.accent) : widget.accent;

    // Turned off: the theme's one turned-off fill and its words, as every
    // disabled button (a fixed white vanished on a light theme; the text at
    // 6% nearly did on a dark sheet).
    final bg = disabled
        ? ZestColors.disabledFill
        : (_hover ? Color.lerp(accent, AppColors.v3TextPrimary, 0.08)! : accent);
    // Dark text on a brand fill, as everywhere (AppColors.onBrand); white on
    // the danger red.
    final fg = disabled ? ZestColors.disabledInk : _onFill(widget.accent);

    final still = zestReduceMotion(context);
    final squeeze = _pressed && !still ? 0.97 : 1.0;
    return _DialogButtonKeys(
      focusNode: _focusNode,
      onPressed: widget.onPressed,
      onFocusRing: (f) => setState(() => _focusRing = f),
      child: ZestFocusRing(
      show: _focusRing,
      radius: widget.expand ? 10 : 8,
      child: MouseRegion(
      cursor: disabled
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: zestMotion(context, const Duration(milliseconds: 120)),
          curve: Curves.easeOut,
          alignment: widget.expand ? Alignment.center : null,
          // At least the least target each way (32 with a mouse, 48 where a
          // finger presses it), the words in its middle.
          constraints: BoxConstraints(minHeight: zestUsesSheets(context) ? 48 : minTapTarget(context)),
          padding: EdgeInsets.symmetric(
              horizontal: 16, vertical: widget.expand ? 13 : 9),
          transform: Matrix4.identity()
            ..scaleByDouble(squeeze, squeeze, squeeze, 1),
          transformAlignment: Alignment.center,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(widget.expand ? 10 : 8),
            boxShadow: !disabled && _hover
                ? [
                    BoxShadow(
                      color: accent.withValues(alpha: 0.35),
                      blurRadius: 14,
                      spreadRadius: -3,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: fg),
                const SizedBox(width: 7),
              ],
              // A label longer than the room beside a side option (a longer
              // language) wraps rather than running out of the button.
              Flexible(
                child: Text(
                  widget.label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
      ),
    );
  }
}

/// A dialog button's keyboard and screen reader side: a button by its label
/// to a screen reader (said turned off where it is), a stop for Tab, pressed
/// by Enter or Space, and the ring shown while the keyboard is on it.
class _DialogButtonKeys extends StatelessWidget {
  const _DialogButtonKeys({
    required this.focusNode,
    required this.onPressed,
    required this.onFocusRing,
    required this.child,
  });

  final FocusNode focusNode;
  final VoidCallback? onPressed;
  final ValueChanged<bool> onFocusRing;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Semantics(
      container: true,
      button: true,
      enabled: enabled,
      child: FocusableActionDetector(
        focusNode: focusNode,
        // A turned-off button keeps its place for Tab, as it did: its words
        // still say what it would do.
        mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onShowFocusHighlight: onFocusRing,
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {ActivateIntent: _PressAction(onPressed)},
        child: child,
      ),
    );
  }
}

/// Presses a dialog button; turned off, it takes no key, which goes on to
/// the dialog (Enter submits it where it can be).
class _PressAction extends Action<ActivateIntent> {
  _PressAction(this.onPressed);

  final VoidCallback? onPressed;

  @override
  bool isEnabled(ActivateIntent intent) => onPressed != null;

  @override
  Object? invoke(ActivateIntent intent) {
    onPressed?.call();
    return null;
  }
}

/// A scroll view whose edge fades where there is more beyond it, so a line
/// is never cut in half under a header or above a footer.
class _FadingScroll extends StatefulWidget {
  const _FadingScroll({required this.child, required this.padding, this.scrollKey});

  final Widget child;
  final EdgeInsets padding;
  final Key? scrollKey;

  @override
  State<_FadingScroll> createState() => _FadingScrollState();
}

class _FadingScrollState extends State<_FadingScroll> {
  final _controller = ScrollController();
  bool _above = false;
  bool _below = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_measure);
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
  }

  void _measure() {
    if (!mounted || !_controller.hasClients) return;
    final p = _controller.position;
    final above = p.pixels > 0.5;
    final below = p.pixels < p.maxScrollExtent - 0.5;
    if (above != _above || below != _below) {
      setState(() {
        _above = above;
        _below = below;
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scroll = NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        return false;
      },
      child: SingleChildScrollView(
        key: widget.scrollKey,
        controller: _controller,
        padding: widget.padding,
        child: widget.child,
      ),
    );
    // Always masked (opaque where nothing waits beyond an edge): adding the
    // mask only when needed rebuilt the scroll view, which lost its place,
    // which took the mask away again, frame after frame.
    return ShaderMask(
      shaderCallback: (rect) => LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          _above ? Colors.transparent : Colors.black,
          Colors.black,
          Colors.black,
          _below ? Colors.transparent : Colors.black,
        ],
        stops: [0, 18 / rect.height.clamp(36, double.infinity), 1 - 18 / rect.height.clamp(36, double.infinity), 1],
      ).createShader(rect),
      blendMode: BlendMode.dstIn,
      child: scroll,
    );
  }
}

// ── Internal widgets ───────────────────────────────────────────────

class _AnimatedScale extends StatefulWidget {
  const _AnimatedScale({required this.child});
  final Widget child;

  @override
  State<_AnimatedScale> createState() => _AnimatedScaleState();
}

class _AnimatedScaleState extends State<_AnimatedScale>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
  )..forward();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Less motion asked for: there at once, not grown and faded in.
    if (zestReduceMotion(context)) return widget.child;
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, child) {
        // Emphasized ease: cubic-bezier(0.16, 1, 0.3, 1) approximated
        // via Curves.easeOutCubic.
        final t = Curves.easeOutCubic.transform(_ctrl.value);
        return Opacity(
          opacity: t,
          child: Transform.scale(
            scale: 0.96 + (0.04 * t),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _CloseButton extends StatefulWidget {
  const _CloseButton({required this.onPressed});
  final VoidCallback onPressed;
  @override
  State<_CloseButton> createState() => _CloseButtonState();
}

class _CloseButtonState extends State<_CloseButton> {
  bool _hover = false;
  bool _focusRing = false; // keyboard focus only
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Where a finger presses it (a phone's sheet, a tablet's dialog) its
    // target is 48 square; the cross still looks 28. With a mouse, 32.
    final target = zestUsesSheets(context) || touchSizedAt(context) ? 48.0 : 32.0;
    // A button by name to a screen reader ("Close, button"), and a stop for
    // the keyboard with the accent ring, where it was a picture of a cross
    // that only a pointer could press (Escape closed it, but nothing said so).
    return Semantics(
      container: true,
      button: true,
      label: l10n.close,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: Tooltip(
        message: l10n.close,
        excludeFromSemantics: true,
        child: ZestHover(onHover: (h) => setState(() => _hover = h), child: FocusableActionDetector(
          mouseCursor: SystemMouseCursors.click,
          onShowFocusHighlight: (f) => setState(() => _focusRing = f),
          shortcuts: const {
            SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.numpadEnter): ActivateIntent(),
            SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
          },
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
              widget.onPressed();
              return null;
            }),
          },
          child: GestureDetector(
            key: const ValueKey('zest-dialog-close'),
            behavior: HitTestBehavior.opaque,
            onTap: widget.onPressed,
            child: SizedBox.square(
              dimension: target,
              child: Center(
                child: ZestFocusRing(
                  show: _focusRing,
                  radius: 6,
                  gap: 2,
                  child: AnimatedContainer(
                    duration: zestMotion(context, const Duration(milliseconds: 120)),
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _hover ? AppColors.v3TextPrimary.withValues(alpha: 0.07) : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Icon(
                      LucideIcons.x,
                      size: 14,
                      color: _hover ? AppColors.v3TextPrimary : AppColors.v3TextSecondary,
                    ),
                  ),
                ),
              ),
            ),
          ),
        )),
      ),
    );
  }
}

class _DialogButton extends StatefulWidget {
  const _DialogButton({
    super.key,
    required this.label,
    required this.onPressed,
    required this.filled,
    required this.accent,
    this.expand = false,
    this.borderless = false,
    this.link = false,
  });

  final String label;

  /// A side option drawn as a link: no box, less room either side.
  final bool link;

  /// Null: shown disabled (while the dialog is busy, say).
  final VoidCallback? onPressed;
  final bool filled;
  final Color accent;

  /// Across the width, taller (a phone's sheet).
  final bool expand;

  /// No outline (a sheet's quiet last button).
  final bool borderless;

  @override
  State<_DialogButton> createState() => _DialogButtonState();
}

class _DialogButtonState extends State<_DialogButton> {
  bool _hover = false;
  bool _pressed = false;
  bool _focusRing = false; // keyboard focus only
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final filled = widget.filled;
    final accent = filled && widget.accent == AppColors.v3Error ? _dangerFill(widget.accent) : widget.accent;

    final bg = filled
        ? (_hover ? Color.lerp(accent, AppColors.v3TextPrimary, 0.08)! : accent)
        : (_hover
            ? Colors.white.withValues(alpha: 0.05)
            : Colors.transparent);
    // Not filled, the accent is a label: the nearest shade of it that reads
    // on the dialog (the brand orange is 2.3:1 on Daylight's).
    final fg = filled ? _onFill(widget.accent) : ZestColors.inkOn(accent, AppColors.v3Elevated);
    // The theme's strong border, so an outline shows on light themes too.
    final border = filled || widget.borderless
        ? Colors.transparent
        : (widget.accent == AppColors.v3Error ? accent.withValues(alpha: 0.55) : AppColors.v3BorderStrong);

    final squeeze = _pressed && !zestReduceMotion(context) ? 0.97 : 1.0;
    return _DialogButtonKeys(
      focusNode: _focusNode,
      onPressed: widget.onPressed,
      onFocusRing: (f) => setState(() => _focusRing = f),
      child: ZestFocusRing(
      show: _focusRing,
      child: Opacity(
        opacity: widget.onPressed == null ? 0.45 : 1,
        child: MouseRegion(
        cursor: widget.onPressed == null ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: zestMotion(context, const Duration(milliseconds: 120)),
            curve: Curves.easeOut,
            alignment: widget.expand ? Alignment.center : null,
            // At least the least target high (32 with a mouse, 48 where a
            // finger presses it).
            constraints: BoxConstraints(minHeight: zestUsesSheets(context) ? 48 : minTapTarget(context)),
            padding: EdgeInsets.symmetric(
                horizontal: widget.link ? 8 : 16, vertical: widget.expand ? 13 : 9),
            transform: Matrix4.identity()
              ..scaleByDouble(squeeze, squeeze, squeeze, 1),
            transformAlignment: Alignment.center,
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: border),
              boxShadow: filled && _hover
                  ? [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.35),
                        blurRadius: 14,
                        spreadRadius: -3,
                        offset: const Offset(0, 4),
                      ),
                    ]
                  : null,
            ),
            child: Align(
              widthFactor: 1,
              heightFactor: 1,
              child: Text(
                widget.label,
                style: TextStyle(
                  fontFamily: 'GeistSans',
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: fg,
                  letterSpacing: 0.1,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
    ),
    );
  }
}
