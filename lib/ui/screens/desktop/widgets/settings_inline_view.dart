import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/services/settings_service.dart' show LockSessionsShown;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/features/orchards/tab_sources.dart';
import 'package:zestssh/features/screens/model/screen_options.dart' show ScreenScaling;
import 'package:zestssh/features/screens/screen_settings.dart';
import 'package:zestssh/features/screens/view/screen_touch.dart' show ScreenTouchMode;
import 'package:zestssh/services/mosh/builtin_mosh_service.dart' show moshSystemClientOffered;
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/utils/help_links.dart' show kZestDiscordUrl, kZestPlansUrl;
import 'package:zestssh/features/cloud_import/ui/cloud_accounts_view.dart';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show UiDensity, setUiDensity, uiDensityProvider;
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:zestssh/features/password_managers/password_manager_providers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_settings.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/services/update_check_service.dart';
import 'package:zestssh/ui/screens/settings/reachability_checks_setting.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/widgets/update_check_now.dart';
import 'package:zestssh/utils/file_manager.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/idle_lock_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/idle_lock.dart';
import 'package:zestssh/features/changelog/whats_new_dialog.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/zest_theme.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/features/hosts/models/host_card_settings.dart';
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/terminal/terminal_dictation.dart' show voiceInputSupportedProvider;
import 'package:zestssh/features/shortcuts/widgets/keyboard_shortcuts_panel.dart';
import 'package:zestssh/providers/host_card_settings_provider.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_dock.dart';
import 'package:zestssh/ui/screens/desktop/widgets/app_theme_gallery.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardSummariesProvider;
import 'package:zestssh/features/workspaces/widgets/workspace_identity.dart' show WorkspaceDashedBox;
import 'package:zestssh/ui/screens/desktop/widgets/theme_designer_view.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/security/security_actions.dart';
import 'package:zestssh/ui/screens/settings/language_picker.dart';
import 'package:zestssh/ui/screens/settings/licenses_screen.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart';
import 'package:zestssh/ui/screens/purchase/pricing_modal.dart';
import 'package:zestssh/features/notifications/widgets/notification_toast_overlay.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/ui/widgets/beside_or_under.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/setting_help.dart' show SettingMoreButton;
import 'package:zestssh/utils/redactor.dart' show RedactLevel;
import 'package:zestssh/ui/widgets/ink_layer.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// Bumped to force the Terminal settings section to rebuild after a custom
/// terminal theme is deleted (the theme store is a static map, not a provider,
/// so nothing else notifies the view).
final _terminalThemesRevisionProvider = StateProvider<int>((ref) => 0);

// ── Section enum ──────────────────────────────────────────────────

/// The groups the pages of Settings stand in, under a small label each (4.0,
/// as designed). A phone's Settings has the same groups
/// (settings_screen.dart).
enum _SettingsGroup { account, app, connections, securityData, about }

/// The pages of Settings, in the order the list shows them. One page for
/// security (there were two: "Account and security" and "Security"), and
/// one for the keyboard and the mouse (there were two: Mouse and Keyboard
/// shortcuts).
enum _SettingsSection {
  // The account (3.0 UI): sign-in, keys, devices and sync.
  account(LucideIcons.user, _SettingsGroup.account),
  // The plan this account has, Redeem a code, and the plans.
  plan(LucideIcons.crown, _SettingsGroup.account),
  // Language, the window and startup, and nothing else.
  general(LucideIcons.settings, _SettingsGroup.app),
  // The app's theme and the host list's look.
  appearance(LucideIcons.palette, _SettingsGroup.app),
  // What the mouse does in a terminal, and the shortcuts.
  keyboard(LucideIcons.keyboard, _SettingsGroup.app),
  // The same toggles the bell's gear manages.
  notifications(LucideIcons.bell, _SettingsGroup.app),
  // The terminal (colours, font, cursor, behaviour, session logs) and the
  // defaults of a new connection.
  terminal(LucideIcons.terminalSquare, _SettingsGroup.connections),
  // The SFTP browser's rows.
  files(LucideIcons.folder, _SettingsGroup.connections),
  // Remote screens (4.0): the screen menu's key, a new screen's scaling, a
  // phone's pointer and what recording mode does to the picture.
  screens(LucideIcons.monitor, _SettingsGroup.connections),
  // The app lock, encryption at rest, host keys, dangerous commands and
  // recording mode.
  security(LucideIcons.shield, _SettingsGroup.securityData),
  // Export, import, backups, the cloud accounts kept in sync, and clearing
  // this device's data or settings.
  data(LucideIcons.archive, _SettingsGroup.securityData),
  about(LucideIcons.info, _SettingsGroup.about);

  const _SettingsSection(this.icon, this.group);

  final IconData icon;
  final _SettingsGroup group;
}

/// The name of a group of pages, over them in the list (About stands alone,
/// under a line, with no name over it).
String? _groupLabel(AppLocalizations l10n, _SettingsGroup group) => switch (group) {
      _SettingsGroup.account => l10n.settingsGroupAccount,
      _SettingsGroup.app => l10n.settingsGroupApp,
      _SettingsGroup.connections => l10n.settingsGroupConnections,
      _SettingsGroup.securityData => l10n.settingsGroupSecurityData,
      _SettingsGroup.about => null,
    };

/// A page's name, as the list, its title and the search's headings say it.
String _sectionLabel(AppLocalizations l10n, _SettingsSection section) => switch (section) {
      _SettingsSection.account => l10n.settingsAccount,
      _SettingsSection.plan => l10n.settingsPagePlan,
      _SettingsSection.general => l10n.settingsInlineSectionGeneral,
      _SettingsSection.appearance => l10n.settingsInlineSectionAppearance,
      _SettingsSection.keyboard => l10n.settingsPageKeyboardMouse,
      _SettingsSection.notifications => l10n.settingsNotifications,
      _SettingsSection.terminal => l10n.settingsPageTerminalSsh,
      _SettingsSection.files => l10n.settingsPageFiles,
      _SettingsSection.screens => l10n.settingsScreensSection,
      _SettingsSection.security => l10n.settingsPageSecurityPrivacy,
      _SettingsSection.data => l10n.settingsPageBackupsData,
      _SettingsSection.about => l10n.settingsInlineSectionAbout,
    };

/// Where each page of an earlier version is now, for the page kept on this
/// device (Settings opens where it was last): the two pages merged into
/// another are found in it.
const Map<String, _SettingsSection> _kMovedSections = {
  'shortcuts': _SettingsSection.keyboard,
};

// ── Settings, a pop-up over the app (3.0 UI) ─────────────
//
// Settings used to be a page of the shell: opening it left the terminal, and
// its rows stood in a narrow column beside a lot of empty window. It is a
// pop-up now, over whatever is shown: the sections with a search field on
// the left, the chosen section's rows on the right, and the sub-editors
// (theme designer, sync storage) inside that pane with a way back.

/// Where the section the pop-up was last on is kept on this device.
const String kSettingsLastSectionKey = 'settings_last_section';

/// The section the pop-up was last on, so that it opens there again, also
/// after the app was closed: it starts from what this device kept (the view
/// keeps each section it shows, see _remember). A name this version does not
/// know (a section of another version, a damaged value) is General; a page
/// merged into another (Keyboard shortcuts) is the one it is in now.
final _lastSettingsSectionProvider = StateProvider<_SettingsSection>((ref) {
  final kept = ref.read(sharedPreferencesProvider).getString(kSettingsLastSectionKey);
  return _SettingsSection.values
          .where((s) => s.name == kept && (s != _SettingsSection.plan || zestHasPlans))
          .firstOrNull ??
      _kMovedSections[kept] ??
      _SettingsSection.general;
});

/// How wide and how high the pop-up is where the window has the room.
// 30% larger than it was (980 by 700), so a page's rows and its sub-editors
// have room; still never
// larger than the window.
const double _kSettingsPopupWidth = 1274;
const double _kSettingsPopupHeight = 910;

/// The width of the pop-up's list of sections.
const double _kSettingsNavWidth = 232;

/// Shows Settings over whatever the app shows. Closing it (the cross, Escape,
/// a click beside it) asks first where a sub-editor has unsaved changes.
Future<void> showSettingsPopup(BuildContext context) {
  return showDialog<void>(
    context: context,
    useSafeArea: false,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    // A click beside the pop-up closes it through the pop-up's own guard.
    builder: (_) => const _SettingsPopupFrame(),
  );
}

/// The pop-up's frame: centred, as large as [_kSettingsPopupWidth] by
/// [_kSettingsPopupHeight] and never larger than the window, with a place
/// of its own for the app's notices and for an undo bar, which would
/// otherwise be drawn under the dimmed app behind it.
class _SettingsPopupFrame extends StatelessWidget {
  const _SettingsPopupFrame();

  @override
  Widget build(BuildContext context) {
    return NotificationToastOverlay(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              maxWidth: _kSettingsPopupWidth,
              maxHeight: _kSettingsPopupHeight,
            ),
            child: Material(
              color: AppColors.v3Background,
              clipBehavior: Clip.antiAlias,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: AppColors.v3BorderSubtle),
              ),
              child: const ScaffoldMessenger(
                child: Scaffold(
                  backgroundColor: Colors.transparent,
                  body: SettingsInlineView(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The scrollback a computer's Settings offers, in lines.
const List<int> kScrollbackChoices = [1000, 2000, 5000, 10000, 20000, 50000];

/// What the scrollback menu lists for [current]: its choices, and [current]
/// itself where it is none of them (a phone sets any number, 0 for
/// unlimited), smallest first and unlimited last.
List<int> scrollbackMenuValues(int current) {
  int size(int n) => n <= 0 ? 1 << 62 : n;
  return {...kScrollbackChoices, current}.toList()..sort((a, b) => size(a).compareTo(size(b)));
}

class SettingsInlineView extends ConsumerStatefulWidget {
  const SettingsInlineView({super.key});

  @override
  ConsumerState<SettingsInlineView> createState() =>
      _SettingsInlineViewState();
}

class _SettingsInlineViewState extends ConsumerState<SettingsInlineView> {
  /// The section whose rows the right-hand pane shows.
  late _SettingsSection _section;
  final ScrollController _scrollController = ScrollController();
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  /// S7: per-setting-row [GlobalKey]s (lazily created, keyed by
  /// `"${section}/${label}"`) so a search result can scroll to and briefly
  /// highlight the exact setting row, not just the section heading.
  final Map<String, GlobalKey> _settingRowKeys = {};
  GlobalKey _rowKey(String id) =>
      _settingRowKeys.putIfAbsent(id, () => GlobalKey());

  /// The setting id currently flashing its highlight, or null. Watched by
  /// every [_SettingRow] via the section search scope.
  final ValueNotifier<String?> _highlightedSetting =
      ValueNotifier<String?>(null);

  /// Generation token so an older highlight-clear timer can't wipe a fresher
  /// flash triggered by a subsequent search selection.
  int _highlightGeneration = 0;

  /// A [GlobalKey] for each section so the TOC can scroll to it and the
  /// scroll listener can determine which section is currently in view.
  final Map<_SettingsSection, GlobalKey> _sectionKeys = {
    for (final section in _SettingsSection.values) section: GlobalKey(),
  };

  /// Generation token for scroll-to-section requests. Incremented on
  /// every click; pending postFrameCallbacks + animation .then handlers
  /// compare their captured generation against the current value and
  /// bail if a newer click has superseded them.
  ///
  /// Fixes the race where rapid sidebar clicks would land out of order:
  /// the first animateTo's `.then` would set [_isScrollingToSection]
  /// false while the second was still running, letting [_onScroll]
  /// pick a wrong active section mid-animation.
  int _scrollGeneration = 0;

  /// Notifier for the docked-sub-editor state, captured in [initState] so it
  /// can be reset from [dispose] (where `ref.read` is unreliable once the
  /// element is deactivated - same convention as the SFTP panes).
  late final StateController<SettingsDock> _dockController;

  /// Memoised docked-editor panels. Cached so a rebuild of this view (e.g. the
  /// section-search field's setState) does NOT throw away the editor's
  /// in-progress state. Cleared whenever the dock closes so re-opening starts
  /// fresh.
  Widget? _appThemeDesignerPanel;
  Widget? _customThemePanel;
  Widget? _syncBackendPanel;

  /// Created once so the docked sync-storage panel's ✕ can drive the screen's
  /// dirty-guarded close across the file boundary (its State is private).
  late final SyncBackendCloseController _syncBackendCloseController;

  /// The search field of the list of sections ("/" puts the cursor in it).
  final FocusNode _searchFocus = FocusNode(debugLabel: 'settings search');

  /// Captured in [initState] for the same reason as [_dockController].
  late final StateController<_SettingsSection> _lastSectionController;

  @override
  void initState() {
    super.initState();
    _lastSectionController = ref.read(_lastSettingsSectionProvider.notifier);
    _section = _lastSectionController.state;
    _dockController = ref.read(settingsDockProvider.notifier);
    // Shared singleton so the theme-editor buttons (separate widgets) can run
    // the sync-backend dirty guard before replacing a dirty docked panel.
    _syncBackendCloseController = ref.read(syncBackendCloseControllerProvider);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchFocus.dispose();
    _highlightedSetting.dispose();
    // Clear any docked sub-editor so it can't linger when Settings is
    // reopened. Deferred to a microtask: dispose can run while the tree is
    // locked, and mutating a provider then would throw.
    final dockController = _dockController;
    Future.microtask(() {
      // Gone with the whole app (its providers disposed first): nothing to
      // clear, and touching it would throw.
      if (!dockController.mounted) return;
      if (dockController.state != SettingsDock.none) {
        dockController.state = SettingsDock.none;
      }
    });
    super.dispose();
  }

  /// Land on the section a Help-menu deep link asked for (spec 7b): clear the
  /// one-shot request and scroll once the frame has laid out.
  void _consumeJump(SettingsJumpTarget target) {
    final section = switch (target) {
      SettingsJumpTarget.keyboard => _SettingsSection.keyboard,
      SettingsJumpTarget.privacy => _SettingsSection.security,
      SettingsJumpTarget.security => _SettingsSection.security,
      SettingsJumpTarget.notifications => _SettingsSection.notifications,
      SettingsJumpTarget.account => _SettingsSection.account,
      SettingsJumpTarget.appearance => _SettingsSection.appearance,
      SettingsJumpTarget.plan => _SettingsSection.plan,
      SettingsJumpTarget.terminal => _SettingsSection.terminal,
      SettingsJumpTarget.files => _SettingsSection.files,
      SettingsJumpTarget.data => _SettingsSection.data,
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(settingsJumpProvider.notifier).state = null;
      _goToSection(section);
    });
  }

  /// Close the docked editor and drop the cached panels so the next open is a
  /// clean instance.
  void _closeDock() {
    _appThemeDesignerPanel = null;
    _customThemePanel = null;
    _syncBackendPanel = null;
    ref.read(settingsDockProvider.notifier).state = SettingsDock.none;
  }

  /// Build (or return the cached) docked editor panel for [dock].
  Widget _dockedEditorFor(SettingsDock dock) {
    final l10n = AppLocalizations.of(context)!;
    switch (dock) {
      case SettingsDock.appThemeDesigner:
        return _appThemeDesignerPanel ??= _DockedEditorPanel(
          title: l10n.settingsThemeDesignerDockTitle,
          onClose: _closeDock,
          child: ThemeDesignerView(initialTab: 0, onClose: _closeDock),
        );
      case SettingsDock.customThemeBuilder:
        // Reuses the tabbed Theme Designer, opened on its Terminal tab (the
        // ANSI palette editor is embedded there). One designer, two tabs.
        return _customThemePanel ??= _DockedEditorPanel(
          title: l10n.settingsThemeDesignerDockTitle,
          onClose: _closeDock,
          child: ThemeDesignerView(initialTab: 1, onClose: _closeDock),
        );
      case SettingsDock.syncBackend:
        return _syncBackendPanel ??= _DockedEditorPanel(
          title: l10n.settingsSyncBackendDockTitle,
          // The header ✕ must run the dirty guard, so route it through the
          // controller's requestClose (which prompts on unsaved changes) -
          // NOT _closeDock, which would drop half-entered store credentials.
          onClose: () => _syncBackendCloseController.requestClose(),
          child: SyncBackendScreen(
            // Fired only after a save or a confirmed discard.
            onClose: _closeDock,
            closeController: _syncBackendCloseController,
          ),
        );
      case SettingsDock.none:
        return const SizedBox.shrink();
    }
  }

  /// Notes [section] as the one Settings is on, for the next time it opens:
  /// while the app runs, and on this device for after it was closed.
  void _remember(_SettingsSection section) {
    _lastSectionController.state = section;
    // ignore: discarded_futures
    ref.read(sharedPreferencesProvider).setString(kSettingsLastSectionKey, section.name);
  }

  // ── Go to section ───────────────────────────────────────────────

  /// Shows [section] from its top, with no search in the way, and remembers
  /// it for the next time Settings opens. A sub-editor that is open is left
  /// behind through its own guard: one with unsaved changes asks first, and
  /// the section stays as it is when its person stays.
  Future<void> _goToSection(_SettingsSection section) async {
    if (!await _leaveDock()) return;
    if (!mounted) return;
    ++_scrollGeneration;
    setState(() {
      _section = section;
      _searchController.clear();
      _searchQuery = '';
    });
    _remember(section);
    if (_scrollController.hasClients) _scrollController.jumpTo(0);
  }

  /// Closes the sub-editor that is open, if one is. False where it has
  /// unsaved changes and its person chose to stay with them.
  Future<bool> _leaveDock() async {
    final dock = ref.read(settingsDockProvider);
    if (dock == SettingsDock.none) return true;
    if (dock == SettingsDock.syncBackend &&
        _syncBackendCloseController.isDirty) {
      // Asks, and closes the dock itself after a save or a discard.
      await _syncBackendCloseController.requestClose();
      if (!mounted) return false;
      return ref.read(settingsDockProvider) == SettingsDock.none;
    }
    _closeDock();
    return true;
  }

  /// Closes Settings: the cross, Escape and a click beside the pop-up all
  /// come here. A sub-editor with unsaved changes asks first.
  Future<void> _closePopup() async {
    if (!await _leaveDock()) return;
    if (!mounted) return;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// Animate the content view so the widget behind [key] is revealed near the
  /// top. When [highlightId] is non-null the matching row flashes once the
  /// scroll settles (used by search-result selection, S7).
  void _runScrollToKey(GlobalKey? key, int myGen, {String? highlightId}) {
    // Bail if a newer click has superseded us.
    if (myGen != _scrollGeneration || !mounted) {
      _releaseScrollFlagIfLatest(myGen);
      return;
    }

    final ctx = key?.currentContext;
    if (ctx == null || !_scrollController.hasClients) {
      _releaseScrollFlagIfLatest(myGen);
      // The target row isn't currently mounted (e.g. a conditionally-rendered
      // setting). Still flash so the intent isn't silently lost if it appears.
      if (highlightId != null) _flashHighlight(highlightId);
      return;
    }
    final box = ctx.findRenderObject();
    if (box is! RenderBox) {
      _releaseScrollFlagIfLatest(myGen);
      return;
    }
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) {
      _releaseScrollFlagIfLatest(myGen);
      return;
    }

    final pos = _scrollController.position;
    // Give a setting row a little breathing room from the very top so the
    // highlight reads as "here", not glued under the pane edge.
    final margin = highlightId != null ? 96.0 : 0.0;
    final reveal = viewport.getOffsetToReveal(box, 0.0).offset - margin;
    final target = reveal.clamp(pos.minScrollExtent, pos.maxScrollExtent);

    // Skip the animation if we're already there (within 1px) so
    // re-selecting the active item doesn't visibly twitch.
    if ((target - pos.pixels).abs() < 1) {
      _releaseScrollFlagIfLatest(myGen);
      if (highlightId != null) _flashHighlight(highlightId);
      return;
    }

    _scrollController
        .animateTo(
          target,
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeInOut,
        )
        .then((_) {
      _releaseScrollFlagIfLatest(myGen);
      if (highlightId != null) _flashHighlight(highlightId);
    });
  }

  /// Jump to and briefly highlight a specific setting row (search result):
  /// close the search, show the row's section, then scroll to the row and
  /// flash it.
  Future<void> _scrollToSetting(_SettingSearchEntry entry) async {
    if (!await _leaveDock()) return;
    if (!mounted) return;
    final myGen = ++_scrollGeneration;
    setState(() {
      _searchController.clear();
      _searchQuery = '';
      _section = entry.section;
    });
    _remember(entry.section);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // The account page's rows (on Account, Plan, and Backups and data) are
      // its own, not _SettingRows: found by the name they show.
      if (entry.byName && _rowKey(entry.id).currentContext == null) {
        _revealByName(entry.title);
        return;
      }
      _runScrollToKey(_rowKey(entry.id), myGen, highlightId: entry.id);
    });
  }

  /// Brings the first text on the open page that reads [name] into view, a
  /// little below the top (a row that is not a _SettingRow).
  void _revealByName(String name) {
    Element? found;
    void visit(Element e) {
      if (found != null) return;
      final w = e.widget;
      if (w is Text && w.data == name) {
        found = e;
        return;
      }
      e.visitChildren(visit);
    }

    if (!mounted) return;
    (context as Element).visitChildren(visit);
    final target = found;
    if (target == null) return;
    Scrollable.ensureVisible(target,
        alignment: 0.15, duration: const Duration(milliseconds: 280), curve: Curves.easeInOut);
  }

  /// Flash the highlight on [id] for a short beat, then clear it. Generation-
  /// guarded so a later flash isn't cut short by an earlier timer.
  void _flashHighlight(String id) {
    final gen = ++_highlightGeneration;
    _highlightedSetting.value = id;
    Future.delayed(const Duration(milliseconds: 1700), () {
      if (mounted && gen == _highlightGeneration) {
        _highlightedSetting.value = null;
      }
    });
  }

  /// Retained as a harmless hook so the scroll callbacks read cleanly. The
  /// old scroll-spy guard it managed was removed with the one-section layout;
  /// the generation token ([_scrollGeneration]) still guards stale callbacks.
  void _releaseScrollFlagIfLatest(int myGen) {}

  // ── Undo toast helper ────────────────────────────────────────────

  void _showUndoToast(String message, VoidCallback onUndo) {
    final l10n = AppLocalizations.of(context)!;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(message),
          behavior: SnackBarBehavior.floating,
          width: 360,
          duration: const Duration(seconds: 4),
          action: SnackBarAction(
            label: l10n.settingsInlineUndo,
            textColor: AppColors.v3AccentInk,
            onPressed: onUndo,
          ),
        ),
      );
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // A deep link (the Help menu's "Keyboard shortcuts", the bell's gear, the
    // account button) lands on its section. One-shot: consumed (cleared after
    // the frame, never during build). The read covers a request made before
    // this view mounted; the listen covers one made while it is showing.
    final pendingJump = ref.read(settingsJumpProvider);
    if (pendingJump != null) _consumeJump(pendingJump);
    ref.listen<SettingsJumpTarget?>(settingsJumpProvider, (_, next) {
      if (next != null) _consumeJump(next);
    });
    // Drop the cached editor panels the moment the dock closes so the next
    // open is a fresh editor rather than a stale one.
    ref.listen<SettingsDock>(settingsDockProvider, (prev, next) {
      if (next == SettingsDock.none) {
        _appThemeDesignerPanel = null;
        _customThemePanel = null;
        _syncBackendPanel = null;
      }
    });

