import 'package:flutter/gestures.dart' show DragStartBehavior;
import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The least width of the left-hand label cell, and its width where nothing
/// measures it. A standalone [ZestField], a `.custom` one, and a
/// [ZestFieldGroup] all align their inputs on the same vertical rule. 88px did
/// not fit every name in every language ("Soprannome" in Italian, at the size
/// the app is drawn at; most names at 1.3 times): a form whose names may be
/// longer measures its column from them ([ZestFieldLabels]).
const double _kFieldLabelWidth = 88;

/// The width of a form's label column that holds each of [labels] on one line
/// at the text size it is drawn at: at least [min], and at most 42% of the
/// screen (and 240). A name longer than that wraps to a second line. With
/// [icons], the column holds a field's icon before its name as well.
double zestFieldLabelWidth(BuildContext context, Iterable<String> labels,
    {double min = _kFieldLabelWidth, bool icons = false}) {
  var widest = 0.0;
  for (final label in labels) {
    final width = _labelTextWidth(context, label);
    if (width > widest) widest = width;
  }
  final most = MediaQuery.sizeOf(context).width * 0.42;
  return (widest + 26 + (icons ? _kLabelIconWidth : 0)).clamp(min, most < min ? min : (most > 240 ? 240.0 : most));
}

/// A field's icon before its name, with the room after it ([_labelText]).
const double _kLabelIconWidth = 15 + 7;

/// Gives the [ZestField]s and [ZestFieldGroup]s under it that name no width of
/// their own a label column measured from [labels] ([zestFieldLabelWidth]):
/// a form's inputs stay on one rule, and no name is cut, whatever the
/// language and the text size.
///
/// A field under it stands its name above its value where beside it the name
/// or the value would be cut: where one of the names does not hold in the
/// column, a word of it being longer ("Широковещательный" in Russian, at the
/// size the app is drawn at) or it needing more than two lines, or where the
/// value would keep less than [_kMinValueWidth].
class ZestFieldLabels extends StatelessWidget {
  const ZestFieldLabels({super.key, required this.labels, this.min = _kFieldLabelWidth, required this.child});

  final List<String> labels;

  /// The least width of the column.
  final double min;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final width = zestFieldLabelWidth(context, labels, min: min);
    return _ZestFieldLabelWidth(width: width, stacked: labels.any((l) => !_holds(context, l, width - 22)), child: child);
  }
}

class _ZestFieldLabelWidth extends InheritedWidget {
  const _ZestFieldLabelWidth({required this.width, required this.stacked, required super.child});

  final double width;

  /// Whether the form's names stand above their values, one of them not
  /// holding in the column.
  final bool stacked;

  @override
  bool updateShouldNotify(_ZestFieldLabelWidth oldWidget) =>
      oldWidget.width != width || oldWidget.stacked != stacked;
}

