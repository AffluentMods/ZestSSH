import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart' show CustomSemanticsAction;
import 'package:flutter/services.dart';
import 'package:zestssh/features/hosts/host_attention.dart';
import 'package:zestssh/features/hosts/host_health_summary.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import '../../../l10n/generated/app_localizations.dart';
import '../../../core/theme/zest_colors.dart';
import '../../../theme/app_colors.dart';
import '../../../core/widgets/os_icon.dart';
import '../../../core/widgets/status_pill.dart';
import '../../../providers/host_card_settings_provider.dart';
import '../models/host_card_settings.dart';
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart' show HostSessionsLoggedNote;
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart' show HostCrateClosedNote;
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart' show HostSessionsWatchedNote;
import 'package:zestssh/features/cloud_import/cloud_plan.dart';
import 'package:zestssh/features/cloud_import/ui/host_cloud_mark.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;

/// The built-in icon a host of [protocol] shows where its person chose none:
/// a screen for a remote screen (4.0, VNC); null for any other host.
String? defaultIconIdFor(String protocol) => ConnectionProtocol.storedIsScreen(protocol) ? 'desktop' : null;

/// Whether a host of [protocol] can carry a remote screen (4.0): an SSH host,
/// or one reached over SSH (Mosh, Eternal Terminal). "Add a screen for this
/// host" is on their menus.
bool screenCarrierKind(String protocol) =>
    protocol == ConnectionProtocol.ssh.name ||
    protocol == ConnectionProtocol.mosh.name ||
    protocol == ConnectionProtocol.et.name;

class HostCardData {
  const HostCardData({
    required this.id,
    required this.name,
    required this.subtitle,
    required this.osId,
    required this.status,
    required this.hasActiveSession,
    this.colorValue,
    this.colorIndex = 0,
    this.groupColor,
    this.groupName,
    this.pinned = false,
    this.note,
    this.lastConnected,
    this.hasChangedHostKey = false,
    this.showGroupChip = true,
    this.tmuxSessions = 0,
    this.iconId,
    this.customIcon,
    this.iconColor,
    this.healthChips = const [],
    this.cloud,
    this.tags = const [],
    this.health = HostHealthSummary.none,
    this.oldKeyExchange = false,
    this.connectOnly = false,
    this.openSessions = 0,
  });

  /// How many sessions to the host are open or opening: what its card says
  /// at its right ("Open", "2 open").
  final int openSessions;

  /// [openSessions], or one where the caller said only that it is open.
  int get openCount => openSessions > 0 ? openSessions : (hasActiveSession ? 1 : 0);

  /// The host refused a connection from this device for an old key exchange
  /// that Compatibility mode would take, and the mode is off: "Old key
  /// exchange" after its address (3.4).
  final bool oldKeyExchange;

  /// In a team's vault where this account's role can only connect: while
  /// hosts are selected, "Connect only" after its address, since an edit of
  /// the selection leaves it as it is.
  final bool connectOnly;

  /// Its health in one cell of the Hosts list, and what the list's Health
  /// order goes by (its worst metric).
  final HostHealthSummary health;

  /// The host's tags: small outlined chips after its name where the person
  /// has them shown on cards (Settings, Host cards), and in the list view.
  final List<String> tags;
  final String id;
  final String name;
  final String subtitle;           // e.g. "deploy@192.168.10.21 · SSH"
  final String? osId;

  /// A user-chosen built-in icon id (overrides the auto OS icon).
  final String? iconId;

  /// A user-uploaded base64 PNG icon (overrides everything).
  final String? customIcon;

  /// What colours the icon, as the host stores it (see `HostIconColor`): null
  /// for the icon's own colour.
  final int? iconColor;

  /// The per-host colour-label channel, stored raw so the card resolves it
  /// through [AppColors.resolveConnectionLabelColor] at render time. A custom
  /// [colorValue] (ARGB) wins; otherwise a non-zero [colorIndex] is an explicit
  /// palette override; `null`/`0` means "None → inherit the group colour".
  final int? colorValue;
  final int colorIndex;

  /// The host's group's OWN resolved colour, or `null` when the host is
  /// ungrouped. Never copied onto the host record - the caller resolves it at
  /// render time (via `resolveGroupColor`) and passes it here. It feeds TWO
  /// channels: the left rail's group INHERITANCE (when the host has no explicit
  /// colour override) and the group CHIP's dot. Ungrouped + no override ⇒ the
  /// rail falls back to neutral grey.
  final Color? groupColor;

  /// The host's group name for the inline group chip, or `null` when ungrouped
  /// (the chip is then suppressed).
  final String? groupName;

  final HostStatus status;
  final bool hasActiveSession;

  /// Pinned to the front of its section (Part B). Rendered as a small badge.
  final bool pinned;

  /// Optional user note. Stored + editable; surfaced in the host inspector.
  final String? note;

  /// Last time a session connected - stored for sorting / the inspector.
  final DateTime? lastConnected;