    final dock = ref.watch(settingsDockProvider);
    final l10n = AppLocalizations.of(context)!;

    // The list of sections and the pane are separate traversal units, so Tab
    // inside a settings field never lands on a section in the same band.
    final nav = FocusTraversalGroup(
      child: _SettingsNav(
        selected: _section,
        // While a search shows its results no section is the one on screen.
        searching: _searchQuery.trim().length >= 2,
        searchController: _searchController,
        searchFocus: _searchFocus,
        searchQuery: _searchQuery,
        onSearchChanged: (q) => setState(() => _searchQuery = q),
        onSelect: _goToSection,
      ),
    );

    final pane = FocusTraversalGroup(
      child: dock != SettingsDock.none
          // A sub-editor takes the whole pane, with a way back in its header.
          ? _dockedEditorFor(dock)
          : _ContentArea(
              section: _section,
              searchQuery: _searchQuery,
              onSelectSetting: _scrollToSetting,
              scrollController: _scrollController,
              sectionKeys: _sectionKeys,
              showUndoToast: _showUndoToast,
              rowKey: _rowKey,
              highlightedSetting: _highlightedSetting,
            ),
    );

    return PopScope(
      // Every way out goes through the guard of a sub-editor's unsaved changes.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _closePopup();
      },
      // A scope of its own, so that the keys below are the pop-up's whatever
      // in it has the keyboard, and also when nothing in it has (the control
      // that had it went with its section).
      child: FocusScope(
        autofocus: true,
        // Escape ends a search that is going on, and otherwise closes
        // Settings, through the same guard as the cross. "/" puts the cursor
        // in the search field, but not while a text field has the keyboard:
        // the key is a character to type there.
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;
          if (event.logicalKey == LogicalKeyboardKey.escape) {
            if (_searchQuery.isNotEmpty) {
              setState(() {
                _searchController.clear();
                _searchQuery = '';
              });
            } else {
              _closePopup();
            }
            return KeyEventResult.handled;
          }
          if (event.logicalKey != LogicalKeyboardKey.slash) {
            return KeyEventResult.ignored;
          }
          // (A text field's focus node sits in a Focus inside its
          // EditableText, so the field is looked for above the node.)
          final focused = FocusManager.instance.primaryFocus?.context;
          if (focused?.findAncestorWidgetOfExactType<EditableText>() != null) {
            return KeyEventResult.ignored;
          }
          _searchFocus.requestFocus();
          return KeyEventResult.handled;
        },
        child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(width: _kSettingsNavWidth, child: nav),
                  VerticalDivider(width: 1, thickness: 1, color: AppColors.v3BorderSubtle),
                  Expanded(child: pane),
                ],
              ),
              Positioned(
                top: 8,
                right: 8,
                child: IconButton(
                  key: const ValueKey('settings-popup-close'),
                  icon: Icon(LucideIcons.x, size: 20, color: AppColors.v3TextSecondary),
                  tooltip: l10n.close,
                  onPressed: _closePopup,
                ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What the list of pages says beside Plan: the plan this account has
/// (Squeezed, Juiced, the Bundle or Free), as the rail's chip says it; the
/// Plan page it opens explains it. Nothing for a team's member, who is not
/// shown the plans' names.
String? _planTag(WidgetRef ref, AppLocalizations l10n) {
  if ((ref.watch(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty) return null;
  final plan = ref.watch(accountPlanProvider);
  return plan == AccountPlan.teamSeat ? null : plan.nameIn(l10n);
}

/// The pop-up's left side: its title, the search field, and the pages under
/// the names of their groups.
class _SettingsNav extends ConsumerWidget {
  const _SettingsNav({
    required this.selected,
    required this.searching,
    required this.searchController,
    required this.searchFocus,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onSelect,
  });

  final _SettingsSection selected;
  final bool searching;
  final TextEditingController searchController;
  final FocusNode searchFocus;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final ValueChanged<_SettingsSection> onSelect;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final planTag = _planTag(ref, l10n);
    final items = <Widget>[];
    _SettingsGroup? group;
    for (final s in _SettingsSection.values) {
      // (No Plan page in a build with no plans to buy.)
      if (s == _SettingsSection.plan && !zestHasPlans) continue;
      if (s.group != group) {
        group = s.group;
        final name = _groupLabel(l10n, s.group);
        items.add(name == null
            // About, apart under a line.
            ? Padding(
                padding: const EdgeInsets.fromLTRB(10, 12, 10, 8),
                child: Divider(height: 1, thickness: 1, color: AppColors.v3BorderSubtle),
              )
            : _SettingsGroupLabel(key: ValueKey('settings-group-${s.group.name}'), label: name));
      }
      items.add(_SettingsNavItem(
        key: ValueKey('settings-nav-${s.name}'),
        icon: s.icon,
        label: _sectionLabel(l10n, s),
        trailing: s == _SettingsSection.plan ? planTag : null,
        selected: !searching && s == selected,
        onTap: () => onSelect(s),
      ));
    }
    return ColoredBox(
      color: AppColors.v3Surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 14),
            child: Text(
              l10n.settingsTitle,
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                fontFamily: 'GeistSans',
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: _searchField(l10n),
          ),
          // Every page built, also where the window is low and the list
          // scrolls (a short list: no need to build it lazily).
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: items),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(AppLocalizations l10n) {
    return SizedBox(
      height: 34,
      child: TextField(
        key: const ValueKey('settings-search'),
        controller: searchController,
        focusNode: searchFocus,
        onChanged: onSearchChanged,
        style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 13),
        decoration: InputDecoration(
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          hintText: l10n.settingsSearchHint,
          hintStyle: TextStyle(color: AppColors.v3TextSecondary.withValues(alpha: 0.6), fontSize: 13),
          prefixIcon: Icon(LucideIcons.search, size: 16, color: AppColors.v3TextSecondary),
          prefixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 0),
          suffixIcon: searchQuery.isNotEmpty
              ? IconButton(
                  icon: Icon(LucideIcons.x, size: 15, color: AppColors.v3TextSecondary),
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 30, minHeight: 0),
                  tooltip: l10n.settingsInlineClear,
                  onPressed: () {
                    searchController.clear();
                    onSearchChanged('');
                  },
                )
              : null,
          suffixIconConstraints: const BoxConstraints(minWidth: 30, minHeight: 0),
          filled: true,
          fillColor: AppColors.v3Background,
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppColors.v3BorderSubtle)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppColors.v3BorderSubtle)),
          focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: AppColors.v3AccentPrimary)),
        ),
      ),
    );
  }
}

/// The name of a group of pages in the list: small capitals, a heading to a
/// screen reader.
class _SettingsGroupLabel extends StatelessWidget {
  const _SettingsGroupLabel({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 14, 10, 6),
      child: Semantics(
        header: true,
        child: Text(
          label.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: AppColors.v3TextTertiary,
            fontSize: 10.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.9,
          ),
        ),
      ),
    );
  }
}