/// How wide [text] is drawn on one line as a field's name, at the text size it
/// is drawn at.
double _labelTextWidth(BuildContext context, String text) {
  final painter = _labelPainter(context, text, maxLines: 1)..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

/// Whether a field's name [label] holds in [width] as its cell draws it: each
/// of its words on a line, and on two lines at most.
bool _holds(BuildContext context, String label, double width) {
  for (final word in label.split(' ')) {
    if (_labelTextWidth(context, word) > width) return false;
  }
  final painter = _labelPainter(context, label, maxLines: 2)..layout(maxWidth: width);
  final holds = !painter.didExceedMaxLines;
  painter.dispose();
  return holds;
}

TextPainter _labelPainter(BuildContext context, String text, {required int maxLines}) {
  final base = Theme.of(context).textTheme.bodyMedium ?? DefaultTextStyle.of(context).style;
  return TextPainter(
    text: TextSpan(text: text, style: base.merge(const TextStyle(fontSize: 12, height: 1.2))),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
    maxLines: maxLines,
  );
}

/// The label column a field takes where it names none: its form's, or the
/// least.
double _labelWidthOf(BuildContext context) =>
    context.dependOnInheritedWidgetOfExactType<_ZestFieldLabelWidth>()?.width ?? _kFieldLabelWidth;

/// Where a field's value starts in the form around [context]: past the
/// names' column, or at the start where the names stand above their values.
double zestFieldValueStart(BuildContext context) {
  final form = context.dependOnInheritedWidgetOfExactType<_ZestFieldLabelWidth>();
  if (form?.stacked ?? false) return 0;
  return form?.width ?? _kFieldLabelWidth;
}

/// Every field is at LEAST this tall; a validator's error subtext (or a tall
/// multi-line field) grows the box downward from here.
const double _kFieldMinHeight = 40;

/// The port segment of an Address+Port [ZestFieldGroup] is a fixed narrow region
/// so a value like "22" never clips. Exposed so callers laying out an
/// address/port row use the SAME width the Hosts editor uses.
const double kZestPortSegmentWidth = 64;

/// The app's monospace family. Existing-system-wins: the app already ships and
/// bundles 'JetBrainsMono' for all code/command/key text (terminal, snippets,
/// keycaps), so mono fields use that family for one consistent monospace.
const String _kMonoFamily = 'JetBrainsMono';

/// A truly BARE input decoration: no fill, no border in any state, and zero
/// internal padding, so the hosting [ZestField] shell is the only surface and
/// the value region reads as part of the container rather than a separately
/// decorated box nested inside it. `isCollapsed`/`isDense` keep a
/// [DropdownButtonFormField] from ballooning the row taller than a text field.
/// The error subtext still renders (and can grow the box) via [errorStyle].
///
/// Public so a caller building its OWN input widget (a [DropdownButtonFormField],
/// a [TextFormField] with a validator, ...) as the `child` of a [ZestField.custom]
/// or a [ZestFieldGroup] segment can give it the same bare look as the built-in
/// text field.
InputDecoration zestShellFieldDecoration({String? hintText}) =>
    InputDecoration(
      isCollapsed: true,
      isDense: true,
      filled: false,
      contentPadding: EdgeInsets.zero,
      border: InputBorder.none,
      enabledBorder: InputBorder.none,
      focusedBorder: InputBorder.none,
      errorBorder: InputBorder.none,
      focusedErrorBorder: InputBorder.none,
      disabledBorder: InputBorder.none,
      hintStyle: TextStyle(color: ZestTokens.textPlaceholder, fontSize: 13),
      errorStyle: TextStyle(
        color: ZestTokens.statusCritical,
        fontSize: 11.5,
        height: 1.2,
      ),
    ).copyWith(hintText: hintText);

/// The shared value text style (13px, primary). Matches the Hosts editor
/// `.val`. A getter: a top-level style kept the first theme's colour, so a
/// value was drawn light on a light theme's white.
TextStyle get _kValueStyle => TextStyle(fontSize: 13, color: ZestTokens.textPrimary, height: 1.25);

/// The shared MONO value text style. Matches the Hosts editor `.val.mono`.
TextStyle get _kValueMonoStyle => TextStyle(
      fontSize: 13,
      color: ZestTokens.textPrimary,
      fontFamily: _kMonoFamily,
      height: 1.25,
    );

/// A light theme lifts its fields: the well white, the label cell a step
/// tinted (dark themes the other way round, the well a step down).
bool get _kLight => ZestTokens.surfaceBase.computeLuminance() > 0.5;
Color get _kWell => _kLight ? ZestTokens.surfaceRaised : ZestTokens.surfaceSunken;
Color get _kLabelCell => _kLight ? ZestTokens.surfaceSunken : ZestTokens.surfaceRaised;

/// The shared `.cell` label: [width], [ZestTokens.surfaceRaised] surface
/// (painted behind by the shell), 12px [ZestTokens.textTertiary], 11px
/// horizontal padding. A name longer than its cell wraps to a second line
/// rather than being cut. [top] pins the label to the top for tall (Note /
/// Tags) fields. An optional [leadingIcon] is drawn before the label for forms
/// that want an icon cue.
Widget _fieldLabelCell(
  String label, {
  required double width,
  required bool top,
  IconData? leadingIcon,
  bool said = true,
}) {
  return SizedBox(
    width: width,
    child: Padding(
      padding: EdgeInsets.fromLTRB(11, top ? 12 : 0, 11, 0),
      child: ExcludeSemantics(excluding: !said, child: _labelText(label, leadingIcon)),
    ),
  );
}

/// A field's name, with its icon before it where it has one.
Widget _labelText(String label, IconData? leadingIcon) {
  final text = Text(
    label,
    maxLines: 2,
    overflow: TextOverflow.clip,
    style: TextStyle(
      fontSize: 12,
      height: 1.2,
      color: ZestTokens.textTertiary,
    ),
  );
  return leadingIcon == null
      ? text
      : Row(
          children: [
            Icon(leadingIcon, size: 15, color: ZestTokens.textTertiary),
            const SizedBox(width: 7),
            Flexible(child: text),
          ],
        );
}

/// The least room a field's value keeps beside its form's label column, at
/// the text size the app is drawn at; it grows with the text. Under a
/// [ZestFieldLabels], a field with less stands its name above its value.
const double _kMinValueWidth = 140;

/// A field's name beside its value ([beside]), or, under a
/// [ZestFieldLabels] whose names would be cut in its column or where the
/// value beside the column would keep less than [_kMinValueWidth], above it:
/// the name in the raised band across the top of the field, the [value]
/// under it. A field under no [ZestFieldLabels] keeps its name beside.
class _BesideOrAbove extends StatelessWidget {
  const _BesideOrAbove({
    required this.label,
    required this.leadingIcon,
    required this.labelWidth,
    required this.beside,
    required this.value,
    this.labelSaid = true,
  });

  final String label;
  final IconData? leadingIcon;
  final double labelWidth;
  final Widget beside;
  final Widget value;

  /// False where the input says the name itself (it is not read twice).
  final bool labelSaid;

  @override
  Widget build(BuildContext context) {
    final form = context.dependOnInheritedWidgetOfExactType<_ZestFieldLabelWidth>();
    if (form == null) return beside;
    return LayoutBuilder(builder: (context, box) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      if (!form.stacked && box.maxWidth - labelWidth - 1 >= _kMinValueWidth * scale) return beside;
      return Column(
        key: const ValueKey('zest-field-name-above'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ColoredBox(
            color: _kLabelCell,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(11, 7, 11, 6),
              child: ExcludeSemantics(excluding: !labelSaid, child: _labelText(label, leadingIcon)),
            ),
          ),
          Container(height: 1, color: ZestTokens.border),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: _kFieldMinHeight),
            child: value,
          ),
        ],
      );
    });
  }
}

