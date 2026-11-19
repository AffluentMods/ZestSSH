import 'package:zestssh/services/connection_share_service.dart';
import 'dart:async' show unawaited;

import 'package:zestssh/features/hosts/phone/phone_hosts_view.dart';
import 'package:zestssh/features/hosts/phone/phone_host_selection.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/item_selection_bar.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/providers/pinned_hosts_provider.dart';
import 'package:zestssh/features/groups/widgets/phone_group_sheets.dart' show showNewHostOrGroupSheet;
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/features/keys/key_agent.dart' show canAddToSystemAgent;
import 'package:zestssh/features/keys/replace_key_view.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:zestssh/features/orchards/rules/reveal_gate.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/hosts/delete_host.dart' show deleteOneHost;
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/features/shortcuts/tablet_shortcuts.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/database/database.dart' show Connection, Identity, PortForwardRule, PortForwardRulesCompanion;
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/local_shell_service.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart' show isAppLockedProvider;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/cloud_reach_banner.dart';
import 'package:zestssh/ui/widgets/wake_host.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/screens/home/app_icon_shortcuts.dart';
import 'package:zestssh/utils/platform_utils.dart' show isLargeScreen;
import 'package:zestssh/ui/screens/home/widgets/quick_connect_bar.dart';
import 'package:zestssh/ui/screens/home/widgets/more_tab.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/terminal/session_swipe.dart'
    show SessionsTabHost, listedInSessionsTab, sessionsTabHost;
import 'package:zestssh/utils/host_search.dart';
import 'package:zestssh/ui/screens/port_forward/network_bind_confirm.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/services/shortcut_service.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/features/networks/widgets/current_network_banner.dart';
import 'package:zestssh/features/notifications/widgets/mobile_notification_bell.dart';
import 'package:zestssh/features/onboarding/widgets/get_connected_options.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_bottom_nav.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/widgets/crate_filter_chips.dart';
import 'package:zestssh/features/orchards/widgets/space_switcher_sheet.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart' show hostsByIdProvider;
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_first_steps.dart' show KeysFirstStepsList;
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart'
    show IdentityEditScreen, InitialImportedKey, KeySetupDialog;
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/screens/identity/key_users.dart';
import 'package:zestssh/l10n/time_text.dart';

/// Whether Home has a phone's tabs (3.1): Hosts, Sessions, Manage, Monitor
/// and More, wherever the screen is not a large screen (4.0: below it
/// the phone's tabs exactly, a small tablet held
/// upright included; a large screen has the computer's shell). The 3.0
/// tablet tabs (Hosts, Snippets, Sessions, Monitor, More) are gone.
bool usesPhoneTabs(BuildContext context) => !isLargeScreen(MediaQuery.sizeOf(context));

/// The two parts of a phone's Manage tab.
enum ManageSection { keys, portForwards }

/// A part of the Manage tab asked for from elsewhere (the Keys and Port
/// forwarding pages' routes, which a phone has as its Manage tab): Home
/// shows it, and clears this.
final manageSectionWanted = ValueNotifier<ManageSection?>(null);

/// The page of the Keys or the Port forwarding route: where Home has the
/// phone's tabs, Home's Manage tab on that part (the route leaves at once for
/// Home); on a large screen the full page.
Page<void> manageSectionPage(BuildContext context, GoRouterState state, ManageSection section) {
  if (usesPhoneTabs(context)) {
    return NoTransitionPage<void>(key: state.pageKey, child: _OpenManageSection(section));
  }
  return MaterialPage<void>(
    key: state.pageKey,
    name: state.name ?? state.path,
    arguments: <String, String>{...state.pathParameters, ...state.uri.queryParameters},
    restorationId: state.pageKey.value,
    child: section == ManageSection.keys ? const KeysPhoneScreen() : const PortForwardsPhoneScreen(),
  );
}

/// Asks Home for the Manage tab on [section], and goes there.
class _OpenManageSection extends StatefulWidget {
  const _OpenManageSection(this.section);

  final ManageSection section;

  @override
  State<_OpenManageSection> createState() => _OpenManageSectionState();
}

class _OpenManageSectionState extends State<_OpenManageSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      manageSectionWanted.value = widget.section;
      context.go(Routes.home);
    });
  }

  @override
  Widget build(BuildContext context) => ColoredBox(color: Theme.of(context).scaffoldBackgroundColor);
}

/// Home's tabs.
enum _Tab { hosts, sessions, manage, monitor, more }

