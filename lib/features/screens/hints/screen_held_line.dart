// Remote screens (4.0): the line over the picture while the
// pointer is held for the remote (relative mouse). It is the one thing that
// says how to get out, so it stays for as long as the pointer is held (no
// time of its own, no fading out), sits at the picture's top centre above
// everything of the remote's, never takes the pointer or the keyboard, and is
// said to a screen reader once as it shows. The key that lets go is drawn as
// a keycap inside the sentence.
import 'package:flutter/material.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;

class ScreenHeldLine extends StatefulWidget {
  const ScreenHeldLine({super.key, required this.text, required this.keyLabel});

  /// The whole sentence, with [keyLabel] in it ("Pointer held for the
  /// remote. Press F8 to get it back.").
  final String text;

  /// The key's name as it stands in [text], drawn as a keycap.
  final String keyLabel;

  @override
  State<ScreenHeldLine> createState() => _ScreenHeldLineState();
}

class _ScreenHeldLineState extends State<ScreenHeldLine> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) zestAnnounce(context, widget.text);
    });
  }

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: ZestColors.textPrimary, fontSize: 13, height: 1.4);
    final at = widget.keyLabel.isEmpty ? -1 : widget.text.indexOf(widget.keyLabel);
    final keycap = WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 3),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: ZestColors.surfaceChip,
          borderRadius: BorderRadius.circular(5),
          border: Border(
            top: BorderSide(color: ZestColors.borderDefault),
            left: BorderSide(color: ZestColors.borderDefault),
            right: BorderSide(color: ZestColors.borderDefault),
            bottom: BorderSide(color: ZestColors.borderDefault, width: 2),
          ),
        ),
        child: Text(
          widget.keyLabel,
          style: style.copyWith(fontWeight: FontWeight.w600, fontSize: 12, fontFamily: 'JetBrainsMono'),
        ),
      ),
    );
    final spans = at < 0
        ? <InlineSpan>[TextSpan(text: widget.text)]
        : <InlineSpan>[
            TextSpan(text: widget.text.substring(0, at)),
            keycap,
            TextSpan(text: widget.text.substring(at + widget.keyLabel.length)),
          ];
    return IgnorePointer(
      child: ExcludeFocus(
        child: Align(
          alignment: Alignment.topCenter,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Semantics(
              liveRegion: true,
              label: widget.text,
              excludeSemantics: true,
              child: Container(
                key: const ValueKey('screen-held-line'),
                constraints: const BoxConstraints(maxWidth: 520),
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: ZestColors.chromeElevated.withValues(alpha: 0.94),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: ZestColors.borderDefault),
                  boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 4))],
                ),
                child: Text.rich(TextSpan(style: style, children: spans), textAlign: TextAlign.center),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