/// The single-input field shell: ONE bordered, rounded container
/// ([ZestTokens.surfaceSunken] surface, 0.5px [ZestTokens.border], radius 8,
/// clipped) that carries EVERYTHING. Inside, a fixed `.cell` label region and a
/// bare value region sit flush - the value has no fill, border, radius, or
/// padding of its own beyond the shared 11px, so it is NOT a box nested inside a
/// box, and every field is the same [_kFieldMinHeight].
///
/// A [Stack] paints the raised `.cell` fill + 1px divider full-height BEHIND the
/// content (rather than an [IntrinsicHeight]) so it stays safe around children
/// that reject intrinsic sizing - dropdowns, a tags [Wrap], multi-line notes -
/// while `minHeight` still lets a validator's error text grow the box.
class _ZestFieldShell extends StatelessWidget {
  const _ZestFieldShell({
    required this.label,
    required this.child,
    this.leadingIcon,
    this.helperText,
    this.helperIsError = false,
    this.labelWidth = _kFieldLabelWidth,
    this.tall = false,
    this.onResize,
    this.labelSaid = true,
    this.padValue = true,
  });

  final String label;
  final Widget child;

  /// False where the input inside says the field's name itself (the
  /// built-in text input): its name's cell is not read as words of their
  /// own as well.
  final bool labelSaid;

  /// False where the input pads itself top and bottom, so that its own
  /// target fills the box (the built-in text input): only the sides are
  /// padded here. Such a field also puts the keyboard in its input from a
  /// press anywhere in it.
  final bool padValue;
  final IconData? leadingIcon;
  final String? helperText;
  final bool helperIsError;

  /// Fixed width of the `.cell` - a shared const so every field aligns on one
  /// vertical rule. Never sized to content, so labels never truncate.
  final double labelWidth;

  /// Top-aligns the label + value so the field can grow downward from
  /// [_kFieldMinHeight] (Note / Tags).
  final bool tall;

  /// Where given, the small resize grip in the bottom-right corner, which
  /// hands it each vertical move of a drag (the Note field).
  final ValueChanged<double>? onResize;