/// One page in the pop-up's list: its icon and name (and, for Plan, the plan
/// this account has), marked while its rows are the ones on screen: in the
/// accent, bold, and said selected (never by colour alone).
class _SettingsNavItem extends StatelessWidget {
  const _SettingsNavItem({
    super.key,
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// Quiet words at the right end (Plan's plan).
  final String? trailing;

  @override
  Widget build(BuildContext context) {
    final colour = selected ? AppColors.v3AccentInk : AppColors.v3TextPrimary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Semantics(
        button: true,
        selected: selected,
        child: Material(
          color: selected ? AppColors.v3AccentPrimary.withValues(alpha: 0.10) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
          child: InkWell(
            borderRadius: BorderRadius.circular(6),
            hoverColor: AppColors.v3Hover,
            onTap: onTap,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
                child: Row(
                  children: [
                    Icon(icon, size: 16, color: selected ? AppColors.v3AccentInk : AppColors.v3TextTertiary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colour,
                          fontSize: 13.5,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                    ),
                    if (trailing != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        trailing!,
                        key: const ValueKey('settings-nav-plan-tag'),
                        maxLines: 1,
                        style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 12),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Docked editor panel - hosts a heavy sub-editor in the right pane
// ══════════════════════════════════════════════════════════════════

/// The chrome around a sub-editor shown in the pop-up's pane: a header (a way
/// back to the section, then the title) over the editor's body. The pop-up's
/// own cross stands at the header's right end, which is left free for it.
class _DockedEditorPanel extends StatelessWidget {
  const _DockedEditorPanel({
    required this.title,
    required this.onClose,
    required this.child,
  });

  final String title;
  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(color: AppColors.v3Background),
      child: InkLayer(
        child: Column(
        children: [
          // ── Header bar ──────────────────────────────────────────
          Container(
            height: 48,
            padding: const EdgeInsets.fromLTRB(8, 0, 52, 0),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: AppColors.v3BorderSubtle),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('settings-dock-back'),
                  icon: Icon(
                    LucideIcons.arrowLeft,
                    size: 20,
                    color: AppColors.v3TextSecondary,
                  ),
                  tooltip: AppLocalizations.of(context)!.back,
                  onPressed: onClose,
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: AppColors.v3TextPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(child: child),
        ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Settings search index (S7)
// ══════════════════════════════════════════════════════════════════
//
// What the search of Settings can find: one entry for each row, with the row's
// own words (see _kSettingsSearchIndex). The row id is derived as
// `"${section}/${title}"`, the SAME scheme `_SettingRow` uses to register its
// GlobalKey, so selecting a result scrolls to and flashes that exact row.
class _SettingSearchEntry {
  const _SettingSearchEntry(this.section, this.title, [this.subtitle = '', this.byName = false]);

  final _SettingsSection section;
  final String title;
  final String subtitle;

  /// A row of the account page's own (not a _SettingRow): found by its name.
  final bool byName;

  /// Stable row id - must match `_SettingRow`'s `"${section}/${label}"`.
  String get id => '${section.name}/$title';
}

/// Where a row's words for the search come from: the strings the row shows.
class _SettingSearchSpec {
  const _SettingSearchSpec(this.section, this.title, [this.subtitle])
      : macOnly = false,
        byName = false,
        plans = false,
        computerOnly = false;

  /// A row a Mac's Settings has alone (Option as Meta): found on a Mac only.
  const _SettingSearchSpec.macOnly(this.section, this.title, [this.subtitle])
      : macOnly = true,
        byName = false,
        plans = false,
        computerOnly = false;

  /// A row about a computer's window (its close, the tray, its sessions
  /// restored at start): not in a tablet's Settings, which has no window
  /// of its own (4.0), so found on a computer only.
  const _SettingSearchSpec.computerOnly(this.section, this.title, [this.subtitle])
      : macOnly = false,
        byName = false,
        plans = false,
        computerOnly = true;

  /// A row about the plans themselves (Compare plans), which a team's member
  /// is not shown: found by those who are in no team.
  const _SettingSearchSpec.plans(this.section, this.title, [this.subtitle])
      : macOnly = false,
        byName = false,
        plans = true,
        computerOnly = false;

  /// A row of the account page's own (ProfileScreen, on Account, Plan, and
  /// Backups and data), not a _SettingRow: a result opens the page and brings
  /// the row with that name into view. It found nothing for "export"
  /// before.
  const _SettingSearchSpec.page(this.section, this.title, [this.subtitle])
      : macOnly = false,
        byName = true,
        plans = false,
        computerOnly = false;

  final _SettingsSection section;
  final String Function(AppLocalizations l) title;
  final String Function(AppLocalizations l)? subtitle;
  final bool macOnly;
  final bool byName;
  final bool plans;
  final bool computerOnly;

  /// The row in the language of [l].
  _SettingSearchEntry said(AppLocalizations l) => _SettingSearchEntry(section, title(l), subtitle?.call(l) ?? '', byName);
}

/// A search match plus WHERE the query matched (title, help text, and/or the
/// section name), so the result item can show why it matched.
class _SearchHit {
  const _SearchHit(this.entry, this.inTitle, this.inSubtitle, this.inSection);

  final _SettingSearchEntry entry;
  final bool inTitle;
  final bool inSubtitle;
  final bool inSection;
}

/// Bumped after a security action so the Security page re-reads state that
/// has no provider of its own (encrypt at rest, hardware binding).
final _securityRevisionProvider = StateProvider<int>((_) => 0);

/// The built-in Mosh client's row (4.0): on a Mac and Linux only, the
/// computers that may use a mosh program of their own instead
/// ([moshSystemClientOffered]); the search finds it there alone.
final _kMoshSearchSpec =
    _SettingSearchSpec.computerOnly(_SettingsSection.terminal, (l) => l.settingsMoshBuiltin, (l) => l.settingsMoshBuiltinDesc);

/// Every row of Settings, for the search: its section and its own words (the
/// strings the row itself shows), so the search speaks the app's language and
/// a result lands on its row in any of them. One line for each _SettingRow of
/// this file, which test/ui/settings_search_index_test.dart holds.
final List<_SettingSearchSpec> _kSettingsSearchIndex = [
  // Account (rows of the account page itself)
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountTwoStep, (l) => l.twoStepSectionOffDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.passkeysTitle, (l) => l.passkeysDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.authenticatorTitle, (l) => l.authenticatorOffDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountSignInWays, (l) => l.accountSignInWaysAny),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountYourKeys, (l) => l.accountKeysWordsDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.zestProfileNavDevices),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.devicesSignOutEverywhere, (l) => l.devicesSignOutEverywhereDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.zestProfileNavSync),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.zestProfileNavStorage, (l) => l.accountStorageHelp),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountRestore),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountSignOutThisDevice, (l) => l.accountSignOutDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.syncResetTitle, (l) => l.syncResetRowDesc),
  _SettingSearchSpec.page(_SettingsSection.account, (l) => l.accountDeleteAccount, (l) => l.accountDeleteAccountDesc),
  // Plan
  _SettingSearchSpec(_SettingsSection.plan, (l) => l.settingsPlanYours),
  _SettingSearchSpec.plans(_SettingsSection.plan, (l) => l.settingsPlanCompare, (l) => l.settingsPlanCompareDesc),
  _SettingSearchSpec.page(_SettingsSection.plan, (l) => l.settingsMobRedeemCode, (l) => l.settingsMobRedeemCodeDesc),
  // General
  _SettingSearchSpec(_SettingsSection.general, (l) => l.settingsLanguage, (l) => l.settingsLanguageSubtitle),
  _SettingSearchSpec.computerOnly(_SettingsSection.general, (l) => l.settingsInlineCloseToTray, (l) => l.settingsInlineCloseToTrayDesc),
  _SettingSearchSpec.computerOnly(_SettingsSection.general, (l) => l.settingsConfirmCloseWindow, (l) => l.settingsConfirmCloseWindowDesc),
  _SettingSearchSpec.computerOnly(_SettingsSection.general, (l) => l.settingsInlineAutoRestore, (l) => l.settingsInlineAutoRestoreDesc),
  // Appearance
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineFollowSystemTheme, (l) => l.settingsInlineFollowSystemThemeDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineAppTheme, (l) => l.settingsInlineAppThemeGalleryDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineCustomTheme, (l) => l.settingsInlineCustomAppThemesDescPro),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineMatchTerminalToApp, (l) => l.settingsInlineMatchTerminalToAppDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsControlSize, (l) => l.settingsControlSizeDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineDensity, (l) => l.settingsInlineDensityDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineColumns, (l) => l.settingsInlineColumnsDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineAccentRail, (l) => l.settingsInlineAccentRailDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineShowOsIcon),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineShowSubtitle, (l) => l.settingsInlineShowSubtitleDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineShowTags, (l) => l.settingsInlineShowTagsDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineShowStatusPill, (l) => l.settingsInlineShowStatusPillDesc),
  _SettingSearchSpec(_SettingsSection.appearance, (l) => l.settingsInlineHoverEditButton, (l) => l.settingsInlineHoverEditButtonDesc),
  // Keyboard and mouse
  _SettingSearchSpec(_SettingsSection.keyboard, (l) => l.settingsInlineRightClickPaste),
  _SettingSearchSpec(_SettingsSection.keyboard, (l) => l.settingsInlineMiddleClickPaste),
  _SettingSearchSpec.macOnly(_SettingsSection.keyboard, (l) => l.hwKeysOptionMeta, (l) => l.hwKeysOptionMetaDesc),
  // Notifications
  _SettingSearchSpec.computerOnly(_SettingsSection.notifications, (l) => l.notifPrefsSystemComputer, (l) => l.notifPrefsSystemComputerDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsMonitorAlerts, (l) => l.notifPrefsMonitorAlertsDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsConnectionLost, (l) => l.notifPrefsConnectionLostDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsServerHealthChecks, (l) => l.notifPrefsServerHealthChecksDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsTransferComplete, (l) => l.notifPrefsTransferCompleteDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsTransferFailed, (l) => l.notifPrefsTransferFailedDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsSecurityAlerts, (l) => l.notifPrefsSecurityAlertsDesc),
  _SettingSearchSpec(_SettingsSection.notifications, (l) => l.notifPrefsUpdateAvailable, (l) => l.notifPrefsUpdateAvailableDesc),
  // Terminal and SSH
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineDefaultSshPort),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineDefaultUsername),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineConnectionTimeout),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsHealthChecks, (l) => l.settingsHealthChecksHelp),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineCheckInterval),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineTerminalColours, (l) => l.settingsInlineTerminalColoursDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineCustomTerminalThemes),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineFontFamily, (l) => l.settingsTerminalFontNerdIcons),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineFontSize),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsMobProgrammingLigatures, (l) => l.settingsMobProgrammingLigaturesDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineCursorStyle),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineCursorBlink),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsCursorVisibility, (l) => l.settingsCursorVisibilityDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineScrollbackBuffer, (l) => l.settingsInlineScrollbackBufferDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineTerminalBell),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineCopyOnSelect, (l) => l.settingsInlineCopyOnSelectDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsKeepAwake, (l) => l.settingsKeepAwakeDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsOsc52Clipboard, (l) => l.settingsOsc52ClipboardDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineAutoReconnect, (l) => l.settingsInlineAutoReconnectDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsTabSource, (l) => l.settingsTabSourceDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsTabSourceVault, (l) => l.settingsTabSourceVaultDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsTabSourceGroup, (l) => l.settingsTabSourceGroupDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsTmuxAutoDetect, (l) => l.settingsTmuxAutoDetectDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsInlineSshKeepaliveInterval, (l) => l.settingsKeepaliveDesc),
  _kMoshSearchSpec,
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsSessionLogEnabled, (l) => l.settingsSessionLogEnabledDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsSessionLogFolder),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.settingsSessionLogTimestamps, (l) => l.settingsSessionLogTimestampsDesc),
  _SettingSearchSpec(_SettingsSection.terminal, (l) => l.transcriptsTitle, (l) => l.transcriptsSettingsDesc),
  // Files
  _SettingSearchSpec(_SettingsSection.files, (l) => l.settingsSftpTimeFormat, (l) => l.settingsSftpTimeFormatDesc),
  _SettingSearchSpec(_SettingsSection.files, (l) => l.settingsMobHiddenFilesInBrowser, (l) => l.settingsMobHiddenFilesInBrowserDesc),
  _SettingSearchSpec(_SettingsSection.files, (l) => l.settingsDeleteHoldLabel, (l) => l.settingsDeleteHoldSubtitle),
  // Remote screens
  _SettingSearchSpec(_SettingsSection.screens, (l) => l.settingsScreenMenuKey, (l) => l.settingsScreenMenuKeyDesc),
  _SettingSearchSpec(_SettingsSection.screens, (l) => l.settingsScreenScalingDefault, (l) => l.settingsScreenScalingDefaultDesc),
  _SettingSearchSpec(_SettingsSection.screens, (l) => l.settingsScreenTouchDefault, (l) => l.settingsScreenTouchDefaultDesc),
  _SettingSearchSpec(_SettingsSection.screens, (l) => l.settingsScreenRecording, (l) => l.settingsScreenRecordingDesc),
  _SettingSearchSpec(_SettingsSection.screens, (l) => l.settingsScreenClipboardDefault, (l) => l.settingsScreenClipboardDefaultDesc),
  // Security and privacy
  _SettingSearchSpec(_SettingsSection.security, (l) => l.settingsInlineAppLock),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetChangePin, (l) => l.secSetChangePinSubtitle),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.settingsInlineAutoLock, (l) => l.settingsInlineAutoLockDesc),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetIdleLock),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetLockWithComputer, (l) => l.secSetLockWithComputerDesc),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetLockShowSessions, (l) => l.secSetLockShowSessionsDesc),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetEncryptAtRest),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetHwEncryption),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.settingsInlineDangerousCommandProtection, (l) => l.settingsDangerousCommandDesc),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.settingsInlineUnknownHostKeys),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetTrustedHostKeys, (l) => l.secSetTrustedHostKeysSubtitle),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.secSetClearAllKeys, (l) => l.secSetClearAllKeysSubtitle),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.recModeName, (l) => l.recModeTooltipOff),
  _SettingSearchSpec(_SettingsSection.security, (l) => l.recModeLevelLabel, (l) => l.recModeLevelStrictDesc),
  // Backups and data (rows of the account page itself, and Reset all settings)
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.accountExport, (l) => l.accountExportDescAll),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.accountImport, (l) => l.accountImportDesc),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.settingsMobConnectionsAsSshConfig, (l) => l.settingsMobConnectionsAsSshConfigDesc),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.accountAutoBackups),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.accountClearCache, (l) => l.accountClearCacheHelp),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.cloudAccTitle),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.accountDeleteLocal, (l) => l.accountDeleteLocalHelp),
  _SettingSearchSpec.page(_SettingsSection.data, (l) => l.settingsInlineResetAllSettings, (l) => l.settingsResetAllHelp),
  // About: the switch of the check for updates, where its row is (a
  // computer that updates from the website).
  if (UpdateCheckService.manualCheckSupported) ...[
    _SettingSearchSpec(_SettingsSection.about, (l) => l.updateCheckAutomatic, (l) => l.updateCheckAutomaticDesc),
    _SettingSearchSpec(_SettingsSection.about, (l) => l.updateAutoInstall, (l) => l.updateAutoInstallDesc),
  ],
];

/// A single search result row in the nav rail (S7): the setting title over a
/// muted "in {Section}" line. Tapping scrolls to + flashes the row.
/// A small uppercase section header above a group of search results, so
/// results are grouped by the section they live in.
class _SearchGroupHeader extends StatelessWidget {
  const _SearchGroupHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    // The app's section header, as every section's.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: ZestSectionHeader(label: label),
    );
  }
}

/// Splits [text] into spans, accenting each case-insensitive occurrence of
/// [query], so a result shows exactly what matched. An empty query returns
/// the whole string in [base].
List<InlineSpan> _highlightMatch(
  String text,
  String query, {
  required Color base,
  required Color accent,
}) {
  if (query.isEmpty) {
    return [TextSpan(text: text, style: TextStyle(color: base))];
  }
  final lower = text.toLowerCase();
  final q = query.toLowerCase();
  final spans = <InlineSpan>[];
  var start = 0;
  var idx = lower.indexOf(q, start);
  while (idx != -1) {
    if (idx > start) {
      spans.add(TextSpan(
          text: text.substring(start, idx),
          style: TextStyle(color: base)));
    }
    spans.add(TextSpan(
      text: text.substring(idx, idx + q.length),
      style: TextStyle(color: accent, fontWeight: FontWeight.w700),
    ));
    start = idx + q.length;
    idx = lower.indexOf(q, start);
  }
  if (start < text.length) {
    spans.add(
        TextSpan(text: text.substring(start), style: TextStyle(color: base)));
  }
  return spans;
}

class _SearchResultItem extends StatefulWidget {
  const _SearchResultItem({
    required this.hit,
    required this.query,
    required this.section,
    required this.onTap,
  });

  final _SearchHit hit;
  final String query;

  /// Where the row is: its section's name.
  final String section;
  final VoidCallback onTap;

  @override
  State<_SearchResultItem> createState() => _SearchResultItemState();
}

