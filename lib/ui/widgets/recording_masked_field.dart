import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';

/// The display form of an endpoint URL (a Prometheus base URL, a WebDAV
/// server, an S3 endpoint, a sync server, a webhook). Only the host part
/// identifies anything, so the scheme, port and path survive and the host goes
/// through the address rule. A bare `host` / `host:port` (no scheme) is masked
/// as an address. Returns [raw] untouched while recording mode is off.
String maskEndpointUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return raw;
  if (!value.contains('://')) return Redactable.address(value).display;
  final uri = Uri.tryParse(value);
  if (uri == null || uri.host.isEmpty) return Redactable.freeText(value).display;
  final host = Redactable.address(uri.host).display;
  if (host == uri.host) return raw;
  // Credentials in the URL (`https://alice:s3cret@dav.example.com/x`) are
  // as identifying as the host: they go too while the mode is on.
  return uri.replace(host: host, userInfo: '').toString();
}

/// A Material text field that holds an identifier (an endpoint URL, a
/// forwarding rule's remote host, a network's gateway address) must not show
/// the real value while recording mode is on. This renders [child] (the real,
/// editable field) normally and, while recording, a read-only field in the
/// same [decoration] that paints `mask(controller.text)` instead. Tapping the
/// masked field runs the reveal gate, which only proceeds by turning recording
/// mode off; the underlying [controller] is never edited here.
///
/// [validate] runs against the REAL value when the enclosing [Form] validates,
/// so a required field stays required while it is masked.
class RecordingMaskedFormField extends ConsumerWidget {
  const RecordingMaskedFormField({
    super.key,
    required this.controller,
    required this.mask,
    required this.decoration,
    required this.child,
    this.style,
    this.validate,
  });

  final TextEditingController controller;

  /// The masked display for the raw text, e.g.
  /// `(v) => Redactable.address(v).display` or [maskEndpointUrl].
  final String Function(String raw) mask;
  final InputDecoration decoration;

  /// The real field, shown while recording mode is off.
  final Widget child;
  final TextStyle? style;
  final String? Function()? validate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recording = ref.watch(recordingModeProvider);
    // Watched so a level change re-masks without a toggle.
    ref.watch(recordingRedactLevelProvider);
    if (!recording) return child;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final shown = mask(controller.text);
        return TextFormField(
          // A new field state whenever the shown value changes, so the
          // read-only initial value tracks the real controller.
          key: ValueKey<String>('recording-mask:$shown'),
          initialValue: shown,
          readOnly: true,
          showCursor: false,
          enableInteractiveSelection: false,
          mouseCursor: SystemMouseCursors.click,
          style: style,
          decoration: decoration,
          onTap: () => confirmRevealWhileRecording(context, ref),
          validator: validate == null ? null : (_) => validate!(),
        );
      },
    );
  }
}

/// The masked, read-only stand-in for a `ZestField` value region (or one
/// segment of a `ZestFieldGroup`) that holds an identifier, for the recording
/// mode branch of a desktop form. Paints `mask(controller.text)` in the field's
/// value style; a tap runs the reveal gate. The caller decides when to show it
/// (it watches `recordingModeProvider`) and never hands it a secret.
class RecordingMaskedValue extends ConsumerWidget {
  const RecordingMaskedValue({
    super.key,
    required this.controller,
    required this.mask,
    this.isMono = false,
    this.placeholder,
  });

  final TextEditingController controller;
  final String Function(String raw) mask;
  final bool isMono;

  /// Dim text shown when the real value is empty.
  final String? placeholder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final shown = mask(controller.text);
        final empty = shown.trim().isEmpty;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => confirmRevealWhileRecording(context, ref),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                empty ? (placeholder ?? '') : shown,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.25,
                  fontFamily: isMono ? 'JetBrainsMono' : null,
                  letterSpacing: isMono ? 0.4 : null,
                  color: empty
                      ? ZestTokens.textPlaceholder
                      : ZestTokens.textPrimary,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