  @override
  Widget build(BuildContext context) {
    return _FieldFocusRing(tapToFocus: !padValue, builder: (focused) {
    final field = Container(
      constraints: const BoxConstraints(minHeight: _kFieldMinHeight),
      decoration: BoxDecoration(
        color: _kWell,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
      ),
      // Orange border while any input inside this field holds keyboard focus,
      // so Tab / Shift+Tab give a visible focus ring on every field (dropdowns
      // included, which otherwise showed nothing when focused). Drawn over
      // the field, not around it: the input inside fills the box (its
      // target), and nothing moves as the ring thickens.
      foregroundDecoration: _fieldEdge(focused),
      clipBehavior: Clip.antiAlias,
      child: _BesideOrAbove(
        label: label,
        leadingIcon: leadingIcon,
        labelWidth: labelWidth,
        labelSaid: labelSaid,
        value: Align(
          alignment: tall ? AlignmentDirectional.topStart : AlignmentDirectional.centerStart,
          child: Padding(
            padding: EdgeInsets.fromLTRB(11, tall && padValue ? 11 : 0, 11, tall && padValue ? 11 : 0),
            child: child,
          ),
        ),
        beside: Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned.fill(
            child: Row(
              children: [
                Container(width: labelWidth, color: _kLabelCell),
                Container(width: 1, color: ZestTokens.border),
              ],
            ),
          ),
          Row(
            // Single-line fields center vertically; tall fields (Note / Tags)
            // top-align so they grow downward.
            crossAxisAlignment:
                tall ? CrossAxisAlignment.start : CrossAxisAlignment.center,
            children: [
              _fieldLabelCell(
                label,
                width: labelWidth,
                top: tall,
                leadingIcon: leadingIcon,
                said: labelSaid,
              ),
              const SizedBox(width: 1),
              Expanded(
                child: Padding(
                  // Bare value region: only the shared 11px horizontal padding
                  // (plus a symmetric 11px top/bottom for tall fields, where
                  // the input does not pad itself).
                  padding: EdgeInsets.fromLTRB(
                      11, tall && padValue ? 11 : 0, 11, tall && padValue ? 11 : 0),
                  child: child,
                ),
              ),
            ],
          ),
          if (onResize != null)
            Positioned(right: 0, bottom: 0, child: _ResizeGrip(onDrag: onResize!)),
        ],
      ),
      ),
    );
    if (helperText == null || helperText!.isEmpty) return field;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        field,
        const SizedBox(height: 6),
        Text(
          helperText!,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color:
                helperIsError ? ZestTokens.statusCritical : ZestTokens.textMuted,
          ),
        ),
      ],
    );
    });
  }
}

/// A field's edge: the hairline, or the accent's ring while the keyboard is
/// in it.
BoxDecoration _fieldEdge(bool focused) => BoxDecoration(
      borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
      border: Border.all(
        color: focused ? ZestTokens.brand : ZestTokens.border,
        width: focused ? 1.5 : 0.5,
      ),
    );

/// Wraps a field and reports, via [builder], whether any descendant (the text
/// input or dropdown inside) currently holds keyboard focus. The wrapping Focus
/// is not itself a tab stop (`canRequestFocus: false`, `skipTraversal: true`),
/// it only observes so the field can draw an orange focus ring.
///
/// A press anywhere in it that nothing inside takes (its name's cell, the
/// padding around the input) puts the keyboard in its first input (4.0
/// accessibility pass: the input's own line of 16 was all a click could
/// land on in a box of 40).
class _FieldFocusRing extends StatefulWidget {
  const _FieldFocusRing({required this.builder, this.tapToFocus = false});

  final Widget Function(bool focused) builder;

  /// A press that nothing inside takes puts the keyboard in the first
  /// input. Off where the field holds a control of a caller's own (a select
  /// drawn in the field opens from a press anywhere in it, and the press
  /// must reach it).
  final bool tapToFocus;

  @override
  State<_FieldFocusRing> createState() => _FieldFocusRingState();
}

class _FieldFocusRingState extends State<_FieldFocusRing> {
  bool _focused = false;
  final _node = FocusNode(canRequestFocus: false, skipTraversal: true, debugLabel: 'zest-field');

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ring = Focus(
      focusNode: _node,
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (f) {
        if (f != _focused) setState(() => _focused = f);
      },
      child: widget.builder(_focused),
    );
    if (!widget.tapToFocus) return ring;
    return _FocusFirstInside(node: _node, child: ring);
  }
}

/// A press in [child] that nothing in it takes puts the keyboard in the
/// first input under [node] (its own, where [node] is null). An input under
/// the press takes it itself, as it is deeper.
class _FocusFirstInside extends StatefulWidget {
  const _FocusFirstInside({this.node, required this.child});

  final FocusNode? node;
  final Widget child;

  @override
  State<_FocusFirstInside> createState() => _FocusFirstInsideState();
}

class _FocusFirstInsideState extends State<_FocusFirstInside> {
  FocusNode? _own;