  /// Whether to render the inline group CHIP (dot + group name) beside the
  /// host name. The chip is the ONLY per-card group signal now that the left
  /// bar carries the colour label, so it matters in FLAT views (search
  /// results, Sort: Recent, Arrange mode) where the group section headers are
  /// gone. In a grouped view the section header already names the group, so
  /// the caller passes `false` to suppress the redundant chip. Only rendered
  /// when [groupName] is non-null.
  final bool showGroupChip;

  /// tmux sessions known to be running on this host (from the last look):
  /// a badge in the list view, and a line of the host's panel that attaches
  /// directly (the card has no room for it since 4.0). Zero hides it.
  final int tmuxSessions;

  /// Server Monitor's warnings for this host (a metric over its threshold,
  /// or cannot be reached), worst first. Empty when healthy or unwatched.
  /// The card shows the worst; its tooltip says each.
  final List<HostHealthChip> healthChips;

  /// Where the host was imported from (3.0 cloud import), shown as a small
  /// cloud next to its name; null when it was not imported from a cloud.
  final CloudLink? cloud;

  /// This host presented a CHANGED host key that the user hasn't resolved yet
  /// (Doc-3 F2). Surfaced as a distinct security warning on the card - taking
  /// visual priority over the routine connection status - so the condition is
  /// visible WITHOUT a fresh connection attempt. Cleared once the user trusts
  /// the new key.
  final bool hasChangedHostKey;
}

/// Host card on the Hosts home page.
///
/// Behaviour:
/// * Plain tap     → [onTap] (typically connect-to-host)
/// * Right-click   → [onSecondaryTap] receives the global pointer position
///                   so the caller can anchor a context menu
/// * Hover         → reveals a small pencil button in the top-right that
///                   calls [onEdit] (so users don't have to right-click
///                   to find the edit action). The pencil is gated by the
///                   `showHoverEdit` user setting.
/// * Selection mode (toggled via [isSelectionMode]) shows a circular
///   checkbox in the top-right; selected cards get an accent ring +
///   subtle wash to read as "checked" without being noisy.
///
/// What it shows (4.0): its OS tile, its
/// name and its address, and at its right at most two quiet signals, "Open"
/// or "2 open" while it has sessions and one health chip only where a limit
/// is crossed (a changed host key in the chip's place). No stripe and no
/// tags by default.
///
/// Visual customisation: the card height, font sizes, OS icon size,
/// whether it says it is open, subtitle visibility, its tags and the accent
/// rail colour all read from [hostCardSettingsProvider].  Users tune
/// these from Settings → Appearance → Host cards.
class HostCard extends ConsumerStatefulWidget {
  const HostCard({
    super.key,
    required this.data,
    this.onTap,
    this.onSecondaryTap,
    this.onEdit,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.highlighted = false,
    this.onTapDown,
    this.onDoubleTap,
    this.compact = false,
    this.onActivate,
    this.onConnect,
  });

  final HostCardData data;

  /// What Enter or Space on the card, and a screen reader's double tap, do
  /// (4.0, the accessibility pass): where null, [onTap], else [onTapDown]. A
  /// computer's card answers a press with [onTapDown] and has no [onTap], so
  /// before this a keyboard and a screen reader could not open it.
  final VoidCallback? onActivate;

  /// Connects: a screen reader's Connect action on the card (where null,
  /// [onDoubleTap]).
  final VoidCallback? onConnect;

  /// The Hosts page's compact grid: the card at its compact size, whatever
  /// size Settings gives the cards.
  final bool compact;
  final VoidCallback? onTap;

  /// The host shown in the Hosts page's panel: an accent ring.
  final bool highlighted;

  /// Fires on press, before a possible second tap: selects without waiting
  /// out the double-tap delay.
  final VoidCallback? onTapDown;

  /// A double click connects (desktop Hosts page).
  final VoidCallback? onDoubleTap;
  final ValueChanged<Offset>? onSecondaryTap;

  /// Hover-revealed edit affordance. When non-null AND the user has
  /// `showHoverEdit` enabled, a pencil button appears in the top-right
  /// corner on mouse hover.
  final VoidCallback? onEdit;

  /// Multi-select mode is on. Cards show a checkbox affordance and the
  /// tap handler should toggle selection rather than connect.
  final bool isSelectionMode;

  /// True when this specific card is currently selected. Only meaningful
  /// when [isSelectionMode] is also true.
  final bool isSelected;

  @override
  ConsumerState<HostCard> createState() => _HostCardState();
}

class _HostCardState extends ConsumerState<HostCard> {
  bool _hovering = false;

  /// The keyboard is on the card: its ring in the accent, 2 px.
  bool _focused = false;

  VoidCallback? get _activate => widget.onActivate ?? widget.onTap ?? widget.onTapDown;
  VoidCallback? get _connect => widget.onConnect ?? widget.onDoubleTap;

