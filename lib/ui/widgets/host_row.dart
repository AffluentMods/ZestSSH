import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart' show Connection, ConnectionGroup;
import 'package:zestssh/features/hosts/host_card_face.dart' show osCatalogIdFor;
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/os_detection_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/match_marks.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/host_address.dart';

// One row for a host, wherever hosts are listed.
// The identity's USED BY list had it
// right: the host's own icon in its tile, its name, user@address. A generic
// server glyph, or a list's own idea of a row, said less and looked like
// another app. test/ui/host_row_guard_test.dart keeps new lists on this row.

/// A host's own icon in its tile: the one picked or uploaded for it, else the
/// system seen on it, in the colour chosen for it. The same drawing as on its
/// card.
class HostGlyph extends ConsumerWidget {
  const HostGlyph({super.key, required this.host, this.group, this.size = 22, this.cornerRadius});

  final Connection host;

  /// The host's group, for a colour that follows its label; looked up where
  /// not given.
  final ConnectionGroup? group;
  final double size;

  /// Its corners: a quarter of its size where not given.
  final double? cornerRadius;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seen = ref.watch(detectedOsProvider(host.id));
    final inGroup = group ?? ref.watch(hostsByIdProvider)[host.id]?.group;
    return HostIcon(
      iconId: host.iconId,
      customIcon: host.customIcon,
      osId: seen == null ? null : osCatalogIdFor(seen),
      iconColor: host.iconColor,
      labelColor: AppColors.resolveConnectionLabelColorOrNull(
        connColorValue: host.colorValue,
        connColorIndex: host.colorIndex,
        inheritedGroupColor: inGroup == null
            ? null
            : resolveGroupColor(colorValue: inGroup.colorValue, colorIndex: inGroup.colorIndex, name: inGroup.name),
      ),
      size: size,
      cornerRadius: cornerRadius ?? size / 4,
    );
  }
}

/// The small green dot of a host with a session open (amber while it is on
/// its way, [connecting]). With a [label], the word beside it; a dot alone
/// says it in its tooltip.
class HostOpenDot extends StatelessWidget {
  const HostOpenDot({super.key, this.label, this.connecting = false, this.showLabel = false});

  final String? label;
  final bool connecting;

  /// The word beside the dot, not only over it.
  final bool showLabel;

  @override
  Widget build(BuildContext context) {
    final color = connecting ? ZestTokens.statusWarning : ZestTokens.statusHealthy;
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color.withValues(alpha: 0.45), blurRadius: 4, spreadRadius: 0.5)],
      ),
    );
    final said = label;
    if (said == null) return dot;
    if (showLabel) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          dot,
          const SizedBox(width: 5),
          Text(said, maxLines: 1, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w500, color: color)),
        ],
      );
    }
    return Tooltip(message: said, child: dot);
  }
}

/// A host's name as its row shows it: its label, or its address where it has
/// none, each masked by its own rule while a screen is recorded.
String hostRowName(Connection host, WidgetRef ref) =>
    (host.label.isNotEmpty ? Redactable.host(host.label) : Redactable.address(host.host)).displayIn(ref);

/// user@address as a host's row shows it, the port where it is not 22, masked
/// while a screen is recorded. [user] null or empty: the address alone.
String hostRowEndpoint(Connection host, String? user, WidgetRef ref) {
  final address = Redactable.address(host.host).displayIn(ref);
  final at = host.port == 22 ? address : hostWithPort(address, host.port);
  final who = user == null || user.isEmpty ? null : Redactable.username(user).displayIn(ref);
  return who == null ? at : '$who@$at';
}

/// A host in a list: [HostGlyph], its name, and user@address (the port where
/// it is not 22), with the dot of an open session. Hosts' names and addresses
/// are masked while a screen is recorded.
///
/// By default the address stands to the right of the name, and is left out
/// where the row is too narrow for it; [under] sets it under the name, for a
/// narrow pane. [showAddress] false leaves it out (the sidebar, as narrow as
/// it is, has the name alone). A row made with an [unavailableReason] (a host
/// that is SFTP only, for what runs on a host) is dimmed, says why, and does
/// nothing when tapped. A [highlight] (what was typed in a search) is marked
/// where the name and the address hold it ([matchesIn]).
class HostRow extends ConsumerStatefulWidget {
  const HostRow({
    super.key,
    required this.host,
    this.user,
    this.group,
    this.onTap,
    this.onDoubleTap,
    this.onSecondaryTapDown,
    this.leading,
    this.trailing,
    this.open = false,
    this.connecting = false,
    this.openLabel,
    this.showOpenLabel = false,
    this.highlight,
    this.selected = false,
    this.unavailableReason,
    this.unavailableKey,
    this.under = false,
    this.showAddress = true,
    this.iconSize = 22,
    this.nameStyle,
    this.padding = const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
    this.margin = const EdgeInsets.only(bottom: 2),
    this.hovers = true,
  });

  final Connection host;

  /// Who signs in, for user@address: the identity's where not given.
  final String? user;

  /// The host's group, for a colour that follows its label; looked up where
  /// not given.
  final ConnectionGroup? group;
  final VoidCallback? onTap;
  final VoidCallback? onDoubleTap;
  final GestureTapDownCallback? onSecondaryTapDown;

  /// What stands before the icon (a list that ticks hosts: its box).
  final Widget? leading;

  /// What stands at the row's end (a count, a chevron, a button).
  final Widget? trailing;

  /// The host has a session open, or on its way ([connecting]): the dot.
  final bool open;
  final bool connecting;