  FocusNode get _node => widget.node ?? (_own ??= FocusNode(canRequestFocus: false, skipTraversal: true));

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  void _focusFirst() {
    for (final n in _node.descendants) {
      if (n.canRequestFocus && !n.skipTraversal && n.context != null) {
        n.requestFocus();
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tappable = GestureDetector(
      behavior: HitTestBehavior.translucent,
      // Not a control of its own to a screen reader: the input is.
      excludeFromSemantics: true,
      onTap: _focusFirst,
      child: widget.child,
    );
    if (widget.node != null) return tappable;
    return Focus(focusNode: _node, canRequestFocus: false, skipTraversal: true, child: tappable);
  }
}

/// The 1.7 field. Adopts the "combined" look promoted from the Hosts editor: ONE
/// rounded 0.5px border encloses a RAISED label cell on the left and a SUNKEN
/// value region on the right, split by a 1px vertical divider. Replaces
/// Material's notched/floating label entirely.
///
/// ## The placeholder-vs-value contrast rule (systemic bug fix)
///
/// A [value] (or a non-empty [controller]) is the field's TEXT - bright
/// [ZestTokens.textPrimary]. A [placeholder] is only ever the empty-state HINT -
/// dim [ZestTokens.textPlaceholder]. The two route to two different visual slots
/// so a caller cannot accidentally make a value look like a placeholder.
class ZestField extends StatefulWidget {
  /// A standard text field. Builds a bare [TextField] and renders it inside the
  /// shared shell.
  const ZestField({
    super.key,
    required this.label,
    this.leadingIcon,
    this.controller,
    this.placeholder,
    this.value,
    this.helperText,
    this.errorText,
    this.isMono = false,
    this.maxLines = 1,
    this.enabled = true,
    this.obscureText = false,
    this.onChanged,
    this.onSubmit,
    this.labelWidth,
    this.focusNode,
  })  : showLabel = true,
        customChild = null,
        tall = false,
        onResize = null;

  /// A field destined for a [ZestFieldGroup]: it renders WITHOUT its own left
  /// label cell, because the group supplies one shared cell for the whole run.
  /// Inside a group it draws ONLY its bare input; used standalone it draws its
  /// own bordered, rounded, sunken box (without a label cell).
  const ZestField.grouped({
    super.key,
    required this.label,
    this.leadingIcon,
    this.controller,
    this.placeholder,
    this.value,
    this.helperText,
    this.errorText,
    this.isMono = false,
    this.maxLines = 1,
    this.enabled = true,
    this.obscureText = false,
    this.onChanged,
    this.onSubmit,
    this.labelWidth,
    this.focusNode,
  })  : showLabel = false,
        customChild = null,
        tall = false,
        onResize = null;

  /// The raw shell hosting an ARBITRARY [child] (a dropdown, a tags editor, a
  /// multi-line note, ...) in the same combined frame as a text field. This is
  /// the general form - the default constructor is just this with a built-in
  /// [TextField] child.
  const ZestField.custom({
    super.key,
    required this.label,
    required Widget child,
    this.leadingIcon,
    this.helperText,
    this.labelWidth,
    this.tall = false,
    this.onResize,
  })  : customChild = child,
        showLabel = true,
        controller = null,
        placeholder = null,
        value = null,
        errorText = null,
        isMono = false,
        maxLines = 1,
        enabled = true,
        obscureText = false,
        onChanged = null,
        onSubmit = null,
        focusNode = null;

  /// Already-localized label. Rendered in the left cell (or, for a grouped
  /// child, kept only as the accessible name - the group draws the visible cell).
  final String label;
  final IconData? leadingIcon;

  /// Caller-owned controller. When supplied it OWNS the text; [value] is ignored.
  final TextEditingController? controller;

  /// Dim empty-state hint. Never becomes the field's value.
  final String? placeholder;

  /// Bright committed text, used only when [controller] is null.
  final String? value;

  final String? helperText;

  /// When set (non-empty) replaces [helperText] and renders in
  /// [ZestTokens.statusCritical]. errorText wins.
  final String? errorText;

  /// Monospace the input for hosts / commands / keys.
  final bool isMono;

  final int maxLines;
  final bool enabled;

  /// Obscure the input (passwords). Adds a reveal/hide toggle at the trailing
  /// edge. Only valid for single-line fields.
  final bool obscureText;

  final ValueChanged<String>? onChanged;
  final VoidCallback? onSubmit;

  /// Where focus is moved to the field from outside (the Groups panel's
  /// New group puts the cursor in the name).
  final FocusNode? focusNode;

  /// Whether to draw the left label cell. False for grouped children.
  final bool showLabel;

  /// The arbitrary child for [ZestField.custom]; null for the text constructors.
  final Widget? customChild;

  /// Top-align + grow-downward (Note / Tags). Only meaningful for `.custom`.
  final bool tall;

  /// Where given, a resize grip that hands it each vertical move of a drag
  /// (Note): a grip with nothing behind it was a picture that could not be
  /// dragged. Only meaningful for `.custom`.
  final ValueChanged<double>? onResize;

  /// Override for the left label cell width. Defaults to the form's
  /// ([ZestFieldLabels]), or [_kFieldLabelWidth].
  final double? labelWidth;

  @override
  State<ZestField> createState() => _ZestFieldState();
}

class _ZestFieldState extends State<ZestField> {
  TextEditingController? _internal;
  bool _revealed = false;

  TextEditingController get _controller =>
      widget.controller ??
      (_internal ??= TextEditingController(text: widget.value ?? ''));

  @override
  void didUpdateWidget(ZestField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.controller == null &&
        widget.value != oldWidget.value &&
        widget.value != _internal?.text) {
      _internal?.text = widget.value ?? '';
    }
  }

  @override
  void dispose() {
    _internal?.dispose();
    super.dispose();
  }

  bool get _hasError =>
      widget.errorText != null && widget.errorText!.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    // A `.custom` field is just the raw shell around the caller's child.
    if (widget.customChild != null) {
      return _ZestFieldShell(
        label: widget.label,
        leadingIcon: widget.leadingIcon,
        labelWidth: widget.labelWidth ?? _labelWidthOf(context),
        tall: widget.tall,
        onResize: widget.onResize,
        helperText: widget.helperText,
        child: widget.customChild!,
      );
    }

    // A grouped child living INSIDE a [ZestFieldGroup] renders only its bare
    // input; the group owns the outer border, the label cell and the dividers.
    if (!widget.showLabel && _ZestFieldGroupScope.of(context)) {
      return _bareInput();
    }

    final bool multiline = widget.maxLines > 1;

    // Standalone grouped field (no scope): a self-bordered box without a label
    // cell.
    if (!widget.showLabel) {
      return _FocusFirstInside(
        child: Container(
          constraints: const BoxConstraints(minHeight: _kFieldMinHeight),
          decoration: BoxDecoration(
            color: _kWell,
            borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
          ),
          foregroundDecoration: _fieldEdge(false),
          clipBehavior: Clip.antiAlias,
          alignment: Alignment.centerLeft,
          // The input pads itself top and bottom (its target fills the box).
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: _bareInput(),
        ),
      );
    }

    // Standard labelled text field: the built-in bare input inside the shell.
    return _ZestFieldShell(
      label: widget.label,
      leadingIcon: widget.leadingIcon,
      labelWidth: widget.labelWidth ?? _labelWidthOf(context),
      tall: multiline,
      helperText: _hasError ? widget.errorText : widget.helperText,
      helperIsError: _hasError,
      labelSaid: false,
      padValue: false,
      child: _bareInput(),
    );
  }

