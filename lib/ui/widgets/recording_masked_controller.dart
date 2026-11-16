import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// The controller of a field a person writes free text in, for a form that can
/// stand on screen while it is recorded: what is in it is drawn as bullets, one
/// for each character, so a draft brought back and an address being typed stay
/// out of the picture and the cursor stays where it is. What it holds, and what
/// is sent, is what was typed.
class RecordingMaskedController extends TextEditingController {
  /// Drawn as bullets ([RecordingMaskedFields.maskWhileRecording]).
  bool masked = false;

  @override
  TextSpan buildTextSpan({required BuildContext context, TextStyle? style, required bool withComposing}) {
    if (!masked) return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    return TextSpan(style: style, text: text.replaceAll(RegExp(r'[^\n]'), '•'));
  }
}

/// For the build of what holds the fields.
extension RecordingMaskedFields on WidgetRef {
  /// [fields] follow recording mode.
  void maskWhileRecording(Iterable<RecordingMaskedController> fields) {
    final recording = watch(recordingModeProvider);
    for (final field in fields) {
      field.masked = recording;
    }
  }
}