  /// What the dot says, in its tooltip; beside it with [showOpenLabel].
  final String? openLabel;
  final bool showOpenLabel;

  /// What was typed in a search, marked where the name and the address hold
  /// it. Null: nothing marked.
  final String? highlight;

  /// The row is the one chosen (its panel open beside the list).
  final bool selected;

  /// Why the host cannot be picked here, under its name. Null where it can.
  final String? unavailableReason;
  final Key? unavailableKey;

  /// The address under the name, not beside it.
  final bool under;
  final bool showAddress;
  final double iconSize;

  /// The name's style, for a list that says more with it.
  final TextStyle? nameStyle;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin;

  /// The row lights up under the mouse: off where what holds it does that.
  final bool hovers;

  @override
  ConsumerState<HostRow> createState() => _HostRowState();
}

class _HostRowState extends ConsumerState<HostRow> {
  bool _hover = false;

  /// The least room an address is shown in, beside the name.
  static const double _minAddress = 56;

  @override
  Widget build(BuildContext context) {
    final c = widget.host;
    final unavailable = widget.unavailableReason;
    final canTap = unavailable == null && widget.onTap != null;
    final details = ref.watch(hostsByIdProvider)[c.id];
    final user = widget.user ?? details?.identity?.username;
    // Recording mode: the address and the user masked, the host's name by its
    // own rule (a host with no name goes by its address, and its rule).
    final name = hostRowName(c, ref);
    final endpoint = hostRowEndpoint(c, user, ref);
    final nameStyle = widget.nameStyle ?? TextStyle(fontSize: 13, color: ZestTokens.textPrimary);
    final addressStyle = TextStyle(fontSize: 11.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary);
    // What was typed, where the words shown hold it (masked words are
    // matched as they are shown, so a mask gives nothing away).
    final highlight = widget.highlight;
    final marks = highlight == null || highlight.trim().isEmpty
        ? null
        : matchesIn([(text: name, fuzzy: true), (text: endpoint, fuzzy: true)], highlight);
    final nameSpan = marks == null ? TextSpan(text: name) : markedText(name, marks[0]);
    final dot = widget.open || widget.connecting
        ? HostOpenDot(
            key: ValueKey('host-open-${c.id}'),
            label: widget.openLabel,
            connecting: widget.connecting,
            showLabel: widget.showOpenLabel,
          )
        : null;
    final nameText = marks == null
        ? Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: nameStyle)
        : Text.rich(nameSpan, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: nameStyle);
    final addressText = marks == null
        ? Text(endpoint, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: addressStyle)
        : Text.rich(markedText(endpoint, marks[1]),
            maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: addressStyle);

    Widget words;
    if (!widget.showAddress) {
      words = Row(children: [
        Flexible(child: nameText),
        if (dot != null) ...[const SizedBox(width: 7), dot],
      ]);
    } else if (widget.under) {
      words = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Flexible(child: nameText),
            if (dot != null) ...[const SizedBox(width: 7), dot],
          ]),
          const SizedBox(height: 1),
          addressText,
        ],
      );
    } else {
      // The name takes the room it needs, and the address what is left: two
      // halves cut both, and neither then said which host it was.
      words = LayoutBuilder(builder: (context, box) {
        final painter = TextPainter(
          text: TextSpan(style: DefaultTextStyle.of(context).style.merge(nameStyle), children: [nameSpan]),
          maxLines: 1,
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
        )..layout();
        final left = box.maxWidth - painter.width - 12 - (dot == null ? 0 : (widget.showOpenLabel ? 56 : 14));
        painter.dispose();
        if (left < _minAddress) {
          return Row(children: [
            Flexible(child: nameText),
            if (dot != null) ...[const SizedBox(width: 7), dot],
          ]);
        }
        return Row(children: [
          nameText,
          if (dot != null) ...[const SizedBox(width: 7), dot],
          const SizedBox(width: 12),
          Expanded(child: Align(alignment: AlignmentDirectional.centerEnd, child: addressText)),
        ]);
      });
    }

    if (unavailable != null) {
      words = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          words,
          Text(
            unavailable,
            key: widget.unavailableKey,
            style: TextStyle(fontSize: 11, color: ZestTokens.textTertiary),
          ),
        ],
      );
    }

    final hovered = widget.hovers && _hover && canTap;
    Widget row = Container(
      margin: widget.margin,
      padding: widget.padding,
      decoration: BoxDecoration(
        color: widget.selected
            ? ZestTokens.brandSubtle
            : hovered
                ? ZestTokens.surfaceHover
                : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          if (widget.leading != null) ...[widget.leading!, const SizedBox(width: 6)],
          HostGlyph(host: c, group: widget.group ?? details?.group, size: widget.iconSize),
          SizedBox(width: widget.iconSize <= 16 ? 8 : 10),
          Expanded(child: words),
          if (widget.trailing != null) ...[const SizedBox(width: 8), widget.trailing!],
        ],
      ),
    );
    if (unavailable != null) row = Opacity(opacity: 0.55, child: row);
    return MouseRegion(
      cursor: canTap ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: widget.hovers ? (_) => setState(() => _hover = true) : null,
      onExit: widget.hovers ? (_) => setState(() => _hover = false) : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canTap ? widget.onTap : null,
        onDoubleTap: canTap ? widget.onDoubleTap : null,
        onSecondaryTapDown: widget.onSecondaryTapDown,
        child: Semantics(
          button: widget.onTap != null,
          enabled: widget.onTap == null ? null : canTap,
          selected: widget.selected ? true : null,
          child: row,
        ),
      ),
    );
  }
}