  /// The raw input content: the [TextField] (plus the reveal toggle for
  /// [ZestField.obscureText]). Carries NO border/radius/padding - the enclosing
  /// shell or group segment draws those.
  Widget _bareInput() {
    final textColor =
        widget.enabled ? ZestTokens.textPrimary : ZestTokens.textTertiary;
    final textStyle = widget.isMono
        ? _kValueMonoStyle.copyWith(color: textColor, letterSpacing: 0.4)
        : _kValueStyle.copyWith(color: textColor);

    // The input's own target fills its box: 40 high with a mouse, a
    // finger's 48 where the app is touch sized (its line of 16 was all a
    // press could land on, and all a screen reader's finger found: 4.0
    // accessibility pass). The box grows with it, never the other way.
    final least = touchSizedAt(context) ? 48.0 : _kFieldMinHeight;
    final oneLine = widget.obscureText || widget.maxLines == 1;
    final field = Semantics(
      // Said by the field's name ("Host, edit box"): the cell beside it is
      // tied to nothing, and a grouped field's name was said nowhere.
      label: widget.label,
      child: TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        enabled: widget.enabled,
        obscureText: widget.obscureText && !_revealed,
        maxLines: widget.obscureText ? 1 : widget.maxLines,
        minLines: 1,
        style: textStyle,
        cursorColor: ZestTokens.brand,
        cursorWidth: 1.5,
        onChanged: widget.onChanged,
        onSubmitted: widget.onSubmit == null ? null : (_) => widget.onSubmit!(),
        // One line in the middle of its box; several from its top, 11 in,
        // as the box padded them before.
        textAlignVertical: oneLine ? TextAlignVertical.center : TextAlignVertical.top,
        decoration: zestShellFieldDecoration(hintText: widget.placeholder).copyWith(
          isCollapsed: false,
          contentPadding: const EdgeInsets.symmetric(vertical: 11),
          constraints: BoxConstraints(minHeight: least),
        ),
      ),
    );

