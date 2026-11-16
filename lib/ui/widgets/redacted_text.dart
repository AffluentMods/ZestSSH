import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// A [Text] that renders a [Redactable]'s display form and rebuilds when
/// recording mode toggles.
///
/// This is the one primitive a screen needs to show an identifying value:
/// hand it the model's [Redactable] and it does the right thing in both
/// modes, with no per-widget `recording ? Redactor.x : y` branch to forget.
/// The source gate (`test/redaction/no_raw_in_ui_test.dart`) keeps `.raw`
/// out of the UI layer; this widget is how `.display` gets on screen.
class RedactedText extends ConsumerWidget {
  const RedactedText(
    this.value, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
    this.textAlign,
    this.softWrap,
    this.semanticsLabel,
  });

  final Redactable value;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;
  final TextAlign? textAlign;
  final bool? softWrap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watched only so the widget rebuilds on a toggle or a level change; the
    // value itself comes from the Redactor singleton the providers keep in
    // sync.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    return Text(
      value.display,
      style: style,
      maxLines: maxLines,
      overflow: overflow,
      textAlign: textAlign,
      softWrap: softWrap,
      semanticsLabel: semanticsLabel,
    );
  }
}

/// The display string for a [Redactable] inside a widget that already
/// watches [recordingModeProvider] (or does not need to rebuild on toggle),
/// for places that compose strings rather than render a [Text] directly.
extension RedactableDisplay on Redactable {
  String displayIn(WidgetRef ref) {
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    return display;
  }
}