class _SearchResultItemState extends State<_SearchResultItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final hit = widget.hit;
    final entry = hit.entry;

    // "Why matched": the help text as a second line, with the query accented
    // when the match was there. The group header above already names the
    // section, so a section-only match needs no extra note.
    final showSubtitle = entry.subtitle.isNotEmpty;

    // A row of at least 44: the setting's name, one line of what it does,
    // and where it is at its right, with hover and the keyboard's focus
    // (Tab to it, Enter opens it).
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: widget.onTap,
        onHover: (h) => setState(() => _hovered = h),
        borderRadius: BorderRadius.circular(8),
        hoverColor: AppColors.v3Surface,
        focusColor: AppColors.v3Surface,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Text.rich, not RichText: it takes the app's font,
                      // where a bare RichText is drawn in the system's.
                      Text.rich(
                        TextSpan(
                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                          children: _highlightMatch(
                            entry.title,
                            hit.inTitle ? widget.query : '',
                            base: AppColors.v3TextPrimary,
                            accent: AppColors.v3AccentInk,
                          ),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (showSubtitle) ...[
                        const SizedBox(height: 2),
                        Text.rich(
                          TextSpan(
                            style: const TextStyle(fontSize: 12, height: 1.3),
                            children: _highlightMatch(
                              entry.subtitle,
                              hit.inSubtitle ? widget.query : '',
                              base: AppColors.v3TextTertiary,
                              accent: AppColors.v3AccentInk,
                            ),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  widget.section,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12,
                    color: _hovered ? AppColors.v3TextSecondary : AppColors.v3TextTertiary,
                  ),
                ),
                const SizedBox(width: 4),
                Icon(LucideIcons.chevronRight, size: 14, color: AppColors.v3TextTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Content Area
// ══════════════════════════════════════════════════════════════════

/// Provides the current section + the shared row-key factory / highlight
/// listenable to every [_SettingRow] beneath it, so rows can register a scroll
/// target and flash on search selection (S7) without per-call-site wiring.
class _SettingsSearchScope extends InheritedWidget {
  const _SettingsSearchScope({
    required this.section,
    required this.rowKey,
    required this.highlighted,
    required super.child,
  });

  final _SettingsSection section;
  final GlobalKey Function(String id) rowKey;
  final ValueListenable<String?> highlighted;

  static _SettingsSearchScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_SettingsSearchScope>();

  @override
  bool updateShouldNotify(_SettingsSearchScope old) =>
      old.section != section; // rowKey + highlighted are stable identities
}

class _ContentArea extends ConsumerWidget {
  const _ContentArea({
    required this.section,
    required this.searchQuery,
    required this.onSelectSetting,
    required this.scrollController,
    required this.sectionKeys,
    required this.showUndoToast,
    required this.rowKey,
    required this.highlightedSetting,
  });

  /// The section whose rows are shown.
  final _SettingsSection section;
  final String searchQuery;
  final void Function(_SettingSearchEntry) onSelectSetting;
  final ScrollController scrollController;
  final Map<_SettingsSection, GlobalKey> sectionKeys;
  final void Function(String message, VoidCallback onUndo) showUndoToast;
  final GlobalKey Function(String id) rowKey;
  final ValueListenable<String?> highlightedSetting;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final lowerQuery = searchQuery.trim().toLowerCase();
    if (lowerQuery.length >= 2) return _searchResults(context, ref, l10n, lowerQuery);
    return _shell(child: _sectionBlock(context, ref, l10n, section));
  }

  /// The scrollable content shell: the pane's width, capped so that on a
  /// wide pane a _SettingRow's label and control stay within easy reading
  /// distance (780 for the rows, as the mockup draws them). The right padding
  /// keeps the rows clear of the pop-up's cross.
  Widget _shell({required Widget child}) {
    return ZestScrollFade(
      child: Scrollbar(
      controller: scrollController,
      child: SingleChildScrollView(
        controller: scrollController,
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 860),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 18, 48, 40),
              child: child,
            ),
          ),
        ),
      ),
    ),
    );
  }

  /// What a page holds, said under its title.
  String _sectionHelp(AppLocalizations l10n, _SettingsSection s) => switch (s) {
        _SettingsSection.account => l10n.settingsPageAccountDesc,
        _SettingsSection.plan => l10n.settingsPagePlanDesc,
        _SettingsSection.general => l10n.settingsPageGeneralDesc,
        _SettingsSection.appearance => l10n.settingsPageAppearanceDesc,
        _SettingsSection.keyboard => l10n.settingsPageKeyboardMouseDesc,
        _SettingsSection.notifications => l10n.settingsLinkNotificationsHelp,
        _SettingsSection.terminal => l10n.settingsPageTerminalSshDesc,
        _SettingsSection.files => l10n.settingsPageFilesDesc,
        _SettingsSection.screens => l10n.settingsScreensHelp,
        _SettingsSection.security => l10n.settingsPageSecurityPrivacyDesc,
        _SettingsSection.data => l10n.settingsPageBackupsDataDesc,
        _SettingsSection.about => '',
      };

  /// One page's header and settings, keyed and search-scoped (so search jump
  /// and highlight resolve against its row keys). The header is the page's
  /// name, the line of what it holds and a rule, as the mockup draws it;
  /// runs of rows stand in cards (see [_carded]).
  Widget _sectionBlock(BuildContext context, WidgetRef ref,
      AppLocalizations l10n, _SettingsSection section) {
    final help = _sectionHelp(l10n, section);
    return Container(
      key: sectionKeys[section],
      child: _SettingsSearchScope(
        section: section,
        rowKey: rowKey,
        highlighted: highlightedSetting,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              label: _sectionLabel(l10n, section),
              // Sync is the Account page's, backups the Backups and data
              // page's; the themes Appearance's: their guides' "?" by the
              // header.
              guide: switch (section) {
                _SettingsSection.account => 'sync',
                _SettingsSection.data => 'sync',
                _SettingsSection.appearance => 'themes',
                _ => null,
              },
            ),
            if (help.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  help,
                  key: const ValueKey('settings-page-help'),
                  style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13.5),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 14, bottom: 24),
              child: Divider(height: 1, color: AppColors.v3BorderSubtle),
            ),
            Builder(
              builder: (ctx) {
                try {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: _carded(_buildSection(context, ref, section)),
                  );
                } catch (e) {
                  return Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l10n.settingsInlineSectionLoadError(
                          _sectionLabel(l10n, section), e.toString()),
                      style: TextStyle(color: AppColors.v3Error, fontSize: 12),
                    ),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }

  /// A page's widgets with each run of rows in one card, a hairline between
  /// two rows: the labels, notes, galleries and
  /// panels between them stand as they are.
  List<Widget> _carded(List<Widget> widgets) {
    final out = <Widget>[];
    var run = <Widget>[];
    void close() {
      if (run.isEmpty) return;
      out.add(_RowCard(rows: run));
      run = <Widget>[];
    }

    for (final w in widgets) {
      if (w is _SettingRow || w is _LateRow) {
        run.add(w);
      } else {
        close();
        out.add(w);
      }
    }
    close();
    return out;
  }

  /// Search across every setting (title / help / section name), grouped by
  /// section. Selecting a result shows its section and flashes the row.
  Widget _searchResults(
      BuildContext context, WidgetRef ref, AppLocalizations l10n, String query) {
    final grouped = <_SettingsSection, List<_SearchHit>>{};
    // A team's member is not shown the plans' names.
    final inTeam = (ref.watch(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty;
    for (final spec in _kSettingsSearchIndex) {
      if (spec.macOnly && defaultTargetPlatform != TargetPlatform.macOS) continue;
      if (spec.computerOnly && isTouchLayout) continue;
      if (spec.section == _SettingsSection.plan && !zestHasPlans) continue;
      if (identical(spec, _kMoshSearchSpec) && !moshSystemClientOffered) continue;
      if (spec.plans && inTeam) continue;
      final e = spec.said(l10n);
      final inTitle = e.title.toLowerCase().contains(query);
      final inSubtitle = e.subtitle.toLowerCase().contains(query);
      final inSection =
          _sectionLabel(l10n, e.section).toLowerCase().contains(query);
      if (inTitle || inSubtitle || inSection) {
        grouped
            .putIfAbsent(e.section, () => [])
            .add(_SearchHit(e, inTitle, inSubtitle, inSection));
      }
    }
    if (grouped.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(32, 22, 48, 8),
            child: Text(l10n.settingsSearchNoResults,
                style:
                    TextStyle(color: AppColors.v3TextSecondary, fontSize: 13)),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: ZestScrollFade(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 14, 48, 32),
            children: [
              for (final section in _SettingsSection.values)
                if (grouped[section] != null) ...[
                  _SearchGroupHeader(label: _sectionLabel(l10n, section)),
                  for (final hit in grouped[section]!)
                    _SearchResultItem(
                      hit: hit,
                      query: query,
                      section: _sectionLabel(l10n, section),
                      onTap: () => onSelectSetting(hit.entry),
                    ),
                ],
            ],
          ),
        ),
      ),
    );
  }

  /// Remote screens (4.0): the key that opens a screen's menu on a computer,
  /// the scaling a new screen is saved with, how a finger drives one on a
  /// phone or tablet, what recording mode does to the picture, and whether
  /// one's own hosts' screens share the clipboard by default.
  List<Widget> _buildScreens(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _SettingRow(
        label: l10n.settingsScreenMenuKey,
        subtitle: l10n.settingsScreenMenuKeyDesc,
        child: _Dropdown<ScreenMenuKey>(
          value: ref.watch(screenMenuKeyProvider),
          items: [for (final k in ScreenMenuKey.values) ZestSelectItem(k, k.label)],
          onChanged: (v) => ref.read(screenMenuKeyProvider.notifier).set(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsScreenScalingDefault,
        subtitle: l10n.settingsScreenScalingDefaultDesc,
        child: _Dropdown<ScreenScaling>(
          value: ref.watch(screenScalingDefaultProvider),
          items: [for (final s in ScreenScaling.values) ZestSelectItem(s, screenScalingNameIn(l10n, s))],
          onChanged: (v) => ref.read(screenScalingDefaultProvider.notifier).set(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsScreenTouchDefault,
        subtitle: l10n.settingsScreenTouchDefaultDesc,
        child: _Dropdown<ScreenTouchMode>(
          value: ref.watch(screenTouchDefaultProvider),
          items: [for (final m in ScreenTouchMode.values) ZestSelectItem(m, screenTouchModeNameIn(l10n, m))],
          onChanged: (v) => ref.read(screenTouchDefaultProvider.notifier).set(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsScreenRecording,
        subtitle: l10n.settingsScreenRecordingDesc,
        child: _Dropdown<ScreenRecordingBehaviour>(
          value: ref.watch(screenRecordingBehaviourProvider),
          items: [for (final b in ScreenRecordingBehaviour.values) ZestSelectItem(b, b.nameIn(l10n))],
          onChanged: (v) => ref.read(screenRecordingBehaviourProvider.notifier).set(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsScreenClipboardDefault,
        subtitle: l10n.settingsScreenClipboardDefaultDesc,
        child: _Toggle(
          key: const ValueKey('screen-settings-clipboard'),
          value: ref.watch(screenClipboardDefaultProvider),
          onChanged: (v) => ref.read(screenClipboardDefaultProvider.notifier).set(v),
        ),
      ),
    ];
  }

  List<Widget> _buildSection(
      BuildContext context, WidgetRef ref, _SettingsSection section) {
    switch (section) {
      case _SettingsSection.account:
        // The Account panel's sections, without its title bar or scroll:
        // sign-in, keys, devices, sync and the account's danger rows.
        return const [ProfileScreen(embedded: true, part: ProfilePart.account)];
      case _SettingsSection.plan:
        return _buildPlan(context, ref);
      case _SettingsSection.general:
        return _buildGeneral(context, ref);
      case _SettingsSection.appearance:
        return _buildAppearance(context, ref);
      case _SettingsSection.keyboard:
        return _buildKeyboard(context, ref);
      case _SettingsSection.notifications:
        return _buildNotifications(context, ref);
      case _SettingsSection.terminal:
        // The terminal (it was the end of Appearance) and what a new
        // connection starts with (it was General's).
        return [
          ..._buildTerminal(context, ref),
          const _SettingDivider(),
          ..._buildConnectionDefaults(context, ref),
        ];
      case _SettingsSection.files:
        return _buildFiles(context, ref);
      case _SettingsSection.screens:
        return _buildScreens(context, ref);
      case _SettingsSection.security:
        return _buildSecurity(context, ref);
      case _SettingsSection.data:
        // The account page's Data section and this device's danger rows,
        // with the cloud accounts kept in sync on this computer (they were
        // under General: found 18 October 2026, only a phone listed them).
        return const [
          ProfileScreen(
            embedded: true,
            part: ProfilePart.data,
            // Under the Data section, whose heading it shares (its own tile
            // says Cloud accounts).
            dataExtra: _RowCard(rows: [CloudAccountsTiles()], padded: false),
          ),
        ];
      case _SettingsSection.about:
        return _buildAbout(context, ref);
    }
  }

  // ── Plan ───────────────────────────────────────────────────────

  /// The plan this account has, its chip opening the plan popover (what
  /// each plan is, 4.0); Compare plans, on the website's page on the plans;
  /// Redeem a code where the account is not fully entitled (it was the
  /// account page's). A team's member is told what the seat gives, never the
  /// plans' names.
  List<Widget> _buildPlan(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final inTeam = (ref.watch(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty;
    return [
      _SettingRow(
        key: const ValueKey('settings-plan-yours'),
        label: l10n.settingsPlanYours,
        subtitle: inTeam ? l10n.settingsPlanTeamSeat : null,
        alwaysShowSubtitle: true,
        child: inTeam ? const SizedBox.shrink() : const PlanChip(key: ValueKey('settings-plan-chip')),
      ),
      if (!inTeam)
        _SettingRow(
          label: l10n.settingsPlanCompare,
          subtitle: l10n.settingsPlanCompareDesc,
          child: _ActionButton(
            key: const ValueKey('settings-plan-compare'),
            label: l10n.settingsPlanCompare,
            icon: LucideIcons.externalLink,
            onPressed: () => ref.read(planPageOpenerProvider)(Uri.parse(kZestPlansUrl)),
          ),
        ),
      const SizedBox(height: 18),
      const ProfileScreen(embedded: true, part: ProfilePart.plan),
    ];
  }

  // ── Notifications ──────────────────────────────────────────────

  /// What reaches the notification panel: the same toggles the bell's gear
  /// used to open in a modal, now a settings page like the other categories.
  List<Widget> _buildNotifications(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Text(
          l10n.notifPrefsSubtitle,
          style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 12),
        ),
      ),
      // A computer's notices shown by the system as well (4.0, off at
      // first): with "Close to tray" on, nothing was heard until the window
      // was opened. A tablet's are the system's always.
      if (!isTouchLayout) ...[
        _SettingRow(
          label: l10n.notifPrefsSystemComputer,
          subtitle: l10n.notifPrefsSystemComputerDesc,
          child: _Toggle(
            key: const ValueKey('settings-system-notifications'),
            value: ref.watch(desktopSystemNotificationsProvider),
            onChanged: (v) async {
              if (await updater.setDesktopSystemNotifications(v) || !context.mounted) return;
              // macOS said no: the switch stays off, and why is said, with
              // the way to its settings.
              showTopSnackBar(
                context,
                l10n.notifPrefsSystemMacDenied,
                isWarning: true,
                duration: const Duration(seconds: 12),
                actionLabel: l10n.notificationsOpenSystemSettings,
                onAction: NotificationService.openSystemSettings,
              );
            },
          ),
        ),
        const _SettingDivider(),
      ],
      _SubSectionLabel(label: l10n.settingsInlineNotifSessionsSection),
      _SettingRow(
        label: l10n.notifPrefsMonitorAlerts,
        subtitle: l10n.notifPrefsMonitorAlertsDesc,
        child: _Toggle(
          value: ref.watch(monitorAlertsEnabledProvider),
          onChanged: (v) => updater.setMonitorAlertsEnabled(v),
        ),
      ),
      _SettingRow(
        label: l10n.notifPrefsConnectionLost,
        subtitle: l10n.notifPrefsConnectionLostDesc,
        child: _Toggle(
          value: ref.watch(notifyConnectionLostProvider),
          onChanged: (v) => updater.setNotifyConnectionLost(v),
        ),
      ),
      _SettingRow(
        label: l10n.notifPrefsServerHealthChecks,
        subtitle: l10n.notifPrefsServerHealthChecksDesc,
        child: _Toggle(
          key: const ValueKey('settings-reach-checks-notifications'),
          value: ref.watch(healthChecksEnabledProvider),
          onChanged: (v) => setReachabilityChecks(context, ref, v),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineNotifTransfersSection),
      _SettingRow(
        label: l10n.notifPrefsTransferComplete,
        subtitle: l10n.notifPrefsTransferCompleteDesc,
        child: _Toggle(
          value: ref.watch(notifyTransferCompleteProvider),
          onChanged: (v) => updater.setNotifyTransferComplete(v),
        ),
      ),
      _SettingRow(
        label: l10n.notifPrefsTransferFailed,
        subtitle: l10n.notifPrefsTransferFailedDesc,
        child: _Toggle(
          value: ref.watch(notifyTransferFailedProvider),
          onChanged: (v) => updater.setNotifyTransferFailed(v),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineNotifAppSection),
      _SettingRow(
        label: l10n.notifPrefsSecurityAlerts,
        subtitle: l10n.notifPrefsSecurityAlertsDesc,
        child: _Toggle(
          value: ref.watch(notifySecurityAlertsProvider),
          onChanged: (v) => updater.setNotifySecurityAlerts(v),
        ),
      ),
      _SettingRow(
        label: l10n.notifPrefsUpdateAvailable,
        subtitle: l10n.notifPrefsUpdateAvailableDesc,
        child: _Toggle(
          value: ref.watch(notifyUpdateAvailableProvider),
          onChanged: (v) => updater.setNotifyUpdateAvailable(v),
        ),
      ),
    ];
  }

  // ── General ──────────────────────────────────────────────────

  /// General: the language, the window and startup, and nothing else (4.0:
  /// the connection defaults are Terminal and SSH's, the SFTP rows Files',
  /// the cloud accounts and Reset all settings Backups and data's).
  List<Widget> _buildGeneral(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final desktopUpdater = ref.read(desktopSettingsUpdaterProvider);
    final restoreSessions = ref.watch(desktopRestoreSessionsProvider);
    final minimizeToTray = ref.watch(desktopMinimizeToTrayProvider);
    final confirmClose = ref.watch(desktopConfirmCloseWithSessionsProvider);

    return [
      _SettingRow(
        label: l10n.settingsLanguage,
        subtitle: l10n.settingsLanguageSubtitle,
        child: _SelectButton(
          key: const ValueKey('settings-language'),
          label: currentLanguageLabel(context, ref),
          onTap: () => showLanguagePickerDialog(context, ref),
        ),
      ),
      // A computer's window (its close, the tray, its sessions restored at
      // start): a tablet's app has none of its own (4.0), and these did
      // nothing there.
      if (!isTouchLayout) ...[
      _SettingRow(
        label: l10n.settingsInlineCloseToTray,
        subtitle: l10n.settingsInlineCloseToTrayDesc,
        child: _Toggle(
          value: minimizeToTray,
          onChanged: (v) => desktopUpdater.setMinimizeToTray(v),
        ),
      ),
      // S1 (close-confirmation audit): this is the WIRED control - consumed at
      // desktop_shell.dart's window-close handler. The old Security→Safety
      // "Confirm before closing sessions" toggle (`close_confirmation`) drove
      // nothing and was removed; this one is renamed so its scope (window close
      // while sessions are live) is unmistakable.
      _SettingRow(
        label: l10n.settingsConfirmCloseWindow,
        subtitle: l10n.settingsConfirmCloseWindowDesc,
        child: _Toggle(
          value: confirmClose,
          onChanged: (v) => desktopUpdater.setConfirmCloseWithSessions(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineAutoRestore,
        subtitle: l10n.settingsInlineAutoRestoreDesc,
        child: _Toggle(
          value: restoreSessions,
          onChanged: (v) => desktopUpdater.setRestoreSessions(v),
        ),
      ),
      ],
    ];
  }

  // ── Terminal and SSH: connection defaults ──────────────────────

  /// What a new connection starts with, and whether hosts are checked for
  /// being reachable (they were General's).
  List<Widget> _buildConnectionDefaults(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    final defaultPort = ref.watch(defaultPortProvider);
    final defaultUsername = ref.watch(defaultUsernameProvider);
    final connectionTimeout = ref.watch(connectionTimeoutProvider);
    return [
      _SubSectionLabel(label: l10n.settingsInlineConnectionDefaultsSection),
      _SettingRow(
        label: l10n.settingsInlineDefaultSshPort,
        child: SizedBox(
          width: _kControlWidth,
          child: _NumberField(
            value: defaultPort,
            min: 1,
            max: 65535,
            onChanged: (v) => updater.setDefaultPort(v),
          ),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineDefaultUsername,
        child: SizedBox(
          width: _kControlWidth,
          child: _TextField(
            value: defaultUsername,
            onChanged: (v) => updater.setDefaultUsername(v),
          ),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineConnectionTimeout,
        child: SizedBox(
          width: _kControlWidth,
          child: _NumberField(
            value: connectionTimeout,
            min: 5,
            max: 120,
            unit: 's',
            onChanged: (v) => updater.setConnectionTimeout(v),
          ),
        ),
      ),
      // Whether hosts are checked for being reachable (moved from Advanced):
      // app-wide, so it lives with the other connection defaults. Off until
      // its person turns it on, which asks first (setReachabilityChecks).
      _SettingRow(
        label: l10n.settingsHealthChecks,
        subtitle: l10n.settingsHealthChecksHelp,
        child: _Toggle(
          key: const ValueKey('settings-reach-checks'),
          value: ref.watch(healthChecksEnabledProvider),
          onChanged: (v) => setReachabilityChecks(context, ref, v),
        ),
      ),
      if (ref.watch(healthChecksEnabledProvider))
        _SettingRow(
          label: l10n.settingsInlineCheckInterval,
          child: _Dropdown<int>(
            value: ref.watch(healthCheckIntervalProvider),
            items: [
              ZestSelectItem(30, l10n.settingsInlineSecondsOption(30)),
              ZestSelectItem(60, l10n.settingsInlineMinutesOption(1)),
              ZestSelectItem(120, l10n.settingsInlineMinutesOption(2)),
              ZestSelectItem(300, l10n.settingsInlineMinutesOption(5)),
            ],
            onChanged: (v) => updater.setHealthCheckInterval(v),
          ),
        ),
    ];
  }

  // ── Files ──────────────────────────────────────────────────────

  /// The SFTP browser's rows (they were General's).
  List<Widget> _buildFiles(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return [
      _SettingRow(
        label: l10n.settingsSftpTimeFormat,
        subtitle: l10n.settingsSftpTimeFormatDesc,
        child: _Dropdown<SftpTimeFormat>(
          value: ref.watch(sftpTimeFormatProvider),
          items: [
            for (final f in SftpTimeFormat.values)
              ZestSelectItem(f, sftpTimeFormatLabel(l10n, f)),
          ],
          onChanged: (v) => ref.read(sftpTimeFormatProvider.notifier).set(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsMobHiddenFilesInBrowser,
        subtitle: l10n.settingsMobHiddenFilesInBrowserDesc,
        child: _Dropdown<SftpHiddenLevel>(
          value: ref.watch(sftpHiddenLevelProvider),
          items: [
            ZestSelectItem(SftpHiddenLevel.systemOnly, l10n.settingsMobSystemFilesOnly),
            ZestSelectItem(SftpHiddenLevel.hiddenAndSystem, l10n.settingsMobHiddenAndSystem),
            ZestSelectItem(SftpHiddenLevel.none, l10n.none),
          ],
          onChanged: (v) =>
              ref.read(sftpHiddenLevelProvider.notifier).setLevel(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsDeleteHoldLabel,
        subtitle: l10n.settingsDeleteHoldSubtitle,
        child: _Dropdown<int>(
          value: ref.watch(sftpDeleteHoldSecondsProvider),
          items: [
            ZestSelectItem(0, l10n.settingsDeleteHoldOff),
            for (final s in const [5, 10, 30])
              ZestSelectItem(s, l10n.settingsDeleteHoldSeconds(s)),
          ],
          onChanged: (v) =>
              ref.read(sftpDeleteHoldSecondsProvider.notifier).setSeconds(v),
        ),
      ),
    ];
  }

  // ── Terminal ───────────────────────────────────────────────────

  /// Delete a custom TERMINAL theme (desktop had no delete path before). Falls
  /// back to the Dark theme if the deleted one was the active terminal theme.
  /// `_ContentArea` is a ConsumerWidget (no setState), so refresh is driven by
  /// bumping [_terminalThemesRevisionProvider], which `_buildTerminal` watches.
  Future<void> _deleteCustomTerminalTheme(
      BuildContext context, WidgetRef ref, String id) async {
    final l10n = AppLocalizations.of(context)!;
    final name = TerminalThemes.names[id] ?? id;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.settingsInlineDeleteTerminalThemeTitle(name),
      body: l10n.settingsInlineDeleteTerminalThemeBody,
      confirmLabel: l10n.settingsInlineDeleteTheme,
    );
    if (ok != true || !context.mounted) return;
    final prefs = ref.read(sharedPreferencesProvider);
    final wasActive = ref.read(terminalThemeIdProvider) == id;
    await TerminalThemes.deleteCustomTheme(prefs: prefs, id: id);
    if (wasActive) {
      await ref
          .read(settingsUpdaterProvider)
          .setTerminalTheme(TerminalThemes.defaultId);
    }
    ref.read(_terminalThemesRevisionProvider.notifier).state++;
  }

  List<Widget> _buildTerminal(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    // Depend on the delete-revision so the section rebuilds when a custom
    // terminal theme is removed (the theme store is static, not a provider).
    ref.watch(_terminalThemesRevisionProvider);
    final fontSize = ref.watch(terminalFontSizeProvider);
    final fontFamily = ref.watch(terminalFontFamilyProvider);
    final cursorStyle = ref.watch(cursorStyleProvider);
    final cursorBlink = ref.watch(cursorBlinkProvider);
    final cursorShown = ref.watch(cursorVisibilityProvider);
    final ligatures = ref.watch(terminalLigaturesProvider);
    final scrollback = ref.watch(scrollbackLinesProvider);
    final bell = ref.watch(bellEnabledProvider);
    final copyOnSelect = ref.watch(copyOnSelectProvider);
    final keepalive = ref.watch(keepaliveIntervalProvider);
    final autoReconnect = ref.watch(autoReconnectEnabledProvider);

    // S5: the terminal-theme picker + "Build custom theme" button moved here
    // from Appearance so all terminal presentation lives in one place.
    final themeId = ref.watch(shownTerminalThemeIdProvider);
    final isPro = ref.watch(isProProvider);
    final themeNames = TerminalThemes.names;
    final themeIds = themeNames.keys.toList();

    return [
      _SubSectionLabel(label: l10n.settingsInlineSectionTerminal),
      _SettingRow(
        label: l10n.settingsInlineTerminalColours,
        subtitle: l10n.settingsInlineTerminalColoursDesc,
        child: _Dropdown<String>(
          value:
              themeIds.contains(themeId) ? themeId : TerminalThemes.defaultId,
          items: [
            for (final id in themeIds)
              ZestSelectItem(
                id,
                themeNames[id] ?? id,
                enabled: isPro || TerminalThemes.freeThemeIds.contains(id),
                swatch: [TerminalThemes.all[id]?.background ?? AppColors.v3Surface],
                badge: !isPro && !TerminalThemes.freeThemeIds.contains(id) ? l10n.settingsInlinePro : null,
              ),
          ],
          // Route through the coordinator so "Match terminal to app theme"
          // (when on) flips the paired app theme too.
          onChanged: (v) =>
              ref.read(themeSyncCoordinatorProvider).setTerminalTheme(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineCustomTerminalThemes,
        subtitle: isPro
            ? l10n.settingsInlineCustomTerminalThemesDescPro
            : l10n.settingsInlineCustomTerminalThemesDescFree,
        child: _TerminalThemeActionButton(isPro: isPro),
      ),
      // Saved custom terminal palettes, each deletable (desktop had no delete
      // path before). Built-ins are not listed here.
      if (TerminalThemes.customThemeIds.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final id in TerminalThemes.customThemeIds)
                _DeletableThemeChip(
                  label: TerminalThemes.names[id] ?? id,
                  swatch: TerminalThemes.all[id]?.background,
                  onDelete: () =>
                      _deleteCustomTerminalTheme(context, ref, id),
                ),
            ],
          ),
        ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineFontSection),
      _SettingRow(
        label: l10n.settingsInlineFontFamily,
        // Nerd Font icons come with every font (4.0), behind More.
        subtitle: l10n.settingsTerminalFontNerdIcons,
        child: _Dropdown<TerminalFontFamily>(
          value: fontFamily,
          items: [
            for (final f in TerminalFontFamily.values)
              ZestSelectItem(f, f.nameIn(l10n)),
          ],
          onChanged: (v) => updater.setTerminalFontFamily(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineFontSize,
        child: SizedBox(
          width: _kControlWidth,
          child: _NumberField(
            value: clampTerminalFontSize(fontSize).round(),
            min: kTerminalFontSizeMin.round(),
            max: kTerminalFontSizeMax.round(),
            unit: 'pt',
            onChanged: (v) => updater.setTerminalFontSize(v.toDouble()),
          ),
        ),
      ),
      // Programming ligatures, as a phone's Terminal settings have them (a
      // computer had no switch for them: found 22 October 2026 in the 3.0
      // docs check).
      _SettingRow(
        label: l10n.settingsMobProgrammingLigatures,
        subtitle: l10n.settingsMobProgrammingLigaturesDesc,
        child: _Toggle(
          value: ligatures,
          onChanged: (v) => updater.setTerminalLigatures(v),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineCursorSection),
      _SettingRow(
        label: l10n.settingsInlineCursorStyle,
        child: _Dropdown<TerminalCursorShape>(
          value: cursorStyle,
          items: [
            for (final s in TerminalCursorShape.values)
              ZestSelectItem(s, s.nameIn(l10n)),
          ],
          onChanged: (v) => updater.setTerminalCursorShape(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineCursorBlink,
        child: _Toggle(
          value: cursorBlink,
          onChanged: (v) => updater.setCursorBlink(v),
        ),
      ),
      // Hidden while output arrives, for full-screen programs that make it
      // jump around as they redraw, or never drawn
      // (4.0).
      _SettingRow(
        label: l10n.settingsCursorVisibility,
        subtitle: l10n.settingsCursorVisibilityDesc,
        child: _Dropdown<TerminalCursorVisibility>(
          value: cursorShown,
          items: [
            for (final v in TerminalCursorVisibility.values) ZestSelectItem(v, v.nameIn(l10n), note: v.noteIn(l10n)),
          ],
          onChanged: (v) => updater.setCursorVisibility(v),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineBehaviorSection),
      _SettingRow(
        label: l10n.settingsInlineScrollbackBuffer,
        subtitle: l10n.settingsInlineScrollbackBufferDesc,
        child: _Dropdown<int>(
          // A value set on a phone (any number of lines, 0 for unlimited)
          // that is none of these is shown as it is, as an item of its own:
          // it matched no item (blank in a released build, an assertion in a
          // debug one), or was shown as 5k lines.
          value: scrollback,
          items: [
            for (final n in scrollbackMenuValues(scrollback))
              ZestSelectItem(n, kScrollbackChoices.contains(n)
                    ? l10n.settingsInlineScrollbackLines(n ~/ 1000)
                    : n <= 0
                        ? l10n.settingsMobUnlimitedScrollback
                        : l10n.settingsScrollbackCount(n)),
          ],
          onChanged: (v) => updater.setScrollbackLines(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineTerminalBell,
        child: _Toggle(
          value: bell,
          onChanged: (v) => updater.setBellEnabled(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineCopyOnSelect,
        subtitle: l10n.settingsInlineCopyOnSelectDesc,
        child: _Toggle(
          value: copyOnSelect,
          onChanged: (v) => updater.setCopyOnSelect(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsOsc52Clipboard,
        subtitle: l10n.settingsOsc52ClipboardDesc,
        child: _Toggle(
          value: ref.watch(osc52ClipboardProvider),
          onChanged: (v) => updater.setOsc52Clipboard(v),
        ),
      ),
      // On by default and held on every platform while a session is live
      // (keep_awake_controller.dart), but only a phone could turn it off
      // (found in a code audit).
      _SettingRow(
        key: const ValueKey('settings-keep-awake'),
        label: l10n.settingsKeepAwake,
        subtitle: l10n.settingsKeepAwakeDesc,
        child: _Toggle(
          value: ref.watch(keepScreenAwakeProvider),
          onChanged: (v) => updater.setKeepScreenAwake(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineAutoReconnect,
        subtitle: l10n.settingsInlineAutoReconnectDesc,
        child: _Toggle(
          value: autoReconnect,
          onChanged: (v) => updater.setAutoReconnectEnabled(v),
        ),
      ),
      // Tabs that say where a host comes from (3.3.0).
      _SettingRow(
        label: l10n.settingsTabSource,
        subtitle: l10n.settingsTabSourceDesc,
        child: _Dropdown<TabSourceMode>(
          value: ref.watch(tabSourceModeProvider),
          items: [
            for (final m in TabSourceMode.values) ZestSelectItem(m, m.nameIn(l10n)),
          ],
          onChanged: (m) => setTabSourceMode(ref, m),
        ),
      ),
      _SettingRow(
        label: l10n.settingsTabSourceVault,
        subtitle: l10n.settingsTabSourceVaultDesc,
        child: _Toggle(
          value: ref.watch(tabSourceVaultProvider),
          onChanged: ref.watch(tabSourceModeProvider) == TabSourceMode.off ? null : (v) => setTabSourceVault(ref, v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsTabSourceGroup,
        subtitle: l10n.settingsTabSourceGroupDesc,
        child: _Toggle(
          value: ref.watch(tabSourceGroupProvider),
          onChanged: ref.watch(tabSourceModeProvider) == TabSourceMode.off ? null : (v) => setTabSourceGroup(ref, v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsTmuxAutoDetect,
        subtitle: l10n.settingsTmuxAutoDetectDesc,
        child: _Toggle(
          value: ref.watch(tmuxAutoDetectProvider),
          onChanged: (v) => updater.setTmuxAutoDetect(v),
        ),
      ),
      // Mosh (4.0): the app's own client, or the mosh program installed on
      // this computer (a Mac and Linux only; every other device has the
      // app's own alone).
      if (moshSystemClientOffered)
        _SettingRow(
          label: l10n.settingsMoshBuiltin,
          subtitle: l10n.settingsMoshBuiltinDesc,
          child: _Toggle(
            value: !ref.watch(moshSystemClientProvider),
            onChanged: (v) => updater.setMoshSystemClient(!v),
          ),
        ),
      _SettingRow(
        label: l10n.settingsInlineSshKeepaliveInterval,
        // S2: this global is now the effective keepalive for any connection
        // that doesn't set its own; 0 disables keepalive entirely.
        subtitle: l10n.settingsKeepaliveDesc,
        child: SizedBox(
          width: _kControlWidth,
          child: _NumberField(
            value: keepalive,
            min: 0,
            max: 300,
            onChanged: (v) => updater.setKeepaliveInterval(v),
          ),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsSessionLogSection),
      ..._buildSessionLog(context, ref, l10n, updater),
    ];
  }

  /// Session log to file (2.1): the switch, where the files go, timestamps.
  /// Device-local settings; the folder row shows the folder that is really
  /// used (the default when none is set) with Change / Open / Use default.
  List<Widget> _buildSessionLog(
    BuildContext context,
    WidgetRef ref,
    AppLocalizations l10n,
    SettingsUpdater updater,
  ) {
    final enabled = ref.watch(sessionLogEnabledProvider);
    final configuredDir = ref.watch(sessionLogDirectoryProvider);
    final effectiveDir =
        ref.watch(sessionLogEffectiveDirProvider).valueOrNull ?? '';

    Future<void> changeFolder() async {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: l10n.settingsSessionLogFolder,
        initialDirectory: effectiveDir.isEmpty ? null : effectiveDir,
      );
      if (picked == null || picked.isEmpty) return;
      await updater.setSessionLogDirectory(picked);
    }

    return [
      _SettingRow(
        label: l10n.settingsSessionLogEnabled,
        subtitle: l10n.settingsSessionLogEnabledDesc,
        child: _Toggle(
          value: enabled,
          onChanged: (v) => updater.setSessionLogEnabled(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsSessionLogFolder,
        // The folder in use: a value, not help, so it is always shown.
        subtitle: effectiveDir,
        alwaysShowSubtitle: true,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ActionButton(
              label: l10n.settingsSessionLogChangeFolder,
              icon: LucideIcons.folderOpen,
              onPressed: changeFolder,
            ),
            const SizedBox(width: 8),
            _ActionButton(
              label: l10n.settingsSessionLogOpenFolder,
              icon: LucideIcons.externalLink,
              onPressed: effectiveDir.isEmpty
                  ? null
                  : () => openFolderInFileManager(effectiveDir),
            ),
            if (configuredDir.isNotEmpty) ...[
              const SizedBox(width: 8),
              _ActionButton(
                label: l10n.settingsSessionLogResetFolder,
                icon: LucideIcons.rotateCcw,
                onPressed: () => updater.setSessionLogDirectory(''),
              ),
            ],
          ],
        ),
      ),
      _SettingRow(
        label: l10n.settingsSessionLogTimestamps,
        subtitle: l10n.settingsSessionLogTimestampsDesc,
        child: _Toggle(
          value: ref.watch(sessionLogTimestampsProvider),
          onChanged: (v) => updater.setSessionLogTimestamps(v),
        ),
      ),
      // The transcripts saved on this computer, and one saved anywhere, to
      // read (nothing in the app opened one).
      _SettingRow(
        label: l10n.transcriptsTitle,
        subtitle: l10n.transcriptsSettingsDesc,
        child: _ActionButton(
          label: l10n.transcriptsOpen,
          icon: LucideIcons.scrollText,
          onPressed: () => context.push(Routes.transcripts),
        ),
      ),
    ];
  }

  // ── Appearance ─────────────────────────────────────────────────

  List<Widget> _buildAppearance(BuildContext context, WidgetRef ref) {
    // S5: terminal-theme controls moved to the Terminal section, so the
    // terminal `updater`/`themeId`/`themeNames`/`themeIds` locals are gone
    // from here. Appearance now covers app-level theme + layout only.
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);

    // ── App-theme data ──────────────────────────────────────────
    final appThemeId = ref.watch(appThemeIdProvider);
    final followSystem = ref.watch(followSystemThemeProvider);
    final customAppThemes = ref.watch(customAppThemesProvider);
    final builtInAppThemes = BuiltInThemes.all;
    // A team's member is not shown the plans' names.
    final inTeam = (ref.watch(orchardSummariesProvider).valueOrNull ?? const []).isNotEmpty;
    final allAppThemes = <ZestTheme>[
      ...builtInAppThemes,
      ...customAppThemes.values,
    ];

    return [
      // ════════════════════════════════════════════════════════════
      // APP THEME - controls the surrounding chrome (sidebar, dialogs,
      // pill bar, settings). Independent of the terminal palette.
      // ════════════════════════════════════════════════════════════
      _SubSectionLabel(label: l10n.settingsInlineAppThemeSection),
      _SettingRow(
        label: l10n.settingsInlineFollowSystemTheme,
        subtitle: l10n.settingsInlineFollowSystemThemeDesc,
        child: _Toggle(
          value: followSystem,
          onChanged: (v) =>
              ref.read(themeUpdaterProvider).setFollowSystemTheme(v),
        ),
      ),
      // The themes as a gallery (4.0): each drawn
      // in its own colours, the one in use with the accent's border and a
      // check; a pick goes through the coordinator, as the dropdown's did
      // (following the system stops; the terminal follows while matched).
      AppThemeGallery(
        header: (showAll) => _SettingRow(
          label: l10n.settingsInlineAppTheme,
          subtitle: followSystem ? l10n.settingsInlineAppThemeFollowingDesc : l10n.settingsInlineAppThemeGalleryDesc,
          // The gallery's line, as its mockup draws it (it says what a pick does).
          alwaysShowSubtitle: true,
          child: showAll ?? const SizedBox.shrink(),
        ),
        choices: [
          for (final t in builtInAppThemes)
            AppThemeChoice(theme: t, name: t.name, enabled: isPro || kFreeAppThemeIds.contains(t.id)),
          // Custom themes are unlocked by making them.
          for (final t in customAppThemes.values) AppThemeChoice(theme: t, name: t.name, custom: true),
        ],
        selectedId: allAppThemes.any((t) => t.id == appThemeId) ? appThemeId : kDefaultAppThemeId,
        onPick: (id) => ref.read(themeSyncCoordinatorProvider).setAppTheme(id),
      ),
      const SizedBox(height: 12),
      // A theme of one's own, with what it belongs to: the Squeezed tag says
      // what Squeezed is, except to a team's member, who is not shown the
      // plans' names.
      WorkspaceDashedBox(
        radius: 12,
        color: AppColors.v3BorderStrong,
        padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
        // (On a line of its own: test/ui/settings_search_index_test.dart reads
        // each row's name from the line it starts on.)
        child:
            _SettingRow(
          leading: const AppThemeCustomTile(),
          label: l10n.settingsInlineCustomTheme,
          labelTrailing: inTeam ? null : const PlanChip(plan: AccountPlan.squeezed),
          subtitle: !isPro
              ? l10n.settingsInlineCustomAppThemesDescFree
              : customAppThemes.isEmpty
                  ? l10n.settingsInlineCustomAppThemesDescPro
                  : l10n.settingsInlineCustomThemeDescSaved(customAppThemes.length),
          // The card's words, as the gallery's mockup draws them.
          alwaysShowSubtitle: true,
          child: _AppThemeActionButtons(isPro: isPro),
        ),
      ),
      const SizedBox(height: 4),
      _SettingRow(
        label: l10n.settingsInlineMatchTerminalToApp,
        subtitle: l10n.settingsInlineMatchTerminalToAppDesc,
        child: _Toggle(
          value: ref.watch(themesSyncedProvider),
          onChanged: (v) =>
              ref.read(themeSyncCoordinatorProvider).setSyncEnabled(v),
        ),
      ),
      // How big the controls are (4.0): Auto follows
      // the input (touch sized while touch is used, a computer's size while a
      // mouse or a trackpad is).
      _SettingRow(
        key: const ValueKey('settings-control-size'),
        label: l10n.settingsControlSize,
        subtitle: l10n.settingsControlSizeDesc,
        child: _Dropdown<UiDensity>(
          value: ref.watch(uiDensityProvider),
          items: [
            for (final d in UiDensity.values) ZestSelectItem(d, d.nameIn(l10n)),
          ],
          onChanged: (d) => setUiDensity(ref, d),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineHostCardsSection),
      ..._buildHostCardSection(context, ref),
      // The terminal's colours, font and cursor are Terminal and SSH's (4.0),
      // with the rest of the terminal.
    ];
  }

  // ── Host card customisation ────────────────────────────────────

  List<Widget> _buildHostCardSection(
      BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final settings = ref.watch(hostCardSettingsProvider);
    final notifier = ref.read(hostCardSettingsProvider.notifier);

    return [
      _SettingRow(
        label: l10n.settingsInlineDensity,
        subtitle: l10n.settingsInlineDensityDesc,
        child: _Dropdown<HostCardDensity>(
          value: settings.density,
          items: [
            for (final d in HostCardDensity.values)
              ZestSelectItem(d, d.nameIn(l10n)),
          ],
          onChanged: notifier.setDensity,
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineColumns,
        subtitle: l10n.settingsInlineColumnsDesc,
        child: _Dropdown<HostCardColumns>(
          value: settings.columns,
          items: [
            // A column-count option ("Auto", "2 columns") is not a host
            // name; it must never go through the name rule.
            for (final c in HostCardColumns.values)
              ZestSelectItem(c, c.nameIn(l10n)),
          ],
          onChanged: notifier.setColumns,
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineAccentRail,
        subtitle: l10n.settingsInlineAccentRailDesc,
        child: _Dropdown<HostCardAccentMode>(
          value: settings.accentMode,
          items: [
            for (final a in HostCardAccentMode.values)
              ZestSelectItem(a, a.nameIn(l10n)),
          ],
          onChanged: notifier.setAccentMode,
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineShowOsIcon,
        child: _Toggle(
          value: settings.showOsIcon,
          onChanged: (v) => notifier.setShowOsIcon(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineShowSubtitle,
        subtitle: l10n.settingsInlineShowSubtitleDesc,
        child: _Toggle(
          value: settings.showSubtitle,
          onChanged: (v) => notifier.setShowSubtitle(v),
        ),
      ),
      // A host's tags on its card (4.0: off by default; the list view and
      // the host's panel always show them).
      _SettingRow(
        label: l10n.settingsInlineShowTags,
        subtitle: l10n.settingsInlineShowTagsDesc,
        child: _Toggle(
          value: settings.showTags,
          onChanged: (v) => notifier.setShowTags(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineShowStatusPill,
        subtitle: l10n.settingsInlineShowStatusPillDesc,
        child: _Toggle(
          value: settings.showStatusPill,
          onChanged: (v) => notifier.setShowStatusPill(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineHoverEditButton,
        subtitle: l10n.settingsInlineHoverEditButtonDesc,
        child: _Toggle(
          value: settings.showHoverEdit,
          onChanged: (v) => notifier.setShowHoverEdit(v),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () async {
              await notifier.reset();
              if (context.mounted) {
                showTopSnackBar(
                    context, l10n.settingsInlineHostCardSettingsReset);
              }
            },
            icon: const Icon(LucideIcons.rotateCcw, size: 16),
            label: Text(l10n.settingsInlineResetHostCardSettings),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.v3TextSecondary,
              textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12),
            ),
          ),
        ),
      ),
    ];
  }

  // ── Keyboard ───────────────────────────────────────────────────

  /// Keyboard and mouse (4.0: the Mouse and Keyboard shortcuts pages in one):
  /// what the mouse does in a terminal, Option as Meta on a Mac, and the
  /// shortcuts' table, to rebind, unbind or reset each action.
  List<Widget> _buildKeyboard(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final desktopUpdater = ref.read(desktopSettingsUpdaterProvider);
    final rightClickPaste = ref.watch(desktopRightClickPasteProvider);
    final middleClickPaste = ref.watch(desktopMiddleClickPasteProvider);

    // S1: the "Copy on select (desktop)" control was removed here - it was an
    // orphaned duplicate (`desktop_copy_on_select`) that drove nothing. The
    // real, wired copy-on-select lives under Terminal and SSH, Behavior
    // (`copy_on_select`, consumed by the terminal area).
    return [
      _SubSectionLabel(label: l10n.settingsInlineMouseSection),
      _SettingRow(
        label: l10n.settingsInlineRightClickPaste,
        child: _Toggle(
          value: rightClickPaste,
          onChanged: (v) => desktopUpdater.setRightClickPaste(v),
        ),
      ),
      _SettingRow(
        label: l10n.settingsInlineMiddleClickPaste,
        child: _Toggle(
          value: middleClickPaste,
          onChanged: (v) => desktopUpdater.setMiddleClickPaste(v),
        ),
      ),
      // Option as Meta, a Mac's alone (Windows' and Linux' Alt is Meta):
      // off until turned on, as Option types the layout's own characters.
      // (It was with the terminal's behaviour; a phone has it with the
      // keyboard too.)
      if (defaultTargetPlatform == TargetPlatform.macOS) ...[
        const _SettingDivider(),
        _SubSectionLabel(label: l10n.settingsDesktopSectionKeyboard),
        _SettingRow(
          label: l10n.hwKeysOptionMeta,
          subtitle: l10n.hwKeysOptionMetaDesc,
          child: _Toggle(
            value: ref.watch(optionAsMetaProvider),
            onChanged: (v) => ref.read(settingsUpdaterProvider).setOptionAsMeta(v),
          ),
        ),
      ],
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineKeyboardShortcutsSection),
      // As many as the table lists (it said 28).
      Padding(
        padding: const EdgeInsets.only(top: 6, bottom: 4),
        child: Text(
          l10n.settingsLinkShortcutsHelp(shortcutActionsOffered(voice: ref.watch(voiceInputSupportedProvider)).length),
          style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 12.5),
        ),
      ),
      const KeyboardShortcutsPanel(),
    ];
  }

  // ── Strongbox / Sync ───────────────────────────────────────────

  // ── Security ───────────────────────────────────────────────────

  List<Widget> _buildSecurity(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final updater = ref.read(settingsUpdaterProvider);
    // Encrypt-at-rest and hardware binding have no provider of their own;
    // the revision counter rebuilds this section after each action.
    ref.watch(_securityRevisionProvider);
    void bump() => ref.read(_securityRevisionProvider.notifier).state++;
    final actions = SecurityActions(context, ref);
    final lockEnabled = ref.watch(securityLockEnabledProvider);
    final encryptOn = ref.read(settingsServiceProvider).encryptingLockEnabled;
    final dangerousCmd = ref.watch(dangerousCommandProtectionProvider);
    final askHostKeys = ref.watch(askBeforeTrustingKeysProvider);

    return [
      _SubSectionLabel(label: l10n.settingsInlineAppLockSection),
      _SettingRow(
        label: l10n.settingsInlineAppLock,
        // The app lock cannot be removed while encryption is on: the PIN is
        // what decrypts the data. Turn encryption off first.
        // Biometrics named where the computer has them (Touch ID, Windows
        // Hello): it said so on a Mac alone, with Touch ID or without.
        // Why it cannot be turned off, where it cannot: always in sight.
        alwaysShowSubtitle: encryptOn,
        subtitle: encryptOn
            ? l10n.secSetAppLockSubtitleEncrypted
            : (ref.watch(biometricAvailableProvider).valueOrNull == true
                ? l10n.settingsAppLockDescPinBiometric
                : l10n.settingsAppLockDescPin),
        child: _Toggle(
          value: lockEnabled,
          onChanged: encryptOn
              ? null
              : (v) async {
                  await actions.setAppLock(v);
                  bump();
                },
        ),
      ),
      if (lockEnabled)
        _SettingRow(
          label: l10n.secSetChangePin,
          subtitle: l10n.secSetChangePinSubtitle,
          child: _ActionButton(
            label: l10n.accountChange,
            icon: LucideIcons.pin,
            onPressed: () async {
              await actions.changePin();
              bump();
            },
          ),
        ),
      if (lockEnabled)
        _SettingRow(
          label: l10n.settingsInlineAutoLock,
          subtitle: l10n.settingsInlineAutoLockDesc,
          child: _Dropdown<int>(
            value: ref.watch(autoLockTimeoutProvider).valueOrNull ??
                ((Platform.isAndroid || Platform.isIOS) ? 1 : 10),
            items: [
              ZestSelectItem(0, l10n.settingsInlineImmediately),
              ZestSelectItem(1, l10n.settingsInlineMinutesOption(1)),
              ZestSelectItem(5, l10n.settingsInlineMinutesOption(5)),
              ZestSelectItem(10, l10n.settingsInlineMinutesOption(10)),
              ZestSelectItem(15, l10n.settingsInlineMinutesOption(15)),
              ZestSelectItem(30, l10n.settingsInlineMinutesOption(30)),
              ZestSelectItem(-1, l10n.settingsInlineNever),
            ],
            onChanged: (v) async {
              await ref
                  .read(securityLockServiceProvider)
                  .setAutoLockTimeout(v);
              ref.invalidate(autoLockTimeoutProvider);
            },
          ),
        ),
      // The idle lock (3.0): locks with the app in front too.
      if (lockEnabled)
        _LateRow(builder: (context) {
          final own = ref.watch(idleLockSettingProvider).valueOrNull ?? 0;
          final team = ref.watch(teamIdleLockMinutesProvider);
          return _SettingRow(
            key: const ValueKey('settings-idle-lock'),
            label: l10n.secSetIdleLock,
            subtitle: team == null
                ? l10n.secSetIdleLockDesc
                : '${l10n.secSetIdleLockDesc} ${l10n.secSetIdleLockTeam(team)}',
            child: _Dropdown<int>(
              value: kIdleLockChoices.contains(own) ? own : 0,
              items: [
                for (final m in kIdleLockChoices)
                  ZestSelectItem(m, m == 0 ? l10n.secSetIdleLockOff : l10n.settingsInlineMinutesOption(m)),
              ],
              onChanged: (v) async {
                await ref.read(securityLockServiceProvider).setIdleLockMinutes(v);
                ref.invalidate(idleLockSettingProvider);
              },
            ),
          );
        }),
      // The app locks with the computer, when its lock screen comes up or it
      // sleeps; on by default with the app lock (from a security experience
      // review).
      if (lockEnabled)
        _SettingRow(
          key: const ValueKey('settings-lock-with-computer'),
          label: l10n.secSetLockWithComputer,
          subtitle: l10n.secSetLockWithComputerDesc,
          child: _Toggle(
            value: ref.watch(lockWithComputerSettingProvider).valueOrNull ?? true,
            onChanged: (v) async {
              await ref.read(securityLockServiceProvider).setLockWithComputer(v);
              ref.invalidate(lockWithComputerSettingProvider);
            },
          ),
        ),
      // What the lock screen says of the sessions still connected behind it:
      // nothing by default, how many, or how many and their names (4.0.1).
      if (lockEnabled)
        _SettingRow(
          key: const ValueKey('settings-lock-sessions'),
          label: l10n.secSetLockShowSessions,
          subtitle: l10n.secSetLockShowSessionsDesc,
          child: _Dropdown<LockSessionsShown>(
            value: ref.watch(lockSessionsShownProvider),
            items: [
              for (final s in LockSessionsShown.values) ZestSelectItem(s, lockSessionsShownName(l10n, s)),
            ],
            onChanged: (v) => updater.setLockSessionsShown(v),
          ),
        ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.secSetHeaderDataAtRest),
      _SettingRow(
        label: l10n.secSetEncryptAtRest,
        // Why it cannot be turned on yet, where it cannot: always in sight.
        alwaysShowSubtitle: !lockEnabled,
        subtitle: lockEnabled
            ? l10n.secSetEncryptAtRestSubtitle
            : l10n.secSetEncryptNeedsLock,
        child: _Toggle(
          value: encryptOn,
          // Needs an app-lock PIN first (the encryption key rides on it).
          onChanged: lockEnabled
              ? (v) async {
                  if (v) {
                    await actions.enableEncryption();
                  } else {
                    await actions.disableEncryption();
                  }
                  bump();
                }
              : null,
        ),
      ),
      // Without full-disk encryption, an attacker who takes the raw drive
      // can attempt the PIN offline with nothing to throttle them; disk
      // encryption is the real stolen-device defence on a computer.
      Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 6),
        child: Text(
          l10n.secSetDesktopDiskNote(SecurityActions.diskEncryptionName()),
          style: TextStyle(
              color: AppColors.v3TextSecondary, fontSize: 12, height: 1.4),
        ),
      ),
      // Hardware-backed encryption: binds the vault key to the TPM, or on a
      // Mac to its Secure Enclave (4.0), so an extracted file is useless off
      // this machine. Linux has no provider yet.
      if (Platform.isWindows || Platform.isMacOS)
        _LateRow(builder: (_) => FutureBuilder<({bool available, bool bound})>(
          future: actions.hardwareState(),
          builder: (context, snap) {
            final available = snap.data?.available ?? false;
            final bound = snap.data?.bound ?? false;
            final texts = hardwareTexts(l10n);
            return _SettingRow(
              label: l10n.secSetHwEncryption,
              alwaysShowSubtitle: !encryptOn || !available,
              subtitle: !encryptOn
                  ? l10n.secSetHwNeedsEncrypt
                  : !available
                      ? texts.notAvailable
                      : texts.subtitle,
              child: _Toggle(
                value: bound,
                onChanged: (encryptOn && available && snap.hasData)
                    ? (v) async {
                        await actions.setHardwareBinding(v);
                        bump();
                      }
                    : null,
              ),
            );
          },
        )),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineSafetySection),
      _SettingRow(
        label: l10n.settingsInlineDangerousCommandProtection,
        // S3: accurate scope - the gate covers pasted commands, snippet
        // execution, and broadcast, but NOT free typing.
        subtitle: l10n.settingsDangerousCommandDesc,
        child: _Toggle(
          value: dangerousCmd,
          onChanged: (v) => updater.setDangerousCommandProtection(v),
        ),
      ),
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlineHostKeysSection),
      _SettingRow(
        label: l10n.settingsInlineUnknownHostKeys,
        subtitle: askHostKeys
            ? l10n.settingsInlineUnknownHostKeysAskDesc
            : l10n.settingsInlineUnknownHostKeysTofuDesc,
        subtitleColor: askHostKeys ? null : AppColors.sftpWarn,
        child: _Dropdown<bool>(
          value: askHostKeys,
          items: [
            ZestSelectItem(true, l10n.settingsInlineAskBeforeTrusting),
            ZestSelectItem(false, l10n.settingsInlineTrustOnFirstUse),
          ],
          onChanged: (v) => updater.setAskBeforeTrustingNewKeys(v),
        ),
      ),
      _SettingRow(
        label: l10n.secSetTrustedHostKeys,
        subtitle: l10n.secSetTrustedHostKeysSubtitle,
        child: _ActionButton(
          label: l10n.accountManage,
          icon: LucideIcons.keyRound,
          onPressed: () => context.push(Routes.knownHosts),
        ),
      ),
      _SettingRow(
        label: l10n.secSetClearAllKeys,
        subtitle: l10n.secSetClearAllKeysSubtitle,
        child: _ActionButton(
          label: l10n.commonClearAll,
          icon: LucideIcons.trash,
          destructive: true,
          onPressed: () => actions.clearKnownHosts(),
        ),
      ),
      // Recording mode and its level (4.0: it was in the Help panel and the
      // status bar alone, which keep it too): names and addresses masked
      // before a screenshot or a recording.
      const _SettingDivider(),
      _SubSectionLabel(label: l10n.settingsInlinePrivacySection),
      _SettingRow(
        label: l10n.recModeName,
        subtitle: l10n.recModeTooltipOff,
        child: _Toggle(
          key: const ValueKey('settings-recording-mode'),
          value: ref.watch(recordingModeProvider),
          onChanged: (v) => updater.setRecordingMode(v),
        ),
      ),
      if (ref.watch(recordingModeProvider))
        _SettingRow(
          label: l10n.recModeLevelLabel,
          subtitle: ref.watch(recordingRedactLevelProvider) == RedactLevel.strict
              ? l10n.recModeLevelStrictDesc
              : l10n.recModeLevelLayoutDesc,
          child: _Dropdown<RedactLevel>(
            value: ref.watch(recordingRedactLevelProvider),
            items: [
              ZestSelectItem(RedactLevel.layout, l10n.recModeLevelLayout),
              ZestSelectItem(RedactLevel.strict, l10n.recModeLevelStrict),
            ],
            onChanged: (v) => updater.setRecordingRedactLevel(v),
          ),
        ),
      // Where keys' passwords stay in a password manager (3.0).
      if (ref.watch(passwordManagersProvider) != null) ...[
        _SubSectionLabel(label: l10n.pmSettingsTitle),
        const PasswordManagerSettingsPanel(),
      ],
    ];
  }

  // ── Automation ─────────────────────────────────────────────────

  // ── Backups ────────────────────────────────────────────────────

  /// Short relative label for the last backup time ('Never', 'Just now',
  /// '5 min ago', '3 h ago', '2 d ago', or an absolute date past a month).
  // ── Advanced ───────────────────────────────────────────────────

  // ── Notifications ──────────────────────────────────────────────
  // Promoted to a top-level section (was a sub-group under Advanced).

  // ── About ──────────────────────────────────────────────────────

  List<Widget> _buildAbout(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final asyncVersion = ref.watch(appVersionProvider);
    // Tier rendered from the ONE source (spec 4 note 4), so it can never
    // disagree with the rail or the Account card.
    final tierLabel =
        ref.watch(tierLabelProvider) ?? l10n.settingsInlineTierFree;

    final versionString = asyncVersion.maybeWhen(
      data: (v) => v,
      orElse: () => 'unknown',
    );
    final platformLabel = _prettyPlatformLabel();
    final dartVersion = Platform.version.split(' ').first;

    // Single-line build string the user can copy into a bug report.
    final buildInfo =
        'ZestSSH $versionString • $platformLabel • Dart $dartVersion • $tierLabel';

    return [
      Center(
        child: Column(
          children: [
            // Product logo - was a generic terminal glyph; now the
            // real app icon, matching the mobile About screen.
            Container(
              width: 80,
              height: 80,
              padding: const EdgeInsets.all(2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.v3AccentPrimary.withValues(alpha: 0.55),
                    AppColors.v3AccentPrimary.withValues(alpha: 0.05),
                  ],
                ),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.asset(
                  'assets/ZestSSH.png',
                  fit: BoxFit.contain,
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'ZestSSH',
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                asyncVersion.when(
                  data: (version) => Text(
                    l10n.settingsInlineVersionLabel(version),
                    style: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontSize: 13,
                    ),
                  ),
                  loading: () => Text(
                    l10n.settingsInlineLoadingVersion,
                    style: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontSize: 13,
                    ),
                  ),
                  error: (_, _) => Text(
                    l10n.settingsInlineVersionUnknown,
                    style: TextStyle(
                      color: AppColors.v3TextSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                // Which build this is, where it is not the release.
                if (!zestOfficial) ...[
                  const SizedBox(width: 8),
                  Text(
                    zestBuildNameShown != '' ? zestBuildNameShown : l10n.communityBuild,
                    key: const ValueKey('settings-about-build-kind'),
                    style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 13),
                  ),
                ],
                const SizedBox(width: 10),
                const PlanChip(key: ValueKey('about-plan-chip')),
              ],
            ),
            const SizedBox(height: 10),
            // The single product statement - one sentence, shared with the
            // first-run screen and mobile About so the product says one thing.
            Text(
              AppLocalizations.of(context)!.productStatement,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppColors.v3TextSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            // Copy-build-info chip - handy for bug reports - and, on the
            // desktop builds that update from the website, a check for a
            // newer release (the same check as clicking the status bar's
            // version).
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              runSpacing: 8,
              children: [
                _CopyBuildInfoButton(buildInfo: buildInfo),
                if (UpdateCheckService.manualCheckSupported)
                  const _CheckForUpdatesButton(),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 32),
      Container(
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: AppColors.v3BorderSubtle,
            width: 1,
          ),
        ),
        // Dedup (spec 4 note 3): version and tier are already stated inline
        // above, so the table keeps only Platform - the one value not on
        // screen elsewhere.
        child: _AboutRow(
            label: l10n.settingsInlinePlatform, value: platformLabel),
      ),
      // Whether ZestSSH asks the website for a newer version by itself
      // (3.0, 17 October 2026: the check could be turned off, and no screen
      // had the switch). Only where updates come from the website.
      if (UpdateCheckService.manualCheckSupported) ...[
        const SizedBox(height: 12),
        _SettingRow(
          label: l10n.updateCheckAutomatic,
          subtitle: l10n.updateCheckAutomaticDesc,
          child: _Toggle(
            key: const ValueKey('settings-update-check-automatic'),
            value: ref.watch(updateCheckEnabledProvider),
            onChanged: (v) => ref.read(updateCheckEnabledProvider.notifier).set(v),
          ),
        ),
        // Installing a release by itself, as the app starts, and no "Update
        // available" in the title bar for it (off by default). Only with
        // the check on: without it nothing is found to install.
        if (ref.watch(updateCheckEnabledProvider)) ...[
          const SizedBox(height: 12),
          _SettingRow(
            label: l10n.updateAutoInstall,
            subtitle: l10n.updateAutoInstallDesc,
            child: _Toggle(
              key: const ValueKey('settings-update-auto-install'),
              value: ref.watch(autoUpdateProvider),
              onChanged: (v) => ref.read(autoUpdateProvider.notifier).set(v),
            ),
          ),
        ],
      ],
      const SizedBox(height: 24),
      _SubSectionLabel(label: l10n.settingsInlineLinksSection),
      const SizedBox(height: 8),
      // (Only what the build has: its own website, Discord, report service
      // and policy, or none of them.)
      if (kZestWebsite != '')
        _LinkRow(
          label: l10n.settingsInlineLinkWebsite,
          icon: LucideIcons.languages,
          onTap: () => launchUrl(Uri.parse(kZestWebsite)),
        ),
      // Community, bug reporting and changelog. Bug reports go through
      // the in-app Help panel (which attaches the build info and an optional
      // redacted screenshot) and What's new opens the in-app changelog, so
      // neither leaves the app any more.
      if (kZestDiscordUrl != '')
        _LinkRow(
          label: l10n.settingsInlineLinkDiscord,
          icon: LucideIcons.messagesSquare,
          onTap: () => launchUrl(Uri.parse(kZestDiscordUrl)),
        ),
      if (zestHasCloud)
      _LinkRow(
        label: l10n.settingsInlineLinkReportBug,
        icon: LucideIcons.bug,
        // The report form is a panel of the shell, which is behind this
        // pop-up: Settings closes, and the form opens where it can be used.
        onTap: () {
          final help = ref.read(helpDockProvider.notifier);
          Navigator.of(context).maybePop();
          help.state = HelpPage.reportBug;
        },
      ),
      _LinkRow(
        label: l10n.settingsInlineLinkWhatsNew,
        icon: LucideIcons.gift,
        onTap: () => showWhatsNewDialog(context),
      ),
      if (kZestPrivacyUrl != '') ...[
        _LinkRow(
          label: l10n.settingsInlineLinkPrivacy,
          icon: LucideIcons.shieldQuestion,
          onTap: () => launchUrl(Uri.parse(kZestPrivacyUrl)),
        ),
        _LinkRow(
          label: l10n.settingsInlineLinkTerms,
          icon: LucideIcons.fileText,
          onTap: () => launchUrl(Uri.parse(kZestTermsUrl)),
        ),
      ],
      _LinkRow(
        label: l10n.settingsInlineLinkLicenses,
        icon: LucideIcons.copyright,
        onTap: () {
          // Show the existing custom LicensesScreen inside a dialog
          // so the user stays in the settings flow on desktop.  The
          // built-in showLicensePage pushed a fullscreen route that
          // took over the entire window - that's the bug the user
          // pointed out.
          final size = MediaQuery.of(context).size;
          final dialogWidth =
              (size.width * 0.75).clamp(720.0, 1280.0);
          final dialogHeight =
              (size.height * 0.85).clamp(560.0, 1000.0);
          // Open unconditionally - gating on `whenData` meant a click did
          // nothing while the version was still loading. Fall back to an
          // empty version string until it resolves.
          showDialog<void>(
            context: context,
            builder: (_) => Dialog(
              backgroundColor: AppColors.v3Background,
              insetPadding: const EdgeInsets.all(24),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: SizedBox(
                  width: dialogWidth,
                  height: dialogHeight,
                  child: LicensesScreen(version: asyncVersion.valueOrNull ?? ''),
                ),
              ),
            ),
          );
        },
      ),
      const SizedBox(height: 24),
      Center(
        child: Text(
          l10n.settingsInlineMadeWithCare,
          style: TextStyle(
            color: AppColors.v3TextSecondary.withValues(alpha: 0.6),
            fontSize: 12,
          ),
        ),
      ),
    ];
  }
}

// ══════════════════════════════════════════════════════════════════
// Shared building blocks
// ══════════════════════════════════════════════════════════════════

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, this.guide});

  final String label;

  /// The feature id of the guide whose "?" follows the header, if any.
  final String? guide;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      style: TextStyle(
        color: AppColors.v3TextPrimary,
        fontSize: 22,
        height: 1.2,
        letterSpacing: -0.2,
        fontWeight: FontWeight.w600,
        fontFamily: 'GeistSans',
      ),
    );
    final feature = guide;
    return feature == null ? text : GuideTitle(feature: feature, title: text);
  }
}

/// The one section header on the page: a 2px brand tick, an 11px uppercase
/// label, a hairline filling the width, and an optional right-aligned action.
class _SubSectionLabel extends StatelessWidget {
  const _SubSectionLabel({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // The app's section header (it was a look-alike of its own here).
      padding: const EdgeInsets.only(top: 16),
      child: ZestSectionHeader(label: label),
    );
  }
}

class _SettingDivider extends StatelessWidget {
  const _SettingDivider();

  @override
  Widget build(BuildContext context) {
    // Each section's header draws its own rule: a gap is enough.
    return const SizedBox(height: 10);
  }
}

/// A small pill for a saved custom terminal theme, with a delete affordance.
/// Used in the Terminal settings section's "Custom terminal themes" area.
class _DeletableThemeChip extends StatelessWidget {
  const _DeletableThemeChip({
    required this.label,
    required this.swatch,
    required this.onDelete,
  });

  final String label;
  final Color? swatch;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.only(start: 8),
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: AppColors.v3BorderSubtle),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: swatch ?? AppColors.v3Elevated,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: AppColors.v3BorderSubtle, width: 0.5),
            ),
          ),
          const SizedBox(width: 7),
          Text(
            label,
            style: TextStyle(color: AppColors.v3TextSecondary, fontSize: 12),
          ),
          const SizedBox(width: 6),
          // A button that says which theme it removes, a stop for the
          // keyboard, 32 square (it was a 14 square cross for a pointer).
          Semantics(
            button: true,
            label: AppLocalizations.of(context)!.a11yRemoveNamed(label),
            excludeSemantics: true,
            onTap: onDelete,
            child: Tooltip(
              message: AppLocalizations.of(context)!.commonRemove,
              excludeFromSemantics: true,
              child: InkResponse(
                onTap: onDelete,
                radius: 16,
                child: SizedBox.square(
                  dimension: minTapTarget(context),
                  child: Icon(LucideIcons.x, size: 14, color: AppColors.v3TextTertiary),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One setting: its name at the left and its control at the right, on one
/// line, with what it does behind a quiet More beside the name (rows
/// one line plus More).
/// Every row was its name over a line or two of help,
/// and a page read as a wall of words. A line that is a value (a folder in
/// use), a reason a control cannot be used, or a warning stays in sight
/// ([alwaysShowSubtitle], or any [subtitleColor]).
class _SettingRow extends StatelessWidget {
  const _SettingRow({
    super.key,
    required this.label,
    this.subtitle,
    this.subtitleColor,
    this.leading,
    this.labelTrailing,
    this.alwaysShowSubtitle = false,
    required this.child,
  });

  final String label;
  final String? subtitle;

  /// Before the words: a tile (the custom theme card's, 4.0).
  final Widget? leading;

  /// Beside the name, on its line: a tag (Squeezed, 4.0).
  final Widget? labelTrailing;

  /// The line under the name is always shown, not behind More.
  final bool alwaysShowSubtitle;

  /// Override for the description colour, e.g. the trust-on-first-use host-key
  /// warning (which is then always shown). Defaults to the muted secondary.
  final Color? subtitleColor;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final words = _RowWords(
      label: label,
      subtitle: subtitle,
      subtitleColor: subtitleColor,
      labelTrailing: labelTrailing,
      alwaysShown: alwaysShowSubtitle || subtitleColor != null,
      // Its switch, select or field is said with the setting's name ("Bell,
      // switch, on"): it was a switch of nothing to a screen reader.
      control: ZestControlLabel(label: label, child: child),
    );
    final row = ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 56),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: leading == null
              ? words
              : Row(children: [leading!, const SizedBox(width: 14), Expanded(child: words)]),
        ),
      ),
    );

    // S7: when inside a section search scope, register a scroll-target key
    // (id = "${section}/${label}") and flash a brief highlight when a search
    // result selects this row. Rows outside a scope render unchanged.
    final scope = _SettingsSearchScope.maybeOf(context);
    if (scope == null) return row;
    final id = '${scope.section.name}/$label';
    return KeyedSubtree(
      key: scope.rowKey(id),
      child: ValueListenableBuilder<String?>(
        valueListenable: scope.highlighted,
        builder: (context, highlighted, child) => AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          decoration: BoxDecoration(
            color: highlighted == id
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.10)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        ),
        child: row,
      ),
    );
  }
}

/// A row's words and control: the name (with its tag and More) beside the
/// control, or the control under them where beside them the words would keep
/// too little room; the help under both while it is open.
class _RowWords extends StatefulWidget {
  const _RowWords({
    required this.label,
    required this.subtitle,
    required this.subtitleColor,
    required this.labelTrailing,
    required this.alwaysShown,
    required this.control,
  });

  final String label;
  final String? subtitle;
  final Color? subtitleColor;
  final Widget? labelTrailing;
  final bool alwaysShown;
  final Widget control;

  @override
  State<_RowWords> createState() => _RowWordsState();
}

class _RowWordsState extends State<_RowWords> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final help = widget.subtitle;
    final hasHelp = help != null && help.isNotEmpty;
    final foldable = hasHelp && !widget.alwaysShown;
    final shown = hasHelp && (widget.alwaysShown || _open);
    final head = Wrap(
      spacing: 12,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          widget.label,
          style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 14),
        ),
        ?widget.labelTrailing,
        if (foldable)
          SettingMoreButton(
            setting: widget.label,
            open: _open,
            onTap: () => setState(() => _open = !_open),
          ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The control under the words where beside them they would keep less
        // than 200 pixels (a wide choice left them a few letters a line at
        // the window's least width and a larger text size, in Russian).
        BesideOrUnder(gap: 16, words: head, control: widget.control),
        if (shown)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Text(
                  help,
                  style: TextStyle(
                    color: widget.subtitleColor ?? AppColors.v3TextSecondary,
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A row whose widget is built later (a builder of a _SettingRow, or of a
/// future one): it stands in a card with the rows beside it.
class _LateRow extends StatelessWidget {
  const _LateRow({required this.builder});

  final WidgetBuilder builder;

  @override
  Widget build(BuildContext context) => builder(context);
}

/// A run of rows in one card, a hairline between two:
/// the surface, its border and a radius of 10, the rows
/// 20 in from its sides.
class _RowCard extends StatelessWidget {
  const _RowCard({required this.rows, this.padded = true});

  final List<Widget> rows;

  /// The rows 20 in from the card's sides (a list of its own, the cloud
  /// accounts, has its own padding).
  final bool padded;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: const ValueKey('settings-row-card'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.border),
      ),
      child: InkLayer(
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < rows.length; i++)
            DecoratedBox(
              decoration: BoxDecoration(
                border: i == rows.length - 1 ? null : Border(bottom: BorderSide(color: ZestTokens.borderSubtle)),
              ),
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: padded ? 20 : 0),
                child: rows[i],
              ),
            ),
        ],
        ),
      ),
    );
  }
}

/// Compact accent switch. Position is the primary channel, accent reinforces
/// it: OFF knob is the DIM token, ON track is a brand ALPHA over the surface
/// (not a baked hex). 36 by 20, 14px knob. Shared shape with the full-screen
/// settings switch.
class _Toggle extends StatelessWidget {
  const _Toggle({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool>? onChanged;

  // The app's one switch (it drew an orange thumb on a brown track).
  @override
  Widget build(BuildContext context) => ZestSwitch(value: value, onChanged: onChanged);
}

/// A setting's choice: the app's select (it was a Material dropdown inside
/// the same box, its menu over the field; found in a design
/// audit).
class _Dropdown<T> extends StatelessWidget {
  const _Dropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final T value;
  final List<ZestSelectItem<T>> items;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) =>
      ZestSelect<T>(value: value, items: items, onChanged: onChanged, width: _kControlWidth);
}

/// How wide every control in a setting's row is: inputs and selects line up
/// in one column.
const double _kControlWidth = 200;

/// A setting's control as the theme draws an input: its fill, its hairline,
/// its radius; the control column's width and 34 high.
class _ControlBox extends StatelessWidget {
  const _ControlBox({required this.child, this.focused = false});

  final Widget child;
  final bool focused;

  @override
  Widget build(BuildContext context) {
    final deco = Theme.of(context).inputDecorationTheme;
    final border = (focused ? deco.focusedBorder : deco.enabledBorder) as OutlineInputBorder?;
    return Container(
      width: _kControlWidth,
      // 34 high, or more where larger text needs it (a fixed 34 cut it off).
      constraints: const BoxConstraints(minHeight: 34),
      padding: const EdgeInsets.only(left: 12, right: 10, top: 4, bottom: 4),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: deco.fillColor,
        borderRadius: border?.borderRadius ?? BorderRadius.circular(8),
        border: Border.fromBorderSide(border?.borderSide ?? BorderSide(color: AppColors.v3BorderSubtle)),
      ),
      child: child,
    );
  }
}

/// A select that opens its own picker (the language's): the value and a
/// chevron, as a dropdown shows them.
class _SelectButton extends StatefulWidget {
  const _SelectButton({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  State<_SelectButton> createState() => _SelectButtonState();
}

class _SelectButtonState extends State<_SelectButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    // To a screen reader: the setting, what is chosen, a button.
    return Semantics(
      container: true,
      button: true,
      label: ZestControlLabel.maybeOf(context),
      value: widget.label,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
      mouseCursor: SystemMouseCursors.click,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
      child: GestureDetector(
        onTap: widget.onTap,
        child: _ControlBox(
          focused: _focused,
          child: Row(
            children: [
              Expanded(
                child: Text(widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 13)),
              ),
              Icon(LucideIcons.chevronDown, size: 14, color: AppColors.v3TextSecondary),
            ],
          ),
        ),
      ),
      ),
    );
  }
}

class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.unit,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Optional unit rendered inside the field (e.g. 's', 'pt'), so the row
  /// description never has to name the unit.
  final String? unit;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value.toString());
  }

  @override
  void didUpdateWidget(_NumberField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value) {
      final cursorPos = _controller.selection;
      _controller.text = widget.value.toString();
      try {
        _controller.selection = cursorPos;
      } catch (_) {}
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final parsed = int.tryParse(_controller.text);
    if (parsed != null) {
      final clamped = parsed.clamp(widget.min, widget.max);
      widget.onChanged(clamped);
      if (clamped != parsed) {
        _controller.text = clamped.toString();
      }
    } else {
      _controller.text = widget.value.toString();
    }
  }

  @override
  Widget build(BuildContext context) {
    // By the setting's name to a screen reader; 34 high or more where larger
    // text needs it (a fixed 34 cut the number off).
    return Semantics(
      label: ZestControlLabel.maybeOf(context),
      child: TextField(
      controller: _controller,
      keyboardType: TextInputType.number,
      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
      textAlign: TextAlign.right,
      style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 13),
      decoration: InputDecoration(
        isDense: true,
        constraints: const BoxConstraints(minHeight: 34),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        suffixText: widget.unit,
        suffixStyle: TextStyle(color: AppColors.v3TextSecondary, fontSize: 11),
      ),
      onSubmitted: (_) => _commit(),
      onTapOutside: (_) => _commit(),
      ),
    );
  }
}

class _TextField extends StatefulWidget {
  const _TextField({
    required this.value,
    required this.onChanged,
  });

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_TextField> createState() => _TextFieldState();
}

class _TextFieldState extends State<_TextField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.value);
  }

  @override
  void didUpdateWidget(_TextField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.value != widget.value &&
        _controller.text != widget.value) {
      _controller.text = widget.value;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final text = _controller.text.trim();
    if (text.isNotEmpty && text != widget.value) {
      widget.onChanged(text);
    } else if (text.isEmpty) {
      _controller.text = widget.value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: ZestControlLabel.maybeOf(context),
      child: TextField(
        controller: _controller,
        style: TextStyle(color: AppColors.v3TextPrimary, fontSize: 13),
        decoration: const InputDecoration(
          isDense: true,
          constraints: BoxConstraints(minHeight: 34),
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        ),
        onSubmitted: (_) => _commit(),
        onTapOutside: (_) => _commit(),
      ),
    );
  }
}

class _ActionButton extends StatefulWidget {
  const _ActionButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  // Nullable so a button can render visibly disabled ("not available
  // yet") instead of claiming success for an action it can't perform.
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  State<_ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<_ActionButton> {
  bool _hovered = false;
  bool _focusRing = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null;
    final color = !enabled
        ? AppColors.v3TextTertiary
        : widget.destructive
            ? AppColors.sftpCrit
            : AppColors.v3TextPrimary;

    // A button to a screen reader and a stop for the keyboard, with the
    // accent ring (it was a box only a pointer could press).
    final button = Semantics(
      container: true,
      button: true,
      enabled: enabled,
      child: ZestHover(onHover: enabled ? (h) => setState(() => _hovered = h) : null, child: FocusableActionDetector(
      enabled: enabled,
      onShowFocusHighlight: (f) => setState(() => _focusRing = f),
      mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
          widget.onPressed?.call();
          return null;
        }),
      },
      child: GestureDetector(
        onTap: widget.onPressed,
        child: ZestFocusRing(
        show: _focusRing,
        radius: 6,
        child: Container(
          constraints: BoxConstraints(minHeight: minTapTarget(context)),
          padding:
              const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            // Real hover feedback (was a no-op: both branches used the
            // same surface colour).
            color: enabled && _hovered
                ? AppColors.v3Hover
                : AppColors.v3Surface,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: widget.destructive && enabled
                  ? AppColors.sftpCrit.withValues(alpha: 0.4)
                  : AppColors.v3BorderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: Icon(widget.icon, size: 16, color: color)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ],
          ),
        ),
        ),
      ),
      )),
    );
    return button;
  }
}

/// A theme's three colours, as its choice shows them: brand, surface,
/// background.
/// Switch the Settings dock to [target], first running the sync-backend dirty
/// guard when it's the panel being REPLACED - so opening another editor while
/// sync-backend has unsaved store credentials prompts to discard instead of
/// dropping them silently. Aborts the switch if the user keeps editing.
Future<void> _guardedSwitchDock(WidgetRef ref, SettingsDock target) async {
  if (ref.read(settingsDockProvider) == SettingsDock.syncBackend &&
      target != SettingsDock.syncBackend) {
    final ctrl = ref.read(syncBackendCloseControllerProvider);
    if (ctrl.isDirty) {
      await ctrl.requestClose();
      // requestClose closes (dock→none) on save/discard; if the user kept
      // editing, the dock is still syncBackend → abort the switch.
      if (ref.read(settingsDockProvider) == SettingsDock.syncBackend) return;
    }
  }
  ref.read(settingsDockProvider.notifier).state = target;
}

/// "Create custom app theme" + "Open designer" action row.
///
/// For free users: shows a single locked button that routes to the
/// upgrade screen. For Pro users: shows a "+ New theme" button that
/// opens the Theme Designer.
class _AppThemeActionButtons extends ConsumerWidget {
  const _AppThemeActionButtons({required this.isPro});

  final bool isPro;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // How many are saved is said under Custom theme (4.0).
    return _ActionButton(
      label: isPro ? l10n.settingsInlineOpenThemeDesigner : l10n.deskUnlockWithSqueezed,
      icon: isPro ? LucideIcons.slidersHorizontal : LucideIcons.lock,
      onPressed: () {
        if (isPro) {
          // Dock the Theme Designer into the right pane of Settings
          // instead of pushing a full-screen route (guarding a dirty
          // sync-backend panel first).
          _guardedSwitchDock(ref, SettingsDock.appThemeDesigner);
        } else {
          PricingModal.show(context);
        }
      },
    );
  }
}

/// "Create custom terminal theme" button.
///
/// Docks the custom terminal-theme builder into the right pane of Settings
/// (instead of the modal dialog that [showCustomThemeBuilder] opens).
/// Pro-gated.
class _TerminalThemeActionButton extends ConsumerWidget {
  const _TerminalThemeActionButton({required this.isPro});
  final bool isPro;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return _ActionButton(
      label: isPro
          ? l10n.settingsInlineOpenThemeDesigner
          : l10n.deskUnlockWithSqueezed,
      icon: isPro ? LucideIcons.slidersHorizontal : LucideIcons.lock,
      onPressed: () {
        if (isPro) {
          _guardedSwitchDock(ref, SettingsDock.customThemeBuilder);
        } else {
          PricingModal.show(context);
        }
      },
    );
  }
}

