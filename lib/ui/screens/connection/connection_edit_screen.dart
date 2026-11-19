import 'package:zestssh/services/connection_share_service.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/ui/widgets/os_icon.dart' show OsIconWidget;
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/core/widgets/status_pill.dart' show HostStatus;
import 'package:zestssh/features/hosts/host_card_face.dart';
import 'package:zestssh/features/hosts/host_screens.dart' show addScreenForHost;
import 'package:zestssh/features/hosts/host_tester.dart';
import 'package:zestssh/features/hosts/widgets/section_label.dart' show SectionLink;
import 'package:zestssh/features/hosts/widgets/host_test_views.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart' show HostCard, HostCardData, defaultIconIdFor;
import 'package:zestssh/models/os_kind.dart';
import 'package:zestssh/providers/os_detection_providers.dart' show detectedOsProvider;
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/core/theme/group_color.dart' show resolveGroupColor;
import 'package:zestssh/database/daos/connection_tags_dao.dart' show ConnectionTagsDao;
import 'package:zestssh/database/database.dart' show Connection, Identity, PortForwardRule, PortForwardRulesCompanion;
import 'package:zestssh/features/hosts/widgets/host_network_overrides_section.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/utils/platform_utils.dart' show desktopShellInUse, isDesktopPlatform, isTouchLayout;
import 'package:zestssh/features/groups/widgets/phone_group_sheets.dart' show MadeGroup, showNewGroupSheet;
import 'package:zestssh/services/local_shell_service.dart' show LocalShellService;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/core/data/os_catalog.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_color_field.dart';
import 'package:zestssh/ui/screens/connection/widgets/host_icon_picker.dart';
import 'package:zestssh/ui/screens/connection/widgets/phone_host_form.dart';
import 'package:zestssh/features/identity/identity_kind.dart' show isPasswordIdentity;
import 'package:zestssh/features/screens/model/rdp_gateway_offered.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/session/screen_team_rules.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/connection_tags_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/ui/widgets/sync_off_notice.dart';
import 'package:zestssh/services/wol_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/core/theme/group_color.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/ui/screens/connection/qr_scan_screen.dart';
import 'package:zestssh/ui/screens/connection/share_connection_sheet.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart' show zestUsesSheets;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';
import 'package:zestssh/ui/widgets/zest_button_group.dart';
import 'package:zestssh/ui/widgets/zest_close_button.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/sftp/forget_last_folder.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/l10n/host_icon_names.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/l10n/l10n_global.dart';

export 'package:zestssh/features/hosts/host_tester.dart'
    show ConnectionTestSaid, connectionTestFailed, testPasswordAfterKey;

/// The app monospace family (existing-system-wins: 'JetBrainsMono').
const String _kMono = 'JetBrainsMono';

/// The Hosts `.val` value text style, shared across this screen's read-only
/// value rows and dropdowns. Read each time, in the theme on screen: as a
/// variable it kept the text colour of the first theme it was read in, so
/// after a change to a light theme a value (the port, the identity) was
/// drawn light on white (found 22 October 2026).
TextStyle get _kValStyle =>
    TextStyle(fontFamily: 'GeistSans', fontSize: 13, color: ZestTokens.textPrimary, height: 1.25);

/// The Hosts `.val.mono` value text style, in the theme on screen.
TextStyle get _kValMonoStyle => TextStyle(
      fontSize: 13,
      color: ZestTokens.textPrimary,
      fontFamily: _kMono,
      height: 1.25,
    );

/// A field's bare decoration ([zestShellFieldDecoration]) with its hint in
/// the muted text colour, which reads on the field in every theme (the
/// placeholder colour did not, in a light one).
InputDecoration _fieldDecoration({String? hintText}) => zestShellFieldDecoration(hintText: hintText)
    .copyWith(hintStyle: TextStyle(color: ZestTokens.textTertiary, fontSize: 13));

/// [_fieldDecoration] for a one-line input whose own target is a mouse's 32
/// high inside its 40 high box (its line of 16 was all a press could land
/// on: 4.0, the accessibility pass).
InputDecoration _fieldDecorationTall({String? hintText}) =>
    _fieldDecoration(hintText: hintText).copyWith(isCollapsed: false, contentPadding: const EdgeInsets.symmetric(vertical: 12));

/// The Hosts `.chip` corner radius.
const double _kChipRadius = 7.0;

/// Add another key's Create new key, told apart from a key's id (ids are
/// UUIDs, never this).
const String _kCreateNewKey = '\u0000create-new-key';

/// Create or edit an SSH connection.
///
/// JuiceSSH-inspired layout with BASIC SETTINGS and ADVANCED SETTINGS
/// sections, checkmark save in the app bar, and a clean form layout.
/// Whether the host form offers what a computer can open, as on a computer.
/// Null in the app (the system it runs on decides).
@visibleForTesting
bool? debugHostFormOnComputer;

/// Whether a remote screen's More options start open, for a test that looks at
/// what is in them: null for what the form does (closed).
bool? debugScreenMoreOpen;

/// Whether the host form offers a local shell. Null in the app.
@visibleForTesting
bool? debugHostFormLocalShell;

class ConnectionEditScreen extends ConsumerStatefulWidget {
  final String? connectionId;

  /// True when this screen is rendered inside a desktop [Dialog].
  /// Switches the chrome from the mobile Scaffold/AppBar pattern to a
  /// purpose-built desktop layout: custom header bar + content +
  /// sticky footer action row.
  final bool inDialog;

  /// Invoked when the editor should close itself (the header's close / after a
  /// successful save or delete). Supplied by the docked desktop editor so the
  /// panel can clear its target provider instead of popping a route. When
  /// null (mobile route / legacy dialog), the editor falls back to popping.
  final VoidCallback? onClose;

  /// Protocol to pre-select for a BRAND-NEW connection (ignored when editing an
  /// existing one). Lets callers open the editor already switched to e.g.
  /// [ConnectionProtocol.serial] so a serial-over-SSH host can be created in one
  /// step from the Hosts toolbar's SERIAL button.
  final ConnectionProtocol? initialProtocol;

  /// Pre-fill values for a BRAND-NEW connection promoted from a live
  /// (ephemeral) session, so "Save connection" opens the editor already
  /// carrying the session's host / port / label instead of a blank form.
  /// Ignored when editing an existing connection (a non-null [connectionId]
  /// that loads). The username is not pre-filled here because it lives on the
  /// chosen Identity, not on the connection - the label carries `user@host`.
  final String? initialHost;
  final int? initialPort;
  final String? initialLabel;

  /// The section a computer's editor opens on, in front (Basic where null):
  /// for a caller that sends the person to one thing, as Server monitor's
  /// "Fix the login" does.
  final HostEditorSection? initialSection;

  /// For a BRAND-NEW remote screen (4.0, [initialProtocol] VNC): the SSH host
  /// it is reached through, filled in ("Add a screen for this host").
  final String? initialVia;

  const ConnectionEditScreen({
    super.key,
    this.connectionId,
    this.inDialog = false,
    this.onClose,
    this.initialProtocol,
    this.initialHost,
    this.initialPort,
    this.initialLabel,
    this.initialSection,
    this.initialVia,
  });

  /// A test's word on whether the app shows a computer's shell, where the
  /// editor docks beside the hosts; null asks the system the app runs on.
  @visibleForTesting
  static bool? debugDesktopShell;

  /// The docked editor open now, asked to close (set while one is open).
  static Future<bool> Function()? _dockedClose;

  /// Asks the docked editor to close, as its own close button does: at once where
  /// nothing changed, else after the question every editor of the app asks
  /// about unsaved changes. True once it is closed (or none was open); false
  /// where the person kept it open. The Hosts page asks it before it shows
  /// another host's details in the editor's place (one pane at the right).
  static Future<bool> closeDocked() async {
    final close = _dockedClose;
    return close == null ? true : close();
  }

  /// Show as a dialog on desktop or push a route on mobile.
  static Future<void> showAdaptive(
    BuildContext context, {
    String? connectionId,
    ConnectionProtocol? initialProtocol,
    String? initialHost,
    int? initialPort,
    String? initialLabel,
    HostEditorSection? initialSection,
    String? initialVia,
  }) {
    final size = MediaQuery.of(context).size;
    // Docked only in a computer's shell, in a window wide enough. A tablet, or
    // a phone held sideways, is as wide, but has no shell to dock in: the
    // editor was asked for there and nothing showed it.
    final docked = (debugDesktopShell ?? desktopShellInUse) &&
        size.width > DesktopDimensions.dialogDesktopBreakpoint;
    if (docked) {
      // Docked editor - a resizable right-side panel that is a layout SIBLING
      // in the desktop shell (ConnectionEditorDock), so opening it SHRINKS the
      // main content instead of floating a modal over it behind a scrim. Just
      // set the target; the shell watches this provider and mounts the dock.
      // Clicking the content behind it does nothing (it isn't modal); the
      // editor is dismissed only through its own close/save, which run
      // through the `onClose` the dock supplies.
      //
      // The dock lives on the Hosts view (the shell tucks it away with
      // Offstage anywhere else), so route there first: deselect any active
      // terminal tab and select the Hosts section. This makes "New/Edit
      // connection" behave the same no matter where it was triggered from
      // (pill bar, a terminal's menu, the sidebar), and keeps the pull-out
      // visible instead of hidden.
      final container = ProviderScope.containerOf(context, listen: false);
      container.read(workTabsProvider.notifier).clearActiveTab();
      container.read(activeSidebarNavProvider.notifier).state =
          NavSection.hosts;
      container
          .read(connectionEditorTargetProvider.notifier)
          .state = ConnectionEditorTarget(
        connectionId: connectionId,
        initialProtocol: initialProtocol,
        initialHost: initialHost,
        initialPort: initialPort,
        initialLabel: initialLabel,
        initialSection: initialSection,
        initialVia: initialVia,
      );
      return Future.value();
    } else {
      if (connectionId != null) {
        return context.push('/connection/edit/$connectionId');
      }
      // A new host of a kind the caller chose (a remote screen through one
      // of the hosts) is handed to the page.
      if (initialProtocol != null) {
        return context.push(Routes.connectionEdit,
            extra: ConnectionEditorTarget(
                initialProtocol: initialProtocol,
                initialVia: initialVia,
                initialHost: initialHost,
                initialLabel: initialLabel));
      }
      return context.push(Routes.connectionEdit);
    }
  }

  /// Open the FULL editor (the SAME rail + fields as the docked panel) as a
  /// MODAL over whatever is on screen, instead of the dock. Used by "Save
  /// connection" from a live session: the dock navigates to the Hosts view and
  /// leaves the terminal, so a modal keeps the user in the terminal while
  /// carrying the identical UI. Pass initialHost/Port/Label to pre-fill a new
  /// connection promoted from that session.
  static Future<void> showModal(
    BuildContext context, {
    String? connectionId,
    ConnectionProtocol? initialProtocol,
    String? initialHost,
    int? initialPort,
    String? initialLabel,
    HostEditorSection? initialSection,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      builder: (ctx) {
        final size = MediaQuery.of(ctx).size;
        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(24),
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox(
            width: size.width < 828 ? size.width - 48 : 780,
            height: size.height < 748 ? size.height - 48 : 700,
            child: ConnectionEditScreen(
              connectionId: connectionId,
              initialProtocol: initialProtocol,
              initialHost: initialHost,
              initialPort: initialPort,
              initialLabel: initialLabel,
              initialSection: initialSection,
              inDialog: true,
              onClose: () => Navigator.of(ctx).pop(),
            ),
          ),
        );
      },
    );
  }

  @override
  ConsumerState<ConnectionEditScreen> createState() =>
      _ConnectionEditScreenState();
}

class _ConnectionEditScreenState extends ConsumerState<ConnectionEditScreen> {
  final _formKey = GlobalKey<FormState>();

  // Per-inspector-tab form keys. In the docked desktop inspector every pane is
  // wrapped in its own nested Form so a failed save can validate each tab in
  // order and jump to the FIRST tab that actually owns an invalid field,
  // instead of always dumping the user on Basic. Index == inspector tab index.
  // (The mobile form path doesn't use these - it validates the outer form.)
  final _inspectorTabFormKeys =
      List.generate(5, (_) => GlobalKey<FormState>());
  final _labelController = TextEditingController();
  final _hostController = TextEditingController();
  final _portController = TextEditingController(text: '22');
  final _noteController = TextEditingController();

  /// The Note box's height as its grip set it; null while it grows with its
  /// words (one line up to six), as it does until the grip is dragged.
  double? _noteHeight;
  final _noteBox = GlobalKey();

  /// How low and how high the Note's grip takes the box: one line, and about
  /// twelve.
  static const double _kNoteMinHeight = 21;
  static const double _kNoteMaxHeight = 250;
  final _startupController = TextEditingController();
  final _wolMacController = TextEditingController();
  final _wolBroadcastController =
      TextEditingController(text: '255.255.255.255');

  /// Drives [HostNetworkOverridesSection] from the parent's `_save` -
  /// `currentState!.bakeDrafts(resolvedHostId)` returns the user's edits as
  /// a list of [HostNetworkOverride] models the parent then hands to the
  /// repository's atomic replace.
  final _networkOverridesKey =
      GlobalKey<HostNetworkOverridesSectionState>();

  ConnectionProtocol _protocol = ConnectionProtocol.ssh;

  /// The kinds of host that sign in with a key or a password of the app's:
  /// SSH, SFTP only, and those reached over SSH (Mosh, Eternal Terminal,
  /// Serial).
  bool get _signsInWithKey => const {
        ConnectionProtocol.ssh,
        ConnectionProtocol.sftp,
        // FTPS (3.4): the user name and the password the key holds.
        ConnectionProtocol.ftps,
        ConnectionProtocol.ftpsImplicit,
        // A remote screen (4.0): the VNC password the key holds, or an RDP
        // host's user name and password.
        ConnectionProtocol.vnc,
        ConnectionProtocol.rdp,
        ConnectionProtocol.mosh,
        ConnectionProtocol.et,
        ConnectionProtocol.serial,
      }.contains(_protocol);

  /// A host that gives files only: everything SSH has (its address, key,
  /// jump hosts, Compatibility mode, host key check) and nothing of a
  /// terminal's (startup commands, a theme, variables, forwards).
  bool get _sftpOnly => _protocol == ConnectionProtocol.sftp;

  /// An FTPS host (3.4), explicit or implicit TLS: files only, like SFTP
  /// only, but over FTP with TLS, so nothing of SSH's either (no jump hosts,
  /// no Compatibility mode, no host key).
  bool get _ftps => _protocol.isFtps;

  /// The kind class of the host as it was saved
  /// ([ConnectionProtocol.kindClassOf]: SSH-like, FTPS or a remote screen);
  /// null for a new host. A team's host stays in its class (3.4 for FTPS, 4.0
  /// for screens): the pills of the other classes are not offered, and the
  /// team's database refuses the change (kTeamHostKindRefused).
  int? _savedKindClass;

  /// Whether this is a team's host that is saved already, which keeps its
  /// kind class as it was ([_savedKindClass]).
  bool get _teamKindFixed => _savedKindClass != null && ref.read(databaseProvider).isOrchard;

  /// A remote screen (4.0, VNC or RDP): reached through an SSH host of the
  /// space (its carrier, kept in [_connectViaId]), or directly over TLS.
  bool get _screen => _protocol.isScreen;

  /// An RDP host (4.0): a screen with no Unix socket and no picture
  /// quality of VNC's, and with its own two options (NLA, graphics).
  bool get _rdp => _protocol == ConnectionProtocol.rdp;

  /// A remote screen's options ([ScreenOptions]), as the form has them; its
  /// socket path is [_socketController]'s.
  ScreenOptions _screenOptions = ScreenOptions.forNewHost;

  /// Whether a screen's options were saved with the host (loaded): one that
  /// becomes a screen in this editor starts at Settings' scaling instead.
  bool _screenOptionsLoaded = false;

  /// A host becoming a remote screen here: Settings' scaling for new screens
  /// (Settings, Remote screens), once.
  void _startScreenAtDefaultScaling() {
    if (_screenOptionsLoaded) return;
    _screenOptionsLoaded = true;
    _screenOptions = _screenOptions.copyWith(scaling: ref.read(screenScalingDefaultProvider));
  }

  /// A host becoming an RDP host here: the remote is resized to the tab, which
  /// RDP does well and is what people expect of it; once, and never over
  /// options that were saved with the host.
  void _startRdpAtItsScaling() {
    if (_screenOptionsLoaded) return;
    _screenOptionsLoaded = true;
    _screenOptions = _screenOptions.copyWith(scaling: ScreenScaling.remoteResize);
  }
  final _socketController = TextEditingController();

  /// RDP through an RD Gateway (4.0), chosen under "Reach through":
  /// the gateway's address and port, and the key its sign-in uses (null:
  /// the PC's own).
  bool _throughGateway = false;
  final _gatewayHostController = TextEditingController();
  final _gatewayPortController = TextEditingController(text: '443');
  String? _gatewayKeyId;

  /// An RDP host that goes through an RD Gateway (chosen here, or one this
  /// version cannot read): its Test is off, since it would dial the PC
  /// directly, which the session never does.
  bool get _gatewayHost => _rdp && (_throughGateway || _screenOptions.gateway?.readable == false);

  /// What "Reach through" holds while the gateway is chosen (no host's id
  /// can be it).
  static const _gatewayChoice = ' rd-gateway';

  /// A remote screen reached at a Unix socket on its carrier: no address or
  /// port of its own.
  bool get _screenUnix =>
      _screen && !_rdp && _connectViaId != null && _screenOptions.target == ScreenTargetKind.unix;

  /// A host that gives files only, by SFTP or by FTPS, or a remote screen:
  /// nothing of a terminal's is shown for it.
  bool get _filesOnly => _sftpOnly || _ftps || _screen;

  /// Compatibility mode as it is saved: never for an FTPS host, which signs
  /// in over TLS and reads no SSH setting (one switched on for the host as
  /// another kind is not kept).
  bool get _compatibilitySaved => _compatibilityMode && !_ftps;

  // The protocol pill row is one Tab stop (a radio group); true while it holds
  // keyboard focus, so the active pill draws its orange focus ring.
  bool _protocolFocused = false;
  String? _identityId;
  String? _groupId;

  /// A phone's and a tablet's group list ends with New group (3.0.1): the
  /// group it made, until the list of groups has it.
  MadeGroup? _madeGroup;
  String? _snippetId;
  String? _connectViaId;

  /// Host-card icon override: a chosen built-in catalog id and/or an uploaded
  /// base64 PNG. Both null = the auto OS icon.
  String? _iconId;
  String? _customIcon;

  /// What colours the icon, as the host stores it (see `HostIconColor`):
  /// null is the icon's own colour.
  int? _iconColor;
  int _colorIndex = 0;

  /// Custom per-connection label colour (ARGB int). When non-null it OVERRIDES
  /// [_colorIndex], so the user can pick ANY colour, not just a palette preset.
  /// Null falls back to the legacy index behaviour.
  int? _colorValue;
  String? _terminalThemeId; // null = use global default

  /// The group the form has the host in, or null.
  dynamic _groupOf(AsyncValue<List<dynamic>> groupsAsync) {
    if (_groupId == null) return null;
    for (final g in groupsAsync.valueOrNull ?? const <dynamic>[]) {
      if (g.id == _groupId) return g;
    }
    return null;
  }

  /// The colour of the host's label as the form has it, the same rule as the
  /// cards: the explicit colour label, else the group's colour, else null.
  /// The icon is drawn in it only where the person had it follow the label.
  /// The icon of the system seen on this host (for Auto), as its card draws
  /// it; null for a new host, or one never reached.
  String? get _detectedOsId {
    final id = widget.connectionId;
    if (id == null) return null;
    final kind = ref.watch(detectedOsProvider(id));
    return kind == null ? null : osCatalogIdFor(kind);
  }

  /// The icon the host's card draws where none is chosen: a screen for a
  /// remote screen, as on the Hosts page (the editor drew a terminal for it).
  String? get _shownIconId => _iconId ?? defaultIconIdFor(_protocol.name);

  /// The host's icon as its card draws it (the icon chosen, a picture, or the
  /// system seen on it), at [size].
  Widget _hostIcon(double size, Color? labelColor, {double cornerRadius = 8}) => HostIcon(
        iconId: _shownIconId,
        customIcon: _customIcon,
        osId: _detectedOsId,
        size: size,
        cornerRadius: cornerRadius,
        iconColor: _iconColor,
        labelColor: labelColor,
      );

  Color? _labelColor(AsyncValue<List<dynamic>> groupsAsync) {
    if (AppColors.hasExplicitConnectionLabel(_colorValue, _colorIndex)) {
      return AppColors.labelColorFor(_colorValue, _colorIndex);
    }
    final g = _groupOf(groupsAsync);
    if (g != null) {
      return resolveGroupColor(
        colorValue: g.colorValue as int?,
        colorIndex: g.colorIndex as int?,
        name: g.name as String,
      );
    }
    return null;
  }

  /// Terminal-tab "Override app defaults" banner state. When false the host
  /// follows global Settings (theme override cleared to null on save). Derived
  /// from whether a per-host theme is set when loading an existing connection.
  bool _terminalOverride = false;
  bool _zlibCompression = false;
  bool _forwardAgent = false;
  bool _compatibilityMode = false;
  int _keepAliveSeconds = 0; // 0 = use the global keepalive setting
  bool _isLoading = false;

  /// Where a new host is saved ("Save in", 3.4); null: where new items of
  /// the space on screen go.
  SavePlace? _saveIn;
  bool _isTesting = false;

  /// Which test was asked for last: the one whose button shows it running in
  /// the computer's footer while [_isTesting].
  _HostTestKind? _runningTest;
  HostTestResult? _testResult;

  /// Whether the form has unsaved edits. Drives the header "unsaved" dot, the
  /// Save button's enabled state, and the discard-on-close confirmation.
  bool _dirty = false;

  /// True while the editor is populating its controllers from a loaded
  /// connection, so the controller listeners don't flag those writes as user
  /// edits. Set true before [_loadConnection], cleared at its end.
  bool _hydrating = false;

  /// Flag the form dirty. No-op while hydrating (loading an existing host) or
  /// once already dirty, so it stays cheap to call from every onChanged.
  void _markDirty() {
    if (_hydrating || _dirty) return;
    setState(() => _dirty = true);
  }

  /// [c] marks the form changed when its words change, not when its cursor or
  /// selection moves: a text field's listener hears both, and a click into a
  /// field lit Save with nothing changed.
  TextEditingController _watchWords(TextEditingController c) {
    var words = c.text;
    c.addListener(() {
      if (c.text == words) return;
      words = c.text;
      _markDirty();
    });
    return c;
  }

  /// Whether the advanced options section is expanded (mobile/full-screen
  /// path only - the desktop docked inspector uses [_inspectorTab] instead).
  bool _showAdvanced = false;

  /// Whether a phone's More options (group, colour, icon, tags and note) is
  /// open; null until it is opened or closed, while it is open for a saved
  /// host that has one of them, so nothing set is hidden ([_organiseHasValues]).
  bool? _showMore;

  /// Whether a phone's "Signs in with" lists the passwords (true) or the keys,
  /// while no key or password is chosen; one chosen says which itself.
  bool _signInWithPassword = false;

  /// Active section in the desktop docked inspector's rail:
  /// 0 Basic · 1 Auth · 2 Network · 3 Terminal · 4 Advanced.
  int _inspectorTab = 0;

  /// Whether the custom keep-alive text field is shown.
  bool _showCustomKeepAlive = false;

  /// Environment variable key-value pairs for the connection.
  final List<_EnvVarEntry> _envVars = [];

  /// Free-form tags attached to this connection. Always stored in
  /// canonical form (lowercased / trimmed by [ConnectionTagsDao.normalize]).
  List<String> _tags = const [];

  /// True once tags have finished loading (or immediately for a brand-new
  /// connection). `_save` must not persist `_tags` before this - an empty
  /// placeholder saved during the async load would wipe the host's tags.
  bool _tagsLoaded = false;

  /// True once the user has edited the tag field. Guards against the async
  /// tag load resolving *after* an edit and clobbering the user's change
  /// (the field is live from first paint, so this race is reachable).
  bool _tagsDirty = false;

  /// The host's other accounts (3.0, accounts per host): identities it can
  /// also be signed in to with, in their order, never [_identityId]. Loaded
  /// and saved as the tags are, with the same two guards.
  List<String> _otherAccounts = const [];
  bool _otherAccountsLoaded = false;
  bool _otherAccountsDirty = false;

  /// Accent for the inspector chrome (rail, section headers, field focus,
  /// title strip). This is the BRAND accent, deliberately NOT the per-
  /// connection color label: letting the label bleed into every header made
  /// a red/blue/etc. host recolor the whole editor and read as off-brand
  /// (and, for red, alarming). The color label still shows in its own
  /// swatch row + on the host card, which is where it belongs.
  Color get _accentColor => AppColors.brandOrange;

  /// Serialize environment variables to JSON string.
  String _serializeEnvVars() {
    final map = <String, String>{};
    for (final entry in _envVars) {
      final key = entry.key.text.trim();
      final value = entry.value.text;
      if (key.isNotEmpty) {
        map[key] = value;
      }
    }
    return map.isEmpty ? '' : jsonEncode(map);
  }

  @override
  void initState() {
    super.initState();
    // Opened on the section the caller named, in front.
    _inspectorTab = widget.initialSection?.index ?? 0;
    // The docked editor answers [ConnectionEditScreen.closeDocked].
    if (widget.inDialog && widget.onClose != null) ConnectionEditScreen._dockedClose = _askToClose;
    // A new host's port is the one Settings gives new connections (it was 22
    // whatever Settings said); a host loaded below has its own.
    _portController.text = '${ref.read(defaultPortProvider)}';
    // Any keystroke in a core text field flags the form dirty. Guarded by
    // [_hydrating] so the load-time writes below don't trip it.
    for (final c in [
      _labelController,
      _hostController,
      _portController,
      _noteController,
      _startupController,
      _wolMacController,
      _wolBroadcastController,
    ]) {
      _watchWords(c);
    }
    if (widget.connectionId != null) {
      _hydrating = true;
      _loadConnection();
    } else {
      // Brand-new connection: nothing to load, so tags are "ready" and the
      // form's list is authoritative from the start. So are its accounts.
      _tagsLoaded = true;
      _otherAccountsLoaded = true;
      // Honor a caller-requested starting protocol (e.g. the Hosts SERIAL
      // button opens the editor pre-switched to serial-over-SSH). Mirror the
      // port default that _onProtocolSelected applies, without its snackbar /
      // dirty side-effects which are unsafe during initState.
      if (widget.initialProtocol != null) {
        _protocol = widget.initialProtocol!;
        if (_protocol == ConnectionProtocol.serial) {
          _portController.text = '3001';
        }
        if (_protocol == ConnectionProtocol.vnc) {
          _portController.text = '5900';
          _hostController.text = 'localhost';
          _connectViaId = widget.initialVia;
          _startScreenAtDefaultScaling();
        }
        if (_protocol == ConnectionProtocol.rdp) {
          _portController.text = '3389';
          _connectViaId = widget.initialVia;
          if (_connectViaId != null) _hostController.text = 'localhost';
          _startRdpAtItsScaling();
        }
      }
      // Promoting a live (ephemeral) session into a saved connection: seed the
      // basics the session already knows so the form is not blank. Leaving the
      // form flagged dirty is intended - the user opened "Save connection" to
      // save it. The username is carried inside the label (`user@host`); the
      // Identity is still the user's pick.
      if (widget.initialHost != null && widget.initialHost!.isNotEmpty) {
        _hostController.text = widget.initialHost!;
      }
      if (widget.initialPort != null) {
        _portController.text = widget.initialPort.toString();
      }
      if (widget.initialLabel != null && widget.initialLabel!.isNotEmpty) {
        _labelController.text = widget.initialLabel!;
      }
    }
  }