/// The phone app's home (3.0 UI; 3.1): a standard tab
/// bar, Hosts first. A phone has Hosts, Sessions, Manage (Keys and Port
/// forwarding), Monitor and More (networks, Snippets, the terminal tools,
/// Settings, Account, help and, in an Orchard, the Team), on every screen
/// that is not a large screen, a small tablet's included (4.0; a
/// large screen has the computer's shell).
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static const _tabs = [_Tab.hosts, _Tab.sessions, _Tab.manage, _Tab.monitor, _Tab.more];

  /// The tab picked; Hosts first.
  _Tab _picked = _Tab.hosts;

  /// The tab on screen.
  _Tab get _selected => _picked;

  /// The part of the Manage tab on screen.
  final _manageSection = ValueNotifier<ManageSection>(ManageSection.keys);

  /// Bottom padding for scrollable content. Derived from the ACTUAL
  /// bottom-nav chrome - bar height + raised centre indicator + home-gesture
  /// inset + a floating-action-button allowance - instead of a hardcoded
  /// magic number, so the last row always clears the nav and the FAB and
  /// stays fully visible/tappable even on devices with a large gesture inset.
  static double scrollPaddingBottomFor(BuildContext context) =>
      ZestBottomNav.contentBottomPadding(context);

  @override
  void initState() {
    super.initState();

    // A host picked from the app icon's shortcuts: the one the app was
    // started with, and one picked while it runs.
    ShortcutService.pendingConnection.addListener(_shortcutSoon);
    _shortcutSoon();
    // A quick connect link's host goes into the quick connect bar, which is
    // on the list of hosts: that list is shown.
    quickConnectLinkText.addListener(_showHostsForLink);
    _showHostsForLink();
    // The quick connect field asked for by a keyboard's key (here, or from a
    // terminal): it is on the list of hosts, which is shown.
    quickConnectFocusWanted.addListener(_showHostsForQuickConnect);
    _showHostsForQuickConnect();
    // Keys or Port forwarding asked for (their routes, links): the Manage
    // tab on that part, on a phone.
    manageSectionWanted.addListener(_showManageSection);
    WidgetsBinding.instance.addPostFrameCallback((_) => _showManageSection());
    // The Manage tab's part decides what its selection's tab bar is (3.4);
    // another part ends the one being selected.
    _manageSection.addListener(_manageSectionChanged);
    // The app's keys from a keyboard plugged in or paired (TabletShortcut).
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  void _showHostsForLink() {
    if (!mounted || quickConnectLinkText.value == null || _picked == _Tab.hosts) return;
    _onTabSelected(_Tab.hosts);
  }

  void _showHostsForQuickConnect() {
    if (!mounted || !quickConnectFocusWanted.value || _picked == _Tab.hosts) return;
    _onTabSelected(_Tab.hosts);
  }

  void _manageSectionChanged() {
    if (!mounted) return;
    ref.read(keySelectionProvider.notifier).exit();
    ref.read(forwardSelectionProvider.notifier).exit();
    setState(() {});
  }

  /// The kind of items the tab on screen lists and may be selecting (3.4):
  /// keys or port forwards on the Manage tab.
  String? get _itemKind => switch (_selected) {
        _Tab.manage => _manageSection.value == ManageSection.keys ? TransferKinds.key : TransferKinds.forward,
        _ => null,
      };

  void _showManageSection() {
    final section = manageSectionWanted.value;
    if (!mounted || section == null) return;
    manageSectionWanted.value = null;
    _manageSection.value = section;
    _onTabSelected(_Tab.manage);
  }

  /// A key from a keyboard, while Home is in front and no text field has the
  /// keyboard: New connection, Quick connect, Find (the hosts' search, which
  /// is the quick connect field) and Settings, at a computer's keys with Cmd
  /// on an iPad and Ctrl on Android ([TabletShortcut]). A phone's and a
  /// tablet's Home had no keys.
  bool _onKey(KeyEvent event) {
    if (!mounted || textFieldHasKeyboard()) return false;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;
    final shortcut = tabletShortcutFor(event, among: const [
      TabletShortcut.newConnection,
      TabletShortcut.quickConnect,
      TabletShortcut.find,
      TabletShortcut.settings,
    ]);
    switch (shortcut) {
      case TabletShortcut.newConnection:
        if (!mayAddScreenSpace(ref, watch: false)) return false;
        _addConnection();
      case TabletShortcut.quickConnect:
      case TabletShortcut.find:
        quickConnectFocusWanted.value = true;
      case TabletShortcut.settings:
        context.push(Routes.settings);
      default:
        return false;
    }
    return true;
  }

  void _shortcutSoon() => Future.microtask(_handleShortcutLaunch);

  /// Connects to the host of a shortcut picked from the app icon (Android's
  /// app shortcuts, an iPhone's quick actions) as a tap in the list does,
  /// once the app is open and its hosts are loaded. It was read once, as this
  /// screen started, and lost where the hosts had not loaded yet; one picked
  /// while the app ran did nothing.
  void _handleShortcutLaunch() {
    if (!mounted) return;
    connectAppIconShortcut(ref, _connectTo);
  }

  @override
  void dispose() {
    ShortcutService.pendingConnection.removeListener(_shortcutSoon);
    quickConnectLinkText.removeListener(_showHostsForLink);
    quickConnectFocusWanted.removeListener(_showHostsForQuickConnect);
    manageSectionWanted.removeListener(_showManageSection);
    _manageSection.removeListener(_manageSectionChanged);
    _manageSection.dispose();
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // The app icon's shortcuts follow the hosts (mobile only; Squeezed).
    keepAppIconShortcuts(ref);
    // A shortcut's host waits for the hosts to load and for the app to open.
    ref.listen(connectionsWithDetailsProvider, (_, next) {
      if (next.hasValue) _shortcutSoon();
    });
    ref.listen<bool>(isAppLockedProvider, (_, locked) {
      if (!locked) _shortcutSoon();
    });

    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.watch(activeSessionsProvider);
    final live = sessions.values
        .where((s) => s.status == SessionStatus.connecting || s.status == SessionStatus.connected)
        .length;
    // In an Orchard, More says when the Team needs someone (as the desktop
    // rail's Team item): people wait to be added, or keys to be replaced.
    final orchard = kOrchardsEnabled ? ref.watch(activeOrchardProvider).valueOrNull : null;
    final teamAttention = orchard != null && (orchard.invitesWaiting > 0 || orchard.keysWaiting);

    const tabs = _tabs;
    final selected = _selected;
    // Server Monitor brings its own bar (refresh, sort, its setup guide), as
    // the Manage tab does (its search, its "+", its guide).
    final ownBar = selected == _Tab.monitor || selected == _Tab.manage;
    // Hosts selected on the Hosts tab (3.4): the top bar
    // says how many and selects every host shown; the tab bar is the
    // selection's actions; back ends it.
    final selecting = selected == _Tab.hosts && ref.watch(hostMultiSelectProvider).active;
    // Keys or port forwards selected (3.4), the hosts' way: the tab bar is
    // the selection's actions, back ends it. (The Manage tab's own bar says
    // how many.)
    final itemKind = _itemKind;
    final itemSelecting = itemKind != null && ref.watch(itemSelectionProvider(itemKind)).active;
    return PopScope(
      canPop: !selecting && !itemSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) ref.read(hostMultiSelectProvider.notifier).exit();
        if (!didPop && itemSelecting) ref.read(itemSelectionProvider(itemKind).notifier).exit();
      },
      child: Scaffold(
      appBar: selecting
          ? const PhoneHostSelectionAppBar()
          : (ownBar
              ? null
              : (itemSelecting ? PhoneItemSelectionAppBar(kind: itemKind) : _buildAppBar())),
      // With no bar of this screen's above them (the Monitor tab, and a
      // phone's Manage tab), the status bar's height is kept once, over the
      // tab's own bar, and taken off what is under it (the Monitor screen's
      // own bar kept it again: a gap). Those tabs put Home's banners under
      // their own bar, as every other tab has them under its title (they sat
      // above it, found in a design audit). (The same widgets on
      // every tab, so that no tab loses what it holds when the Monitor tab
      // comes and goes.)
      body: Builder(
        builder: (context) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: _statusBarStyle(context),
          child: Padding(
            padding: EdgeInsets.only(top: ownBar ? MediaQuery.paddingOf(context).top : 0),
            child: MediaQuery.removePadding(
              context: context,
              removeTop: ownBar,
              child: Column(
        children: [
          // The update banner is desktop-only: mobile users update through the
          // Play Store / App Store, so it is intentionally not mounted here.
          // Home's banners over the tabs, under the bar; a tab with a bar of
          // its own has them under that ([_HomeBanners]).
          ownBar ? const SizedBox.shrink() : const _HomeBanners(),
          Expanded(
            child: _LazyTabs(
              selected: selected,
              tabs: {
                for (final tab in tabs)
                  tab: switch (tab) {
                    _Tab.hosts => () => _HostsTab(
                          onConnect: _connectTo,
                          onConnectAs: (item, account) => _connectTo(item, asAccount: account),
                          onAddConnection: _addConnection,
                          onLaunchDemo: _launchDemo,
                        ),
                    _Tab.sessions => () => _SessionsTab(
                          onResume: _resumeSession,
                          onOpenSession: _openSession,
                        ),
                    _Tab.manage => () => ManageTab(section: _manageSection, underBar: const _HomeBanners()),
                    _Tab.monitor => () => const ServerMonitorScreen(underBar: _HomeBanners()),
                    // In the same centred column on a tablet, as the
                    // other tabs (it ran the full width: found 5 November
                    // 2026); a phone's is its whole width.
                    _Tab.more => () => const PhonePageColumn(child: MoreTab()),
                  },
              },
            ),
          ),
        ],
              ),
            ),
          ),
        ),
      ),
      floatingActionButton: selecting || itemSelecting ? null : _buildFab(),
      bottomNavigationBar: itemSelecting
          ? PhoneItemSelectionBar(
              kind: itemKind,
              onItemActions: switch (itemKind) {
                TransferKinds.key => (id) => openPhoneKeySheet(context, ref, id),
                _ => null,
              },
            )
          : selecting
          ? PhoneHostSelectionBar(
              onOpened: () => _onTabSelected(_Tab.sessions),
              onHostActions: (item) => showPhoneHostSheet(
                context,
                ref,
                item,
                phoneHostActionsFor(context, ref, item,
                    onConnect: _connectTo, onConnectAs: (item, account) => _connectTo(item, asAccount: account)),
                pinned: ref.read(pinnedHostsProvider).contains(item.connection.id),
              ),
            )
          : ZestBottomNav(
        selectedIndex: tabs.indexOf(selected),
        onDestinationSelected: (i) => _onTabSelected(tabs[i]),
        items: [
          for (final tab in tabs)
            switch (tab) {
              _Tab.hosts => ZestNavItem(
                  icon: LucideIcons.server, selectedIcon: LucideIcons.server, label: l10n.narrowSidebarHosts),
              _Tab.sessions => ZestNavItem(
                  icon: LucideIcons.terminalSquare,
                  selectedIcon: LucideIcons.terminalSquare,
                  label: l10n.homeSessionsTab,
                  count: live,
                ),
              _Tab.manage => ZestNavItem(
                  icon: LucideIcons.keyRound, selectedIcon: LucideIcons.keyRound, label: l10n.narrowSidebarGroupManage),
              _Tab.monitor => ZestNavItem(
                  icon: LucideIcons.activity, selectedIcon: LucideIcons.activity, label: l10n.phoneTabMonitor),
              _Tab.more => ZestNavItem(
                  icon: LucideIcons.moreHorizontal,
                  selectedIcon: LucideIcons.moreHorizontal,
                  label: l10n.phoneTabMore,
                  attention: teamAttention,
                ),
            },
        ],
      ),
    ),
    );
  }

  // ─── App Bar ─────────────────────────────────────────────────────

  /// The status bar's icons over the Monitor tab, where no bar of this
  /// screen's is at the top to say them: as a bar there would.
  static SystemUiOverlayStyle _statusBarStyle(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.appBarTheme.systemOverlayStyle;
    if (style != null) return style;
    final under = theme.appBarTheme.backgroundColor ?? theme.colorScheme.surface;
    return (ThemeData.estimateBrightnessForColor(under) == Brightness.dark
            ? SystemUiOverlayStyle.light
            : SystemUiOverlayStyle.dark)
        .copyWith(statusBarColor: Colors.transparent);
  }

  PreferredSizeWidget _buildAppBar() {
    final l10n = AppLocalizations.of(context)!;
    // The Sessions tab's way to open one, beside its sessions: a "+" in the
    // bar, as every list page adds (3.0 UI review; it was a floating button
    // there). With no session, the empty tab's own button does it.
    final hasHosts = ref.watch(connectionsWithDetailsProvider).valueOrNull?.isNotEmpty ?? false;
    final hasSessions = ref.watch(activeSessionsProvider).values.any(_SessionsTabState.listed);
    final selected = _selected;
    return AppBar(
      title: selected == _Tab.hosts
          // Orchards (3.0): the Hosts tab's title is the space
          // switcher.
          ? (kOrchardsEnabled ? const MobileSpaceTitle() : _buildBrandTitle())
          : Text(_tabTitle),
      // The theme's neutral hairline under the bar, as on every page (the
      // tabs had an orange one). Hosts has no search of its own here: the
      // quick connect field over the list filters it.
      actions: [
        if (selected == _Tab.sessions && hasHosts && hasSessions)
          IconButton(
            key: const ValueKey('phone-open-session'),
            icon: const Icon(LucideIcons.plus),
            tooltip: l10n.phoneOpenSession,
            onPressed: _openSession,
          ),
        // A one-tap shell on the device itself, where it has one (Android):
        // an icon in the Hosts tab's bar (4.0:
        // it was a card of its own over the hosts).
        if (selected == _Tab.hosts && LocalShellService.isAvailable)
          IconButton(
            key: const ValueKey('phone-local-terminal'),
            icon: const Icon(LucideIcons.terminalSquare),
            tooltip: l10n.homeLocalTerminal,
            onPressed: _launchLocalShell,
          ),
        // Help & support, one tap from every tab (this app bar is shared across
        // the mobile tabs). Opens the support screen, where the Discord
        // community, FAQ, report-a-bug and email all live, so Discord sits
        // inside help rather than as its own button. Left of the bell, which
        // keeps the far-right slot as the app's own control.
        const _HelpButton(),
        const MobileNotificationBell(),
        const SizedBox(width: 4),
      ],
    );
  }

  String get _tabTitle {
    final l10n = AppLocalizations.of(context)!;
    return switch (_selected) {
      _Tab.sessions => l10n.homeSessionsTab,
      _Tab.manage => l10n.narrowSidebarGroupManage,
      _Tab.more => l10n.phoneTabMore,
      _ => l10n.appName,
    };
  }

  Widget _buildBrandTitle() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: Image.asset(
            'assets/ZestSSH.png',
            width: 30,
            height: 30,
          ),
        ),
        const SizedBox(width: 10),
        Text(
          AppLocalizations.of(context)!.appName,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 22,
            letterSpacing: -0.5,
          ),
        ),
      ],
    );
  }

  void _clearAllSearchQueries() {
    ref.read(connectionSearchQueryProvider.notifier).state = '';
  }

  // ─── Tab Selection ──────────────────────────────────────────────

  void _onTabSelected(_Tab tab) {
    setState(() {
      // Leaving Hosts ends its search, so the list is whole on return (the
      // quick connect field empties with it).
      if (tab != _Tab.hosts) _clearAllSearchQueries();
      _picked = tab;
    });
  }

  // ─── Floating Action Button ─────────────────────────────────────

  Widget? _buildFab() {
    final l10n = AppLocalizations.of(context)!;
    switch (_selected) {
      case _Tab.hosts:
        if (!mayAddScreenSpace(ref)) return null;
        // Its name is the button's own tooltip (a label around it named a
        // node above the button, and a screen reader reached the button
        // itself unnamed).
        return FloatingActionButton(
            key: const ValueKey('phone-new-host'),
            tooltip: l10n.homeAddNewConnection,
            // New host, or New group (3.0.1: groups are made on a phone
            // too; the + offers both, as a computer's New host menu). A group
            // made is picked in the list, to be filled (the New group chip
            // did that; the + took it over in 4.0).
            onPressed: () => showNewHostOrGroupSheet(
              context,
              onNewHost: _addConnection,
              onGroupMade: (group) => phoneGroupPickWanted.value = group.id,
            ),
            child: const Icon(LucideIcons.plus),
          );
      default:
        return null;
    }
  }

  /// Picks a host and connects to it (the Sessions tab's main action).
  Future<void> _openSession() async {
    final picked = await ConnectionPickerDialog.show(
      context,
      title: AppLocalizations.of(context)!.homeSelectConnection,
    );
    final item = picked.connection;
    if (item == null || !mounted) return;
    await _connectTo(item);
  }

  // ─── Connection Actions ────────────────────────────────────────

  void _addConnection() {
    context.push(Routes.connectionEdit);
  }

  /// [asAccount]: signed in with that one of the host's other accounts (3.0,
  /// accounts per host: "Connect as"); its default where null.
  Future<void> _connectTo(ConnectionWithDetails item, {String? asAccount}) async {
    final account = asAccount == item.connection.identityId ? null : asAccount;
    // ── Check for existing active/backgrounded session (of this account) ──
    final sessions = ref.read(activeSessionsProvider);
    final notifier = ref.read(activeSessionsProvider.notifier);
    final existing = sessions.entries
        .where((e) =>
            e.value.connectionId == item.connection.id &&
            notifier.accountOf(e.key) == account &&
            (e.value.status == SessionStatus.connected ||
             e.value.status == SessionStatus.connecting))
        .firstOrNull;

    if (existing != null) {
      // Resume existing session - don't start a new one
      context.push('/terminal/${existing.key}');
      return;
    }

    // ── Free tier: limit concurrent sessions, not saved connections ──
    final isPro = ref.read(isProProvider);
    if (!isPro) {
      // Counts only slots genuinely held: a session the user is closing frees
      // its slot at once, so they need not wait out the close delay to open
      // another (see [ActiveSessionsNotifier.occupiedSessionSlots]).
      final activeCount =
          ref.read(activeSessionsProvider.notifier).occupiedSessionSlots;
      if (activeCount >= freeSessionLimit) {
        final l10n = AppLocalizations.of(context)!;
        ScaffoldMessenger.of(context).showMaterialBanner(
          MaterialBanner(
            content: Text(l10n.homeFreeSessionLimit(freeSessionLimit)),
            actions: [
              TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                  context.push(Routes.upgrade);
                },
                child: Text(l10n.upgrade),
              ),
              TextButton(
                onPressed: () {
                  ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
                },
                child: Text(l10n.cancel),
              ),
            ],
          ),
        );
        return;
      }
    }

    // Warn the user before establishing a cleartext Telnet connection.
    if (item.connection.protocol == 'telnet') {
      final l10n = AppLocalizations.of(context)!;
      final proceed = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.warning,
        title: l10n.homeTelnetWarningTitle,
        body: l10n.homeTelnetWarningBody,
        confirmLabel: l10n.homeTelnetConnectAnyway,
      );
      if (proceed != true || !mounted) return;
    }

    // startSession is now non-blocking - returns the session ID immediately
    final sessionId = ref
        .read(activeSessionsProvider.notifier)
        .startSession(item.connection, asAccount: account);
    if (sessionId == null) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.homeFreeSessionLimitSnack(freeSessionLimit),
          actionLabel: AppLocalizations.of(context)!.upgrade,
          onAction: () => context.push(Routes.upgrade),
        );
      }
      return;
    }

    // (The host's last use is stamped by its session once it is connected,
    // as on a computer: stamped here, a connection that failed was "used",
    // and synced so to the other devices.)

    // Navigate to terminal immediately (shows "Connecting..." state)
    context.push('/terminal/$sessionId');
  }

  void _resumeSession(String sessionId) {
    context.push('/terminal/$sessionId');
  }

  /// Launch the built-in demo terminal (no real server required).
  void _launchDemo() {
    final now = DateTime.now();
    final demoConnection = Connection(
      id: '__demo__',
      label: AppLocalizations.of(context)!.homeDemoTerminalLabel,
      host: 'demo.zestssh.com',
      port: 22,
      colorIndex: 0,
      protocol: 'demo',
      zlibCompression: false,
      forwardAgent: false,
      compatibilityMode: false,
      keepAliveSeconds: 0,
      envVars: '',
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: now,
      updatedAt: now,
    );

    final sessionId = ref
        .read(activeSessionsProvider.notifier)
        .startSession(demoConnection, allowDuplicate: false);

    if (sessionId != null) {
      context.push('/terminal/$sessionId');
    }
  }

  /// Open an on-device local shell (Android only). The mobile counterpart to
  /// the desktop "TERMINAL" sub-action: synthesize an ephemeral `localShell`
  /// connection (host `localhost`, port 0) and open a session for it via the
  /// same [startSession] path everything else uses - the `_createShell`
  /// dispatch returns a real-PTY [LocalShellService] for `protocol ==
  /// 'localShell'`. A unique id means each tap opens a fresh shell.
  void _launchLocalShell() {
    final now = DateTime.now();
    final localConnection = Connection(
      id: 'local_${now.millisecondsSinceEpoch}',
      label: AppLocalizations.of(context)!.homeLocalShellLabel,
      host: 'localhost',
      port: 0,
      colorIndex: 0,
      protocol: 'localShell',
      zlibCompression: false,
      forwardAgent: false,
      compatibilityMode: false,
      keepAliveSeconds: 0,
      envVars: '',
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: now,
      updatedAt: now,
    );

    final sessionId = ref
        .read(activeSessionsProvider.notifier)
        .startSession(localConnection, space: const TreeSpace());
    if (sessionId == null) {
      // Free-tier concurrent-session cap hit - surface it (like _connectTo)
      // rather than failing silently.
      if (context.mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.homeFreeSessionLimitSnack(freeSessionLimit),
          actionLabel: AppLocalizations.of(context)!.upgrade,
          onAction: () => context.push(Routes.upgrade),
        );
      }
      return;
    }
    context.push('/terminal/$sessionId');
  }

}

