import 'package:flutter/material.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import '../models/group.dart';
import '../../../core/theme/zest_colors.dart';

class GroupCard extends StatefulWidget {
  const GroupCard({
    super.key,
    required this.group,
    this.onTap,
    this.onSecondaryTap,
    this.onAcceptHost,
  });
  final HostGroup group;
  final VoidCallback? onTap;

  /// Right-click / long-press on the card. The Offset is in *global*
  /// coordinates (suitable for [showMenu]'s `position` argument).
  /// When null the card has no context menu.
  final ValueChanged<Offset>? onSecondaryTap;

  /// When non-null, the card becomes a drop target for host drags.
  /// Receives the dropped connection so the parent can re-assign its
  /// `groupId`. Null hides the drop affordance entirely.
  final ValueChanged<ConnectionWithDetails>? onAcceptHost;

  @override
  State<GroupCard> createState() => _GroupCardState();
}

class _GroupCardState extends State<GroupCard> {
  /// True while a drag-from-host is hovering over this card. Lights up
  /// the border in the group's accent colour so the user has clear
  /// "drop here" feedback.
  bool _isDropHover = false;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    final card = MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: radius,
          onTap: widget.onTap,
          onSecondaryTapUp: widget.onSecondaryTap == null
              ? null
              : (details) =>
                  widget.onSecondaryTap!(details.globalPosition),
          onLongPress: widget.onSecondaryTap == null
              ? null
              : () {
                  // Long-press anchor falls back to the card's centre.
                  // (We don't have a position from onLongPress, only
                  // from onLongPressStart, but InkWell exposes the
                  // simple version - good enough for touch / a11y.)
                  final box = context.findRenderObject();
                  if (box is RenderBox) {
                    final centre = box.localToGlobal(
                        Offset(box.size.width / 2, box.size.height / 2));
                    widget.onSecondaryTap!(centre);
                  }
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            decoration: BoxDecoration(
              color: _isDropHover
                  ? Color.alphaBlend(
                      widget.group.accentColor.withValues(alpha: 0.10),
                      ZestColors.bgSurface,
                    )
                  : ZestColors.bgSurface,
              borderRadius: radius,
              border: Border.all(
                color: _isDropHover
                    ? widget.group.accentColor
                    : ZestColors.borderDefault,
                width: _isDropHover ? 1.5 : 0.5,
              ),
            ),
            child: ClipRRect(
              borderRadius: radius,
              child: SizedBox(
                height: 88,
                child: Stack(
                  children: [
                    // 3px color band along the top
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: 3,
                      child: ColoredBox(color: widget.group.accentColor),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 19, 16, 16),
                      child: Row(
                        children: [
                          // 48x48 tinted icon container
                          Container(
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: widget.group.color.tint,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Icon(
                              widget.group.icon,
                              color: widget.group.accentColor,
                              size: 24,
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                RedactedText(
                                  Redactable.group(widget.group.name),
                                  style: TextStyle(
                                    color: ZestColors.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                const SizedBox(height: 4),
                                Text.rich(TextSpan(
                                  style: TextStyle(
                                    color: ZestColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                  children: [
                                    TextSpan(
                                      text:
                                          '${widget.group.hostCount} ${widget.group.hostCount == 1 ? "host" : "hosts"}',
                                    ),
                                    const TextSpan(text: ' · '),
                                    TextSpan(
                                      text:
                                          '${widget.group.onlineCount} online',
                                      style: TextStyle(
                                        color: ZestColors.statusSuccess,
                                      ),
                                    ),
                                  ],
                                )),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

    if (widget.onAcceptHost == null) return card;

    // DragTarget wraps the card so dragging a host card onto this group
    // assigns the host to this group. Highlight ([_isDropHover]) gives
    // the user clear "drop here" feedback in the group's accent colour.
    return DragTarget<ConnectionWithDetails>(
      onWillAcceptWithDetails: (_) {
        setState(() => _isDropHover = true);
        return true;
      },
      onLeave: (_) => setState(() => _isDropHover = false),
      onAcceptWithDetails: (details) {
        setState(() => _isDropHover = false);
        widget.onAcceptHost!(details.data);
      },
      builder: (_, _, _) => card,
    );
  }
}