  /// The SFTP host default on the record (remember-last-folder spec), shown
  /// under advanced options with a "Forget last folder" action.
  String? _lastRemotePath;

  /// The host's row as this editor read it, for Save to tell the fields the
  /// person changed from those another device changed meanwhile.
  Connection? _loadedRow;

  Future<void> _loadConnection() async {
    final dao = ref.read(connectionsDaoProvider);
    final connection = await dao.getById(widget.connectionId!);
    if (connection != null && mounted) {
      _loadedRow = connection;
      // Load per-connection terminal theme from SharedPreferences
      final prefs = ref.read(sharedPreferencesProvider);
      final savedTheme = prefs.getString('terminal_theme_${widget.connectionId}');

      setState(() {
        _labelController.text = connection.label;
        _hostController.text = connection.host;
        _portController.text = connection.port.toString();
        _noteController.text = connection.note ?? '';
        _startupController.text = connection.startupCommand ?? '';
        _lastRemotePath = connection.lastRemotePath;
        _protocol = ConnectionProtocol.values.firstWhere(
          (p) => p.name == connection.protocol,
          orElse: () => ConnectionProtocol.ssh,
        );
        _savedKindClass = ConnectionProtocol.kindClassOf(connection.protocol);
        if (ConnectionProtocol.storedIsScreen(connection.protocol)) {
          _screenOptions = ScreenOptions.decode(connection.screenOptions);
          _screenOptionsLoaded = true;
          _socketController.text = _screenOptions.socket ?? '';
          // A gateway this version cannot read stays in the options as it
          // came (and the host is refused at connect): not shown here.
          final gateway = _screenOptions.gateway;
          if (gateway != null && gateway.readable) {
            _throughGateway = true;
            _gatewayHostController.text = gateway.host;
            _gatewayPortController.text = '${gateway.port}';
            _gatewayKeyId = gateway.keyId;
          }
        }
        _identityId = connection.identityId;
        _groupId = connection.groupId;
        _snippetId = connection.snippetId;
        _connectViaId = connection.connectViaId;
        _colorIndex = connection.colorIndex;
        _colorValue = connection.colorValue;
        _iconId = connection.iconId;
        _customIcon = connection.customIcon;
        _iconColor = connection.iconColor;
        _terminalThemeId = savedTheme;
        _terminalOverride = savedTheme != null;
        _zlibCompression = connection.zlibCompression;
        _forwardAgent = connection.forwardAgent;
        _compatibilityMode = connection.compatibilityMode;
        _keepAliveSeconds = connection.keepAliveSeconds;
        _showCustomKeepAlive = !const {0, 15, 30, 60, 120, 300}
            .contains(connection.keepAliveSeconds);
        _wolMacController.text = connection.wolMacAddress ?? '';
        _wolBroadcastController.text =
            connection.wolBroadcastAddress ?? '255.255.255.255';

        // Load environment variables
        _envVars.clear();
        if (connection.envVars.isNotEmpty) {
          try {
            final Map<String, dynamic> vars =
                jsonDecode(connection.envVars) as Map<String, dynamic>;
            for (final entry in vars.entries) {
              _envVars.add(_EnvVarEntry(
                key: _watchWords(TextEditingController(text: entry.key)),
                value: _watchWords(
                    TextEditingController(text: entry.value.toString())),
              ));
            }
          } catch (_) {
            // Ignore malformed JSON
          }
        }
      });

      // Load tags off the main setState - tags live in their own
      // table and the dao read is async. The form is happy to
      // re-paint when they arrive.
      final tagsDao = ref.read(connectionTagsDaoProvider);
      final loadedTags =
          await tagsDao.getTagsForConnection(widget.connectionId!);
      if (mounted) {
        setState(() {
          // Don't clobber a tag the user added while the load was in flight.
          if (!_tagsDirty) _tags = loadedTags;
          _tagsLoaded = true;
        });
      }
      final loadedAccounts =
          await ref.read(hostAccountsDaoProvider).otherAccountsOf(widget.connectionId!);
      if (mounted) {
        setState(() {
          if (!_otherAccountsDirty) _otherAccounts = loadedAccounts;
          _otherAccountsLoaded = true;
        });
      }
    }
    // Hydration finished (whether or not the connection existed) - from here
    // on, controller/dropdown changes are real user edits.
    _hydrating = false;
  }

  @override
  void dispose() {
    if (ConnectionEditScreen._dockedClose == _askToClose) ConnectionEditScreen._dockedClose = null;
    _labelController.dispose();
    _hostController.dispose();
    _socketController.dispose();
    _gatewayHostController.dispose();
    _gatewayPortController.dispose();
    _portController.dispose();
    _noteController.dispose();
    _startupController.dispose();
    _wolMacController.dispose();
    _wolBroadcastController.dispose();
    for (final entry in _envVars) {
      entry.key.dispose();
      entry.value.dispose();
    }
    super.dispose();
  }