// ═══════════════════════════════════════════════════════════════════
//  TAB 0 - Sessions
// ═══════════════════════════════════════════════════════════════════

class _SessionsTab extends ConsumerStatefulWidget {
  final void Function(String sessionId) onResume;
  final VoidCallback onOpenSession;

  const _SessionsTab({
    required this.onResume,
    required this.onOpenSession,
  });

  @override
  ConsumerState<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends ConsumerState<_SessionsTab> {
  /// The sessions the tab lists: live ones, and ones that dropped, so they
  /// can be reconnected or cleared from here.
  /// (The terminal's swipe between sessions keeps this order: 3.1.)
  static bool listed(SessionState s) => listedInSessionsTab(s);

  /// Whether the bulk-selection mode is active (entered via long-press).
  bool _selectionMode = false;

  /// Session ids currently selected for a bulk action.
  final Set<String> _selected = {};

  // ── Selection-mode state transitions ──────────────────────────────

  void _enterSelection(String sessionId) {
    haptic(ref, Haptic.medium);
    setState(() {
      _selectionMode = true;
      _selected.add(sessionId);
    });
  }

  void _exitSelection() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggle(String sessionId) {
    setState(() {
      if (!_selected.remove(sessionId)) _selected.add(sessionId);
    });
  }

  void _toggleGroup(List<String> ids, bool select) {
    setState(() {
      if (select) {
        _selected.addAll(ids);
      } else {
        _selected.removeAll(ids);
      }
    });
  }

  void _selectAll(List<String> visibleIds) {
    setState(() {
      _selectionMode = true;
      _selected.addAll(visibleIds);
    });
  }

  void _selectAllDisconnected() {
    final sessions = ref.read(activeSessionsProvider);
    setState(() {
      _selectionMode = true;
      for (final e in sessions.entries) {
        if (e.value.status == SessionStatus.disconnected) {
          _selected.add(e.key);
        }
      }
    });
  }

  // ── Bulk operations wired to the real per-session ops ─────────────

  /// Disconnect = drop the SSH connection but KEEP the entries.
  Future<void> _bulkDisconnect() async {
    final sessions = ref.read(activeSessionsProvider);
    final ids = _selected.where(sessions.containsKey).toList();
    if (ids.isEmpty) return;
    final notifier = ref.read(activeSessionsProvider.notifier);
    for (final id in ids) {
      await notifier.disconnectSession(id);
    }
    if (mounted) _exitSelection();
  }

  /// Close = end the session and remove the entry. A confirm is shown only
  /// when the selection includes LIVE (connected/connecting) sessions -
  /// the count-in-action label makes the ordinary (already-disconnected)
  /// cleanup case self-explanatory.
  Future<void> _bulkClose() async {
    final l10n = AppLocalizations.of(context)!;
    final sessions = ref.read(activeSessionsProvider);
    final ids = _selected.where(sessions.containsKey).toList();
    if (ids.isEmpty) return;

    final liveCount = ids.where((id) {
      final s = sessions[id];
      return s != null &&
          (s.status == SessionStatus.connected ||
              s.status == SessionStatus.connecting);
    }).length;

    if (liveCount > 0) {
      final confirmed = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: l10n.sessionsBulkCloseConfirmTitle(ids.length),
        body: l10n.sessionsBulkCloseConfirmBody(liveCount),
        confirmLabel: l10n.close,
      );
      if (confirmed != true) return;
    }

    final notifier = ref.read(activeSessionsProvider.notifier);
    for (final id in ids) {
      await notifier.endSession(id);
    }
    if (mounted) _exitSelection();
  }