    if (!widget.obscureText) return field;
    final l10n = AppLocalizations.of(context)!;
    return Row(
      children: [
        Expanded(child: field),
        // Pressed anywhere in a mouse's 32 (a finger's 48) around its 16,
        // said as Show or Hide (it was its 16 alone, said by its tooltip
        // only). Out of Tab's way, as the dialogs' own is.
        Tooltip(
          message: _revealed ? l10n.zestDialogHide : l10n.zestDialogShow,
          excludeFromSemantics: true,
          child: ExcludeFocus(
            child: ZestPressable(
              onTap: () async {
                // Revealing a secret while recording mode is on: spec 5.
                if (!_revealed && !await confirmRevealWhileRecording(context)) {
                  return;
                }
                if (!mounted) return;
                setState(() => _revealed = !_revealed);
              },
              semanticLabel: _revealed ? l10n.zestDialogHide : l10n.zestDialogShow,
              excludeChildSemantics: true,
              child: Icon(
                _revealed ? LucideIcons.eyeOff : LucideIcons.eye,
                size: 16,
                color: ZestTokens.textTertiary,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A run of inputs that SHARE one left label cell - e.g. Address + Port laid out
/// in one row under a single "Address" label - rendered as ONE bordered control:
/// `[raised label cell | input | divider | input | ...]`, split by 1px dividers.
/// This is what turns Address+Port (or the Port Forwarding Source/Destination
/// Host+Port pairs) into a single combined field.
///
/// Each entry in [fields] is a segment. A plain widget (or a
/// [ZestField.grouped]) fills the remaining space (Expanded); wrap a segment in
/// a `SizedBox(width: X, child: ...)` to pin it to a fixed width (the narrow
/// port cell). The child of a fixed segment is unwrapped so it renders bare.
class ZestFieldGroup extends StatelessWidget {
  const ZestFieldGroup({
    super.key,
    required this.label,
    required this.fields,
    this.leadingIcon,
    this.gap = 8,
    this.labelWidth,
  });

  /// Already-localized shared label for the whole run.
  final String label;
  final IconData? leadingIcon;
  final List<Widget> fields;

  /// Retained for API compatibility. In the combined look the children are
  /// separated by the single-pixel internal divider rather than empty space, so
  /// this no longer inserts a gap.
  final double gap;

  /// Override for the shared left label-cell width. Defaults to the form's
  /// ([ZestFieldLabels]), or [_kFieldLabelWidth]; a form with wider labels
  /// (e.g. Port Forwarding) passes its own width so a group's label cell
  /// aligns with the standalone [ZestField]s in the same column.
  final double? labelWidth;

  /// Pull the shared helper/error subtext out of any [ZestField] children (raw
  /// widgets such as a validating [TextFormField] carry their own subtext via
  /// the field decoration instead, so they contribute nothing here).
  ({String? message, bool hasError}) _sharedState() {
    String? error;
    String? helper;
    for (final w in fields) {
      Widget field = w;
      if (field is Flexible) field = field.child;
      if (field is SizedBox && field.child != null) field = field.child!;
      if (field is ZestField) {
        final e = field.errorText;
        if (e != null && e.isNotEmpty) error ??= e;
        final h = field.helperText;
        if (h != null && h.isNotEmpty) helper ??= h;
      }
    }
    return (message: error ?? helper, hasError: error != null);
  }

  /// The [content] Row over its [bg] (cell fill + dividers), the two of the
  /// same widths.
  Widget _segments(List<Widget> bg, List<Widget> content) => Stack(
        alignment: Alignment.centerLeft,
        children: [
          Positioned.fill(child: Row(children: bg)),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: content),
        ],
      );

  /// A segment's fixed width (null = expanded) and its bare child.
  (double?, Widget) _segment(Widget field) {
    if (field is SizedBox && field.width != null) {
      return (field.width, field.child ?? const SizedBox.shrink());
    }
    if (field is Flexible) return (null, field.child);
    return (null, field);
  }

  @override
  Widget build(BuildContext context) {
    final labelWidth = this.labelWidth ?? _labelWidthOf(context);
    // The background Row (cell fill + dividers) and the content Row use the
    // IDENTICAL widths / flex so the dividers line up exactly behind the gaps.
    final bg = <Widget>[];
    final content = <Widget>[];
    for (var i = 0; i < fields.length; i++) {
      if (i > 0) {
        bg.add(Container(width: 1, color: ZestTokens.border));
        content.add(const SizedBox(width: 1));
      }
      final (width, child) = _segment(fields[i]);
      // A press in a segment's padding puts the keyboard in its input.
      final padded = _FocusFirstInside(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11),
          child: child,
        ),
      );
      if (width == null) {
        bg.add(const Expanded(child: SizedBox()));
        content.add(Expanded(child: padded));
      } else {
        bg.add(SizedBox(width: width));
        content.add(SizedBox(width: width, child: padded));
      }
    }

    // Ringed in the accent while one of its inputs has the keyboard, as a
    // field is (a group showed nothing); a press on its name puts the
    // keyboard in its first input.
    final container = _FieldFocusRing(tapToFocus: true, builder: (focused) => _ZestFieldGroupScope(
      child: Container(
        constraints: const BoxConstraints(minHeight: _kFieldMinHeight),
        decoration: BoxDecoration(
          color: _kWell,
          borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        ),
        foregroundDecoration: _fieldEdge(focused),
        clipBehavior: Clip.antiAlias,
        child: _BesideOrAbove(
          label: label,
          leadingIcon: leadingIcon,
          labelWidth: labelWidth,
          value: _segments(bg, content),
          beside: _segments([
            Container(width: labelWidth, color: _kLabelCell),
            Container(width: 1, color: ZestTokens.border),
            ...bg,
          ], [
            _fieldLabelCell(
              label,
              width: labelWidth,
              top: false,
              leadingIcon: leadingIcon,
            ),
            const SizedBox(width: 1),
            ...content,
          ]),
        ),
      ),
    ));

    final shared = _sharedState();
    final message = shared.message;
    if (message == null) return container;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        container,
        const SizedBox(height: 6),
        Text(
          message,
          style: TextStyle(
            fontSize: 12,
            height: 1.4,
            color: shared.hasError
                ? ZestTokens.statusCritical
                : ZestTokens.textMuted,
          ),
        ),
      ],
    );
  }
}

/// Marker a [ZestFieldGroup] plants above its children so a [ZestField.grouped]
/// knows to render only its raw input (the group draws the shared chrome). A
/// standalone `.grouped` field finds no marker and stays self-bordered.
class _ZestFieldGroupScope extends InheritedWidget {
  const _ZestFieldGroupScope({required super.child});

  static bool of(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_ZestFieldGroupScope>() != null;

  @override
  bool updateShouldNotify(_ZestFieldGroupScope oldWidget) => false;
}

/// The subtle resize grip painted in a field's bottom-right corner (Note): a
/// drag on it, up or down, hands [onDrag] each move. Its glyph is 10px, in a
/// 16px corner a pointer can take hold of.
class _ResizeGrip extends StatelessWidget {
  const _ResizeGrip({required this.onDrag});

  final ValueChanged<double> onDrag;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpDown,
      child: GestureDetector(
        key: const ValueKey('zest-field-grip'),
        behavior: HitTestBehavior.opaque,
        // From where the pointer went down, so the box follows it exactly.
        dragStartBehavior: DragStartBehavior.down,
        onVerticalDragUpdate: (d) => onDrag(d.delta.dy),
        child: const Padding(
          padding: EdgeInsets.all(3),
          child: SizedBox(
            width: 10,
            height: 10,
            child: CustomPaint(painter: _ResizeGripPainter()),
          ),
        ),
      ),
    );
  }
}

class _ResizeGripPainter extends CustomPainter {
  const _ResizeGripPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = ZestTokens.borderStrong
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    final w = size.width;
    final h = size.height;
    canvas.drawLine(Offset(w, h * 0.42), Offset(w * 0.42, h), paint);
    canvas.drawLine(Offset(w, h * 0.72), Offset(w * 0.72, h), paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