  /// Dismiss the editor. In the docked desktop editor [widget.onClose] clears
  /// the dock's target provider; otherwise (mobile route / legacy dialog) we
  /// pop the route exactly as before, so behaviour is unchanged when no
  /// `onClose` is supplied. Callers guard with `mounted` where needed.
  void _closeEditor() {
    _closed = true;
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose();
    } else {
      context.pop();
    }
  }

  /// Whether the editor was closed ([_closeEditor]): after a save, whether it
  /// went through.
  bool _closed = false;

  /// [ConnectionEditScreen.closeDocked]: as [_confirmDiscardThenClose], and
  /// says whether the editor closed.
  Future<bool> _askToClose() async {
    await _confirmDiscardThenClose();
    return _closed || !mounted;
  }

  /// Close the editor, first asking the user what to do with unsaved edits.
  /// A clean form closes immediately; a dirty one offers Save / Discard /
  /// Cancel. Routed through by the header's close button and (on
  /// mobile) the back button, so no in-progress edit is lost silently.
  Future<void> _confirmDiscardThenClose() async {
    if (!_dirty) {
      _closeEditor();
      return;
    }
    // The one question every editor of the app asks about unsaved changes.
    final choice = await showZestDiscardDialog(context);
    if (!mounted) return;
    switch (choice) {
      case DiscardChoice.discard:
        _closeEditor();
      case DiscardChoice.save:
        await _save();
      case DiscardChoice.cancel:
        break; // keep the editor open
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Recording mode: the header and preview compose their strings inside
    // AnimatedBuilders (which rebuild on their own), so this screen watches
    // the mode and level here to re-run them on a toggle.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final identitiesAsync = ref.watch(identitiesProvider);
    final snippetsAsync = ref.watch(snippetsProvider);
    final groupsAsync = ref.watch(connectionGroupsProvider);
    final connectionsAsync = ref.watch(filteredConnectionsProvider);
    final isEditing = widget.connectionId != null;

    // Desktop dialog gets a purpose-built chrome (no AppBar, sticky
    // footer). Everything else (mobile / full-screen route) keeps the
    // mobile-style ResponsiveScaffold.
    if (widget.inDialog) {
      return ZestFieldLabels(
        labels: _mainFieldLabels(l10n),
        child: _buildDialogChrome(
          l10n: l10n,
          isEditing: isEditing,
          identitiesAsync: identitiesAsync,
          snippetsAsync: snippetsAsync,
          groupsAsync: groupsAsync,
          connectionsAsync: connectionsAsync,
        ),
      );
    }

    return ZestFieldLabels(
      labels: _mainFieldLabels(l10n),
      child: PopScope<void>(
      // A clean form pops normally; a dirty one intercepts the back gesture /
      // app-bar back button and runs the discard confirmation instead.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _confirmDiscardThenClose();
      },
      child: ResponsiveScaffold(
      title: isEditing ? l10n.connectionEditTitle : l10n.hostsNewHost,
      actions: [
        // Move or copy to another place (4.0): a saved host's.
        if (isEditing) _moveCopyButton(),
        // Share via QR / link - only meaningful for connections that
        // already exist. Hidden during initial create so the user
        // can't share half-filled drafts that would fail validation
        // on the receiving side.
        if (isEditing && mayExportScreenSpace(ref) && ConnectionShareService.canShare(_protocol.name))
          IconButton(
            icon: const Icon(LucideIcons.qrCode),
            tooltip: l10n.connectionEditShare,
            onPressed: _shareConnection,
          ),
        // Mobile-only: scan a share QR from another device. Bypasses
        // the editor entirely - the scanner routes through the same
        // IncomingShareDialog confirmation as deep links and saves
        // directly. Hidden on desktop (no realistic camera) and when
        // editing (this is for adding new ones).
        if (!isEditing && QrScanScreen.isSupported)
          IconButton(
            icon: const Icon(LucideIcons.scanLine),
            tooltip: l10n.connectionEditScanQr,
            onPressed: () => context.push(Routes.connectionScanQr),
          ),
        // (Saving is the form's own Save at its foot: a check here as well
        // was a second Save, 22 October 2026.)
        if (isEditing && _mayDelete)
          IconButton(
            tooltip: AppLocalizations.of(context)!.delete,
            icon: const Icon(LucideIcons.trash2),
            onPressed: _confirmDelete,
          ),
      ],
      body: Form(
        key: _formKey,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final useTwoColumns = constraints.maxWidth > 700;
            // A phone's (and a narrow window's) form, as the design
            // draws it: names above the
            // fields, the protocols as tiles, the rest folded, Test and Save
            // in a bar at the foot.
            if (!useTwoColumns) {
              return _buildPhoneForm(
                l10n: l10n,
                isEditing: isEditing,
                identitiesAsync: identitiesAsync,
                snippetsAsync: snippetsAsync,
                groupsAsync: groupsAsync,
                connectionsAsync: connectionsAsync,
              );
            }
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Where a new host is saved (3.4).
                if (!isEditing)
                  SaveInField(
                    value: _saveIn,
                    onChanged: (p) => setState(() => _saveIn = p),
                    padding: const EdgeInsets.only(bottom: 16),
                  ),
                _buildTwoColumnForm(
                  l10n: l10n,
                  identitiesAsync: identitiesAsync,
                  snippetsAsync: snippetsAsync,
                  groupsAsync: groupsAsync,
                  connectionsAsync: connectionsAsync,
                ),
                const SizedBox(height: 24),
                // ── Test result banner ────────────────────────────
                if (_testResult != null) _buildTestResultBanner(),
                // ── Bottom action buttons ─────────────────────────
                _buildBottomButtons(l10n, isEditing),
                const SizedBox(height: 32),
              ],
            );
          },
        ),
      ),
      ),
      ),
    );
  }

  /// The names of the editor's main fields, which its label column is
  /// measured from: in 88 pixels, "Soprannome" (Italian), "Псевдоним" and
  /// "Идентификатор" (Russian) were cut at the size the app is drawn at, and
  /// most names at 1.3 times. The Network, Automation and Wake-on-LAN
  /// sections measure their own ([_secondaryLabelWidth]).
  List<String> _mainFieldLabels(AppLocalizations l10n) => [
        l10n.zestHostFieldNickname,
        l10n.zestHostFieldAddress,
        l10n.zestHostFieldIdentity,
        l10n.zestHostFieldGroup,
        l10n.zestHostFieldNote,
        l10n.hostIconLabel,
        l10n.zestHostFieldTags,
        l10n.connectionEditTheme,
      ];

  /// A section of the Network, Automation and Wake-on-LAN fields, under their
  /// own label column: as wide as their longest name, at least the 132 they
  /// had, and their names above their values where beside them a name or a
  /// value would be cut (on a phone, at 1.3 times the text size; in Russian
  /// at the size the app is drawn at).
  Widget _withSecondaryLabels(Widget section) {
    final l10n = AppLocalizations.of(context)!;
    return ZestFieldLabels(
      labels: [
        l10n.connectionConnectVia,
        l10n.settingsKeepaliveInterval,
        l10n.connectionEditCustomInterval,
        l10n.connectionRunSnippet,
        l10n.connectionStartupCommand,
        l10n.connectionMacAddress,
        l10n.connectionBroadcastAddress,
      ],
      min: _kSecondaryLabelWidth,
      child: section,
    );
  }

  /// Desktop-dialog chrome: header strip with title + close, scrolling
  /// content area centred at a comfortable reading width, and a sticky
  /// footer with the Test group and Save.
  ///
  /// Replaces the old "Scaffold + AppBar + scroll-everything-including
  /// -the-action-buttons" layout that read fine on mobile but felt
  /// busy on desktop (multiple chrome layers, action buttons buried at
  /// the bottom of a long scroll).
  Widget _buildDialogChrome({
    required AppLocalizations l10n,
    required bool isEditing,
    required AsyncValue<List<Identity>> identitiesAsync,
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
    required AsyncValue<List<dynamic>> connectionsAsync,
  }) {
    return ColoredBox(
      color: ZestTokens.surfacePanel,
      child: Form(
        key: _formKey,
        child: Column(
          children: [
            // ── Header - host-card style (glyph + name + badge +
            //    live user@host:port subtitle, with subtle delete/close).
            _buildInspectorHeader(l10n, isEditing, identitiesAsync),
            // ── Body: section rail + active section (docked inspector) ──
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _InspectorRail(
                    active: _inspectorTab,
                    accent: _accentColor,
                    onSelect: (i) => setState(() => _inspectorTab = i),
                  ),
                  Expanded(
                    // IndexedStack keeps EVERY section built (it only shows
                    // one), so each section's GlobalKey + controllers stay
                    // alive and _save() reads them correctly no matter which
                    // tab is active - switching tabs never loses edits.
                    child: IndexedStack(
                      index: _inspectorTab,
                      sizing: StackFit.expand,
                      children: [
                        // 0 · Basic - two columns on a wide panel (connection
                        // details left, organise + live preview right); a
                        // narrow panel falls back to one stacked column (A3).
                        _inspectorPane(0, [
                          // Where a new host is saved (3.4).
                          if (!isEditing)
                            SaveInField(
                              value: _saveIn,
                              onChanged: (p) => setState(() => _saveIn = p),
                              padding: const EdgeInsets.only(bottom: 16),
                            ),
                          _buildBasicPane(l10n, identitiesAsync, groupsAsync),
                        ]),
                        // 1 · Auth
                        _inspectorPane(1, [
                          _buildAuthSection(),
                        ]),
                        // 2 · Network
                        _inspectorPane(2, [
                          if (_screen)
                            _screenNetworkNote()
                          else
                            _buildNetworkSection(
                                connectionsAsync: connectionsAsync),
                          // Rules per network: what SSH reads as it connects
                          // (address, port, account, jump hosts, skip); an
                          // FTPS host reads none of them, so none are shown.
                          if (!_ftps && !_screen) ...[
                            const SizedBox(height: 24),
                            _buildHostNetworkOverridesSection(
                                identitiesAsync: identitiesAsync),
                          ],
                          // (A host that is SFTP only forwards nothing.)
                          if (widget.connectionId != null && !_filesOnly) ...[
                            const SizedBox(height: 24),
                            _buildPortForwardsSection(),
                          ],
                        ]),
                        // 3 · Terminal (a line saying why there is none, for
                        // a host that is SFTP only)
                        _inspectorPane(3, [
                          _buildTerminalThemeDropdown(),
                        ]),
                        // 4 · Advanced
                        _inspectorPane(4, [
                          // What runs as a terminal starts, and its variables:
                          // not for a host that is SFTP only.
                          if (_filesOnly)
                            _sftpOnlyNote()
                          else
                            _buildAutomationSection(
                              snippetsAsync: snippetsAsync,
                              groupsAsync: groupsAsync,
                            ),
                          const SizedBox(height: 24),
                          _buildWakeOnLanSection(),
                          if (!_filesOnly) ...[
                            const SizedBox(height: 24),
                            _buildEnvVarsSection(),
                          ],
                          if (isEditing && _mayDelete) ...[
                            const SizedBox(height: 24),
                            _buildDeleteSection(l10n),
                          ],
                        ]),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // ── Test result banner (only when there's something to show) ──
            if (_testResult != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: _buildTestResultBanner(),
              ),
            // ── Sticky footer ──
            _buildDialogFooter(l10n, isEditing),
          ],
        ),
      ),
    );
  }

  /// Host-card style header for the docked inspector: protocol glyph, the
  /// connection's name + a protocol badge, and a live user@host:port
  /// subtitle. A subtle delete (edit only) and a close button sit at the
  /// right. Matches the redesign mockup.
  Widget _buildInspectorHeader(
    AppLocalizations l10n,
    bool isEditing,
    AsyncValue<List<Identity>> identitiesAsync,
  ) {
    // `.panel-head` - padding 12/14, gap 10, border-bottom 0.5px #26262a.
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: Border(
          bottom: BorderSide(color: ZestTokens.borderSubtle, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          // The host's icon, as its card draws it (it was the protocol's
          // glyph whatever the icon field said, 22 October 2026).
          KeyedSubtree(
            key: const ValueKey('host-edit-head-icon'),
            child: _hostIcon(30, _labelColor(ref.watch(connectionGroupsProvider)), cornerRadius: 8),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: AnimatedBuilder(
              animation: Listenable.merge(
                  [_labelController, _hostController, _portController]),
              builder: (context, _) {
                final label = _labelController.text.trim();
                final host = _hostController.text.trim();
                final port = _portController.text.trim();
                // Painted forms: masked by kind in recording mode.
                final name = label.isNotEmpty
                    ? Redactable.host(label).display
                    : (host.isNotEmpty
                        ? Redactable.address(host).display
                        : (isEditing
                            ? l10n.connectionEditTitle
                            : l10n.hostsNewHost));
                final username = _resolveUsername(identitiesAsync);
                final sub = host.isEmpty
                    ? l10n.connectionEditNoAddressYet
                    : _displayTarget(username, host, port);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: ZestTokens.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        _protocolBadge(),
                        // Unsaved-changes dot - 6px brand circle after the
                        // proto badge whenever the form is dirty.
                        if (_dirty) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l10n.zestDetailUnsaved,
                            child: Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                color: ZestTokens.brand,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: ZestTokens.textMuted,
                        fontFamily: _kMono,
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          const SizedBox(width: 6),
          // Move or copy to another place (4.0, a dropdown in
          // the top right): a saved host's, beside Share.
          if (isEditing)
            _moveCopyButton(
              builder: (context, open, label, focusNode) => _HeaderIconButton(
                icon: LucideIcons.folderInput,
                tooltip: label,
                onTap: open,
                focusNode: focusNode,
              ),
            ),
          // Share (QR / link) - parity with the mobile form's app-bar action.
          // Gated on isEditing exactly like delete, so half-filled drafts
          // can't be shared before they'd validate on the receiving side.
          if (isEditing && mayExportScreenSpace(ref) && ConnectionShareService.canShare(_protocol.name))
            _HeaderIconButton(
              icon: LucideIcons.share,
              tooltip: l10n.connectionEditShare,
              onTap: _shareConnection,
            ),
          // (Delete is in Advanced, red, away from close: beside it, one
          // was taken for the other, 22 October 2026.)
          // The way out of the editor (there is no Cancel in the footer): in
          // the danger colour, larger than the actions beside it.
          const SizedBox(width: 4),
          ZestCloseButton(
            key: const ValueKey('host-edit-close'),
            onPressed: _confirmDiscardThenClose,
          ),
        ],
      ),
    );
  }

  /// The saved host's Move or copy (4.0): its places, then Move here or Copy
  /// here; after a move the host is not here any more, and the editor
  /// closes. Not with changes not saved (what moves is what is saved).
  Widget _moveCopyButton({MoveCopyButtonBuilder? builder}) => MoveCopyMenuButton(
        kind: TransferKinds.host,
        itemKey: widget.connectionId!,
        hasUnsavedChanges: () => _dirty,
        onMoved: () {
          if (mounted) _closeEditor();
        },
        builder: builder,
      );

  Widget _protocolBadge() {
    // `.badge-proto` - 10px brand on #2d1e12, radius 4, padding 1/6.
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: ZestTokens.brandBadge,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        // (SFTP only by its short name: its full one says what it is for.)
        (_protocol == ConnectionProtocol.sftp
                ? AppLocalizations.of(context)!.connectionEditProtocolSftpShort
                : _protocol.nameIn(AppLocalizations.of(context)!))
            .toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: ZestTokens.brandInk,
        ),
      ),
    );
  }

  /// `user@host:port` for the header / preview, each part through its own
  /// recording-mode rule (the port survives the address rule).
  String _displayTarget(String username, String host, String port) {
    final user = username.isNotEmpty
        ? '${Redactable.username(username).display}@'
        : '';
    final address =
        Redactable.address(port.isNotEmpty ? '${bracketIpv6(host)}:$port' : host).display;
    return '$user$address';
  }

  String _resolveUsername(AsyncValue<List<Identity>> identitiesAsync) {
    if (_identityId == null) return '';
    final identities = identitiesAsync.valueOrNull ?? const <Identity>[];
    final id = identities.where((i) => i.id == _identityId).firstOrNull;
    return id?.username ?? '';
  }

  /// One scrollable section pane inside the docked inspector's IndexedStack.
  /// Each section keeps its own scroll offset because the panes stay built.
  ///
  /// [tabIndex] wraps the pane in its own [Form] keyed by
  /// [_inspectorTabFormKeys] so `_save` can validate panes independently and
  /// jump to the first one with an invalid field.
  Widget _inspectorPane(int tabIndex, List<Widget> children) {
    // Scope Tab traversal to this pane's fields. The docked editor is a layout
    // SIBLING in the desktop shell (not a modal route with its own FocusScope),
    // so without a group here Tab escapes the form and walks the shell chrome
    // (the section rail, the top bar) by global reading order instead of moving
    // to the next field. The group keeps Tab / Shift+Tab cycling through this
    // pane's inputs, top to bottom.
    return FocusTraversalGroup(
      child: Form(
        key: _inspectorTabFormKeys[tabIndex],
        child: SingleChildScrollView(
          // `.content` - padding 13px 14px.
          padding: const EdgeInsets.fromLTRB(14, 13, 14, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: children,
          ),
        ),
      ),
    );
  }

  /// Sticky bottom action bar shown only in desktop dialog mode.
  Widget _buildDialogFooter(AppLocalizations l10n, bool isEditing) {
    final showTest = _protocol == ConnectionProtocol.ssh ||
        _protocol == ConnectionProtocol.sftp ||
        _protocol == ConnectionProtocol.mosh ||
        _protocol == ConnectionProtocol.et ||
        _protocol == ConnectionProtocol.serial ||
        _ftps;
    // Shared sticky footer: the tests as one outlined group on the left, Save
    // alone on the right (disabled until the form is dirty). The header's
    // close button leaves the editor, so the footer has no Cancel. The group
    // goes one under the other where the footer leaves it less than it needs
    // side by side (a narrow editor, longer words).
    final group = _screen
        ? [
            ZestButtonGroupItem(
              key: const ValueKey('host-edit-screen-test'),
              label: l10n.screenTestButton,
              icon: LucideIcons.radio,
              isLoading: _isTesting,
              onPressed: _isTesting || _gatewayHost ? null : _testScreen,
            ),
          ]
        : showTest
            ? [
                ZestButtonGroupItem(
                  key: const ValueKey('host-edit-test-reachability'),
                  label: l10n.zestHostTestReachability,
                  icon: LucideIcons.radio,
                  isLoading: _isTesting && _runningTest == _HostTestKind.reachability,
                  onPressed: _isTesting ? null : () => _testReachability(_baseTestConfig()),
                ),
                ZestButtonGroupItem(
                  key: const ValueKey('host-edit-test-full'),
                  label: l10n.zestHostTestFull,
                  icon: LucideIcons.lock,
                  isLoading: _isTesting && _runningTest == _HostTestKind.full,
                  onPressed: _isTesting ? null : () => _testFullAuth(_baseTestConfig()),
                ),
              ]
            : null;
    return ZestPaneFooter(
      leading: group == null ? null : ZestButtonGroup(items: group),
      onSave: _maySave ? _save : null,
      saveEnabled: _dirty && _maySave,
      saveBusy: _isLoading,
      saveLabel: isEditing
          ? l10n.connectionSaveChanges
          : l10n.connectionSaveConnection,
    );
  }

  // ── Form layout builders ──────────────────────────────────────

  Widget _buildBasicFields(
    AppLocalizations l10n,
    AsyncValue<List<dynamic>> identitiesAsync,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.zestHostSectionConnection),
        ZestField.custom(
          label: l10n.zestHostFieldNickname,
          // Editor rule: the nickname is a host label, so it is masked (and
          // read-only behind the reveal gate) while recording mode is on.
          child: RecordingMaskedFormField(
            controller: _labelController,
            mask: (raw) => Redactable.host(raw).display,
            style: _kValStyle,
            decoration:
                _fieldDecoration(hintText: l10n.connectionNicknameHint),
            child: TextFormField(
              controller: _labelController,
              style: _kValStyle,
              decoration: _fieldDecoration(
                  hintText: l10n.connectionNicknameHint),
              textCapitalization: TextCapitalization.words,
            ),
          ),
        ),
        const SizedBox(height: 11),
        _buildProtocolField(l10n),
        ?_addScreenLine(l10n),
        // Explicit or implicit TLS, for an FTPS host (3.4).
        if (_ftps) _buildFtpsModeField(l10n),
        // A remote screen (4.0): the SSH host it is reached through, and
        // what it is on that host.
        if (_screen) ...[
          const SizedBox(height: 11),
          _buildScreenReachFields(l10n),
        ],
        const SizedBox(height: 11),
        if (_screenUnix) _buildScreenSocketField(l10n) else _buildAddressPortRow(l10n),
        const SizedBox(height: 7),
        // Identity / key - hidden for protocols that don't use one
        // (telnet, local shell).
        _buildIdentityDropdown(l10n, identitiesAsync),
        if (_screen) ...[
          _screenNote(_rdp ? l10n.connectionEditRdpPasswordNote : l10n.connectionEditScreenPasswordNote,
              key: const ValueKey('host-edit-screen-password-note')),
          _buildScreenMore(l10n),
        ] else
          _buildOtherAccounts(l10n, identitiesAsync),
      ],
    );
  }

  /// `.choice-label` caption (11px #8d8b83) sitting above a choice row or the
  /// colour swatches.
  Widget _labeledField(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _MChoiceLabel(label),
        child,
      ],
    );
  }

  /// Protocol chooser as segmented pills (one click, active reads at a
  /// glance) instead of a dropdown; on a phone ([phone]) a grid of tiles with
  /// their whole names, its name above it (it cut "Teln..." and "Seri..." in
  /// one row of pills).
  Widget _buildProtocolField(AppLocalizations l10n, {bool phone = false}) {
    // What this device can open: Mosh and Eternal Terminal need their client
    // on a computer, a local shell a computer or an Android phone. (A phone
    // offered all six, and Mosh, Eternal Terminal and an iPhone's local shell
    // failed to connect.) A host's own protocol is shown whatever it is.
    final onComputer = debugHostFormOnComputer ?? isDesktopPlatform;
    final localShell = !ref.read(databaseProvider).isOrchard && (debugHostFormLocalShell ?? LocalShellService.isAvailable);
    // A team's host saved already keeps its kind: an FTPS host shows FTPS
    // alone, a remote screen VNC alone, any other host every pill of its
    // class ([_savedKindClass]).
    final kindFixed = _teamKindFixed;
    final protocols = [
      for (final p in const [
        ConnectionProtocol.ssh,
        // Files only, on every device: SFTP is the app's own.
        ConnectionProtocol.sftp,
        // Files only over FTP with TLS (3.4), in a person's own space and in
        // a team's alike.
        ConnectionProtocol.ftps,
        // A remote screen (4.0), on every device.
        ConnectionProtocol.vnc,
        // RDP (4.0), once its session is in the app.
        ConnectionProtocol.rdp,
        ConnectionProtocol.mosh,
        ConnectionProtocol.et,
        ConnectionProtocol.telnet,
        ConnectionProtocol.serial,
        ConnectionProtocol.localShell,
      ])
        if (p == _protocol ||
            (!kindFixed || ConnectionProtocol.kindClassOf(p.name) == _savedKindClass) &&
                switch (p) {
                  // Mosh opens everywhere with the app's own client (4.0).
                  ConnectionProtocol.et => onComputer,
                  ConnectionProtocol.localShell => localShell,
                  ConnectionProtocol.rdp => ref.watch(rdpOfferedProvider),
                  _ => true,
                })
          p,
    ];
    // The pill of the host's protocol: FTPS's for either of its two.
    final current = _ftps ? ConnectionProtocol.ftps : _protocol;
    final Widget choices = phone
        ? PhoneChoiceGrid<ConnectionProtocol>(
            key: const ValueKey('host-form-protocols'),
            choices: [
              for (final p in protocols)
                PhoneChoice(
                  p,
                  _shortProtocolLabel(p),
                  // A screen reader says the whole name ("SFTP only (files, no
                  // terminal)", "Serial (SSH)").
                  semanticsLabel: p.nameIn(l10n),
                  key: ValueKey('host-form-protocol-${p.name}'),
                ),
            ],
            selected: current,
            groupFocused: _protocolFocused,
            onSelected: _onProtocolSelected,
          )
        : Row(
            children: [
              for (var i = 0; i < protocols.length; i++) ...[
                if (i > 0) const SizedBox(width: 5),
                Expanded(
                  child: _MChoicePill(
                    label: _shortProtocolLabel(protocols[i]),
                    selected: current == protocols[i],
                    focused: _protocolFocused && current == protocols[i],
                    tabStop: false,
                    onTap: () => _onProtocolSelected(protocols[i]),
                  ),
                ),
              ],
            ],
          );
    // The six pills are ONE Tab stop (a radio group): Tab focuses the group
    // and rings the active protocol, Left/Right (or Up/Down) rove between
    // them and move the selection, and Tab again moves on to Address. Each
    // pill is a GestureDetector (not individually focusable), so this Focus
    // is what makes the group keyboard-reachable. A phone's tiles the same.
    final group = Focus(
        onFocusChange: (f) => setState(() => _protocolFocused = f),
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          final idx = protocols.indexOf(current);
          if (idx < 0) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            _onProtocolSelected(protocols[(idx + 1) % protocols.length]);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
              event.logicalKey == LogicalKeyboardKey.arrowUp) {
            _onProtocolSelected(
                protocols[(idx - 1 + protocols.length) % protocols.length]);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: choices,
    );
    if (phone) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [PhoneFormLabel(l10n.zestHostFieldProtocol), group],
      );
    }
    return _labeledField(l10n.zestHostFieldProtocol, group);
  }

  /// Compact protocol label for the equal-width pill row - trims the two
  /// longest display names so all six pills fit one row at the narrowest
  /// pane width.
  String _shortProtocolLabel(ConnectionProtocol p) {
    final l10n = AppLocalizations.of(context)!;
    switch (p) {
      case ConnectionProtocol.serial:
        return l10n.connectionEditProtocolSerialShort;
      case ConnectionProtocol.sftp:
        return l10n.connectionEditProtocolSftpShort;
      case ConnectionProtocol.localShell:
        return l10n.connectionEditProtocolLocalShort;
      case ConnectionProtocol.et:
        return l10n.connectionEditProtocolEtShort;
      case ConnectionProtocol.ftps:
      case ConnectionProtocol.ftpsImplicit:
        return ConnectionProtocol.ftps.nameIn(l10n);
      default:
        return p.nameIn(l10n);
    }
  }

  void _onProtocolSelected(ConnectionProtocol v) {
    // The one it has, picked again: nothing changed (not even the port). The
    // FTPS pill picked again keeps its explicit or implicit TLS.
    if (v == _protocol || (v.isFtps && _ftps)) return;
    final l10n = AppLocalizations.of(context)!;
    // SSH and SFTP only are reached on the same port: one set for either
    // stays when the other is picked.
    final samePort = {v, _protocol}.containsAll(const [ConnectionProtocol.ssh, ConnectionProtocol.sftp]);
    _markDirty();
    setState(() {
      _protocol = v;
      switch (v) {
        case ConnectionProtocol.telnet:
          _portController.text = '23';
          showTopSnackBar(
            context,
            l10n.connectionEditTelnetWarning,
            isWarning: true,
            duration: const Duration(seconds: 5),
          );
        case ConnectionProtocol.serial:
          _portController.text = '3001';
          showTopSnackBar(
            context,
            l10n.connectionEditSerialInfo,
            isInfo: true,
            duration: const Duration(seconds: 5),
          );
        case ConnectionProtocol.mosh:
          _portController.text = '${ref.read(defaultPortProvider)}';
          showTopSnackBar(
            context,
            l10n.connectionEditMoshInfo,
            isInfo: true,
            duration: const Duration(seconds: 5),
          );
        case ConnectionProtocol.et:
          _portController.text = '${ref.read(defaultPortProvider)}';
          showTopSnackBar(
            context,
            l10n.connectionEditEtInfo,
            isInfo: true,
            duration: const Duration(seconds: 6),
          );
        case ConnectionProtocol.ssh:
          if (!samePort) _portController.text = '${ref.read(defaultPortProvider)}';
        case ConnectionProtocol.sftp:
          if (!samePort) _portController.text = '${ref.read(defaultPortProvider)}';
          showTopSnackBar(
            context,
            l10n.connectionEditSftpInfo,
            isInfo: true,
            duration: const Duration(seconds: 6),
          );
        case ConnectionProtocol.ftps:
        case ConnectionProtocol.ftpsImplicit:
          _portController.text = v == ConnectionProtocol.ftpsImplicit ? '990' : '21';
        case ConnectionProtocol.vnc:
          // A remote screen (4.0): the VNC server's port as its carrier sees
          // it, on the carrier itself, reached through the SSH host last used.
          _portController.text = '5900';
          if (_hostController.text.trim().isEmpty) _hostController.text = 'localhost';
          _connectViaId ??= _lastUsedCarrierId();
          _startScreenAtDefaultScaling();
        case ConnectionProtocol.rdp:
          // RDP (4.0): its own port, reached directly unless an SSH
          // host was picked already (a VNC host turned into one keeps its
          // carrier), and never at a Unix socket.
          _portController.text = '3389';
          _screenOptions = _screenOptions.copyWith(target: ScreenTargetKind.tcp, clearSocket: true);
          _socketController.clear();
          _startRdpAtItsScaling();
        case ConnectionProtocol.localShell:
        case ConnectionProtocol.demo:
          break;
      }
    });
  }

  /// Explicit or implicit TLS for an FTPS host (3.4). The port follows where
  /// it is the other's default (21 and 990).
  void _onFtpsModeSelected(ConnectionProtocol v) {
    if (v == _protocol) return;
    _markDirty();
    setState(() {
      final port = _portController.text.trim();
      if (v == ConnectionProtocol.ftpsImplicit && (port == '21' || port.isEmpty)) _portController.text = '990';
      if (v == ConnectionProtocol.ftps && (port == '990' || port.isEmpty)) _portController.text = '21';
      _protocol = v;
    });
  }

  /// The explicit and implicit choice, under the protocol, for an FTPS host;
  /// a phone's as its two segments ([phone]).
  Widget _buildFtpsModeField(AppLocalizations l10n, {bool phone = false}) {
    if (phone) {
      return Padding(
        key: const ValueKey('host-edit-ftps-mode'),
        padding: const EdgeInsets.only(top: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PhoneFormLabel(l10n.connectionEditFtpsMode),
            PhoneSegments<ConnectionProtocol>(
              choices: [
                for (final m in const [ConnectionProtocol.ftps, ConnectionProtocol.ftpsImplicit])
                  PhoneChoice(
                    m,
                    m == ConnectionProtocol.ftps ? l10n.connectionEditFtpsExplicit : l10n.connectionEditFtpsImplicit,
                    key: ValueKey('host-edit-ftps-${m.name}'),
                  ),
              ],
              selected: _protocol,
              onSelected: _onFtpsModeSelected,
            ),
            const SizedBox(height: 6),
            Text(
              l10n.connectionEditFtpsModeNote,
              style: TextStyle(color: ZestTokens.textMuted, fontSize: 12.5, height: 1.4),
            ),
          ],
        ),
      );
    }
    return Padding(
      key: const ValueKey('host-edit-ftps-mode'),
      padding: const EdgeInsets.only(top: 12),
      child: _labeledField(
        l10n.connectionEditFtpsMode,
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                for (final (i, m) in const [ConnectionProtocol.ftps, ConnectionProtocol.ftpsImplicit].indexed) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: _MChoicePill(
                      key: ValueKey('host-edit-ftps-${m.name}'),
                      label: m == ConnectionProtocol.ftps ? l10n.connectionEditFtpsExplicit : l10n.connectionEditFtpsImplicit,
                      selected: _protocol == m,
                      focused: false,
                      onTap: () => _onFtpsModeSelected(m),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l10n.connectionEditFtpsModeNote,
              style: TextStyle(color: ZestTokens.textMuted, fontSize: 11, height: 1.45),
            ),
          ],
        ),
      ),
    );
  }

  /// Address + Port as ONE combined field, in the SAME 40px container as every
  /// other field: label cell (88) | address input (expanded, mono) | a 1px
  /// divider | the port input in a fixed 64px segment (mono). The 64px width
  /// keeps a port like "22" from clipping. No extra padding is added around the
  /// inputs beyond the shared 11px region padding, so this row is exactly the
  /// same height as the Identity dropdown.
  Widget _buildAddressPortRow(AppLocalizations l10n) {
    // Each input named for a screen reader (the group's name is drawn beside
    // them, tied to neither: the port was an unnamed box).
    return ZestFieldGroup(
      label: l10n.zestHostFieldAddress,
      fields: [
        Semantics(label: l10n.zestHostFieldAddress, child: _buildAddressField(l10n)),
        SizedBox(
          width: kZestPortSegmentWidth,
          child: Semantics(label: l10n.connectionPort, child: _buildPortField(l10n)),
        ),
      ],
    );
  }

  Widget _buildAddressField(AppLocalizations l10n, {bool phone = false}) {
    // Editor rule: the address is masked (read-only behind the reveal gate)
    // while recording mode is on; validation still runs on the real text.
    final style = phone ? phoneFormValueStyle(mono: true) : _kValMonoStyle;
    final decoration = phone
        ? _phoneDecoration(l10n.phoneUiFormAddressHint)
        : _fieldDecorationTall(hintText: l10n.phoneUiFormAddressHint);
    return RecordingMaskedFormField(
      controller: _hostController,
      mask: (raw) => Redactable.address(raw).display,
      style: style,
      decoration: decoration,
      validate: () => _validateAddress(l10n, _hostController.text),
      child: TextFormField(
        key: phone ? const ValueKey('host-form-address') : null,
        controller: _hostController,
        style: style,
        decoration: decoration,
        keyboardType: TextInputType.url,
        autocorrect: false,
        validator: (v) => _validateAddress(l10n, v),
      ),
    );
  }

  /// A phone's box's bare decoration ([zestShellFieldDecoration]): its hint
  /// in the app's font a size up, its error under the value.
  InputDecoration _phoneDecoration(String? hint) => zestShellFieldDecoration(hintText: hint).copyWith(
        hintStyle: phoneFormHintStyle,
        errorStyle: TextStyle(color: ZestTokens.statusCritical, fontSize: 12.5, height: 1.3),
        errorMaxLines: 3,
      );

  String? _validateAddress(AppLocalizations l10n, String? v) {
    if (_protocol == ConnectionProtocol.localShell) return null;
    // A remote screen through its carrier: at a socket there is no address,
    // and none means the carrier itself (localhost).
    if (_screenUnix || (_screen && _connectViaId != null && (v == null || v.trim().isEmpty))) return null;
    if (v == null || v.isEmpty) return l10n.connectionAddressRequired;
    // A remote screen's address takes no user ("alex@10.0.2.2" was saved as
    // the host's name, and the SSH host it is reached through signed in as
    // Settings' default user): the SSH user is that host's key's, and a VNC
    // user name is this screen's key's.
    if (_screen && v.contains('@')) {
      return _rdp ? l10n.connectionEditRdpAddressUser : l10n.connectionEditScreenAddressUser;
    }
    // Reject control characters and whitespace in hostname
    if (RegExp(r'[\x00-\x1f\s]').hasMatch(v)) {
      return l10n.connectionEditAddressInvalidChars;
    }
    if (v.length > 253) return l10n.connectionEditAddressTooLong;
    return null;
  }

  Widget _buildPortField(AppLocalizations l10n, {bool phone = false}) {
    return TextFormField(
      key: const ValueKey('host-port'),
      controller: _portController,
      style: phone ? phoneFormValueStyle(mono: true) : _kValMonoStyle,
      decoration: phone ? _phoneDecoration('22') : _fieldDecorationTall(hintText: '22'),
      keyboardType: TextInputType.number,
      validator: (v) {
        if (_protocol == ConnectionProtocol.localShell || _screenUnix) return null;
        if (v == null || v.isEmpty) return l10n.connectionPortRequired;
        final port = int.tryParse(v);
        if (port == null || port < 1 || port > 65535) {
          return l10n.connectionPortInvalid;
        }
        return null;
      },
    );
  }

  Widget _buildIdentityDropdown(
    AppLocalizations l10n,
    AsyncValue<List<dynamic>> identitiesAsync,
  ) {
    if (!_signsInWithKey) return const SizedBox.shrink();
    return identitiesAsync.when(
      data: (identities) {
        // The app's select, drawn in the field's shell (a Material dropdown
        // sat in it, its value above the name's line; found in a design
        // audit). Create new key makes one rather than being
        // chosen.
        return ZestSelect<String?>(
          value: _identityId,
          hint: l10n.connectionIdentityHint,
          items: [
            ZestSelectItem(null, l10n.none),
            for (final i in identities)
              // Masked label; the item's value stays the real id.
              ZestSelectItem(
                i.id as String,
                '${Redactable.keyName(i.label as String).displayIn(ref)} '
                '(${Redactable.username(i.username as String).displayIn(ref)})',
              ),
          ],
          actions: [
            ZestSelectAction(
              l10n.connectionCreateNewIdentity,
              icon: LucideIcons.plusCircle,
              onPressed: _createIdentity,
            ),
          ],
          onChanged: (v) {
            // The one it has, picked again: nothing changed.
            if (v == _identityId) return;
            setState(() => _pickDefaultAccount(v));
            _markDirty();
          },
          frame: (value) => ZestField.custom(label: l10n.zestHostFieldIdentity, child: value),
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => Text(l10n.connectionErrorLoadingIdentities),
    );
  }

  /// Create new key, from the key list: the key editor, and the key made
  /// there is the one the host signs in with.
  void _createIdentity() => _createKeyThen((newId) => _identityId = newId);

  /// Create new key, from Add another key: the key made in the key editor
  /// joins the host's other accounts (adding
  /// another key had no way to make one).
  void _createOtherAccount() => _createKeyThen((newId) {
        if (newId != _identityId && !_otherAccounts.contains(newId)) {
          _otherAccounts = [..._otherAccounts, newId];
          _otherAccountsDirty = true;
        }
      });

  /// Opens the key editor; the key made there, if any, is given to [use].
  void _createKeyThen(void Function(String newId) use) {
    context.push<String?>(Routes.identityEdit).then((newId) {
      ref.invalidate(identitiesProvider);
      if (newId != null && mounted) {
        setState(() => use(newId));
        _markDirty();
      }
    });
  }

  /// [id] becomes the identity the host is signed in to with by default. It
  /// leaves the other accounts if it was one; with none chosen, the first
  /// other account takes its place, since a host's other accounts stand
  /// beside a default one.
  void _pickDefaultAccount(String? id) {
    var others = [for (final o in _otherAccounts) if (o != id) o];
    if (id == null && others.isNotEmpty) {
      id = others.first;
      others = others.sublist(1);
    }
    if (others.length != _otherAccounts.length) _otherAccountsDirty = true;
    _identityId = id;
    _otherAccounts = others;
  }

  /// The host's other accounts (3.0, accounts per host), below its default
  /// identity: each with "Use by default" (it and the default change
  /// places) and Remove, and "Add an account" with the identities the host
  /// does not have yet. Shown where the host has a default identity, for
  /// the protocols that use one.
  Widget _buildOtherAccounts(AppLocalizations l10n, AsyncValue<List<dynamic>> identitiesAsync, {bool phone = false}) {
    if (!_signsInWithKey) return const SizedBox.shrink();
    if (_identityId == null && _otherAccounts.isEmpty) return const SizedBox.shrink();
    final identities = identitiesAsync.valueOrNull;
    if (identities == null) return const SizedBox.shrink();
    final byId = {for (final i in identities) i.id as String: i};
    String name(dynamic i) => '${Redactable.keyName(i.label as String).displayIn(ref)} '
        '(${Redactable.username(i.username as String).displayIn(ref)})';
    final shown = [for (final id in _otherAccounts) if (byId.containsKey(id)) id];
    final addable = [
      for (final i in identities)
        if (i.id != _identityId && !_otherAccounts.contains(i.id)) i,
    ];
    void change(void Function() edit) {
      setState(() {
        edit();
        _otherAccountsDirty = true;
        _otherAccountsLoaded = true;
      });
      _markDirty();
    }

    // Indented to where the Identity field's value starts, so each other
    // identity reads as the field going on (a phone's names are above its
    // values: not indented).
    final start = phone ? 0.0 : zestFieldValueStart(context);
    return Padding(
      padding: EdgeInsetsDirectional.only(start: start, top: shown.isEmpty ? 4 : 6),
      child: Column(
        key: const ValueKey('host-accounts'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final id in shown)
            Container(
              key: ValueKey('host-account-$id'),
              margin: const EdgeInsets.only(bottom: 6),
              constraints: const BoxConstraints(minHeight: 40),
              padding: const EdgeInsetsDirectional.only(start: 12),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceSunken,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZestTokens.border),
              ),
              child: Row(
                children: [
                  Icon(LucideIcons.cornerDownRight, size: 15, color: ZestTokens.textTertiary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(name(byId[id]), style: _kValStyle, overflow: TextOverflow.ellipsis),
                  ),
                  TextButton(
                    key: ValueKey('host-account-default-$id'),
                    onPressed: () => change(() {
                      final at = _otherAccounts.indexOf(id);
                      final previous = _identityId;
                      final others = [..._otherAccounts];
                      if (previous == null) {
                        others.removeAt(at);
                      } else {
                        others[at] = previous;
                      }
                      _identityId = id;
                      _otherAccounts = others;
                    }),
                    child: Text(l10n.hostAccountsMakeDefault),
                  ),
                  IconButton(
                    key: ValueKey('host-account-remove-$id'),
                    tooltip: l10n.commonRemove,
                    icon: Icon(LucideIcons.x, size: 16, color: ZestTokens.textTertiary),
                    onPressed: () => change(() => _otherAccounts = [for (final o in _otherAccounts) if (o != id) o]),
                  ),
                ],
              ),
            ),
          // Shown with no other key left to pick too: Create new key makes one.
          if (_identityId != null)
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: PopupMenuButton<String>(
                key: const ValueKey('host-accounts-add'),
                tooltip: l10n.hostAccountsHelp,
                onSelected: (id) => id == _kCreateNewKey
                    ? _createOtherAccount()
                    : change(() => _otherAccounts = [..._otherAccounts, id]),
                itemBuilder: (_) => [
                  for (final i in addable)
                    PopupMenuItem<String>(
                      key: ValueKey('host-accounts-add-${i.id}'),
                      value: i.id as String,
                      child: Text(name(i)),
                    ),
                  if (addable.isNotEmpty) const PopupMenuDivider(),
                  PopupMenuItem<String>(
                    key: const ValueKey('host-accounts-create'),
                    value: _kCreateNewKey,
                    child: Row(
                      children: [
                        Icon(LucideIcons.plusCircle, size: 16, color: AppColors.accentInk),
                        const SizedBox(width: 10),
                        Text(l10n.connectionCreateNewIdentity),
                      ],
                    ),
                  ),
                ],
                // Words to click, not a button (a finger's height on a phone).
                child: Padding(
                  padding: EdgeInsets.symmetric(vertical: phone ? 13 : 3),
                  child: Text(
                    l10n.hostAccountsAddAnother,
                    style: TextStyle(fontSize: 12.5, color: AppColors.accentInk, fontWeight: FontWeight.w500),
                  ),
                ),
              ),
            ),
          if (shown.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(l10n.hostAccountsHelp, style: TextStyle(fontSize: 11.5, color: ZestTokens.textTertiary)),
          ],
        ],
      ),
    );
  }

  /// Basic tab body - a single scrolling column: Connection fields, the
  /// Organise section (group, colour label, tags, note), then the live preview
  /// card. Matches the mockup's single-column Basic layout.
  Widget _buildBasicPane(
    AppLocalizations l10n,
    AsyncValue<List<Identity>> identitiesAsync,
    AsyncValue<List<dynamic>> groupsAsync,
  ) {
    // Single scrolling column (Connection → Organise → Preview), exactly as
    // the mockup lays out the Basic tab.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildBasicFields(l10n, identitiesAsync),
        const SizedBox(height: 18),
        _buildOrganiseSection(l10n, groupsAsync),
        const SizedBox(height: 18),
        _buildHostCardPreview(l10n, identitiesAsync, groupsAsync),
      ],
    );
  }

  /// The live preview: the host's card itself ([HostCard]), as the Hosts
  /// page's grid will draw it, from what the form holds now (the
  /// preview is the real card).
  Widget _buildHostCardPreview(
    AppLocalizations l10n,
    AsyncValue<List<Identity>> identitiesAsync,
    AsyncValue<List<dynamic>> groupsAsync,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.zestHostSectionPreview),
        AnimatedBuilder(
          animation: Listenable.merge([_labelController, _hostController, _portController, _socketController]),
          builder: (context, _) {
            final label = _labelController.text.trim();
            final host = _hostController.text.trim();
            final username = _resolveUsername(identitiesAsync);
            final group = _groupOf(groupsAsync);
            final groupColor = group == null
                ? null
                : resolveGroupColor(
                    colorValue: group.colorValue as int?,
                    colorIndex: group.colorIndex as int?,
                    name: group.name as String,
                  );
            final data = HostCardData(
              id: widget.connectionId ?? '__new_host_preview',
              name: label.isNotEmpty
                  ? label
                  : (host.isNotEmpty ? host : l10n.connectionPreviewNewName),
              // A remote screen: where it listens and the host it is reached
              // through (an empty address through a host is localhost).
              subtitle: _screen && (host.isNotEmpty || _connectViaId != null)
                  ? screenCardSubtitle(
                      host: host,
                      port: int.tryParse(_portController.text.trim()) ?? 5900,
                      socket: _screenUnix ? _socketController.text.trim() : null,
                      carrier: _carrierName(),
                      via: l10n.pfPageVia,
                    )
                  : host.isEmpty
                  ? l10n.connectionPreviewNoAddress
                  : hostCardSubtitle(username.isEmpty ? 'root' : username, host, _protocol.name),
              osId: _detectedOsId,
              iconId: _shownIconId,
              customIcon: _customIcon,
              iconColor: _iconColor,
              colorValue: _colorValue,
              colorIndex: _colorIndex,
              groupColor: groupColor,
              groupName: group?.name as String?,
              // The grid's sections name the group; its card shows no chip.
              showGroupChip: false,
              status: HostStatus.offline,
              hasActiveSession: false,
              tags: _tags,
            );
            return LayoutBuilder(
              builder: (context, box) => SizedBox(
                key: const ValueKey('host-edit-preview'),
                // About a card of the grid's width.
                width: box.maxWidth.clamp(0.0, 320.0),
                child: IgnorePointer(child: HostCard(data: data)),
              ),
            );
          },
        ),
      ],
    );
  }

  /// New group from the group list: the group is made and the form has the
  /// host in it (saved with the host); cancelled, the list shows what it
  /// had (New group is not a choice, so nothing was picked).
  Future<void> _newGroupFromList() async {
    final label = _labelController.text.trim();
    final made = await showNewGroupSheet(context, forHost: label.isEmpty ? null : label);
    if (!mounted || made == null) return;
    setState(() {
      _madeGroup = made;
      _groupId = made.id;
    });
    _markDirty();
  }

  /// A field of the Organise section: in its shell with its name beside it,
  /// or, on a phone ([phone]), its name above it and the phone's box.
  Widget _organiseField(
    String label,
    Widget child, {
    required bool phone,
    bool tall = false,
    String? helperText,
    ValueChanged<double>? onResize,
  }) {
    if (!phone) {
      return ZestField.custom(label: label, tall: tall, helperText: helperText, onResize: onResize, child: child);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        PhoneFormLabel(label),
        PhoneFormBox(
          padding: tall ? const EdgeInsets.fromLTRB(14, 12, 14, 12) : const EdgeInsets.symmetric(horizontal: 14),
          alignment: tall ? AlignmentDirectional.topStart : AlignmentDirectional.centerStart,
          child: child,
        ),
        if (helperText != null) ...[
          const SizedBox(height: 6),
          Text(helperText, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textMuted)),
        ],
      ],
    );
  }

  Widget _buildOrganiseSection(
    AppLocalizations l10n,
    AsyncValue<List<dynamic>> groupsAsync, {
    bool phone = false,
  }) {
    // The colour's name above its swatches, as the app's or as a phone's.
    Widget labelled(String label, Widget child) => phone
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [PhoneFormLabel(label), child])
        : _labeledField(label, child);
    return Column(
      crossAxisAlignment: phone ? CrossAxisAlignment.stretch : CrossAxisAlignment.start,
      children: [
        // A phone's section is its own row, More options: no heading.
        if (!phone) ZestSectionHeader(label: l10n.zestHostSectionOrganise),
        groupsAsync.when(
          data: (groups) {
            // A phone and a tablet make a group from here too (3.0.1), where
            // groups may be made: the list ends with New group. A computer
            // makes them in its group editor.
            final canMake = isTouchLayout && mayAddScreenSpace(ref);
            if (groups.isEmpty && !canMake) return const SizedBox.shrink();
            final made = _madeGroup;
            final madeMissing = made != null && made.id == _groupId && !groups.any((g) => g.id == made.id);
            return Padding(
              padding: EdgeInsets.only(bottom: phone ? 14 : 11),
              // The app's select in the field's shell (found in a design
              // audit): New group makes one rather than being
              // chosen.
              child: ZestSelect<String?>(
                key: const ValueKey('host-form-group'),
                value: _groupId,
                large: phone,
                hint: l10n.connectionGroupHint,
                items: [
                  ZestSelectItem(null, l10n.none),
                  for (final g in groups)
                    ZestSelectItem(g.id as String, Redactable.group(g.name as String).displayIn(ref)),
                  if (madeMissing) ZestSelectItem(made.id, Redactable.group(made.name).displayIn(ref)),
                ],
                actions: [
                  if (canMake)
                    ZestSelectAction(
                      l10n.phoneGroupsNewGroupMore,
                      key: const ValueKey('host-group-new'),
                      icon: LucideIcons.folderPlus,
                      onPressed: _newGroupFromList,
                    ),
                ],
                onChanged: (v) {
                  if (v == _groupId) return;
                  setState(() => _groupId = v);
                  _markDirty();
                },
                frame: (value) => _organiseField(l10n.zestHostFieldGroup, value, phone: phone),
              ),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
        ),
        labelled(
          l10n.zestHostFieldColor,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // One row, made a little smaller where the field is narrower
              // than every swatch (a phone): wrapped, one or two of them
              // stood alone on a second line.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: AlignmentDirectional.centerStart,
                child: ZestColorPicker(
                presets: AppColors.labelPalette,
                selected: AppColors.labelColorFor(_colorValue, _colorIndex),
                // Any explicit pick persists as `colorValue` (index cleared to
                // 0); None is the unambiguous colorValue==null && index==0.
                allowCustom: true,
                allowNone: true,
                noneSelected: _colorValue == null && _colorIndex == 0,
                onNoneSelected: () {
                  if (_colorValue == null && _colorIndex == 0) return;
                  setState(() {
                    _colorValue = null;
                    _colorIndex = 0;
                  });
                  _markDirty();
                },
                onChanged: (c) {
                  if (c.toARGB32() == _colorValue && _colorIndex == 0) return;
                  setState(() {
                    _colorValue = c.toARGB32();
                    _colorIndex = 0;
                  });
                  _markDirty();
                },
              ),
              ),
              const SizedBox(height: 7),
              _buildColorHelper(l10n, groupsAsync),
            ],
          ),
        ),
        SizedBox(height: phone ? 14 : 11),
        _buildIconField(l10n, groupsAsync, phone: phone),
        SizedBox(height: phone ? 14 : 11),
        _buildTagsField(l10n, phone: phone),
        SizedBox(height: phone ? 14 : 11),
        _organiseField(
          l10n.zestHostFieldNote,
          phone: phone,
          tall: true,
          // The grip sets the box's height, from where it is now (it
          // could not be dragged).
          // A phone's Note grows with its words; a grip there is a corner too
          // small for a finger, and the page scrolls past it.
          onResize: zestUsesSheets(context) ? null : (dy) => setState(() {
            final now = _noteHeight ?? _noteBox.currentContext?.size?.height ?? _kNoteMinHeight;
            _noteHeight = (now + dy).clamp(_kNoteMinHeight, _kNoteMaxHeight);
          }),
          helperText: l10n.zestHostNoteHelp,
          SizedBox(
            key: _noteBox,
            height: _noteHeight,
            child: TextField(
              key: phone ? const ValueKey('host-form-note') : null,
              controller: _noteController,
              // Starts at the shared 40px height (one line) and grows with
              // content, matching the mockup's Note field; once its grip set
              // a height, it fills that and scrolls past it.
              minLines: _noteHeight == null ? 1 : null,
              maxLines: _noteHeight == null ? 6 : null,
              expands: _noteHeight != null,
              textAlignVertical: TextAlignVertical.top,
              maxLength: 280,
              style: phone ? phoneFormValueStyle().copyWith(height: 1.45) : _kValStyle.copyWith(height: 1.6),
              decoration: (phone ? _phoneDecoration(null) : _fieldDecoration()).copyWith(counterText: ''),
            ),
          ),
        ),
      ],
    );
  }

  /// The host-card icon row: the current icon, a one-line description of the
  /// choice, and a Change button that opens the picker. Both null = auto.
  Widget _buildIconField(
    AppLocalizations l10n,
    AsyncValue<List<dynamic>> groupsAsync, {
    bool phone = false,
  }) {
    final isCustom = _customIcon != null && _customIcon!.isNotEmpty;
    // Auto: its value, with the system seen on the host under it (or when
    // it will be), where "Auto, from the detected OS" was cut on a phone.
    final auto = !isCustom && _iconId == null;
    final value = isCustom
        ? l10n.hostIconCustomSubtitle
        : _iconId != null
            ? hostIconName(OsCatalog.get(_iconId), l10n)
            : l10n.phoneUiFormIconAuto;
    final detected = !auto || widget.connectionId == null ? null : ref.watch(detectedOsProvider(widget.connectionId!));
    // A remote screen's Auto is a screen, whatever runs behind it: nothing
    // is seen of its system, so it never "follows the system once connected".
    final autoNote = !auto
        ? null
        : _screen
            ? hostIconName(OsCatalog.get(defaultIconIdFor(_protocol.name)), l10n)
        : detected != null && detected != OsKind.unknown
            ? OsIconWidget.labelForOs(detected)
            : l10n.phoneUiFormIconAutoPending;
    final label = _labelColor(groupsAsync);
    return _organiseField(
      l10n.hostIconLabel,
      phone: phone,
      LayoutBuilder(builder: (context, box) {
        // Where the button's words would not fit beside the icon and a little
        // of its name, the button is a pencil, its words its tooltip (in a
        // phone's narrow field at 1.3 times the text size, "Изменить" ran
        // out of it).
        final words = TextPainter(
          text: TextSpan(text: l10n.hostIconChange, style: Theme.of(context).textTheme.labelLarge),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final needed = 28 + 11 + 8 + words.width + 24 + 40;
        words.dispose();
        return Row(
          children: [
            KeyedSubtree(
              key: const ValueKey('host-edit-field-icon'),
              child: _hostIcon(28, label),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Padding(
                padding: EdgeInsets.symmetric(vertical: autoNote == null ? 0 : 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: phone ? phoneFormValueStyle() : _kValStyle),
                    if (autoNote != null)
                      Text(
                        autoNote,
                        key: const ValueKey('host-icon-auto-note'),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: phone ? 13 : 11.5, height: 1.3, color: ZestTokens.textTertiary),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (box.maxWidth >= needed)
              TextButton(
                onPressed: () => _pickIcon(groupsAsync),
                // A mouse's 32 high at least (the compact theme drew 30).
                style: TextButton.styleFrom(minimumSize: Size(0, minTapTarget(context))),
                child: Text(l10n.hostIconChange),
              )
            else
              IconButton(
                key: const ValueKey('host-icon-change'),
                onPressed: () => _pickIcon(groupsAsync),
                tooltip: l10n.hostIconChange,
                icon: const Icon(LucideIcons.pencil, size: 18),
              ),
          ],
        );
      }),
    );
  }

  Future<void> _pickIcon(AsyncValue<List<dynamic>> groupsAsync) async {
    final group = _groupOf(groupsAsync);
    final choice = await showHostIconPicker(
      context,
      currentIconId: _iconId,
      currentCustomIcon: _customIcon,
      currentIconColor: _iconColor,
      labelColor: _labelColor(groupsAsync),
      labelSource: AppColors.hasExplicitConnectionLabel(_colorValue, _colorIndex)
          ? HostLabelColorSource.label
          : group != null
              ? HostLabelColorSource.group
              : HostLabelColorSource.none,
      groupName: group?.name as String?,
      // The system seen on it, for Auto to name (none before it connects).
      autoIconId: defaultIconIdFor(_protocol.name),
      detectedOs: _screen
          ? hostIconName(OsCatalog.get(defaultIconIdFor(_protocol.name)), AppLocalizations.of(context)!)
          : switch (widget.connectionId == null ? null : ref.read(detectedOsProvider(widget.connectionId!))) {
        final OsKind kind when kind != OsKind.unknown => OsIconWidget.labelForOs(kind),
        _ => null,
      },
    );
    if (choice == null || !mounted) return;
    if (choice.iconId == _iconId &&
        choice.customIcon == _customIcon &&
        choice.iconColor == _iconColor) {
      return; // the icon it has, picked again
    }
    setState(() {
      _iconId = choice.iconId;
      _customIcon = choice.customIcon;
      _iconColor = choice.iconColor;
    });
    _markDirty();
  }

  /// State-driven helper under the colour swatches. Reflects whether the
  /// current pick overrides the group's colour, inherits it (with a colour
  /// dot), or the host has no colour at all.
  Widget _buildColorHelper(
    AppLocalizations l10n,
    AsyncValue<List<dynamic>> groupsAsync,
  ) {
    final hasOverride =
        AppColors.hasExplicitConnectionLabel(_colorValue, _colorIndex);
    dynamic group;
    if (_groupId != null) {
      final groups = groupsAsync.valueOrNull;
      if (groups != null) {
        for (final g in groups) {
          if (g.id == _groupId) {
            group = g;
            break;
          }
        }
      }
    }
    final String? groupName = group?.name as String?;

    if (groupName == null) {
      // No group to inherit from: an explicit pick just shows on the swatch;
      // otherwise the host carries no colour.
      if (hasOverride) return const SizedBox.shrink();
      return _colorHelperText(l10n.zestColorNoColor);
    }
    if (hasOverride) {
      return _colorHelperText(l10n.zestColorOverridesGroup(groupName));
    }
    final groupColor = resolveGroupColor(
      colorValue: group.colorValue as int?,
      colorIndex: group.colorIndex as int?,
      name: groupName,
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration: BoxDecoration(color: groupColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 7),
        Flexible(child: _colorHelperText(l10n.zestColorUsingGroup(groupName))),
      ],
    );
  }

  // `.helper` line under the swatches - 11px #78766f.
  Widget _colorHelperText(String text) => Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: ZestTokens.textMuted,
          height: 1.5,
        ),
      );

  /// Free-form tags field (autocompletes from existing tags). Guards a
  /// late async load from clobbering an in-flight edit via [_tagsDirty].
  Widget _buildTagsField(AppLocalizations l10n, {bool phone = false}) {
    return _organiseField(
      l10n.zestHostFieldTags,
      phone: phone,
      tall: true,
      Consumer(
        builder: (context, ref, _) {
          final allTags =
              ref.watch(allTagsProvider).valueOrNull ?? const <String>[];
          return _InlineTagsField(
            hintText: l10n.zestHostAddTag,
            tags: _tags,
            availableTags: allTags,
            onChanged: (next) {
              setState(() {
                _tags = next;
                _tagsDirty = true;
                _tagsLoaded = true;
              });
              _markDirty();
            },
          );
        },
      ),
    );
  }

  /// Auth pane - advanced authentication/security toggles. The key itself is
  /// chosen under Basic → CONNECTION; this holds the behaviours that ride on
  /// top of it (SSH only). Non-SSH protocols show a friendly empty state.
  Widget _buildAuthSection() {
    final l10n = AppLocalizations.of(context)!;
    // SFTP only signs in as SSH does, older algorithms where Compatibility
    // mode is on; agent forwarding is for a terminal's next hop, and it has
    // none.
    if (_sftpOnly) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZestSectionHeader(label: l10n.connectionEditAuthOptionsTitle),
          Text(
            l10n.connectionEditAuthSftpOnly,
            style: TextStyle(
              color: ZestTokens.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: const ValueKey('host-edit-compat-sftp'),
            child: _MToggleRow(
              label: l10n.connectionEditCompatibilityModeLabel,
              note: l10n.connectionEditCompatibilityModeNote,
              warnWhenOn: true,
              value: _compatibilityMode,
              onChanged: (v) {
                setState(() => _compatibilityMode = v);
                _markDirty();
              },
            ),
          ),
        ],
      );
    }
    if (_ftps) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZestSectionHeader(label: l10n.connectionEditAuthTitle),
          Text(
            l10n.connectionEditAuthFtps,
            key: const ValueKey('host-edit-auth-ftps'),
            style: TextStyle(color: ZestTokens.textMuted, fontSize: 11, height: 1.5),
          ),
        ],
      );
    }
    if (_protocol != ConnectionProtocol.ssh) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZestSectionHeader(label: l10n.connectionEditAuthTitle),
          Text(
            _protocol == ConnectionProtocol.localShell
                ? l10n.connectionEditAuthLocalShell
                : l10n.connectionEditAuthNonSshOptions(_protocol.nameIn(l10n)),
            style: TextStyle(
              color: ZestTokens.textMuted,
              fontSize: 11,
              height: 1.5,
            ),
          ),
          // A serial line is reached over SSH, which takes the older
          // algorithms where this is on: offered here as for SSH.
          if (_protocol == ConnectionProtocol.serial) ...[
            const SizedBox(height: 8),
            KeyedSubtree(
              key: const ValueKey('host-edit-compat-serial'),
              child: _MToggleRow(
                label: l10n.connectionEditCompatibilityModeLabel,
                note: l10n.connectionEditCompatibilityModeNote,
                warnWhenOn: true,
                value: _compatibilityMode,
                onChanged: (v) {
                  setState(() => _compatibilityMode = v);
                  _markDirty();
                },
              ),
            ),
          ],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.connectionEditAuthOptionsTitle),
        Text(
          l10n.connectionEditAuthOptionsBody,
          style: TextStyle(
            color: ZestTokens.textMuted,
            fontSize: 11,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 8),
        _MToggleRow(
          label: l10n.connectionEditForwardAgent,
          note: l10n.connectionEditForwardAgentNote,
          value: _forwardAgent,
          onChanged: (v) {
            setState(() => _forwardAgent = v);
            _markDirty();
          },
        ),
        // Not recommended, and for old servers only: its label says so,
        // and its note is in the warning colour while it is on.
        _MToggleRow(
          label: l10n.connectionEditCompatibilityModeLabel,
          note: l10n.connectionEditCompatibilityModeNote,
          warnWhenOn: true,
          value: _compatibilityMode,
          onChanged: (v) {
            setState(() => _compatibilityMode = v);
            _markDirty();
          },
        ),
      ],
    );
  }

  /// Said where a terminal's settings would be, for a host that is SFTP only.
  Widget _sftpOnlyNote({Key? key}) => Row(
        key: key,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(LucideIcons.folderOpen, size: 15, color: ZestTokens.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _screen
                  ? AppLocalizations.of(context)!.hostScreenNoTerminal
                  : _ftps
                      ? AppLocalizations.of(context)!.hostFtpsNoTerminal
                      : AppLocalizations.of(context)!.hostSftpOnlyNoTerminal,
              style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textMuted),
            ),
          ),
        ],
      );

  Widget _buildTerminalThemeDropdown() {
    final l10n = AppLocalizations.of(context)!;
    // No terminal, so no theme for one.
    if (_filesOnly) return _sftpOnlyNote(key: const ValueKey('host-edit-sftp-no-terminal'));
    final themeNames = TerminalThemes.names;
    final themeIds = themeNames.keys.toList();
    final isPro = ref.watch(isProProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // `.banner` - Override app defaults. Off means the host follows the
        // global terminal settings (per-host theme cleared on save).
        _MBanner(
          title: l10n.connectionEditOverrideDefaults,
          subtitle: l10n.connectionEditOverrideDefaultsSub,
          value: _terminalOverride,
          onChanged: (v) {
            setState(() {
              _terminalOverride = v;
              if (!v) _terminalThemeId = null;
            });
            _markDirty();
          },
        ),
        if (_terminalOverride) ...[
          ZestSectionHeader(label: l10n.connectionEditAppearance),
          // The app's select in the field's shell (found in a design
          // audit); a theme the plan does not include is shown with
          // its lock and cannot be chosen.
          ZestSelect<String?>(
            value: _terminalThemeId,
            hint: l10n.connectionEditThemeDefault,
            items: [
              ZestSelectItem(null, l10n.connectionEditThemeDefault),
              for (final id in themeIds)
                if (!isPro && !TerminalThemes.freeThemeIds.contains(id) && !TerminalThemes.isCustomTheme(id))
                  ZestSelectItem(id, themeNames[id] ?? id, enabled: false, trailingIcon: LucideIcons.lock)
                else
                  ZestSelectItem(id, themeNames[id] ?? id),
            ],
            onChanged: (v) {
              if (v == _terminalThemeId) return;
              setState(() => _terminalThemeId = v);
              _markDirty();
            },
            frame: (value) => ZestField.custom(label: l10n.connectionEditTheme, child: value),
          ),
        ] else
          Text(
            l10n.connectionEditThemeGlobalNote,
            style: TextStyle(fontSize: 11, color: ZestTokens.textMuted, height: 1.5),
          ),
      ],
    );
  }

  /// Whether a saved host has any of what a phone's More options holds (a
  /// group, a colour label, an icon of its own, tags, a note): it opens with
  /// the form, so nothing set is hidden behind it.
  bool get _organiseHasValues =>
      _groupId != null ||
      AppColors.hasExplicitConnectionLabel(_colorValue, _colorIndex) ||
      _iconId != null ||
      (_customIcon?.isNotEmpty ?? false) ||
      _iconColor != null ||
      _tags.isNotEmpty ||
      _noteController.text.trim().isNotEmpty;

  /// Whether the form lacks the address it needs to be saved: every host but
  /// a local shell, and a remote screen on its carrier (none there is the
  /// carrier itself) or at a socket on it.
  bool get _addressMissing =>
      _hostController.text.trim().isEmpty &&
      _protocol != ConnectionProtocol.localShell &&
      !_screenUnix &&
      !(_screen && _connectViaId != null);

  /// A phone's form (4.0 UI),
  /// and a narrow window's: each field's name above it;
  /// the protocols as tiles; the address with its port beside it, what it
  /// signs in with, and its nickname; the group, colour, icon, tags and note
  /// folded under More options and the advanced options under a row of their
  /// own; Test and Save in a bar at the foot, with why Save is off where it
  /// is. Every field and what it does are the form's as before, moved.
  Widget _buildPhoneForm({
    required AppLocalizations l10n,
    required bool isEditing,
    required AsyncValue<List<Identity>> identitiesAsync,
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
    required AsyncValue<List<dynamic>> connectionsAsync,
  }) {
    final moreOpen = _showMore ?? (isEditing && _organiseHasValues);
    return Column(
      children: [
        Expanded(
          child: ListView(
            key: const ValueKey('host-form-phone'),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
            children: [
              // Where a new host is saved (3.4).
              if (!isEditing)
                SaveInField(
                  value: _saveIn,
                  onChanged: (p) => setState(() => _saveIn = p),
                  padding: const EdgeInsets.only(bottom: 16),
                ),
              _buildProtocolField(l10n, phone: true),
              ?_addScreenLine(l10n),
              // Explicit or implicit TLS, for an FTPS host (3.4).
              if (_ftps) _buildFtpsModeField(l10n, phone: true),
              // A remote screen (4.0): the SSH host it is reached through,
              // and what it is on that host.
              if (_screen) ...[
                const SizedBox(height: 18),
                _buildScreenReachFields(l10n, phone: true),
              ],
              const SizedBox(height: 18),
              if (_screenUnix) _buildScreenSocketField(l10n, phone: true) else _buildPhoneAddressPort(l10n),
              // Hidden for protocols that sign in with no key (Telnet, a
              // local shell).
              if (_signsInWithKey) ...[
                const SizedBox(height: 14),
                _buildPhoneSignIn(l10n, identitiesAsync),
              ],
              if (_screen) ...[
                _screenNote(_rdp ? l10n.connectionEditRdpPasswordNote : l10n.connectionEditScreenPasswordNote,
                    key: const ValueKey('host-edit-screen-password-note')),
                _buildScreenMore(l10n, phone: true),
              ] else
                _buildOtherAccounts(l10n, identitiesAsync, phone: true),
              const SizedBox(height: 14),
              _buildPhoneNickname(l10n),
              const SizedBox(height: 18),
              PhoneFoldCard(
                folds: [
                  PhoneFold(
                    key: const ValueKey('host-form-more'),
                    icon: LucideIcons.palette,
                    title: l10n.hostFormMoreOptions,
                    subtitle: l10n.hostFormMoreOptionsSub,
                    open: moreOpen,
                    onToggle: () => setState(() => _showMore = !moreOpen),
                    content: (_) => _buildOrganiseSection(l10n, groupsAsync, phone: true),
                  ),
                  PhoneFold(
                    key: const ValueKey('host-form-advanced'),
                    icon: LucideIcons.slidersHorizontal,
                    title: l10n.hostFormAdvancedOptions,
                    // A host with no terminal has no startup command.
                    subtitle: _filesOnly ? l10n.hostFormAdvancedOptionsFilesSub : l10n.hostFormAdvancedOptionsSub,
                    open: _showAdvanced,
                    onToggle: () => setState(() => _showAdvanced = !_showAdvanced),
                    content: (_) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: _buildAdvancedSections(
                        connectionsAsync: connectionsAsync,
                        snippetsAsync: snippetsAsync,
                        groupsAsync: groupsAsync,
                        identitiesAsync: identitiesAsync,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        _buildPhoneBar(l10n, isEditing),
      ],
    );
  }

  /// A phone's Address, with its Port beside it, each with its name above.
  Widget _buildPhoneAddressPort(AppLocalizations l10n) {
    // As wide as a port of five digits needs at the text size the app is
    // drawn at, and no narrower than the mockup's 90.
    final digits = TextPainter(
      text: TextSpan(text: '65535', style: phoneFormValueStyle(mono: true)),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final portWidth = math.max(90.0, digits.width + 30);
    digits.dispose();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: PhoneFormLabel(l10n.zestHostFieldAddress)),
            const SizedBox(width: 10),
            SizedBox(width: portWidth, child: PhoneFormLabel(l10n.zestHostFieldPort)),
          ],
        ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: PhoneFormBox(child: _buildAddressField(l10n, phone: true))),
            const SizedBox(width: 10),
            SizedBox(width: portWidth, child: PhoneFormBox(child: _buildPortField(l10n, phone: true))),
          ],
        ),
      ],
    );
  }

  /// A phone's "Signs in with": a key or a password, and which one, from the
  /// keys of the space (as the computer's Key field lists them, "name
  /// (user)"). An SSH host and those reached over SSH choose between the two
  /// kinds first, as the Keys page holds them apart; an FTPS host and a
  /// remote screen sign in with a user name and a password a key holds, so
  /// their list is whole. A host with none chosen signs in as Settings'
  /// default user and asks for the password: said under the list.
  Widget _buildPhoneSignIn(AppLocalizations l10n, AsyncValue<List<Identity>> identitiesAsync) {
    return identitiesAsync.when(
      data: (identities) {
        final split = !_ftps && !_screen;
        final chosen = identities.where((i) => i.id == _identityId).firstOrNull;
        final passwords = chosen != null ? isPasswordIdentity(chosen) : _signInWithPassword;
        final listed = split ? [for (final i in identities) if (isPasswordIdentity(i) == passwords) i] : identities;
        return Column(
          key: const ValueKey('host-form-sign-in'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PhoneFormLabel(l10n.hostFormSignsInWith),
            if (split) ...[
              PhoneSegments<bool>(
                choices: [
                  PhoneChoice(false, l10n.hostFormSignInKey,
                      icon: LucideIcons.keyRound, key: const ValueKey('host-form-sign-in-key')),
                  PhoneChoice(true, l10n.hostFormSignInPassword,
                      icon: LucideIcons.lock, key: const ValueKey('host-form-sign-in-password')),
                ],
                selected: passwords,
                onSelected: (p) {
                  // The other kind: what it signed in with is no longer
                  // chosen, as None would be.
                  final other = chosen != null && isPasswordIdentity(chosen) != p;
                  setState(() {
                    _signInWithPassword = p;
                    if (other) _pickDefaultAccount(null);
                  });
                  if (other) _markDirty();
                },
              ),
              const SizedBox(height: 8),
            ],
            ZestSelect<String?>(
              key: const ValueKey('host-form-identity'),
              value: _identityId,
              large: true,
              // Nothing chosen shows what to do; None is offered to take a
              // choice back.
              hint: passwords && split ? l10n.hostFormChoosePassword : l10n.hostFormChooseKey,
              items: [
                if (_identityId != null) ZestSelectItem(null, l10n.none),
                for (final i in listed)
                  // Masked label; the item's value stays the real id.
                  ZestSelectItem(
                    i.id,
                    '${Redactable.keyName(i.label).displayIn(ref)} '
                    '(${Redactable.username(i.username).displayIn(ref)})',
                  ),
              ],
              actions: [
                ZestSelectAction(l10n.connectionCreateNewIdentity, icon: LucideIcons.plusCircle, onPressed: _createIdentity),
              ],
              onChanged: (v) {
                // The one it has, picked again: nothing changed.
                if (v == _identityId) return;
                setState(() => _pickDefaultAccount(v));
                _markDirty();
              },
              frame: (value) => PhoneFormBox(child: value),
            ),
            // None chosen: whom it signs in as, and that the password is
            // asked for (a screen's own note says what its key holds).
            if (_identityId == null && !_screen)
              Padding(
                key: const ValueKey('host-form-sign-in-default'),
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  l10n.hostFormSignsInAsDefault(
                      Redactable.username(ref.watch(defaultUsernameProvider)).displayIn(ref)),
                  style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textMuted),
                ),
              ),
          ],
        );
      },
      loading: () => const LinearProgressIndicator(),
      error: (_, _) => Text(l10n.connectionErrorLoadingIdentities),
    );
  }

  /// A phone's Nickname, said to be optional (the address names a host that
  /// has none).
  Widget _buildPhoneNickname(AppLocalizations l10n) {
    final style = phoneFormValueStyle();
    final decoration = _phoneDecoration(l10n.connectionNicknameHint);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PhoneFormLabel(l10n.zestHostFieldNickname, trailing: l10n.hostFormOptional),
        PhoneFormBox(
          // Editor rule: the nickname is a host label, so it is masked (and
          // read-only behind the reveal gate) while recording mode is on.
          child: RecordingMaskedFormField(
            controller: _labelController,
            mask: (raw) => Redactable.host(raw).display,
            style: style,
            decoration: decoration,
            child: TextFormField(
              key: const ValueKey('host-form-nickname'),
              controller: _labelController,
              style: style,
              decoration: decoration,
              textCapitalization: TextCapitalization.words,
            ),
          ),
        ),
      ],
    );
  }

  /// The bar at the foot of a phone's form: what a test said, why Save is
  /// off where that is not plain (no address; the vault does not let this
  /// account change it), and Test beside Save. Test offers the two tests
  /// by name in a menu (it was a button and an unnamed swap beside it); a
  /// remote screen's runs its one.
  Widget _buildPhoneBar(AppLocalizations l10n, bool isEditing) {
    final canTest = _protocol == ConnectionProtocol.ssh ||
        _protocol == ConnectionProtocol.sftp ||
        _protocol == ConnectionProtocol.mosh ||
        _protocol == ConnectionProtocol.et ||
        _protocol == ConnectionProtocol.serial ||
        _ftps;
    final testing = _isTesting
        ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
        : null;
    final Widget? test = _screen
        ? Tooltip(
            message: l10n.screenTestButton,
            child: OutlinedButton.icon(
              key: const ValueKey('host-edit-screen-test'),
              onPressed: _isTesting || _gatewayHost ? null : _testScreen,
              style: phoneBarButtonStyle(),
              icon: testing ?? const Icon(LucideIcons.activity, size: 18),
              label: Text(_isTesting ? l10n.connectionEditTesting : l10n.hostFormTest),
            ),
          )
        : !canTest
            ? null
            : MenuAnchor(
                alignmentOffset: const Offset(0, 6),
                menuChildren: [
                  MenuItemButton(
                    key: const ValueKey('host-form-test-reachability'),
                    style: MenuItemButton.styleFrom(minimumSize: const Size(0, kPhoneFormBoxHeight)),
                    leadingIcon: const Icon(LucideIcons.radio, size: 18),
                    onPressed: () => _testReachability(_baseTestConfig()),
                    child: Text(l10n.zestHostTestReachability),
                  ),
                  MenuItemButton(
                    key: const ValueKey('host-form-test-full'),
                    style: MenuItemButton.styleFrom(minimumSize: const Size(0, kPhoneFormBoxHeight)),
                    leadingIcon: const Icon(LucideIcons.lock, size: 18),
                    onPressed: () => _testFullAuth(_baseTestConfig()),
                    child: Text(l10n.zestHostTestFull),
                  ),
                ],
                builder: (context, menu, _) => OutlinedButton.icon(
                  key: const ValueKey('host-form-test'),
                  onPressed: _isTesting ? null : () => menu.isOpen ? menu.close() : menu.open(),
                  style: phoneBarButtonStyle(),
                  icon: testing ?? const Icon(LucideIcons.activity, size: 18),
                  label: Text(_isTesting ? l10n.connectionEditTesting : l10n.hostFormTest),
                ),
              );
    final saveLabel = isEditing ? l10n.connectionSaveChanges : l10n.connectionSaveConnection;
    // What each needs with its words: beside one another where the row holds
    // both (while a test runs Test says Testing...).
    final testWidth = test == null
        ? 0.0
        : math.max(PhoneFormBar.buttonWidth(context, l10n.hostFormTest),
            PhoneFormBar.buttonWidth(context, l10n.connectionEditTesting));
    final saveWidth = PhoneFormBar.buttonWidth(context, saveLabel);
    // Said while the address is typed: the bar is drawn again as it changes.
    return ListenableBuilder(
      listenable: _hostController,
      builder: (context, _) {
        final missing = _addressMissing;
        final reason = !_maySave
            ? l10n.orchardWriteNotAllowed
            : missing
                ? l10n.hostFormAddAddressToSave
                : null;
        return PhoneFormBar(
          notice: _testResult == null
              ? null
              : HostTestResultBanner(result: _testResult!, onClose: () => setState(() => _testResult = null)),
          reason: reason,
          test: test,
          testWidth: testWidth,
          saveWidth: saveWidth,
          save: FilledButton.icon(
            key: const ValueKey('host-form-save'),
            onPressed: (_isLoading || !_dirty || !_maySave || missing) ? null : _save,
            style: phoneBarButtonStyle(primary: true),
            icon: _isLoading
                ? const SizedBox(width: 16, height: 16, child: ButtonSpinner())
                : const Icon(LucideIcons.check, size: 18),
            label: Text(saveLabel),
          ),
        );
      },
    );
  }

  /// Two-column form layout for desktop / wide screens.
  Widget _buildTwoColumnForm({
    required AppLocalizations l10n,
    required AsyncValue<List<Identity>> identitiesAsync,
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
    required AsyncValue<List<dynamic>> connectionsAsync,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Left column: Connection (incl. identity) ──
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildBasicFields(l10n, identitiesAsync),
                  ],
                ),
              ),
            ),
            // ── Right column: Organise ──
            // (Terminal Theme lives in the advanced section below - it was
            // duplicated here, showing two identical dropdowns when advanced
            // was expanded.)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildOrganiseSection(l10n, groupsAsync),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        _buildAdvancedToggle(
          connectionsAsync: connectionsAsync,
          snippetsAsync: snippetsAsync,
          groupsAsync: groupsAsync,
          identitiesAsync: identitiesAsync,
        ),
      ],
    );
  }

  /// Advanced options section - collapsed by default, contains Network,
  /// Automation, Wake-on-LAN, Port Forwards, Environment Variables, and
  /// Terminal Theme settings.
  Widget _buildAdvancedToggle({
    required AsyncValue<List<dynamic>> connectionsAsync,
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
    required AsyncValue<List<Identity>> identitiesAsync,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // A button in the accent's text colour (the fill's orange on white
        // did not read), its chevron turning as the options open.
        TextButton(
          key: const ValueKey('host-form-advanced'),
          onPressed: () => setState(() => _showAdvanced = !_showAdvanced),
          style: TextButton.styleFrom(
            foregroundColor: ZestTokens.brandInk,
            minimumSize: const Size(0, 44),
            // Its chevron on the page's edge, as the fields are.
            padding: const EdgeInsetsDirectional.only(end: 8),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedRotation(
                turns: _showAdvanced ? 0.5 : 0,
                duration: const Duration(milliseconds: 160),
                child: Icon(LucideIcons.chevronDown, size: 18, color: ZestTokens.brandInk),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  _showAdvanced
                      ? l10n.connectionEditHideAdvanced
                      : l10n.connectionEditShowAdvanced,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ZestTokens.brandInk,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_showAdvanced) ...[
          const SizedBox(height: 16),
          ..._buildAdvancedSections(
            connectionsAsync: connectionsAsync,
            snippetsAsync: snippetsAsync,
            groupsAsync: groupsAsync,
            identitiesAsync: identitiesAsync,
          ),
        ],
      ],
    );
  }

  /// What the advanced options hold, under their button (a tablet's form) or
  /// their row (a phone's).
  List<Widget> _buildAdvancedSections({
    required AsyncValue<List<dynamic>> connectionsAsync,
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
    required AsyncValue<List<Identity>> identitiesAsync,
  }) {
    return [
      // Auth (agent forwarding + compatibility mode). On desktop these
      // live in the rail's Auth tab; the mobile form has no rail, so
      // surface them here or they'd be unreachable.
      _buildAuthSection(),
      const SizedBox(height: 24),
      // A host that is SFTP only: what a terminal has (its theme, what
      // runs as it starts, forwards, variables) is not shown, and one
      // line says why.
      _buildTerminalThemeDropdown(),
      const SizedBox(height: 24),
      if (_screen) _screenNetworkNote() else _buildNetworkSection(connectionsAsync: connectionsAsync),
      // (No rules per network for an FTPS host or a remote screen: they
      // read none of them.)
      if (!_ftps && !_screen) ...[
        const SizedBox(height: 24),
        _buildHostNetworkOverridesSection(identitiesAsync: identitiesAsync),
      ],
      if (!_filesOnly) ...[
        const SizedBox(height: 24),
        _buildAutomationSection(
          snippetsAsync: snippetsAsync,
          groupsAsync: groupsAsync,
        ),
      ],
      const SizedBox(height: 24),
      _buildWakeOnLanSection(),
      if (widget.connectionId != null && !_filesOnly) ...[
        const SizedBox(height: 24),
        _buildPortForwardsSection(),
      ],
      if (!_filesOnly) ...[
        const SizedBox(height: 24),
        _buildEnvVarsSection(),
      ],
      if (widget.connectionId != null && _lastRemotePath != null) ...[
        const SizedBox(height: 24),
        _buildLastFolderSection(),
      ],
    ];
  }

  // ── SFTP: remembered folder (remember-last-folder spec, section 4) ──

  Widget _buildLastFolderSection() {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.connectionSftpSectionTitle),
        const SizedBox(height: 8),
        RedactedText(
          Redactable.freeText(_lastRemotePath!),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 12.5,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () async {
            await forgetLastFolder(ref, widget.connectionId!);
            if (!mounted) return;
            setState(() => _lastRemotePath = null);
            showTopSnackBar(context, l10n.sftpForgetLastFolderDone);
          },
          icon: const Icon(LucideIcons.folderX, size: 18),
          label: Text(l10n.sftpForgetLastFolder),
        ),
      ],
    );
  }

  // ── Port Forwards Section ──────────────────────────────────────

  Widget _buildPortForwardsSection() {
    final rulesAsync =
        ref.watch(portForwardRulesForConnectionProvider(widget.connectionId!));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(
            label: AppLocalizations.of(context)!.connectionPortForwarding),
        rulesAsync.when(
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
          data: (rules) {
            if (rules.isEmpty) {
              return Column(
                children: [
                  Text(
                    AppLocalizations.of(context)!.connectionPortForwardingDesc,
                    style: TextStyle(
                        color: AppColors.textSecondary, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _addPortForwardRule,
                    icon: const Icon(LucideIcons.plus, size: 18),
                    label: Text(AppLocalizations.of(context)!.connectionAddPortForward),
                  ),
                ],
              );
            }
            return Column(
              children: [
                for (final rule in rules)
                  Card(
                    margin: const EdgeInsets.only(bottom: 4),
                    child: ListTile(
                      dense: true,
                      leading: Icon(
                        rule.type == 'remote'
                            ? LucideIcons.arrowLeft
                            : rule.type == 'dynamic'
                                ? LucideIcons.globe
                                : LucideIcons.arrowRight,
                        size: 20,
                        color: rule.autoStart
                            ? AppColors.success
                            : AppColors.textSecondary,
                      ),
                      title: Text(
                        rule.label ?? _ruleDescription(rule),
                        style: const TextStyle(fontSize: 14),
                      ),
                      subtitle: rule.label != null
                          ? Text(
                              _ruleDescription(rule),
                              style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'JetBrainsMono'),
                            )
                          : null,
                      trailing: IconButton(
                        tooltip: AppLocalizations.of(context)!.delete,
                        icon: const Icon(LucideIcons.trash2, size: 20),
                        onPressed: () async {
                          // Confirm before deleting - a port-forward rule is
                          // not trivially recreated and there's no undo.
                          final l10n = AppLocalizations.of(context)!;
                          final confirmed = await ZestConfirmDialog.show(
                            context,
                            tone: ZestDialogTone.destructive,
                            title: l10n.connectionEditDeletePortForward,
                            body: _ruleDescription(rule),
                            confirmLabel: l10n.delete,
                          );
                          if (confirmed != true) return;
                          final dao = ref.read(portForwardRulesDaoProvider);
                          await dao.deleteRule(rule.id);
                        },
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: _addPortForwardRule,
                  icon: const Icon(LucideIcons.plus, size: 18),
                  label: Text(AppLocalizations.of(context)!.connectionAddPortForward),
                ),
              ],
            );
          },
        ),
      ],
    );
  }

  /// The painted `bind → remote` line; its addresses go through the
  /// free-text rule in recording mode (ports stay readable).
  String _ruleDescription(PortForwardRule rule) {
    final l10n = AppLocalizations.of(context)!;
    final String raw;
    if (rule.type == 'dynamic') {
      raw = l10n.connectionEditSocks5On('${rule.bindAddress}:${rule.bindPort}');
    } else if (rule.type == 'remote') {
      raw = '${rule.remoteHost}:${rule.remotePort} → ${rule.bindAddress}:${rule.bindPort}';
    } else {
      raw = '${rule.bindAddress}:${rule.bindPort} → ${rule.remoteHost}:${rule.remotePort}';
    }
    return Redactable.freeText(raw).display;
  }

  Future<void> _addPortForwardRule() async {
    final form = GlobalKey<_PortForwardFormDialogState>();
    final result = await showZestModal<_PortForwardFormResult>(
      context: context,
      size: ZestModalSize.standard,
      onSubmit: () => form.currentState?._submit(),
      child: _PortForwardFormDialog(key: form),
    );
    if (result == null || widget.connectionId == null) return;

    final dao = ref.read(portForwardRulesDaoProvider);
    await dao.insertRule(PortForwardRulesCompanion.insert(
      id: result.id,
      connectionId: widget.connectionId!,
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

  // ── A remote screen (4.0, VNC) ─────────────────────────────────

  /// What a screen's options column is saved as: null for any other host.
  String? _screenOptionsToSave() {
    if (!_screen) return null;
    final socket = _socketController.text.trim();
    // An RDP host: an address and a port, whichever way it is reached; and
    // its RD Gateway where it goes through one (one set here replaces any).
    final had = _screenOptions.gateway;
    if (_rdp) {
      final rdp = _screenOptions.copyWith(target: ScreenTargetKind.tcp, clearSocket: true);
      if (_throughGateway) {
        return rdp
            .copyWith(
                gateway: ScreenGateway(
                    host: _gatewayHostController.text.trim(),
                    port: int.tryParse(_gatewayPortController.text.trim()) ?? 443,
                    keyId: _gatewayKeyId))
            .encode();
      }
      return (had != null && had.readable ? rdp.copyWith(clearGateway: true) : rdp).encode();
    }
    final o = (_connectViaId == null
            // Reached directly: an address and a port, never a socket.
            ? _screenOptions.copyWith(target: ScreenTargetKind.tcp)
            : _screenOptions)
        // RDP's options are no VNC host's.
        .copyWith(nla: true, graphics: ScreenGraphics.auto, displays: 1, relativeMouse: false, textScale: 0,
            clearGateway: had != null && had.readable);
    return (socket.isEmpty ? o.copyWith(clearSocket: true) : o.copyWith(socket: socket)).encode();
  }

  /// Under Protocol, while a saved SSH host (or one reached over SSH) is
  /// edited: "Remote screen for this host? Add a screen", which adds a screen
  /// host reached through it ([addScreenForHost]) once this editor has closed
  /// (its unsaved changes asked about first). Only where a host may be added
  /// in the space on screen; null otherwise.
  Widget? _addScreenLine(AppLocalizations l10n) {
    final saved = _loadedRow;
    if (saved == null ||
        !_carrierKinds.contains(saved.protocol) ||
        !_carrierKinds.contains(_protocol.name) ||
        !mayAddScreenSpace(ref)) {
      return null;
    }
    return Padding(
      key: const ValueKey('host-edit-add-screen-line'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Flexible(
            child: Text(
              l10n.hostEditScreenLine,
              style: TextStyle(fontSize: 11.5, height: 1.4, color: ZestTokens.textMuted),
            ),
          ),
          const SizedBox(width: 8),
          SectionLink(
            key: const ValueKey('host-edit-add-screen'),
            label: l10n.hostScreenAdd,
            onTap: () {
              final opener = Navigator.of(context, rootNavigator: true).context;
              addScreenForHost(opener, ref, saved, beforeOpen: _askToClose);
            },
          ),
        ],
      ),
    );
  }

  /// The SSH host last connected to in this space: where a new screen is
  /// reached through, until another is picked. Null where there is none.
  String? _lastUsedCarrierId() {
    final all = ref.read(filteredConnectionsProvider).valueOrNull ?? const [];
    Connection? best;
    for (final c in all) {
      if (c.id == widget.connectionId || !_carrierKinds.contains(c.protocol)) continue;
      final at = c.lastConnected;
      final bestAt = best?.lastConnected;
      if (best == null || (at != null && (bestAt == null || at.isAfter(bestAt)))) best = c;
    }
    return best?.id;
  }

  /// The name of the host this screen is reached through; null for a screen
  /// reached directly, or one whose host is not in this space.
  String? _carrierName() {
    final id = _connectViaId;
    if (id == null) return null;
    for (final c in ref.read(filteredConnectionsProvider).valueOrNull ?? const <Connection>[]) {
      if (c.id == id) return c.label.isNotEmpty ? c.label : c.host;
    }
    return null;
  }

  /// The hosts a remote screen can be reached through: SSH hosts and those
  /// reached over SSH (Mosh, Eternal Terminal).
  static final _carrierKinds = {
    ConnectionProtocol.ssh.name,
    ConnectionProtocol.mosh.name,
    ConnectionProtocol.et.name,
  };

  Widget _screenNote(String text, {Key? key, bool warn = false}) => Padding(
        key: key,
        padding: const EdgeInsets.only(top: 6),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            height: 1.45,
            color: warn ? AppColors.warning : ZestTokens.textMuted,
          ),
        ),
      );

  /// A screen's Network tab: what it goes through is its carrier's.
  Widget _screenNetworkNote() => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ZestSectionHeader(label: AppLocalizations.of(context)!.connectionNetwork),
          _screenNote(AppLocalizations.of(context)!.connectionEditScreenNetworkNote,
              key: const ValueKey('host-edit-screen-network')),
        ],
      );

  /// "Reach through": an SSH host of this space (never locked behind
  /// Squeezed: remote screens are free, and so is the hop), or directly over
  /// TLS; and, through a host, an address and port on it or a Unix socket.
  Widget _buildScreenReachFields(AppLocalizations l10n, {bool phone = false}) {
    final all = ref.watch(filteredConnectionsProvider).valueOrNull ?? const [];
    final carriers = [
      for (final c in all)
        if (c.id != widget.connectionId && _carrierKinds.contains(c.protocol)) c,
    ];
    // A carrier that is not in the list (gone, or not an SSH host) is shown
    // as none, and saved as the person picks.
    final via = carriers.any((c) => c.id == _connectViaId) ? _connectViaId : null;
    final carrier = via == null ? null : carriers.firstWhere((c) => c.id == via);
    // The team's rule "remote screens through an SSH host only": no direct
    // connection is offered, and a screen with none is told why it will not
    // open (it is refused at connect, ZS-1821).
    final sshOnly = ref.watch(screenTeamRulesProvider).sshOnly;
    // An RD Gateway (4.0): for an RDP host, where this build offers
    // it, and never under the team's rule (a gateway is no SSH host). One a
    // host already has stays shown while the rule is off.
    final gatewayOffered = _rdp && !sshOnly && (ref.watch(rdpGatewayOfferedProvider) || _throughGateway);
    final throughGateway = _rdp && _throughGateway;
    return Column(
      key: const ValueKey('host-edit-screen-reach'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSelect<String?>(
          value: throughGateway ? _gatewayChoice : via,
          hint: l10n.connectionEditScreenVia,
          // Directly and an RD Gateway first, each with what it is, then the
          // SSH hosts under their heading, each with its own icon and address,
          // searched where there are many.
          items: [
            if (!sshOnly)
              ZestSelectItem(null, l10n.connectionEditScreenDirect,
                  icon: LucideIcons.globe, note: l10n.connectionEditReachDirectNote),
            if (gatewayOffered)
              ZestSelectItem(_gatewayChoice, l10n.connectionEditRdpGateway,
                  icon: LucideIcons.shieldCheck, note: l10n.connectionEditReachGatewayNote),
            for (final c in carriers)
              ZestSelectItem(
                c.id,
                c.label.isNotEmpty ? Redactable.host(c.label).displayIn(ref) : Redactable.address(c.host).displayIn(ref),
                leading: HostGlyph(host: c, size: 16),
                note: c.label.isNotEmpty ? Redactable.address(c.host).displayIn(ref) : null,
                section: l10n.connectionEditReachSshSection,
                searchable: true,
              ),
          ],
          searchHint: l10n.connectionEditReachSearch,
          noMatches: l10n.connectionEditReachNoMatches,
          onChanged: (v) {
            if (v == _gatewayChoice) {
              if (_throughGateway) return;
              setState(() {
                _throughGateway = true;
                _connectViaId = null;
                if (_hostController.text.trim() == 'localhost') _hostController.clear();
              });
              _markDirty();
              return;
            }
            if (v == _connectViaId && !_throughGateway) return;
            setState(() {
              _throughGateway = false;
              _connectViaId = v;
              if (v == null && _hostController.text.trim() == 'localhost') _hostController.clear();
            });
            _markDirty();
          },
          large: phone,
          frame: (value) => _organiseField(l10n.connectionEditScreenVia, value, phone: phone),
        ),
        if (throughGateway)
          _buildGatewayFields(l10n, phone: phone)
        // Its carrier is gone (deleted, moved away): it is refused at
        // connect (ZS-1808), never dialled directly, until one is picked.
        else if (via == null && _connectViaId != null)
          _screenNote(l10n.screenCarrierGone, key: const ValueKey('host-edit-screen-carrier-gone'), warn: true)
        else if (via == null && sshOnly)
          _screenNote(l10n.connectionEditScreenTeamSshOnly,
              key: const ValueKey('host-edit-screen-team-ssh-only'), warn: true)
        else if (via == null && _rdp)
          // RDP is always inside TLS with its certificate asked about, so
          // reaching it directly is a choice, not a warning.
          _screenNote(l10n.connectionEditRdpDirectNote, key: const ValueKey('host-edit-rdp-direct-note'))
        else if (via == null)
          _screenNote(carriers.isEmpty ? l10n.connectionEditScreenNoCarriers : l10n.connectionEditScreenDirectWarning,
              key: const ValueKey('host-edit-screen-direct-warning'), warn: true)
        else ...[
          // An SSH host with no key signs in as Settings' default user and
          // asks for its password: said here, never found out at connect.
          if (carrier!.identityId == null)
            _screenNote(
              l10n.connectionEditScreenCarrierNoKey(
                carrier.label.isNotEmpty
                    ? Redactable.host(carrier.label).displayIn(ref)
                    : Redactable.address(carrier.host).displayIn(ref),
                Redactable.username(ref.watch(defaultUsernameProvider)).displayIn(ref),
              ),
              key: const ValueKey('host-edit-screen-carrier-no-key'),
              warn: true,
            ),
          // An address and port, or a Unix socket: VNC's choice alone.
          if (!_rdp) const SizedBox(height: 11),
          if (_rdp)
            const SizedBox.shrink()
          else if (phone)
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                PhoneFormLabel(l10n.connectionEditScreenTarget),
                PhoneSegments<ScreenTargetKind>(
                  choices: [
                    for (final kind in ScreenTargetKind.values)
                      PhoneChoice(
                        kind,
                        kind == ScreenTargetKind.tcp
                            ? l10n.connectionEditScreenTargetTcp
                            : l10n.connectionEditScreenTargetUnix,
                        key: ValueKey('host-edit-screen-target-${kind.name}'),
                      ),
                  ],
                  selected: _screenOptions.target,
                  onSelected: (kind) {
                    if (_screenOptions.target == kind) return;
                    setState(() => _screenOptions = _screenOptions.copyWith(target: kind));
                    _markDirty();
                  },
                ),
              ],
            )
          else
          _labeledField(
            l10n.connectionEditScreenTarget,
            Row(
              children: [
                for (final (i, kind) in ScreenTargetKind.values.indexed) ...[
                  if (i > 0) const SizedBox(width: 5),
                  Expanded(
                    child: _MChoicePill(
                      key: ValueKey('host-edit-screen-target-${kind.name}'),
                      label: kind == ScreenTargetKind.tcp
                          ? l10n.connectionEditScreenTargetTcp
                          : l10n.connectionEditScreenTargetUnix,
                      selected: _screenOptions.target == kind,
                      onTap: () {
                        if (_screenOptions.target == kind) return;
                        setState(() => _screenOptions = _screenOptions.copyWith(target: kind));
                        _markDirty();
                      },
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }

  /// The socket's path on the carrier (a path under ~/ is in the home
  /// folder of the account the carrier signs in as).
  Widget _buildScreenSocketField(AppLocalizations l10n, {bool phone = false}) => _organiseField(
        l10n.connectionEditScreenSocket,
        phone: phone,
        TextFormField(
          key: const ValueKey('host-edit-screen-socket'),
          controller: _socketController,
          style: phone ? phoneFormValueStyle(mono: true) : _kValMonoStyle,
          decoration: phone ? _phoneDecoration('~/.vnc/zest.sock') : _fieldDecoration(hintText: '~/.vnc/zest.sock'),
          autocorrect: false,
          onChanged: (_) => _markDirty(),
          validator: (v) => ScreenOptions.socketOk(v) ? null : l10n.connectionEditScreenSocketInvalid,
        ),
      );

  /// An RDP host's RD Gateway (4.0): its address and port, its
  /// sign-in (the PC's own, or a key of its own), and what it learns.
  Widget _buildGatewayFields(AppLocalizations l10n, {bool phone = false}) {
    Widget field(String label, Widget child) => phone
        ? Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [PhoneFormLabel(label), child])
        : _labeledField(label, child);
    final identities = ref.watch(identitiesProvider).valueOrNull ?? const [];
    // A key that is not in the list (gone) shows as the PC's own sign-in and
    // is saved as the person picks.
    final key = identities.any((i) => i.id == _gatewayKeyId) ? _gatewayKeyId : null;
    return Column(
      key: const ValueKey('host-edit-rdp-gateway'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 11),
        field(
          l10n.connectionEditRdpGatewayHost,
          TextFormField(
            key: const ValueKey('host-edit-rdp-gateway-host'),
            controller: _gatewayHostController,
            style: phone ? phoneFormValueStyle(mono: true) : _kValMonoStyle,
            decoration: phone ? _phoneDecoration('rdg.example.com') : _fieldDecoration(hintText: 'rdg.example.com'),
            autocorrect: false,
            onChanged: (_) => _markDirty(),
            validator: (v) => ScreenGateway.hostOk((v ?? '').trim()) ? null : l10n.connectionEditRdpGatewayHostInvalid,
          ),
        ),
        const SizedBox(height: 11),
        field(
          l10n.connectionPort,
          TextFormField(
            key: const ValueKey('host-edit-rdp-gateway-port'),
            controller: _gatewayPortController,
            style: phone ? phoneFormValueStyle(mono: true) : _kValMonoStyle,
            decoration: phone ? _phoneDecoration('443') : _fieldDecoration(hintText: '443'),
            keyboardType: TextInputType.number,
            onChanged: (_) => _markDirty(),
            validator: (v) {
              final n = int.tryParse((v ?? '').trim());
              return n != null && n >= 1 && n <= 65535 ? null : l10n.connectionEditPortRange1To65535;
            },
          ),
        ),
        const SizedBox(height: 11),
        ZestSelect<String?>(
          key: const ValueKey('host-edit-rdp-gateway-key'),
          value: key,
          hint: l10n.connectionEditRdpGatewaySignIn,
          items: [
            ZestSelectItem(null, l10n.connectionEditRdpGatewaySameSignIn),
            for (final i in identities)
              // Masked label; the item's value stays the real id.
              ZestSelectItem(
                i.id,
                '${Redactable.keyName(i.label).displayIn(ref)} (${Redactable.username(i.username).displayIn(ref)})',
              ),
          ],
          onChanged: (v) {
            if (v == _gatewayKeyId) return;
            setState(() => _gatewayKeyId = v);
            _markDirty();
          },
          large: phone,
          frame: (value) => _organiseField(l10n.connectionEditRdpGatewaySignIn, value, phone: phone),
        ),
        _screenNote(l10n.connectionEditRdpGatewayNote, key: const ValueKey('host-edit-rdp-gateway-note')),
      ],
    );
  }

  /// Clipboard, scaling, picture quality and view only. In a team, an
  /// editor also says whether members may turn the clipboard on.
  /// Whether a remote screen's More options are open: null until its person
  /// opens or closes them, which is closed, or open for a host that signs in
  /// without NLA (its warning stays in sight while that is on).
  bool? _screenMoreOpen;

  /// Under what a remote screen needs to connect (its address, how it is
  /// reached, its sign-in): one line on what to turn on on the remote, and
  /// everything else a session starts with behind More options, closed.
  /// Those options are what a new session starts with; each can be changed
  /// in the session's own panel while it is open.
  Widget _buildScreenMore(AppLocalizations l10n, {bool phone = false}) {
    final open = _screenMoreOpen ?? (debugScreenMoreOpen ?? (_rdp && !_screenOptions.nla));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _screenNote(_rdp ? l10n.connectionEditRdpTurnOnNote : l10n.connectionEditVncTurnOnNote,
            key: const ValueKey('host-edit-screen-turn-on-note')),
        const SizedBox(height: 8),
        Semantics(
          button: true,
          expanded: open,
          child: InkWell(
            key: const ValueKey('host-edit-screen-more'),
            borderRadius: BorderRadius.circular(6),
            onTap: () => setState(() => _screenMoreOpen = !open),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: phone ? 48 : 32),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(open ? LucideIcons.chevronDown : LucideIcons.chevronRight, size: 16, color: ZestTokens.textSecondary),
                  const SizedBox(width: 6),
                  Text(
                    // (A phone's form ends with a group named More options: this one names the screen.)
                    phone ? l10n.connectionEditScreenOptionsPhone : l10n.connectionEditScreenMoreOptions,
                    style: TextStyle(fontSize: phone ? 14 : 12.5, fontWeight: FontWeight.w600, color: ZestTokens.textSecondary),
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
        ),
        if (open) ...[
          const SizedBox(height: 8),
          _buildScreenOptionsFields(l10n, phone: phone),
        ],
      ],
    );
  }

  Widget _buildScreenOptionsFields(AppLocalizations l10n, {bool phone = false}) {
    final inTeam = ref.read(databaseProvider).isOrchard;
    final o = _screenOptions;
    // The team's rule "nothing shared with remote screens": the clipboard's
    // switch is off and stays off, with why; the host's own setting is kept
    // as it was for the day the rule is turned off.
    final noSharing = ref.watch(screenTeamRulesProvider).lockRedirections;
    // Each change made to the options as they are when it is made (two taps
    // before the form is drawn again both count).
    void set(ScreenOptions Function(ScreenOptions now) change) {
      setState(() => _screenOptions = change(_screenOptions));
      _markDirty();
    }

    // A phone's as its segments, 48 high.
    Widget pills<T>(String label, List<T> values, T selected, String Function(T) name, void Function(T) pick,
            String keyPrefix) =>
        phone
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  PhoneFormLabel(label),
                  PhoneSegments<T>(
                    choices: [for (final v in values) PhoneChoice(v, name(v), key: ValueKey('$keyPrefix-$v'))],
                    selected: selected,
                    onSelected: pick,
                  ),
                ],
              )
            : _labeledField(
          label,
          Row(
            children: [
              for (final (i, v) in values.indexed) ...[
                if (i > 0) const SizedBox(width: 5),
                Expanded(
                  child: _MChoicePill(
                    key: ValueKey('$keyPrefix-$v'),
                    label: name(v),
                    selected: selected == v,
                    onTap: () => pick(v),
                  ),
                ),
              ],
            ],
          ),
        );

    return Column(
      key: const ValueKey('host-edit-screen-options'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // RDP's own two (4.0): signing in without NLA, a switch that
        // is off unless a person turns it on for a server that has none, its
        // warning in sight while it is on; and what the server draws with.
        if (_rdp) ...[
          KeyedSubtree(
            key: const ValueKey('host-edit-rdp-without-nla'),
            child: _MToggleRow(
              label: l10n.connectionEditRdpWithoutNla,
              note: l10n.connectionEditRdpWithoutNlaNote,
              value: !o.nla,
              warnWhenOn: true,
              onChanged: (v) => set((o) => o.copyWith(nla: !v)),
            ),
          ),
          const SizedBox(height: 11),
          pills<ScreenGraphics>(
            l10n.connectionEditRdpGraphics,
            ScreenGraphics.values,
            o.graphics,
            (v) => switch (v) {
              ScreenGraphics.auto => l10n.connectionEditRdpGraphicsAuto,
              ScreenGraphics.modern => l10n.connectionEditRdpGraphicsModern,
              ScreenGraphics.remotefx => l10n.connectionEditRdpGraphicsRemoteFx,
              ScreenGraphics.basic => l10n.connectionEditRdpGraphicsBasic,
            },
            (v) => set((o) => o.copyWith(graphics: v)),
            'host-edit-rdp-graphics',
          ),
          const SizedBox(height: 6),
          _screenNote(l10n.connectionEditRdpGraphicsNote, key: const ValueKey('host-edit-rdp-graphics-note')),
          const SizedBox(height: 11),
          // How many displays the remote is asked for (4.0): one
          // unless its person picks more.
          pills<int>(
            l10n.connectionEditRdpDisplays,
            const [1, 2, 3, 4],
            o.displays,
            (v) => '$v',
            (v) => set((o) => o.copyWith(displays: v)),
            'host-edit-rdp-displays',
          ),
          const SizedBox(height: 6),
          _screenNote(l10n.connectionEditRdpDisplaysNote, key: const ValueKey('host-edit-rdp-displays-note')),
          const SizedBox(height: 11),
          // Relative mouse (4.0): asked of the server only where on.
          KeyedSubtree(
            key: const ValueKey('host-edit-rdp-relative-mouse'),
            child: _MToggleRow(
              label: l10n.connectionEditRdpRelativeMouse,
              note: l10n.connectionEditRdpRelativeMouseNote,
              value: o.relativeMouse,
              onChanged: (v) => set((o) => o.copyWith(relativeMouse: v)),
            ),
          ),
          const SizedBox(height: 11),
          // The remote's sound (4.0): shown as this device would
          // play it; a change is kept for every device.
          KeyedSubtree(
            key: const ValueKey('host-edit-rdp-sound'),
            child: _MToggleRow(
              label: l10n.connectionEditRdpSound,
              note: l10n.connectionEditRdpSoundNote,
              value: o.soundOn(phone: !(debugHostFormOnComputer ?? isDesktopPlatform)),
              onChanged: (v) => set((o) => o.copyWith(sound: v)),
            ),
          ),
          const SizedBox(height: 11),
          // How large the remote draws its text and windows (4.0):
          // nothing said unless its person picks a size.
          pills<int>(
            l10n.connectionEditRdpTextSize,
            ScreenOptions.textScales,
            o.textScale,
            (v) => v == 0 ? l10n.connectionEditRdpTextSizeOwn : l10n.connectionEditRdpTextSizePercent(v),
            (v) => set((o) => o.copyWith(textScale: v)),
            'host-edit-rdp-text-size',
          ),
          const SizedBox(height: 6),
          _screenNote(l10n.connectionEditRdpTextSizeNote, key: const ValueKey('host-edit-rdp-text-size-note')),
          const SizedBox(height: 11),
        ],
        // How many pictures a second are drawn at most (4.0), VNC and
        // RDP: no limit unless its person picks one.
        pills<int>(
          l10n.connectionEditScreenFrameLimit,
          ScreenOptions.frameLimits,
          o.frameLimit,
          (v) => v == 0 ? l10n.connectionEditScreenFrameLimitOff : l10n.connectionEditScreenFrameLimitFps(v),
          (v) => set((o) => o.copyWith(frameLimit: v)),
          'host-edit-screen-frame-limit',
        ),
        const SizedBox(height: 6),
        _screenNote(l10n.connectionEditScreenFrameLimitNote, key: const ValueKey('host-edit-screen-frame-limit-note')),
        const SizedBox(height: 11),
        KeyedSubtree(
          key: const ValueKey('host-edit-screen-clipboard'),
          child: _MToggleRow(
            label: l10n.connectionEditScreenClipboard,
            value: !noSharing &&
                o.clipboardOnByDefault(inTeam: inTeam, ownDefault: ref.watch(screenClipboardDefaultProvider)),
            onChanged: noSharing ? null : (v) => set((o) => o.copyWith(clipboard: v)),
            note: noSharing ? l10n.connectionEditScreenTeamNoSharing : null,
          ),
        ),
        if (!noSharing)
          KeyedSubtree(
            key: const ValueKey('host-edit-screen-clipboard-on-paste'),
            child: _MToggleRow(
              label: l10n.connectionEditScreenClipboardOnPaste,
              value: o.clipboardOnPaste,
              onChanged: (v) => set((o) => o.copyWith(clipboardOnPaste: v)),
              note: l10n.connectionEditScreenClipboardOnPasteNote,
            ),
          ),
        if (inTeam && !noSharing)
          KeyedSubtree(
            key: const ValueKey('host-edit-screen-clipboard-members'),
            child: _MToggleRow(
              label: l10n.connectionEditScreenClipboardMembers,
              value: !o.clipboardLocked,
              onChanged: (v) => set((o) => o.copyWith(clipboardLocked: !v)),
            ),
          ),
        const SizedBox(height: 11),
        pills<ScreenScaling>(
          l10n.connectionEditScreenScaling,
          ScreenScaling.values,
          o.scaling,
          (v) => switch (v) {
            ScreenScaling.fit => l10n.connectionEditScreenScalingFit,
            ScreenScaling.oneToOne => l10n.connectionEditScreenScalingOneToOne,
            ScreenScaling.remoteResize => l10n.connectionEditScreenScalingRemote,
          },
          (v) => set((o) => o.copyWith(scaling: v)),
          'host-edit-screen-scaling',
        ),
        const SizedBox(height: 11),
        // Picture quality is VNC's (its encodings); RDP has Graphics above.
        if (!_rdp) ...[
          pills<ScreenQuality>(
            l10n.connectionEditScreenQuality,
            ScreenQuality.values,
            o.quality,
            (v) => switch (v) {
              ScreenQuality.auto => l10n.connectionEditScreenQualityAuto,
              ScreenQuality.high => l10n.connectionEditScreenQualityHigh,
              ScreenQuality.low => l10n.connectionEditScreenQualityLow,
            },
            (v) => set((o) => o.copyWith(quality: v)),
            'host-edit-screen-quality',
          ),
          const SizedBox(height: 11),
        ],
        KeyedSubtree(
          key: const ValueKey('host-edit-screen-view-only'),
          child: _MToggleRow(
            label: l10n.connectionEditScreenViewOnly,
            note: l10n.connectionEditScreenViewOnlyNote,
            value: o.viewOnly,
            onChanged: (v) => set((o) => o.copyWith(viewOnly: v)),
          ),
        ),
      ],
    );
  }

  // ── Bottom action buttons ──────────────────────────────────────

  Widget _buildBottomButtons(AppLocalizations l10n, bool isEditing) {
    final canTest = _protocol == ConnectionProtocol.ssh ||
        _protocol == ConnectionProtocol.sftp ||
        _protocol == ConnectionProtocol.mosh ||
        _protocol == ConnectionProtocol.et ||
        _protocol == ConnectionProtocol.serial ||
        _ftps;
    final saveLabel = isEditing ? l10n.connectionSaveChanges : l10n.connectionSaveConnection;
    // Save: the form's one, the theme's primary button (44 high on a phone,
    // its label dark on the accent). Off where nothing changed, and where
    // the host's Crate keeps this account from changing it (it was on there,
    // and did nothing).
    final save = FilledButton.icon(
      key: const ValueKey('host-form-save'),
      onPressed: (_isLoading || !_dirty || !_maySave) ? null : _save,
      icon: _isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: ButtonSpinner(),
            )
          : const Icon(LucideIcons.check, size: 18),
      label: Text(saveLabel),
    );
    if (_screen) {
      final test = OutlinedButton.icon(
        key: const ValueKey('host-edit-screen-test'),
        onPressed: _isTesting || _gatewayHost ? null : _testScreen,
        icon: _isTesting
            ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(LucideIcons.radio, size: 16),
        label: Text(_isTesting ? l10n.connectionEditTesting : l10n.screenTestButton),
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          side: BorderSide(color: AppColors.v3BorderDefault),
          foregroundColor: AppColors.v3TextSecondary,
        ),
      );
      return LayoutBuilder(builder: (context, constraints) {
        final half = (constraints.maxWidth - 12) / 2;
        if (_buttonWordsWidth(context, l10n.screenTestButton) + 16 + 8 + 24 <= half &&
            _buttonWordsWidth(context, saveLabel) + _saveButtonFrame <= half) {
          return Row(children: [Expanded(child: test), const SizedBox(width: 12), Expanded(child: save)]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [test, const SizedBox(height: 12), save]);
      });
    }
    if (!canTest) return Row(children: [Expanded(child: save)]);
    // Test Connection button - split into reachability vs full
    // auth so users can pick the safer test up-front (no creds
    // sent) or the comprehensive one (catches bad identity).
    final test = _TestConnectionButton(
      isTesting: _isTesting,
      onTestReachability:
          _isTesting ? null : () => _testReachability(_baseTestConfig()),
      onTestFullAuth:
          _isTesting ? null : () => _testFullAuth(_baseTestConfig()),
      expanded: true,
    );
    // Side by side where each keeps room for its words in half the row;
    // otherwise the Test button stands over Save, as wide as the page (in
    // half a phone's row, "Test reachability" was cut in two).
    return LayoutBuilder(builder: (context, constraints) {
      final half = (constraints.maxWidth - 12) / 2;
      final testWords = math.max(_buttonWordsWidth(context, l10n.zestHostTestReachability),
          _buttonWordsWidth(context, l10n.zestHostTestFull));
      if (testWords + _testButtonFrame <= half && _buttonWordsWidth(context, saveLabel) + _saveButtonFrame <= half) {
        return Row(children: [Expanded(child: test), const SizedBox(width: 12), Expanded(child: save)]);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [test, const SizedBox(height: 12), save],
      );
    });
  }

  /// What the phone's Test button holds besides its words: its icon and the
  /// room around it and its words, and the swap button beside it.
  static const double _testButtonFrame = 16 + 8 + 24 + 8 + 44;

  /// What the phone's Save button holds besides its words: its icon and the
  /// room between it and its words, with a little to spare.
  static const double _saveButtonFrame = 18 + 8 + 24;

  /// How wide a button's [words] are drawn, at the text size the app is
  /// drawn at.
  double _buttonWordsWidth(BuildContext context, String words) {
    final painter = TextPainter(
      text: TextSpan(text: words, style: Theme.of(context).textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  Widget _buildTestResultBanner() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: HostTestResultBanner(
        result: _testResult!,
        onClose: () => setState(() => _testResult = null),
      ),
    );
  }

  // ── Test Connection logic ──────────────────────────────────────

  /// The host's BASE connection as an [EffectiveTestConfig] - what the footer
  /// "Test connection" buttons probe. Username is left null so the full-auth
  /// test derives it from the selected identity exactly as it did before the
  /// probes were parameterised.
  EffectiveTestConfig _baseTestConfig() {
    return EffectiveTestConfig(
      host: _hostController.text.trim(),
      port: int.tryParse(_portController.text.trim()) ?? 0,
      username: null,
      identityKeyId: _identityId,
      jumpChain:
          _connectViaId == null ? const <String>[] : <String>[_connectViaId!],
    );
  }

  /// The two tests, with what the form says now ([HostTester] has their logic
  /// and every gate): reachability, without a credential, and the full test.
  HostTester get _tester => HostTester(
        context: context,
        ref: ref,
        hostId: widget.connectionId,
        compatibilityMode: _compatibilitySaved,
        sftpOnly: _sftpOnly,
        addressChosenHere: _testAddressChosenHere,
        ftps: _ftps,
        ftpsImplicit: _protocol == ConnectionProtocol.ftpsImplicit,
        screenSocket: _screenUnix ? _socketController.text : null,
        screenRdp: _rdp,
        screenRdpNla: _screenOptions.nla,
      );

  /// A remote screen's one Test (4.0): through its SSH host to the VNC
  /// server's greeting, or directly to VeNCrypt's offer; no VNC password.
  /// For an RDP host: to the server's answer to the connection request,
  /// which says whether it signs in the way the host is set to; no TLS, no
  /// user name, no password.
  Future<void> _testScreen() => _runTest((started) => _tester.screenTest(_baseTestConfig(), onStarted: started));

  Future<void> _testReachability(EffectiveTestConfig cfg) {
    _runningTest = _HostTestKind.reachability;
    return _runTest((started) => _tester.reachability(cfg, onStarted: started));
  }

  Future<void> _testFullAuth(EffectiveTestConfig cfg) {
    _runningTest = _HostTestKind.full;
    return _runTest((started) => _tester.fullConnection(cfg, onStarted: started));
  }

  /// Runs a test: what is refused before it begins leaves what was shown until
  /// its own result, and one that begins clears it and shows it is running.
  Future<void> _runTest(Future<HostTestResult?> Function(VoidCallback started) test) async {
    var began = false;
    try {
      final result = await test(() {
        began = true;
        setState(() {
          _isTesting = true;
          _testResult = null;
        });
      });
      if (mounted && result != null) setState(() => _testResult = result);
    } finally {
      if (began && mounted) setState(() => _isTesting = false);
    }
  }

  /// Network settings section - port, keep-alive, compression, jump host.
  Widget _buildNetworkSection({
    required AsyncValue<List<dynamic>> connectionsAsync,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return _withSecondaryLabels(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: AppLocalizations.of(context)!.connectionNetwork),

        // Connect Via (jump server / proxy) - Pro only. SSH alone goes
        // through one (and SFTP only, which signs in as SSH): Mosh, Eternal
        // Terminal and Serial sessions are built with no jump chain, so the
        // row was a promise nothing kept.
        if (_protocol == ConnectionProtocol.ssh || _sftpOnly) ...[
          Builder(builder: (context) {
            final isPro = ref.watch(isProProvider);
            if (!isPro) {
              // The upgrade button beside the line under the name, or under
              // that line where it does not fit, so the name keeps the row's
              // width (beside the name, at 1.3 times the text size, the
              // button left it 91 pixels and cut "(opzionale)").
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(LucideIcons.lock, size: 20),
                title: Text(l10n.connectionConnectVia),
                subtitle: BesideOrUnder(
                  minWordsWidth: 160,
                  words: Text(l10n.proFeature,
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  control: FilledButton(
                    onPressed: () => context.push(Routes.upgrade),
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.orange,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text(l10n.upgrade),
                  ),
                ),
              );
            }
            return connectionsAsync.when(
              data: (allConnections) {
                // Only hosts signed in to over SSH can be a jump host; the
                // one saved before stays shown (the chain refuses it).
                final others = allConnections
                    .where((c) =>
                        c.id != widget.connectionId &&
                        (ConnectionProtocol.storedCanBeJumpHost(c.protocol as String?) || c.id == _connectViaId))
                    .toList();
                // Left label cell + an inline info affordance (the Connect Via
                // help sheet) kept as a small trailing button beside the shell.
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      // The app's select in the field's shell (found in a design
                      // audit).
                      child: ZestSelect<String?>(
                        value: _connectViaId,
                        hint: l10n.connectionConnectViaHint,
                        items: [
                          ZestSelectItem(null, l10n.connectionDirect),
                          for (final c in others)
                            // Masked label; the value stays the id.
                            ZestSelectItem(
                              c.id as String,
                              (c.label as String).isNotEmpty
                                  ? Redactable.host(c.label as String).displayIn(ref)
                                  : Redactable.address(c.host as String).displayIn(ref),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == _connectViaId) return;
                          setState(() => _connectViaId = v);
                          _markDirty();
                        },
                        frame: (value) => ZestField.custom(label: l10n.connectionConnectVia, child: value),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(LucideIcons.info, size: 18),
                      tooltip: l10n.connectionConnectVia,
                      color: AppColors.accentInk,
                      onPressed: () => _showConnectViaInfo(context),
                    ),
                  ],
                );
              },
              loading: () => const SizedBox.shrink(),
              error: (_, _) => const SizedBox.shrink(),
            );
          }),
          const SizedBox(height: 16),
        ],

        // Keep-Alive interval: SSH alone uses the host's, and SFTP only (Mosh
        // and Eternal Terminal keep their own sessions alive, and Serial
        // sends one every 15 seconds whatever is set).
        if (_protocol == ConnectionProtocol.ssh || _sftpOnly) ...[
          // The app's select in the field's shell (found in a design
          // audit). Its help stands under the field, not in the
          // shell, so the menu hangs under the field itself.
          ZestSelect<int>(
            value: _showCustomKeepAlive ? -1 : _keepAliveSeconds,
            items: [
              ZestSelectItem(0, l10n.connectionEditKeepAliveGlobal),
              ZestSelectItem(15, l10n.connectionEditKeepAlive15s),
              ZestSelectItem(30, l10n.connectionEditKeepAlive30s),
              ZestSelectItem(60, l10n.connectionEditKeepAlive60s),
              ZestSelectItem(120, l10n.connectionEditKeepAlive2m),
              ZestSelectItem(300, l10n.connectionEditKeepAlive5m),
              ZestSelectItem(-1, l10n.connectionEditKeepAliveCustom),
            ],
            onChanged: (v) {
              if (v == (_showCustomKeepAlive ? -1 : _keepAliveSeconds)) return;
              setState(() {
                if (v == -1) {
                  _showCustomKeepAlive = true;
                } else {
                  _showCustomKeepAlive = false;
                  _keepAliveSeconds = v;
                }
              });
              _markDirty();
            },
            frame: (value) => ZestField.custom(label: l10n.settingsKeepaliveInterval, child: value),
          ),
          const SizedBox(height: 6),
          Text(l10n.connectionKeepAliveDesc, style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textMuted)),
          if (_showCustomKeepAlive) ...[
            const SizedBox(height: 12),
            ZestField.custom(
              label: l10n.connectionEditCustomInterval,
              child: TextFormField(
                initialValue: _keepAliveSeconds > 0
                    ? _keepAliveSeconds.toString()
                    : '',
                style: _kValMonoStyle,
                decoration: _fieldDecoration(
                    hintText: l10n.connectionEditKeepAliveCustomHint),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (v) {
                  final parsed = int.tryParse(v);
                  if (parsed != null && parsed >= 0) {
                    setState(() => _keepAliveSeconds = parsed);
                  }
                  _markDirty();
                },
                validator: (v) {
                  if (_showCustomKeepAlive) {
                    if (v == null || v.isEmpty) {
                      return l10n.connectionEditEnterValue;
                    }
                    final n = int.tryParse(v);
                    if (n == null || n < 0 || n > 3600) {
                      return l10n.connectionEditKeepAliveRange;
                    }
                  }
                  return null;
                },
              ),
            ),
          ],
          const SizedBox(height: 12),
          // (No Zlib switch: the SSH core offers no compression, so it did
          // nothing. The saved setting is kept as it is for old data.)
          // Agent Forwarding + Compatibility Mode moved to the Auth tab
          // (they're authentication/security behaviours, not networking).
        ],
      ],
    ));
  }

  /// Per-network overrides section. Lets the user adjust address / port /
  /// username / identity / jump chain for this host depending on which
  /// network is currently matched. The widget itself is self-contained;
  /// the parent only needs to plumb the [GlobalKey] so [_save] can read
  /// out the user's edits at save time.
  Widget _buildHostNetworkOverridesSection({
    required AsyncValue<List<Identity>> identitiesAsync,
  }) {
    // Look up the username from the linked identity (if any). This
    // becomes the placeholder text in each row's username field.
    final identities = identitiesAsync.valueOrNull ?? const <Identity>[];
    final identity = _identityId == null
        ? null
        : identities.where((i) => i.id == _identityId).firstOrNull;
    final baseUsername = identity?.username ?? '';

    final port = int.tryParse(_portController.text) ?? 22;

    // The base jump chain mirrors the resolver: the legacy single
    // `connectViaId` wrapped in a list, or empty for a direct connection.
    final baseJumpChain = _connectViaId == null
        ? const <String>[]
        : <String>[_connectViaId!];

    return HostNetworkOverridesSection(
      key: _networkOverridesKey,
      hostId: widget.connectionId,
      baseAddress: _hostController.text.trim(),
      basePort: port,
      baseUsername: baseUsername,
      baseIdentityKeyId: _identityId,
      baseJumpChain: baseJumpChain,
      accentColor: _accentColor,
      // Per-network "Test as this network" reuses the SAME probes as the
      // footer buttons, composed against each row's resolved effective config.
      isTesting: _isTesting,
      onTestReachability: _testReachability,
      onTestFullAuth: _testFullAuth,
    );
  }

  /// Automation section - snippet on connect, group assignment.
  Widget _buildAutomationSection({
    required AsyncValue<List<dynamic>> snippetsAsync,
    required AsyncValue<List<dynamic>> groupsAsync,
  }) {
    final l10n = AppLocalizations.of(context)!;
    return _withSecondaryLabels(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(
            label: AppLocalizations.of(context)!.connectionAutomation),

        // Run Snippet on connect
        snippetsAsync.when(
          data: (snippets) {
            // The app's select in the field's shell (found in a design
            // audit).
            return ZestSelect<String?>(
              value: _snippetId,
              hint: l10n.connectionAutoRunSnippetHint,
              items: [
                ZestSelectItem(null, l10n.none),
                for (final s in snippets) ZestSelectItem(s.id as String, s.label as String),
              ],
              onChanged: (v) {
                if (v == _snippetId) return;
                setState(() => _snippetId = v);
                _markDirty();
              },
              frame: (value) => ZestField.custom(label: l10n.connectionRunSnippet, child: value),
            );
          },
          loading: () => const SizedBox.shrink(),
          error: (_, _) => const SizedBox.shrink(),
        ),
        const SizedBox(height: 11),
        // Free-text command auto-run on connect - the simpler alternative to a
        // snippet when the user just wants to type one line (e.g. tmux attach).
        ZestField.custom(
          label: l10n.connectionStartupCommand,
          helperText: l10n.connectionStartupCommandHelp,
          child: TextField(
            controller: _startupController,
            minLines: 1,
            maxLines: 3,
            maxLength: 2048,
            style: _kValStyle,
            decoration: _fieldDecoration(
              hintText: l10n.connectionStartupCommandHint,
            ).copyWith(counterText: ''),
          ),
        ),
        // Group + tags moved to Basic → ORGANISE (they're metadata, not
        // automation).
      ],
    ));
  }

  /// Environment Variables section - key-value pairs exported on shell start.
  /// Styled as the mockup's `.row` list: a count + brand "Add" in the header,
  /// then one row per var (mono key #e0b48a, mono value #e6e3da, dim ×).
  Widget _buildEnvVarsSection() {
    void addVar() {
      setState(() {
        _envVars.add(_EnvVarEntry(
          key: _watchWords(TextEditingController()),
          value: _watchWords(TextEditingController()),
        ));
      });
      _markDirty();
    }

    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(
          label: l10n.connectionEditEnvironment,
          count: _envVars.isEmpty ? null : _envVars.length,
          actionLabel: l10n.connectionEditEnvAdd,
          onAction: addVar,
        ),
        for (int i = 0; i < _envVars.length; i++)
          Container(
            margin: const EdgeInsets.only(bottom: 5),
            padding: const EdgeInsets.fromLTRB(11, 3, 8, 3),
            decoration: BoxDecoration(
              color: ZestTokens.surfaceElevated,
              borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
              border: Border.all(color: ZestTokens.border, width: 0.5),
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: TextFormField(
                    controller: _envVars[i].key,
                    decoration: _fieldDecoration(hintText: 'MY_VAR'),
                    style: TextStyle(
                      fontFamily: _kMono,
                      fontSize: 12,
                      color: ZestTokens.varHighlight,
                    ),
                    autocorrect: false,
                    inputFormatters: [
                      FilteringTextInputFormatter.allow(
                        RegExp(r'[a-zA-Z0-9_]'),
                      ),
                    ],
                    validator: (v) {
                      if (v != null &&
                          v.isNotEmpty &&
                          !RegExp(r'^[a-zA-Z_][a-zA-Z0-9_]*$').hasMatch(v)) {
                        return l10n.connectionEditEnvInvalidName;
                      }
                      return null;
                    },
                  ),
                ),
                const SizedBox(width: 9),
                Expanded(
                  child: TextFormField(
                    controller: _envVars[i].value,
                    decoration: _fieldDecoration(
                        hintText: l10n.connectionEditEnvValueHint),
                    style: TextStyle(
                      fontFamily: _kMono,
                      fontSize: 12,
                      color: ZestTokens.textPrimary,
                    ),
                    autocorrect: false,
                  ),
                ),
                const SizedBox(width: 4),
                _HeaderIconButton(
                  icon: LucideIcons.x,
                  tooltip: l10n.commonRemove,
                  hoverColor: ZestTokens.statusCritical,
                  onTap: () {
                    setState(() {
                      final removed = _envVars.removeAt(i);
                      removed.key.dispose();
                      removed.value.dispose();
                    });
                    _markDirty();
                  },
                ),
              ],
            ),
          ),
        if (_envVars.isEmpty)
          Text(
            l10n.connectionEditEnvEmpty,
            style: TextStyle(fontSize: 11, color: ZestTokens.textMuted, height: 1.5),
          ),
      ],
    );
  }

  /// Wake-on-LAN section - MAC address and broadcast address.
  Widget _buildWakeOnLanSection() {
    final l10n = AppLocalizations.of(context)!;
    return _withSecondaryLabels(Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.connectionWakeOnLan),
        ZestField.custom(
          label: l10n.connectionMacAddress,
          child: TextFormField(
            controller: _wolMacController,
            style: _kValMonoStyle,
            decoration:
                _fieldDecoration(hintText: l10n.connectionMacAddressHint),
            textCapitalization: TextCapitalization.characters,
            autocorrect: false,
            // What the sender takes is what may be saved: one rule for
            // both, so that no address is saved that can never be woken.
            validator: (v) {
              if (v == null || v.trim().isEmpty) return null;
              return WolService.isValidMac(v) ? null : l10n.connectionMacAddressInvalid;
            },
          ),
        ),
        const SizedBox(height: 12),
        ZestField.custom(
          label: l10n.connectionBroadcastAddress,
          child: TextFormField(
            controller: _wolBroadcastController,
            style: _kValMonoStyle,
            decoration: _fieldDecoration(
                hintText: l10n.connectionBroadcastAddressHint),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
        ),
      ],
    ));
  }

  /// Whether this account may save the host: a new one where it may add, an
  /// existing one where its Crate lets it edit. Always in
  /// your Tree.
  bool get _maySave => _mayWrite(watch: true);

  bool _mayWrite({required bool watch}) => widget.connectionId == null
      ? mayAddScreenSpace(ref, watch: watch)
      : mayChangeItem(ref, 'host', widget.connectionId!, watch: watch);

  /// Whether a test with [cfg] sends to an address this account chose (3.0):
  /// the host is one it may change (a new one it may add, or one
  /// whose Crate lets it edit), or the address tested is not the saved
  /// host's, since these fields take any address whether or not it can be
  /// saved.
  Future<bool> _testAddressChosenHere(EffectiveTestConfig cfg) async {
    final id = widget.connectionId;
    if (id == null || _mayWrite(watch: false)) return true;
    final saved = await ref.read(connectionsDaoProvider).getById(id);
    return saved == null || saved.host.trim() != cfg.host.trim() || saved.port != cfg.port;
  }

  bool get _mayDelete =>
      widget.connectionId != null && mayChangeItem(ref, 'host', widget.connectionId!, delete: true);

  /// A host's overrides per network, tags and other accounts, from the
  /// editor's fields, written for [resolvedHostId].
  Future<void> _writeHostParts(String resolvedHostId) async {
    // Per-network overrides - bake the in-memory drafts and ask the
    // repository to atomically replace the host's row set. Safe to call
    // even when the user hasn't touched the section: the bake returns an
    // empty list and `replaceForHost` deletes whatever was there before
    // (which, for "all rows in Use base mode", is exactly the right
    // outcome). The section may not have finished its initial load yet
    // - `currentState` is null in that case, so just skip.
    // The section is now ALWAYS built (it lives in the inspector's
    // IndexedStack), so `currentState` is non-null immediately - but its
    // overrides load asynchronously. Only persist once `isLoaded` is true,
    // otherwise a fast save would bake an empty draft list and wipe the
    // host's real overrides.
    final overridesState = _networkOverridesKey.currentState;
    if (overridesState != null && overridesState.isLoaded) {
      final drafts = overridesState.bakeDrafts(resolvedHostId);
      await ref
          .read(hostNetworkOverridesRepositoryProvider)
          .replaceForHost(resolvedHostId, drafts);
    }

    // Replace the tag set wholesale. Empty list clears tags. Only persist
    // once the async tag load has resolved (_tagsLoaded) - otherwise a
    // fast save before the load finishes would clear the host's tags.
    if (_tagsLoaded) {
      await ref
          .read(tagsCrudProvider)
          .setTagsForConnection(resolvedHostId, _tags);
    }

    // The other accounts, the same way: only once they were loaded.
    if (_otherAccountsLoaded) {
      await ref.read(hostAccountsDaoProvider).setOtherAccounts(resolvedHostId, _otherAccounts);
    }
  }

  Future<void> _save() async {
    if (!_mayWrite(watch: false)) return;
    // A remote screen through its carrier with no address is on the carrier
    // itself.
    if (_screen && _connectViaId != null && _hostController.text.trim().isEmpty) _hostController.text = 'localhost';
    if (widget.inDialog) {
      // Docked inspector: every tab is built at once but only one is visible,
      // so a validator failing on a hidden tab looks like "Save does nothing".
      // Validate each tab's own Form (so ALL error texts populate), then jump
      // to the FIRST tab that owns an invalid field - not blindly to Basic.
      int? firstInvalidTab;
      for (var i = 0; i < _inspectorTabFormKeys.length; i++) {
        final ok = _inspectorTabFormKeys[i].currentState?.validate() ?? true;
        if (!ok && firstInvalidTab == null) firstInvalidTab = i;
      }
      if (firstInvalidTab != null) {
        if (mounted) {
          setState(() => _inspectorTab = firstInvalidTab!);
          showTopSnackBar(
            context,
            AppLocalizations.of(context)!.connectionEditFixFields,
            isError: true,
          );
        }
        return;
      }
    } else if (!_formKey.currentState!.validate()) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.connectionEditFixFields,
          isError: true,
        );
      }
      return;
    }
    // An RD Gateway chosen with an address or port that is none (its field not drawn in this
    // layout, so not validated): never saved as a host with no gateway, which would open directly.
    if (_screen && _rdp && _throughGateway) {
      final port = int.tryParse(_gatewayPortController.text.trim());
      if (!ScreenGateway(host: _gatewayHostController.text.trim(), port: port ?? 0).readable) {
        if (mounted) {
          showTopSnackBar(context, AppLocalizations.of(context)!.connectionEditRdpGatewayHostInvalid, isError: true);
        }
        return;
      }
    }

    setState(() => _isLoading = true);

    try {
      final crud = ref.read(connectionCrudProvider);
      final prefs = ref.read(sharedPreferencesProvider);

      // Local shell has no network host/port: coerce to safe sentinels so the
      // DB host-length constraint and int.parse never reject a host-less shell
      // (hot fix - Address/Port are irrelevant for a local shell). A blank
      // nickname falls back to "Local Shell" rather than an empty host.
      final isLocal = _protocol == ConnectionProtocol.localShell;
      final typedHost = _hostController.text.trim();
      final saved = isLocal ? null : savedAddress(typedHost, int.parse(_portController.text));
      final rawHost = saved?.host ?? typedHost;
      final effectiveHost =
          isLocal ? (rawHost.isEmpty ? 'localhost' : rawHost) : rawHost;
      final effectivePort = isLocal
          ? (int.tryParse(_portController.text.trim()) ?? 22)
          : saved!.port;
      // Generate a label from host if nickname is empty.
      final label = _labelController.text.trim().isNotEmpty
          ? _labelController.text.trim()
          : (isLocal
              ? AppLocalizations.of(context)!.connectionEditLocalShellDefault
              : rawHost);

      final wolMac = _wolMacController.text.trim();
      final wolBroadcast = _wolBroadcastController.text.trim();

      final envVarsJson = _serializeEnvVars();

      // Resolved host id - known up front for an edit, captured from the
      // `crud.create` return value for a new host. Used after the host save
      // succeeds to atomically replace the per-network override rows.
      String resolvedHostId;
      var partsWritten = false;
      // Saved in another place than where the screen is ("Save in"): its name.
      String? savedIn;

      if (widget.connectionId != null) {
        // A team's host keeps its kind class (FTPS 3.4, screens 4.0): said here, before
        // anything is written (its pills offer no other; the team's
        // database refuses it as well).
        if (_teamKindFixed && ConnectionProtocol.kindClassOf(_protocol.name) != _savedKindClass) {
          showTopSnackBar(context, AppLocalizations.of(context)!.teamHostKindFixed, isWarning: true);
          return;
        }
        // Persist per-connection terminal theme override
        final themeKey = 'terminal_theme_${widget.connectionId}';
        if (_terminalThemeId != null) {
          await prefs.setString(themeKey, _terminalThemeId!);
        } else {
          await prefs.remove(themeKey);
        }
        // Invalidate the provider so the terminal picks up changes
        ref.invalidate(connectionTerminalThemeProvider(widget.connectionId!));

        // SFTP only again: a device on an older version turning it back is old news.
        if (_protocol == ConnectionProtocol.sftp) {
          await ref.read(settingsServiceProvider).forgetSftpOnlyTurnedBack(widget.connectionId!);
        }

        // A sync (personal or the team's) may have changed this host while the
        // editor was open: a field the person did not touch takes what is
        // there now, and only the fields they changed are written. Save wrote
        // every field of the form, so another device's change went back and,
        // stamped as changed now, won on every device (found in a code
        // audit).
        final now = await ref.read(connectionsDaoProvider).getById(widget.connectionId!);
        final kept = keptFromSync(_loadedRow, now);
        final note = _noteController.text.trim().isEmpty ? null : _noteController.text.trim();
        final startup = _startupController.text.trim().isEmpty ? null : _startupController.text.trim();
        final identityId = kept(_identityId, (c) => c.identityId);
        final groupId = kept(_groupId, (c) => c.groupId);
        final snippetId = kept(_snippetId, (c) => c.snippetId);
        final connectViaId = kept(_connectViaId, (c) => c.connectViaId);
        final colorValue = kept(_colorValue, (c) => c.colorValue);
        final mac = kept(wolMac.isEmpty ? null : wolMac, (c) => c.wolMacAddress);
        final broadcast = kept(wolBroadcast.isEmpty ? null : wolBroadcast, (c) => c.wolBroadcastAddress);
        final keptNote = kept(note, (c) => c.note);
        final keptStartup = kept(startup, (c) => c.startupCommand);
        // The RD Gateway is a field of its own inside the options column: one a sync brought, took
        // away or changed while the editor was open stays as the sync left it, unless the person
        // changed Reach through here (a host that lost its gateway would open the PC directly).
        var screenOptions = _screenOptionsToSave();
        if (screenOptions != null && _rdp && now != null) {
          final form = ScreenOptions.decode(screenOptions);
          final gateway = kept<ScreenGateway?>(form.gateway, (c) => ScreenOptions.decode(c.screenOptions).gateway);
          if (gateway == ScreenGateway.unreadable && form.gateway != gateway) {
            // One this version cannot read: the column as the sync left it.
            screenOptions = now.screenOptions;
          } else if (gateway != form.gateway) {
            screenOptions =
                (gateway == null ? form.copyWith(clearGateway: true) : form.copyWith(gateway: gateway)).encode();
          }
        }
        await crud.update(
          id: widget.connectionId!,
          label: kept(label, (c) => c.label),
          host: kept(effectiveHost, (c) => c.host),
          port: kept(effectivePort, (c) => c.port),
          protocol: _protocol.name,
          identityId: identityId,
          clearIdentityId: identityId == null,
          groupId: groupId,
          clearGroupId: groupId == null,
          snippetId: snippetId,
          clearSnippetId: snippetId == null,
          connectViaId: connectViaId,
          clearConnectViaId: connectViaId == null,
          // A remote screen's options; none for any other host.
          screenOptions: screenOptions,
          setScreenOptions: true,
          colorIndex: kept(_colorIndex, (c) => c.colorIndex),
          colorValue: colorValue,
          clearColorValue: colorValue == null,
          iconId: _iconId,
          customIcon: _customIcon,
          setIcon: true,
          iconColor: _iconColor,
          setIconColor: true,
          zlibCompression: kept(_zlibCompression, (c) => c.zlibCompression),
          forwardAgent: kept(_forwardAgent, (c) => c.forwardAgent),
          compatibilityMode: kept(_compatibilitySaved, (c) => c.compatibilityMode),
          keepAliveSeconds: kept(_keepAliveSeconds, (c) => c.keepAliveSeconds),
          wolMacAddress: mac,
          clearWolMacAddress: mac == null,
          wolBroadcastAddress: broadcast,
          clearWolBroadcastAddress: broadcast == null,
          envVars: kept(envVarsJson, (c) => c.envVars),
          note: keptNote,
          clearNote: keptNote == null,
          startupCommand: keptStartup,
          clearStartupCommand: keptStartup == null,
        );
        resolvedHostId = widget.connectionId!;
      } else {
        // Written where "Save in" says (3.4): where new items of the space
        // on screen go, as before, or any other place, with what it uses
        // asked about first.
        Future<String> writeNew() async {
          final id = await crud.create(
            label: label,
            host: effectiveHost,
            port: effectivePort,
            protocol: _protocol.name,
            identityId: _identityId,
            groupId: _groupId,
            snippetId: _snippetId,
            connectViaId: _connectViaId,
            screenOptions: _screenOptionsToSave(),
            colorIndex: _colorIndex,
            colorValue: _colorValue,
            iconId: _iconId,
            customIcon: _customIcon,
            iconColor: _iconColor,
            zlibCompression: _zlibCompression,
            forwardAgent: _forwardAgent,
            compatibilityMode: _compatibilitySaved,
            keepAliveSeconds: _keepAliveSeconds,
            wolMacAddress: wolMac.isEmpty ? null : wolMac,
            wolBroadcastAddress: wolBroadcast.isEmpty ? null : wolBroadcast,
            envVars: envVarsJson,
            note: _noteController.text.trim().isEmpty
                ? null
                : _noteController.text.trim(),
            startupCommand: _startupController.text.trim().isEmpty
                ? null
                : _startupController.text.trim(),
          );
          // Its terminal theme, where one was chosen (it was kept for a host
          // that was there alone: a new host's was dropped).
          if (_terminalThemeId != null) {
            await prefs.setString('terminal_theme_$id', _terminalThemeId!);
          }
          await _writeHostParts(id);
          return id;
        }

        final place = _saveIn ?? defaultSavePlace(ref);
        if (place != defaultSavePlace(ref)) {
          savedIn = savePlaces(ref, AppLocalizations.of(context)!, watch: false)
              .where((p) => p.place == place)
              .firstOrNull
              ?.title;
        }
        final saved = await saveNewItemIn(context, ref, place: place, kind: TransferKinds.host, write: writeNew);
        if (saved == null) return;
        resolvedHostId = saved;
        partsWritten = true;
      }

      if (!partsWritten) await _writeHostParts(resolvedHostId);

      // Persisted. Flip _dirty through setState so the mobile screen's
      // PopScope (canPop: !_dirty) rebuilds to PERMIT the close - a synchronous
      // pop while still-dirty is swallowed by that PopScope, which is why the
      // editor used to just sit open with no feedback after a successful save.
      // Confirm with a success toast (it renders in the ROOT overlay, so it
      // survives the pop and lands on the hosts list), then dismiss on the next
      // frame, once canPop has rebuilt to true.
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        final created = widget.connectionId == null;
        setState(() => _dirty = false);
        showTopSnackBar(
          context,
          savedIn != null
              ? l10n.saveInSavedToast(Redactable.freeText(savedIn).display)
              : created
                  ? l10n.connectionCreatedToast(label)
                  : l10n.connectionUpdatedToast(label),
          isSuccess: true,
        );
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted) return;
          // Saved while sync is off: said, over the editor, before it closes.
          final router = GoRouter.maybeOf(context);
          final setUp = await maybeShowSyncOffNotice(context, ref);
          // A host that signs in with a saved key or password: the app lock is
          // offered, once (a computer too, 4.0).
          if (_identityId != null && mounted) await maybeOfferAppLock(context, ref);
          if (mounted) _closeEditor();
          if (setUp) router?.push(Routes.profile);
        });
      } else {
        _dirty = false;
      }
    } catch (e) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showTopSnackBar(
          context,
          isOrchardWriteRefused(e)
              ? l10n.orchardWriteNotAllowed
              : isTeamHostKindRefused(e)
                  ? l10n.teamHostKindFixed
                  : l10n.connectionNotSaved,
          isError: true,
          details: isOrchardWriteRefused(e) || isTeamHostKindRefused(e) ? null : '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Open the QR / link share sheet for the connection currently
  /// being edited. Pulls the latest persisted port forwards from
  /// the DB (the in-memory port-forward draft state isn't accessible
  /// here without a wider refactor) and translates the form's
  /// in-memory identity / group selections into label hints - only
  /// names cross the wire, never IDs or key material.
  Future<void> _shareConnection() async {
    if (widget.connectionId == null) return;
    // An Orchard's hosts leave in a share only an owner makes.
    if (!mayExportScreenSpace(ref)) return;

    // Pull live port forwards from the DB (these are the ones the
    // share recipient will get; unsaved drafts in the editor stay
    // local until Save).
    final pfDao = ref.read(portForwardRulesDaoProvider);
    final forwardRules =
        await pfDao.getByConnection(widget.connectionId!);
    final forwards = forwardRules
        .map((r) => SharedForward(
              type: r.type,
              bindAddress: r.bindAddress,
              bindPort: r.bindPort,
              remoteHost: r.remoteHost,
              remotePort: r.remotePort,
              label: r.label,
            ))
        .toList();

    // Identity hint = the local label of the picked identity, if any.
    // We never share the key itself or its passphrase - the receiver
    // sees the hint and picks one of their own identities to match.
    String? identityHint;
    if (_identityId != null) {
      try {
        final identity =
            await ref.read(identitiesDaoProvider).getById(_identityId!);
        identityHint = identity?.label;
      } catch (_) {
        // Best-effort - share works without the hint.
      }
    }

    String? groupHint;
    if (_groupId != null) {
      try {
        final group = await ref
            .read(connectionGroupsDaoProvider)
            .getById(_groupId!);
        groupHint = group?.name;
      } catch (_) {}
    }

    if (!mounted) return;

    final label = _labelController.text.trim().isEmpty
        ? _hostController.text.trim()
        : _labelController.text.trim();
    final port = int.tryParse(_portController.text.trim()) ?? 22;

    await ShareConnectionSheet.show(
      context,
      label: label,
      host: _hostController.text.trim(),
      port: port,
      // Username - connection_edit_screen uses identity-based auth,
      // so the user/login lives on the identity row, not the
      // connection. We pass null here; the receiver matches via the
      // identity hint.
      user: null,
      identityHint: identityHint,
      groupHint: groupHint,
      forwards: forwards,
    );
  }

  /// Advanced's last section: Delete, red, with its question.
  Widget _buildDeleteSection(AppLocalizations l10n) {
    return Column(
      key: const ValueKey('host-edit-delete-section'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader(label: l10n.heditDeleteTitle),
        Text(
          l10n.heditDeleteBody,
          style: TextStyle(color: ZestTokens.textMuted, fontSize: 11.5, height: 1.5),
        ),
        const SizedBox(height: 10),
        ZestButton(
          key: const ValueKey('host-edit-delete'),
          label: l10n.delete,
          icon: LucideIcons.trash2,
          variant: ZestButtonVariant.danger,
          onPressed: _confirmDelete,
        ),
      ],
    );
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    // The app's own question, in the tone of what cannot be taken back.
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.connectionDeleteTitle,
      body: l10n.connectionDeleteMsg,
      confirmLabel: l10n.delete,
    );

    if (confirmed == true && mounted) {
      await ref.read(connectionCrudProvider).delete(widget.connectionId!);
      if (mounted) _closeEditor();
    }
  }
}