  // ── Build ──────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final sessions = ref.watch(activeSessionsProvider);
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);

    // Show live AND lingering disconnected sessions so the latter can be
    // cleaned up / reconnected in bulk from here.
    final visible = sessions.entries.where((e) => listed(e.value)).toList();

    // Keep the selection in sync with what is actually on screen.
    final visibleIds = visible.map((e) => e.key).toSet();
    _selected.retainWhere(visibleIds.contains);

    if (visible.isEmpty) {
      if (_selectionMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _selectionMode) _exitSelection();
        });
      }
      return _buildEmptyState(context);
    }

    // Build connection lookup.
    final connectionMap = <String, ConnectionWithDetails>{};
    if (connectionsAsync.hasValue) {
      for (final c in connectionsAsync.value!) {
        connectionMap[c.connection.id] = c;
      }
    }

    // Group entries by host (its name, with its address), preserving
    // first-seen order.
    final groupOrder = <SessionsTabHost>[];
    final groups = <SessionsTabHost, List<MapEntry<String, SessionState>>>{};
    for (final entry in visible) {
      final connId =
          entry.value.connectionId ?? entry.value.session?.connectionId;
      final conn = connId != null ? connectionMap[connId] : null;
      final key = _hostKeyFor(context, entry.value, conn);
      if (!groups.containsKey(key)) {
        groups[key] = [];
        groupOrder.add(key);
      }
      groups[key]!.add(entry);
    }

    final selectedCount = _selected.length;
    final hasDisconnected = visible
        .any((e) => e.value.status == SessionStatus.disconnected);

    final children = <Widget>[];
    for (final key in groupOrder) {
      final entries = groups[key]!;
      children.add(_buildGroupHeader(context, key, entries));
      for (final (index, entry) in entries.indexed) {
        final sessionId = entry.key;
        final sessionState = entry.value;
        final connId =
            sessionState.connectionId ?? sessionState.session?.connectionId;
        final conn = connId != null ? connectionMap[connId] : null;
        children.add(_SessionCard(
          key: ValueKey('session-row-$sessionId'),
          sessionId: sessionId,
          sessionState: sessionState,
          host: key,
          // Two or more to one host: each numbered, in the order they were
          // opened, so the rows are told apart (two read "web-01" alike).
          number: entries.length > 1 ? index + 1 : null,
          connectionDetails: conn,
          selectionMode: _selectionMode,
          selected: _selected.contains(sessionId),
          onLongPress: () => _enterSelection(sessionId),
          onTap: () {
            if (_selectionMode) {
              _toggle(sessionId);
            } else {
              widget.onResume(sessionId);
            }
          },
        ));
      }
    }

    return PopScope(
      canPop: !_selectionMode,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selectionMode) _exitSelection();
      },
      child: Column(
        children: [
          if (_selectionMode)
            _buildSelectionBar(
              context,
              selectedCount,
              visibleIds.toList(),
              hasDisconnected,
            ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                  bottom: _HomeScreenState.scrollPaddingBottomFor(context)),
              children: children,
            ),
          ),
        ],
      ),
    );
  }

  /// The host a session is grouped under: its name with its address (a host
  /// with no name by its address, then a localized "Unknown").
  SessionsTabHost _hostKeyFor(
          BuildContext context, SessionState s, ConnectionWithDetails? conn) =>
      sessionsTabHost(s, conn, AppLocalizations.of(context)!.homeUnknown);

  Widget _buildSelectionBar(
    BuildContext context,
    int selectedCount,
    List<String> visibleIds,
    bool hasDisconnected,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final enabled = selectedCount > 0;
    return Material(
      color: AppColors.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                icon: const Icon(LucideIcons.arrowLeft),
                tooltip: l10n.sessionsBulkExit,
                onPressed: _exitSelection,
              ),
              Expanded(
                child: Text(
                  l10n.sessionsBulkSelectedCount(selectedCount),
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                ),
              ),
              if (hasDisconnected)
                IconButton(
                  icon: const Icon(LucideIcons.unlink),
                  tooltip: l10n.sessionsBulkSelectAllDisconnected,
                  onPressed: _selectAllDisconnected,
                ),
              IconButton(
                icon: const Icon(LucideIcons.boxSelect),
                tooltip: l10n.sessionsBulkSelectAll,
                onPressed: () => _selectAll(visibleIds),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: enabled ? _bulkDisconnect : null,
                    icon: const Icon(LucideIcons.power, size: 18),
                    label: Text(
                      l10n.sessionsBulkDisconnect(selectedCount),
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppColors.warning,
                      side: BorderSide(
                          color: AppColors.warning.withValues(alpha: 0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: enabled ? _bulkClose : null,
                    icon: const Icon(LucideIcons.x, size: 18),
                    label: Text(
                      l10n.sessionsBulkClose(selectedCount),
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.error,
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: AppColors.divider.withValues(alpha: 0.4)),
        ],
      ),
    );
  }

  /// A host's sessions under its name, its address under that (it was the
  /// raw address alone), and how many.
  Widget _buildGroupHeader(
    BuildContext context,
    SessionsTabHost host,
    List<MapEntry<String, SessionState>> entries,
  ) {
    final l10n = AppLocalizations.of(context)!;
    final ids = entries.map((e) => e.key).toList();
    final selectedInGroup = ids.where(_selected.contains).length;
    final allSelected = selectedInGroup == ids.length;
    final noneSelected = selectedInGroup == 0;
    final connection = ref.read(hostsByIdProvider)[entries.first.value.connectionId]?.connection;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 12, 4),
      child: Row(
        children: [
          if (_selectionMode)
            Semantics(
              label: l10n.sessionsBulkSelectGroup,
              child: SizedBox(
                width: 24,
                height: 24,
                child: Checkbox(
                  value: allSelected ? true : (noneSelected ? false : null),
                  tristate: true,
                  activeColor: AppColors.brandOrange,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  onChanged: (_) => _toggleGroup(ids, !allSelected),
                ),
              ),
            )
          else if (connection != null)
            HostGlyph(host: connection, size: 18)
          else
            Icon(LucideIcons.server,
                size: 14, color: AppColors.textSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // The host's name in the app's own type; its address under
                // it in monospace, a value to copy (3.0). A host
                // with no name goes by its address.
                if (host.name.isNotEmpty)
                  RedactedText(
                    key: const ValueKey('sessions-group-name'),
                    Redactable.host(host.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: ZestTokens.textPrimary,
                    ),
                  ),
                if (host.address.isNotEmpty)
                  RedactedText(
                    key: const ValueKey('sessions-group-address'),
                    Redactable.address(host.address),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: host.name.isEmpty ? 12.5 : 11.5,
                      fontWeight: host.name.isEmpty ? FontWeight.w600 : null,
                      color: host.name.isEmpty ? ZestTokens.textSecondary : ZestTokens.textTertiary,
                      fontFamily: 'JetBrainsMono',
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 6),
          // How many: plain text, not a chip (chips are for filters and what
          // needs someone).
          Text(
            '${entries.length}',
            key: const ValueKey('sessions-group-count'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.terminal,
      iconSize: 56,
      title: l10n.homeNoActiveSessions,
      message: l10n.homeNoActiveSessionsDesc,
      actionLabel: l10n.phoneOpenSession,
      onAction: widget.onOpenSession,
    );
  }
}

/// One session in the Sessions tab, under its host's name with its address:
/// the name again, numbered where the host has more than one, when it
/// started, and how it is. One whose connection has gone is greyed, as a host
/// that cannot be picked is (two rows
/// read "web-01" alike, and the host's colour stood as a bar at the edge of
/// every row, an orange bar on rows that were Disconnected).
class _SessionCard extends ConsumerWidget {
  final String sessionId;
  final SessionState sessionState;

  /// The host it is grouped under, whose name the row says.
  final SessionsTabHost host;

  /// Which of its host's sessions it is, in the order they were opened,
  /// where the host has more than one.
  final int? number;
  final ConnectionWithDetails? connectionDetails;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final bool selectionMode;
  final bool selected;

  const _SessionCard({
    super.key,
    required this.sessionId,
    required this.sessionState,
    required this.host,
    this.number,
    required this.connectionDetails,
    required this.onTap,
    required this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // The host's name, masked while a screen is recorded.
    final name = (host.name.isEmpty ? Redactable.address(host.address) : Redactable.host(host.name)).displayIn(ref);
    final isConnected = sessionState.status == SessionStatus.connected;
    final isConnecting = sessionState.status == SessionStatus.connecting;
    final isDisconnected = sessionState.status == SessionStatus.disconnected;
    // When it started, kept after its connection has gone; how long it has
    // been connected, while it is.
    final startedAt = sessionState.startedAt;
    final liveSince = sessionState.session?.startedAt;
    final status = isConnecting
        ? (l10n.homeConnectingStatus, AppColors.accentInk)
        : isConnected && liveSince != null
            ? (_formatDuration(context, DateTime.now().difference(liveSince)), AppColors.success)
            : isDisconnected
                ? (l10n.sessionsBulkStatusDisconnected, AppColors.textSecondary)
                : null;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: selected
            ? AppColors.brandOrange.withValues(alpha: 0.10)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: selected
            ? Border.all(color: AppColors.brandOrange, width: 1.5)
            : isConnected
                ? Border.all(
                    color: AppColors.success.withValues(alpha: 0.25),
                    width: 1,
                  )
                : null,
        boxShadow: [
          if (isConnected)
            BoxShadow(
              color: AppColors.success.withValues(alpha: 0.06),
              blurRadius: 10,
              spreadRadius: 1,
            )
          else
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        // A right click (a mouse on a tablet or a phone) does what a long
        // press does: the card selected, and the bar of what can be done
        // with the selected ones. It did nothing.
        onSecondaryTap: onLongPress,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Selection indicator (bulk mode): several can be picked, so a
              // check, not a radio.
              if (selectionMode) ...[
                Icon(
                  selected
                      ? LucideIcons.checkCircle2
                      : LucideIcons.circle,
                  size: 22,
                  color: selected
                      ? AppColors.accentInk
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: 12),
              ],

              Expanded(
                child: Opacity(
                  key: ValueKey('session-dim-$sessionId'),
                  opacity: isDisconnected ? 0.55 : 1,
                  child: Row(
                    children: [
                      // Status indicator (pulsing for connected)
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: isConnecting
                              ? AppColors.brandOrange
                              : isConnected
                                  ? AppColors.success
                                  : AppColors.textSecondary,
                          shape: BoxShape.circle,
                          boxShadow: [
                            if (isConnected)
                              BoxShadow(
                                color: AppColors.success.withValues(alpha: 0.5),
                                blurRadius: 10,
                                spreadRadius: 1,
                              ),
                            if (isConnecting)
                              BoxShadow(
                                color: AppColors.brandOrange.withValues(alpha: 0.4),
                                blurRadius: 8,
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 14),

                      // The host's own icon.
                      if (connectionDetails != null) ...[
                        HostGlyph(host: connectionDetails!.connection, group: connectionDetails!.group, size: 28),
                        const SizedBox(width: 12),
                      ],

                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              number == null ? name : l10n.sessionsTabNumbered(name, number!),
                              key: ValueKey('session-title-$sessionId'),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w600),
                            ),
                            if (startedAt != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                plainTimeSpaces(l10n.sessionsTabStarted(startedAt)),
                                key: ValueKey('session-started-$sessionId'),
                                style: TextStyle(
                                  color: AppColors.textSecondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                            if (status != null) ...[
                              const SizedBox(height: 2),
                              Text(
                                status.$1,
                                style: TextStyle(
                                  color: status.$2,
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),

                      Icon(LucideIcons.chevronRight,
                          color: AppColors.textSecondary),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// How long the session has been connected: the shared compact length
  /// ("Connected 2h 5m"), just now under a minute.
  String _formatDuration(BuildContext context, Duration duration) {
    final l10n = AppLocalizations.of(context)!;
    if (duration.inMinutes < 1) return l10n.homeConnectedJustNow;
    return l10n.homeConnectedFor(durationWords(l10n, duration));
  }
}

// ═══════════════════════════════════════════════════════════════════
//  TAB 0 - Hosts
// ═══════════════════════════════════════════════════════════════════

/// The Hosts tab: the quick connect field, which searches too, and every host
/// (the local terminal, where the device has one, is an icon in the bar).
class _HostsTab extends StatelessWidget {
  const _HostsTab({
    required this.onConnect,
    required this.onAddConnection,
    required this.onLaunchDemo,
    this.onConnectAs,
  });

  final void Function(ConnectionWithDetails) onConnect;
  final void Function(ConnectionWithDetails item, String account)? onConnectAs;
  final VoidCallback onAddConnection;
  final VoidCallback onLaunchDemo;

  @override
  Widget build(BuildContext context) {
    // On a tablet, the search and the list in the one centred column a phone
    // page takes there, on one left edge (the search ran the full width over
    // the centred list).
    return PhonePageColumn(
      key: const ValueKey('phone-hosts-column'),
      child: Column(
        key: const ValueKey('phone-hosts'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const QuickConnectBar(),
          Expanded(
            child: _ConnectionsList(
              onConnect: onConnect,
              onConnectAs: onConnectAs,
              onAddConnection: onAddConnection,
              onLaunchDemo: onLaunchDemo,
            ),
          ),
        ],
      ),
    );
  }
}

/// The tabs' pages: each is built the first time it is opened and kept
/// after, so a list keeps its place; only the one on screen is shown.
class _LazyTabs extends StatefulWidget {
  const _LazyTabs({required this.selected, required this.tabs});

  final _Tab selected;

  /// The tabs this screen has, in their order, each built when first shown.
  final Map<_Tab, Widget Function()> tabs;

  @override
  State<_LazyTabs> createState() => _LazyTabsState();
}

class _LazyTabsState extends State<_LazyTabs> {
  final _built = <_Tab, Widget>{};

  @override
  void didUpdateWidget(_LazyTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A phone's tabs became a tablet's or back (a foldable opened or
    // closed): More, which both have, lists other rows.
    if (!listEquals(oldWidget.tabs.keys.toList(), widget.tabs.keys.toList())) _built.remove(_Tab.more);
  }

  @override
  Widget build(BuildContext context) {
    _built.putIfAbsent(widget.selected, () => widget.tabs[widget.selected]!());
    final order = widget.tabs.keys.toList();
    return IndexedStack(
      index: order.indexOf(widget.selected),
      children: [
        for (final tab in order)
          TickerMode(
            key: ValueKey(tab),
            enabled: tab == widget.selected,
            child: _built[tab] ?? const SizedBox.shrink(),
          ),
      ],
    );
  }
}

// ─── Connections Sub-tab ──────────────────────────────────────────

class _ConnectionsList extends ConsumerWidget {
  final void Function(ConnectionWithDetails) onConnect;
  final void Function(ConnectionWithDetails item, String account)? onConnectAs;
  final VoidCallback onAddConnection;
  final VoidCallback onLaunchDemo;

  const _ConnectionsList({
    required this.onConnect,
    this.onConnectAs,
    required this.onAddConnection,
    required this.onLaunchDemo,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);

    return connectionsAsync.when(
      data: (allConnections) {
        if (allConnections.isEmpty) return _buildEmptyState(context, ref);

        // Where its person turned on the checks of whether hosts can be
        // reached (Settings; off until then), ask for these hosts to be
        // checked when the list loads. Guard against widget disposal between
        // frame scheduling and callback.
        final healthChecksOn = ref.watch(healthChecksEnabledProvider);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            final health = ref.read(connectionHealthProvider.notifier);
            if (healthChecksOn) {
              health.startPeriodicChecks(
                allConnections.map((c) => c.connection).toList(),
              );
            } else {
              health.stopPeriodicChecks();
            }
          } catch (_) {
            // Widget was disposed before callback fired - safe to ignore.
          }
        });

        // Crates (3.0): an Orchard on screen shows one Crate's
        // hosts when one is picked.
        final orchard =
            kOrchardsEnabled ? ref.watch(activeOrchardProvider).valueOrNull : null;
        final crateFilter =
            orchard == null ? null : ref.watch(selectedCrateFilterProvider);
        final hostCrates = orchard == null
            ? const <String, String>{}
            : (ref.watch(hostCratesProvider).valueOrNull ?? const <String, String>{});
        // The app bar's search (it filtered nothing on phones before 3.0).
        final query = ref.watch(connectionSearchQueryProvider);
        final connections = [
          for (final c in allConnections)
            if ((orchard == null ||
                    crateFilter == null ||
                    crateOfHost(c.connection.id, hostCrates, orchard) == crateFilter) &&
                hostMatchesQuery(c, query))
              c,
        ];
        if (connections.isEmpty && query.trim().isNotEmpty) {
          return ZestEmptyState(
            key: const ValueKey('phone-hosts-no-match'),
            icon: LucideIcons.searchX,
            title: AppLocalizations.of(context)!.hostsFilterEmptyTitle(query.trim()),
          );
        }
        // What this account may do in the space on screen: watched, so the
        // rows' actions follow it (3.0).
        ItemRules.of(ref, 'host');
        mayAddScreenSpace(ref);

        // Sections of pinned hosts and each group, each host a row (3.0); a
        // tablet has them centred, in the tab's
        // column ([PhonePageColumn]).
        final list = Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: kPhonePageMaxWidth),
            child: PhoneHostsList(
              hosts: connections,
              bottomPadding: _HomeScreenState.scrollPaddingBottomFor(context),
              actionsOf: (item) => phoneHostActionsFor(context, ref, item, onConnect: onConnect, onConnectAs: onConnectAs),
            ),
          ),
        );
        if (orchard == null) return list;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: CrateFilterChips(),
            ),
            Expanded(child: list),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      // What could not be loaded says so with Try again and its details
      // (3.0: it said only that something went wrong).
      error: (error, stack) => LoadErrorState(
        message: AppLocalizations.of(context)!.homeSomethingWentWrong,
        where: 'Loading the hosts',
        error: error,
        stack: stack,
        onRetry: () => ref.invalidate(connectionsWithDetailsProvider),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // A skipped/returning empty grid offers the SAME four paths as the
    // first-run screen so getting connected is never a dead end here.
    return ZestEmptyState(
      icon: LucideIcons.server,
      iconSize: 56,
      // Room under the page for the + (New host or group), which floats over
      // its foot: scrolled to its end, the last card and the demo's button
      // clear it (they lay under it on a test device).
      padding: EdgeInsets.fromLTRB(
          32, 32, 32, mayAddScreenSpace(ref) ? ZestBottomNav.fabOverhang + 12 : 32),
      title: l10n.homeNoConnections2,
      message: l10n.homeNoConnectionsDesc2,
      action: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GetConnectedOptions(
              onImport: () => context.push(Routes.sshConfigImport),
              onScan: () => context.push(Routes.lanScan),
              onRestore: () => context.push(Routes.profile),
              onAdd: () => context.push(Routes.connectionEdit),
            ),
            const SizedBox(height: 8),
            // No server to hand: the demo terminal shows what a session is.
            TextButton.icon(
              key: const ValueKey('phone-try-demo'),
              onPressed: onLaunchDemo,
              icon: const Icon(LucideIcons.playCircle, size: 16),
              label: Text(l10n.homeTryDemoTerminal),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Identities Sub-tab ──────────────────────────────────────────

class _IdentitiesList extends ConsumerWidget {
  const _IdentitiesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final identitiesAsync = ref.watch(filteredIdentitiesProvider);
    final usageCounts =
        ref.watch(identityUsageCountsProvider).valueOrNull ?? {};
    final lastUsedMap =
        ref.watch(identityLastUsedProvider).valueOrNull ?? {};

    final selection = ref.watch(keySelectionProvider);
    return identitiesAsync.when(
      data: (identities) {
        if (identities.isEmpty) {
          publishShownItems(ref, TransferKinds.key, const []);
          return _buildEmptyState(context, ref);
        }
        // What this account may change among an Orchard's keys (3.0);
        // everything in your Tree.
        final keyRules = ItemRules.of(ref, 'key');
        final canAddKeys = mayAddScreenSpace(ref);

        // Group by type when 4+ identities
        final shouldGroup = identities.length >= 4;

        // A key's row, which selects (3.4): a long press starts selecting
        // with it, then a tap puts a key in or takes it out.
        Widget tile(Identity identity) => _IdentityTile(
              identity: identity,
              count: usageCounts[identity.id] ?? 0,
              lastUsed: lastUsedMap[identity.id],
              onDelete: keyRules.mayChange(identity.id, delete: true)
                  ? () => _confirmDelete(context, ref, identity, usageCounts[identity.id] ?? 0)
                  : null,
              onDuplicate: canAddKeys && IdentityCrudNotifier.canDuplicate(identity) ? () => _duplicateIdentity(context, ref, identity) : null,
              selecting: selection.active,
              selected: selection.isSelected(identity.id),
              onToggle: () {
                haptic(ref, Haptic.selection);
                ref.read(keySelectionProvider.notifier).toggle(identity.id);
              },
              onStartSelecting: () {
                haptic(ref, Haptic.medium);
                ref.read(keySelectionProvider.notifier).enter(identity.id);
              },
            );
        // Selected keys the search hides: said, with Show.
        final hidden = PhoneSelectionHiddenLine(
          kind: TransferKinds.key,
          onShow: () => ref.read(identitySearchQueryProvider.notifier).state = '',
        );

        if (shouldGroup) {
          // A key of any kind (a certificate, an agent's key) with the keys,
          // as a computer has them: only passwords were apart from keys.
          final keys = identities
              .where((i) => !isPasswordIdentity(i))
              .toList()
            ..sort((a, b) =>
                (usageCounts[b.id] ?? 0).compareTo(usageCounts[a.id] ?? 0));
          final passwords = identities
              .where(isPasswordIdentity)
              .toList()
            ..sort((a, b) =>
                (usageCounts[b.id] ?? 0).compareTo(usageCounts[a.id] ?? 0));
          publishShownItems(ref, TransferKinds.key, [for (final i in [...keys, ...passwords]) i.id]);

          return ListView(
            padding: EdgeInsets.only(
                bottom: _HomeScreenState.scrollPaddingBottomFor(context),
                top: 4),
            children: [
              hidden,
              if (keys.isNotEmpty) ...[
                _sectionHeader(const ValueKey('keys-section-keys'), l10n.homeSshKeysSection, keys.length),
                for (final identity in keys) tile(identity),
              ],
              if (passwords.isNotEmpty) ...[
                _sectionHeader(const ValueKey('keys-section-passwords'), l10n.homePasswordsSection, passwords.length),
                for (final identity in passwords) tile(identity),
              ],
              // Tip card when few identities
              if (identities.length < 3) _tipCard(context),
            ],
          );
        }

        // Flat list for < 4 identities
        publishShownItems(ref, TransferKinds.key, [for (final i in identities) i.id]);
        return ListView(
          padding: EdgeInsets.only(
              bottom: _HomeScreenState.scrollPaddingBottomFor(context),
              top: 4),
          children: [
            hidden,
            for (final identity in identities) tile(identity),
            if (identities.length < 3) _tipCard(context),
          ],
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => LoadErrorState(
        message: AppLocalizations.of(context)!.homeUnableToLoadIdentities,
        hint: AppLocalizations.of(context)!.homeTryRestartingApp,
        where: 'Loading the keys',
        error: error,
        stack: stack,
        onRetry: () => ref.invalidate(filteredIdentitiesProvider),
      ),
    );
  }

  /// A part of the list: the app's section header, as the hosts' and the
  /// computer's keys have it, in the theme's colours (it was a teal SSH KEYS
  /// and an amber PASSWORDS that no theme changed, found in a design
  /// audit).
  Widget _sectionHeader(Key key, String title, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: ZestSectionHeader(key: key, label: title, count: count),
    );
  }

  Widget _tipCard(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: ZestTokens.brandSubtle,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: ZestTokens.brandBorder),
        ),
        child: Row(
          children: [
            Icon(LucideIcons.lightbulb, color: ZestTokens.brandInk, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.homeIdentityTip,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref,
      Identity identity, int connectionCount) async {
    final l10n = AppLocalizations.of(context)!;
    // The hosts it leaves without a key, by name (up to five, then how many
    // more).
    final users = connectionCount > 0 ? await keyUsersLines(ref, l10n, identity.id) : const <String>[];
    if (!context.mounted) return;
    // The shell (the dialog rules of 3.4): red, for what cannot be undone.
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.homeDeleteIdentityTitle(Redactable.keyName(identity.label).display),
      body: connectionCount > 0 ? l10n.homeDeleteIdentityUsedBy(connectionCount) : l10n.homeDeleteIdentityUnused,
      bullets: users,
      confirmLabel: l10n.delete,
    );
    if (confirmed == true) {
      await ref.read(identityCrudProvider).delete(identity.id);
      if (context.mounted) {
        showTopSnackBar(context,
            l10n.homeIdentityDeleted(Redactable.keyName(identity.label).display));
      }
    }
  }

  Future<void> _duplicateIdentity(
      BuildContext context, WidgetRef ref, Identity identity) async {
    final l10n = AppLocalizations.of(context)!;
    // The copy carries what the key signs in with (it carried none: a copy
    // of a key had no private key and could not sign in), so it is made only
    // for a person who may see that: an Orchard key at Connect keeps its
    // secrets where they are.
    if (!await mayRevealKeyNow(ref, identity.id)) {
      if (context.mounted) showTopSnackBar(context, l10n.orchardWriteNotAllowed, isError: true);
      return;
    }
    if (await revealAsksAgainNow(ref, identity.id)) {
      if (!context.mounted || !await confirmItIsYou(context, ref)) return;
    }
    try {
      await ref.read(identityCrudProvider).duplicate(identity, label: l10n.homeCopyLabelSuffix(identity.label));
    } catch (e) {
      if (context.mounted) {
        final refused = isOrchardWriteRefused(e);
        showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.zestKeysNotSaved,
            isError: true, details: refused ? null : '$e');
      }
      return;
    }
    if (context.mounted) {
      showTopSnackBar(context,
          l10n.homeIdentityDuplicated(Redactable.keyName(identity.label).display));
    }
  }

  /// Nothing saved: the ways to add a first key as a list, as a computer's
  /// Keys page has them (4.0): generate, import, and
  /// a saved password. In a team vault this account may not add to, what
  /// the page is for, with nothing to start (its + is not there either).
  Widget _buildEmptyState(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (!mayAddScreenSpace(ref)) {
      return ZestEmptyState(
        icon: LucideIcons.keyRound,
        iconSize: 56,
        title: l10n.identityNoIdentities,
        message: l10n.identityNoIdentitiesDesc,
      );
    }
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: kPhonePageMaxWidth),
        child: KeysFirstStepsList(
          bottomPadding: _HomeScreenState.scrollPaddingBottomFor(context),
          onGenerate: () => KeyGenerationScreen.showAdaptive(context, initialFormat: KeyGenerationFormatHint.ed25519),
          onImport: () => unawaited(_importKeyFile(context, ref)),
          onNewPassword: () => context.push(Routes.identityEdit),
        ),
      ),
    );
  }

  /// Import a key file: the key setup at Import (Choose key file, Paste a
  /// tab away), then the key's form with the key it loaded, as a phone's
  /// Import from file leaves it.
  Future<void> _importKeyFile(BuildContext context, WidgetRef ref) async {
    final loaded = await KeySetupDialog.show(context, ref, initialTab: 2);
    if (loaded == null || !context.mounted) return;
    await IdentityEditScreen.showAdaptive(
      context,
      key: InitialImportedKey(
        privatePem: loaded.privatePem,
        fingerprint: loaded.fingerprint,
        keyType: loaded.keyType,
        passphrase: loaded.passphrase,
      ),
    );
  }
}

// ─── Identity Tile (rich card with swipe + long-press) ──────────

class _IdentityTile extends ConsumerWidget {
  final Identity identity;
  final int count;
  final DateTime? lastUsed;

  /// Null where this account may not do it (an Orchard key whose Crate
  /// does not let it): the action is not offered.
  final VoidCallback? onDelete;
  final VoidCallback? onDuplicate;

  /// Keys are being selected (3.4): the row has its box, and a tap or a long
  /// press puts it in or takes it out ([onToggle]).
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggle;

  /// A long press starts selecting, with this key; null: it opens the key's
  /// sheet, as before.
  final VoidCallback? onStartSelecting;

  const _IdentityTile({
    required this.identity,
    required this.count,
    this.lastUsed,
    required this.onDelete,
    required this.onDuplicate,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onStartSelecting,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isKey = !isPasswordIdentity(identity);
    // The key's own colour, where it has one, as a computer's list of keys
    // shows it; otherwise the theme's (a fixed teal for a key and amber for
    // a password, whatever the theme, found in a design audit).
    final hasColour = identity.colorValue != null || identity.colorIndex != 0;
    final labelColour = AppColors.labelColorFor(identity.colorValue, identity.colorIndex);

    // Avatar icon: the kind of sign-in it is (a certificate and an agent's
    // key were shown as a password, with a lock).
    final avatarIcon = switch (identity.authMethod) {
      'certificate' || 'teamCertificate' => LucideIcons.award,
      'hardwareToken' => LucideIcons.usb,
      'passwordManager' => LucideIcons.asterisk,
      'password' => LucideIcons.lock,
      _ => LucideIcons.keyRound,
    };

    // Usage label
    final usageLabel = count == 0
        ? l10n.identityNotInUse
        : count == 1
            ? l10n.identityOneConnection
            : l10n.identityConnectionCount(count);

    // Key comment from publicKeyData (last part after second space)
    String? keyComment;
    if (isKey && identity.publicKeyData != null) {
      final parts = identity.publicKeyData!.trim().split(' ');
      if (parts.length >= 3) {
        keyComment = parts.sublist(2).join(' ');
      }
    }

    // Fingerprint (first 20 chars). Masked as a whole in recording mode,
    // then shortened, so the fake keeps its recognisable prefix.
    String? fingerprint;
    if (isKey &&
        identity.publicKeyFingerprint != null &&
        identity.publicKeyFingerprint!.isNotEmpty) {
      final fp = Redactable.fingerprint(identity.publicKeyFingerprint!)
          .displayIn(ref);
      fingerprint = fp.length > 20 ? '${fp.substring(0, 20)}...' : fp;
    }

    // Last used, in the shared compact words, counting on past a week.
    final lastUsedText = lastUsed == null ? null : timeAgoWords(l10n, lastUsed!, keepCounting: true);

    // Key strength
    String? strengthLabel;
    var legacy = false;
    if (isKey && identity.keyType != null) {
      final kt = identity.keyType!.toLowerCase();
      if (kt.contains('ed25519')) {
        strengthLabel = l10n.homeKeyStrengthStrong;
      } else if (kt.contains('ecdsa')) {
        strengthLabel = l10n.homeKeyStrengthGood;
      } else if (kt.contains('rsa')) {
        // A key to replace: the one mark of its row that is a chip.
        strengthLabel = l10n.homeKeyStrengthLegacy;
        legacy = true;
      }
    }

    final card = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Material(
        color: selecting && selected ? Color.alphaBlend(phoneSelectedTint(), AppColors.surface) : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('phone-key-${identity.id}'),
          onTap: selecting ? onToggle : () => context.push('/identity/edit/${identity.id}'),
          onLongPress: selecting ? onToggle : (onStartSelecting ?? () => _showContextMenu(context, ref)),
          borderRadius: BorderRadius.circular(12),
          child: Row(
            children: [
              // The key's own colour along its edge, where it has one (the
              // room kept where it has none, so every row lines up).
              Container(
                key: ValueKey('key-edge-${identity.id}'),
                width: 4,
                height: 80,
                color: hasColour ? labelColour : null,
              ),
              if (selecting)
                Padding(
                  padding: const EdgeInsets.only(left: 12),
                  child: SelectBox(key: ValueKey('phone-key-box-${identity.id}'), checked: selected, size: 20),
                ),

              // Avatar
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
                child: CircleAvatar(
                  key: ValueKey('key-avatar-${identity.id}'),
                  radius: 24,
                  backgroundColor: hasColour
                      ? labelColour.withValues(alpha: count == 0 ? 0.08 : 0.14)
                      : ZestTokens.surfaceChip,
                  child: Icon(
                    avatarIcon,
                    color: count == 0
                        ? ZestTokens.textTertiary
                        : (hasColour ? labelColour : ZestTokens.textSecondary),
                    size: 24,
                  ),
                ),
              ),

              // Content
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Row 1: its name, and Legacy beside it where it is
                      // one.
                      Row(
                        children: [
                          Flexible(
                            child: RedactedText(
                              Redactable.keyName(identity.label),
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: count == 0
                                    ? AppColors.textSecondary
                                    : null,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // A legacy (RSA) key needs its person: the one
                          // status chip a key has (3.0: chips for
                          // what needs someone, the rest plain text).
                          if (legacy) ...[
                            const SizedBox(width: 6),
                            Container(
                              key: ValueKey('key-legacy-${identity.id}'),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: AppColors.warning.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                strengthLabel!,
                                style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.warning),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),

                      // Row 2: who it signs in as, its kind, how strong, and
                      // whether it is the default, as one line of plain text
                      // in the app's own type (a username is not a value to
                      // copy; the kind and strength were chips).
                      Text.rich(
                        TextSpan(children: [
                          TextSpan(text: Redactable.username(identity.username).displayIn(ref)),
                          TextSpan(text: ' · ${identityTypeLabel(l10n, identity)}'),
                          if (strengthLabel != null && !legacy) TextSpan(text: ' · $strengthLabel'),
                          if (identity.isDefault) TextSpan(text: ' · ${l10n.identityDefault}'),
                        ]),
                        key: ValueKey('key-meta-${identity.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
                      ),

                      // Row 3: fingerprint / key comment + usage + last used,
                      // in the theme's quieter text (they were its secondary
                      // text at half strength, which a dark theme left
                      // unreadable, found in a design audit).
                      const SizedBox(height: 3),
                      Row(
                        children: [
                          // Fingerprint for key identities
                          if (fingerprint != null) ...[
                            Flexible(
                              child: Text(
                                fingerprint,
                                key: ValueKey('key-fingerprint-${identity.id}'),
                                style: TextStyle(
                                  fontFamily: 'JetBrainsMono',
                                  fontSize: 11,
                                  color: ZestTokens.textTertiary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ] else if (keyComment != null) ...[
                            Flexible(
                              child: RedactedText(
                                // A key comment is usually `user@host`.
                                Redactable.keyComment(keyComment),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: ZestTokens.textTertiary,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                          if (fingerprint != null || keyComment != null)
                            const SizedBox(width: 6),
                          Text(
                            usageLabel,
                            style: TextStyle(
                              fontSize: 11,
                              color: count == 0
                                  ? ZestTokens.textTertiary
                                  : ZestTokens.textSecondary,
                            ),
                          ),
                          if (lastUsedText != null) ...[
                            Text(
                              ' · $lastUsedText',
                              style: TextStyle(
                                fontSize: 11,
                                color: ZestTokens.textTertiary,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // Chevron
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(LucideIcons.chevronRight,
                    size: 20, color: AppColors.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );

    // Swipe actions.
    //
    // Swipe-LEFT-to-delete was removed at the user's request: delete is
    // destructive and irreversible, and a left swipe is far too easy to
    // trigger by accident while scrolling. Delete remains available on the
    // long-press context menu ([_showContextMenu]). Only the non-destructive
    // swipe-RIGHT Duplicate shortcut is kept, so the gesture is now
    // restricted to that single direction.
    // No swipe while selecting: a row is in or out.
    if (onDuplicate == null || selecting) return card;
    return Dismissible(
      key: ValueKey(identity.id),
      direction: DismissDirection.startToEnd,
      background: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: BoxDecoration(
          color: ZestTokens.brandSubtle,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.copy, color: ZestTokens.brandInk),
            const SizedBox(width: 8),
            Text(l10n.commonDuplicate,
                style: TextStyle(
                    color: ZestTokens.brandInk, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
      confirmDismiss: (direction) async {
        onDuplicate?.call();
        return false; // Never actually dismiss - Duplicate keeps the row.
      },
      child: card,
    );
  }

  void _showContextMenu(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isKey = !isPasswordIdentity(identity);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      // Its seven actions are taller than a sheet's default height on a phone:
      // it takes the height it needs and scrolls on a short screen (Delete was
      // cut off).
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Title
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: RedactedText(
                  Redactable.keyName(identity.label),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 16),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(LucideIcons.pencil),
                title: Text(l10n.edit),
                onTap: () {
                  Navigator.pop(ctx);
                  context.push('/identity/edit/${identity.id}');
                },
              ),
              if (onDuplicate != null)
                ListTile(
                  leading: const Icon(LucideIcons.copy),
                  title: Text(l10n.commonDuplicate),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDuplicate!();
                  },
                ),
              // Its public line, kept or made from its private key (a key made
              // in the app kept none, and this was not offered for it).
              if (isKey && (identity.publicKeyData != null || identity.authMethod == 'publicKey'))
                ListTile(
                  leading: const Icon(LucideIcons.share2),
                  title: Text(l10n.homeSharePublicKey),
                  onTap: () async {
                    Navigator.pop(ctx);
                    // A key goes to the clipboard: reveal gate (spec 5).
                    if (!await confirmRevealWhileRecording(context, ref)) {
                      return;
                    }
                    final line = await ref.read(identityCrudProvider).publicLineOf(identity);
                    if (!context.mounted) return;
                    if (line == null) {
                      showTopSnackBar(context, l10n.zestKeysNoPublicKey, isError: true);
                      return;
                    }
                    await Clipboard.setData(ClipboardData(text: line));
                    if (context.mounted) showTopSnackBar(context, l10n.homePublicKeyCopied);
                  },
                ),
              // A key the vault holds (3.0, Keys): exported as OpenSSH files,
              // its passphrase added or changed (the dialog does what the key
              // needs), replaced on every host that signs in with it. A phone
              // has no system agent: Add to agent is the computer's.
              if (canAddToSystemAgent(identity)) ...[
                ListTile(
                  key: const ValueKey('phone-key-export'),
                  leading: const Icon(LucideIcons.download),
                  title: Text(l10n.keysActExport),
                  onTap: () {
                    Navigator.pop(ctx);
                    showKeyExport(context, ref, identity);
                  },
                ),
                if (mayChangeItem(ref, 'key', identity.id, watch: false)) ...[
                  ListTile(
                    key: const ValueKey('phone-key-passphrase'),
                    leading: const Icon(LucideIcons.lock),
                    title: Text(l10n.keysActPassphrase),
                    onTap: () {
                      Navigator.pop(ctx);
                      showKeyPassphrase(context, ref, identity, KeyPassphraseMode.add);
                    },
                  ),
                  if (count > 0)
                    ListTile(
                      key: const ValueKey('phone-key-replace'),
                      leading: const Icon(LucideIcons.refreshCw),
                      title: Text(l10n.keysActReplaceOnHosts(count)),
                      onTap: () {
                        Navigator.pop(ctx);
                        showReplaceKey(context, identity);
                      },
                    ),
                ],
              ],
              ListTile(
                leading: const Icon(LucideIcons.star),
                title: Text(l10n.homeSetAsDefaultAction),
                onTap: () {
                  Navigator.pop(ctx);
                  ref.read(identityCrudProvider).setDefault(identity.id);
                  showTopSnackBar(
                    context,
                    AppLocalizations.of(context)!.homeSetAsDefault(
                        Redactable.keyName(identity.label).display),
                  );
                },
              ),
              if (onDelete != null)
                ListTile(
                  leading: Icon(LucideIcons.trash2, color: AppColors.error),
                  title: Text(l10n.delete,
                      style: TextStyle(color: AppColors.error)),
                  onTap: () {
                    Navigator.pop(ctx);
                    onDelete!();
                  },
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }
}

/// A key's own sheet on a phone (what a long press on it offered before it
/// started selecting): from the selection's More with the one key [id]
/// selected (3.4).
void openPhoneKeySheet(BuildContext context, WidgetRef ref, String id) {
  final identity = (ref.read(identitiesProvider).valueOrNull ?? const <Identity>[]).where((i) => i.id == id).firstOrNull;
  if (identity == null) return;
  final count = ref.read(identityUsageCountsProvider).valueOrNull?[id] ?? 0;
  const list = _IdentitiesList();
  _IdentityTile(
    identity: identity,
    count: count,
    onDelete: mayChangeItem(ref, 'key', id, delete: true, watch: false)
        ? () => list._confirmDelete(context, ref, identity, count)
        : null,
    onDuplicate: mayAddScreenSpace(ref, watch: false) && IdentityCrudNotifier.canDuplicate(identity)
        ? () => list._duplicateIdentity(context, ref, identity)
        : null,
  )._showContextMenu(context, ref);
}

// ─── Port Forwards Sub-tab ────────────────────────────────────────

// ─── Networks Sub-tab ─────────────────────────────────────────────

/// Networks sub-tab of Manage. Same shared list the standalone Networks screen
/// uses (NetworksListView / NetworksEmptyState), embedded without its own
/// Scaffold/AppBar so it sits inside the Manage TabBarView. Tapping a network,
/// or the Manage FAB, opens the `/networks/edit/:id` route. This is the mobile
/// home for Networks: previously only reachable via Settings, which users could
/// not find.
class _PortForwardsList extends ConsumerWidget {
  final VoidCallback onAdd;
  const _PortForwardsList({required this.onAdd});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final rulesAsync = ref.watch(filteredPortForwardRulesProvider);
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    final selection = ref.watch(forwardSelectionProvider);

    return rulesAsync.when(
      // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, stack) => LoadErrorState(
        message: l10n.homeUnableToLoadPortForwards,
        hint: l10n.homeTryRestartingApp,
        where: 'Loading the forwarded ports',
        error: e,
        stack: stack,
        onRetry: () => ref.invalidate(filteredPortForwardRulesProvider),
      ),
      data: (rules) {
        if (rules.isEmpty) {
          publishShownItems(ref, TransferKinds.forward, const []);
          return _buildEmptyPortForwards(context, l10n);
        }

        // Build a map of connectionId → connection label (typed, so the
        // header below masks a label by the host rule and a bare
        // `host:port` fallback by the address rule).
        final connectionLabels = <String, Redactable>{};
        connectionsAsync.whenData((connections) {
          for (final c in connections) {
            connectionLabels[c.connection.id] = c.connection.label.isNotEmpty
                ? Redactable.host(c.connection.label)
                : Redactable.address(
                    hostWithPort(c.connection.host, c.connection.port));
          }
        });

        // Group rules by connection
        final grouped = <String, List<PortForwardRule>>{};
        for (final rule in rules) {
          grouped.putIfAbsent(rule.connectionId, () => []).add(rule);
        }
        // The rules in the order shown (by host): what Select all shown
        // selects (3.4).
        publishShownItems(ref, TransferKinds.forward, [
          for (final group in grouped.values)
            for (final r in group) r.id,
        ]);

        return ListView(
          padding: const EdgeInsets.only(bottom: 80, top: 8),
          children: [
            // Selected port forwards the search hides: said, with Show.
            PhoneSelectionHiddenLine(
              kind: TransferKinds.forward,
              onShow: () => ref.read(portForwardSearchQueryProvider.notifier).state = '',
            ),
            for (final entry in grouped.entries) ...[
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  connectionLabels[entry.key]?.displayIn(ref) ??
                      l10n.homeUnknownConnection,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentInk,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              for (final rule in entry.value)
                _PortForwardRuleTile(
                  rule: rule,
                  onEdit: () => _editRule(context, ref, rule),
                  selecting: selection.active,
                  selected: selection.isSelected(rule.id),
                  onToggle: () {
                    haptic(ref, Haptic.selection);
                    ref.read(forwardSelectionProvider.notifier).toggle(rule.id);
                  },
                  // A long press starts selecting, with this rule (3.4).
                  onStartSelecting: () {
                    haptic(ref, Haptic.medium);
                    ref.read(forwardSelectionProvider.notifier).enter(rule.id);
                  },
                ),
            ],
          ],
        );
      },
    );
  }

  Future<void> _editRule(
      BuildContext context, WidgetRef ref, PortForwardRule rule) async {
    final result = await showPortForwardEditor(
      context,
      initial: PortForwardResult(
        id: rule.id,
        type: rule.type,
        bindAddress: rule.bindAddress,
        bindPort: rule.bindPort,
        remoteHost: rule.remoteHost,
        remotePort: rule.remotePort,
        autoStart: rule.autoStart,
        label: rule.label,
      ),
      // Delete is on the rule's own page, not on its row (3.0).
      onDelete: () => _deleteRule(context, ref, rule),
      // So are Move and Copy to another place (4.0).
      movable: true,
    );
    if (result != null) {
      // One that other devices on the network can reach, where it did not
      // listen so before: asked first (found in
      // a security audit).
      if (!context.mounted ||
          !await confirmNetworkBind(context,
              listensOn: forwardListensOn(forwardTypeOf(result.type), result.bindAddress,
                  gatewayPorts: rule.gatewayPorts),
              port: result.bindPort,
              before: forwardListensOn(forwardTypeOf(rule.type), rule.bindAddress,
                  gatewayPorts: rule.gatewayPorts))) {
        return;
      }
      final dao = ref.read(portForwardRulesDaoProvider);
      await dao.updateRule(PortForwardRulesCompanion(
        id: Value(result.id),
        connectionId: Value(rule.connectionId),
        type: Value(result.type),
        bindAddress: Value(result.bindAddress),
        bindPort: Value(result.bindPort),
        remoteHost: Value(result.remoteHost),
        remotePort: Value(result.remotePort),
        autoStart: Value(result.autoStart),
        label: Value(result.label),
        createdAt: Value(rule.createdAt),
      ));
    }
  }

  /// Asks, then deletes [rule]; whether it went.
  Future<bool> _deleteRule(
      BuildContext context, WidgetRef ref, PortForwardRule rule) async {
    final l10n = AppLocalizations.of(context)!;
    final title = (rule.label != null && rule.label!.isNotEmpty)
        ? rule.label!
        : '${rule.bindAddress}:${rule.bindPort}';
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.homeDeletePortForward,
      body: l10n.homeDeletePortForwardMsg(title),
      confirmLabel: l10n.delete,
    );
    if (confirmed != true) return false;
    final dao = ref.read(portForwardRulesDaoProvider);
    await dao.deleteRule(rule.id);
    return true;
  }

  Widget _buildEmptyPortForwards(
      BuildContext context, AppLocalizations l10n) {
    return ZestEmptyState(
      icon: LucideIcons.arrowLeftRight,
      iconSize: 56,
      title: l10n.portForwardNone,
      message: l10n.homePortForwardEmptyDesc,
      actionLabel: l10n.homeAddPortForward,
      onAction: onAdd,
    );
  }
}

/// Tile for a single port forward rule in the Manage tab.
class _PortForwardRuleTile extends ConsumerWidget {
  final PortForwardRule rule;

  /// Opens the rule's own page, where its Delete is (3.0: no
  /// Delete on a list row).
  final VoidCallback onEdit;

  /// Port forwards are being selected (3.4): the tile has its box, and a tap
  /// or a long press puts it in or takes it out ([onToggle]).
  final bool selecting;
  final bool selected;
  final VoidCallback? onToggle;

  /// A long press starts selecting, with this rule.
  final VoidCallback? onStartSelecting;

  const _PortForwardRuleTile({
    required this.rule,
    required this.onEdit,
    this.selecting = false,
    this.selected = false,
    this.onToggle,
    this.onStartSelecting,
  });

  IconData _iconForType(String type) {
    switch (type) {
      case 'remote':
        return LucideIcons.arrowLeft;
      case 'dynamic':
        return LucideIcons.globe;
      default:
        return LucideIcons.arrowRight;
    }
  }

  String _typeBadge(String type) {
    switch (type) {
      case 'remote':
        return 'R';
      case 'dynamic':
        return 'D';
      default:
        return 'L';
    }
  }

  /// The rule's `bind \u2192 remote` line. The remote host and bind address are
  /// addresses, so the composed line goes through the free-text rule in
  /// recording mode (ports stay readable).
  String _description(AppLocalizations l10n, WidgetRef ref) {
    final String raw;
    if (rule.type == 'dynamic') {
      raw = l10n.homePortForwardSocks5On('${rule.bindAddress}:${rule.bindPort}');
    } else if (rule.type == 'remote') {
      raw = '${rule.remoteHost}:${rule.remotePort} \u2192 ${rule.bindAddress}:${rule.bindPort}';
    } else {
      raw = '${rule.bindAddress}:${rule.bindPort} \u2192 ${rule.remoteHost}:${rule.remotePort}';
    }
    return Redactable.freeText(raw).displayIn(ref);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final labelled = rule.label != null && rule.label!.isNotEmpty;
    // Monospace for the addresses and ports (values to copy); the kind and
    // whether it starts by itself in the app's own type, as plain text (its
    // AUTO was a chip before 3.0).
    const mono = TextStyle(fontFamily: 'JetBrainsMono');
    final starts = rule.autoStart ? l10n.homePortForwardAuto : l10n.homePortForwardManual;
    final title = labelled
        ? Text(rule.label!)
        : Text(_description(l10n, ref), style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 14));
    final subtitle = labelled
        ? Text.rich(TextSpan(children: [
            TextSpan(text: _description(l10n, ref), style: mono),
            if (rule.autoStart) TextSpan(text: ' \u00b7 ${l10n.homePortForwardAuto}'),
          ]))
        : Text('${_typeBadge(rule.type)} \u00b7 $starts');

    // Green while it runs, on a session of its host. (It was green when it
    // starts with its connection, which its Auto mark says, and read as
    // running.)
    final running = ref.watch(activeForwardIdsProvider).contains(rule.id);
    final icon = Icon(
      _iconForType(rule.type),
      color: running ? AppColors.success : AppColors.textSecondary,
    );
    return Card(
      key: ValueKey('phone-forward-${rule.id}'),
      color: selecting && selected ? Color.alphaBlend(phoneSelectedTint(), Theme.of(context).cardTheme.color ?? AppColors.surface) : null,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: ListTile(
        onTap: selecting ? onToggle : onEdit,
        onLongPress: selecting ? onToggle : onStartSelecting,
        leading: selecting
            ? Row(mainAxisSize: MainAxisSize.min, children: [
                SelectBox(key: ValueKey('phone-forward-box-${rule.id}'), checked: selected, size: 20),
                const SizedBox(width: 14),
                icon,
              ])
            : icon,
        title: title,
        subtitle: DefaultTextStyle.merge(
          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          child: subtitle,
        ),
        // The row opens the rule's own page (Delete is there).
        trailing: Icon(LucideIcons.chevronRight, size: 18, color: AppColors.textSecondary),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Keys and Port forwarding: a phone's Manage tab, a tablet's More
// ═══════════════════════════════════════════════════════════════════

/// A phone screen whose app bar can search: [searchQuery] holds what is
/// typed (cleared when the screen closes), [body] reads it.
class _SearchScreen extends ConsumerStatefulWidget {
  const _SearchScreen({
    super.key,
    required this.title,
    required this.searchQuery,
    required this.body,
    this.add,
    this.guide,
    this.actions = const [],
    this.underBar,
    this.selectionKind,
    this.ownSelectionBar = false,
    this.onItemActions,
  });

  final String title;
  final StateProvider<String> searchQuery;
  final Widget body;

  /// The kind of items its list selects (3.4): while it does, the bar says
  /// how many with Select all shown, and back ends it.
  final String? selectionKind;

  /// Its own tab bar of the selection's actions (a tablet's page of its
  /// own; on a phone's Manage tab, Home's tab bar is).
  final bool ownSelectionBar;

  /// With one item selected, its own sheet (the selection's More).
  final void Function(String id)? onItemActions;

  /// What goes under the bar, over [body]: Home's banners on a phone's
  /// Manage tab, as every tab has them under its title.
  final Widget? underBar;

  /// More of the bar's buttons, before its "+" (the Manage tab's help and
  /// bell, as Home's other tabs have them).
  final List<Widget> actions;

  /// The feature id of the guide the bar's "?" opens (Help > Guides).
  final String? guide;

  /// The bar's "+" (what it adds, and how), where something may be added.
  final ({String tooltip, VoidCallback onPressed, Key key})? add;

  @override
  ConsumerState<_SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<_SearchScreen> {
  final _controller = TextEditingController();
  bool _searching = false;

  /// Read when the screen opens: read lazily, a screen closed without a
  /// search reached for it first in [dispose], where `ref` may no longer be
  /// used, and closing it threw.
  late final StateController<String> _query;

  @override
  void initState() {
    super.initState();
    _query = ref.read(widget.searchQuery.notifier);
  }

  @override
  void dispose() {
    _controller.dispose();
    // The next visit starts with the whole list.
    final query = _query;
    // (Not where the app's state went with it: a test's end.)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (query.mounted) query.state = '';
    });
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // On a tablet, the one centred column a phone page takes there, as Hosts
    // and Networks have (Keys and Port forwarding ran the full width, 1280
    // pixels on a tablet held sideways, after a design audit had lined up
    // Hosts and Networks). Home's
    // banners keep the whole width, as over Hosts.
    final body = PhonePageColumn(child: widget.body);
    // A search emptied from elsewhere (a selection's Show) empties the field.
    ref.listen(widget.searchQuery, (_, q) {
      if (q.isEmpty && _controller.text.isNotEmpty) _controller.clear();
    });
    final kind = widget.selectionKind;
    final selecting = kind != null && ref.watch(itemSelectionProvider(kind)).active;
    return PopScope(
      canPop: !selecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && selecting) ref.read(itemSelectionProvider(kind).notifier).exit();
      },
      child: Scaffold(
      bottomNavigationBar: selecting && widget.ownSelectionBar
          ? PhoneItemSelectionBar(kind: kind, onItemActions: widget.onItemActions)
          : null,
      appBar: selecting ? PhoneItemSelectionAppBar(kind: kind) : AppBar(
        title: _searching
            ? TextField(
                controller: _controller,
                autofocus: true,
                // Plain text in the bar: no well and no box in any state (the
                // theme's outlines drew one around it).
                decoration: InputDecoration(
                  hintText: l10n.homeSearchHint,
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
                onChanged: (q) => _query.state = q,
              )
            // The guide's "?" just after the title, as on every page: beside
            // Help & support's on the right, the two read as one button twice.
            : widget.guide != null
                ? GuideTitle(title: Text(widget.title), feature: widget.guide!)
                : Text(widget.title),
        actions: [
          IconButton(
            icon: Icon(_searching ? LucideIcons.x : LucideIcons.search),
            tooltip: _searching ? l10n.homeCloseSearch : l10n.homeSearchConnections,
            onPressed: () => setState(() {
              _searching = !_searching;
              if (!_searching) {
                _controller.clear();
                _query.state = '';
              }
            }),
          ),
          ...widget.actions,
          if (widget.add case final add?)
            IconButton(
              key: add.key,
              icon: const Icon(LucideIcons.plus),
              tooltip: add.tooltip,
              onPressed: add.onPressed,
            ),
          const SizedBox(width: 4),
        ],
      ),
      body: widget.underBar == null
          ? body
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [widget.underBar!, Expanded(child: body)],
            ),
      ),
    );
  }
}

/// A phone's Manage tab (3.1):
/// Keys and Port forwarding, the screens a tablet opens from More, as two
/// parts picked at the top. Its bar is theirs (search, "+", the guide), with
/// help and the bell as on Home's other tabs.
class ManageTab extends ConsumerWidget {
  const ManageTab({super.key, required this.section, this.underBar});

  final ValueNotifier<ManageSection> section;

  /// Home's banners, under the tab's own bar (they sat above its title).
  final Widget? underBar;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ValueListenableBuilder<ManageSection>(
      valueListenable: section,
      builder: (context, current, _) {
        final picker = Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: SizedBox(
            width: double.infinity,
            child: SegmentedButton<ManageSection>(
              key: const ValueKey('manage-sections'),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: ManageSection.keys,
                  icon: const Icon(LucideIcons.keyRound, size: 16),
                  label: Text(l10n.narrowSidebarKeys, key: const ValueKey('manage-keys')),
                ),
                ButtonSegment(
                  value: ManageSection.portForwards,
                  icon: const Icon(LucideIcons.arrowLeftRight, size: 16),
                  label: Text(l10n.narrowSidebarPortForwarding, key: const ValueKey('manage-port-forwards')),
                ),
              ],
              selected: {current},
              onSelectionChanged: (picked) => section.value = picked.first,
            ),
          ),
        );
        const actions = [_HelpButton(), MobileNotificationBell()];
        return switch (current) {
          ManageSection.keys => _SearchScreen(
              key: const ValueKey('phone-keys'),
              title: l10n.narrowSidebarGroupManage,
              guide: 'keys',
              searchQuery: identitySearchQueryProvider,
              selectionKind: TransferKinds.key,
              actions: actions,
              underBar: underBar,
              body: Column(children: [picker, const Expanded(child: _IdentitiesList())]),
              add: mayAddScreenSpace(ref)
                  ? (
                      tooltip: l10n.homeAddNewIdentity,
                      onPressed: () => context.push(Routes.identityEdit),
                      key: const ValueKey('phone-keys-add'),
                    )
                  : null,
            ),
          ManageSection.portForwards => _SearchScreen(
              key: const ValueKey('phone-port-forwards'),
              title: l10n.narrowSidebarGroupManage,
              guide: 'port_forwards',
              searchQuery: portForwardSearchQueryProvider,
              selectionKind: TransferKinds.forward,
              actions: actions,
              underBar: underBar,
              body: Column(children: [
                picker,
                Expanded(child: _PortForwardsList(onAdd: () => _addPortForward(context, ref))),
              ]),
              add: (
                tooltip: l10n.homeAddPortForward,
                onPressed: () => _addPortForward(context, ref),
                key: const ValueKey('phone-forwards-add'),
              ),
            ),
        };
      },
    );
  }
}

/// Home's banners, under the bar of the tab on screen: the network the device
/// is on, with its override (it hides itself where there are no networks of
/// the person's own), so the active profile is reachable wherever they are,
/// and how ZestSSH Cloud stands while something is in the way of it (a
/// computer says it in its status bar, which a phone has not). Clear of a
/// notch at the side, in landscape.
class _HomeBanners extends StatelessWidget {
  const _HomeBanners();

  @override
  Widget build(BuildContext context) {
    return const SafeArea(
      key: ValueKey('home-banners'),
      top: false,
      bottom: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [CurrentNetworkBanner(), CloudReachBanner()],
      ),
    );
  }
}

/// Help & support, one tap from every tab of a phone's Home: a dot while an
/// answer from support has not been read.
class _HelpButton extends ConsumerWidget {
  const _HelpButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return IconButton(
      icon: Badge(
        isLabelVisible: ref.watch(ticketUnreadCountProvider) > 0,
        backgroundColor: AppColors.brandOrange,
        smallSize: 8,
        child: const Icon(LucideIcons.helpCircle),
      ),
      tooltip: AppLocalizations.of(context)!.helpSupport,
      onPressed: () => context.push(Routes.help),
    );
  }
}

/// A tablet's More, Keys: the keys and passwords hosts sign in with.
class KeysPhoneScreen extends ConsumerWidget {
  const KeysPhoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return _SearchScreen(
      key: const ValueKey('phone-keys'),
      title: l10n.narrowSidebarKeys,
      guide: 'keys',
      searchQuery: identitySearchQueryProvider,
      selectionKind: TransferKinds.key,
      ownSelectionBar: true,
      onItemActions: (id) => openPhoneKeySheet(context, ref, id),
      body: const _IdentitiesList(),
      add: mayAddScreenSpace(ref)
          ? (
              tooltip: l10n.homeAddNewIdentity,
              onPressed: () => context.push(Routes.identityEdit),
              key: const ValueKey('phone-keys-add'),
            )
          : null,
    );
  }
}

/// A tablet's More, Port forwarding: every host's tunnels.
class PortForwardsPhoneScreen extends ConsumerWidget {
  const PortForwardsPhoneScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return _SearchScreen(
      key: const ValueKey('phone-port-forwards'),
      title: l10n.narrowSidebarPortForwarding,
      guide: 'port_forwards',
      searchQuery: portForwardSearchQueryProvider,
      selectionKind: TransferKinds.forward,
      ownSelectionBar: true,
      body: _PortForwardsList(onAdd: () => _addPortForward(context, ref)),
      add: (
        tooltip: l10n.homeAddPortForward,
        onPressed: () => _addPortForward(context, ref),
        key: const ValueKey('phone-forwards-add'),
      ),
    );
  }
}

/// Adds a port forward: picks the host, then the forward.
Future<void> _addPortForward(BuildContext context, WidgetRef ref) async {
  final connections = ref.read(connectionsWithDetailsProvider).valueOrNull;
  if (connections == null || connections.isEmpty) {
    if (!context.mounted) return;
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.homeAddConnectionFirst,
    );
    return;
  }

  // Route through the shared ConnectionPickerDialog (search + live
  // connection status + connected-section grouping + keyboard nav) instead
  // of a bespoke list dialog. Contract is unchanged: we just need the
  // chosen connection's id to scope the new forward.
  final picked = await ConnectionPickerDialog.show(
    context,
    title: AppLocalizations.of(context)!.homeSelectConnection,
  );
  final connectionId = picked.connection?.connection.id;
  if (connectionId == null || !context.mounted) return;

  final result = await showPortForwardEditor(context);
  if (result != null && context.mounted) {
    // One that other devices on the network can reach: asked first.
    if (!await confirmNetworkBind(context,
            listensOn: forwardListensOn(forwardTypeOf(result.type), result.bindAddress), port: result.bindPort) ||
        !context.mounted) {
      return;
    }
    final dao = ref.read(portForwardRulesDaoProvider);
    await dao.insertRule(PortForwardRulesCompanion.insert(
      id: result.id,
      connectionId: connectionId,
      type: result.type,
      bindAddress: Value(result.bindAddress),
      bindPort: result.bindPort,
      remoteHost: result.remoteHost,
      remotePort: result.remotePort,
      autoStart: Value(result.autoStart),
      label: Value(result.label),
      createdAt: DateTime.now(),
    ));
  }
}

/// What a host can do on a phone (its sheet, its page): connect, edit, and
/// what this account may do with it in the space on screen (3.0;
/// everything in your Tree). The list's rows and the selection's More (one
/// host's own actions) both take them from here.
PhoneHostActions phoneHostActionsFor(
  BuildContext context,
  WidgetRef ref,
  ConnectionWithDetails item, {
  required void Function(ConnectionWithDetails) onConnect,
  void Function(ConnectionWithDetails item, String account)? onConnectAs,
}) {
  final hostRules = ItemRules.of(ref, 'host', watch: false);
  final offer = transferOffer(ref, TransferKinds.host, [item.connection.id]);
  return PhoneHostActions(
    connect: () => onConnect(item),
    // Its own screens (4.0): a screen host opens as any host does.
    openScreen: onConnect,
    edit: () => context.push('/connection/edit/${item.connection.id}'),
    connectAs: onConnectAs == null ? null : (account) => onConnectAs(item, account),
    wake: canWake(item.connection) ? () => wakeHost(context, ref, item.connection) : null,
    delete: hostRules.mayChange(item.connection.id, delete: true)
        // As the Hosts page's single delete: its pin too, and a team vault's
        // refusal said (it went unsaid, an error nothing caught).
        ? () => unawaited(deleteOneHost(context, ref, item.connection.id))
        : null,
    duplicate: mayAddScreenSpace(ref, watch: false)
        ? () => ref.read(connectionCrudProvider).duplicate(item.connection,
            label: AppLocalizations.of(context)!.homeCopyLabelSuffix(item.connection.label))
        : null,
    share: mayExportScreenSpace(ref) && ConnectionShareService.canShare(item.connection.protocol)
        ? () => shareHostAsFile(context, ref, item)
        : null,
    moveTo: offer.move
        ? () => showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: [item.connection.id], mode: TransferMode.move)
        : null,
    copyTo: offer.copy
        ? () => showMoveCopyDialog(context, ref, kind: TransferKinds.host, keys: [item.connection.id], mode: TransferMode.copy)
        : null,
  );
}