  /// The card as one sentence for a screen reader: its name, address, group,
  /// whether it is open, what needs attention, and its tags (it read as two
  /// fragments, its name and its address, with no way to open it).
  String _spoken(AppLocalizations? l10n) {
    final d = widget.data;
    return [
      Redactable.host(d.name).displayIn(ref),
      if (d.subtitle.isNotEmpty) Redactable.freeText(d.subtitle).displayIn(ref),
      ?d.groupName,
      // (A card drawn with no app's words around it, in a test, says the rest
      // in none.)
      if (l10n != null) ..._states(l10n),
    ].join(', ');
  }

  List<String> _states(AppLocalizations l10n) {
    final d = widget.data;
    return [
      if (d.openCount > 0) d.openCount > 1 ? l10n.hostOpenSessionsCount(d.openCount) : l10n.phoneHostsOpen,
      if (d.hasChangedHostKey) l10n.hostKeyChangedTitle,
      for (final chip in d.healthChips) chip.tooltip,
      if (d.oldKeyExchange) l10n.bulkOldKeyExchange,
      if (widget.isSelectionMode && d.connectOnly) l10n.bulkConnectOnly,
      if (d.pinned) l10n.phoneHostsPinned,
      ...d.tags,
    ];
  }

  /// Opens what a right click opens, at the card's middle (Shift+F10, the
  /// menu key, a screen reader's More actions).
  void _openMenu() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || widget.onSecondaryTap == null) return;
    widget.onSecondaryTap!(box.localToGlobal(box.size.center(Offset.zero)));
  }

  /// The card reached with Tab, opened with Enter or Space, its menu with
  /// Shift+F10 or the menu key, and said as one button with its state and
  /// its actions (Connect, Edit, More actions).
  Widget _accessible(Widget card) {
    final l10n = AppLocalizations.of(context);
    final activate = _activate;
    final connect = _connect;
    final menu = widget.onSecondaryTap == null ? null : _openMenu;
    // One node to a screen reader: the card's focus and its words together
    // (the focus outside them made an empty stop before the card).
    return Semantics(
      container: true,
      button: true,
      enabled: activate != null,
      label: _spoken(l10n),
      // Picked while hosts are being selected; the one open in the panel
      // otherwise.
      checked: widget.isSelectionMode ? widget.isSelected : null,
      selected: !widget.isSelectionMode && widget.highlighted,
      onTap: activate,
      customSemanticsActions: {
        if (l10n != null && connect != null && !widget.isSelectionMode)
          CustomSemanticsAction(label: l10n.commonConnect): connect,
        if (l10n != null && widget.onEdit != null && !widget.isSelectionMode)
          CustomSemanticsAction(label: l10n.edit): widget.onEdit!,
        if (l10n != null && menu != null && !widget.isSelectionMode)
          CustomSemanticsAction(label: l10n.zestCommonMoreActions): menu,
      },
      child: FocusableActionDetector(
        enabled: activate != null,
        mouseCursor: MouseCursor.defer,
        onShowFocusHighlight: (f) {
          if (f != _focused) setState(() => _focused = f);
        },
        shortcuts: {
          const SingleActivator(LogicalKeyboardKey.enter): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.numpadEnter): const ActivateIntent(),
          const SingleActivator(LogicalKeyboardKey.space): const ActivateIntent(),
          if (menu != null) const SingleActivator(LogicalKeyboardKey.f10, shift: true): const _HostMenuIntent(),
          if (menu != null) const SingleActivator(LogicalKeyboardKey.contextMenu): const _HostMenuIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            activate?.call();
            return null;
          }),
          if (menu != null)
            _HostMenuIntent: CallbackAction<_HostMenuIntent>(onInvoke: (_) {
              menu();
              return null;
            }),
        },
        child: card,
      ),
    );
  }

  static const _radius = BorderRadius.only(
    topLeft: Radius.circular(4),
    bottomLeft: Radius.circular(4),
    topRight: Radius.circular(12),
    bottomRight: Radius.circular(12),
  );

  @override
  Widget build(BuildContext context) {
    final chosen = ref.watch(hostCardSettingsProvider);
    final settings = widget.compact ? chosen.copyWith(density: HostCardDensity.compact) : chosen;

    // Being open is said in words at the card's right (4.0: "Open", "2
    // open", with a green dot), and nothing for a host that is not open, at
    // full strength like the rest. The stripe, where the person has one, is
    // always the colour label, never the status.

    // Every host is drawn as the one full card (icon, name, address, status):
    // the per-host size (small square, medium row) was taken away,
    // and a size a host still has saved is not read.

    // Border colour priority: selected > changed host key > open in the
    // panel > hover > default. Being connected is the words at the right
    // alone: a border tinted by the brand as well competed with the
    // selection's ring.
    Color ringColor;
    double ringWidth;
    if (_focused) {
      // The keyboard is on it (4.0, the accessibility pass): the accent, 2 px.
      ringColor = ZestColors.accentPrimary;
      ringWidth = 2;
    } else if (widget.isSelectionMode && widget.isSelected) {
      ringColor = ZestColors.accentPrimary;
      ringWidth = 1.5;
    } else if (widget.data.hasChangedHostKey) {
      // Unresolved changed host key - a security warning that outranks the
      // routine session border so the card visibly flags itself (F2).
      ringColor = ZestColors.statusError;
      ringWidth = 1.0;
    } else if (widget.highlighted) {
      // The host open in the panel.
      ringColor = ZestColors.accentPrimary;
      ringWidth = 1.5;
    } else if (_hovering) {
      // Pointer response - brighten the border so the card feels alive
      // under the mouse (the #1 "built for touch" tell was that hover
      // did nothing). Restraint over decoration: a border lift + a
      // faint fill, no shadow.
      ringColor = ZestColors.borderStrong;
      ringWidth = 1.0;
    } else {
      ringColor = ZestColors.borderDefault;
      ringWidth = 1.0;
    }

    // Resolved colour label (explicit host override ?? inherited group
    // colour). Used for the accent rail and, in group mode, a soft wash across
    // the whole card so the colour reads at a glance rather than only as a thin
    // stripe - matching the sidebar's group tint.
    final Color? resolvedLabel = _resolvedLabel;
    // The card sits on the Blueprint's card surface (`.raised`); the colour
    // label is its stripe and its icon's tile, not a wash.
    final Color surfaceBase = ZestColors.chromeElevated;

    // Fill lifts subtly on hover; a selected card takes a little of the brand.
    // Being open is the words at its right, not a wash.
    final Color fillColor;
    if (widget.isSelectionMode && widget.isSelected) {
      fillColor = Color.alphaBlend(
        ZestColors.accentPrimary.withValues(alpha: 0.09),
        surfaceBase,
      );
    } else if (_hovering) {
      fillColor = Color.alphaBlend(
        ZestColors.textPrimary.withValues(alpha: 0.04),
        surfaceBase,
      );
    } else {
      fillColor = surfaceBase;
    }

    // Accent rail colour - colour-label / uniform / none.
    final Color railColor;
    final double railWidth;
    switch (settings.accentMode) {
      case HostCardAccentMode.group:
        // The rail is the RESOLVED colour label - explicit host override ??
        // inherited group colour (computed above and also used for the card
        // wash). A host with NEITHER an override NOR a group shows NO rail at
        // all - the bare card, not a neutral-grey stub.
        railColor = resolvedLabel ?? Colors.transparent;
        railWidth = resolvedLabel == null ? 0 : 3;
        break;
      case HostCardAccentMode.uniform:
        railColor = ZestColors.accentPrimary;
        railWidth = 3;
        break;
      case HostCardAccentMode.none:
        railColor = Colors.transparent;
        railWidth = 0;
        break;
    }

    // NOTE: the MouseRegion that drives [_hovering] now lives on the
    // OUTER widget (around the Stack) instead of just around this
    // tile.  When it wrapped only the tile, moving the cursor onto
    // the floating edit-pencil - which is positioned INSIDE the
    // Stack but OUTSIDE the tile - fired the MouseRegion's onExit,
    // [_hovering] flipped false, the pencil faded out, the cursor
    // landed back on the card, [_hovering] flipped true, the pencil
    // faded in, and you saw the button blink in and out repeatedly.
    // Wrapping the Stack as a single hover region fixes that for
    // good - onExit only fires when the cursor leaves the WHOLE
    // card, including the button.
    final Widget tile = Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: _radius,
        // The card's own focus and words are [_accessible]'s.
        canRequestFocus: false,
        excludeFromSemantics: true,
        onTap: widget.onTap,
        onTapDown:
            widget.onTapDown == null ? null : (_) => widget.onTapDown!(),
        onDoubleTap: widget.onDoubleTap,
        onSecondaryTapUp: widget.onSecondaryTap == null
            ? null
            : (details) => widget.onSecondaryTap!(details.globalPosition),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
          decoration: BoxDecoration(
            color: fillColor,
            borderRadius: _radius,
            border: Border.all(color: ringColor, width: ringWidth),
          ),
          child: ClipRRect(
            borderRadius: _radius,
            child: _cardBody(
              settings,
              railColor: railColor,
              railWidth: railWidth,
            ),
          ),
        ),
      ),
    );

    // ── Overlays ─────────────────────────────────────────────────
    // Wrap the whole tile + overlay in ONE MouseRegion. The hover
    // state drives the edit-pencil's visibility; if the MouseRegion
    // wrapped only [tile] (the previous arrangement), moving the
    // cursor onto the floating pencil - which lives in a Positioned
    // outside [tile] - would fire onExit and the pencil would blink
    // in and out repeatedly.
    //
    // InkWell on Flutter desktop doesn't switch the cursor to a
    // pointer on its own; this MouseRegion handles that too.
    // Selection mode: the icon's place holds the card's box (see
    // [_leading]); hover still drives it, so an unselected card offers its
    // empty box under the pointer.
    if (widget.isSelectionMode) {
      return _accessible(MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: tile,
      ));
    }

    // Hosts that are not open are drawn at full strength (3.0): dimmed, a page
    // of hosts nobody is connected to looked switched off.
    Widget dim(Widget w) => _accessible(w);

    if (widget.onEdit == null || !settings.showHoverEdit) {
      // Still track hover so the card's fill/border respond to the
      // pointer even when the edit-pencil affordance is disabled.
      return dim(MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: tile,
      ));
    }

    return dim(MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Stack(
        children: [
          tile,
          // Hover-revealed edit pencil.  The pencil is invisible until
          // hover AND non-interactive until hover - the earlier IgnorePointer
          // race is gone now that the ENTIRE tile+overlay share one
          // MouseRegion (see the comment above): `_hovering` is already true
          // by the time any click can land on the corner, because the cursor
          // must be over the card to reach the pencil. Keying IgnorePointer
          // off the same `_hovering` flag stops a stray click on the invisible
          // top-right corner from firing Edit when the card isn't hovered.
          //
          // Bumped from 32→40px square with an 18px icon - the
          // previous 32px target was easy to overshoot, especially
          // on high-DPI displays where the visual size shrinks.
          Positioned(
            top: 4,
            right: 6,
            child: IgnorePointer(
              ignoring: !_hovering,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 120),
                opacity: _hovering ? 1 : 0,
                child: _EditButton(onTap: widget.onEdit!),
              ),
            ),
          ),
        ],
      ),
    ));
  }

  /// Resolved colour label (explicit host override ?? inherited group
  /// colour), null when the host has neither. Drives the rail and the
  /// group-mode wash, and the host's icon where the person had it follow the
  /// label.
  Color? get _resolvedLabel => AppColors.resolveConnectionLabelColorOrNull(
        connColorValue: widget.data.colorValue,
        connColorIndex: widget.data.colorIndex,
        inheritedGroupColor: widget.data.groupColor,
      );

  /// Builds the interior of the card: the rail where there is one, the icon,
  /// the name line and the address, and the signals at the right.
  Widget _cardBody(
    HostCardSettings settings, {
    required Color railColor,
    required double railWidth,
  }) {
    final showSubtitle = settings.showSubtitle;
    // Its tags, where the person has them on cards (off by default since
    // 4.0), ride on the name's line, so every card is one height whatever it
    // has (a line of their own made every card of the grid taller). A compact
    // card has no room for them.
    final tags = settings.showTags && showSubtitle && !widget.compact && widget.data.tags.isNotEmpty;
    final signals = _signals(settings);
    return SizedBox(
      height: settings.density.heightFor(MediaQuery.textScalerOf(context)),
      child: Stack(
        children: [
          // The colour label's rail lies over the card's edge, so a card with
          // one has its icon and name where a card without one has them (they
          // sat 3px further in).
          if (railWidth > 0)
            Positioned(
              key: const ValueKey('host-card-rail'),
              left: 0,
              top: 0,
              bottom: 0,
              width: railWidth,
              child: ColoredBox(color: railColor),
            ),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: EdgeInsets.fromLTRB(
                      12, settings.density.verticalPadding, 14, settings.density.verticalPadding),
                  child: Row(
                    children: [
                      if (settings.showOsIcon || widget.isSelectionMode) ...[
                        ExcludeSemantics(child: _leading(settings)),
                        const SizedBox(width: 11),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            ExcludeSemantics(child: _nameRow(settings, tags: tags)),
                            if (showSubtitle) ...[
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  Flexible(
                                    child: Text(
                                      Redactable.freeText(widget.data.subtitle).displayIn(ref),
                                      semanticsLabel: '',
                                      style: TextStyle(
                                        color: ZestColors.textTertiary,
                                        fontSize: settings.density.subtitleFontSize,
                                        fontFamily: 'JetBrainsMono',
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // Refused for an old key exchange (3.4).
                                  if (widget.data.oldKeyExchange) ...[
                                    const SizedBox(width: 8),
                                    // Whole beside the address where there is room;
                                    // never wider than this, so a narrow card is
                                    // not overflowed.
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 150),
                                      child: ExcludeSemantics(child: HostOldKexChip(key: ValueKey('host-card-old-kex-${widget.data.id}'))),
                                    ),
                                  ],
                                  // While selecting: an edit leaves it as it is.
                                  if (widget.isSelectionMode && widget.data.connectOnly) ...[
                                    const SizedBox(width: 8),
                                    ConstrainedBox(
                                      constraints: const BoxConstraints(maxWidth: 130),
                                      child: ExcludeSemantics(child: HostConnectOnlyMark(key: ValueKey('host-card-connect-only-${widget.data.id}'))),
                                    ),
                                  ],
                                  // Its sessions are logged for its team,
                                  // said before connecting.
                                  const SizedBox(width: 6),
                                  HostSessionsLoggedNote(connectionId: widget.data.id, compact: true),
                                  // And watched: someone has to join first.
                                  HostSessionsWatchedNote(connectionId: widget.data.id, compact: true),
                                  // Its Crate is closed on this device by its
                                  // own offline limit: it will not connect.
                                  HostCrateClosedNote(connectionId: widget.data.id, compact: true),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (signals != null) ...[
                        const SizedBox(width: 10),
                        ExcludeSemantics(child: signals),
                      ],
                    ],
                  ),
                ),
              ),
              // Touch sized (a tablet, 4.0): what a right click's menu holds,
              // under a more button in sight (a finger has no right button,
              // and nothing is found only by a hover).
              if (touchSizedAt(context) && widget.onSecondaryTap != null && !widget.isSelectionMode)
                Builder(
                  builder: (button) => IconButton(
                    key: ValueKey('host-card-more-${widget.data.id}'),
                    tooltip: AppLocalizations.of(context)!.phoneHostMoreActions(
                      Redactable.host(widget.data.name).displayIn(ref),
                    ),
                    icon: const Icon(LucideIcons.moreVertical, size: 18),
                    color: ZestColors.textSecondary,
                    constraints: const BoxConstraints.tightFor(width: 44, height: 48),
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      final box = button.findRenderObject() as RenderBox?;
                      if (box == null) return;
                      widget.onSecondaryTap!(box.localToGlobal(box.size.center(Offset.zero)));
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// What stands at the card's right (4.0): at
  /// most two quiet signals, one above the other. "Open" or "2 open" while it
  /// has sessions (where Settings has the card say it), and one health chip
  /// only where one of its limits is crossed: its worst, whose tooltip says
  /// each. A changed host key takes the chip's place: it outranks any
  /// reading. Null where there is nothing to say.
  Widget? _signals(HostCardSettings settings) {
    final d = widget.data;
    final open = settings.showStatusPill ? d.openCount : 0;
    final Widget? warning = d.hasChangedHostKey
        ? HostKeyChangedChip(key: ValueKey('host-card-key-changed-${d.id}'))
        : d.healthChips.isEmpty
            ? null
            : HostHealthChipView(key: ValueKey('host-card-health-${d.id}'), chip: worstHealthChip(d.healthChips));
    if (open == 0 && warning == null) return null;
    // Never taller than the card's lines (a large text size scales them
    // down), never wider than a narrow card can give.
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerEnd,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 132),
        child: Column(
          key: ValueKey('host-card-signals-${d.id}'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (open > 0) HostOpenSignal(key: ValueKey('host-card-open-${d.id}'), count: open),
            if (open > 0 && warning != null) const SizedBox(height: 5),
            ?warning,
          ],
        ),
      ),
    );
  }

  /// The card's icon; in selection mode, its box before it:
  /// filled with a tick when selected, empty
  /// when not. Where the icon is hidden (Settings), the box alone.
  Widget _leading(HostCardSettings settings) {
    final size = settings.density.iconSize;
    final icon = HostIcon(
      iconId: widget.data.iconId,
      customIcon: widget.data.customIcon,
      osId: widget.data.osId,
      size: size,
      iconColor: widget.data.iconColor,
      labelColor: _resolvedLabel,
    );
    if (!widget.isSelectionMode) return icon;
    final box = HostSelectBox(key: ValueKey('host-card-box-${widget.data.id}'), checked: widget.isSelected, size: 18);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        box,
        if (settings.showOsIcon) ...[const SizedBox(width: 10), icon],
      ],
    );
  }

  /// Name + pinned pin + group chip, and its tags where they are shown.
  ///
  /// The name shrinks (flex 3) before the group chip (flex 2) so both stay
  /// ellipsis-safe on a narrow card - neither can overflow the row. The chip is
  /// the GROUP channel; it is distinct from the signals at the right
  /// (connection state, health) and the resolved colour-label rail.
  Widget _nameRow(HostCardSettings settings, {bool tags = false}) {
    // Whether it is open is said at the card's right (see [_signals]).
    final name = RedactedText(
      Redactable.host(widget.data.name),
      style: TextStyle(
        color: ZestColors.textPrimary,
        fontSize: settings.density.titleFontSize - 0.5,
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    final group = widget.data.groupName != null && widget.data.showGroupChip
        ? _GroupChip(name: widget.data.groupName!, color: widget.data.groupColor)
        : null;
    final marks = <Widget>[
      // Group chip - the only per-card group signal (the left bar is the
      // colour label). Suppressed in grouped views via [showGroupChip].
      if (group != null) ...[
        const SizedBox(width: 8),
        tags ? ConstrainedBox(constraints: const BoxConstraints(maxWidth: 110), child: group) : Flexible(flex: 2, child: group),
      ],
      if (widget.data.pinned) ...[
        const SizedBox(width: 6),
        Icon(
          LucideIcons.pin,
          size: 11,
          color: ZestColors.accentInk,
        ),
      ],
      if (widget.data.cloud case final cloud?) ...[
        const SizedBox(width: 6),
        HostCloudMark(link: cloud),
      ],
    ];
    if (!tags) return Row(children: [Flexible(flex: 3, child: name), ...marks]);
    // Its tags on the name's line: as many as fit whole, never a second line
    // (the address keeps its own line whole). The name takes what it needs,
    // up to most of the line, and the tags the rest.
    final lineHeight = math.max(20.0, MediaQuery.textScalerOf(context).scale(settings.density.titleFontSize) * 1.45);
    return SizedBox(
      height: lineHeight,
      child: CustomMultiChildLayout(
        delegate: _NameLineDelegate(),
        children: [
          LayoutId(id: _NameLinePart.name, child: name),
          if (marks.isNotEmpty) LayoutId(id: _NameLinePart.marks, child: Row(mainAxisSize: MainAxisSize.min, children: marks)),
          LayoutId(
            id: _NameLinePart.chips,
            child: Flow(
              key: ValueKey('host-card-chips-${widget.data.id}'),
              delegate: const _WholeChipsDelegate(gap: 5),
              children: [
                for (final tag in widget.data.tags.take(3)) HostTagChip(tag: tag),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

enum _NameLinePart { name, marks, chips }

/// Opens a card's right click menu from the keyboard.
class _HostMenuIntent extends Intent {
  const _HostMenuIntent();
}

/// A card's name line with its tags: its marks (group, pin, cloud) at
/// their own width, the name at its own width up to most of what is left,
/// and the tags in the rest.
class _NameLineDelegate extends MultiChildLayoutDelegate {
  static const _gap = 8.0;

  @override
  void performLayout(Size size) {
    final h = size.height;
    var marks = Size.zero;
    if (hasChild(_NameLinePart.marks)) {
      marks = layoutChild(_NameLinePart.marks, BoxConstraints.loose(Size(size.width / 2, h)));
    }
    final room = math.max(0.0, size.width - marks.width);
    final name = layoutChild(_NameLinePart.name, BoxConstraints(maxWidth: room * 0.62, maxHeight: h));
    positionChild(_NameLinePart.name, Offset(0, (h - name.height) / 2));
    var x = name.width;
    if (hasChild(_NameLinePart.marks)) {
      positionChild(_NameLinePart.marks, Offset(x, (h - marks.height) / 2));
      x += marks.width;
    }
    x += _gap;
    final chipsHeight = math.min(18.0, h);
    layoutChild(_NameLinePart.chips, BoxConstraints.tightFor(width: math.max(0.0, size.width - x), height: chipsHeight));
    positionChild(_NameLinePart.chips, Offset(x, (h - chipsHeight) / 2));
  }

  @override
  bool shouldRelayout(_NameLineDelegate oldDelegate) => false;
}

/// Chips in a line, each at its own width: those that fit whole are drawn,
/// from the first, and the first that does not fit ends the line.
class _WholeChipsDelegate extends FlowDelegate {
  const _WholeChipsDelegate({required this.gap});

  final double gap;

  @override
  BoxConstraints getConstraintsForChild(int i, BoxConstraints constraints) =>
      BoxConstraints(maxHeight: constraints.maxHeight);

  @override
  void paintChildren(FlowPaintingContext context) {
    var x = 0.0;
    for (var i = 0; i < context.childCount; i++) {
      final size = context.getChildSize(i)!;
      if (x + size.width > context.size.width) break;
      final y = (context.size.height - size.height) / 2;
      context.paintChild(i, transform: Matrix4.translationValues(x, y, 0));
      x += size.width + gap;
    }
  }

  @override
  bool shouldRepaint(_WholeChipsDelegate oldDelegate) => oldDelegate.gap != gap;
}

/// The one health chip a host's card or row shows (4.0): the worst of
/// [chips] (they come worst first), its tooltip saying each of them.
HostHealthChip worstHealthChip(List<HostHealthChip> chips) {
  final worst = chips.first;
  if (chips.length == 1) return worst;
  return HostHealthChip(
    label: worst.label,
    critical: worst.critical,
    tooltip: [for (final c in chips) c.tooltip].join('\n'),
  );
}

/// The words a host's card or row says while it has sessions open or
/// opening (4.0): a green dot and "Open",
/// or "2 open" for more than one. In words, not by colour alone.
class HostOpenSignal extends StatelessWidget {
  const HostOpenSignal({super.key, required this.count, this.fontSize = 12});

  final int count;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final green = ZestColors.statusSuccess;
    // On a light page the green words read at about 3:1 on white: a third of
    // the way to the text colour there (as the list's Status column).
    final ink = Theme.of(context).brightness == Brightness.light ? Color.lerp(green, ZestColors.textPrimary, 0.35)! : green;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 7, height: 7, decoration: BoxDecoration(color: green, shape: BoxShape.circle)),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            count > 1 ? l10n.hostOpenSessionsCount(count) : l10n.phoneHostsOpen,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500, color: ink, height: 1.2),
          ),
        ),
      ],
    );
  }
}

/// A changed host key nobody has resolved (Doc-3 F2), on a host's card or
/// row: a security warning in red, with its words, in the place of a health
/// chip, which it outranks.
class HostKeyChangedChip extends StatelessWidget {
  const HostKeyChangedChip({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = ZestColors.statusError;
    final ink = Theme.of(context).brightness == Brightness.light ? Color.lerp(c, ZestColors.textPrimary, 0.35)! : c;
    return Tooltip(
      message: l10n.hostKeyChangedTitle,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.shieldAlert, size: 11, color: ink),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                l10n.hostKeyChangedTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ink, height: 1.1),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Inline group chip beside the host name (flat views only): a small dot in
/// the group's own colour + the muted group name, so it reads as a tag, not a
/// title. This is the sole per-card group signal once the left bar carries the
/// colour label instead of the group.
class _GroupChip extends StatelessWidget {
  const _GroupChip({required this.name, this.color});
  final String name;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            color: color ?? ZestColors.textTertiary,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: RedactedText(
            Redactable.group(name),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: ZestColors.textTertiary,
              fontSize: 11,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }
}

/// A host's box in selection mode (its card, its row of the list): filled in
/// the accent with a tick when the host is selected, an empty outline when it
/// is not. The box every list that selects draws ([SelectBox], 3.4).
typedef HostSelectBox = SelectBox;

/// "Old key exchange" after a host's address: it refused a connection for
/// an old key exchange that Compatibility mode would take (3.4).
class HostOldKexChip extends StatelessWidget {
  const HostOldKexChip({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final warn = ZestColors.statusWarning;
    return Tooltip(
      message: l10n.bulkOldKeyExchangeTip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: warn.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Text(
          l10n.bulkOldKeyExchange,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: warn),
        ),
      ),
    );
  }
}

/// "Connect only" after a host's address while hosts are selected: its
/// vault lets this account connect to it and no more, so an edit of the
/// selection leaves it as it is.
class HostConnectOnlyMark extends StatelessWidget {
  const HostConnectOnlyMark({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Tooltip(
      message: l10n.bulkConnectOnlyTip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 11, color: ZestColors.textTertiary),
          const SizedBox(width: 4),
          Flexible(
            child: Text(l10n.bulkConnectOnly,
                maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary)),
          ),
        ],
      ),
    );
  }
}

/// "N sessions" tmux badge: the brand-wash chip used for tmux everywhere,
/// so it reads as tmux at a glance. Tapping attaches directly.
class TmuxSessionsBadge extends StatelessWidget {
  const TmuxSessionsBadge({super.key, required this.count, this.onTap, this.compact = false});
  final int count;
  final VoidCallback? onTap;

  /// Icon and number only (tab bar).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final accent = AppColors.v3AccentPrimary;
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: accent.withValues(alpha: 0.32)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (compact) ...[
            Icon(LucideIcons.layoutGrid, size: 9, color: ZestColors.accentInk),
            const SizedBox(width: 3),
          ],
          Text(
            compact ? '$count' : l10n.tmuxSessionsBadge(count),
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: ZestColors.accentInk,
            ),
          ),
        ],
      ),
    );
    return Tooltip(
      message: l10n.tmuxSessionsBadgeTooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: chip,
        ),
      ),
    );
  }
}