// ─── Docked-inspector section rail ──────────────────────────────

/// Vertical icon+label rail on the left of the desktop connection
/// inspector - Basic / Auth / Network / Terminal / Advanced. Switching a
/// tab only changes which IndexedStack child is visible; every section
/// stays built so no edits are lost.
class _InspectorRail extends StatelessWidget {
  const _InspectorRail({
    required this.active,
    required this.accent,
    required this.onSelect,
  });

  final int active;
  final Color accent;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = <({IconData icon, String label})>[
      (icon: LucideIcons.slidersHorizontal, label: l10n.connectionEditRailBasic),
      (icon: LucideIcons.keyRound, label: l10n.connectionEditRailAuth),
      (icon: LucideIcons.network, label: l10n.connectionEditRailNetwork),
      (icon: LucideIcons.terminal, label: l10n.connectionEditRailTerminal),
      (icon: LucideIcons.settings, label: l10n.connectionEditRailAdvanced),
    ];
    // `.rail` - 56px wide, border-right 0.5px #1f1f23, padding 11px 5px.
    return Container(
      width: 72,
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: Border(
          right: BorderSide(color: ZestTokens.surfaceRaised, width: 0.5),
        ),
      ),
      // stretch → every item's highlight box is the full rail width, so a short
      // label ("Basic") gets the SAME size box as a long one ("Advanced").
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < items.length; i++)
            _RailItem(
              icon: items[i].icon,
              label: items[i].label,
              selected: i == active,
              accent: accent,
              onTap: () => onSelect(i),
            ),
        ],
      ),
    );
  }
}

