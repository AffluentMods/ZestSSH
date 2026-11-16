import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

/// [text] as it fits in [maxWidth] on one line with [style]: whole, or with
/// letters from its middle taken out for an ellipsis, so that both ends
/// still read ("Personal \u00b7 reallylonggr\u2026pname"; for
/// a long team or group name on a tab).
String middleEllipsis(String text, TextStyle style, double maxWidth,
    {TextDirection direction = TextDirection.ltr, TextScaler textScaler = TextScaler.noScaling}) {
  double widthOf(String s) {
    final p = TextPainter(text: TextSpan(text: s, style: style), textDirection: direction, textScaler: textScaler, maxLines: 1)
      ..layout();
    final w = p.width;
    p.dispose();
    return w;
  }

  if (widthOf(text) <= maxWidth) return text;
  final chars = text.characters.toList();
  String cut(int keep) {
    final front = (keep + 1) ~/ 2;
    final back = keep - front;
    return '${chars.take(front).join().trimRight()}\u2026${chars.skip(chars.length - back).join().trimLeft()}';
  }

  // The most letters kept that still fit.
  var lo = 0, hi = chars.length - 1;
  while (lo < hi) {
    final mid = (lo + hi + 1) ~/ 2;
    if (widthOf(cut(mid)) <= maxWidth) {
      lo = mid;
    } else {
      hi = mid - 1;
    }
  }
  return cut(lo);
}

/// [value] on one line in the width it is given, cut in the middle where it
/// does not fit; redacted as [RedactedText] is while recording.
class MiddleEllipsisText extends ConsumerWidget {
  const MiddleEllipsisText(this.value, {super.key, required this.style});

  final Redactable value;
  final TextStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = value.displayIn(ref);
    final merged = DefaultTextStyle.of(context).style.merge(style);
    return LayoutBuilder(
      builder: (context, box) => Text(
        box.maxWidth.isFinite
            ? middleEllipsis(shown, merged, box.maxWidth,
                direction: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))
            : shown,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
        style: style,
      ),
    );
  }
}
