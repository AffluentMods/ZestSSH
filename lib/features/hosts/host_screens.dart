// A host's own screens (4.0): the remote screen hosts (VNC, RDP) reached
// through an SSH host are shown as that host's, wherever the host is (its
// card, its row, its panel, its menu, its sheet, the Inspector of its
// session). A screen stays a host of its own in the database: its carrier
// is its `connectViaId`, as the screen's session reads it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/features/hosts/host_card_face.dart' show screenCardSubtitleOf;
import 'package:zestssh/features/hosts/widgets/host_card.dart' show screenCarrierKind;
import 'package:zestssh/features/hosts/widgets/section_label.dart' show SectionLink;
import 'package:zestssh/features/orchards/guardrails.dart' show mayAddScreenSpace;
import 'package:zestssh/features/orchards/spaces.dart' show Space;
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimit;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart' show ZestChoice, showZestChoice;
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';

/// The screens of every host in [all], by the host's id: the screen hosts
/// (VNC, RDP) whose carrier is that host, where that host can carry one
/// ([screenCarrierKind]) and is in [all] too, each list sorted by name. A
/// host with none has no entry.
Map<String, List<ConnectionWithDetails>> hostScreensByHost(List<ConnectionWithDetails> all) {
  final carriers = {
    for (final c in all)
      if (screenCarrierKind(c.connection.protocol)) c.connection.id,
  };
  final out = <String, List<ConnectionWithDetails>>{};
  for (final c in all) {
    final via = c.connection.connectViaId;
    if (via == null || !ConnectionProtocol.storedIsScreen(c.connection.protocol) || !carriers.contains(via)) continue;
    (out[via] ??= <ConnectionWithDetails>[]).add(c);
  }
  for (final list in out.values) {
    list.sort((a, b) {
      final byName = hostScreenName(a).toLowerCase().compareTo(hostScreenName(b).toLowerCase());
      return byName != 0 ? byName : a.connection.id.compareTo(b.connection.id);
    });
  }
  return out;
}

/// [hostScreensByHost] of the hosts of the space on screen, kept up to date.
final hostScreensByHostProvider = Provider<Map<String, List<ConnectionWithDetails>>>((ref) {
  final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
  return hostScreensByHost(all);
});

/// The screens of the host [hostId] ([hostScreensByHost]); empty where it
/// has none, or is not in the space on screen.
final screensOfHostProvider = Provider.family<List<ConnectionWithDetails>, String>((ref, hostId) =>
    ref.watch(hostScreensByHostProvider.select((m) => m[hostId] ?? const <ConnectionWithDetails>[])));

/// A screen host's name: its label, else its address.
String hostScreenName(ConnectionWithDetails screen) =>
    screen.connection.label.isNotEmpty ? screen.connection.label : screen.connection.host;

/// Its kind in a word: RDP or VNC (protocol names, the same in every language).
String hostScreenKind(ConnectionWithDetails screen) =>
    (screen.connection.protocol == ConnectionProtocol.rdp.name ? ConnectionProtocol.rdp : ConnectionProtocol.vnc).nameIn(gl10n);

/// What a button that opens [screens] says: the screen's name where there is
/// one, else that one is to be picked.
String hostScreenButtonLabel(AppLocalizations l10n, WidgetRef ref, List<ConnectionWithDetails> screens) =>
    screens.length == 1
        ? l10n.hostScreenOpenNamed(Redactable.host(hostScreenName(screens.single)).displayIn(ref))
        : l10n.hostScreenPick;

