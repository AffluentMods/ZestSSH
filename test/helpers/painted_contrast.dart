import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A text, an icon or a spinner on screen as a person sees it: its colour
/// and the colour painted behind it, both as they end up after what is
/// see-through above them is laid over what is below.
class PaintedText {
  PaintedText({required this.text, required this.ink, required this.ground, required this.groundBy});

  /// The words, "icon U+E5CD" for an icon, or "spinner".
  final String text;
  final Color ink;
  final Color ground;

  /// The kind of widget that painted the ground ("PhysicalShape", "ColoredBox", ...).
  final String groundBy;

  /// The contrast of [ink] on [ground], as WCAG works it out (1 to 21).
  double get ratio {
    final a = ink.computeLuminance() + 0.05;
    final b = ground.computeLuminance() + 0.05;
    return a > b ? a / b : b / a;
  }

  @override
  String toString() =>
      '"$text": ${_hex(ink)} on ${_hex(ground)} ($groundBy), ${ratio.toStringAsFixed(2)}:1';
}

String _hex(Color c) => '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// The colour a widget paints behind what it holds, where it paints one.
Color? _groundOf(Widget w) {
  if (w is ColoredBox) return w.color;
  if (w is PhysicalShape) return w.color;
  if (w is PhysicalModel) return w.color;
  if (w is DecoratedBox) {
    final d = w.decoration;
    if (d is BoxDecoration) return d.color ?? _mean(d.gradient);
    if (d is ShapeDecoration) return d.color ?? _mean(d.gradient);
  }
  if (w is Ink) {
    final d = w.decoration;
    if (d is BoxDecoration) return d.color ?? _mean(d.gradient);
  }
  // A filled field paints its fill itself, behind what is typed and its hint.
  if (w is InputDecorator && (w.decoration.filled ?? false)) return w.decoration.fillColor;
  return null;
}

/// A gradient read as its colours' mean (a ground of colours that differ is
/// not one colour; the mean is near enough to tell white on white).
Color? _mean(Gradient? g) {
  if (g == null || g.colors.isEmpty) return null;
  double a = 0, r = 0, gr = 0, b = 0;
  for (final c in g.colors) {
    a += c.a;
    r += c.r;
    gr += c.g;
    b += c.b;
  }
  final n = g.colors.length;
  return Color.from(alpha: a / n, red: r / n, green: gr / n, blue: b / n);
}

/// What is painted behind [element]: the nearest widget above it that paints
/// a ground that is not see-through, with each see-through one between laid
/// over it; and how much a widget between fades what [element] draws
/// (Opacity, FadeTransition).
({Color ground, double fade, String by}) _behind(Element element, Color fallbackGround) {
  var fade = 1.0;
  final layers = <Color>[];
  String? by;
  element.visitAncestorElements((a) {
    final w = a.widget;
    if (w is Opacity) fade *= w.opacity;
    if (w is FadeTransition) fade *= w.opacity.value;
    final g = _groundOf(w);
    if (g != null && g.a > 0) {
      layers.add(g);
      if (g.a >= 0.99) {
        by = w.runtimeType.toString();
        return false;
      }
    }
    return true;
  });
  var ground = layers.isNotEmpty && layers.last.a >= 0.99 ? layers.removeLast() : fallbackGround;
  for (final layer in layers.reversed) {
    ground = Color.alphaBlend(layer, ground);
  }
  return (ground: ground, fade: fade, by: by ?? 'the page');
}

/// The colour of the text of [span] where it has text of its own, with the
/// colour of the span around it where it names none; and the colour a span
/// paints behind its own words (a match marked in a line), where it does.
void _spans(InlineSpan span, Color? inherited, void Function(String text, Color color, Color? marked) found,
    [Color? inheritedMark]) {
  if (span is! TextSpan) return;
  final color = span.style?.color ?? inherited;
  final mark = span.style?.backgroundColor ?? inheritedMark;
  final text = span.text;
  if (text != null && text.trim().isNotEmpty) found(text, color ?? const Color(0xFF000000), mark);
  for (final child in span.children ?? const <InlineSpan>[]) {
    _spans(child, color, found, mark);
  }
}

/// Every text, icon and spinner on screen (offstage ones left out), with what
/// is painted behind it, and its own colour laid over that.
List<PaintedText> paintedTexts(WidgetTester tester, {required Color fallbackGround}) {
  final out = <PaintedText>[];
  for (final element in find.byType(RichText).evaluate()) {
    final rich = element.widget as RichText;
    final behind = _behind(element, fallbackGround);
    // An icon is a text of one glyph in its font.
    final icon = element.findAncestorWidgetOfExactType<Icon>();
    _spans(rich.text, null, (text, color, marked) {
      if (color.a == 0 || behind.fade == 0) return;
      final ground = marked == null ? behind.ground : Color.alphaBlend(marked, behind.ground);
      final ink = Color.alphaBlend(color.withValues(alpha: color.a * behind.fade), ground);
      final shown = icon != null && text.runes.length == 1
          ? 'icon U+${text.runes.first.toRadixString(16).toUpperCase()}'
          : (text.length > 60 ? '${text.substring(0, 60)}...' : text);
      out.add(PaintedText(text: shown, ink: ink, ground: ground, groundBy: marked == null ? behind.by : 'its mark'));
    });
  }
  // What is typed in a field is drawn by the field, not as a text of its own.
  for (final element in find.byType(EditableText).evaluate()) {
    final field = element.widget as EditableText;
    final typed = field.controller.text;
    final color = field.style.color;
    if (typed.trim().isEmpty || color == null) continue;
    final behind = _behind(element, fallbackGround);
    if (color.a == 0 || behind.fade == 0) continue;
    final ink = Color.alphaBlend(color.withValues(alpha: color.a * behind.fade), behind.ground);
    final shown = field.obscureText ? 'typed (hidden)' : (typed.length > 60 ? '${typed.substring(0, 60)}...' : typed);
    out.add(PaintedText(text: shown, ink: ink, ground: behind.ground, groundBy: behind.by));
  }
  for (final element in find.byType(CircularProgressIndicator).evaluate()) {
    final spinner = element.widget as CircularProgressIndicator;
    final theme = Theme.of(element);
    final color = spinner.color ??
        spinner.valueColor?.value ??
        theme.progressIndicatorTheme.color ??
        theme.colorScheme.primary;
    final behind = _behind(element, fallbackGround);
    if (color.a == 0 || behind.fade == 0) continue;
    final ink = Color.alphaBlend(color.withValues(alpha: color.a * behind.fade), behind.ground);
    out.add(PaintedText(text: 'spinner', ink: ink, ground: behind.ground, groundBy: behind.by));
  }
  return out;
}

/// The texts, icons and spinners on screen that read at less than [min] to 1
/// on what is painted behind them.
List<PaintedText> hardToRead(WidgetTester tester, {required Color fallbackGround, double min = 2.0}) =>
    [for (final t in paintedTexts(tester, fallbackGround: fallbackGround)) if (t.ratio < min) t];