class _RailItem extends StatefulWidget {
  const _RailItem({
    required this.icon,
    required this.label,
    required this.selected,
    required this.accent,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final Color accent;
  final VoidCallback onTap;

  @override
  State<_RailItem> createState() => _RailItemState();
}

class _RailItemState extends State<_RailItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // `.rail-item` muted #8d8b83; ACTIVE = brand-fill #231a12 bg + 2px brand
    // left-border + brand colour.
    // The picked one in the brand's ink, which reads at 4.5:1 in every theme
    // (the brand itself was 2.6:1 on Daylight's white).
    final color = widget.selected
        ? ZestTokens.brandInk
        : (_hover ? ZestTokens.textSecondary : ZestTokens.textTertiary);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Semantics + InkWell (not a bare GestureDetector) so the rail is
      // Tab-focusable, activates on Enter/Space, and announces its selected
      // state to screen readers.
      child: Semantics(
        button: true,
        selected: widget.selected,
        label: widget.label,
        child: InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(6),
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: widget.selected ? ZestTokens.brandFill : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border(
                left: BorderSide(
                  color: widget.selected ? ZestTokens.brand : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(widget.icon, size: 22, color: color),
                const SizedBox(height: 5),
                // Said by the item's label ("Basic" was read twice).
                Text(
                  widget.label,
                  semanticsLabel: '',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 11,
                    color: color,
                    fontWeight:
                        widget.selected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Header icon button ─────────────────────────────────────────

/// The two tests of a host that is not a remote screen.
enum _HostTestKind { reachability, full }

/// Understated icon button for the inspector header (move or copy, share).
/// Ghost by default, tinting to [hoverColor] on hover. (The close beside them
/// is a [ZestCloseButton].)
class _HeaderIconButton extends StatefulWidget {
  const _HeaderIconButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.hoverColor,
    this.focusNode,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final Color? hoverColor;
  final FocusNode? focusNode;

  @override
  State<_HeaderIconButton> createState() => _HeaderIconButtonState();
}

class _HeaderIconButtonState extends State<_HeaderIconButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    // `.head-act` - 16px #8d8b83, tinting to [hoverColor] on hover.
    final hoverColor = widget.hoverColor ?? ZestTokens.textSecondary;
    // Reached with Tab, named for a screen reader, pressed anywhere in a
    // mouse's 32 (a finger's 48) around its 30 (4.0, the accessibility pass).
    return Tooltip(
      message: widget.tooltip,
      excludeFromSemantics: true,
      child: ZestPressable(
          onTap: widget.onTap,
          focusNode: widget.focusNode,
          onHover: (h) => setState(() => _hover = h),
          semanticLabel: widget.tooltip,
          excludeChildSemantics: true,
          borderRadius: 7,
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: _hover
                  ? hoverColor.withValues(alpha: 0.14)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Icon(
              widget.icon,
              size: 16,
              color: _hover ? hoverColor : ZestTokens.textTertiary,
            ),
          ),
      ),
    );
  }
}

// ─── Field label widths ──────────────────────────────────────────
// The combined left-label field / section header / footer now live in the
// shared ZestField / ZestSectionHeader / ZestPaneFooter widgets.

/// The least `.cell` width of the secondary panes (Network / Terminal /
/// Advanced), whose labels ("Keepalive Interval", "Broadcast Address", …) are
/// longer than the Basic pane's; a longer name widens it
/// ([_ConnectionEditScreenState._withSecondaryLabels]).
const double _kSecondaryLabelWidth = 132;


// ─── Inline tags editor ─────────────────────────────────────────

/// A bare, in-place tag editor for the Tags [ZestField.custom]. Renders the existing
/// tags as chips and a bare add-tag input DIRECTLY in the field's value region
/// (a wrap on the field's own sunken surface) - it draws NO box of its own, so
/// the tags field reads exactly like every other field instead of a decorated
/// input nested inside the shell.
///
/// Behaviour mirrors the app's shared tags editor exactly: commit on Enter,
/// comma, or blur; autocomplete from [availableTags] (already-applied tags
/// filtered out); canonicalise via [ConnectionTagsDao.normalize]; Backspace on
/// an empty input removes the last chip; the parent owns the canonical list via
/// [onChanged].
class _InlineTagsField extends StatefulWidget {
  const _InlineTagsField({
    required this.tags,
    required this.onChanged,
    this.availableTags = const [],
    this.hintText,
  });

  final List<String> tags;
  final ValueChanged<List<String>> onChanged;
  final List<String> availableTags;
  final String? hintText;

  @override
  State<_InlineTagsField> createState() => _InlineTagsFieldState();
}

class _InlineTagsFieldState extends State<_InlineTagsField> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _focusNode.addListener(_handleFocusChange);
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleFocusChange() {
    // Commit any in-flight text when focus leaves so typing isn't lost on save.
    if (!_focusNode.hasFocus) {
      _commit(_controller.text);
    }
  }

  void _commit(String raw) {
    final canonical = ConnectionTagsDao.normalize(raw);
    if (canonical == null) {
      _controller.clear();
      return;
    }
    if (widget.tags.contains(canonical)) {
      _controller.clear();
      return;
    }
    final updated = [...widget.tags, canonical]..sort();
    widget.onChanged(updated);
    _controller.clear();
  }

  void _remove(String tag) {
    final updated = widget.tags.where((t) => t != tag).toList();
    widget.onChanged(updated);
  }

  @override
  Widget build(BuildContext context) {
    final suggestions = widget.availableTags
        .where((t) => !widget.tags.contains(t))
        .toList(growable: false);

    return Wrap(
      spacing: 5,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final tag in widget.tags)
          _InlineTagChip(label: tag, onDelete: () => _remove(tag)),
        // Bare add-tag input - no box, sits on the field's own surface.
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 96, maxWidth: 180),
          child: RawAutocomplete<String>(
            textEditingController: _controller,
            focusNode: _focusNode,
            optionsBuilder: (value) {
              final query = value.text.trim().toLowerCase();
              if (query.isEmpty) return suggestions;
              return suggestions.where((s) => s.contains(query)).toList();
            },
            onSelected: _commit,
            fieldViewBuilder:
                (context, controller, focusNode, onFieldSubmitted) {
              // Backspace on an empty input deletes the last chip - same removal
              // path as the per-chip x. Purely an event interceptor: it neither
              // takes focus nor a traversal stop, so a normal backspace (when
              // text is present) is untouched.
              return Focus(
                canRequestFocus: false,
                skipTraversal: true,
                onKeyEvent: (node, event) {
                  if (event is KeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.backspace &&
                      controller.text.isEmpty &&
                      widget.tags.isNotEmpty) {
                    _remove(widget.tags.last);
                    return KeyEventResult.handled;
                  }
                  return KeyEventResult.ignored;
                },
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  maxLength: ConnectionTagsDao.maxLength,
                  style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                  decoration: InputDecoration(
                    isCollapsed: true,
                    isDense: true,
                    filled: false,
                    // Its target a mouse's 32 high, a finger's 48 (its line
                    // of 20 was all of it: 4.0, the accessibility pass).
                    contentPadding: EdgeInsets.symmetric(vertical: (minTapTarget(context) - 12) / 2),
                    border: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    disabledBorder: InputBorder.none,
                    errorBorder: InputBorder.none,
                    focusedErrorBorder: InputBorder.none,
                    counterText: '',
                    hintText: widget.hintText ?? gl10n.zestHostAddTag,
                    // Read at 4.5:1 (the turned-off grey was under 3:1).
                    hintStyle: TextStyle(color: ZestTokens.textTertiary, fontSize: 13),
                  ),
                  // Commit on comma without inserting it.
                  inputFormatters: [
                    TextInputFormatter.withFunction((oldValue, newValue) {
                      if (newValue.text.endsWith(',')) {
                        final candidate = newValue.text
                            .substring(0, newValue.text.length - 1);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (!mounted) return;
                          _commit(candidate);
                        });
                        return TextEditingValue(
                          text: candidate,
                          selection: TextSelection.collapsed(
                            offset: candidate.length,
                          ),
                        );
                      }
                      return newValue;
                    }),
                  ],
                  onSubmitted: (value) {
                    _commit(value);
                    focusNode.requestFocus();
                  },
                ),
              );
            },
            optionsViewBuilder: (context, onSelected, options) {
              return Align(
                alignment: Alignment.topLeft,
                child: Material(
                  color: ZestTokens.surfaceRaisedAlt,
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints:
                        const BoxConstraints(maxHeight: 200, maxWidth: 320),
                    child: ListView.builder(
                      shrinkWrap: true,
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final opt = options.elementAt(index);
                        return InkWell(
                          onTap: () => onSelected(opt),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 8),
                            child: Text(
                              opt,
                              style:
                                  TextStyle(color: ZestTokens.textPrimary, fontSize: 13),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

/// `.tag` chip - 11px `ZestTokens.textSecondary` on a `ZestTokens.surfaceChip` surface, radius 4, with a small
/// dim x to remove (removal also available via Backspace on the empty input).
class _InlineTagChip extends StatelessWidget {
  const _InlineTagChip({required this.label, required this.onDelete});

  final String label;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final target = minTapTarget(context);
    final chip = Container(
      padding: const EdgeInsets.fromLTRB(8, 2, 4, 2),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: ZestTokens.textSecondary)),
          const SizedBox(width: 3),
          ExcludeSemantics(child: Icon(LucideIcons.x, size: 12, color: ZestTokens.textMuted)),
        ],
      ),
    );
    // The chip drawn as it was; its x pressed anywhere in a mouse's 32 (a
    // finger's 48) square centred on it, reached with Tab and said as
    // "Remove tag prod" (it was a 12 px "Remove": 4.0, the accessibility
    // pass).
    return SizedBox(
      height: target,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Padding(
            padding: EdgeInsetsDirectional.only(end: target / 2 - 10),
            child: Center(widthFactor: 1, child: chip),
          ),
          PositionedDirectional(
            end: 0,
            top: 0,
            bottom: 0,
            width: target,
            child: Tooltip(
              message: l10n.commonRemove,
              excludeFromSemantics: true,
              child: ZestPressable(
                onTap: onDelete,
                semanticLabel: l10n.hostTagRemove(label),
                minSize: 0,
                borderRadius: 4,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Port Forward Form Dialog ────────────────────────────────────

class _PortForwardFormResult {
  final String id;
  final String type;
  final String bindAddress;
  final int bindPort;
  final String remoteHost;
  final int remotePort;
  final bool autoStart;
  final String? label;

  const _PortForwardFormResult({
    required this.id,
    required this.type,
    required this.bindAddress,
    required this.bindPort,
    required this.remoteHost,
    required this.remotePort,
    required this.autoStart,
    this.label,
  });
}

class _PortForwardFormDialog extends StatefulWidget {
  const _PortForwardFormDialog({super.key});

  @override
  State<_PortForwardFormDialog> createState() => _PortForwardFormDialogState();
}

class _PortForwardFormDialogState extends State<_PortForwardFormDialog> {
  String _type = 'local';
  final _labelController = TextEditingController();
  final _bindPortController = TextEditingController();
  final _remoteHostController = TextEditingController(text: 'localhost');
  final _remotePortController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _autoStart = true;

  bool get _isDynamic => _type == 'dynamic';

  @override
  void dispose() {
    _labelController.dispose();
    _bindPortController.dispose();
    _remoteHostController.dispose();
    _remotePortController.dispose();
    super.dispose();
  }

  void _applyPreset(String name) {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      switch (name) {
        case 'web':
          _type = 'local';
          _labelController.text = l10n.connectionEditPresetWebService;
          _bindPortController.text = '8080';
          _remoteHostController.text = 'localhost';
          _remotePortController.text = '80';
        case 'database':
          _type = 'local';
          _labelController.text = l10n.connectionEditPfDatabase;
          _bindPortController.text = '5432';
          _remoteHostController.text = 'localhost';
          _remotePortController.text = '5432';
        case 'socks':
          _type = 'dynamic';
          _labelController.text = l10n.connectionEditPresetSocksProxy;
          _bindPortController.text = '1080';
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): Cancel and Add in its footer.
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.arrowLeftRight,
      title: l10n.connectionEditAddPortForwardTitle,
      body: Form(
        key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Presets
              Wrap(
                spacing: 8,
                children: [
                  // A browser's window, as the port forward page's Web
                  // preset (a translate icon stood here).
                  ActionChip(
                    key: const ValueKey('host-pf-preset-web'),
                    avatar: const Icon(LucideIcons.appWindow, size: 16),
                    label: Text(l10n.connectionEditPfWeb),
                    onPressed: () => _applyPreset('web'),
                  ),
                  ActionChip(
                    avatar: const Icon(LucideIcons.hardDrive, size: 16),
                    label: Text(l10n.connectionEditPfDatabase),
                    onPressed: () => _applyPreset('database'),
                  ),
                  ActionChip(
                    avatar: const Icon(LucideIcons.globe, size: 16),
                    label: Text(l10n.connectionEditPfSocks),
                    onPressed: () => _applyPreset('socks'),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Type selector
              SegmentedButton<String>(
                segments: [
                  ButtonSegment(
                    value: 'local',
                    label: Text(l10n.connectionEditPfLocal),
                    icon: const Icon(LucideIcons.arrowRight, size: 16),
                  ),
                  ButtonSegment(
                    value: 'remote',
                    label: Text(l10n.connectionEditPfRemote),
                    icon: const Icon(LucideIcons.arrowLeft, size: 16),
                  ),
                  ButtonSegment(
                    value: 'dynamic',
                    label: Text(l10n.connectionEditPfSocks5),
                    icon: const Icon(LucideIcons.globe, size: 16),
                  ),
                ],
                selected: {_type},
                onSelectionChanged: (s) => setState(() => _type = s.first),
              ),
              const SizedBox(height: 16),

              // Nickname
              TextFormField(
                controller: _labelController,
                decoration: InputDecoration(
                  labelText: l10n.connectionEditPfNickname,
                  hintText: l10n.connectionEditPfNicknameHint,
                ),
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),

              // Source port
              TextFormField(
                controller: _bindPortController,
                decoration: InputDecoration(
                  labelText: _isDynamic
                      ? l10n.connectionEditPfSocks5Port
                      : l10n.connectionEditPfSourcePort,
                  hintText: _isDynamic ? '1080' : '8080',
                ),
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return l10n.connectionEditRequired;
                  }
                  final port = int.tryParse(v);
                  if (port == null || port < 1 || port > 65535) {
                    return l10n.connectionEditPortRange1To65535;
                  }
                  return null;
                },
              ),

              if (!_isDynamic) ...[
                const SizedBox(height: 12),
                // Editor rule: the destination host is an address, masked
                // while recording mode is on; "Required" still checks the
                // real text.
                RecordingMaskedFormField(
                  controller: _remoteHostController,
                  mask: (raw) => Redactable.address(raw).display,
                  decoration: InputDecoration(
                    labelText: l10n.connectionEditPfDestHost,
                    hintText: 'localhost',
                  ),
                  validate: () => _remoteHostController.text.isEmpty
                      ? l10n.connectionEditRequired
                      : null,
                  child: TextFormField(
                    controller: _remoteHostController,
                    decoration: InputDecoration(
                      labelText: l10n.connectionEditPfDestHost,
                      hintText: 'localhost',
                    ),
                    validator: (v) => v == null || v.isEmpty
                        ? l10n.connectionEditRequired
                        : null,
                  ),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _remotePortController,
                  decoration: InputDecoration(
                    labelText: l10n.connectionEditPfDestPort,
                    hintText: '3306',
                  ),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  validator: (v) {
                    if (v == null || v.isEmpty) {
                      return l10n.connectionEditRequired;
                    }
                    final port = int.tryParse(v);
                    if (port == null || port < 1 || port > 65535) {
                      return l10n.connectionEditPortRange1To65535;
                    }
                    return null;
                  },
                ),
              ],

              const SizedBox(height: 8),

              SwitchListTile(
                title: Text(l10n.connectionEditPfAutoActivate),
                value: _autoStart,
                onChanged: (v) => setState(() => _autoStart = v),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryAction: (label: l10n.commonAdd, icon: null, onPressed: _submit),
    );
  }

  /// Adds the rule, from the main button or Enter, once the form is right.
  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final labelText = _labelController.text.trim();
    Navigator.pop(
      context,
      _PortForwardFormResult(
        id: const Uuid().v4(),
        type: _type,
        bindAddress: '127.0.0.1',
        bindPort: int.parse(_bindPortController.text),
        remoteHost: _isDynamic ? '*' : _remoteHostController.text.trim(),
        remotePort: _isDynamic ? 0 : int.parse(_remotePortController.text),
        autoStart: _autoStart,
        label: labelText.isEmpty ? null : labelText,
      ),
    );
  }
}

// ─── Environment variable entry ─────────────────────────────────

class _EnvVarEntry {
  final TextEditingController key;
  final TextEditingController value;

  _EnvVarEntry({required this.key, required this.value});
}

// ── Connect Via info ─────────────────────────────────────────────

/// What Connect Via does: a notice in the app's dialog (3.4), a phone's
/// sheet, with Got it in its footer (a sheet of its own before, its headings
/// in the accent).
void _showConnectViaInfo(BuildContext context) {
  showZestModal<void>(
    context: context,
    size: ZestModalSize.compact,
    child: Builder(
      builder: (ctx) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.info,
        icon: LucideIcons.gitFork,
        title: AppLocalizations.of(ctx)!.connectionEditConnectViaSheetTitle,
        body: const _ConnectViaInfoSheet(),
        primaryKey: const ValueKey('connect-via-info-done'),
        primaryAction: (label: AppLocalizations.of(ctx)!.desktopGotIt, icon: null, onPressed: () => Navigator.of(ctx).pop()),
      ),
    ),
  );
}

class _ConnectViaInfoSheet extends StatelessWidget {
  const _ConnectViaInfoSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // Headings in the text's colour: colour is for what a dialog means.
    final heading = TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary);
    return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // What it does
          Text(
            l10n.connectionEditConnectViaWhatTitle,
            style: heading,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.connectionEditConnectViaWhatBody,
            style: TextStyle(fontSize: 14, color: AppColors.onSurface, height: 1.5),
          ),
          const SizedBox(height: 14),

          // When to use
          Text(
            l10n.connectionEditConnectViaWhenTitle,
            style: heading,
          ),
          const SizedBox(height: 4),
          Text(
            l10n.connectionEditConnectViaWhenBody,
            style: TextStyle(fontSize: 14, color: AppColors.onSurface, height: 1.5),
          ),
          const SizedBox(height: 14),

          // Example
          Text(
            l10n.connectionEditConnectViaExampleTitle,
            style: heading,
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              l10n.connectionEditConnectViaExampleBody,
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
                color: AppColors.onSurface,
                height: 1.6,
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Tip
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.lightbulb, size: 16, color: AppColors.v3TextSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l10n.connectionEditConnectViaTip,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.onSurface.withValues(alpha: 0.8),
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ),
        ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Test connection split-button - reachability vs full auth
// ══════════════════════════════════════════════════════════════════

/// Two-button row: a "Test [reachability | full connection]" main
/// button and a small swap button next to it.  Tapping swap toggles
/// which test the main button runs; the choice sticks until the
/// dialog closes (no popup menu, no chevron - just an instant
/// toggle the user can keep flipping).
///
/// `expanded: true` lets the main button stretch to fill the parent
/// (used in the mobile bottom-bar layout where buttons are full-width).
class _TestConnectionButton extends StatefulWidget {
  const _TestConnectionButton({
    required this.isTesting,
    required this.onTestReachability,
    required this.onTestFullAuth,
    this.expanded = false,
  });

  final bool isTesting;
  final VoidCallback? onTestReachability;
  final VoidCallback? onTestFullAuth;
  final bool expanded;

  @override
  State<_TestConnectionButton> createState() => _TestConnectionButtonState();
}

class _TestConnectionButtonState extends State<_TestConnectionButton> {
  // Currently-armed test mode.  Local to this widget so the choice
  // resets whenever the parent rebuilds the form (e.g. dialog
  // re-open) - exactly the "remembers until they close/reopen the
  // menu" semantics the spec asked for.
  _TestKind _kind = _TestKind.reachability;

  void _swap() {
    setState(() {
      _kind = _kind == _TestKind.reachability
          ? _TestKind.fullAuth
          : _TestKind.reachability;
    });
  }

  void _runActive() {
    switch (_kind) {
      case _TestKind.reachability:
        widget.onTestReachability?.call();
      case _TestKind.fullAuth:
        widget.onTestFullAuth?.call();
    }
  }

  /// Below this width we collapse to the swap-toggle UI.  Above it
  /// we have room for two full buttons side-by-side.  ~360px fits
  /// "Test reachability" + a 12px gap + "Test full connection" with
  /// padding and the icons; below that, the labels would truncate
  /// unpleasantly.
  static const double _sideBySideThreshold = 360;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= _sideBySideThreshold) {
          return _buildSideBySide();
        }
        return _buildSwapToggle();
      },
    );
  }

  // ── Wide layout: two full buttons, no swap needed ───────────────

  Widget _buildSideBySide() {
    final l10n = AppLocalizations.of(context)!;
    final isReachability = _kind == _TestKind.reachability;
    return Row(
      mainAxisSize:
          widget.expanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Flexible(
          fit: widget.expanded ? FlexFit.tight : FlexFit.loose,
          child: _testButton(
            kind: _TestKind.reachability,
            icon: LucideIcons.radio,
            label: l10n.zestHostTestReachability,
            isActive: isReachability,
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          fit: widget.expanded ? FlexFit.tight : FlexFit.loose,
          child: _testButton(
            kind: _TestKind.fullAuth,
            icon: LucideIcons.lock,
            label: l10n.zestHostTestFull,
            isActive: !isReachability,
          ),
        ),
      ],
    );
  }

  /// Single test button used in side-by-side mode.  Highlights the
  /// most recently-clicked one with a slightly heavier border so
  /// the user has a visual record of what they last tested - a
  /// minor polish vs. just two plain buttons.
  Widget _testButton({
    required _TestKind kind,
    required IconData icon,
    required String label,
    required bool isActive,
  }) {
    final running = widget.isTesting && _kind == kind;
    final iconWidget = running
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(icon, size: 16);

    return OutlinedButton.icon(
      onPressed: widget.isTesting
          ? null
          : () {
              setState(() => _kind = kind);
              switch (kind) {
                case _TestKind.reachability:
                  widget.onTestReachability?.call();
                case _TestKind.fullAuth:
                  widget.onTestFullAuth?.call();
              }
            },
      icon: iconWidget,
      label: Text(
          running ? AppLocalizations.of(context)!.connectionEditTesting : label),
      // The theme's secondary button (its height and corners), the one last
      // run a little heavier at its edge.
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        side: BorderSide(
          color: AppColors.v3BorderDefault,
          width: isActive ? 1.5 : 1,
        ),
        foregroundColor: AppColors.v3TextSecondary,
      ),
    );
  }

  // ── Narrow layout: main button + inline swap toggle ─────────────

  Widget _buildSwapToggle() {
    final l10n = AppLocalizations.of(context)!;
    final isReachability = _kind == _TestKind.reachability;
    final mainIcon = widget.isTesting
        ? const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Icon(
            isReachability ? LucideIcons.radio : LucideIcons.lock,
            size: 16,
          );
    final mainLabel = widget.isTesting
        ? l10n.connectionEditTesting
        : (isReachability
            ? l10n.zestHostTestReachability
            : l10n.zestHostTestFull);

    return Row(
      mainAxisSize:
          widget.expanded ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Flexible(
          fit: widget.expanded ? FlexFit.tight : FlexFit.loose,
          child: OutlinedButton.icon(
            onPressed: widget.isTesting ? null : _runActive,
            icon: mainIcon,
            label: Text(mainLabel),
            // A secondary button of its own (it was fused to the swap
            // button, square at their seam).
            style: OutlinedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              side: BorderSide(color: AppColors.v3BorderDefault),
              foregroundColor: AppColors.v3TextSecondary,
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Which test the button runs: a button of its own, 44 square.
        IconButton.outlined(
          key: const ValueKey('host-form-test-swap'),
          tooltip: isReachability
              ? l10n.connectionEditSwitchToFull
              : l10n.connectionEditSwitchToReachability,
          onPressed: widget.isTesting ? null : _swap,
          icon: const Icon(LucideIcons.arrowLeftRight, size: 18),
          style: IconButton.styleFrom(
            minimumSize: const Size(44, 44),
            fixedSize: const Size(44, 44),
            // 44 is its target already: no wider margin round it, so it
            // stands 8 from the Test button as drawn.
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: EdgeInsets.zero,
            foregroundColor: AppColors.v3TextSecondary,
            side: BorderSide(color: AppColors.v3BorderDefault),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
      ],
    );
  }
}

enum _TestKind { reachability, fullAuth }

// _TestMenuItem (the popup-menu row) was removed when the
// reachability/full-auth dropdown was replaced by the inline swap
// toggle in [_TestConnectionButton].  Keeping the enum because the
// state machine still uses it.

// ═══════════════════════════════════════════════════════════════════════
// Host-editor local controls (choice pills, toggles, buttons). These consume
// the shared ZestTokens palette; the field/header/footer chrome now lives in
// the shared ZestField / ZestSectionHeader / ZestPaneFooter widgets.
// ═══════════════════════════════════════════════════════════════════════

/// `.choice-label` - the small 11px caption sitting above a choice row
/// or the colour swatches.
class _MChoiceLabel extends StatelessWidget {
  const _MChoiceLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      // A form's label, as every form names its fields.
      child: ZestFieldLabel(label),
    );
  }
}

/// `.choice` - one equal-width pill in a full-width choice row. Text only
/// (11px #c9c6bd on #1a1a1d, 0.5px #3a3a3f border, radius 7, padding 8/0);
/// ACTIVE = #0d0d0e text on brand fill, transparent border. Caller wraps each
/// in an [Expanded] so the row shares width equally.
class _MChoicePill extends StatelessWidget {
  const _MChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.focused = false,
    this.tabStop = true,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Reached with Tab and picked with Enter or Space, with the keyboard's
  /// ring. False for the protocol row alone: that group is one Tab stop of
  /// its own, moved through with the arrow keys, and draws [focused] itself.
  final bool tabStop;

  /// The protocol group has keyboard focus and this is the active pill: draw an
  /// orange focus ring around it (a 2px gap separates the ring from the filled
  /// pill so it reads even on the selected/orange one).
  final bool focused;

  @override
  Widget build(BuildContext context) {
    // Its name said once (the label and its words were both read: "SSH,
    // SSH").
    if (tabStop) {
      // No least size of its own: the row's pills keep the height they had.
      return ZestPressable(
        onTap: onTap,
        semanticLabel: label,
        selected: selected,
        inGroup: true,
        excludeChildSemantics: true,
        minSize: 0,
        borderRadius: _kChipRadius,
        child: _pill(),
      );
    }
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      label: label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: _pill(),
      ),
    );
  }

  Widget _pill() {
    return AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? ZestTokens.brand : ZestTokens.surfaceRaisedAlt,
            borderRadius: BorderRadius.circular(_kChipRadius),
            border: Border.all(
              color: focused
                  ? ZestTokens.brand
                  : (selected ? Colors.transparent : ZestTokens.borderStrong),
              width: focused ? 2 : 0.5,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      color: ZestTokens.brand.withValues(alpha: 0.45),
                      blurRadius: 6,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: selected ? ZestTokens.onBrand : ZestTokens.textSecondary,
            ),
          ),
    );
  }
}