/// Opens one of [screens] with [onOpen]: the one there is at once; of
/// several, the one picked from a small menu at [at] (a computer), or from
/// a list where no place is given (a phone).
Future<void> pickHostScreen(
  BuildContext context,
  WidgetRef ref,
  List<ConnectionWithDetails> screens,
  ValueChanged<ConnectionWithDetails> onOpen, {
  Offset? at,
}) async {
  if (screens.isEmpty) return;
  if (screens.length == 1) {
    onOpen(screens.single);
    return;
  }
  final l10n = AppLocalizations.of(context)!;
  String words(ConnectionWithDetails s) => '${hostScreenKind(s)} · ${Redactable.host(hostScreenName(s)).displayIn(ref)}';
  String? id;
  final overlay = Overlay.maybeOf(context)?.context.findRenderObject();
  if (at != null && overlay is RenderBox) {
    id = await showMenu<String>(
      context: context,
      color: ZestColors.surfaceRaisedAlt,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: ZestColors.borderStrong),
      ),
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        for (final s in screens)
          PopupMenuItem(
            key: ValueKey('host-screen-pick-${s.connection.id}'),
            value: s.connection.id,
            height: 36,
            child: Row(
              children: [
                Icon(LucideIcons.monitor, size: 15, color: ZestColors.textSecondary),
                const SizedBox(width: 10),
                Flexible(
                  child: Text(words(s),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: ZestColors.textPrimary)),
                ),
              ],
            ),
          ),
      ],
    );
  } else {
    id = await showZestChoice<String>(
      context,
      title: l10n.hostScreenPick,
      icon: LucideIcons.monitor,
      choices: [
        for (final s in screens)
          ZestChoice(
            key: ValueKey('host-screen-pick-${s.connection.id}'),
            value: s.connection.id,
            label: Redactable.host(hostScreenName(s)).displayIn(ref),
            detail: hostScreenKind(s),
            icon: LucideIcons.monitor,
          ),
      ],
    );
  }
  final picked = screens.where((s) => s.connection.id == id).firstOrNull;
  if (picked != null) onOpen(picked);
}

/// "Add a screen" for the SSH host [host]: VNC or RDP asked first (VNC
/// alone where this build offers no RDP), then the editor of a new screen
/// host reached through [host], as "Add a screen for this host" opens it:
/// VNC at localhost:5900 on the host itself, RDP at the host's own address
/// on port 3389, named after the host and its kind. [beforeOpen], where
/// given, runs once the kind is chosen and before the editor opens (the
/// host's own editor closing first, its unsaved changes asked about); false
/// stops there. [ref] is not read once it has run.
Future<void> addScreenForHost(BuildContext context, WidgetRef ref, Connection host,
    {Future<bool> Function()? beforeOpen}) async {
  final l10n = AppLocalizations.of(context)!;
  final name = host.label.isNotEmpty ? host.label : host.host;
  var kind = ConnectionProtocol.vnc;
  if (ref.read(rdpOfferedProvider)) {
    final picked = await showZestChoice<ConnectionProtocol>(
      context,
      key: const ValueKey('host-screen-kind'),
      title: l10n.hostScreenAddTitle(Redactable.host(name).displayIn(ref)),
      subtitle: l10n.hostScreenAddSubtitle,
      icon: LucideIcons.monitor,
      choices: [
        ZestChoice(
          key: const ValueKey('host-screen-kind-vnc'),
          value: ConnectionProtocol.vnc,
          label: ConnectionProtocol.vnc.nameIn(l10n),
          detail: l10n.hostScreenAddVncDetail,
          icon: LucideIcons.monitor,
        ),
        ZestChoice(
          key: const ValueKey('host-screen-kind-rdp'),
          value: ConnectionProtocol.rdp,
          label: ConnectionProtocol.rdp.nameIn(l10n),
          detail: l10n.hostScreenAddRdpDetail,
          icon: LucideIcons.monitor,
        ),
      ],
    );
    if (picked == null || !context.mounted) return;
    kind = picked;
  }
  if (beforeOpen != null && (!await beforeOpen() || !context.mounted)) return;
  if (!context.mounted) return;
  await ConnectionEditScreen.showAdaptive(
    context,
    initialProtocol: kind,
    initialVia: host.id,
    initialHost: kind == ConnectionProtocol.rdp && host.host.isNotEmpty ? host.host : null,
    initialLabel: '$name ${kind.nameIn(l10n)}',
  );
}

/// Opens the screen host [screen] in a tab (the Inspector of a session: the
/// one open already is brought up), in [space], the space the session that
/// asked works in.
void openHostScreenInTab(BuildContext context, WidgetRef ref, ConnectionWithDetails screen, {Space? space}) {
  final id = ref.read(activeSessionsProvider.notifier).startSession(screen.connection, space: space);
  if (id == null) {
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(context, l10n.hostsSelNotOpenedPlan(Redactable.host(hostScreenName(screen)).display, freeSessionLimit),
        isWarning: true);
    return;
  }
  ref.read(workTabsProvider.notifier).onSessionCreated(id);
  ref.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  ref.read(v3ActiveSessionTabProvider.notifier).state = id;
}

/// The screen button of a host's card or row: a monitor that opens the
/// host's screen in one press, or, where it has several, a small menu of
/// them. Nothing where the host has none.
class HostScreenButton extends ConsumerWidget {
  const HostScreenButton({
    super.key,
    required this.hostId,
    required this.onOpen,
    this.size = 32,
    this.iconSize = 16,
    this.phone = false,
  });

