import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// A name and its address on one line, the name first: the name takes the
/// room it needs (all of it if need be, and then it is cut short), the
/// address what is left, and the address is left out when what is left is
/// too little to read ([minAddress]).
///
/// For a pane's own header, where a host's name has to stay readable however
/// narrow the pane (a tab of sixteen terminals stands in a grid of four by
/// four): the two used to share the room as two halves, which cut both, so
/// that neither said which host it was.
class NameFirstRow extends ConsumerWidget {
  const NameFirstRow({
    super.key,
    required this.name,
    required this.nameStyle,
    this.address,
    this.addressStyle,
    this.gap = 8,
    this.minAddress = 48,
  });

  final Redactable name;
  final TextStyle nameStyle;
  final Redactable? address;
  final TextStyle? addressStyle;

  /// Room between the name and the address.
  final double gap;

  /// The least room an address is shown in.
  final double minAddress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Masked while a screen is recorded: rebuilt when that changes.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final shownName = name.display;
    final nameText = Text(
      shownName,
      style: nameStyle,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
    final shownAddress = address?.display ?? '';
    if (shownAddress.isEmpty) return nameText;
    final addressText = Text(
      shownAddress,
      style: addressStyle,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
    );
    return LayoutBuilder(builder: (context, constraints) {
      // (Where there is no end to the room, the address is not cut, and both
      // are whole.)
      final painter = TextPainter(
        text: TextSpan(text: shownName, style: DefaultTextStyle.of(context).style.merge(nameStyle)),
        maxLines: 1,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout();
      final left = constraints.maxWidth - painter.width - gap;
      painter.dispose();
      if (left < minAddress) return nameText;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [nameText, SizedBox(width: gap), Flexible(child: addressText)],
      );
    });
  }
}