/// A Server Monitor warning on a card: amber for a warning, red for a
/// critical or an unreachable host. The tooltip says what crossed which line.
class HostHealthChipView extends StatelessWidget {
  const HostHealthChipView({super.key, required this.chip});

  final HostHealthChip chip;

  @override
  Widget build(BuildContext context) {
    final c = chip.critical ? ZestColors.statusError : ZestColors.statusWarning;
    // On a light page the amber or red words on their own tint read at about
    // 4.2:1: they are taken a third of the way to the text colour there.
    final ink = Theme.of(context).brightness == Brightness.light
        ? Color.lerp(c, ZestColors.textPrimary, 0.35)!
        : c;
    return Tooltip(
      message: chip.tooltip,
      // Sized by its text (never taller than the address line beside it),
      // so the fixed-height card never overflows.
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: c.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          chip.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.w500,
            color: ink,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// A host's tag on its card or row: a small outlined chip.
class HostTagChip extends StatelessWidget {
  const HostTagChip({super.key, required this.tag});
  final String tag;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestColors.borderStrong),
      ),
      child: Text(
        tag,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 10.5, color: ZestColors.textTertiary, height: 1.1),
      ),
    );
  }
}

class _EditButton extends StatefulWidget {
  const _EditButton({required this.onTap});
  final VoidCallback onTap;

  @override
  State<_EditButton> createState() => _EditButtonState();
}

class _EditButtonState extends State<_EditButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: AppLocalizations.of(context)!.connectionCardEditConnection,
          child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 40,
            height: 40,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? ZestColors.bgElevated
                  : ZestColors.bgSurface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _hover
                    ? ZestColors.accentRing
                    : ZestColors.borderSubtle,
                width: _hover ? 0.8 : 0.6,
              ),
            ),
            child: Icon(
              LucideIcons.pencil,
              size: 18,
              color: _hover
                  ? ZestColors.accentInk
                  : ZestColors.textSecondary,
            ),
          ),
        ),
        ),
      ),
    );
  }
}

