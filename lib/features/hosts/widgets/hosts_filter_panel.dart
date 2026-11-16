import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// The Hosts page's Filter (3.0): by group, tag, kind of host, open now and
/// needs attention, each ticked or not where it is, the page following as
/// they change. Clear takes them all off.
class HostsFilterPanel extends StatelessWidget {
  const HostsFilterPanel({
    super.key,
    required this.groups,
    required this.ungroupedId,
    required this.group,
    required this.onGroup,
    required this.tags,
    required this.tagsOn,
    required this.onTag,
    required this.kinds,
    required this.kindsOn,
    required this.onKind,
    required this.openOnly,
    required this.onOpenOnly,
    required this.attentionOnly,
    required this.onAttentionOnly,
    required this.onClear,
  });

  final List<({String id, String name})> groups;
  final String ungroupedId;

  /// The group shown alone, or null for any.
  final String? group;
  final ValueChanged<String?> onGroup;
  final List<String> tags;
  final Set<String> tagsOn;
  final ValueChanged<String> onTag;
  final List<({String id, String name})> kinds;
  final Set<String> kindsOn;
  final ValueChanged<String> onKind;
  final bool openOnly;
  final ValueChanged<bool> onOpenOnly;
  final bool attentionOnly;
  final ValueChanged<bool> onAttentionOnly;
  final VoidCallback onClear;

  bool get _any => group != null || tagsOn.isNotEmpty || kindsOn.isNotEmpty || openOnly || attentionOnly;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      key: const ValueKey('hosts-filter-panel'),
      width: 280,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.borderStrong),
        boxShadow: const [BoxShadow(color: Color(0xA6000000), blurRadius: 60, offset: Offset(0, 24), spreadRadius: -12)],
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _Head(l10n.hostsFilterShow),
            _Check(
              key: const ValueKey('filter-open-now'),
              icon: LucideIcons.circleDot,
              label: l10n.hostsFilterOpenNow,
              on: openOnly,
              onTap: () => onOpenOnly(!openOnly),
            ),
            _Check(
              key: const ValueKey('filter-attention'),
              icon: LucideIcons.alertTriangle,
              label: l10n.hostsFilterAttention,
              on: attentionOnly,
              onTap: () => onAttentionOnly(!attentionOnly),
            ),
            if (groups.isNotEmpty) ...[
              _Head(l10n.hostsFilterGroup),
              _Check(
                icon: LucideIcons.layers,
                label: l10n.hostsFilterAnyGroup,
                on: group == null,
                round: true,
                onTap: () => onGroup(null),
              ),
              for (final g in groups)
                _Check(
                  key: ValueKey('filter-group-${g.id}'),
                  icon: LucideIcons.folder,
                  label: g.name,
                  redact: true,
                  on: group == g.id,
                  round: true,
                  onTap: () => onGroup(group == g.id ? null : g.id),
                ),
              _Check(
                icon: LucideIcons.folderOpen,
                label: l10n.hostPanelUngrouped,
                on: group == ungroupedId,
                round: true,
                onTap: () => onGroup(group == ungroupedId ? null : ungroupedId),
              ),
            ],
            if (tags.isNotEmpty) ...[
              _Head(l10n.hostsFilterTags),
              for (final t in tags)
                _Check(
                  key: ValueKey('filter-tag-$t'),
                  icon: LucideIcons.tag,
                  label: t,
                  on: tagsOn.contains(t),
                  onTap: () => onTag(t),
                ),
            ],
            if (kinds.length > 1) ...[
              _Head(l10n.hostsFilterKind),
              for (final k in kinds)
                _Check(
                  key: ValueKey('filter-kind-${k.id}'),
                  icon: LucideIcons.terminal,
                  label: k.name,
                  on: kindsOn.contains(k.id),
                  onTap: () => onKind(k.id),
                ),
            ],
            if (_any) ...[
              Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 5, horizontal: 4), color: ZestTokens.border),
              _Check(
                key: const ValueKey('filter-clear'),
                icon: LucideIcons.x,
                label: l10n.hostsClearFilters,
                on: false,
                plain: true,
                onTap: onClear,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.text);
  final String text;

  @override
  // The app's section header, as every section's, popovers too.
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 0),
        child: ZestSectionHeader(label: text),
      );
}

class _Check extends StatefulWidget {
  const _Check({
    super.key,
    required this.icon,
    required this.label,
    required this.on,
    required this.onTap,
    this.round = false,
    this.plain = false,
    this.redact = false,
  });

  final IconData icon;
  final String label;
  final bool on;
  final VoidCallback onTap;

  /// One of several (a group): a round mark.
  final bool round;

  /// No mark at all (Clear).
  final bool plain;

  /// A name of the person's own (a group), masked in recording mode.
  final bool redact;

  @override
  State<_Check> createState() => _CheckState();
}

class _CheckState extends State<_Check> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(color: ZestTokens.textPrimary, fontSize: 12.5);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: Container(
          height: 34,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: _hover ? ZestTokens.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(7),
          ),
          child: Row(
            children: [
              if (!widget.plain) ...[
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: widget.on ? ZestTokens.brand : Colors.transparent,
                    borderRadius: BorderRadius.circular(widget.round ? 8 : 4),
                    border: Border.all(color: widget.on ? ZestTokens.brand : ZestTokens.borderStrong, width: 1.5),
                  ),
                  child: widget.on ? Icon(LucideIcons.check, size: 11, color: ZestTokens.onBrand) : null,
                ),
                const SizedBox(width: 10),
              ],
              Icon(widget.icon, size: 14, color: ZestTokens.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: widget.redact
                    ? RedactedText(Redactable.group(widget.label), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)
                    : Text(widget.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