class _AboutRow extends StatelessWidget {
  const _AboutRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          Text(
            label,
            style: TextStyle(
              color: AppColors.v3TextSecondary,
              fontSize: 13,
            ),
          ),
          const Spacer(),
          Flexible(
            child: SelectableText(
              value,
              style: TextStyle(
                color: AppColors.v3TextPrimary,
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
              ),
              maxLines: 1,
            ),
          ),
        ],
      ),
    );
  }
}

/// "Copy build info" pill - copies a single-line summary of the
/// app version, OS, Dart, and tier so the user can paste it into
/// a bug report without having to type it out.
/// About's "Check for updates": checks now and says what it found.
class _CheckForUpdatesButton extends ConsumerStatefulWidget {
  const _CheckForUpdatesButton();

  @override
  ConsumerState<_CheckForUpdatesButton> createState() =>
      _CheckForUpdatesButtonState();
}

class _CheckForUpdatesButtonState
    extends ConsumerState<_CheckForUpdatesButton> {
  bool _checking = false;
  bool _hovered = false;

  Future<void> _check() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await checkForUpdatesNow(context, ref);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: _checking ? SystemMouseCursors.basic : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        key: const ValueKey('about-check-updates'),
        onTap: _checking ? null : _check,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered && !_checking
                ? AppColors.v3Hover
                : AppColors.v3Surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_checking)
                SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppColors.v3TextSecondary,
                  ),
                )
              else
                Icon(
                  LucideIcons.refreshCw,
                  size: 13,
                  color: AppColors.v3TextSecondary,
                ),
              const SizedBox(width: 6),
              Text(
                _checking ? l10n.updateCheckChecking : l10n.updateCheckAction,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CopyBuildInfoButton extends StatefulWidget {
  const _CopyBuildInfoButton({required this.buildInfo});
  final String buildInfo;

  @override
  State<_CopyBuildInfoButton> createState() => _CopyBuildInfoButtonState();
}

class _CopyBuildInfoButtonState extends State<_CopyBuildInfoButton> {
  bool _copied = false;
  bool _hovered = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.buildInfo));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1500));
    if (!mounted) return;
    setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: _copy,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: _hovered
                ? AppColors.v3Hover
                : AppColors.v3Surface.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: _copied
                  ? AppColors.v3Success.withValues(alpha: 0.5)
                  : AppColors.v3BorderSubtle,
              width: 1,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _copied ? LucideIcons.check : LucideIcons.copy,
                size: 13,
                color: _copied
                    ? AppColors.v3Success
                    : AppColors.v3TextSecondary,
              ),
              const SizedBox(width: 6),
              Text(
                _copied
                    ? l10n.settingsInlineCopied
                    : l10n.settingsInlineCopyBuildInfo,
                style: TextStyle(
                  fontSize: 12,
                  color: _copied
                      ? AppColors.v3Success
                      : AppColors.v3TextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pretty-print the OS name + version.  Drops Dart's quoted product
/// name on Windows (which renders as `windows "Windows 10 Pro" 10.0
/// (Build 26200)` - readable but ugly).
String _prettyPlatformLabel() {
  final ver = Platform.operatingSystemVersion;
  if (Platform.isWindows) {
    // Pull "Windows 10 Pro" out of the quoted segment if present,
    // append the build number cleanly.
    final productMatch = RegExp(r'"([^"]+)"').firstMatch(ver);
    final buildMatch = RegExp(r'\(Build (\d+)\)').firstMatch(ver);
    var product = productMatch?.group(1) ?? 'Windows';
    final build = buildMatch?.group(1);
    // Windows 11 still reports major version 10 AND a product name of
    // "Windows 10 …", so the reported string mislabels every Win11 machine.
    // The build number is the only reliable discriminator: 11 is build
    // >= 22000. Correct the "10" to "11" (preserving the edition, e.g.
    // "Pro") so copied build info names the right OS. Non-"Windows 10 …"
    // products (e.g. "Windows Server 2025") are left untouched.
    final buildNum = build == null ? null : int.tryParse(build);
    if (buildNum != null && buildNum >= 22000) {
      product = product.replaceFirst('Windows 10', 'Windows 11');
    }
    return build == null ? product : '$product (Build $build)';
  }
  if (Platform.isMacOS) {
    // e.g. "Version 14.5 (Build 23F79)" → "macOS 14.5"
    final v = RegExp(r'Version ([\d.]+)').firstMatch(ver)?.group(1);
    return v == null ? 'macOS' : 'macOS $v';
  }
  if (Platform.isLinux) {
    // First line of /etc/os-release-derived string is usually enough.
    final firstLine = ver.split('\n').first.trim();
    return firstLine.isEmpty ? 'Linux' : firstLine;
  }
  if (Platform.isAndroid) return 'Android $ver';
  if (Platform.isIOS) return 'iOS $ver';
  return '${Platform.operatingSystem} $ver';
}

class _LinkRow extends StatefulWidget {
  const _LinkRow({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_LinkRow> createState() => _LinkRowState();
}

class _LinkRowState extends State<_LinkRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color:
                _hovered ? AppColors.v3Surface : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Icon(widget.icon,
                  size: 18, color: AppColors.v3TextSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: AppColors.v3TextPrimary,
                    fontSize: 14,
                  ),
                ),
              ),
              Icon(
                LucideIcons.externalLink,
                size: 14,
                color: AppColors.v3TextSecondary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