/// `.toggle-row` - a 13px #c9c6bd label + a 32×18 pill switch, with an optional
/// `.note` (11px #78766f) below.
class _MToggleRow extends StatelessWidget {
  const _MToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.note,
    this.warnWhenOn = false,
  });

  final String label;
  final bool value;

  /// Null for a switch that cannot be changed here (a team's rule decides
  /// it): it is drawn dimmed, and a tap does nothing.
  final ValueChanged<bool>? onChanged;
  final String? note;

  /// Whether the [note] is in the warning colour while the switch is on:
  /// for a switch that makes connections less secure (Compatibility mode),
  /// so that what it allows stays in sight while it is on.
  final bool warnWhenOn;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // One control to a screen reader and to the keyboard (the 4.0
        // accessibility pass): its name, that it is a switch and whether it
        // is on, reached with Tab and flipped with Enter or Space, and a
        // finger's 48 down where the app is touch sized (it was 33). It was a
        // bare tap on some words: read as words, with no state, and out of
        // the keyboard's reach.
        ZestPressable(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          semanticLabel: label,
          toggled: value,
          button: false,
          excludeChildSemantics: true,
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: minTapTarget(context)),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Opacity(opacity: onChanged == null ? 0.45 : 1, child: _MSwitch(value: value)),
                ],
              ),
            ),
          ),
        ),
        if (note != null && note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 11),
            child: Text(
              note!,
              style: TextStyle(
                fontSize: 11,
                color: warnWhenOn && value ? ZestTokens.statusWarning : ZestTokens.textMuted,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// `.tg` - the 32×18 pill switch. Off: #3a3a3f track + #8d8b83 knob. On: brand
/// track + #0d0d0e knob.
class _MSwitch extends StatelessWidget {
  const _MSwitch({required this.value});
  final bool value;
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      width: 32,
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        // As the app's switch (ZestSwitch) draws itself.
        color: value ? ZestTokens.brand : ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: value ? ZestTokens.brand : ZestTokens.border),
      ),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: value ? Colors.white : ZestTokens.textTertiary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// `.banner` - the Terminal-tab "Override app defaults" strip: title 13px
/// #c9c6bd + sub 11px #78766f on #1c1c20, radius 8, with a trailing switch.
class _MBanner extends StatelessWidget {
  const _MBanner({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        // The theme's raised surface with a hairline (a fixed near-black
        // was a dark box on a light theme's page).
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
          border: Border.all(color: ZestTokens.borderSubtle),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: TextStyle(fontSize: 11, color: ZestTokens.textMuted)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            _MSwitch(value: value),
          ],
        ),
      ),
    );
  }
}

/// The host and port a host's editor saves from its Address and Port
/// fields: an address typed with its port ("host:2222",
/// "[2001:db8::1]:2222") gives both, and an IPv6 address loses its
/// brackets, as a connection is made to it (it was saved whole, a name no
/// lookup finds); else the address as typed, with the Port field's port.
({String host, int port}) savedAddress(String typed, int portField) {
  final split = splitHostPort(typed);
  return (host: split?.host ?? typed.trim(), port: split?.port ?? portField);
}

/// For Save in the host editor: the value to write for a field, given the
/// row as the editor read it ([loaded]) and as it is now ([now]). When the
/// row did not change meanwhile (or either is not known), what the form
/// holds. When it did (a sync wrote it), a field whose form value is still
/// the one the editor read takes the row's value now; a field the person
/// changed keeps theirs (found in a code audit).
T Function<T>(T form, T Function(Connection row) of) keptFromSync(Connection? loaded, Connection? now) {
  final moved = loaded != null && now != null && now.updatedAt != loaded.updatedAt;
  return <T>(T form, T Function(Connection row) of) => moved && form == of(loaded) ? of(now) : form;
}