  final String hostId;
  final ValueChanged<ConnectionWithDetails> onOpen;

  /// The button's square (a mouse's 32, a finger's 44 or 48).
  final double size;
  final double iconSize;

  /// Several screens are picked from a list, not a menu at the button.
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screens = ref.watch(screensOfHostProvider(hostId));
    if (screens.isEmpty) return const SizedBox.shrink();
    final words = hostScreenButtonLabel(AppLocalizations.of(context)!, ref, screens);
    return Tooltip(
      message: words,
      waitDuration: const Duration(milliseconds: 400),
      excludeFromSemantics: true,
      child: Builder(
        builder: (button) => ZestPressable(
          key: ValueKey('host-screen-button-$hostId'),
          onTap: () => pickHostScreen(button, ref, screens, onOpen, at: phone ? null : _below(button)),
          semanticLabel: words,
          excludeChildSemantics: true,
          borderRadius: 7,
          minSize: size,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(LucideIcons.monitor, size: iconSize, color: ZestColors.textSecondary),
          ),
        ),
      ),
    );
  }

  static Offset? _below(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    return box?.localToGlobal(box.size.bottomLeft(Offset.zero));
  }
}

/// The Screens section of a host's panel and of a session's Inspector: each
/// screen of the SSH host [hostId] with Open, and "+ Add a screen" where this
/// account may add a host in the space on screen. Nothing for a host that
/// carries no screen, nor where it has none and none may be added.
class HostScreensSection extends ConsumerWidget {
  const HostScreensSection({super.key, required this.hostId, required this.onOpen, this.topPadding = 16});

  final String hostId;
  final ValueChanged<ConnectionWithDetails> onOpen;

  /// The gap above the section's head, as the sections around it have.
  final double topPadding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final host = all.where((c) => c.connection.id == hostId).firstOrNull?.connection;
    if (host == null || !screenCarrierKind(host.protocol)) return const SizedBox.shrink();
    final screens = ref.watch(screensOfHostProvider(hostId));
    final mayAdd = mayAddScreenSpace(ref);
    if (screens.isEmpty && !mayAdd) return const SizedBox.shrink();
    return Column(
      key: ValueKey('host-screens-$hostId'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: ZestSectionHeader(
            label: l10n.hostScreensHead,
            trailing: mayAdd
                ? SectionLink(
                    key: ValueKey('host-screens-add-$hostId'),
                    label: '+ ${l10n.hostScreenAdd}',
                    onTap: () => addScreenForHost(context, ref, host),
                  )
                : null,
          ),
        ),
        if (screens.isEmpty)
          Text(
            l10n.hostScreensNone,
            key: ValueKey('host-screens-none-$hostId'),
            style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textSecondary),
          )
        else
          for (final s in screens) _ScreenRow(screen: s, onOpen: () => onOpen(s)),
      ],
    );
  }
}

/// One of a host's screens: its kind, its name and where it listens, and Open.
class _ScreenRow extends ConsumerWidget {
  const _ScreenRow({required this.screen, required this.onOpen});

  final ConnectionWithDetails screen;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final name = Redactable.host(hostScreenName(screen)).displayIn(ref);
    // Where it listens, as its own card says it (the host it is reached
    // through is the one this row is under).
    final where = screenCardSubtitleOf(screen.connection, labelOf: (_) => null, via: l10n.pfPageVia, withKind: false);
    return Container(
      key: ValueKey('host-screen-row-${screen.connection.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        color: ZestColors.chromeElevated,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderDefault),
      ),
      child: Row(
        children: [
          Container(
            height: 20,
            padding: const EdgeInsets.symmetric(horizontal: 5),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: ZestColors.surfaceChip,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: ZestColors.borderSubtle),
            ),
            child: Text(
              hostScreenKind(screen),
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: ZestColors.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
                const SizedBox(height: 2),
                Text(
                  Redactable.freeText(where).displayIn(ref),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: ZestColors.textTertiary),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            label: l10n.hostScreenOpenNamed(name),
            button: true,
            excludeSemantics: true,
            onTap: onOpen,
            child: ZestButton(
              key: ValueKey('host-screen-open-${screen.connection.id}'),
              label: l10n.hostsHomeMenuOpen,
              icon: LucideIcons.monitor,
              variant: ZestButtonVariant.secondary,
              size: ZestButtonSize.medium,
              onPressed: onOpen,
            ),
          ),
        ],
      ),
    );
  }
}
