import 'dart:async';
import 'dart:convert';
import 'dart:ui' show AppExitResponse;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart' show GoRoute, GoRouter;
import 'package:zestssh/features/notifications/notification_center.dart' show notificationCenterProvider;
import 'package:zestssh/features/shortcuts/shortcut_action.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart' show debugPuttyImportHere;
import 'package:zestssh/ui/screens/terminal/widgets/terminal_search_bar.dart';
import 'package:zestssh/ui/screens/tmux/tmux_session_view.dart';
import 'package:zestssh/features/broadcast/broadcast_to_hosts.dart';
import 'package:zestssh/features/broadcast/broadcast_controls.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/quick_connect_v3.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:flutter/rendering.dart' show RenderParagraph;
import '../helpers/words_cut.dart';
import 'package:http/http.dart' as http;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHClient;
import 'package:zestssh/core/widgets/status_pill.dart' show HostStatus;
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/snippet_providers.dart' show SnippetMetadata, encodeSnippetMetadata;
import 'package:zestssh/features/hosts/connect_link.dart' show quickConnectLinkText;
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/widgets/hosts_band.dart' show HostsBand;
import 'package:zestssh/ui/screens/desktop/widgets/desktop_terminal_area.dart' show DesktopTerminalArea;
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/providers/monitoring_providers.dart' show serverStatsProvider;
import 'package:zestssh/services/server_stats_service.dart';
import 'package:zestssh/services/security_lock_service.dart';
import 'package:zestssh/models/enums.dart' show SecurityLockMethod;
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/features/workspaces/models/workspace_view.dart' as ws_view;
import 'package:zestssh/features/workspaces/state/workspaces_provider.dart' as ws;
import 'package:zestssh/database/daos/connection_tags_dao.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/pane_layout.dart';
import 'package:zestssh/models/pane_tree.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_editor_dock.dart' show kHostsPageMinWidth;
import 'package:zestssh/providers/pane_tree_provider.dart';
import 'package:zestssh/providers/profile_avatar_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/shortcut_overrides_provider.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/theme_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/account/device_approvals.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/session_persistence_service.dart';
import 'package:zestssh/services/local_state_store.dart' show localStateStoreProvider;
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/theme/terminal_themes.dart' as app_themes;
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/desktop_shell.dart';
import 'package:zestssh/ui/screens/desktop/widgets/connection_failed_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/inspector_panel.dart';
import 'package:zestssh/ui/screens/desktop/widgets/session_chrome.dart' show SessionHeaderBar;
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/ui/screens/help/support_hub_compose.dart' show resetSupportHubDraft;
import 'package:zestssh/ui/screens/help/support_hub_page.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_dock.dart';
import 'package:zestssh/ui/screens/desktop/widgets/settings_inline_view.dart';
import 'package:zestssh/ui/screens/desktop/widgets/narrow_sidebar.dart';
import 'package:zestssh/ui/screens/settings/about_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/sftp_dock.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart' show sftpTransfersProvider;
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart' show TransferDirection, TransferItem, TransferStatus;
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/account_attention.dart'
    show accountSetupNeedsAttentionProvider;
import 'package:zestssh/features/orchards/spaces.dart' show Space, kOrchardsEnabled;
import 'package:zestssh/providers/update_providers.dart';
import 'package:zestssh/services/update_check_service.dart';

import '../helpers/fake_device_approvals_server.dart';
import '../helpers/memory_store_backend.dart';
import '../helpers/played_sftp_host.dart';
import 'shots_util.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';
import 'package:zestssh/ui/screens/desktop/widgets/desktop_status_bar.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;
import 'package:zestssh/ui/screens/desktop/widgets/pane_keys_row.dart';
import 'package:zestssh/ui/screens/terminal/widgets/terminal_soft_keyboard.dart' show TerminalSoftKeyboard;

/// Screenshots of the desktop shell, drawn offscreen with the real fonts,
/// for checking the 3.0 UI without running the app against anyone's data.
/// Off unless asked for:
///
///   flutter test --dart-define=ZEST_SHOTS=true test/visual/shell_shots_test.dart
///
/// Pictures land in build/shots/.
///
/// One test at the end takes no picture and always runs: it is the only one
/// that has the whole shell to click in and type at.
const _shots = shotsEnabled;

/// The pictures of the computer's shell are taken as on a computer: the
/// app's controls take a computer's sizes there (34 high, a phone's 44).
final _computer = TargetPlatformVariant.only(TargetPlatform.windows);

/// A tablet's pictures (4.0): Android's, touch sized.
final _tablet = TargetPlatformVariant.only(TargetPlatform.android);

/// An iPad Pro 12.9 upright, and held sideways (the mockups' sizes).
const _tabletUpright = Size(1024, 1366);
const _tabletSideways = Size(1366, 1024);

/// The themes the shell is drawn in: Ember, Graphite and Daylight, or the
/// ones named with `--dart-define=ZEST_SHOT_THEMES=one_dark,darcula`, each
/// with the terminal theme that goes with it.
const _namedThemes = String.fromEnvironment('ZEST_SHOT_THEMES');
final _shotThemes = _namedThemes.isEmpty ? const ['default_dark', 'graphite', 'default_light'] : _namedThemes.split(',');

/// The terminal theme a named theme brings along, as picking it in Settings
/// does.
Map<String, Object> _terminalOf(String themeId) => {
      if (_namedThemes.isNotEmpty && kAppToTerminalThemeId[themeId] != null)
        'terminal_theme': kAppToTerminalThemeId[themeId]!,
    };

/// Quiet stand-ins for the desktop plugins the shell calls: a window that
/// is not maximized, and a network that never changes.
void _stubPlugins() {
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
    switch (call.method) {
      case 'isMaximized':
      case 'isFullScreen':
      case 'isMinimized':
        return false;
      default:
        return null;
    }
  });
  const connectivity = 'dev.fluttercommunity.plus/connectivity_status';
  messenger.setMockMethodCallHandler(const MethodChannel(connectivity), (call) async => null);
  messenger.setMockMethodCallHandler(const MethodChannel('dev.fluttercommunity.plus/connectivity'),
      (call) async => ['wifi']);
}

/// Sync storage's guard as an editor with unsaved changes has it: it says
/// that it is dirty, counts each time it is asked to close, and stays.
class _DirtySyncStorage extends SyncBackendCloseController {
  bool dirty = true;
  int asked = 0;

  @override
  bool get isDirty => dirty;

  @override
  Future<void> requestClose() async => asked++;
}

/// Sessions the harness can set directly.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  void set(Map<String, SessionState> sessions) => state = sessions;

  /// While set, each host asked to open is written here and stands open at
  /// once, as a session of its own (the harness connects to nothing).
  List<String>? opened;

  /// While set, ending a session waits for it (a disconnect that takes its
  /// time).
  Completer<void>? holdEnding;

  /// While set, no session is opened: the free plan's limit is reached.
  bool full = false;

  /// When the connection of a session that dropped did, where the test says.
  DateTime? dropTime;

  @override
  DateTime? droppedAt(String sessionId) => dropTime ?? super.droppedAt(sessionId);

  @override
  Future<void> endSession(String sessionId, {bool byThePerson = true}) async {
    await holdEnding?.future;
    return super.endSession(sessionId);
  }

  /// Hosts that are not saved, asked to open (quick connect): each with the
  /// user typed. None is opened.
  final quick = <(Connection, String?)>[];

  @override
  String? startSession(
    Connection connection, {
    bool allowDuplicate = false,
    String? usernameOverride,
    String? initialCommand,
    String? asAccount,
    bool unattended = false,
    Space? space,
  }) {
    if (connection.id.startsWith('quick_')) {
      quick.add((connection, usernameOverride));
      return null;
    }
    if (full) return null;
    final opened = this.opened;
    if (opened == null) {
      return super.startSession(
        connection,
        allowDuplicate: allowDuplicate,
        usernameOverride: usernameOverride,
        initialCommand: initialCommand,
        asAccount: asAccount,
        unattended: unattended,
      space: space,
      );
    }
    opened.add(connection.id);
    final id = 'r${opened.length}';
    state = {...state, id: _session(int.parse(connection.id.substring(1)), id: id)};
    return id;
  }
}

/// A live-looking SSH shell that sends nothing anywhere.
class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

/// A live-looking SSH session whose connection is an SFTP server the test
/// plays: the SFTP dock opens the app's own file service on it. (The SFTP
/// dock of a session with a [_Shell] said that SFTP needs an active SSH
/// connection: a [_Shell] has none, and the app's SFTP button opens SFTP
/// only for a session that has one.)
class _SftpShell extends _Shell implements SshService {
  _SftpShell(this.client);

  @override
  final SSHClient client;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// deploy's home folder on web-01, made up: four folders and three files,
/// each changed at its own time.
PlayedSftpHost _deployHome() {
  int at(int month, int day, int hour, int minute) =>
      DateTime(2026, month, day, hour, minute).millisecondsSinceEpoch ~/ 1000;
  final host = PlayedSftpHost()..home = '/home/deploy';
  for (final (name, time) in [
    ('.config', at(10, 2, 14, 11)),
    ('app', at(11, 12, 8, 41)),
    ('backups', at(11, 11, 23, 0)),
    ('logs', at(11, 12, 9, 30)),
  ]) {
    host.folders.add('/home/deploy/$name');
    host.folderTimes['/home/deploy/$name'] = time;
  }
  void file(String name, String text, int size, int time) =>
      host.files['/home/deploy/$name'] = PlayedFile(utf8.encode(text), modified: time)..reportsSize = size;
  file('deploy.sh', '#!/bin/sh\nset -e\ndocker compose pull\ndocker compose up -d\n', 2150, at(11, 8, 17, 22));
  file('docker-compose.yml', 'services:\n  api:\n    image: shop/api:3.4.1\n', 1843, at(11, 12, 9, 28));
  file('notes.md', '# web-01\n', 4710, at(11, 2, 11, 5));
  return host;
}

/// A session's tmux side: attached to [controller] where there is one, off
/// otherwise.
class _TmuxHost extends ChangeNotifier implements TmuxSessionHost {
  _TmuxHost(this.sessionId, [this.controller]);

  @override
  final String sessionId;

  @override
  final TmuxController? controller;

  @override
  TmuxHostStage get stage => controller == null ? TmuxHostStage.idle : TmuxHostStage.attached;

  @override
  bool get active => controller != null;

  @override
  bool get live => controller != null;

  @override
  Future<void> stop() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An app lock with a PIN set.
class _PinLock implements SecurityLockService {
  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's lock, open to begin with.
class _Unlocked extends AppLockNotifier {
  _Unlocked(super.ref) {
    state = false;
  }
}

/// A fixed Squeezed account, without RevenueCat or the backend.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A fixed Juiced account (hosted Cloud), without RevenueCat or the backend.
class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Who a picture is signed in as, unless the test says otherwise: Alex of
/// the demo world (the website's), on Juiced, never a guest.
const _demoAccount = UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex');

/// Health checks that never run (the harness sets the results).
class _Health extends ConnectionHealthNotifier {
  void set(Map<String, HealthCheckResult> m) => state = m;
}

const _hosts = [
  ['web-01', '192.168.10.21', 'deploy'],
  ['web-02', '192.168.10.22', 'deploy'],
  ['mac-studio', '192.168.10.30', 'ops'],
  ['build-runner', '192.168.10.50', 'ci'],
  ['hypervisor-b', '192.168.20.12', 'root'],
  ['hypervisor-a', '192.168.20.11', 'root'],
  ['edge-router', '192.168.20.1', 'root'],
  ['log-store', '192.168.10.24', 'deploy'],
  ['db-primary', '192.168.10.31', 'deploy'],
  ['cache-01', '192.168.10.41', 'deploy'],
  ['monitoring', '192.168.10.60', 'deploy'],
  ['vpn-gateway', '192.168.10.23', 'deploy'],
];

/// The systems of the made-up hosts, as the app keeps what it found out.
const _osKinds = {
  'os_kind_c0': 'ubuntu',
  'os_kind_c1': 'ubuntu',
  'os_kind_c2': 'macos',
  'os_kind_c3': 'debian',
  'os_kind_c4': 'debian',
  'os_kind_c5': 'debian',
  'os_kind_c6': 'openwrt',
  'os_kind_c7': 'rocky',
  'os_kind_c8': 'debian',
  'os_kind_c9': 'alpine',
  'os_kind_c10': 'ubuntu',
  'os_kind_c11': 'alpine',
};

Future<AppDatabase> _seeded() async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final now = DateTime(2026, 9, 24);
  for (var i = 0; i < _hosts.length; i++) {
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: 'c$i',
          label: _hosts[i][0],
          host: _hosts[i][1],
          colorValue: Value(i == 0 ? 0xFFFF7A1A : i == 1 ? 0xFF4F9D69 : null),
          port: const Value(22),
          // Server Monitor watches four of them (see [_monitorStats]).
          monitored: Value(const {0, 1, 7, 8}.contains(i)),
          createdAt: now,
          updatedAt: now,
        ));
  }
  return db;
}

/// Groups with their own colours, and tags, for the Hosts page as the
/// Blueprint draws it (made up).
Future<void> _seedGroupsAndTags(AppDatabase db) async {
  final now = DateTime(2026, 9, 24);
  const groups = {
    'g_web': ('Web', 0xFF4FAE78, ['c0', 'c1']),
    'g_db': ('Databases', 0xFF7AA7E0, ['c8', 'c9']),
    'g_hv': ('Hypervisors', 0xFFA879E8, ['c4', 'c5']),
    'g_net': ('Network', 0xFFE6A23C, ['c6', 'c11']),
  };
  var order = 0;
  for (final g in groups.entries) {
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
          id: g.key,
          name: g.value.$1,
          createdAt: now,
          sortOrder: Value(order++),
          colorValue: Value(g.value.$2),
        ));
    for (final c in g.value.$3) {
      await (db.update(db.connections)..where((t) => t.id.equals(c)))
          .write(ConnectionsCompanion(groupId: Value(g.key), colorValue: const Value(null)));
    }
  }
  final tags = ConnectionTagsDao(db);
  await tags.setTagsForConnection('c0', ['prod', 'nginx']);
  await tags.setTagsForConnection('c1', ['prod']);
  await tags.setTagsForConnection('c8', ['postgres', 'prod']);
  await tags.setTagsForConnection('c3', ['ci']);
  await tags.setTagsForConnection('c11', ['staging']);
}

/// Three saved workspaces (made up).
List<ws_view.WorkspaceView> _demoWorkspaces() {
  ws_view.WorkspaceMemberHost m(String id, String name) => ws_view.WorkspaceMemberHost(
        id: id,
        name: name,
        colorValue: null,
        colorIndex: 0,
        resolvedColor: const Color(0xFF8B919C),
        userAtAddress: 'deploy@$name',
        resolved: true,
      );
  ws_view.WorkspaceView w(String id, String name, int tabs, List<ws_view.WorkspaceMemberHost> hosts, DateTime? at, int i) =>
      ws_view.WorkspaceView(
        id: id,
        name: name,
        tabCount: tabs,
        paneCount: hosts.length,
        memberHosts: hosts,
        lastOpened: at,
        launchShortcutIndex: i,
        panePreview: [
          ws_view.WorkspaceTabPreview(paneColors: [for (final _ in hosts) const Color(0xFF8B919C)]),
        ],
      );
  final now = DateTime.now();
  return [
    w('w1', 'Deploy', 1, [m('c0', 'web-01'), m('c1', 'web-02'), m('c11', 'vpn-gateway')], now.subtract(const Duration(hours: 2)), 0),
    w('w2', 'Database night', 1, [m('c8', 'db-primary'), m('c9', 'cache-01')], now.subtract(const Duration(days: 1)), 1),
    w('w3', 'Morning check', 2, [m('c4', 'hypervisor-b'), m('c5', 'hypervisor-a'), m('c6', 'edge-router'), m('c10', 'monitoring')],
        now.subtract(const Duration(days: 3)), 2),
  ];
}

/// tmux sessions known on some hosts, without a store.
class _Tmux extends TmuxSessionCounts {
  _Tmux(Map<String, int> counts) : super(null) {
    state = counts;
  }
}

/// Server Monitor's last readings for the watched hosts, as its cache holds
/// them: web-01 short of memory, web-02's CPU pinned, log-store's disk full,
/// db-primary's disk filling.
Map<String, Object> _monitorStats() {
  final at = DateTime.now().millisecondsSinceEpoch;
  Map<String, Object> s(double cpu, int ramUsed, double disk) => {
        'cpuPercent': cpu,
        'ramUsedMB': ramUsed,
        'ramTotalMB': 8192,
        'diskPercent': disk,
        'collectedAt': at,
        'source': 'ssh',
      };
  return {
    'cached_server_stats': jsonEncode({
      'c0': s(22, 7946, 61),
      'c1': s(100, 3100, 44),
      'c7': s(18, 2600, 100),
      'c8': s(9, 2100, 82),
    }),
  };
}

/// A terminal with a login banner and a prompt, like a fresh session.
Terminal _terminal(String user, String host, {bool busy = false}) {
  final t = Terminal(maxLines: 1000);
  t.resize(160, 40);
  const g = '\x1b[32m', b = '\x1b[34m', y = '\x1b[33m', r = '\x1b[31m', o = '\x1b[0m';
  final prompt = '$g$user@$host$o:$b~$o\$ ';
  t.write('Welcome to Ubuntu 24.04.3 LTS (GNU/Linux 6.8.0-124-generic x86_64)\r\n\r\n');
  t.write('  System load:  1.44               Processes:        559\r\n');
  t.write('  Usage of /:   66.3% of 123.83GB  Users logged in:  1\r\n');
  t.write('  Memory usage: 70%                Swap usage:       ${y}98%$o\r\n\r\n');
  if (busy) {
    t.write('${prompt}docker compose logs --tail 3 api\r\n');
    t.write('api-1  | listening on :8080\r\n');
    t.write('api-1  | ${r}ERROR: upstream redis refused connection$o\r\n');
    t.write('api-1  | retrying in 2s\r\n');
  }
  t.write(prompt);
  return t;
}

SessionState _session(int i, {bool busy = false, String? id, ShellService? shell}) {
  final h = _hosts[i];
  return SessionState(
    status: SessionStatus.connected,
    connectionId: 'c$i',
    connectionLabel: h[0],
    host: h[1],
    port: 22,
    username: h[2],
    session: TerminalSession(
      id: id ?? 's$i',
      connectionId: 'c$i',
      terminal: _terminal(h[2], h[0].toLowerCase(), busy: busy),
      shell: shell ?? _Shell(),
      startedAt: DateTime(2026, 9, 24, 20, 31),
    ),
  );
}

class _Shell0 {
  _Shell0(this.key, this.container, this.db);
  final GlobalKey key;
  final ProviderContainer container;
  final AppDatabase db;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  _stubPlugins();

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Future<_Shell0> pumpShell(
    WidgetTester tester,
    String themeId, {
    Map<String, Object> prefsExtra = const {},
    Future<void> Function(AppDatabase db)? seed,
    UserProfile? user,
    List<Override> extra = const [],
    bool picture = true,
    Locale? locale,
    Size size = const Size(1440, 900),
    // The app's pages as the app has them (a router, where the lock screen
    // takes the shell's place); the shell alone without it.
    GoRouter? router,
  }) async {
    if (picture) {
      realShadows();
      await tester.runAsync(loadShotFonts);
    }
    SharedPreferences.setMockInitialValues({
      'app_theme_id': themeId,
      // In a picture every host's system is known, as it is once the app has
      // connected to it: the cards show their systems' icons, not the
      // terminal glyph of a host never reached.
      if (picture) ..._osKinds,
      ...prefsExtra,
    });
    final prefs = await SharedPreferences.getInstance();
    final db = await _seeded();
    if (seed != null) await seed(db);
    // Closed after the test, outside its fake clock (inside it, drift's close
    // never finishes).
    addTearDown(db.close);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final theme = BuiltInThemes.getById(themeId);
    AppColors.applyTheme(theme.colorScheme);
    final key = GlobalKey();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      healthChecksEnabledProvider.overrideWith((ref) => false),
      currentUserProvider.overrideWith((_) => user ?? (picture ? _demoAccount : null)),
      if (picture) isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      // The demo account has no photo kept online: nothing is fetched.
      if (picture) syncedAvatarUrlProvider.overrideWith((ref) => SyncedAvatarNotifier()),
      authStateProvider.overrideWith((_) => const Stream.empty()),
      accountSetupNeedsAttentionProvider.overrideWith((_) async => false),
      appThemeIdProvider.overrideWith((ref) => themeId),
      activeSessionsProvider.overrideWith(_Sessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
      // A still clock: its 30-second ticker would outlive the picture.
      syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 9, 24, 21))),
      ...extra,
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: UncontrolledProviderScope(
        container: container,
        child: router != null
            ? MaterialApp.router(
                debugShowCheckedModeBanner: false,
                theme: theme.toThemeData(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                routerConfig: router,
              )
            : MaterialApp(
                debugShowCheckedModeBanner: false,
                theme: theme.toThemeData(),
                locale: locale,
                localizationsDelegates: AppLocalizations.localizationsDelegates,
                supportedLocales: AppLocalizations.supportedLocales,
                home: const DesktopShell(),
              ),
      ),
    ));
    await settle(tester);
    return _Shell0(key, container, db);
  }

  Future<void> tearDownShell(WidgetTester tester, _Shell0 s) async {
    plainShadows();
    await tester.pumpWidget(const SizedBox());
    // Let the few delayed clean-ups the providers schedule (a help-status
    // link kept 5 minutes, the monitor's 60-second grace) run out.
    await tester.pump(const Duration(hours: 7));
  }

  /// Four live sessions, web-01 in front.
  Future<void> openSessions(WidgetTester tester, _Shell0 s) async {
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 4; i++) 's$i': _session(i, busy: i == 0),
    });
    (c.read(connectionHealthProvider.notifier) as _Health).set({
      for (var i = 0; i < 4; i++)
        'c$i': HealthCheckResult(
          status: ConnectionHealth.online,
          latencyMs: 24 + i * 7,
          checkedAt: DateTime(2026, 9, 24, 21),
        ),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final first = tabs.tabContaining('s0');
    if (first != null) tabs.setActiveTab(first.id);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
    c.read(desktopSelectedTabProvider.notifier).state = 0;
    await settle(tester);
  }

  for (final themeId in _shotThemes) {
    testWidgets('desktop shell, $themeId', (tester) async {
      final s = await pumpShell(tester, themeId, prefsExtra: _monitorStats());
      await saveShot(tester, s.key, 'shell-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);

    testWidgets('desktop session, $themeId', (tester) async {
      final s = await pumpShell(tester, themeId, prefsExtra: _terminalOf(themeId));
      await openSessions(tester, s);
      await saveShot(tester, s.key, 'session-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // ── Tablets (4.0): the computer's shell on a large
  // screen, touch sized, as the mockups draw it. ──
  for (final (orientation, size) in [('portrait', _tabletUpright), ('landscape', _tabletSideways)]) {
    testWidgets('tablet $orientation: Hosts', (tester) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final s = await pumpShell(
        tester,
        'default_dark',
        prefsExtra: _monitorStats(),
        size: size,
        seed: _seedGroupsAndTags,
        extra: [ws.workspacesProvider.overrideWithValue(_demoWorkspaces())],
      );
      // Three hosts open (web-01 twice), the Hosts page in front, as the
      // computer's picture has them.
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({
        for (var i = 0; i < 3; i++) 's$i': _session(i),
        's3': _session(0, id: 's3'),
      });
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text('Hosts')).first);
      await settle(tester);
      await saveShot(tester, s.key, 'tablet-hosts-$orientation');
      // A tap on a card opens its panel (web-01, as the landscape mockup).
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('web-01')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      await saveShot(tester, s.key, 'tablet-hosts-panel-$orientation');
      // Its more button: what a right click's menu holds.
      await tester.ensureVisible(find.byKey(const ValueKey('host-card-more-c0')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('host-card-more-c0')));
      await settle(tester);
      await saveShot(tester, s.key, 'tablet-hosts-menu-$orientation');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _tablet);

    // Every page of the rail at tablet size, either way up (4.0).
    testWidgets('tablet $orientation: every page', (tester) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final s = await pumpShell(tester, 'default_dark', prefsExtra: _monitorStats(), size: size, seed: _seedGroupsAndTags);
      for (final section in [
        NavSection.keys,
        NavSection.portForwarding,
        NavSection.networks,
        NavSection.snippets,
        NavSection.triggers,
        NavSection.commandHistory,
        NavSection.automation,
        NavSection.monitor,
      ]) {
        s.container.read(activeSidebarNavProvider.notifier).state = section;
        await settle(tester);
        await saveShot(tester, s.key, 'tablet-${section.name}-$orientation');
      }
      // Settings, its pop-up over the page.
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
      await settle(tester);
      s.container.read(settingsPopupOpenProvider.notifier).state = true;
      await settle(tester);
      await saveShot(tester, s.key, 'tablet-settings-$orientation');
      s.container.read(settingsPopupOpenProvider.notifier).state = false;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _tablet);

    testWidgets('tablet $orientation: a session', (tester) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      final s = await pumpShell(tester, 'default_dark', prefsExtra: _terminalOf('default_dark'), size: size);
      await openSessions(tester, s);
      await saveShot(tester, s.key, 'tablet-session-$orientation');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _tablet);
  }

  for (final themeId in ['default_dark', 'default_light']) {
    testWidgets('Settings, Account and security, $themeId', (tester) async {
      // Signed in with sync set up, as the docs show it: two-step sign-in
      // on, Google and a password to sign in with, three devices. Without
      // these the rows said "Could not check" (nothing is reached in a test).
      FlutterSecureStorage.setMockInitialValues({'sync_setup_complete': 'true'});
      final devices = MockClient((req) async => http.Response(
          jsonEncode({
            'sessions': [
              {'id': 'd1', 'kind': 'session_token', 'platform': 'windows', 'created_at': '2026-09-02T10:00:00Z', 'current': true},
              {'id': 'd2', 'kind': 'registration', 'platform': 'ios', 'created_at': '2026-08-14T08:30:00Z'},
              {'id': 'd3', 'kind': 'session_token', 'platform': 'macos', 'created_at': '2026-07-30T16:20:00Z'},
            ],
          }),
          200));
      final s = await pumpShell(tester, themeId, extra: [
        isSignedInProvider.overrideWithValue(true),
        recoveryCodesApiProvider.overrideWithValue(RecoveryCodesApi(
          client: MockClient((_) async => http.Response(jsonEncode({'two_step': true, 'count': 8}), 200)),
          baseUrl: 'https://cloud.example.dev/v1',
          bearer: () async => 't',
        )),
        signInWaysProvider.overrideWith(
            (ref) async => const SignInWays(email: 'alex@example.com', ways: [SignInWay.google, SignInWay.password])),
        deviceSessionServiceProvider.overrideWithValue(DeviceSessionService(
          api: DeviceSessionsApi(client: devices, baseUrl: 'https://cloud.example.dev/v1', bearer: () async => 't'),
          store: DeviceSessionStore(const FlutterSecureStorage()),
          firebaseUid: () => null,
          sessionToken: () async => null,
          saveSessionToken: (_) async {},
          labels: () async => const DeviceLabels(platform: 'windows'),
        )),
      ]);
      s.container.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.account;
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.settings;
      await settle(tester);
      await saveShot(tester, s.key, 'settings-account-$themeId');
      // The plan's chip beside the person opens the plan popover (4.0,
      // as designed).
      await tester.tap(find.byKey(const ValueKey('account-plan-chip')));
      await settle(tester);
      await saveShot(tester, s.key, 'settings-account-plan-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // Settings is a pop-up over whatever is shown (3.0).
  for (final themeId in ['default_dark', 'default_light']) {
    testWidgets('Settings as a pop-up over a session, $themeId', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final s = await pumpShell(tester, themeId, prefsExtra: _terminalOf(themeId));
      await openSessions(tester, s);
      s.container.read(settingsPopupOpenProvider.notifier).state = true;
      await settle(tester);
      // General with one row's help open, as its mockup
      // draws it (4.0): the pages in their groups, one line a row.
      final l10n = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsInlineCloseToTray}')));
      await settle(tester);
      await saveShot(tester, s.key, 'settings-popup-$themeId');
      await tester.tap(find.byKey(const ValueKey('settings-nav-appearance')));
      await settle(tester);
      await saveShot(tester, s.key, 'settings-popup-appearance-$themeId');
      // Each page of 4.0 that is new or changed.
      for (final page in ['plan', 'keyboard', 'terminal', 'files', 'security', 'data']) {
        await tester.tap(find.byKey(ValueKey('settings-nav-$page')));
        await settle(tester);
        await saveShot(tester, s.key, 'settings-popup-$page-$themeId');
      }
      await tester.enterText(find.byKey(const ValueKey('settings-search')), 'font');
      await settle(tester);
      await saveShot(tester, s.key, 'settings-popup-search-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // Approving a new device (3.0): the Devices row, then
  // both dialogs, against the stand-in server.
  // The row is a team feature: these run with --dart-define=ZEST_ORCHARDS=true.
  for (final themeId in ['default_dark', 'default_light']) {
    testWidgets('Approving a new device, $themeId', (tester) async {
      FlutterSecureStorage.setMockInitialValues({'sync_setup_complete': 'true'});
      final server = FakeApprovalServer();
      final list = MockClient((req) async => http.Response(
          jsonEncode({
            'sessions': [
              {'id': 'd1', 'kind': 'session_token', 'platform': 'windows', 'created_at': '2026-09-02T10:00:00Z', 'current': true},
              {'id': 'd2', 'kind': 'registration', 'platform': 'ios', 'created_at': '2026-08-14T08:30:00Z'},
            ],
          }),
          200));
      final s = await pumpShell(tester, themeId,
          user: const UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex'),
          extra: [
            deviceApprovalsApiProvider.overrideWithValue(server.device('desktop')),
            deviceSessionServiceProvider.overrideWithValue(DeviceSessionService(
              api: DeviceSessionsApi(client: list, baseUrl: 'https://cloud.test/v1', bearer: () async => 't'),
              store: DeviceSessionStore(const FlutterSecureStorage()),
              firebaseUid: () => null,
              sessionToken: () async => null,
              saveSessionToken: (_) async {},
              labels: () async => const DeviceLabels(platform: 'windows'),
            )),
          ]);
      s.container.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.account;
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.settings;
      await settle(tester);
      final row = find.byKey(const ValueKey('devices-approve'));
      await tester.ensureVisible(row);
      await settle(tester);
      await saveShot(tester, s.key, 'devices-approve-$themeId');

      final phone = (await tester.runAsync(() => ApprovalAsk.start(server.device('phone'), name: 'Android')))!;
      await tester.tap(row);
      await settle(tester);
      await saveShot(tester, s.key, 'approve-who-$themeId');

      final l10n = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.text(l10n.approveContinue));
      await settle(tester);
      await tester.runAsync(() => phone.awaitApprover(wait: (_) async {}));
      await tester.pump(kDeviceApprovalPoll);
      await settle(tester);
      await saveShot(tester, s.key, 'approve-words-$themeId');
      await tester.tap(find.text(l10n.approveNoMatch));
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots || !kOrchardsEnabled, variant: _computer);

    testWidgets('Set up sync on a second device, $themeId', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = MemoryStoreBackend(MemoryStore());
      await tester.runAsync(() async {
        final salt = SyncService.generateSalt();
        final dek = SyncService.generateDek();
        const fast = {'memory': 65536, 'iterations': 3, 'parallelism': 4};
        final mek = await SyncService.deriveKey('the sync password', salt, params: fast);
        await store.push(
          data: const {'connections': []},
          dek: dek,
          salt: salt,
          verificationHash: await SyncService.computeVerificationHash(mek),
          wrappedDekPassword: await SyncService.wrapDek(dek, mek),
          createOnly: true,
          argon2Params: fast,
        );
      });
      final s = await pumpShell(tester, themeId,
          user: const UserProfile(uid: 'uid-alex', email: 'alex@example.com', displayName: 'Alex'),
          extra: [syncBackendProvider.overrideWithValue(store)]);
      s.container.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.account;
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.settings;
      await settle(tester);
      final l10n = lookupAppLocalizations(const Locale('en'));
      final setUp = find.text(l10n.accountSyncSetUp);
      await tester.ensureVisible(setUp);
      await tester.tap(setUp);
      await settle(tester);
      await saveShot(tester, s.key, 'unlock-approve-$themeId');
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);

    testWidgets('The new device asks, $themeId', (tester) async {
      final server = FakeApprovalServer();
      final s = await pumpShell(tester, themeId, extra: [
        deviceApprovalsApiProvider.overrideWithValue(server.device('laptop')),
      ]);
      final context = tester.element(find.byType(DesktopShell));
      showAskForApproval(context);
      await settle(tester);
      await saveShot(tester, s.key, 'ask-waiting-$themeId');
      final give = (await tester.runAsync(
          () => ApprovalGive.answer(server.device('desktop'), server.rows.keys.single)))!;
      await tester.pump(kDeviceApprovalPoll);
      await settle(tester);
      await tester.runAsync(() => give.awaitReveal(wait: (_) async {}));
      await saveShot(tester, s.key, 'ask-words-$themeId');
      await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).cancel).last);
      await settle(tester);
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  testWidgets('Hosts page with a host open in the panel', (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      prefsExtra: _monitorStats(),
      seed: (db) async {
        await db.knownHostsDao.upsertHost(KnownHostsCompanion.insert(
          id: 'kh0',
          host: '192.168.10.21',
          port: 22,
          keyType: 'ssh-ed25519',
          fingerprint: 'SHA256:Qm4Lr8Tz2Nw0Pv6Ks1Hc9YbV3xE7uJ5aD2fG8hK1mQ',
          publicKeyBase64: 'AAAA',
          firstSeen: DateTime(2026, 3, 14),
          lastSeen: DateTime(2026, 9, 24),
        ));
      },
    );
    await tester.tap(find.text('web-01').first);
    await settle(tester);
    await saveShot(tester, s.key, 'hosts-panel-default_dark');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  // Every page the rail reaches, in Graphite, for comparing with the
  // Blueprint page by page (3.0).
  testWidgets('every rail page, graphite', (tester) async {
    final s = await pumpShell(tester, 'graphite', prefsExtra: _monitorStats(), seed: _seedGroupsAndTags);
    final l10n = lookupAppLocalizations(const Locale('en'));
    final pages = {
      'keys': l10n.narrowSidebarKeys,
      'forwards': l10n.narrowSidebarPortForwarding,
      'networks': l10n.narrowSidebarNetworks,
      'snippets': l10n.narrowSidebarSnippets,
      'triggers': l10n.narrowSidebarTriggers,
      'history': l10n.narrowSidebarHistory,
      'automation': l10n.narrowSidebarAutomation,
      'monitor': l10n.desktopServerMonitor,
      'settings': l10n.narrowSidebarSettings,
    };
    for (final p in pages.entries) {
      await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text(p.value)).first);
      await settle(tester);
      await saveShot(tester, s.key, 'page-${p.key}-graphite');
    }
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  // The Keys page with nothing saved (4.0): its ways to
  // start, then a key file dragged over it, the page lit.
  // History before Squeezed (4.0): the page in use,
  // faded, with made-up commands, behind what it gives and its price.
  for (final themeId in const ['default_dark', 'default_light']) {
    testWidgets('History before Squeezed, $themeId', (tester) async {
      final s = await pumpShell(tester, themeId, prefsExtra: _monitorStats());
      final l10n = lookupAppLocalizations(const Locale('en'));
      await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text(l10n.narrowSidebarHistory)).first);
      await settle(tester);
      await saveShot(tester, s.key, 'locked-history-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  testWidgets('the Keys page with nothing saved, and a key file dragged over it, graphite', (tester) async {
    final s = await pumpShell(tester, 'graphite', prefsExtra: _monitorStats());
    final l10n = lookupAppLocalizations(const Locale('en'));
    await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text(l10n.narrowSidebarKeys)).first);
    await settle(tester);
    await saveShot(tester, s.key, 'keys-empty-graphite');
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final call in const [
      MethodCall('entered', [820.0, 520.0]),
      MethodCall('updated', [820.0, 520.0]),
    ]) {
      await messenger.handlePlatformMessage('desktop_drop', const StandardMethodCodec().encodeMethodCall(call), (_) {});
    }
    await settle(tester);
    await saveShot(tester, s.key, 'keys-drop-graphite');
    await messenger.handlePlatformMessage(
        'desktop_drop', const StandardMethodCodec().encodeMethodCall(const MethodCall('exited')), (_) {});
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  // The Hosts page as designed (3.0):
  // groups with their own colours, tags, workspaces,
  // open sessions and a tmux badge, all made up.
  for (final themeId in const ['graphite', 'default_dark', 'default_light']) {
    testWidgets('Hosts page, the Blueprint one, $themeId', (tester) async {
      final s = await pumpShell(
        tester,
        themeId,
        prefsExtra: _monitorStats(),
        seed: _seedGroupsAndTags,
        extra: [
          ws.workspacesProvider.overrideWithValue(_demoWorkspaces()),
          tmuxSessionCountsProvider.overrideWith((ref) => _Tmux({'c0': 2})),
        ],
      );
      // Three hosts open (web-01 twice: its card says "2 open"), the Hosts
      // page in front.
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({
        for (var i = 0; i < 3; i++) 's$i': _session(i),
        's3': _session(0, id: 's3'),
      });
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text('Hosts')).first);
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-$themeId');
      // The plan's chip at the rail's foot, open (4.0, the plan popover).
      await tester.tap(find.byKey(const ValueKey('plan-chip')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-plan-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      // The band's Sort, with Active first under the sorts (4.0).
      await tester.tap(find.byKey(const ValueKey('hosts-sort')));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      await saveShot(tester, s.key, 'hosts-blueprint-sort-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('db-primary')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-panel-$themeId');
      await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-list-$themeId');
      await tester.tap(find.byKey(const ValueKey('hosts-view-cards')));
      await tester.tap(find.byKey(const ValueKey('hosts-new-menu')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-newmenu-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hosts-filter')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-filter-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      // New group: every group in view, the new one's name and colour ready.
      await tester.tap(find.byKey(const ValueKey('group-tile-new')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-blueprint-groups-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // The Hosts page's bulk selection, host panel, host menu, editor and
  // drawer, as designed (all made up).
  for (final themeId in const ['graphite', 'default_light']) {
    testWidgets('Hosts page, selection, panel, menu, editor and drawer, $themeId', (tester) async {
      final s = await pumpShell(
        tester,
        themeId,
        prefsExtra: _monitorStats(),
        seed: (db) async {
          await _seedGroupsAndTags(db);
          final now = DateTime.now();
          // db-primary: a port forward, a note, and two sessions of commands.
          await db.into(db.portForwardRules).insert(PortForwardRulesCompanion.insert(
                id: 'pf-db',
                connectionId: 'c8',
                type: 'local',
                bindPort: 5432,
                remoteHost: 'localhost',
                remotePort: 5432,
                label: const Value('Postgres'),
                createdAt: now,
              ));
          await (db.update(db.connections)..where((t) => t.id.equals('c8')))
              .write(ConnectionsCompanion(note: const Value('Primary for the shop; replica on cache-01.'),
                  lastConnected: Value(now.subtract(const Duration(days: 1)))));
          var n = 0;
          for (final t in [
            now.subtract(const Duration(days: 1, hours: 2)),
            now.subtract(const Duration(days: 1, hours: 1, minutes: 35)),
            now.subtract(const Duration(days: 4, hours: 3)),
            now.subtract(const Duration(days: 4, hours: 2, minutes: 50)),
          ]) {
            await db.into(db.commandHistory).insert(CommandHistoryCompanion.insert(
                  id: 'cmd${n++}',
                  command: 'psql -c "select 1"',
                  connectionId: const Value('c8'),
                  createdAt: t,
                ));
          }
        },
        extra: [
          ws.workspacesProvider.overrideWithValue(_demoWorkspaces()),
          tmuxSessionCountsProvider.overrideWith((ref) => _Tmux({'c0': 2})),
        ],
      );
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({
        for (var i = 0; i < 3; i++) 's$i': _session(i),
      });
      // db-primary's last reading, with its mounts, its load and how long it is up.
      s.container.read(serverStatsProvider.notifier).commitSshStats(
            'c8',
            ServerStats(
              cpuPercent: 14,
              ramUsedMB: 7290,
              ramTotalMB: 8192,
              diskPercent: 62,
              loadAverage: const [0.42, 0.38, 0.31],
              uptimeSeconds: 41 * 86400,
              filesystems: const [
                FilesystemUsage(mount: '/', usedBytes: 62, totalBytes: 100, usedPercent: 62),
                FilesystemUsage(mount: '/boot', usedBytes: 91, totalBytes: 100, usedPercent: 91),
              ],
              collectedAt: DateTime.now().subtract(const Duration(seconds: 30)),
              source: MetricSource.ssh,
            ),
          );
      await settle(tester);
      await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text('Hosts')).first);
      await settle(tester);
      // Five hosts selected: the cards' boxes, the bar and its hint.
      s.container.read(hostMultiSelectProvider.notifier).selectAll(['c0', 'c1', 'c8', 'c4', 'c5']);
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-select-grid-$themeId');
      await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-select-list-$themeId');
      await tester.tap(find.byKey(const ValueKey('hosts-view-cards')));
      s.container.read(hostMultiSelectProvider.notifier).exit();
      await settle(tester);
      // db-primary's panel: its health with an alert, its sessions, its
      // forward, how it connects, its note.
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('db-primary')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-panel-full-$themeId');
      await tester.tap(find.byKey(const ValueKey('host-panel-alert-ram')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-panel-alert-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      // A host Server monitor does not watch: Watch this host.
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('build-runner')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-panel-unwatched-$themeId');
      // Its right-click menu, and its Health submenu near the window's edge.
      await tester.tapAt(tester.getCenter(find.descendant(of: find.byType(HostCard), matching: find.text('db-primary'))),
          buttons: kSecondaryButton);
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-menu-$themeId');
      // Organize and Tools, each open (4.0: the menu grouped).
      await tester.tap(find.byKey(const ValueKey('host-menu-organize')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-menu-organize-$themeId');
      await tester.tap(find.byKey(const ValueKey('host-menu-tools')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-menu-tools-$themeId');
      await tester.tap(find.byKey(const ValueKey('host-menu-health')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-menu-health-$themeId');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      // The editor in the panel's place.
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('db-primary')));
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('host-panel-edit')));
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-editor-$themeId');
      await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).connectionEditRailAdvanced).first);
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-editor-advanced-$themeId');
      s.container.read(connectionEditorTargetProvider.notifier).state = null;
      await settle(tester);
      // The drawer (beside another page: the Hosts page hides it), with a
      // selection and its bar.
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.keys;
      s.container.read(hostPanelVisibleProvider.notifier).state = true;
      s.container.read(hostMultiSelectProvider.notifier).selectAll(['c8', 'c9']);
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-drawer-select-$themeId');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // New host open in a window 1200 or 1024 wide (seen on a
  // device): the Hosts page behind it was squeezed to about 290 wide,
  // its toolbar on three rows and the empty page's cards one word a line. The
  // page keeps room for its toolbar and cards: the editor narrows beside it,
  // down to its least width, and below that it lies over the page.
  for (final width in const [1200.0, 1024.0]) {
    for (final empty in const [true, false]) {
      testWidgets('New host beside the Hosts page, ${width.toInt()} wide${empty ? ', no hosts' : ''}', (tester) async {
        final s = await pumpShell(
          tester,
          'graphite',
          size: Size(width, 800),
          seed: empty ? (db) => db.delete(db.connections).go() : null,
        );
        final c = s.container;
        c.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
        await settle(tester);
        c.read(connectionEditorTargetProvider.notifier).state = const ConnectionEditorTarget();
        await settle(tester);
        final page = tester.getRect(find.byType(HostsHomePage));
        final editor = tester.getRect(find.byType(ConnectionEditScreen));
        final band = tester.getRect(find.byType(HostsBand));
        expect(page.width, greaterThanOrEqualTo(kHostsPageMinWidth), reason: 'the page keeps room for its toolbar');
        // Two rows: the buttons and the field, then the views, Sort and Filter
        // (the device run had three, each 34 high and 8 apart, and more).
        expect(band.height, lessThan(110), reason: 'the toolbar on two rows');
        expect(editor.right, width, reason: 'the editor whole, at the right');
        expect(editor.width, greaterThanOrEqualTo(kConnectionEditorMinWidth));
        if (width == 1200) {
          expect(page.right, lessThanOrEqualTo(editor.left), reason: 'beside the page at 1200');
        } else {
          expect(editor.left, lessThan(page.right), reason: 'over the page at 1024: beside it the page had too little');
        }
        if (empty) {
          // The empty page's cards: each title on one line.
          final title = find.text(lookupAppLocalizations(const Locale('en')).firstRunScanTitle);
          expect(tester.getSize(title).height, lessThan(24));
        }
        if (_shots) await saveShot(tester, s.key, 'hosts-new-host-${width.toInt()}${empty ? '-empty' : ''}');
        if (width == 1200 && empty) {
          // The window narrowed across the line: the editor goes over the page
          // with what was typed in it kept.
          await tester.enterText(
              find.descendant(of: find.byType(ConnectionEditScreen), matching: find.byType(TextField)).first, 'db-new');
          tester.view.physicalSize = const Size(1024, 800);
          await settle(tester);
          expect(tester.getRect(find.byType(ConnectionEditScreen)).left,
              lessThan(tester.getRect(find.byType(HostsHomePage)).right));
          expect(
              tester
                  .widget<EditableText>(find
                      .descendant(of: find.byType(ConnectionEditScreen), matching: find.byType(EditableText))
                      .first)
                  .controller
                  .text,
              'db-new');
        }
        c.read(connectionEditorTargetProvider.notifier).state = null;
        await tearDownShell(tester, s);
      }, variant: _computer);
    }
  }

  // The Hosts page's toolbar and its list, as
  // designed (all made up): one toolbar row, the list sorted by health
  // (a warning, a critical, a muted metric, plain readings), the compact
  // grid, the New host menu, the column picker, folded sections, and a
  // narrower window with the panel open.
  for (final themeId in const ['graphite', 'default_light']) {
    for (final size in const [Size(1440, 900), Size(1366, 768)]) {
      testWidgets('Hosts page toolbar and list, $themeId, ${size.width.toInt()}', (tester) async {
        final at = DateTime.now().millisecondsSinceEpoch;
        Map<String, Object> st(double cpu, int ramUsed, double disk) => {
              'cpuPercent': cpu,
              'ramUsedMB': ramUsed,
              'ramTotalMB': 8192,
              'diskPercent': disk,
              'collectedAt': at,
              'source': 'ssh',
            };
        final w = size.width.toInt();
        final s = await pumpShell(
          tester,
          themeId,
          size: size,
          prefsExtra: {
            'cached_server_stats': jsonEncode({
              'c0': st(22, 5900, 61),
              'c1': st(12, 3100, 44),
              'c2': st(9, 2000, 38),
              'c3': st(41, 4100, 52),
              'c4': st(18, 5900, 47),
              'c5': st(23, 7400, 58),
              'c6': st(6, 900, 21),
              'c7': st(18, 2600, 93),
              'c8': st(9, 2100, 97),
              'c9': st(11, 3300, 29),
              'c10': st(31, 4300, 64),
              'c11': st(4, 700, 18),
            }),
            // db-primary's disk alerts muted by its person.
            'monitor_host_alert_prefs_v1': jsonEncode({
              'c8': {
                'silences': {'disk': {'kind': 'mute'}},
              },
            }),
          },
          seed: (db) async {
            await _seedGroupsAndTags(db);
            final now = DateTime.now();
            const ago = [
              Duration(minutes: 0), Duration(hours: 2), Duration(days: 1, hours: 3), Duration(days: 6),
              Duration(days: 2), Duration(days: 2, hours: 5), Duration(hours: 5), Duration(days: 14),
              Duration(hours: 26), Duration(days: 3), Duration(days: 40), Duration(hours: 2),
            ];
            for (var i = 0; i < _hosts.length; i++) {
              await (db.update(db.connections)..where((t) => t.id.equals('c$i'))).write(ConnectionsCompanion(
                monitored: const Value(true),
                lastConnected: Value(now.subtract(ago[i])),
              ));
            }
          },
          extra: [
            ws.workspacesProvider.overrideWithValue(_demoWorkspaces()),
            tmuxSessionCountsProvider.overrideWith((ref) => _Tmux({'c0': 2})),
          ],
        );
        (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({
          for (var i = 0; i < 2; i++) 's$i': _session(i),
        });
        await settle(tester);
        await tester.tap(find.descendant(of: find.byType(NarrowSidebar), matching: find.text('Hosts')).first);
        await settle(tester);
        await saveShot(tester, s.key, 'hosts-tb-grid-$themeId-$w');
        // The list, sorted by health from its head.
        await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
        await settle(tester);
        await tester.tap(find.byKey(const ValueKey('hosts-head-health')));
        await settle(tester);
        await saveShot(tester, s.key, 'hosts-tb-list-health-$themeId-$w');
        if (size.width == 1440) {
          await tester.tap(find.byKey(const ValueKey('hosts-columns')));
          await settle(tester);
          await saveShot(tester, s.key, 'hosts-tb-columns-$themeId-$w');
          await tester.tap(find.byKey(const ValueKey('hosts-columns')));
          await settle(tester);
          await tester.tap(find.byKey(const ValueKey('hosts-new-menu')));
          await settle(tester);
          await saveShot(tester, s.key, 'hosts-tb-newmenu-$themeId-$w');
          await tester.sendKeyEvent(LogicalKeyboardKey.escape);
          await settle(tester);
          // Workspaces and groups folded away, the compact grid.
          await tester.tap(find.byKey(const ValueKey('hosts-fold-workspaces')));
          await tester.tap(find.byKey(const ValueKey('hosts-fold-groups')));
          await tester.tap(find.byKey(const ValueKey('hosts-view-compact')));
          await settle(tester);
          await saveShot(tester, s.key, 'hosts-tb-compact-folded-$themeId-$w');
        } else {
          // A host open in the panel beside the list: the toolbar on two rows.
          await tester.tap(find.byKey(const ValueKey('hosts-row-c8')));
          await settle(tester);
          await saveShot(tester, s.key, 'hosts-tb-list-panel-$themeId-$w');
        }
        await tearDownShell(tester, s);
      }, skip: !_shots, variant: _computer);
    }
  }

  // The toolbar and the list in a longer language, at 1366 and 1100 wide.
  for (final width in const [1366.0, 1100.0]) {
    testWidgets('Hosts page toolbar and list in German, ${width.toInt()}', (tester) async {
      final s = await pumpShell(
        tester,
        'graphite',
        size: Size(width, 768),
        locale: const Locale('de'),
        prefsExtra: {..._monitorStats(), 'hosts_view_mode': 'list'},
        seed: _seedGroupsAndTags,
      );
      s.container.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
      await settle(tester);
      await saveShot(tester, s.key, 'hosts-tb-list-de-${width.toInt()}');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  // The SFTP dock (4.0): web-01's
  // files in one pane, at the bottom and on the right with an upload under
  // way; then web-01's connection dropped (at 09:41 today), the dock saying
  // so with Reconnect.
  for (final themeId in ['default_dark', 'default_light']) {
    testWidgets('desktop session with the SFTP dock, bottom, right, then dropped, $themeId', (tester) async {
      final s = await pumpShell(tester, themeId);
      await openSessions(tester, s);
      final c = s.container;
      // web-01's connection is one SFTP opens on: its files are listed.
      final files = _deployHome();
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      live.set({...live.state, 's0': _session(0, busy: true, shell: _SftpShell(files.client))});
      await settle(tester);
      final tree = c.read(paneTreeProvider.notifier);
      tree.initSinglePane('s0');
      final leaf = c.read(paneTreeProvider)!.allLeaves.first.id;
      tree.splitPaneWithSftp(leaf, Axis.horizontal, 's0');
      await settle(tester);
      expect(find.text('backups'), findsOneWidget);
      await saveShot(tester, s.key, 'sftp-dock-bottom-$themeId');

      c.read(sftpDockPrefsProvider.notifier).setSide(SftpDockSide.right);
      // An upload under way, as one from Upload is.
      c.read(sftpTransfersProvider.notifier).add(TransferItem(
            id: 'up-compose',
            localPath: 'C:/Users/alex/Projects/shop/docker-compose.yml',
            remotePath: '/home/deploy/docker-compose.yml',
            fileName: 'docker-compose.yml',
            direction: TransferDirection.upload,
            totalBytes: 1843,
            transferredBytes: 1180,
            status: TransferStatus.active,
            srcSide: 0,
            dstSide: 1,
          ));
      await settle(tester);
      // Activity open, with the upload's own row.
      await tester.tap(find.text('Activity'));
      await settle(tester);
      await saveShot(tester, s.key, 'sftp-dock-right-$themeId');

      // Its connection dropped: the dock says so, and when.
      final now = DateTime.now();
      live.dropTime = DateTime(now.year, now.month, now.day, 9, 41);
      live.set({
        ...live.state,
        's0': SessionState.disconnected(
          connectionId: 'c0',
          connectionLabel: 'web-01',
          host: '192.168.10.21',
          port: 22,
          dropped: true,
          dropCause: hostClosedConnection,
        ),
      });
      await settle(tester);
      expect(find.text('web-01 is disconnected'), findsOneWidget);
      await saveShot(tester, s.key, 'sftp-dock-off-$themeId');
      c.read(sftpTransfersProvider.notifier).remove('up-compose');
      await tearDownShell(tester, s);
    }, skip: !_shots, variant: _computer);
  }

  for (final themeId in ['default_dark', 'default_light']) {
  testWidgets('desktop session with the Inspector, Tools then Session, $themeId', (tester) async {
    final collected = DateTime(2026, 9, 24, 21, 4).millisecondsSinceEpoch;
    final s = await pumpShell(
      tester,
      themeId,
      prefsExtra: {
        'command_history_enabled': true,
        // Run on this device: the Tools tab fills up with the most run.
        'snippet_usage_v1': jsonEncode({
          'sn3': {'runCount': 14, 'lastRunAt': DateTime(2026, 9, 24, 20).millisecondsSinceEpoch},
        }),
        'cached_server_stats': jsonEncode({
          'c0': {
            'cpuPercent': 37.0,
            'ramUsedMB': 5734,
            'ramTotalMB': 8192,
            'diskPercent': 66.3,
            'uptime': '12 days',
            'loadAverage': [1.44, 1.21, 0.98],
            'collectedAt': collected,
            'source': 'ssh',
          },
        }),
      },
      seed: (db) async {
        final now = DateTime(2026, 9, 24);
        // The first three have web-01 (c0) as their default host; the
        // last is run most.
        const snippets = [
          ['Running containers', 'docker ps', 'c0'],
          ['Container logs', r'docker logs ${CONTAINER} --tail ${LINES:-50}', 'c0'],
          ['Restart service', r'sudo systemctl restart ${SERVICE}', 'c0'],
          ['Disk usage', 'df -h /', null],
        ];
        for (var i = 0; i < snippets.length; i++) {
          await db.into(db.snippets).insert(SnippetsCompanion.insert(
                id: 'sn$i',
                label: snippets[i][0]!,
                command: snippets[i][1]!,
                metadata: Value(snippets[i][2] == null
                    ? null
                    : encodeSnippetMetadata(SnippetMetadata(defaultConnectionId: snippets[i][2]))),
                createdAt: now,
                updatedAt: now,
              ));
        }
        const history = ['docker compose up -d', 'npm run test', 'sudo apt install tmux', 'systemctl status nginx'];
        for (var i = 0; i < history.length; i++) {
          await db.commandHistoryDao.record(
            command: history[i],
            connectionId: 'c0',
            hostLabel: 'web-01',
            at: DateTime(2026, 9, 24, 21, 40 - i * 7),
          );
        }
        await (db.update(db.commandHistory)..where((t) => t.command.equals('npm run test')))
            .write(const CommandHistoryCompanion(exitCode: Value(1)));
        await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
              id: 'pf-grafana',
              connectionId: 'c0',
              type: 'local',
              bindPort: 3000,
              remoteHost: '127.0.0.1',
              remotePort: 3000,
              label: const Value('Grafana'),
              createdAt: now,
            ));
        await db.portForwardRulesDao.insertRule(PortForwardRulesCompanion.insert(
              id: 'pf-pg',
              connectionId: 'c0',
              type: 'local',
              bindPort: 5433,
              remoteHost: 'db-primary.internal',
              remotePort: 5432,
              label: const Value('Postgres'),
              createdAt: now,
            ));
      },
    );
    await openSessions(tester, s);
    s.container.read(activeForwardIdsProvider.notifier).state = {'pf-grafana'};
    s.container.read(sessionSlidePanelVisibleProvider.notifier).state = true;
    await settle(tester);
    await saveShot(tester, s.key, 'inspector-tools-$themeId');
    s.container.read(inspectorTabProvider.notifier).state = InspectorTab.session;
    await settle(tester);
    await saveShot(tester, s.key, 'inspector-session-$themeId');
    s.container.read(inspectorTabProvider.notifier).state = InspectorTab.appearance;
    await settle(tester);
    await saveShot(tester, s.key, 'inspector-appearance-$themeId');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);
  }

  testWidgets('desktop split with broadcast and the Layout popover', (tester) async {
    final s = await pumpShell(tester, 'default_dark');
    await openSessions(tester, s);
    final c = s.container;
    // One tab holding all four, in a 2x2 grid.
    final tabs = c.read(workTabsProvider.notifier);
    final dest = tabs.tabContaining('s0')!.id;
    for (final sid in ['s1', 's2', 's3']) {
      final t = tabs.tabContaining(sid);
      if (t != null && t.id != dest) tabs.mergeTabs(t.id, dest);
    }
    tabs.setActiveTab(dest);
    PaneLeaf leaf(String sid) => PaneLeaf(sessionIds: [sid]);
    c.read(paneTreeProvider.notifier).setTree(PaneSplit(
          first: PaneSplit(first: leaf('s0'), second: leaf('s3'), axis: Axis.horizontal),
          second: PaneSplit(first: leaf('s1'), second: leaf('s2'), axis: Axis.horizontal),
          axis: Axis.vertical,
        ));
    final firstLeaf = c.read(paneTreeProvider)!.allLeaves.first.id;
    c.read(focusedPaneProvider.notifier).state = firstLeaf;
    expect(c.read(broadcastModeProvider.notifier).startTab(dest), isTrue);
    await settle(tester);
    await saveShot(tester, s.key, 'split-default_dark');

    await tester.tap(find.text('Layout').first);
    await settle(tester);
    await saveShot(tester, s.key, 'layout-popover-default_dark');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  testWidgets('broadcast: its button and pop-over, a pane left out, a tab of sixteen, the host picker', (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    await openSessions(tester, s);
    final c = s.container;
    final tabs = c.read(workTabsProvider.notifier);
    final dest = tabs.tabContaining('s0')!.id;
    for (final sid in ['s1', 's2', 's3']) {
      tabs.mergeTabs(tabs.tabContaining(sid)!.id, dest);
    }
    tabs.setActiveTab(dest);
    final broadcast = c.read(broadcastModeProvider.notifier);
    expect(broadcast.startTab(dest), isTrue);
    broadcast.setReceiving(dest, 's2', false);
    await settle(tester);
    await saveShot(tester, s.key, 'broadcast-panes-default_dark');

    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await settle(tester);
    await saveShot(tester, s.key, 'broadcast-popover-default_dark');

    await tester.tap(find.byKey(const ValueKey('broadcast-choose-hosts')));
    await settle(tester);
    for (final name in ['log-store', 'db-primary', 'cache-01']) {
      await tester.tap(find.descendant(of: find.byType(BroadcastToHostsDialog), matching: find.text(name)));
      await settle(tester);
    }
    await saveShot(tester, s.key, 'broadcast-hosts-default_dark');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Sixteen in one tab: every host named whole on its pane.
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 16; i++) 'n$i': _session(i % _hosts.length, id: 'n$i'),
    });
    await tester.pump();
    final big = tabs.tabContaining('n0')!.id;
    for (var i = 1; i < 16; i++) {
      tabs.mergeTabs(tabs.tabContaining('n$i')!.id, big);
    }
    tabs.setActiveTab(big);
    expect(broadcast.startTab(big), isTrue);
    await settle(tester);
    await saveShot(tester, s.key, 'broadcast-sixteen-default_dark');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  // The Broadcast pop-over with its risky command switch:
  // on, as a new install has it, and off, which says so in amber.
  for (final themeId in ['default_dark', 'default_light']) {
  testWidgets('the Broadcast pop-over and its risky command switch, $themeId', (tester) async {
    final s = await pumpShell(tester, themeId, extra: [isProProvider.overrideWith((ref) => _Pro(true))]);
    await openSessions(tester, s);
    final c = s.container;
    final tabs = c.read(workTabsProvider.notifier);
    final dest = tabs.tabContaining('s0')!.id;
    for (final sid in ['s1', 's2']) {
      tabs.mergeTabs(tabs.tabContaining(sid)!.id, dest);
    }
    tabs.setActiveTab(dest);
    expect(c.read(broadcastModeProvider.notifier).startTab(dest), isTrue);
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await settle(tester);
    await saveShot(tester, s.key, 'broadcast-popover-on-$themeId');
    await tester.tap(find.byKey(const ValueKey('broadcast-risky-switch')));
    await settle(tester);
    expect(c.read(dangerousCommandProtectionProvider), isFalse);
    await saveShot(tester, s.key, 'broadcast-popover-riskyoff-$themeId');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);
  }

  testWidgets('five tabs joined one by one, and what the Layout popover offers them', (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 5; i++) 's$i': _session(i, busy: i == 0),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final dest = tabs.tabContaining('s0')!.id;
    for (var i = 1; i < 5; i++) {
      tabs.mergeTabs(tabs.tabContaining('s$i')!.id, dest);
    }
    tabs.setActiveTab(dest);
    c.read(focusedPaneProvider.notifier).state = c.read(paneTreeProvider)!.allLeaves.first.id;
    await settle(tester);
    await saveShot(tester, s.key, 'grid-five-default_dark');

    await tester.tap(find.text('Layout').first);
    await settle(tester);
    await saveShot(tester, s.key, 'layout-popover-five-default_dark');
    await tester.tapAt(const Offset(40, 400));
    await settle(tester);

    // An arrangement someone chose, then one more terminal: the stack grows.
    tabs.arrangeTab(dest, LayoutPreset.oneAndFour);
    await settle(tester);
    await saveShot(tester, s.key, 'one-and-four-default_dark');
    await tearDownShell(tester, s);
  }, skip: !_shots, variant: _computer);

  // No picture, always on: the computer's shell on a tablet (4.0).
  group('on a tablet', () {
    Future<_Shell0> pumpTablet(WidgetTester tester, Size size) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      return pumpShell(tester, 'default_dark', picture: false, size: size);
    }

    testWidgets('upright: the session tabs in a strip under the app bar, only while sessions are open', (tester) async {
      final s = await pumpTablet(tester, _tabletUpright);
      expect(find.byKey(const ValueKey('session-tab-strip')), findsNothing);
      expect(tester.getSize(find.byType(PillBar).first).height, 60, reason: "the app bar, a finger's height");
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's1': _session(1)});
      await settle(tester);
      final strip = find.byKey(const ValueKey('session-tab-strip'));
      expect(strip, findsOneWidget);
      expect(find.descendant(of: strip, matching: find.text('web-02')), findsOneWidget);
      // Each tab 44 high to a finger.
      expect(tester.getSize(find.ancestor(of: find.text('web-02'), matching: find.byType(Container)).first).height,
          greaterThanOrEqualTo(44));
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({});
      await settle(tester);
      expect(find.byKey(const ValueKey('session-tab-strip')), findsNothing);
      await tearDownShell(tester, s);
    }, variant: _tablet);

    testWidgets("sideways: the host's panel beside the list, its tests as 48 high rows, its metrics' limits marked",
        (tester) async {
      final s = await pumpTablet(tester, _tabletSideways);
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('web-01')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byKey(const ValueKey('host-panel-sheet')), findsNothing, reason: 'beside the list, not over it');
      expect(find.byKey(const ValueKey('host-panel-primary')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('host-panel-test-reachability'))).height, 48);
      expect(tester.getSize(find.byKey(const ValueKey('host-panel-test-full'))).height, 48);
      expect(find.byKey(const ValueKey('host-panel-more')), findsOneWidget);
      await tearDownShell(tester, s);
    }, variant: _tablet);

    testWidgets('sideways: the tabs in the app bar, no strip', (tester) async {
      final s = await pumpTablet(tester, _tabletSideways);
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's1': _session(1)});
      await settle(tester);
      expect(find.byKey(const ValueKey('session-tab-strip')), findsNothing);
      expect(find.descendant(of: find.byType(PillBar), matching: find.text('web-02')), findsOneWidget);
      await tearDownShell(tester, s);
    }, variant: _tablet);

    testWidgets("a tab's long press opens what its right click does", (tester) async {
      final s = await pumpTablet(tester, _tabletSideways);
      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's1': _session(1)});
      await settle(tester);
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.pillRenameTab), findsNothing);
      await tester.longPress(find.descendant(of: find.byType(PillBar), matching: find.text('web-02')));
      await settle(tester);
      expect(find.text(l10n.pillRenameTab), findsOneWidget, reason: "the tab's menu");
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    }, variant: _tablet);

    testWidgets("a host card's more button opens its menu; a tap opens its panel", (tester) async {
      final s = await pumpTablet(tester, _tabletUpright);
      expect(find.byKey(const ValueKey('host-panel-primary')), findsNothing);
      await tester.tap(find.descendant(of: find.byType(HostCard), matching: find.text('web-02')));
      await tester.pump(const Duration(milliseconds: 400));
      await settle(tester);
      expect(find.byKey(const ValueKey('host-panel-primary')), findsOneWidget, reason: "the host's panel");
      // Upright it is a sheet over the page (the grid keeps its two columns),
      // its foot touch sized with a more button; a tap on the scrim closes it.
      expect(find.byKey(const ValueKey('host-panel-sheet')), findsOneWidget);
      expect(tester.getSize(find.byKey(const ValueKey('host-panel-primary'))).height, 48);
      await tester.tap(find.byKey(const ValueKey('host-panel-more')));
      await settle(tester);
      expect(find.text(lookupAppLocalizations(const Locale('en')).hpanelOpenInSplit), findsWidgets);
      // A tap on the scrim, beside the menu, closes both.
      await tester.tapAt(const Offset(300, 700));
      await settle(tester);
      expect(find.text(lookupAppLocalizations(const Locale('en')).hpanelOpenInSplit), findsNothing);
      expect(find.byKey(const ValueKey('host-panel-sheet')), findsNothing);
      final more = find.byKey(const ValueKey('host-card-more-c0'));
      expect(more, findsOneWidget, reason: 'in sight, nothing behind a hover');
      expect(tester.getSize(more).height, 48);
      await tester.tap(more);
      await settle(tester);
      final l10n = lookupAppLocalizations(const Locale('en'));
      expect(find.text(l10n.hpanelOpenInSplit), findsWidgets, reason: "the host's menu");
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    }, variant: _tablet);

    testWidgets("a terminal has the row of keys a touch keyboard lacks; a computer's has none", (tester) async {
      final s = await pumpTablet(tester, _tabletSideways);
      await openSessions(tester, s);
      expect(find.byType(PaneKeysRow), findsOneWidget);
      expect(find.byType(TerminalSoftKeyboard), findsOneWidget);
      await tearDownShell(tester, s);
      debugTouchLayout = null;
      final computer = await pumpShell(tester, 'default_dark', picture: false);
      await openSessions(tester, computer);
      expect(find.byType(TerminalSoftKeyboard), findsNothing);
      await tearDownShell(tester, computer);
    }, variant: _tablet);
  });

  // No picture, always on. "Switch to session" on the Hosts page changed an
  // index of sessions kept from before tabs held groups, and nothing came on
  // screen.
  testWidgets("the Hosts page's Switch to session brings the session's tab on screen, with its pane in front",
      (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false);
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's8': _session(8)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final first = tabs.tabContaining('s0')!.id;
    final wanted = tabs.tabContaining('s8')!.id;
    expect(wanted, isNot(first));
    tabs.setActiveTab(first);
    await settle(tester);
    // The Hosts page, with both sessions still open.
    tabs.clearActiveTab();
    c.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
    await settle(tester);
    expect(find.byType(HostsHomePage), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(HostsHomePage), matching: find.text(_hosts[8][0])).first);
    await settle(tester);
    final primary = find.byKey(const ValueKey('host-panel-primary'));
    expect(find.descendant(of: primary, matching: find.text(lookupAppLocalizations(const Locale('en')).hostPanelSwitchToSession)), findsOneWidget);
    await tester.tap(primary);
    await settle(tester);
    // The switch runs after the frame of the tap; the next one shows it.
    await tester.pump();
    expect(c.read(workTabsProvider).activeTabId, wanted, reason: "the session's own tab");
    expect(find.byType(DesktopTerminalArea), findsOneWidget, reason: 'the terminal is on screen, not the Hosts page');
    await tearDownShell(tester, s);
  });

  // No picture, always on: the Layout button and the digit keys of the real
  // shell (2.2.1 had no quick way to a grid of five).
  testWidgets('the Layout button arranges the tab; Ctrl and a digit goes to a tab, with Alt as well it does nothing',
      (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 6; i++) 's$i': _session(i),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final dest = tabs.tabContaining('s0')!.id;
    // Five in one tab; the sixth keeps a tab of its own.
    for (var i = 1; i < 5; i++) {
      tabs.mergeTabs(tabs.tabContaining('s$i')!.id, dest);
    }
    tabs.setActiveTab(dest);
    await settle(tester);
    final prefs = c.read(sharedPreferencesProvider);
    List<int>? rows() => rowsOf(c.read(paneTreeProvider)!);
    expect(rows(), [3, 2]);

    // An arrangement is chosen: the tab stands in it, and its number is kept.
    await tester.tap(find.text('Layout').first);
    await settle(tester);
    await tester.tap(find.text('2 + 3'));
    await settle(tester);
    expect(rows(), [2, 3]);
    expect(c.read(workTabsProvider).activeTab!.sessionIds, ['s0', 's1', 's2', 's3', 's4']);
    expect(prefs.getInt('desktop_pane_layout_preset'), LayoutPreset.twoAndThree.number);
    expect(find.text('2 + 3'), findsNothing, reason: 'the popover closed');

    // The automatic grid: the tab is in it again, and no number is kept.
    await tester.tap(find.text('Layout').first);
    await settle(tester);
    await tester.tap(find.text('Automatic'));
    await settle(tester);
    expect(rows(), [3, 2]);
    expect(isTiled(c.read(paneTreeProvider)), isTrue);
    expect(prefs.getInt('desktop_pane_layout_preset'), isNull);

    // The keys, typed at the shell itself (inside a terminal every key is
    // the terminal's).
    final other = tabs.tabContaining('s5')!.id;
    String? inFront() => c.read(workTabsProvider).activeTabId;
    Future<void> ctrl(LogicalKeyboardKey digit) async {
      tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(digit);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    await ctrl(LogicalKeyboardKey.digit2);
    expect(inFront(), other, reason: 'Ctrl+2 goes to the second tab');
    await ctrl(LogicalKeyboardKey.digit1);
    expect(inFront(), dest);

    // Ctrl+Alt and a digit is how a brace or a bracket is typed on many
    // keyboards: it goes to no tab and arranges nothing.
    tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
    for (final key in [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2, LogicalKeyboardKey.digit8]) {
      await tester.sendKeyEvent(key);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(inFront(), dest);
    expect(rows(), [3, 2]);
    expect(prefs.getInt('desktop_pane_layout_preset'), isNull);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0). The keyboard's tab keys went by a list of
  // sessions kept from before tabs held groups: Ctrl+Tab and Ctrl and a
  // digit moved through sessions, not the tabs on screen, and Ctrl+Shift+W
  // ended the session at an index, in a tab of several not the one in
  // front, or a session of another tab, unasked and for good.
  testWidgets('the tab keys go by the strip, and Ctrl+Shift+W closes the tab in front as its pill does',
      (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final l10n = lookupAppLocalizations(const Locale('en'));
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    live.set({for (var i = 0; i < 7; i++) 's$i': _session(i)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final a = tabs.tabContaining('s0')!.id;
    // A group of three: web-02, mac-studio and hypervisor-b.
    final g = tabs.tabContaining('s1')!.id;
    for (final id in ['s2', 's4']) {
      tabs.mergeTabs(tabs.tabContaining(id)!.id, g);
    }
    // Another, pinned (build-runner, hypervisor-a, edge-router): first in
    // the strip, though its tab came last.
    final p = tabs.tabContaining('s3')!.id;
    for (final id in ['s5', 's6']) {
      tabs.mergeTabs(tabs.tabContaining(id)!.id, p);
    }
    tabs.togglePin(p);
    tabs.setActiveTab(a);
    await settle(tester);
    expect(c.read(workTabsProvider).tabs.map((t) => t.id), [a, g, p]);
    double x(String tab) => tester.getTopLeft(find.byKey(ValueKey(tab))).dx;
    expect(x(p) < x(a) && x(a) < x(g), isTrue, reason: 'the strip: the pinned tab, then a, then the group');

    String? inFront() => c.read(workTabsProvider).activeTabId;
    Map<String, SessionState> sessions() => c.read(activeSessionsProvider);
    Future<void> press(LogicalKeyboardKey key, {bool shift = false, bool atShell = true}) async {
      // At the shell itself: inside a terminal every key is the terminal's,
      // but for the few the shell takes there.
      if (atShell) {
        tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
        await tester.pump();
      }
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    /// Lets the time to take a close back run out.
    Future<void> runOut() async {
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    }

    // Ctrl+Tab: the next of the strip, from the last round to the first;
    // Ctrl+Shift+Tab: the one before. (From a pane in focus as well, when it
    // holds one session.)
    c.read(focusedPaneProvider.notifier).state = c.read(paneTreeProvider)!.allLeaves.single.id;
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), g);
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), p);
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), a);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), p);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), g);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), a);
    // With no tab in front (a page of the side bar), the first and the last.
    tabs.clearActiveTab();
    await settle(tester);
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), p);
    tabs.clearActiveTab();
    await settle(tester);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), g);

    // Ctrl and a digit: that pill; past the last, nothing.
    await press(LogicalKeyboardKey.digit1);
    expect(inFront(), p);
    await press(LogicalKeyboardKey.digit3);
    expect(inFront(), g);
    await press(LogicalKeyboardKey.digit2);
    expect(inFront(), a);
    await press(LogicalKeyboardKey.digit4);
    expect(inFront(), a, reason: 'there is no fourth');

    // The terminal area shows the tab's first session, counted as that area
    // lists them: not one closed, not one hidden, not one in a window of its
    // own. (cache-01's session, closed, is in no tab.)
    tabs.expectSplitSession();
    live.set({
      'closed': _session(9, id: 'closed').copyWith(status: SessionStatus.disconnected),
      ...sessions(),
    });
    live.hideSession('s2');
    await settle(tester);
    await press(LogicalKeyboardKey.digit1);
    expect(c.read(v3ActiveSessionTabProvider), 's3');
    expect(c.read(desktopSelectedTabProvider), 2, reason: 's0, s1, s3');
    c.read(detachedSessionsProvider.notifier).detach('s0');
    await settle(tester);
    await press(LogicalKeyboardKey.digit3);
    expect(c.read(v3ActiveSessionTabProvider), 's1');
    expect(c.read(desktopSelectedTabProvider), 0);
    // A first session the area does not list is given no place in it.
    c.read(detachedSessionsProvider.notifier).detach('s3');
    await settle(tester);
    await press(LogicalKeyboardKey.digit1);
    expect(inFront(), p);
    expect(c.read(v3ActiveSessionTabProvider), 's3');
    expect(c.read(desktopSelectedTabProvider), isNonNegative);
    c.read(detachedSessionsProvider.notifier).reattach('s3');
    c.read(detachedSessionsProvider.notifier).reattach('s0');
    live.unhideSession('s2');
    live.set({...sessions()}..remove('closed'));
    await settle(tester);

    // A pane that holds several sessions: Ctrl+Tab and Ctrl+Shift+Tab go
    // between them, not to another tab. (log-store and db-primary join
    // web-01's pane.)
    await press(LogicalKeyboardKey.digit2);
    expect(inFront(), a);
    final paneOfA = c.read(paneTreeProvider)!.allLeaves.single.id;
    for (final id in ['s7', 's8']) {
      tabs.expectSplitSession();
      live.set({...sessions(), id: _session(int.parse(id.substring(1)))});
      await tester.pump();
      c.read(paneTreeProvider.notifier).addSessionToPane(paneOfA, id);
    }
    await settle(tester);
    int inPane() => c.read(paneTreeProvider)!.findLeaf(paneOfA)!.activeIndex;
    expect(c.read(paneTreeProvider)!.findLeaf(paneOfA)!.sessionIds, ['s0', 's7', 's8']);
    c.read(paneTreeProvider.notifier).setActiveTab(paneOfA, 0);
    c.read(focusedPaneProvider.notifier).state = paneOfA;
    await settle(tester);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), a);
    expect(inPane(), 2, reason: 'round to the last');
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), a);
    expect(inPane(), 0);
    // db-primary goes; web-01 and log-store stay in the pane.
    live.set({...sessions()}..remove('s8'));
    await settle(tester);

    // Ctrl+Shift+W, with the group in front: it is asked about, as at its
    // pill, and Cancel keeps it.
    await press(LogicalKeyboardKey.digit3);
    expect(inFront(), g);
    await press(LogicalKeyboardKey.keyW, shift: true);
    expect(find.text(l10n.desktopShellDisconnectGroup), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    expect(c.read(workTabsProvider).tabs.map((t) => t.id), [a, g, p]);
    expect(sessions().keys, hasLength(8));

    // Disconnect all: the tab leaves the strip at once, with a moment to
    // take it back; Undo brings it back whole.
    await press(LogicalKeyboardKey.keyW, shift: true);
    await tester.tap(find.text(l10n.desktopShellDisconnectAll));
    await tester.pump();
    expect(find.byKey(ValueKey(g)), findsNothing);
    expect(inFront(), isNot(g));
    await settle(tester);
    await tester.tap(find.text(l10n.desktopShellUndo));
    await settle(tester);
    await runOut();
    expect(find.byKey(ValueKey(g)), findsOneWidget);
    expect(sessions().keys, hasLength(8));
    expect(c.read(recentlyClosedTabsProvider), isEmpty);

    // Again, and the moment runs out: the group's three sessions end, and
    // nothing else.
    await press(LogicalKeyboardKey.digit3);
    expect(inFront(), g);
    await press(LogicalKeyboardKey.keyW, shift: true);
    await tester.tap(find.text(l10n.desktopShellDisconnectAll));
    await tester.pump();
    await runOut();
    expect(sessions().keys, unorderedEquals(['s0', 's3', 's5', 's6', 's7']));
    expect(c.read(workTabsProvider).tabs.map((t) => t.id), [a, p]);
    // Each of its hosts can be opened again, the last first.
    expect(c.read(recentlyClosedTabsProvider), ['c4', 'c2', 'c1']);

    // A pinned tab, a group as well, is not closed by the key, nor asked
    // about, as not at its pill.
    await press(LogicalKeyboardKey.digit1);
    expect(inFront(), p);
    await press(LogicalKeyboardKey.keyW, shift: true);
    expect(find.text(l10n.desktopShellDisconnectGroup), findsNothing);
    await runOut();
    expect(sessions().keys, hasLength(5));
    expect(c.read(workTabsProvider).tabs.map((t) => t.id), [a, p]);

    // From inside a terminal as well; a tab of two is closed unasked, and
    // web-01, which has its files open beside it as well, is remembered once.
    await press(LogicalKeyboardKey.digit2);
    expect(inFront(), a);
    c.read(paneTreeProvider.notifier).splitPaneWithSftp(paneOfA, Axis.horizontal, 's0');
    await settle(tester);
    expect(c.read(workTabsProvider).activeTab!.sessionIds, ['s0', 's7', 's0']);
    await tester.tap(find.byType(TerminalView).first);
    await settle(tester);
    await press(LogicalKeyboardKey.keyW, shift: true, atShell: false);
    expect(find.text(l10n.desktopShellDisconnectGroup), findsNothing);
    expect(find.byKey(ValueKey(a)), findsNothing);
    await runOut();
    expect(sessions().keys, unorderedEquals(['s3', 's5', 's6']));
    expect(c.read(recentlyClosedTabsProvider), ['c7', 'c0', 'c4', 'c2', 'c1']);

    // Ctrl+Shift+T opens them again, one at a time, the last closed first.
    live.opened = [];
    await press(LogicalKeyboardKey.keyT, shift: true);
    expect(live.opened, ['c7']);
    await press(LogicalKeyboardKey.keyT, shift: true);
    expect(live.opened, ['c7', 'c0']);
    expect(c.read(recentlyClosedTabsProvider), ['c4', 'c2', 'c1']);

    // The palette's "Close current tab" closes the tab in front, as the key.
    final second = tabs.tabContaining('r2')!.id;
    tabs.setActiveTab(second);
    await settle(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, l10n.desktopCmdCloseCurrentTab);
    await settle(tester);
    await tester.tap(find.text(l10n.desktopCmdCloseCurrentTab).last);
    await settle(tester);
    expect(find.byKey(ValueKey(second)), findsNothing);
    await runOut();
    expect(sessions().keys, unorderedEquals(['s3', 's5', 's6', 'r1']));

    // The last of them by the key: the pinned tab is left alone in the strip,
    // and Ctrl+Tab has nowhere to go (it does not even show it again).
    tabs.setActiveTab(tabs.tabContaining('r1')!.id);
    await settle(tester);
    await press(LogicalKeyboardKey.keyW, shift: true);
    await runOut();
    expect(sessions().keys, unorderedEquals(['s3', 's5', 's6']));
    expect(inFront(), p);
    final paneOfP = c.read(paneTreeProvider)!.allLeaves.first.id;
    c.read(focusedPaneProvider.notifier).state = paneOfP;
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), p);
    expect(c.read(focusedPaneProvider), paneOfP);

    // Unpinned, it closes too; with no tab at all, the keys do nothing.
    tabs.togglePin(p);
    await press(LogicalKeyboardKey.keyW, shift: true);
    await tester.tap(find.text(l10n.desktopShellDisconnectAll));
    await tester.pump();
    await runOut();
    expect(sessions(), isEmpty);
    expect(c.read(workTabsProvider).tabs, isEmpty);
    await press(LogicalKeyboardKey.tab);
    await press(LogicalKeyboardKey.tab, shift: true);
    await press(LogicalKeyboardKey.digit1);
    await press(LogicalKeyboardKey.keyW, shift: true);
    expect(tester.takeException(), isNull);
    expect(inFront(), isNull);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0): Settings lets each of these keys be
  // changed, and the shell listened for its own keys only.
  testWidgets('the next tab, the one before and reopening a closed one go by the keys Settings binds them to',
      (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    live.set({for (var i = 0; i < 3; i++) 's$i': _session(i)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final ids = [for (var i = 0; i < 3; i++) tabs.tabContaining('s$i')!.id];
    tabs.setActiveTab(ids[0]);
    await settle(tester);
    final keys = c.read(shortcutBindingsProvider.notifier);
    await keys.setBinding(ShortcutAction.nextTab, ShortcutKey(keyId: LogicalKeyboardKey.pageDown.keyId, ctrl: true));
    await keys.setBinding(ShortcutAction.previousTab, ShortcutKey(keyId: LogicalKeyboardKey.pageUp.keyId, ctrl: true));
    await keys.setBinding(
      ShortcutAction.reopenLastTab,
      ShortcutKey(keyId: LogicalKeyboardKey.keyO.keyId, ctrl: true, shift: true),
    );
    String? inFront() => c.read(workTabsProvider).activeTabId;
    Future<void> press(LogicalKeyboardKey key, {bool shift = false}) async {
      tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    await press(LogicalKeyboardKey.pageDown);
    expect(inFront(), ids[1]);
    await press(LogicalKeyboardKey.tab);
    expect(inFront(), ids[1], reason: 'Ctrl+Tab is not the key any more');
    await press(LogicalKeyboardKey.pageUp);
    expect(inFront(), ids[0]);
    await press(LogicalKeyboardKey.tab, shift: true);
    expect(inFront(), ids[0]);

    await press(LogicalKeyboardKey.keyW, shift: true);
    await tester.pump(const Duration(seconds: 7));
    await settle(tester);
    expect(c.read(recentlyClosedTabsProvider), ['c0']);
    live.opened = [];
    await press(LogicalKeyboardKey.keyT, shift: true);
    expect(live.opened, isEmpty, reason: 'Ctrl+Shift+T is not the key any more');
    await press(LogicalKeyboardKey.keyO, shift: true);
    expect(live.opened, ['c0']);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0): every other key Settings lets one change was
  // fixed in the shell, so a key chosen there did nothing (though the palette
  // named it), the old key went on working, and Ctrl+comma opened Settings
  // where Settings had no key.
  testWidgets('outside a terminal every key goes by what Settings binds it to: the key chosen there works, the old one '
      'does nothing, nor does one cleared there', (tester) async {
    // The app's own fonts: the test's font, every letter a full square, makes
    // the session's header too wide for the Inspector beside it.
    await tester.runAsync(loadShotFonts);
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final l10n = lookupAppLocalizations(const Locale('en'));
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    live.set({'s0': _session(0)});
    live.opened = [];
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final tab = tabs.tabContaining('s0')!.id;
    tabs.setActiveTab(tab);
    c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
    if (c.read(paneTreeProvider) == null) c.read(paneTreeProvider.notifier).initSinglePane('s0');
    await settle(tester);
    var fullscreen = 0;
    DesktopShell.debugToggleFullscreen = () => fullscreen++;
    addTearDown(() => DesktopShell.debugToggleFullscreen = null);

    final keys = c.read(shortcutBindingsProvider.notifier);
    ShortcutKey ctrlF(LogicalKeyboardKey key) => ShortcutKey(keyId: key.keyId, ctrl: true);
    await keys.setBinding(ShortcutAction.splitRight, ctrlF(LogicalKeyboardKey.f3));
    await keys.setBinding(ShortcutAction.splitDown, ctrlF(LogicalKeyboardKey.f4));
    await keys.setBinding(ShortcutAction.maximizePane, ctrlF(LogicalKeyboardKey.f5));
    await keys.setBinding(ShortcutAction.closeSplit, ctrlF(LogicalKeyboardKey.f6));
    await keys.setBinding(ShortcutAction.zoomIn, ctrlF(LogicalKeyboardKey.f7));
    await keys.setBinding(ShortcutAction.resetZoom, ctrlF(LogicalKeyboardKey.f9));
    await keys.setBinding(ShortcutAction.toggleSessionInfo, ctrlF(LogicalKeyboardKey.f10));
    await keys.setBinding(ShortcutAction.toggleBroadcast, ctrlF(LogicalKeyboardKey.f12));
    await keys.setBinding(ShortcutAction.toggleSftpPanel, ctrlF(LogicalKeyboardKey.f8));
    await keys.setBinding(ShortcutAction.toggleFullscreen, ctrlF(LogicalKeyboardKey.f11));
    await keys.unbind(ShortcutAction.settings);

    /// [key] pressed with Ctrl (and Shift, or Alt) held, the keyboard in the
    /// shell, in no terminal.
    Future<void> press(LogicalKeyboardKey key, {bool ctrl = true, bool shift = false}) async {
      tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
      await tester.pump();
      if (ctrl) await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(key);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      if (ctrl) await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    int panes() => c.read(paneTreeProvider)?.allLeaves.length ?? 0;
    void focusFirst() => c.read(focusedPaneProvider.notifier).state = c.read(paneTreeProvider)!.allLeaves.first.id;

    // Split right, then down.
    final before = panes();
    expect(before, 1);
    await press(LogicalKeyboardKey.keyD, shift: true);
    expect(panes(), before, reason: 'Ctrl+Shift+D is not the key any more');
    await press(LogicalKeyboardKey.f3);
    expect(panes(), before + 1);
    expect((c.read(paneTreeProvider)! as PaneSplit).axis, Axis.horizontal);
    focusFirst();
    await press(LogicalKeyboardKey.keyE, shift: true);
    expect(panes(), before + 1, reason: 'Ctrl+Shift+E is not the key any more');
    await press(LogicalKeyboardKey.f4);
    expect(panes(), before + 2);

    // Maximize and back.
    focusFirst();
    await press(LogicalKeyboardKey.keyM, shift: true);
    expect(panes(), before + 2, reason: 'Ctrl+Shift+M is not the key any more');
    await press(LogicalKeyboardKey.f5);
    expect(panes(), 1);
    await press(LogicalKeyboardKey.f5);
    expect(panes(), before + 2);

    // Broadcast, with more than one terminal in the tab.
    await press(LogicalKeyboardKey.keyB, shift: true);
    expect(c.read(broadcastModeProvider).broadcasts(tab), isFalse, reason: 'Ctrl+Shift+B is not the key any more');
    await press(LogicalKeyboardKey.f12);
    expect(c.read(broadcastModeProvider).broadcasts(tab), isTrue);
    await press(LogicalKeyboardKey.f12);
    expect(c.read(broadcastModeProvider).broadcasts(tab), isFalse);

    // Close a split.
    focusFirst();
    await press(LogicalKeyboardKey.backslash);
    expect(panes(), before + 2, reason: 'Ctrl and the backslash is not the key any more');
    await press(LogicalKeyboardKey.f6);
    expect(panes(), before + 1);

    // Zoom: in by its key; out by Ctrl+- and the pad's -, its default kept;
    // reset by its key, neither Ctrl+0 nor the pad's 0 any more.
    double size() => c.read(terminalFontSizeProvider);
    final start = size();
    await press(LogicalKeyboardKey.equal);
    await press(LogicalKeyboardKey.numpadAdd);
    expect(size(), start, reason: 'Ctrl+= and the pad\'s + are not the keys any more');
    await press(LogicalKeyboardKey.f7);
    expect(size(), start + 1);
    await press(LogicalKeyboardKey.f7);
    await press(LogicalKeyboardKey.minus);
    expect(size(), start + 1);
    await press(LogicalKeyboardKey.numpadSubtract);
    expect(size(), start, reason: "the pad's - is Ctrl+-'s twin while zoom out keeps it");
    await press(LogicalKeyboardKey.f7);
    await press(LogicalKeyboardKey.digit0);
    await press(LogicalKeyboardKey.numpad0);
    expect(size(), start + 1, reason: 'Ctrl+0 and the pad\'s 0 are not the keys any more');
    await press(LogicalKeyboardKey.f9);
    expect(size(), 14);

    // The session's panel.
    await press(LogicalKeyboardKey.keyI, shift: true);
    expect(c.read(sessionSlidePanelVisibleProvider), isFalse, reason: 'Ctrl+Shift+I is not the key any more');
    await press(LogicalKeyboardKey.f10);
    expect(c.read(sessionSlidePanelVisibleProvider), isTrue);
    await press(LogicalKeyboardKey.f10);
    expect(c.read(sessionSlidePanelVisibleProvider), isFalse);

    // SFTP (this test's shell is no SSH one, and says so).
    bool sftpSaid() =>
        find.text(l10n.desktopShellSftpRequiresSsh).evaluate().isNotEmpty ||
        c.read(notificationCenterProvider).history.any((n) => n.title == l10n.desktopShellSftpRequiresSsh);
    await press(LogicalKeyboardKey.keyS, shift: true);
    expect(sftpSaid(), isFalse, reason: 'Ctrl+Shift+S is not the key any more');
    await press(LogicalKeyboardKey.f8);
    expect(sftpSaid(), isTrue);
    await tester.pump(const Duration(seconds: 7));
    await settle(tester);

    // Full screen.
    await press(LogicalKeyboardKey.f11, ctrl: false);
    expect(fullscreen, 0, reason: 'F11 is not the key any more');
    await press(LogicalKeyboardKey.f11);
    expect(fullscreen, 1);

    // Settings has no key.
    await press(LogicalKeyboardKey.comma);
    expect(c.read(settingsPopupOpenProvider), isFalse, reason: 'Settings was cleared');
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.3, the Support Hub).
  group('the Support Hub over the shell', () {
    // (The form keeps what was typed for as long as the app runs.)
    setUp(resetSupportHubDraft);

    Future<_Shell0> hubShell(WidgetTester tester) async {
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'zestssh', version: '3.3.0', buildNumber: '340', buildSignature: '');
      final s = await pumpShell(tester, 'default_dark', picture: false, extra: [
        cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
      ]);
      await openSessions(tester, s);
      return s;
    }

    bool keyboardInTerminal() =>
        FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TerminalView>() != null;

    /// The keyboard in the shell, in no terminal.
    Future<void> toShell(WidgetTester tester) async {
      tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
      await tester.pump();
    }

    testWidgets('F1 opens it where the keyboard is in no terminal, and goes back; in a terminal F1 is the program\'s',
        (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      await tester.tap(find.byType(TerminalView).first);
      await settle(tester);
      expect(keyboardInTerminal(), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse, reason: 'mc and htop have their help there');

      await toShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue);
      expect(find.byType(SupportHubPage), findsOneWidget);
      // The sessions go on behind it: their terminals are still there.
      expect(find.byType(TerminalView, skipOffstage: false), findsWidgets);
      expect(find.text(lookupAppLocalizations(const Locale('en')).supportHubTitle), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(find.byType(SupportHubPage), findsNothing);
      await tearDownShell(tester, s);
    });

    testWidgets('Esc goes back to the sessions and the keyboard goes back to the terminal in front', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      await tester.tap(find.byType(TerminalView).first);
      await settle(tester);
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      expect(keyboardInTerminal(), isFalse, reason: 'the page has it now');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(keyboardInTerminal(), isTrue);
      await tearDownShell(tester, s);
    });

    testWidgets('the shell\'s keys do nothing behind it', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      final panesBefore = c.read(paneTreeProvider)?.allLeaves.length;
      final tabsBefore = c.read(workTabsProvider).tabs.length;
      final keys = HardwareKeyboard.instance;
      expect(keys.isControlPressed, isFalse);
      // A new connection, a split, close the tab.
      for (final key in [LogicalKeyboardKey.keyN, LogicalKeyboardKey.keyD, LogicalKeyboardKey.keyW]) {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
      }
      expect(c.read(connectionEditorTargetProvider), isNull);
      expect(c.read(paneTreeProvider)?.allLeaves.length, panesBefore);
      expect(c.read(workTabsProvider).tabs, hasLength(tabsBefore));
      expect(c.read(supportHubOpenProvider), isTrue);
      await tearDownShell(tester, s);
    });

    testWidgets('the ? button goes back from it and opens the small panel otherwise; the panel\'s row opens it',
        (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      final help = find.byIcon(LucideIcons.helpCircle);
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      await tester.tap(help);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(c.read(helpDockProvider), isNull, reason: 'back to the sessions, nothing opened on top of them');

      await tester.tap(help);
      await settle(tester);
      expect(c.read(helpDockProvider), HelpPage.home);
      final row = find.byKey(const ValueKey('help-open-hub'));
      await tester.ensureVisible(row);
      await settle(tester);
      await tester.tap(row);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue);
      expect(c.read(helpDockProvider), isNull);
      await tearDownShell(tester, s);
    });

    testWidgets('a tab chosen in the bar goes to that tab, and so does a panel asked for elsewhere', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      final tab = c.read(workTabsProvider).activeTab!;
      await tester.tap(find.byKey(ValueKey(tab.id)));
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse, reason: 'the tab in front, chosen again');

      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      c.read(helpDockProvider.notifier).state = HelpPage.reportBug;
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse, reason: 'it would open behind the hub');
      await tearDownShell(tester, s);
    });

    testWidgets('the palette has it, and its key comes back from it', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      final l10n = lookupAppLocalizations(const Locale('en'));
      Future<void> paletteKey() async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
      }

      await toShell(tester);
      await paletteKey();
      await tester.enterText(find.byType(TextField).last, 'support hub');
      await settle(tester);
      await tester.tap(find.text(l10n.supportHubOpen));
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue);

      await paletteKey();
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(find.text(l10n.zestPaletteHint), findsOneWidget);
      // It has the keyboard: as the hub went, the keyboard fell somewhere, and a
      // palette opened in that frame stood open with the keys going past it.
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull,
          reason: 'in its field');
      expect(keyboardInTerminal(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.text(l10n.zestPaletteHint), findsNothing, reason: 'Esc closes it');
      await tearDownShell(tester, s);
    });

    testWidgets('Quick connect asked for from it has the keyboard, and what is typed reaches no session', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      final typed = <String>[];
      for (final e in live.state.values) {
        e.session!.terminal.onOutput = typed.add;
      }
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      // Ctrl+T, the shell's own key, does nothing behind the page; the tray and
      // the Mac's menu call what the bar's + calls.
      tester.widget<PillBar>(find.byType(PillBar)).onNewSession();
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<EditableText>(), isNotNull);
      expect(keyboardInTerminal(), isFalse);
      tester.testTextInput.enterText('web');
      await settle(tester);
      expect(typed, isEmpty);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('from the page the report\'s screenshot is of the app, the form as it was', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      await tester.enterText(find.byKey(const ValueKey('hub-body')), 'Typed before the picture.');
      await tester.pump();
      final add = find.byKey(const ValueKey('hub-screenshot-add'));
      await tester.ensureVisible(add);
      await settle(tester);
      await tester.tap(add);
      // The page steps aside for the frames of the picture...
      await tester.pump();
      expect(find.byType(SupportHubPage), findsNothing, reason: 'offstage');
      expect(find.byType(SupportHubPage, skipOffstage: false), findsOneWidget);
      // ...and comes back with everything it held.
      for (var i = 0; i < 12; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(find.byType(SupportHubPage), findsOneWidget);
      expect(find.text('Typed before the picture.'), findsWidgets);
      await tearDownShell(tester, s);
    });

    // A key that reaches a live host from a form is the worst thing this page
    // could do. Everything below goes through the real shell and real terminals.
    group('no key reaches a session behind it', () {
      /// What every session's terminal sent, by session, from now on (a session
      /// opened later has to be listened to as well: [listenTo]).
      final sent = <String, List<String>>{};
      void listenTo(_Shell0 s) {
        final live = s.container.read(activeSessionsProvider);
        for (final e in live.entries) {
          final terminal = e.value.session?.terminal;
          if (terminal == null) continue;
          terminal.onOutput = (sent[e.key] ??= []).add;
        }
      }

      Map<String, List<String>> reached() => {
            for (final e in sent.entries)
              if (e.value.isNotEmpty) e.key: e.value,
          };

      /// Writes in the form and presses what a shell would run: Enter, Tab, Esc
      /// is left out, it closes the page. By the hardware keys and through the
      /// input method both.
      Future<void> write(WidgetTester tester, String words) async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyM);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        if (tester.testTextInput.isVisible) tester.testTextInput.enterText(words);
        await settle(tester);
      }

      /// The hub's form open with the keyboard in its field, every session
      /// listened to.
      Future<void> writing(WidgetTester tester, _Shell0 s) async {
        final c = s.container;
        sent.clear();
        c.read(supportHubOpenProvider.notifier).state = true;
        c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
        await settle(tester);
        listenTo(s);
        await tester.tap(find.byKey(const ValueKey('hub-body')));
        await settle(tester);
        await write(tester, 'first words');
        expect(reached(), isEmpty, reason: 'nothing has moved yet');
      }

      testWidgets('the session in front ends while the person writes: the next terminal does not take the keyboard',
          (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        await writing(tester, s);
        live.set({...live.state}..remove('s0'));
        await settle(tester);
        expect(find.byType(TerminalView), findsWidgets, reason: 'the next one is in front, under the page');
        expect(find.byType(SupportHubPage), findsOneWidget);
        await write(tester, 'rm -rf more words');
        expect(reached(), isEmpty);
        expect(keyboardInTerminal(), isFalse);
        // And back: the keyboard goes to what is in front now, and only then.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(c.read(supportHubOpenProvider), isFalse);
        expect(keyboardInTerminal(), isTrue);
        await tearDownShell(tester, s);
      });

      testWidgets('a session that opens behind it does not take the keyboard', (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        await writing(tester, s);
        // A workspace, a restored session, an automation: none of them went
        // through the shell's Connect.
        final tabs = c.read(workTabsProvider.notifier);
        live.set({...live.state, 's4': _session(4)});
        await tester.pump();
        listenTo(s);
        tabs.setActiveTab(tabs.tabContaining('s4')!.id);
        c.read(v3ActiveSessionTabProvider.notifier).state = 's4';
        await settle(tester);
        await write(tester, 'more words');
        expect(reached(), isEmpty);
        expect(keyboardInTerminal(), isFalse);
        await tearDownShell(tester, s);
      });

      testWidgets('a session opened by Connect (the tray, a link) comes to the front, and the page goes first',
          (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        final connections = await c.read(connectionsWithDetailsProvider.future);
        await writing(tester, s);
        live.opened = [];
        // The tray and a link call what this calls: DesktopShell._connectTo.
        tester.widget<DesktopTerminalArea>(find.byType(DesktopTerminalArea, skipOffstage: false)).onConnectTo(
              connections.firstWhere((h) => h.connection.id == 'c4'),
            );
        await settle(tester);
        expect(c.read(supportHubOpenProvider), isFalse, reason: 'it opened behind the page, out of sight');
        expect(live.opened, ['c4']);
        await tearDownShell(tester, s);
      });

      testWidgets('F1 while a host connects, then writing: it connects behind the page and gets nothing',
          (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        // Connecting, in front.
        final h = _session(4);
        live.set({
          ...live.state,
          's4': SessionState(
            status: SessionStatus.connecting,
            connectionId: h.connectionId,
            connectionLabel: h.connectionLabel,
            host: h.host,
            port: h.port,
            username: h.username,
          ),
        });
        await tester.pump();
        final tabs = c.read(workTabsProvider.notifier);
        tabs.setActiveTab(tabs.tabContaining('s4')!.id);
        c.read(v3ActiveSessionTabProvider.notifier).state = 's4';
        await settle(tester);
        await toShell(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.f1);
        await settle(tester);
        expect(c.read(supportHubOpenProvider), isTrue);
        await writing(tester, s);
        // It connects: its terminal mounts and asks for the keyboard.
        live.set({...live.state, 's4': h});
        await tester.pump();
        listenTo(s);
        await settle(tester);
        await write(tester, 'more words');
        expect(reached(), isEmpty);
        expect(keyboardInTerminal(), isFalse);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(keyboardInTerminal(), isTrue, reason: 'as the page goes, the keyboard goes to it');
        await tearDownShell(tester, s);
      });

      testWidgets('asking every terminal for the keyboard under the page moves nothing', (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        await writing(tester, s);
        c.read(terminalKeyboardAskProvider.notifier).state++;
        await settle(tester);
        await write(tester, 'more words');
        expect(reached(), isEmpty);
        expect(keyboardInTerminal(), isFalse);
        await tearDownShell(tester, s);
      });

      testWidgets('with the page stepped aside for a picture the terminals take no click', (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        c.read(supportHubOpenProvider.notifier).state = true;
        c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
        await settle(tester);
        final add = find.byKey(const ValueKey('hub-screenshot-add'));
        await tester.ensureVisible(add);
        await settle(tester);
        await tester.tap(add);
        await tester.pump();
        expect(find.byType(SupportHubPage), findsNothing, reason: 'offstage');
        expect(find.byType(TerminalView).hitTestable(), findsNothing);
        for (var i = 0; i < 12; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
          await tester.pump(const Duration(milliseconds: 60));
        }
        await tearDownShell(tester, s);
      });

      testWidgets('a file dropped on the page types no path anywhere; on the terminal in front, only into that one',
          (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        Future<void> drop(Offset at) async {
          for (final call in [
            MethodCall('entered', [at.dx, at.dy]),
            MethodCall('updated', [at.dx, at.dy]),
            const MethodCall('performOperation', ['C:/made/up/notes.txt']),
          ]) {
            await messenger.handlePlatformMessage(
              'desktop_drop',
              const StandardMethodCodec().encodeMethodCall(call),
              (_) {},
            );
          }
          await settle(tester);
        }

        sent.clear();
        listenTo(s);
        final middle = tester.getCenter(find.byType(TerminalView).first);
        await drop(middle);
        expect(sent['s0']?.join(), contains('notes.txt'), reason: 'a drop on a terminal still types its path');
        final others = {...reached()}..remove('s0');
        expect(others, isEmpty, reason: 'the terminals hidden behind it heard of the drop too');

        sent.clear();
        listenTo(s);
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
        await drop(middle);
        expect(reached(), isEmpty, reason: 'it fell on the page');
        await tearDownShell(tester, s);
      });

      // A drop on a pane of a split that is on show, the keyboard in the other. It
      // did nothing, with `front` taken for what is on show.
      testWidgets('a file dropped on the pane of a split without the keyboard types its path there, and only there',
          (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        live.set({'s0': _session(0), 's1': _session(1)});
        await tester.pump();
        final tabs = c.read(workTabsProvider.notifier);
        tabs.mergeTabs(tabs.tabContaining('s1')!.id, tabs.tabContaining('s0')!.id);
        tabs.setActiveTab(tabs.tabContaining('s0')!.id);
        c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
        await settle(tester);
        final inTheOther = find.byWidgetPredicate(
            (w) => w is TerminalView && identical(w.terminal, c.read(activeSessionsProvider)['s1']!.session!.terminal));
        final at = tester.getCenter(inTheOther);
        await tester.tap(find.byWidgetPredicate(
            (w) => w is TerminalView && identical(w.terminal, c.read(activeSessionsProvider)['s0']!.session!.terminal)));
        await settle(tester);
        sent.clear();
        listenTo(s);
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        for (final call in [
          MethodCall('entered', [at.dx, at.dy]),
          MethodCall('updated', [at.dx, at.dy]),
          const MethodCall('performOperation', ['C:/made/up/notes.txt']),
        ]) {
          await messenger.handlePlatformMessage('desktop_drop', const StandardMethodCodec().encodeMethodCall(call), (_) {});
        }
        await settle(tester);
        expect(sent['s1']?.join(), contains('notes.txt'));
        expect(sent['s0'] ?? const <String>[], isEmpty, reason: 'it was dropped on the other');
        await tearDownShell(tester, s);
      });

      testWidgets('a file dropped on a dialog over a terminal types no path either', (tester) async {
        final s = await hubShell(tester);
        final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        sent.clear();
        listenTo(s);
        final middle = tester.getCenter(find.byType(TerminalView).first);
        unawaited(showDialog<void>(
          context: tester.element(find.byType(DesktopTerminalArea)),
          builder: (_) => const Center(child: SizedBox(width: 1000, height: 800, child: Material())),
        ));
        await settle(tester);
        for (final call in [
          MethodCall('entered', [middle.dx, middle.dy]),
          const MethodCall('performOperation', ['C:/made/up/notes.txt']),
        ]) {
          await messenger.handlePlatformMessage(
            'desktop_drop',
            const StandardMethodCodec().encodeMethodCall(call),
            (_) {},
          );
        }
        await settle(tester);
        expect(reached(), isEmpty);
        await tearDownShell(tester, s);
      });
    });

    // A host opened, then a dialog, the palette or Quick connect while it connected,
    // and typing went on: the terminal asked for the keyboard before it had anywhere
    // to take it, was remembered, and took it as it connected, past the check for
    // what lies over the page. `k` reached the host.
    group('a host that connects under what is open takes no key from it', () {
      final typed = <String>[];

      Future<void> connectsUnder(WidgetTester tester, Future<void> Function(_Shell0 s) open) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        final h = _session(4);
        live.set({
          ...live.state,
          's4': SessionState(
            status: SessionStatus.connecting,
            connectionId: h.connectionId,
            connectionLabel: h.connectionLabel,
            host: h.host,
            port: h.port,
            username: h.username,
          ),
        });
        await tester.pump();
        final tabs = c.read(workTabsProvider.notifier);
        tabs.setActiveTab(tabs.tabContaining('s4')!.id);
        c.read(v3ActiveSessionTabProvider.notifier).state = 's4';
        await settle(tester);
        await open(s);
        await settle(tester);
        expect(keyboardInTerminal(), isFalse);

        typed.clear();
        live.set({...live.state, 's4': h});
        await tester.pump();
        for (final e in live.state.values) {
          e.session!.terminal.onOutput = typed.add;
        }
        await settle(tester);
        expect(keyboardInTerminal(), isFalse, reason: 'it took the keyboard from what lies over it');
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await settle(tester);
        expect(typed, isEmpty);

        // What lay over it goes, and the keyboard comes to what has connected.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(keyboardInTerminal(), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await settle(tester);
        expect(typed.join(), 'k', reason: 'it has the keyboard now, and nothing before was held for it');
        await tearDownShell(tester, s);
      }

      testWidgets('a dialog', (tester) async {
        await connectsUnder(tester, (s) async {
          unawaited(showDialog<void>(
            context: tester.element(find.byType(DesktopTerminalArea)),
            builder: (_) => const Dialog(child: TextField(autofocus: true)),
          ));
        });
      });

      testWidgets('the palette', (tester) async {
        await connectsUnder(tester, (s) async {
          tester.widget<PillBar>(find.byType(PillBar)).onCommandPalette();
          await settle(tester);
          expect(find.text(lookupAppLocalizations(const Locale('en')).zestPaletteHint), findsOneWidget);
        });
      });

      testWidgets('Quick connect', (tester) async {
        await connectsUnder(tester, (s) async {
          tester.widget<PillBar>(find.byType(PillBar)).onNewSession();
          await settle(tester);
          expect(find.byType(QuickConnectV3), findsOneWidget);
        });
      });

      testWidgets('with nothing open it has the keyboard as it connects, as ever', (tester) async {
        final s = await hubShell(tester);
        final c = s.container;
        final live = c.read(activeSessionsProvider.notifier) as _Sessions;
        final h = _session(4);
        live.set({
          ...live.state,
          's4': SessionState(
            status: SessionStatus.connecting,
            connectionId: h.connectionId,
            connectionLabel: h.connectionLabel,
            host: h.host,
            port: h.port,
            username: h.username,
          ),
        });
        await tester.pump();
        final tabs = c.read(workTabsProvider.notifier);
        tabs.setActiveTab(tabs.tabContaining('s4')!.id);
        c.read(v3ActiveSessionTabProvider.notifier).state = 's4';
        await settle(tester);
        live.set({...live.state, 's4': h});
        await settle(tester);
        expect(keyboardInTerminal(), isTrue);
        expect(FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TerminalView>()?.terminal,
            same(h.session!.terminal));
        await tearDownShell(tester, s);
      });
    });

    // Find under a dialog, then Esc: the terminal had the keyboard with the dialog
    // still open. No shortcut of the shell's is for what lies behind
    // a dialog.
    testWidgets('Under a dialog the shell\'s keys do nothing, and Find closing leaves the keyboard with the dialog',
        (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      final tabsBefore = c.read(workTabsProvider).tabs.length;
      await toShell(tester);
      final field = FocusNode();
      addTearDown(field.dispose);
      Future<void> aDialog() async {
        unawaited(showDialog<void>(
          context: tester.element(find.byType(DesktopTerminalArea)),
          builder: (_) => Dialog(child: TextField(focusNode: field, autofocus: true)),
        ));
        await settle(tester);
        expect(field.hasFocus, isTrue);
      }

      await aDialog();
      Future<void> ctrlShift(LogicalKeyboardKey key) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(key);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
      }

      await ctrlShift(LogicalKeyboardKey.keyF);
      expect(c.read(terminalFindProvider), isNull, reason: 'Find in terminal opened under the dialog');
      expect(field.hasFocus, isTrue);
      await ctrlShift(LogicalKeyboardKey.keyW);
      expect(c.read(workTabsProvider).tabs, hasLength(tabsBefore), reason: 'a tab closed behind the dialog');
      expect(field.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(Dialog), findsNothing);

      // Open already, and closed under one.
      c.read(terminalFindProvider.notifier).state = (sessionId: 's0', ask: 0);
      await settle(tester);
      await aDialog();
      c.read(terminalFindProvider.notifier).state = null;
      await settle(tester);
      expect(field.hasFocus, isTrue, reason: 'its closing gave the terminal the keyboard');
      expect(keyboardInTerminal(), isFalse);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(find.byType(Dialog), findsNothing);
      expect(keyboardInTerminal(), isTrue, reason: 'the dialog has gone, and it is owed the keyboard');
      await tearDownShell(tester, s);
    });

    testWidgets('F1 under a dialog: the page does not come up under it, and the dialog keeps its keyboard', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      await toShell(tester);
      final field = FocusNode();
      addTearDown(field.dispose);
      unawaited(showDialog<void>(
        context: tester.element(find.byType(DesktopTerminalArea)),
        builder: (_) => Dialog(child: TextField(focusNode: field, autofocus: true)),
      ));
      await settle(tester);
      expect(field.hasFocus, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(field.hasFocus, isTrue);

      // Opened some other way under it (a notification, a link): the page waits
      // for the keyboard until the dialog has gone, and F1 is still not its own.
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      expect(field.hasFocus, isTrue, reason: 'the dialog\'s field lost it');
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue);
      // Nor is the palette's, which leaves the page: not from under a dialog.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue, reason: 'the page left, under the dialog');
      expect(find.text(lookupAppLocalizations(const Locale('en')).zestPaletteHint), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isTrue, reason: 'Esc is for the dialog');
      expect(find.byType(TextField).evaluate().where((e) => (e.widget as TextField).focusNode == field), isEmpty,
          reason: 'it closed');
      // It has the keyboard now: Esc goes back.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      await tearDownShell(tester, s);
    });

    testWidgets('Esc still goes back after the field that had the keyboard has gone', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-body')));
      await settle(tester);
      c.read(supportHubComposeProvider.notifier).state = null;
      await settle(tester);
      expect(find.byKey(const ValueKey('hub-body')), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      await tearDownShell(tester, s);
    });

    testWidgets('the keyboard that falls out of the page comes back to it, and Esc works', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      await settle(tester);
      // As when a window's focus comes back with nobody left to give it to.
      FocusManager.instance.rootScope.requestScopeFocus();
      await settle(tester);
      expect(FocusManager.instance.primaryFocus, isNot(same(FocusManager.instance.rootScope)));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse);
      await tearDownShell(tester, s);
    });

    testWidgets('a window put in the background and brought back keeps the place in the form', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      c.read(supportHubOpenProvider.notifier).state = true;
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-body')));
      await settle(tester);
      // In the background a computer's focus manager lets go of the keyboard,
      // and gives it back by itself: the page must not take it in between, or
      // it gives up the place in the form.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      FocusManager.instance.rootScope.requestScopeFocus();
      await settle(tester);
      expect(FocusManager.instance.primaryFocus, same(FocusManager.instance.rootScope));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tearDownShell(tester, s);
    });

    testWidgets('a person\'s own F1 wins over the page\'s', (tester) async {
      final s = await hubShell(tester);
      final c = s.container;
      await c.read(shortcutBindingsProvider.notifier).setBinding(
            ShortcutAction.newConnection,
            ShortcutKey(keyId: LogicalKeyboardKey.f1.keyId),
          );
      await toShell(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.f1);
      await settle(tester);
      expect(c.read(supportHubOpenProvider), isFalse, reason: 'the default came after the person\'s own');
      expect(c.read(connectionEditorTargetProvider), isNotNull, reason: 'their action ran');
      expect(c.read(shortcutBindingProvider(ShortcutAction.supportHub)), isNull, reason: 'no hint of a key it has not');
      await tearDownShell(tester, s);
    });
  });

  // No picture, always on (3.0).
  testWidgets('copy and paste outside a terminal go by their keys in Settings, in a text field of the shell as well; '
      'so does a new connection',
      (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false);
    final c = s.container;
    String? clipboard;
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      switch (call.method) {
        case 'Clipboard.setData':
          clipboard = (call.arguments as Map)['text'] as String?;
          return null;
        case 'Clipboard.getData':
          return clipboard == null ? null : <String, Object?>{'text': clipboard};
        case 'Clipboard.hasStrings':
          return <String, Object?>{'value': clipboard != null};
      }
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(SystemChannels.platform, null));
    final keys = c.read(shortcutBindingsProvider.notifier);
    await keys.setBinding(ShortcutAction.copySelection, ShortcutKey(keyId: LogicalKeyboardKey.keyC.keyId, alt: true));
    await keys.setBinding(ShortcutAction.paste, ShortcutKey(keyId: LogicalKeyboardKey.keyV.keyId, alt: true));

    final field = find.descendant(of: find.byType(HostsHomePage), matching: find.byType(TextField));
    await tester.tap(field.first);
    await settle(tester);
    final controller = tester.widget<TextField>(field.first).controller!;
    Future<void> press(LogicalKeyboardKey key, List<LogicalKeyboardKey> held) async {
      for (final k in held) {
        await tester.sendKeyDownEvent(k);
      }
      await tester.sendKeyEvent(key);
      for (final k in held.reversed) {
        await tester.sendKeyUpEvent(k);
      }
      await settle(tester);
    }

    const ctrlShift = [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft];
    controller.text = 'web-01';
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.pump();
    await press(LogicalKeyboardKey.keyC, ctrlShift);
    expect(clipboard, isNull, reason: 'Ctrl+Shift+C is not the key any more');
    await press(LogicalKeyboardKey.keyC, const [LogicalKeyboardKey.altLeft]);
    expect(clipboard, 'web-01');

    clipboard = 'db-02';
    controller.text = '';
    await tester.pump();
    await press(LogicalKeyboardKey.keyV, ctrlShift);
    expect(controller.text, isEmpty, reason: 'Ctrl+Shift+V is not the key any more');
    await press(LogicalKeyboardKey.keyV, const [LogicalKeyboardKey.altLeft]);
    expect(controller.text, 'db-02');

    // A new connection.
    await keys.setBinding(ShortcutAction.newConnection, ShortcutKey(keyId: LogicalKeyboardKey.f2.keyId, ctrl: true));
    tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
    await tester.pump();
    await press(LogicalKeyboardKey.keyN, ctrlShift);
    expect(find.byType(ConnectionEditScreen), findsNothing, reason: 'Ctrl+Shift+N is not the key any more');
    await press(LogicalKeyboardKey.f2, const [LogicalKeyboardKey.controlLeft]);
    expect(find.byType(ConnectionEditScreen), findsOneWidget);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0).
  testWidgets("the palette's key is the one Settings binds it to, inside a terminal as well; Ctrl+Shift+P opens it "
      'always, and stays open (it opened and closed at once), and a key it was moved away from is the terminal\'s',
      (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false);
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    live.set({'s0': _session(0)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    tabs.setActiveTab(tabs.tabContaining('s0')!.id);
    await settle(tester);
    final terminal = live.state['s0']!.session!.terminal;
    final typed = <String>[];
    terminal.onOutput = typed.add;

    Future<void> press(LogicalKeyboardKey key, List<LogicalKeyboardKey> held) async {
      for (final k in held) {
        await tester.sendKeyDownEvent(k);
      }
      await tester.sendKeyEvent(key);
      for (final k in held.reversed) {
        await tester.sendKeyUpEvent(k);
      }
      await settle(tester);
    }

    // The palette's field, empty, says what it is for.
    final l10n = lookupAppLocalizations(const Locale('en'));
    bool paletteOpen() => find.text(l10n.zestPaletteHint).evaluate().isNotEmpty;
    Future<void> close() async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(paletteOpen(), isFalse);
    }

    const ctrlShift = [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft];
    const ctrlAlt = [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.altLeft];
    const cmdShift = [LogicalKeyboardKey.metaLeft, LogicalKeyboardKey.shiftLeft];

    // Outside a terminal: Ctrl+Shift+P, and the default Ctrl+Shift+K.
    tester.widget<KeyboardListener>(find.byType(KeyboardListener).first).focusNode.requestFocus();
    await tester.pump();
    await press(LogicalKeyboardKey.keyP, ctrlShift);
    expect(paletteOpen(), isTrue);
    await close();

    // Moved to Ctrl+Alt+K.
    await c
        .read(shortcutBindingsProvider.notifier)
        .setBinding(ShortcutAction.commandPalette, ShortcutKey(keyId: LogicalKeyboardKey.keyK.keyId, ctrl: true, alt: true));
    await tester.tap(find.byType(TerminalView).first);
    await settle(tester);
    typed.clear();
    await press(LogicalKeyboardKey.keyK, ctrlAlt);
    expect(paletteOpen(), isTrue, reason: 'its key, from inside a terminal');
    await close();
    await tester.tap(find.byType(TerminalView).first);
    await settle(tester);
    typed.clear();
    await press(LogicalKeyboardKey.keyK, ctrlShift);
    expect(paletteOpen(), isFalse, reason: 'Ctrl+Shift+K is not its key any more');
    expect(typed, isNotEmpty, reason: 'it went to the terminal');
    typed.clear();
    await press(LogicalKeyboardKey.keyK, cmdShift);
    expect(paletteOpen(), isFalse, reason: "Cmd+Shift+K was Ctrl+Shift+K's twin");
    await press(LogicalKeyboardKey.keyP, ctrlShift);
    expect(paletteOpen(), isTrue, reason: 'Ctrl+Shift+P is kept');
    await close();

    // Back to Ctrl+Shift+K: Cmd+Shift+K is its twin again.
    await c.read(shortcutBindingsProvider.notifier).resetBinding(ShortcutAction.commandPalette);
    await tester.tap(find.byType(TerminalView).first);
    await settle(tester);
    await press(LogicalKeyboardKey.keyK, cmdShift);
    expect(paletteOpen(), isTrue);
    await close();
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0: a plain dialog that said
  // "Could not connect to host:port" in English).
  testWidgets("a connection that failed is said in the app's words, and Try again connects again", (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    live.opened = [];
    c.read(connectionErrorProvider.notifier).state = ConnectionError(
      host: '10.50.0.22',
      port: 22,
      errorMessage: 'SocketException: Connection refused',
      connectionLabel: 'web-02',
      connectionId: 'c1',
    );
    await settle(tester);
    expect(find.byType(ConnectionFailedDialog), findsOneWidget);
    await tester.tap(find.text(lookupAppLocalizations(const Locale('en')).retry));
    await settle(tester);
    expect(find.byType(ConnectionFailedDialog), findsNothing);
    expect(live.opened, ['c1'], reason: 'the same host, opened again');
    expect(c.read(connectionErrorProvider), isNull, reason: 'cleared once the dialog closed');
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0: a tab whose connection dropped
  // showed another session's terminal, and its header named that session).
  testWidgets('a tab whose connection dropped shows it there, with why and Reconnect, which connects it again in '
      'its place', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    // web-02 between two others, so the place it is shown in is its own and
    // not the place it had among the live ones.
    live.set({for (var i = 0; i < 3; i++) 's$i': _session(i)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final first = tabs.tabContaining('s0')!.id;
    final second = tabs.tabContaining('s1')!.id;
    tabs.setActiveTab(second);
    await settle(tester);

    // web-02's connection drops, and the tries of connecting again are over.
    live.set({
      's0': _session(0),
      's2': _session(2),
      's1': SessionState.disconnected(
        connectionId: 'c1',
        connectionLabel: 'web-02',
        host: '10.50.0.22',
        port: 22,
        errorMessage: 'SocketException: No route to host',
        connectionLog: const ['error: SocketException: No route to host'],
        dropped: true,
      ).copyWith(reconnectAttempt: 10, maxRetries: 10),
    });
    await settle(tester);
    expect(c.read(workTabsProvider).activeTabId, second, reason: 'its tab stays');
    expect(find.byKey(const ValueKey('connection-lost-s1')).hitTestable(), findsOneWidget);
    expect(find.text(en.connectionLostTitle), findsOneWidget);
    expect(find.text(en.terminalAutoReconnectFailed(10)), findsOneWidget);
    for (final other in ['web-01', 'mac-studio']) {
      expect(find.descendant(of: find.byType(SessionHeaderBar), matching: find.text(other)), findsNothing,
          reason: 'the header names the session of this tab, not another');
    }

    // The other tab is as it was.
    tabs.setActiveTab(first);
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')).hitTestable(), findsNothing);
    tabs.setActiveTab(second);
    await settle(tester);

    // Reconnect connects it again where it is: the same session, the same tab.
    live.debugShellFor = (connection) => _Shell();
    await tester.tap(find.byKey(const ValueKey('connection-lost-reconnect')));
    await settle(tester);
    expect(c.read(activeSessionsProvider)['s1']!.status, SessionStatus.connected);
    expect(tabs.tabContaining('s1')!.id, second);
    expect(find.byKey(const ValueKey('connection-lost-s1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0: a split pane whose session
  // dropped said "Session not found").
  testWidgets('a dropped session in a split is shown in its pane; hidden or popped out it is not; the only session '
      'dropped is shown, not the empty start', (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions;
    SessionState dropped({bool dropped = true}) => SessionState.disconnected(
        connectionId: 'c1', connectionLabel: 'web-02', host: '10.50.0.22', port: 22, dropped: dropped);
    live.set({'s0': _session(0), 's1': _session(1)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    tabs.mergeTabs(tabs.tabContaining('s0')!.id, tabs.tabContaining('s1')!.id);
    final both = tabs.tabContaining('s1')!.id;
    expect(tabs.tabContaining('s0')!.id, both);
    tabs.setActiveTab(both);
    await settle(tester);

    live.set({'s0': _session(0), 's1': dropped()});
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')).hitTestable(), findsOneWidget, reason: 'in its pane');
    expect(find.text(en.desktopTerminalAreaSessionNotFound), findsNothing);
    expect(find.byKey(const ValueKey('connection-lost-s0')), findsNothing, reason: 'web-01 is as it was');

    // Ended or disconnected on purpose (it stays disconnected for a moment as
    // it goes): not told as lost.
    live.set({'s0': _session(0), 's1': dropped(dropped: false)});
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')), findsNothing);

    // Hidden, or popped out to a window of its own: not shown here.
    live.set({'s0': _session(0), 's1': dropped().copyWith(isHidden: true)});
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')), findsNothing);
    live.set({'s0': _session(0), 's1': dropped()});
    c.read(detachedSessionsProvider.notifier).detach('s1');
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')), findsNothing);
    c.read(detachedSessionsProvider.notifier).reattach('s1');

    // The only session left dropped: shown, and not the empty start.
    live.set({'s1': dropped()});
    await settle(tester);
    expect(find.byKey(const ValueKey('connection-lost-s1')).hitTestable(), findsOneWidget);
    expect(find.text(en.connectionLostEnded('web-02')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0: the hosts that could not be
  // loaded had no details to copy; the error went to a console).
  testWidgets('the Hosts page says when the hosts could not be loaded, and loads them again', (tester) async {
    var tries = 0;
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [
        connectionsWithDetailsProvider.overrideWith((ref) {
          tries++;
          return Stream<List<ConnectionWithDetails>>.error(StateError('disk I/O error'));
        }),
      ],
    );
    final l10n = lookupAppLocalizations(const Locale('en'));
    final state = find.byType(LoadErrorState);
    expect(state, findsOneWidget);
    expect(find.descendant(of: state, matching: find.text(l10n.hostsHomeLoadError)), findsOneWidget);
    expect(find.descendant(of: state, matching: find.text(l10n.desktopShellCopyDetails)), findsOneWidget);
    final before = tries;
    await tester.tap(find.byKey(const ValueKey('load-error-retry')));
    await settle(tester);
    expect(tries, greaterThan(before), reason: 'Try again loads them again');
    await tearDownShell(tester, s);
  });

  // No picture, always on (in 2.2.1, a host duplicated and then
  // its first session closed showed as not open
  // anywhere, though its second session still was).
  testWidgets('a host with two sessions is shown as open until both are closed', (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    // web-01 twice (a duplicate of its session), web-02 once.
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      's0': _session(0),
      's0b': _session(0, id: 's0b'),
      's1': _session(1),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    Map<String, SessionState> sessions() => c.read(activeSessionsProvider);

    /// Closes the tab of [session] by its pill, and lets the time to take
    /// it back run out.
    Future<void> closeTabOf(String session) async {
      final tab = tabs.tabContaining(session)!.id;
      tabs.setActiveTab(tab);
      await settle(tester);
      await tester.tap(find.byKey(ValueKey(tab)), buttons: kMiddleMouseButton);
      await tester.pump();
      await tester.pump(const Duration(seconds: 7));
      await settle(tester);
      await tester.pump(const Duration(seconds: 3));
      await settle(tester);
    }

    /// The Hosts page's card of [host], as it stands with no tab in front.
    Future<HostCardData> card(String host) async {
      tabs.clearActiveTab();
      await settle(tester);
      return tester
          .widgetList<HostCard>(find.byType(HostCard, skipOffstage: false))
          .firstWhere((w) => w.data.name == host)
          .data;
    }

    await closeTabOf('s0');
    expect(sessions().keys, unorderedEquals(['s0b', 's1']), reason: 'only the tab that was closed');
    expect(sessions()['s0b']!.status, SessionStatus.connected);
    expect(c.read(workTabsProvider).tabs.map((t) => t.sessionIds), [
      ['s0b'],
      ['s1'],
    ]);
    var web01 = await card('web-01');
    expect(web01.hasActiveSession, isTrue, reason: 'its duplicate is still open');
    expect(web01.status, HostStatus.online);
    expect((await card('web-02')).status, HostStatus.online);

    await closeTabOf('s0b');
    expect(sessions().keys, ['s1']);
    web01 = await card('web-01');
    expect(web01.hasActiveSession, isFalse);
    expect(web01.status, HostStatus.offline);
    expect((await card('web-02')).hasActiveSession, isTrue);
    await tearDownShell(tester, s);
  });

  // No picture, always on (in 2.2.1 there was no clear way to stop
  // broadcasting, nor to turn single broadcasts on and
  // off easily).
  testWidgets('broadcast has a button of its own, a switch on each pane, and stops from inside a terminal',
      (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 3; i++) 's$i': _session(i),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final tab = tabs.tabContaining('s0')!.id;
    for (final id in ['s1', 's2']) {
      tabs.mergeTabs(tabs.tabContaining(id)!.id, tab);
    }
    tabs.setActiveTab(tab);
    await settle(tester);
    BroadcastModeState state() => c.read(broadcastModeProvider);
    final l10n = lookupAppLocalizations(const Locale('en'));

    // The button beside Layout opens the pop-over; its switch turns it on.
    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('broadcast-switch')));
    await settle(tester);
    expect(state().broadcasts(tab), isTrue);
    expect(find.byKey(const ValueKey('broadcast-receiver-s2')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(BroadcastPopover), findsNothing);
    // From the pop-over, "Broadcast to hosts" (the pop-over closes first).
    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('broadcast-choose-hosts')));
    await settle(tester);
    expect(find.byType(BroadcastPopover), findsNothing);
    expect(find.byType(BroadcastToHostsDialog), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    // The Layout pop-over has no switch for it any more.
    await tester.tap(find.text(l10n.sessionHeaderLayout).first);
    await settle(tester);
    expect(find.byKey(const ValueKey('broadcast-switch')), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);

    // Every pane says it is typed into; one is left out from its own header.
    for (final id in ['s0', 's1', 's2']) {
      expect(find.byKey(ValueKey('pane-broadcast-$id')), findsOneWidget, reason: id);
    }
    await tester.tap(find.byKey(const ValueKey('pane-broadcast-s1')));
    await settle(tester);
    expect(state().leftOut(tab), {'s1'});
    // The tab's pill says it broadcasts.
    expect(find.byKey(ValueKey('tab-broadcasting-$tab')), findsOneWidget);

    // With a terminal in front, Ctrl+Shift+B stops it (it used to reach the
    // terminal as Ctrl+B), and starts it again.
    await tester.tap(find.byType(TerminalView).first);
    await settle(tester);
    Future<void> chord() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    await chord();
    expect(state().broadcasts(tab), isFalse);
    expect(find.byKey(ValueKey('tab-broadcasting-$tab')), findsNothing);
    expect(find.byKey(const ValueKey('pane-broadcast-s0')), findsNothing);
    await chord();
    expect(state().broadcasts(tab), isTrue);
    expect(state().leftOut(tab), isEmpty, reason: 'started again, every pane takes part');

    // Down to one terminal on screen: it stops by itself, and says so.
    tabs.splitSessionToNewTab('s2');
    tabs.setActiveTab(tab);
    await settle(tester);
    expect(state().broadcasts(tab), isTrue);
    tabs.splitSessionToNewTab('s1');
    tabs.setActiveTab(tab);
    await settle(tester);
    expect(state().broadcasts(tab), isFalse);
    expect(
      find.text(l10n.broadcastStoppedOneTerminal).evaluate().isNotEmpty ||
          c.read(notificationCenterProvider).history.any((n) => n.title == l10n.broadcastStoppedOneTerminal),
      isTrue,
    );
    await tearDownShell(tester, s);
  });

  // No picture, always on.
  testWidgets('the palette starts and stops broadcast for the tab in front, and opens Broadcast to hosts and Run on '
      'hosts (so does Broadcast\'s pop-over), Quick connect (signed in as the user typed) and the CSV import',
      (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    final l10n = lookupAppLocalizations(const Locale('en'));
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({
      for (var i = 0; i < 2; i++) 's$i': _session(i),
    });
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    final tab = tabs.tabContaining('s0')!.id;
    tabs.mergeTabs(tabs.tabContaining('s1')!.id, tab);
    tabs.setActiveTab(tab);
    await settle(tester);

    /// Opens the palette and narrows it to [query].
    Future<void> palette(String query) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, query);
      await settle(tester);
    }

    await palette('broadcast');
    expect(find.text(l10n.desktopCmdDisableBroadcast), findsNothing);
    await tester.tap(find.text(l10n.desktopCmdEnableBroadcast));
    await settle(tester);
    expect(c.read(broadcastModeProvider).broadcasts(tab), isTrue);

    await palette('broadcast');
    expect(find.text(l10n.desktopCmdEnableBroadcast), findsNothing);
    await tester.tap(find.text(l10n.desktopCmdDisableBroadcast));
    await settle(tester);
    expect(c.read(broadcastModeProvider).any, isFalse);

    await palette('broadcast');
    await tester.tap(find.text(l10n.desktopCmdBroadcastToHosts));
    await settle(tester);
    expect(find.byType(BroadcastToHostsDialog), findsOneWidget);
    await tester.tap(find.text(l10n.cancel));
    await settle(tester);
    expect(find.byType(BroadcastToHostsDialog), findsNothing);

    // Run on hosts (3.0), from the palette and from Broadcast's pop-over.
    await palette('run on hosts');
    await tester.tap(find.text(l10n.runOnHostsMenu));
    await settle(tester);
    expect(find.byType(RunOnHostsDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(RunOnHostsDialog), matching: find.text(l10n.cancel)));
    await settle(tester);
    expect(find.byType(RunOnHostsDialog), findsNothing);
    await tester.tap(find.byKey(const ValueKey('broadcast-button')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('broadcast-run-on-hosts')));
    await settle(tester);
    expect(find.byType(BroadcastPopover), findsNothing, reason: 'the pop-over closes first');
    expect(find.byType(RunOnHostsDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(RunOnHostsDialog), matching: find.text(l10n.cancel)));
    await settle(tester);
    expect(find.byType(RunOnHostsDialog), findsNothing);

    // Quick connect (3.0): signed in as the user typed, where it signed in as
    // the default user; an IPv6 address in brackets read whole.
    final sessions = c.read(activeSessionsProvider.notifier) as _Sessions;
    await palette('quick connect');
    await tester.tap(find.text(l10n.desktopQuickConnect).last);
    await settle(tester);
    await tester.enterText(find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField)),
        'deploy@[2001:db8::1]:2222');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    final (quick, user) = sessions.quick.single;
    expect(user, 'deploy');
    expect((quick.host, quick.port, quick.label), ('2001:db8::1', 2222, 'deploy@[2001:db8::1]'));

    // Import hosts from a CSV file (3.0), from the palette.
    await palette('csv');
    await tester.tap(find.text(l10n.csvImpTitle));
    await settle(tester);
    expect(find.byType(CsvImportDialog), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(CsvImportDialog), matching: find.text(l10n.cancel)));
    await settle(tester);
    expect(find.byType(CsvImportDialog), findsNothing);

    // A tab of one terminal is offered no broadcast of its own.
    tabs.splitSessionToNewTab('s1');
    await settle(tester);
    await palette('broadcast');
    expect(find.text(l10n.desktopCmdEnableBroadcast), findsNothing);
    expect(find.text(l10n.desktopCmdBroadcastToHosts), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tearDownShell(tester, s);
  });

  // No picture, always on (2.2.1, thirteen terminals in one
  // group: a pane's header had tmux and snippets, and no host name).
  testWidgets('in a tab of thirteen terminals, and of sixteen, every host is named whole on its pane', (tester) async {
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      extra: [isProProvider.overrideWith((ref) => _Pro(true))],
    );
    final c = s.container;
    const names = [
      'hypervisor-b', 'build-runner', 'db-primary', 'edge-router', 'log-store', 'monitoring', 'vpn-gateway',
      'cache-01', 'mac-studio', 'web-01', 'web-02', 'staging-api', 'grafana-01', 'backup-nas', 'mail-relay',
      'ci-worker-3',
    ];
    SessionState node(int i) => SessionState(
          status: SessionStatus.connected,
          connectionId: 'n$i',
          connectionLabel: names[i],
          host: '10.50.0.${100 + i}',
          port: 22,
          username: 'deploy',
          session: TerminalSession(
            id: 'n$i',
            connectionId: 'n$i',
            terminal: _terminal('deploy', names[i]),
            shell: _Shell(),
            startedAt: DateTime(2026, 10, 3, 9),
          ),
        );
    for (final count in [13, 16]) {
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({
        for (var i = 0; i < count; i++) 'n$i': node(i),
      });
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      final tab = tabs.tabContaining('n0')!.id;
      for (var i = 1; i < count; i++) {
        tabs.mergeTabs(tabs.tabContaining('n$i')!.id, tab);
      }
      tabs.setActiveTab(tab);
      await settle(tester);
      for (var i = 0; i < count; i++) {
        final header = find.byKey(ValueKey('pane-name-n$i'));
        expect(header, findsOneWidget, reason: '$count: ${names[i]}');
        final name = find.descendant(of: header, matching: find.text(names[i]));
        expect(name, findsOneWidget, reason: '$count: ${names[i]}');
        final paragraph = tester.renderObject<RenderParagraph>(name);
        expect(paragraph.didExceedMaxLines, isFalse, reason: '$count: ${names[i]} is cut');
      }
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({});
      await settle(tester);
    }
    await tearDownShell(tester, s);
  });
  // No picture, always on (3.0: a plain dialog made the app's own).
  testWidgets('a host that speaks Telnet is opened only after the warning that nothing encrypts it was answered '
      'with Connect Anyway', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('en'));
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      // One of the hosts speaks Telnet (the router, c6).
      seed: (db) => (db.update(db.connections)..where((t) => t.id.equals('c6')))
          .write(const ConnectionsCompanion(protocol: Value('telnet'), port: Value(23))),
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions..opened = [];
    final all = await tester.runAsync(() => c.read(databaseProvider).connectionsDao.watchAllWithDetails().first);
    final telnet = all!.singleWhere((i) => i.connection.id == 'c6');
    expect(telnet.connection.protocol, 'telnet');
    final ssh = all.singleWhere((i) => i.connection.id == 'c3');
    final hosts = tester.widget<HostsHomePage>(find.byType(HostsHomePage));
    Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));

    // Cancel: nothing is opened.
    hosts.onConnectTo(telnet);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(inQuestion(l10n.desktopShellUnencryptedConnection), findsOneWidget);
    expect(inQuestion(l10n.desktopShellTelnetWarning), findsOneWidget);
    expect(live.opened, isEmpty, reason: 'not before the answer');
    await tester.tap(inQuestion(l10n.cancel));
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(live.opened, isEmpty);

    // Connect Anyway: it is opened.
    hosts.onConnectTo(telnet);
    await settle(tester);
    await tester.tap(inQuestion(l10n.desktopShellConnectAnyway));
    await settle(tester);
    expect(live.opened, ['c6']);

    // A host that speaks SSH is opened with no question.
    hosts.onConnectTo(ssh);
    await settle(tester);
    expect(find.byType(ZestConfirmDialog), findsNothing);
    expect(live.opened, ['c6', 'c3']);
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0, found while comparing the five
  // versions): a terminal that is not one of the shell's panes (a tmux pane,
  // a shared session's view) was not taken for a terminal, so the app's
  // shortcuts (Ctrl+T, Ctrl+B, Ctrl+,) took its keys.
  testWidgets("Ctrl+T in a tmux pane's terminal goes to the terminal; outside any terminal it is Quick connect",
      (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false);
    final terminal = Terminal();
    final typed = <String>[];
    terminal.onOutput = typed.add;
    final pane = FocusNode(debugLabel: 'tmux %1');
    addTearDown(pane.dispose);
    final shell = tester.element(find.byType(DesktopShell));
    unawaited(showDialog<void>(
      context: shell,
      builder: (_) => Dialog(
        child: SizedBox(width: 480, height: 300, child: TerminalView(terminal, focusNode: pane, autofocus: true)),
      ),
    ));
    await settle(tester);
    pane.requestFocus();
    await tester.pump();
    Future<void> ctrlT() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyT);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    await ctrlT();
    expect(find.byType(QuickConnectV3), findsNothing);
    expect(typed.join(), contains('\x14'), reason: 'Ctrl+T, to the terminal');

    Navigator.of(shell).pop();
    await settle(tester);
    pane.unfocus();
    await tester.pump();
    await ctrlT();
    expect(find.byType(QuickConnectV3), findsOneWidget, reason: 'outside any terminal, as before');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): Find in terminal was a bar of the shell's own, for the first
  // session of the strip's wherever the keyboard was; it counted matches,
  // marked none and brought none into view, and its key did nothing from
  // inside a terminal.
  group('Find in terminal', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final bar = find.byType(TerminalSearchBar);
    Finder field() => find.descendant(of: bar, matching: find.byType(TextField));
    bool fieldHasKeyboard(WidgetTester tester) => tester.widget<TextField>(field()).focusNode!.hasFocus;
    Finder viewAt(Terminal terminal) =>
        find.byWidgetPredicate((w) => w is TerminalView && identical(w.terminal, terminal));
    TerminalView viewOf(WidgetTester tester, Terminal terminal) => tester.widget<TerminalView>(viewAt(terminal));
    Terminal searched(WidgetTester tester) => tester.widget<TerminalSearchBar>(bar).terminal;

    /// The buffer line of [terminal] that has [text].
    int lineOf(Terminal terminal, String text) {
      for (var i = 0; i < terminal.buffer.lines.length; i++) {
        if (terminal.buffer.lines[i].toString().contains(text)) return i;
      }
      throw StateError('no $text');
    }

    /// Whether buffer line [line] of [terminal]'s view is on screen, whole.
    bool shows(WidgetTester tester, Terminal terminal, int line) {
      final height = tester.state<TerminalViewState>(viewAt(terminal)).renderTerminal.lineHeight;
      final pos = tester
          .state<ScrollableState>(find.descendant(of: viewAt(terminal), matching: find.byType(Scrollable)))
          .position;
      return line * height >= pos.pixels - 0.5 && (line + 1) * height <= pos.pixels + pos.viewportDimension + 0.5;
    }

    Future<void> chord(WidgetTester tester, {bool shift = true, bool alt = false}) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      if (shift) await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      if (alt) await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      if (alt) await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      if (shift) await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
    }

    Future<void> escape(WidgetTester tester) async {
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
    }

    /// web-01 and web-02 side by side in one tab, web-01 in front: "needle"
    /// once in each, in web-02 up in 150 lines of scrollback.
    Future<(_Shell0, Terminal, Terminal)> split(WidgetTester tester) async {
      final s = await pumpShell(tester, 'default_dark', picture: false);
      final c = s.container;
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's1': _session(1)});
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      tabs.mergeTabs(tabs.tabContaining('s1')!.id, tabs.tabContaining('s0')!.id);
      tabs.setActiveTab(tabs.tabContaining('s0')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      final first = c.read(activeSessionsProvider)['s0']!.session!.terminal;
      final second = c.read(activeSessionsProvider)['s1']!.session!.terminal;
      first.write('needle in web-01\r\n');
      for (var i = 0; i < 150; i++) {
        second.write(i == 30 ? 'needle in web-02\r\n' : 'line $i\r\n');
      }
      await settle(tester);
      return (s, first, second);
    }

    testWidgets("its key in a pane's terminal opens it there, not in the first of the tab, and brings a match into "
        'view; Escape closes it, the keyboard back in that terminal; outside any terminal it opens for the focused '
        'pane, else for the one last clicked into', (tester) async {
      final (s, first, second) = await split(tester);
      final c = s.container;
      final needle = lineOf(second, 'needle');
      expect(shows(tester, second, needle), isFalse, reason: 'up in the scrollback');

      viewOf(tester, second).focusNode!.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsOneWidget, reason: 'from inside a terminal its key did nothing');
      expect(searched(tester), same(second), reason: 'the terminal the keyboard is in');
      final barAt = tester.getRect(bar), paneAt = tester.getRect(viewAt(second));
      expect(barAt.bottom, lessThanOrEqualTo(paneAt.top + 1), reason: 'above that pane');
      expect(paneAt.left <= barAt.center.dx && barAt.center.dx <= paneAt.right, isTrue, reason: 'above that pane');
      expect(fieldHasKeyboard(tester), isTrue);

      await tester.enterText(field(), 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(find.descendant(of: bar, matching: find.text('1/1')), findsOneWidget);
      expect(shows(tester, second, needle), isTrue, reason: 'its match brought into view');

      await escape(tester);
      expect(bar, findsNothing);
      expect(viewOf(tester, second).focusNode!.hasFocus, isTrue, reason: 'the keyboard back in that terminal');

      final tab = c.read(workTabsProvider).activeTab!;
      c.read(focusedPaneProvider.notifier).state =
          tab.paneTree.allLeaves.firstWhere((l) => l.sessionIds.contains('s1')).id;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await chord(tester);
      expect(searched(tester), same(second), reason: "outside any terminal: the focused pane's");
      expect(fieldHasKeyboard(tester), isTrue);
      await escape(tester);
      expect(viewOf(tester, second).focusNode!.hasFocus, isTrue, reason: 'closed, the keyboard in its terminal');

      c.read(focusedPaneProvider.notifier).state = null;
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await chord(tester);
      expect(searched(tester), same(first), reason: 'no pane focused: the one last clicked into');
      await escape(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('asked for again where it is open, its field takes the keyboard back and it stays open; asked for '
        "from the other pane's terminal, it moves there", (tester) async {
      final (s, first, second) = await split(tester);
      viewOf(tester, first).focusNode!.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(searched(tester), same(first));

      viewOf(tester, first).focusNode!.requestFocus();
      await tester.pump();
      expect(fieldHasKeyboard(tester), isFalse);
      await chord(tester);
      expect(bar, findsOneWidget, reason: 'still open');
      expect(fieldHasKeyboard(tester), isTrue, reason: 'its field has the keyboard again');
      await chord(tester);
      expect(bar, findsOneWidget, reason: 'asked for in the bar itself: open as it was');
      expect(fieldHasKeyboard(tester), isTrue);

      viewOf(tester, second).focusNode!.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsOneWidget);
      expect(searched(tester), same(second), reason: 'moved there');
      expect(fieldHasKeyboard(tester), isTrue);
      await chord(tester);
      expect(searched(tester), same(second), reason: 'asked for in its bar: it stays, not the session in front');
      expect(fieldHasKeyboard(tester), isTrue);
      await escape(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('the key Settings binds it to opens it, from a terminal and from outside one, and the key before does '
        'not', (tester) async {
      final (s, first, _) = await split(tester);
      await s.container.read(shortcutBindingsProvider.notifier).setBinding(
          ShortcutAction.findInTerminal, ShortcutKey(keyId: LogicalKeyboardKey.keyF.keyId, ctrl: true, alt: true));
      viewOf(tester, first).focusNode!.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsNothing, reason: 'Ctrl+Shift+F is not the key any more');
      await chord(tester, shift: false, alt: true);
      expect(searched(tester), same(first));
      await escape(tester);

      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsNothing);
      await chord(tester, shift: false, alt: true);
      expect(bar, findsOneWidget);
      await escape(tester);
      await tearDownShell(tester, s);
    });

    testWidgets("a terminal that is no session's own has no Find of the shell's; with no terminal in front the person "
        'is told so', (tester) async {
      final (s, _, _) = await split(tester);
      final shell = tester.element(find.byType(DesktopShell));
      final shared = Terminal();
      final keys = FocusNode(debugLabel: 'shared view');
      addTearDown(keys.dispose);
      unawaited(showDialog<void>(
        context: shell,
        builder: (_) => Dialog(child: SizedBox(width: 480, height: 300, child: TerminalView(shared, focusNode: keys))),
      ));
      await settle(tester);
      keys.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsNothing, reason: 'not the session in front, behind it');
      expect(find.text(l10n.desktopShellOpenTerminalToSearch), findsNothing);
      Navigator.of(shell).pop();
      await settle(tester);

      (s.container.read(activeSessionsProvider.notifier) as _Sessions).set({});
      await settle(tester);
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsNothing);
      expect(find.text(l10n.desktopShellOpenTerminalToSearch), findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      await tearDownShell(tester, s);
    });

    testWidgets("the palette's Find in terminal opens it for the session in front, its field with the keyboard once "
        'the palette is gone; a choice of the palette that gives the keyboard to something leaves it there (Quick '
        'connect), and one that does not gives it back to where it was', (tester) async {
      final (s, _, second) = await split(tester);
      final tab = s.container.read(workTabsProvider).activeTab!;
      s.container.read(focusedPaneProvider.notifier).state =
          tab.paneTree.allLeaves.firstWhere((l) => l.sessionIds.contains('s1')).id;

      /// From web-02's terminal, the palette's [item], found by [query].
      Future<void> pick(String query, String item) async {
        viewOf(tester, second).focusNode!.requestFocus();
        await tester.pump();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        await tester.enterText(find.byType(TextField).last, query);
        await settle(tester);
        await tester.tap(find.text(item).last);
        await settle(tester);
      }

      await pick('find in terminal', l10n.desktopShortcutFindInTerminal);
      expect(bar, findsOneWidget);
      expect(searched(tester), same(second));
      expect(fieldHasKeyboard(tester), isTrue, reason: 'the palette gave it back to the terminal');
      await escape(tester);

      await pick('quick connect', l10n.desktopQuickConnect);
      final quick = find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField));
      expect(tester.widget<TextField>(quick).focusNode!.hasFocus, isTrue,
          reason: 'it was given back to the terminal behind Quick connect');
      await escape(tester);
      expect(find.byType(QuickConnectV3), findsNothing);

      await pick('broadcast', l10n.desktopCmdEnableBroadcast);
      expect(viewOf(tester, second).focusNode!.hasFocus, isTrue, reason: 'back in the terminal it was in');
      await tearDownShell(tester, s);
    });

    testWidgets("in a tab in tmux mode it opens over tmux's panes, for the pane the keyboard is in, and closes back "
        'into it', (tester) async {
      final tmux = TmuxController(sendBytes: (_) {}, expectMarker: false);
      addTearDown(tmux.dispose);
      tmux.onData(utf8.encode('%session-changed \$0 main\n'));
      tmux.onData(utf8.encode('%layout-change @1 bc62,80x24,0,0,0 bc62,80x24,0,0,0 *\n'));
      final pane = tmux.windows.first.activePane!.terminal;
      for (var i = 0; i < 60; i++) {
        pane.write(i == 4 ? 'needle in tmux\r\n' : 'line $i\r\n');
      }
      final s = await pumpShell(
        tester,
        'default_dark',
        picture: false,
        prefsExtra: {'tmux_intro_seen': true},
        extra: [tmuxHostProvider.overrideWith((ref, sid) => _TmuxHost(sid, sid == 's0' ? tmux : null))],
      );
      final c = s.container;
      (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0)});
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      tabs.setActiveTab(tabs.tabContaining('s0')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      await settle(tester);
      expect(find.byType(TmuxSessionView), findsOneWidget);

      viewOf(tester, pane).focusNode!.requestFocus();
      await tester.pump();
      await chord(tester);
      expect(bar, findsOneWidget);
      expect(searched(tester), same(pane), reason: "the tmux pane's, not the session's own behind it");
      await tester.enterText(field(), 'needle');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump();
      expect(shows(tester, pane, lineOf(pane, 'needle')), isTrue);

      await escape(tester);
      expect(bar, findsNothing);
      expect(viewOf(tester, pane).focusNode!.hasFocus, isTrue, reason: 'the keyboard back in the tmux pane');
      await tearDownShell(tester, s);
    });
  });

  // No picture, always on (found while comparing the five
  // versions): Settings' port for new connections was read by nothing, and a
  // host typed with no port was reached on 22.
  testWidgets('a host typed with no port is reached on the port Settings gives new connections, from Quick connect '
      "and from the Hosts page's search", (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false, prefsExtra: {'default_port': 2200});
    final l10n = lookupAppLocalizations(const Locale('en'));
    final sessions = s.container.read(activeSessionsProvider.notifier) as _Sessions;
    (Connection, String?) quick() => sessions.quick.last;

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    await tester.enterText(find.byType(TextField).last, 'quick connect');
    await settle(tester);
    await tester.tap(find.text(l10n.desktopQuickConnect).last);
    await settle(tester);
    await tester.enterText(
        find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField)), 'deploy@203.0.113.20');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect((quick().$1.host, quick().$1.port, quick().$2), ('203.0.113.20', 2200, 'deploy'), reason: 'it was 22');

    final search = find.byKey(const ValueKey('hosts-quick-field'));
    await tester.enterText(search, 'ops@203.0.113.21');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect((quick().$1.host, quick().$1.port, quick().$2), ('203.0.113.21', 2200, 'ops'));
    await tester.enterText(search, 'ops@203.0.113.22:22');
    await tester.testTextInput.receiveAction(TextInputAction.go);
    await settle(tester);
    expect((quick().$1.host, quick().$1.port), ('203.0.113.22', 22), reason: 'a port typed is that port');
    await tester.pump(const Duration(seconds: 12));
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): the palette's Settings pushed a phone's page of Settings over
  // the shell, though it shows the key that opens the pop-up; its About
  // pushed a phone's About page; and the app lock said it takes biometrics on
  // a Mac alone, Touch ID or not, though Windows offers Windows Hello.
  testWidgets("the palette's Settings opens the pop-up and its About the shell's About; the app lock names "
      'biometrics where the computer has them', (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    PackageInfo.setMockInitialValues(
        appName: 'ZestSSH', packageName: 'com.zestssh.app', version: '3.0.0', buildNumber: '256', buildSignature: '');
    for (final biometrics in [true, false]) {
      FlutterSecureStorage.setMockInitialValues({});
      final s = await pumpShell(tester, 'default_dark',
          picture: false, extra: [biometricAvailableProvider.overrideWith((ref) async => biometrics)]);
      Future<void> pick(String query, String item) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
        await tester.enterText(find.byType(TextField).last, query);
        await settle(tester);
        await tester.tap(find.text(item).last);
        await settle(tester);
      }

      if (biometrics) {
        await pick('settings', l10n.settingsTitle);
        expect(find.byType(SettingsInlineView), findsOneWidget, reason: 'the pop-up');
        expect(find.byType(SettingsScreen), findsNothing, reason: "a phone's page");
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
        expect(find.byType(SettingsInlineView), findsNothing);
        await pick('about', l10n.settingsAbout);
        expect(find.byType(AboutDialog), findsOneWidget);
        expect(find.text('3.0.0 (256)'), findsOneWidget);
        expect(find.byType(AboutScreen), findsNothing, reason: "a phone's page");
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
      }
      s.container.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.security;
      s.container.read(settingsPopupOpenProvider.notifier).state = true;
      await settle(tester);
      // What the app lock does is behind its More (4.0).
      await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsInlineAppLock}')));
      await settle(tester);
      expect(find.text(l10n.settingsAppLockDescPinBiometric), biometrics ? findsOneWidget : findsNothing);
      expect(find.text(l10n.settingsAppLockDescPin), biometrics ? findsNothing : findsOneWidget);
      await tearDownShell(tester, s);
    }
  });

  // No picture: the check for updates could be turned
  // off, and no screen had its switch.
  testWidgets('About has the switch of the check for updates: on until turned off, and turned off it is kept',
      (tester) async {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final s = await pumpShell(tester, 'default_dark', picture: false);
    s.container.read(settingsPopupOpenProvider.notifier).state = true;
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('settings-nav-about')));
    await settle(tester);
    final toggle = find.byKey(const ValueKey('settings-update-check-automatic'));
    expect(UpdateCheckService.manualCheckSupported, isTrue, reason: 'a computer that updates from the website');
    expect(find.text(l10n.updateCheckAutomatic), findsOneWidget);
    // What it does is behind its More (4.0).
    expect(find.text(l10n.updateCheckAutomaticDesc), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.updateCheckAutomatic}')));
    await settle(tester);
    expect(find.text(l10n.updateCheckAutomaticDesc), findsOneWidget);
    expect(s.container.read(updateCheckEnabledProvider), isTrue, reason: 'on until turned off');
    await tester.ensureVisible(toggle);
    await settle(tester);
    await tester.tap(toggle);
    await settle(tester);
    expect(s.container.read(updateCheckEnabledProvider), isFalse);
    expect(s.container.read(sharedPreferencesProvider).getBool('update_check_enabled'), isFalse, reason: 'kept');
    await tester.tap(toggle);
    await settle(tester);
    expect(s.container.read(updateCheckEnabledProvider), isTrue);
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): a quick connect link, zestssh://connect?host=, was answered by
  // nothing. Its host is typed into Quick connect over the shell, for the
  // person to connect or not.
  testWidgets("a quick connect link's host is typed into Quick connect over the shell: one that came before the shell "
      'was up, and one that comes while it is', (tester) async {
    addTearDown(() => quickConnectLinkText.value = null);
    quickConnectLinkText.value = 'deploy@web-01.example.com:2222';
    final s = await pumpShell(tester, 'default_dark', picture: false);
    String typed() => tester
        .widget<TextField>(find.descendant(of: find.byType(QuickConnectV3), matching: find.byType(TextField)))
        .controller!
        .text;
    expect(find.byType(QuickConnectV3), findsOneWidget);
    expect(typed(), 'deploy@web-01.example.com:2222');
    expect(quickConnectLinkText.value, isNull, reason: 'taken once');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byType(QuickConnectV3), findsNothing, reason: 'nothing connected');
    quickConnectLinkText.value = 'ops@192.0.2.10';
    await settle(tester);
    expect(typed(), 'ops@192.0.2.10');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): the palette offered PuTTY's import on a Mac and on Linux, where
  // its page said it was for Windows alone.
  testWidgets("the palette offers PuTTY's saved sessions where they can be read, and not elsewhere", (tester) async {
    addTearDown(() => debugPuttyImportHere = null);
    final s = await pumpShell(tester, 'default_dark', picture: false);
    final l10n = lookupAppLocalizations(const Locale('en'));
    Future<bool> offered() async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, 'putty');
      await settle(tester);
      final found = find.text(l10n.commandPaletteSectionActionImportPutty).evaluate().isNotEmpty;
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      return found;
    }

    debugPuttyImportHere = false;
    expect(await offered(), isFalse, reason: 'not on a Mac nor on Linux');
    debugPuttyImportHere = true;
    expect(await offered(), isTrue, reason: 'on Windows');
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): a host chosen in the palette was started as a bare session: no
  // Telnet warning, nothing said at the free plan's limit.
  testWidgets('a host chosen in the palette is connected to as from the Hosts page: a Telnet host after its warning, '
      "with its tab in front; at the free plan's limit, said so", (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final l10n = lookupAppLocalizations(const Locale('en'));
    final s = await pumpShell(
      tester,
      'default_dark',
      picture: false,
      // The router, c6, speaks Telnet; web-02, c1, is a recent host.
      seed: (db) async {
        await (db.update(db.connections)..where((t) => t.id.equals('c6')))
            .write(const ConnectionsCompanion(protocol: Value('telnet'), port: Value(23)));
        await (db.update(db.connections)..where((t) => t.id.equals('c1')))
            .write(ConnectionsCompanion(lastConnected: Value(DateTime(2026, 10, 15))));
      },
    );
    final c = s.container;
    final live = c.read(activeSessionsProvider.notifier) as _Sessions..opened = [];
    Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));
    Future<void> pick(String host) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyK);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      await tester.enterText(find.byType(TextField).last, host);
      await settle(tester);
      await tester.tap(find.text(host).last);
      await settle(tester);
    }

    await pick('edge-router');
    expect(inQuestion(l10n.desktopShellTelnetWarning), findsOneWidget, reason: 'it was opened with no warning');
    expect(live.opened, isEmpty);
    await tester.tap(inQuestion(l10n.cancel));
    await settle(tester);
    expect(live.opened, isEmpty, reason: 'Cancel opens nothing');

    await pick('edge-router');
    await tester.tap(inQuestion(l10n.desktopShellConnectAnyway));
    await settle(tester);
    expect(live.opened, ['c6']);
    expect(c.read(v3ActiveSessionTabProvider), 'r1', reason: 'its tab in front');

    live.full = true;
    await pick('web-02'); // (among the recent hosts)
    expect(find.text(l10n.desktopShellFreeTierLimit(freeSessionLimit)), findsOneWidget, reason: 'nothing was said');
    await tester.pump(const Duration(seconds: 12));
    await tearDownShell(tester, s);
  });

  // No picture, always on (found while comparing the five
  // versions): a computer's pane showed the app's terminal theme, whatever
  // its host's form gave it.
  testWidgets("a session's pane shows its host's own terminal theme; one of a host with none, the app's", (tester) async {
    final s = await pumpShell(tester, 'default_dark', picture: false, prefsExtra: {'terminal_theme_c0': 'dracula'});
    final c = s.container;
    (c.read(activeSessionsProvider.notifier) as _Sessions).set({'s0': _session(0), 's1': _session(1)});
    await tester.pump();
    final tabs = c.read(workTabsProvider.notifier);
    tabs.mergeTabs(tabs.tabContaining('s1')!.id, tabs.tabContaining('s0')!.id);
    tabs.setActiveTab(tabs.tabContaining('s0')!.id);
    await settle(tester);
    TerminalTheme themeOf(String sid) {
      final terminal = c.read(activeSessionsProvider)[sid]!.session!.terminal;
      return tester
          .widget<TerminalView>(find.byWidgetPredicate((w) => w is TerminalView && identical(w.terminal, terminal)))
          .theme;
    }

    expect(themeOf('s0'), same(app_themes.TerminalThemes.all['dracula']), reason: "it showed the app's");
    expect(themeOf('s1'), same(c.read(terminalThemeProvider)));
    await tearDownShell(tester, s);
  });

  // No picture, always on (3.0): Settings is a pop-up over
  // whatever the shell shows, where it was a page of the shell that a terminal
  // had to be left for.
  group('Settings is a pop-up', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    const close = ValueKey('settings-popup-close');
    const search = ValueKey('settings-search');
    Finder nav(String section) => find.byKey(ValueKey('settings-nav-$section'));
    Finder popup() => find.byType(SettingsInlineView);
    // The title of the section on screen: the one text in the section header's style.
    Finder title(String text) => find.descendant(
          of: popup(),
          matching: find.byWidgetPredicate((w) => w is Text && w.data == text && w.style?.fontSize == 22),
        );

    Future<_Shell0> shell(WidgetTester tester, {Size? size}) async {
      FlutterSecureStorage.setMockInitialValues({});
      final s = await pumpShell(tester, 'default_dark', picture: false);
      if (size != null) {
        tester.view.physicalSize = size;
        await settle(tester);
      }
      return s;
    }

    Future<void> open(WidgetTester tester, _Shell0 s) async {
      s.container.read(settingsPopupOpenProvider.notifier).state = true;
      await settle(tester);
    }

    /// Whether [section] is the one marked in the list on the left.
    bool lit(WidgetTester tester, String section) => tester
        .widget<Semantics>(find
            .descendant(of: nav(section), matching: find.byWidgetPredicate((w) => w is Semantics && w.properties.button == true))
            .first)
        .properties
        .selected!;

    testWidgets('it opens over a session, which stays where it is; the gear, a stray request for the old page and '
        'a deep link all open it; closing it says so', (tester) async {
      final s = await shell(tester);
      final c = s.container;
      // No page of the shell is Settings any more, not one kept out of sight
      // among its pages either (they are all there while no terminal is in front).
      expect(find.byType(SettingsInlineView, skipOffstage: false), findsNothing);
      await openSessions(tester, s);
      expect(popup(), findsNothing);
      final tabBefore = c.read(workTabsProvider).activeTabId;

      await open(tester, s);
      expect(popup(), findsOneWidget);
      expect(find.byType(SettingsInlineView, skipOffstage: false), findsOneWidget, reason: 'one Settings, the pop-up');
      expect(c.read(v3ActiveSessionTabProvider), 's0', reason: 'the session is still the one in front');
      expect(c.read(workTabsProvider).activeTabId, tabBefore);
      expect(c.read(activeSidebarNavProvider), isNot(NavSection.settings));
      expect(find.byType(SessionHeaderBar), findsWidgets, reason: 'the terminal is still behind the pop-up');
      final size = tester.getSize(popup());
      // 1274 by 910 (test/ui/settings_popup_size_test.dart),
      // never larger than the window less its margin: 900 - 48 high here.
      expect(size.width, 1274);
      expect(size.height, 900 - 48);
      expect(tester.widget<NarrowSidebar>(find.byType(NarrowSidebar)).activeSection, NavSection.settings,
          reason: 'the gear is the item that is lit while Settings is open');

      // The cross closes it, and the provider says that it is closed.
      await tester.tap(find.byKey(close));
      await settle(tester);
      expect(popup(), findsNothing);
      expect(c.read(settingsPopupOpenProvider), isFalse);
      expect(c.read(v3ActiveSessionTabProvider), 's0');
      expect(tester.widget<NarrowSidebar>(find.byType(NarrowSidebar)).activeSection, isNull,
          reason: 'a terminal is in front: no section of the rail is lit');

      // The rail's gear.
      await tester.tap(find.byIcon(LucideIcons.settings).first);
      await settle(tester);
      expect(popup(), findsOneWidget);
      expect(c.read(activeSidebarNavProvider), isNot(NavSection.settings));
      expect(c.read(v3ActiveSessionTabProvider), 's0');
      // While it is open, a shortcut of the shell does nothing to what is behind it.
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await settle(tester);
      expect(c.read(workTabsProvider).activeTabId, tabBefore, reason: 'the tab behind Settings is not closed');
      expect(c.read(activeSessionsProvider).keys, containsAll(['s0', 's1', 's2', 's3']));
      expect(popup(), findsOneWidget);
      // Escape closes it.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(popup(), findsNothing);
      expect(c.read(settingsPopupOpenProvider), isFalse);

      // Whatever still asks for the page of old is given the pop-up, and the
      // page that was shown stays the shell's.
      c.read(activeSidebarNavProvider.notifier).state = NavSection.keys;
      await settle(tester);
      c.read(activeSidebarNavProvider.notifier).state = NavSection.settings;
      await settle(tester);
      expect(popup(), findsOneWidget);
      expect(c.read(activeSidebarNavProvider), NavSection.keys);
      // A click beside the pop-up closes it.
      await tester.tapAt(const Offset(40, 880));
      await settle(tester);
      expect(popup(), findsNothing);
      expect(c.read(settingsPopupOpenProvider), isFalse);

      // A deep link lands on its section, also while the pop-up is open.
      c.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.security;
      await open(tester, s);
      expect(title(l10n.settingsPageSecurityPrivacy), findsOneWidget);
      expect(c.read(settingsJumpProvider), isNull, reason: 'taken once');
      c.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.keyboard;
      await settle(tester);
      expect(title(l10n.settingsPageKeyboardMouse), findsOneWidget,
          reason: 'the key bindings are on Keyboard and mouse (4.0: Mouse and Keyboard shortcuts in one)');
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('one section at a time, chosen on the left; the last one is where it opens again; Backups and data '
        'holds the reset', (tester) async {
      final s = await shell(tester);
      await open(tester, s);
      // Every section has its entry, and General is where it starts.
      for (final name in [
        'account', 'plan', 'general', 'appearance', 'keyboard', 'notifications', //
        'terminal', 'files', 'screens', 'security', 'data', 'about',
      ]) {
        expect(nav(name), findsOneWidget, reason: name);
      }
      expect(nav('shortcuts'), findsNothing, reason: 'in Keyboard and mouse (4.0)');
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget);
      expect(lit(tester, 'general'), isTrue);
      expect(lit(tester, 'appearance'), isFalse);
      expect(find.text(l10n.settingsInlineResetAllSettings), findsNothing, reason: "Backups and data's (4.0)");
      await tester.tap(nav('data'));
      await settle(tester);
      expect(find.text(l10n.settingsInlineResetAllSettings), findsOneWidget);
      await tester.tap(nav('general'));
      await settle(tester);
      expect(find.text('More settings'), findsNothing, reason: 'no page of links any more');

      await tester.tap(nav('appearance'));
      await settle(tester);
      expect(title(l10n.settingsInlineSectionAppearance), findsOneWidget);
      expect(title(l10n.settingsInlineSectionGeneral), findsNothing);
      expect(lit(tester, 'appearance'), isTrue);
      expect(lit(tester, 'general'), isFalse);
      expect(find.text(l10n.settingsPageAppearanceDesc), findsOneWidget, reason: 'what the section holds, under its title');
      expect(find.text(l10n.settingsInlineResetAllSettings), findsNothing);

      await tester.tap(nav('about'));
      await settle(tester);
      expect(title(l10n.settingsInlineSectionAbout), findsOneWidget);

      await tester.tap(find.byKey(close));
      await settle(tester);
      await open(tester, s);
      expect(title(l10n.settingsInlineSectionAbout), findsOneWidget, reason: 'opened where it was left');
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('the search is on the left: its results take the pane, one of them opens its section at its row, '
        'and "/" goes to the field unless a field is being typed in', (tester) async {
      final s = await shell(tester);
      await open(tester, s);
      final field = find.byKey(search);
      expect(field, findsOneWidget);
      await tester.enterText(field, 'c');
      await settle(tester);
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget, reason: 'one letter is no search yet');
      await tester.enterText(field, 'cursor blink');
      await settle(tester);
      expect(title(l10n.settingsInlineSectionGeneral), findsNothing, reason: 'the results are shown, not a section');
      expect(lit(tester, 'general'), isFalse, reason: 'no section is the one on screen');
      // "/" in the field is a character to type: the pop-up leaves the key alone.
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.slash), isFalse);
      // Choosing a section ends the search.
      await tester.tap(nav('about'));
      await settle(tester);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(title(l10n.settingsInlineSectionAbout), findsOneWidget);
      await tester.enterText(field, 'cursor blink');
      await settle(tester);
      final hit = find.descendant(of: popup(), matching: find.textContaining('Cursor blink', findRichText: true));
      expect(hit, findsWidgets);
      await tester.tap(hit.first);
      await settle(tester);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'the search is over');
      expect(title(l10n.settingsPageTerminalSsh), findsOneWidget);

      // Nothing found says so, and Escape ends the search before it closes Settings.
      await tester.enterText(field, 'zzzzqq');
      await settle(tester);
      expect(find.text(l10n.settingsSearchNoResults), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(popup(), findsOneWidget);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);
      expect(title(l10n.settingsPageTerminalSsh), findsOneWidget);

      // "/" with no field in use: the cursor goes to the search field.
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isFalse);
      expect(await tester.sendKeyEvent(LogicalKeyboardKey.slash), isTrue);
      await tester.pump();
      expect(tester.widget<TextField>(field).focusNode!.hasFocus, isTrue);
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('the search finds the rows of the account page: "export" opens Backups and data at Export, and the '
        'SSH config export is there on a computer', (tester) async {
      final s = await shell(tester);
      await open(tester, s);
      await tester.enterText(find.byKey(search), 'export');
      await settle(tester);
      expect(find.text(l10n.settingsSearchNoResults), findsNothing, reason: 'it found nothing for "export"');
      final hit = find.descendant(of: popup(), matching: find.text(l10n.accountExport, findRichText: true));
      expect(hit, findsWidgets);
      await tester.tap(hit.first);
      await settle(tester);
      expect(title(l10n.settingsPageBackupsData), findsOneWidget);
      expect(find.text(l10n.accountExport).hitTestable(), findsOneWidget, reason: 'the Export row, in view');
      expect(find.byKey(const ValueKey('account-export-ssh-config')), findsOneWidget);
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('the search knows every row by the words of the row: one the old list lacked, and in German a German '
        'word finds its row and lands on it', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      var s = await pumpShell(tester, 'default_dark', picture: false);
      await open(tester, s);
      // A row of the host cards, which the list written by hand left out.
      await tester.enterText(find.byKey(search), 'hover edit');
      await settle(tester);
      final hover = find.descendant(
          of: popup(), matching: find.textContaining(l10n.settingsInlineHoverEditButton, findRichText: true));
      expect(hover, findsOneWidget);
      await tester.tap(hover);
      await settle(tester);
      expect(title(l10n.settingsInlineSectionAppearance), findsOneWidget);
      expect(find.text(l10n.settingsInlineHoverEditButton).hitTestable(), findsOneWidget, reason: 'its row is on screen');
      // Found by the words under a row's name as well.
      await tester.enterText(find.byKey(search), l10n.settingsInlineScrollbackBufferDesc.substring(0, 12));
      await settle(tester);
      expect(
        find.descendant(of: popup(), matching: find.textContaining(l10n.settingsInlineScrollbackBuffer, findRichText: true)),
        findsOneWidget,
      );
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);

      // German: a German word finds the row, and the result lands on it.
      final de = lookupAppLocalizations(const Locale('de'));
      expect(de.settingsInlineFontFamily, isNot(l10n.settingsInlineFontFamily));
      // (With the app's own fonts: German words are longer, and the test font is wider than any.)
      s = await pumpShell(tester, 'default_dark', locale: const Locale('de'));
      expect(tester.takeException(), isNull, reason: 'the German shell fits');
      await open(tester, s);
      await tester.enterText(find.byKey(search), de.settingsInlineFontFamily.toLowerCase());
      await settle(tester);
      final hit = find.descendant(
          of: popup(), matching: find.textContaining(de.settingsInlineFontFamily, findRichText: true));
      expect(hit, findsOneWidget);
      await tester.tap(hit);
      await settle(tester);
      expect(title(de.settingsPageTerminalSsh), findsOneWidget);
      expect(find.text(de.settingsInlineFontFamily).hitTestable(), findsOneWidget, reason: 'the row itself, in view');
      // The English word finds nothing there: the list is the rows' own words.
      await tester.enterText(find.byKey(search), 'font family');
      await settle(tester);
      expect(find.text(de.settingsSearchNoResults), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('after the app was closed Settings opens on the section it was left on; a section this version does '
        'not know is General', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      var s = await pumpShell(tester, 'default_dark', picture: false);
      await open(tester, s);
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget, reason: 'nothing kept yet');
      await tester.tap(nav('security'));
      await settle(tester);
      expect(s.container.read(sharedPreferencesProvider).getString(kSettingsLastSectionKey), 'security');
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);

      // The app again, over what this device kept.
      s = await pumpShell(tester, 'default_dark', picture: false, prefsExtra: {kSettingsLastSectionKey: 'security'});
      await open(tester, s);
      expect(title(l10n.settingsPageSecurityPrivacy), findsOneWidget);
      expect(lit(tester, 'security'), isTrue);
      // A result of the search is a section shown as well: it is kept.
      await tester.enterText(find.byKey(search), 'cursor blink');
      await settle(tester);
      await tester.tap(find
          .descendant(of: popup(), matching: find.textContaining(l10n.settingsInlineCursorBlink, findRichText: true))
          .first);
      await settle(tester);
      expect(s.container.read(sharedPreferencesProvider).getString(kSettingsLastSectionKey), 'terminal');
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);

      // A name this version does not have.
      s = await pumpShell(tester, 'default_dark', picture: false, prefsExtra: {kSettingsLastSectionKey: 'no-such-section'});
      await open(tester, s);
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget);
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('a sub-editor takes the pane with a way back, and choosing a section leaves it', (tester) async {
      final s = await shell(tester);
      final c = s.container;
      await open(tester, s);
      await tester.tap(nav('appearance'));
      await settle(tester);
      c.read(settingsDockProvider.notifier).state = SettingsDock.appThemeDesigner;
      await settle(tester);
      const back = ValueKey('settings-dock-back');
      expect(find.byKey(back), findsOneWidget);
      expect(find.text(l10n.settingsThemeDesignerDockTitle), findsOneWidget);
      expect(title(l10n.settingsInlineSectionAppearance), findsNothing, reason: 'the editor has the pane');
      expect(nav('appearance'), findsOneWidget, reason: 'the sections stay beside it');
      expect(find.byKey(close), findsOneWidget);

      await tester.tap(find.byKey(back));
      await settle(tester);
      expect(c.read(settingsDockProvider), SettingsDock.none);
      expect(title(l10n.settingsInlineSectionAppearance), findsOneWidget);

      c.read(settingsDockProvider.notifier).state = SettingsDock.appThemeDesigner;
      await settle(tester);
      await tester.tap(nav('general'));
      await settle(tester);
      expect(c.read(settingsDockProvider), SettingsDock.none);
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget);

      // Closing the pop-up with an editor open leaves no editor behind for the next time.
      c.read(settingsDockProvider.notifier).state = SettingsDock.appThemeDesigner;
      await settle(tester);
      await tester.tap(find.byKey(close));
      await settle(tester);
      expect(popup(), findsNothing);
      expect(c.read(settingsDockProvider), SettingsDock.none);
      await tearDownShell(tester, s);
    });

    testWidgets('sync storage with unsaved changes is asked about on every way out of it: the cross, Escape, a click '
        'beside the pop-up, another section', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      final guard = _DirtySyncStorage();
      final s = await pumpShell(tester, 'default_dark',
          picture: false, extra: [syncBackendCloseControllerProvider.overrideWithValue(guard)]);
      final c = s.container;
      await open(tester, s);
      await tester.tap(nav('account'));
      await settle(tester);
      c.read(settingsDockProvider.notifier).state = SettingsDock.syncBackend;
      await settle(tester);
      expect(find.text(l10n.settingsSyncBackendDockTitle), findsOneWidget);

      await tester.tap(find.byKey(close));
      await settle(tester);
      expect(guard.asked, 1);
      expect(popup(), findsOneWidget, reason: 'its person stayed: nothing closes');
      expect(c.read(settingsDockProvider), SettingsDock.syncBackend);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
      expect(guard.asked, 2);
      expect(popup(), findsOneWidget);

      await tester.tapAt(const Offset(40, 880));
      await settle(tester);
      expect(guard.asked, 3);
      expect(popup(), findsOneWidget);

      await tester.tap(nav('general'));
      await settle(tester);
      expect(guard.asked, 4);
      expect(c.read(settingsDockProvider), SettingsDock.syncBackend, reason: 'still in the editor');
      expect(title(l10n.settingsInlineSectionGeneral), findsNothing);

      // The way back in the editor's header asks as well.
      await tester.tap(find.byKey(const ValueKey('settings-dock-back')));
      await settle(tester);
      expect(guard.asked, 5);
      expect(c.read(settingsDockProvider), SettingsDock.syncBackend);

      // Nothing unsaved: every way out is open again.
      guard.dirty = false;
      await tester.tap(nav('general'));
      await settle(tester);
      expect(guard.asked, 5);
      expect(c.read(settingsDockProvider), SettingsDock.none);
      expect(title(l10n.settingsInlineSectionGeneral), findsOneWidget);
      await tester.tap(find.byKey(close));
      await settle(tester);
      expect(popup(), findsNothing);
      await tearDownShell(tester, s);
    });

    testWidgets('a notice raised while Settings is open is drawn over the pop-up, where it can be read and closed',
        (tester) async {
      final s = await shell(tester);
      final c = s.container;
      await open(tester, s);
      c.read(notificationCenterProvider.notifier).info('Saved the layout');
      await settle(tester);
      final notice = find.text('Saved the layout');
      expect(notice, findsNWidgets(2), reason: 'the shell draws it behind the pop-up, and the pop-up draws it in front');
      expect(notice.hitTestable(), findsOneWidget, reason: 'the one in front can be used');
      expect(
        find.ancestor(of: notice.hitTestable(), matching: find.byType(DesktopShell)),
        findsNothing,
        reason: 'and it is the pop-up\'s, not the dimmed one of the shell',
      );
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('in a small window it is as large as the window lets it be, and nothing overflows', (tester) async {
      final s = await shell(tester, size: const Size(900, 600));
      // (The shell behind it fits a window this low as well: its rail scrolls.)
      expect(tester.takeException(), isNull);
      await open(tester, s);
      expect(tester.takeException(), isNull);
      final size = tester.getSize(popup());
      expect(size.width, 900 - 48);
      expect(size.height, 600 - 48);
      for (final name in [
        'appearance', 'account', 'plan', 'keyboard', 'terminal', 'files', 'screens', 'security', 'data', //
        'notifications', 'about', 'general',
      ]) {
        await tester.tap(nav(name));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: name);
      }
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    // Found while comparing the five versions: a scrollback a
    // phone set (any number of lines, 0 for unlimited) that was none of these
    // matched no item (blank, an assertion in a debug build), or showed as 5k.
    for (final (value, said) in [
      (0, l10n.settingsMobUnlimitedScrollback),
      (3000, l10n.settingsScrollbackCount(3000)),
      (2500, l10n.settingsScrollbackCount(2500)),
      (20000, l10n.settingsInlineScrollbackLines(20)),
    ]) {
      testWidgets('a scrollback of $value lines, set on a phone, is shown as it is, and a choice here replaces it',
          (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark', picture: false, prefsExtra: {'scrollback_lines': value});
        await open(tester, s);
        // The terminal's rows are Terminal and SSH's (4.0).
        await tester.tap(nav('terminal'));
        await settle(tester);
        final label = find.text(l10n.settingsInlineScrollbackBuffer);
        await tester.ensureVisible(label);
        await settle(tester);
        final row = find.ancestor(of: label, matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_SettingRow'));
        final menu = find.descendant(of: row, matching: find.byType(ZestSelect<int>));
        expect(tester.takeException(), isNull);
        expect(find.descendant(of: menu, matching: find.text(said)), findsOneWidget);
        await tester.tap(menu);
        await settle(tester);
        await tester.tap(find.text(l10n.settingsInlineScrollbackLines(10)).last);
        await settle(tester);
        expect(s.container.read(sharedPreferencesProvider).getInt('scrollback_lines'), 10000);
        expect(find.descendant(of: menu, matching: find.text(l10n.settingsInlineScrollbackLines(10))), findsOneWidget);
        await tester.tap(find.byKey(close));
        await settle(tester);
        await tearDownShell(tester, s);
      });
    }

    testWidgets('Reset all settings asks in the dialog of the app: Cancel resets nothing, Reset does, and says so',
        (tester) async {
      final s = await shell(tester);
      final c = s.container;
      final prefs = c.read(sharedPreferencesProvider);
      // A saved setting, which the reset takes, and something of the same store that is no setting (what
      // waits to be synced), which it leaves: test/services/settings_reset_test.dart has every key.
      await prefs.setBool('sync_dirty', true);
      await prefs.setInt('default_port', 2222);
      await open(tester, s);
      // Backups and data's (4.0: it was General's).
      await tester.tap(nav('data'));
      await settle(tester);
      await tester.ensureVisible(find.text(l10n.settingsInlineResetAllSettings));
      await settle(tester);
      await tester.tap(find.text(l10n.settingsInlineReset));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsOneWidget);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.text(l10n.settingsInlineResetAllSettingsTitle), findsOneWidget);
      expect(
        find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.settingsResetAllHelp)),
        findsOneWidget,
        reason: 'what is reset and what is not touched',
      );
      await tester.tap(find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.cancel)));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing);
      expect(prefs.getInt('default_port'), 2222);
      expect(popup(), findsOneWidget, reason: 'Settings stays open behind its question');

      await tester.tap(find.text(l10n.settingsInlineReset));
      await settle(tester);
      await tester.tap(
          find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(l10n.settingsInlineReset)));
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing);
      expect(prefs.getInt('default_port'), isNull);
      expect(prefs.getBool('sync_dirty'), isTrue, reason: 'no setting: left as it was');
      expect(find.text(l10n.settingsInlineSettingsResetRestart), findsWidgets, reason: 'said in a notice');
      await tester.tap(find.byKey(close));
      await settle(tester);
      await tearDownShell(tester, s);
    });

    testWidgets('Report a bug closes Settings and opens the report form, which is a panel of the shell', (tester) async {
      // The report form reads the app's version as it opens.
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'zestssh', version: '3.0.0', buildNumber: '300', buildSignature: '');
      final s = await shell(tester);
      final c = s.container;
      await open(tester, s);
      await tester.tap(nav('about'));
      await settle(tester);
      final row = find.text(l10n.settingsInlineLinkReportBug);
      await tester.ensureVisible(row);
      await settle(tester);
      await tester.tap(row);
      await settle(tester);
      expect(popup(), findsNothing);
      expect(c.read(settingsPopupOpenProvider), isFalse);
      expect(c.read(helpDockProvider), HelpPage.reportBug);
      await tearDownShell(tester, s);
    });

    // On a device, Lock ZestSSH's key did nothing while
    // Settings or a dialog was open (the shell's keys stop there, and the lock's
    // was among them). The lock covers whatever is open: it is drawn over the
    // app's navigator.
    group('Lock ZestSSH\'s key', () {
      Future<void> lockKey(WidgetTester tester) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyL);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await settle(tester);
      }

      testWidgets('locks the app with Settings, a dialog or the Support Hub open', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark',
            picture: false,
            prefsExtra: const {'security_lock_enabled': true},
            extra: [
              securityLockServiceProvider.overrideWithValue(_PinLock()),
              isAppLockedProvider.overrideWith(_Unlocked.new),
            ]);
        final c = s.container;
        expect(c.read(isAppLockedProvider), isFalse);

        await open(tester, s);
        expect(popup(), findsOneWidget);
        await lockKey(tester);
        expect(c.read(isAppLockedProvider), isTrue, reason: 'locked with Settings open');

        c.read(isAppLockedProvider.notifier).state = false;
        await tester.tap(find.byKey(close));
        await settle(tester);
        expect(popup(), findsNothing);
        unawaited(showDialog<void>(
          context: tester.element(find.byType(DesktopShell)),
          builder: (_) => const AlertDialog(content: Text('a dialog')),
        ));
        await settle(tester);
        expect(find.text('a dialog'), findsOneWidget);
        await lockKey(tester);
        expect(c.read(isAppLockedProvider), isTrue, reason: 'locked with a dialog open');
        Navigator.of(tester.element(find.text('a dialog'))).pop();
        await settle(tester);

        c.read(isAppLockedProvider.notifier).state = false;
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
        await lockKey(tester);
        expect(c.read(isAppLockedProvider), isTrue, reason: 'locked with the Support Hub open');
        c.read(supportHubOpenProvider.notifier).state = false;
        await tearDownShell(tester, s);
      });

      testWidgets('with the app lock off it does nothing, Settings open or not', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark', picture: false);
        final c = s.container;
        await lockKey(tester);
        expect(c.read(isAppLockedProvider), isFalse);
        await open(tester, s);
        await lockKey(tester);
        expect(c.read(isAppLockedProvider), isFalse);
        expect(popup(), findsOneWidget, reason: 'Settings stays open');
        await tester.tap(find.byKey(close));
        await settle(tester);
        await tearDownShell(tester, s);
      });
    });

    // 3.3.1 (the gear lit, Hosts on screen, and
    // a click on the gear did nothing until the app was opened again).
    // Settings asked for with no pop-up on screen stayed asked for, and the
    // gear only asked for it again, which changed nothing.
    group('the gear opens Settings, whatever happened before', () {
      Future<void> gear(WidgetTester tester) async {
        await tester.tap(find.byIcon(LucideIcons.settings).first);
        await settle(tester);
      }

      testWidgets('asked for before the shell was up (a link, a team join, while the app was locked): shown once it is',
          (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark',
            picture: false, extra: [settingsPopupOpenProvider.overrideWith((ref) => true)]);
        final c = s.container;
        expect(popup(), findsOneWidget, reason: 'what was asked for is shown');
        await tester.tap(find.byKey(close));
        await settle(tester);
        expect(popup(), findsNothing);
        expect(c.read(settingsPopupOpenProvider), isFalse);
        await gear(tester);
        expect(popup(), findsOneWidget, reason: 'and the gear opens it again');
        await tester.tap(find.byKey(close));
        await settle(tester);
        await tearDownShell(tester, s);
      });

      testWidgets('the shell gone with the pop-up open, its navigator with it: the next shell shows it, and the gear '
          'opens it after', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark', picture: false);
        final c = s.container;
        // The app's screens, under the scope that stays.
        Widget app(Widget child) =>
            RepaintBoundary(key: s.key, child: UncontrolledProviderScope(container: c, child: child));
        await open(tester, s);
        expect(popup(), findsOneWidget);

        // Its navigator goes with the shell: the pop-up's route never says it closed.
        await tester.pumpWidget(app(const SizedBox()));
        await settle(tester);
        expect(find.byType(DesktopShell), findsNothing);
        expect(popup(), findsNothing);
        await tester.pumpWidget(app(MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById('default_dark').toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const DesktopShell(),
        )));
        await settle(tester);
        expect(find.byType(DesktopShell), findsOneWidget);
        expect(popup(), findsOneWidget, reason: 'Settings was open, and is again');
        await tester.tap(find.byKey(close));
        await settle(tester);
        expect(c.read(settingsPopupOpenProvider), isFalse);

        await gear(tester);
        expect(popup(), findsOneWidget, reason: 'the gear opens it');
        await tester.tap(find.byKey(close));
        await settle(tester);
        await tearDownShell(tester, s);
      });

      testWidgets('the app locked with the pop-up open (the lock screen takes the shell\'s place): it closes, says '
          'so, and the next shell\'s gear opens it', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        // As the app's router has it.
        final router = GoRouter(routes: [
          GoRoute(path: '/', builder: (_, _) => const DesktopShell()),
          GoRoute(path: '/lock', builder: (_, _) => const SizedBox()),
        ]);
        addTearDown(router.dispose);
        final s = await pumpShell(tester, 'default_dark', picture: false, router: router);
        final c = s.container;
        await open(tester, s);
        expect(popup(), findsOneWidget);

        // (The shell goes under a scope that stays up: its dispose changed a
        // provider while the tree was taken down, which a debug build refused.)
        router.go('/lock');
        await settle(tester);
        expect(find.byType(DesktopShell), findsNothing);
        expect(popup(), findsNothing, reason: 'the pop-up went with the shell');
        expect(c.read(settingsPopupOpenProvider), isFalse, reason: 'and that is said');
        router.go('/');
        await settle(tester);
        expect(popup(), findsNothing, reason: 'nothing asked for it since');

        await gear(tester);
        expect(popup(), findsOneWidget, reason: 'the gear opens it');
        await tester.tap(find.byKey(close));
        await settle(tester);
        expect(c.read(settingsPopupOpenProvider), isFalse);
        await tearDownShell(tester, s);
      });

      testWidgets('a pop-up that could not be shown leaves the gear working', (tester) async {
        FlutterSecureStorage.setMockInitialValues({});
        final s = await pumpShell(tester, 'default_dark', picture: false);
        final c = s.container;
        var tries = 0;
        DesktopShell.debugShowSettingsPopup = (_) {
          tries++;
          throw StateError('no navigator');
        };
        addTearDown(() => DesktopShell.debugShowSettingsPopup = null);
        await gear(tester);
        expect(tries, 1);
        expect(popup(), findsNothing);
        expect(c.read(settingsPopupOpenProvider), isFalse, reason: 'not left asked for');

        DesktopShell.debugShowSettingsPopup = null;
        await gear(tester);
        expect(popup(), findsOneWidget, reason: 'the next click opens it');
        await tester.tap(find.byKey(close));
        await settle(tester);
        expect(c.read(settingsPopupOpenProvider), isFalse);
        await tearDownShell(tester, s);
      });
    });
  });

  // No picture, always on (3.0, found while comparing the five
  // versions). A Mac's menu bar had no menu of the application's own: its first
  // menu, which a Mac shows under the app's name, was File, with no Quit (so
  // Cmd+Q did nothing), no Settings and no Hide. Its Edit > Copy did nothing,
  // and its Paste went into the first session of the tab, wherever the
  // keyboard was.
  group('On a Mac', () {
    final l10n = lookupAppLocalizations(const Locale('en'));
    final mac = TargetPlatformVariant.only(TargetPlatform.macOS);
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    // What the app last handed the Mac for its menu bar, what it asked of its
    // window ('destroy' closes it, and the app with it), and the clipboard.
    var bar = <Map<Object?, Object?>>[];
    var window = <String>[];
    String? clipboard;

    Future<_Shell0> shell(WidgetTester tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      bar = [];
      window = [];
      clipboard = null;
      messenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
        if (call.method == 'Menu.setMenus') {
          bar = [for (final m in (call.arguments as Map)['0'] as List) (m as Map).cast<Object?, Object?>()];
        }
        return null;
      });
      messenger.setMockMethodCallHandler(const MethodChannel('window_manager'), (call) async {
        window.add(call.method);
        return const {'isMaximized', 'isFullScreen', 'isMinimized'}.contains(call.method) ? false : null;
      });
      messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
          case 'Clipboard.getData':
            return clipboard == null ? null : {'text': clipboard};
          case 'Clipboard.hasStrings':
            return {'value': clipboard != null};
        }
        return null;
      });
      addTearDown(() {
        messenger.setMockMethodCallHandler(SystemChannels.menu, null);
        messenger.setMockMethodCallHandler(SystemChannels.platform, null);
        _stubPlugins();
      });
      return pumpShell(tester, 'default_dark', picture: false);
    }

    List<Map<Object?, Object?>> itemsOf(Map<Object?, Object?> menu) => [
          for (final i in menu['children']! as List)
            if ((i as Map)['isDivider'] != true) i.cast<Object?, Object?>(),
        ];
    Map<Object?, Object?> item(String menu, String label) =>
        itemsOf(bar.singleWhere((m) => m['label'] == menu)).singleWhere((i) => i['label'] == label);

    /// Picks [item], as the Mac says it when it is clicked or its keys pressed.
    Future<void> pick(WidgetTester tester, Map<Object?, Object?> item) async {
      await messenger.handlePlatformMessage(
        SystemChannels.menu.name,
        SystemChannels.menu.codec.encodeMethodCall(MethodCall('Menu.selectedCallback', item['id'])),
        (_) {},
      );
      await settle(tester);
    }

    Finder inQuestion(String text) => find.descendant(of: find.byType(ZestConfirmDialog), matching: find.text(text));
    Finder search() =>
        find.byKey(const ValueKey('hosts-quick-field'));
    TerminalView viewOf(WidgetTester tester, Terminal terminal) =>
        tester.widget<TerminalView>(find.byWidgetPredicate((w) => w is TerminalView && w.terminal == terminal));

    testWidgets("the first menu is the application's own: About, Settings on Cmd+comma, the system's Services and "
        'Hide, and Quit on Cmd+Q; File comes after it, and Help has no About of its own', (tester) async {
      final s = await shell(tester);
      expect(bar.first['label'], 'ZestSSH');
      String what(Map<Object?, Object?> i) =>
          i['label'] as String? ?? PlatformProvidedMenuItemType.values[i['platformProvidedMenu']! as int].name;
      final app = itemsOf(bar.first);
      expect(app.map(what), [
        l10n.desktopMenuAboutZestssh,
        l10n.settingsTitle,
        'servicesSubmenu',
        'hide',
        'hideOtherApplications',
        'showAllApplications',
        l10n.trayQuit,
      ]);
      const cmd = 1 << 0; // the Command key, as a menu's shortcut is handed to the Mac
      expect((app.last['shortcutTrigger'], app.last['shortcutModifiers'], app.last['enabled']),
          (LogicalKeyboardKey.keyQ.keyId, cmd, true));
      expect((app[1]['shortcutTrigger'], app[1]['shortcutModifiers']), (LogicalKeyboardKey.comma.keyId, cmd));
      expect(bar[1]['label'], l10n.desktopMenuFile);
      final help = itemsOf(bar.singleWhere((m) => m['label'] == l10n.desktopMenuHelp));
      expect(help.map((i) => i['label']), isNot(contains(l10n.desktopMenuAboutZestssh)));

      await pick(tester, app[1]);
      expect(s.container.read(settingsPopupOpenProvider), isTrue, reason: 'Settings opens Settings');
      await tearDownShell(tester, s);
    }, variant: mac);

    testWidgets('Quit ends the app as closing its window does: with sessions open it asks first, and Cancel leaves '
        'everything as it is; Close keeps the sessions for the next start, ends them and closes the window; the '
        'system, asking then to end the app while the sessions are still ending, is let through without a second '
        'question', (tester) async {
      final s = await shell(tester);
      await openSessions(tester, s);
      final c = s.container;
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      Map<Object?, Object?> quit() => itemsOf(bar.first).last;

      await pick(tester, quit());
      expect(inQuestion(l10n.desktopCloseZestssh), findsOneWidget);
      await tester.tap(inQuestion(l10n.cancel));
      await settle(tester);
      expect(window, isNot(contains('destroy')));
      expect(c.read(activeSessionsProvider), hasLength(4), reason: 'nothing ended');

      live.holdEnding = Completer<void>();
      await pick(tester, quit());
      await tester.tap(inQuestion(l10n.close));
      await settle(tester);
      expect(window.where((m) => m == 'destroy'), hasLength(1));
      // The window gone, the system asks the app to end, while its sessions are still ending.
      final asked = tester.binding.handleRequestAppExit();
      await settle(tester);
      expect(find.byType(ZestConfirmDialog), findsNothing, reason: 'not asked again');
      expect(await asked, AppExitResponse.exit);
      live.holdEnding!.complete();
      await settle(tester);
      expect({for (final x in c.read(activeSessionsProvider).values) x.status}, {SessionStatus.disconnected},
          reason: 'every session ended');
      final kept = await tester.runAsync(() =>
          SessionPersistenceService(c.read(sharedPreferencesProvider), c.read(localStateStoreProvider))
              .loadTabSnapshots());
      expect({for (final t in kept!.tabs) ...t.paneTreeOfConnIds.allLeaves.expand((l) => l.sessionIds)},
          {'c0', 'c1', 'c2', 'c3'},
          reason: 'kept for the next start');

      expect(window.where((m) => m == 'destroy'), hasLength(1));
      await tearDownShell(tester, s);
    }, variant: mac);

    testWidgets("the system's Quit (the Dock's, or logging out) ends the app the same way and leaves the window to "
        'the system: asked twice while the question is up, one question; Cancel tells the system to stay',
        (tester) async {
      final s = await shell(tester);
      await openSessions(tester, s);
      final c = s.container;

      final first = tester.binding.handleRequestAppExit();
      await settle(tester);
      final second = tester.binding.handleRequestAppExit();
      await settle(tester);
      expect(inQuestion(l10n.desktopCloseZestssh), findsOneWidget, reason: 'one question for both');
      await tester.tap(inQuestion(l10n.cancel));
      await settle(tester);
      expect(await first, AppExitResponse.cancel);
      expect(await second, AppExitResponse.cancel);
      expect(c.read(activeSessionsProvider), hasLength(4));

      final third = tester.binding.handleRequestAppExit();
      await settle(tester);
      await tester.tap(inQuestion(l10n.close));
      await settle(tester);
      expect(await third, AppExitResponse.exit);
      expect({for (final x in c.read(activeSessionsProvider).values) x.status}, {SessionStatus.disconnected});
      expect(window, isNot(contains('destroy')), reason: 'the system ends the app itself');
      await tearDownShell(tester, s);
    }, variant: mac);

    testWidgets("Edit > Copy copies the selection where the keyboard is: a text field's, a terminal's",
        (tester) async {
      final s = await shell(tester);
      final c = s.container;
      Map<Object?, Object?> copy() => item(l10n.desktopMenuEdit, l10n.copy);

      await tester.enterText(search(), 'web-01');
      tester.widget<TextField>(search()).controller!.selection = const TextSelection(baseOffset: 0, extentOffset: 3);
      await tester.pump();
      await pick(tester, copy());
      expect(clipboard, 'web');

      await openSessions(tester, s);
      final terminal = c.read(activeSessionsProvider)['s0']!.session!.terminal;
      final view = viewOf(tester, terminal);
      view.controller!.setSelection(terminal.buffer.createAnchor(0, 0), terminal.buffer.createAnchor(17, 0));
      view.focusNode!.requestFocus();
      await tester.pump();
      await pick(tester, copy());
      expect(clipboard, startsWith('Welcome to Ubuntu'));
      expect(clipboard, terminal.buffer.getText(view.controller!.selection));
      await tearDownShell(tester, s);
    }, variant: mac);

    testWidgets('Edit > Paste pastes where the keyboard is: into a text field; into the pane of a split it is in, '
        'not the first of the tab, asked first where the text looks dangerous; with the keyboard in neither, into '
        'the session in front', (tester) async {
      final s = await shell(tester);
      final c = s.container;
      Map<Object?, Object?> paste() => item(l10n.desktopMenuEdit, l10n.terminalPaste);

      await tester.tap(search());
      await tester.pump();
      clipboard = 'web-02';
      await pick(tester, paste());
      expect(tester.widget<TextField>(search()).controller!.text, 'web-02');

      // web-01 and web-02 side by side in one tab, web-01 in front.
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      live.set({'s0': _session(0), 's1': _session(1)});
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      tabs.mergeTabs(tabs.tabContaining('s1')!.id, tabs.tabContaining('s0')!.id);
      tabs.setActiveTab(tabs.tabContaining('s0')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      await settle(tester);
      final first = c.read(activeSessionsProvider)['s0']!.session!.terminal;
      final second = c.read(activeSessionsProvider)['s1']!.session!.terminal;
      final intoFirst = <String>[], intoSecond = <String>[];
      first.onOutput = intoFirst.add;
      second.onOutput = intoSecond.add;

      viewOf(tester, second).focusNode!.requestFocus();
      await tester.pump();
      clipboard = 'uptime';
      await pick(tester, paste());
      expect(intoSecond.join(), contains('uptime'));
      expect(intoFirst, isEmpty, reason: 'not the first of the tab');

      intoSecond.clear();
      clipboard = 'rm -rf /';
      await pick(tester, paste());
      expect(find.text(l10n.dangerPasteTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel).last);
      await settle(tester);
      expect(intoSecond, isEmpty, reason: 'Cancel pastes nothing');
      await pick(tester, paste());
      await tester.tap(find.text(l10n.dangerPasteAnyway));
      await settle(tester);
      expect(intoSecond.join(), contains('rm -rf /'));
      expect(intoFirst, isEmpty);

      intoSecond.clear();
      FocusManager.instance.primaryFocus?.unfocus();
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      await tester.pump();
      clipboard = 'whoami';
      await pick(tester, paste());
      expect(intoFirst.join(), contains('whoami'), reason: 'the session in front');
      expect(intoSecond, isEmpty);
      await tearDownShell(tester, s);
    }, variant: mac);

    // A dialog of buttons has no field to paste into, and the paste went past it, to
    // the live terminal behind.
    testWidgets('Edit > Paste with a dialog of buttons open goes nowhere, and with it gone to the session in front',
        (tester) async {
      final s = await shell(tester);
      final c = s.container;
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      live.set({'s0': _session(0)});
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      tabs.setActiveTab(tabs.tabContaining('s0')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      await settle(tester);
      final typed = <String>[];
      live.state['s0']!.session!.terminal.onOutput = typed.add;

      late BuildContext dialog;
      unawaited(showDialog<void>(
        context: tester.element(find.byType(DesktopTerminalArea)),
        builder: (context) {
          dialog = context;
          return AlertDialog(actions: [TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('OK'))]);
        },
      ));
      await settle(tester);
      clipboard = 'uptime';
      await pick(tester, item(l10n.desktopMenuEdit, l10n.terminalPaste));
      expect(typed, isEmpty);
      // Nor is anything else of the menu's done behind it.
      await pick(tester, item(l10n.desktopMenuEdit, l10n.desktopShortcutFindInTerminal));
      expect(c.read(terminalFindProvider), isNull);
      final tabsBefore = c.read(workTabsProvider).tabs.length;
      await pick(tester, item(l10n.desktopMenuFile, l10n.desktopShortcutCloseTab));
      expect(c.read(workTabsProvider).tabs, hasLength(tabsBefore));

      Navigator.of(dialog).pop();
      await settle(tester);
      await pick(tester, item(l10n.desktopMenuEdit, l10n.terminalPaste));
      expect(typed.join(), contains('uptime'));
      await tearDownShell(tester, s);
    }, variant: mac);

    testWidgets('the menu\'s keys act on nothing out of sight behind the Support Hub: closing closes the page and no '
        'tab, a split or a font goes back to the sessions first, and the clipboard goes to no terminal', (tester) async {
      PackageInfo.setMockInitialValues(
          appName: 'ZestSSH', packageName: 'zestssh', version: '3.3.0', buildNumber: '340', buildSignature: '');
      resetSupportHubDraft();
      final s = await shell(tester);
      final c = s.container;
      final live = c.read(activeSessionsProvider.notifier) as _Sessions;
      live.set({'s0': _session(0), 's1': _session(1)});
      await tester.pump();
      final tabs = c.read(workTabsProvider.notifier);
      tabs.setActiveTab(tabs.tabContaining('s0')!.id);
      c.read(v3ActiveSessionTabProvider.notifier).state = 's0';
      await settle(tester);
      final typed = <String>[];
      live.state['s0']!.session!.terminal.onOutput = typed.add;
      live.state['s1']!.session!.terminal.onOutput = typed.add;
      Future<void> open() async {
        c.read(supportHubOpenProvider.notifier).state = true;
        await settle(tester);
      }

      final fileMenu = l10n.desktopMenuFile, terminalMenu = l10n.desktopShortcutTerminal;
      final tabsBefore = c.read(workTabsProvider).tabs.length;

      // Cmd+W: the page, and no live tab the person cannot see.
      await open();
      await pick(tester, item(fileMenu, l10n.desktopShortcutCloseTab));
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(c.read(workTabsProvider).tabs, hasLength(tabsBefore));
      // With the page gone it is Cmd+W as ever: this is what it would have done.
      expect(item(fileMenu, l10n.desktopShortcutCloseTab)['enabled'], isTrue);

      // Cmd+Shift+V with no field: nowhere, and the page stays.
      await open();
      clipboard = 'rm -rf /tmp/made-up';
      await pick(tester, item(l10n.desktopMenuEdit, l10n.terminalPaste));
      expect(typed, isEmpty);
      expect(c.read(supportHubOpenProvider), isTrue);
      // In a field of the page, into that field.
      c.read(supportHubComposeProvider.notifier).state = TicketType.bug;
      await settle(tester);
      await tester.tap(find.byKey(const ValueKey('hub-body')));
      await settle(tester);
      clipboard = 'a line of the log';
      await pick(tester, item(l10n.desktopMenuEdit, l10n.terminalPaste));
      await settle(tester);
      expect(find.text('a line of the log'), findsWidgets);
      expect(typed, isEmpty);
      c.read(supportHubComposeProvider.notifier).state = null;
      resetSupportHubDraft();
      c.read(supportHubOpenProvider.notifier).state = false;
      await settle(tester);

      // Cmd+Shift+D: back to the sessions, where the split is seen happening.
      final panes = c.read(paneTreeProvider)?.allLeaves.length;
      await open();
      await pick(tester, item(terminalMenu, l10n.desktopShortcutSplitRight));
      expect(c.read(supportHubOpenProvider), isFalse);
      expect(c.read(paneTreeProvider)?.allLeaves.length, isNot(panes));
      await tearDownShell(tester, s);
    }, variant: mac);
  });
  // The computer's window at its least size and at a common one, in every
  // language (3.0): each section of the side rail at the size
  // the app is drawn at: no line breaks inside a word, no one-line name is cut
  // at its box's edge, every word is in a font of the app, no words are cut at
  // their top and bottom, and nothing runs over. At 800 by 500 the automation
  // list's empty page ran over its foot in every language; the narrow rail's
  // Discord button ran out of the rail in Russian; the group chips left their
  // words 15 of the 16 pixels they need; and the keys', snippets', workflows'
  // and networks' forms cut a name in their column ("Отображаемое имя",
  // "Host predeterminado", "Beschreibung", "Nombre").
  // At 1.25 and 1.5 times the system's text size (3.0): the
  // frame (the title bar, the side rail and the status bar) keeps its sizes
  // and grows its words at most kDesktopFrameTextScale times; the pages grow
  // theirs fully, and a word longer than its row may break from 1.5 times, as
  // on a phone. Unclamped, the rail's names of two lines were cut from 1.25
  // times and the title bar's tree selector ran over; at 1.5 the status bar cut
  // its words.
  for (final (size, scale) in const [
    (Size(800, 500), 1.0),
    (Size(1280, 800), 1.0),
    (Size(1280, 800), 1.25),
    (Size(1280, 800), 1.5),
  ]) {
    final words = scale <= 1.3;
    testWidgets("the computer's window, ${size.width.toInt()} by ${size.height.toInt()}"
        "${scale == 1.0 ? '' : ' at $scale times the text size'}, each section, in every language: "
        "${words ? 'no word cut in two or at its edge, every word in a font of the app, ' : ''}"
        'no words cut at their top and bottom, nothing runs over', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final problems = <String>[];
      for (final locale in AppLocalizations.supportedLocales) {
        final found = <String>[];
        void check(String where) => _checkFit(found, where, words: words);

        final reported = FlutterError.onError;
        FlutterError.onError = (details) => found.add(details.exceptionAsString().split(String.fromCharCode(10)).first);
        try {
          final s = await pumpShell(tester, 'default_dark', locale: locale, size: size);
          check('start');
          for (final section in NavSection.values) {
            s.container.read(activeSidebarNavProvider.notifier).state = section;
            await settle(tester);
            check(section.name);
          }
          await tearDownShell(tester, s);
        } finally {
          FlutterError.onError = reported;
        }
        problems.addAll(found.map((p) => '$locale: $p'));
      }
      expect(problems, isEmpty);
    });
  }
  // The computer's settings, each of their pages, at the window's least width
  // (800, and tall enough to hold a page whole), at 1 and 1.25 times the
  // system's text size, in every language (3.0): a setting's
  // control stood beside its words whatever the room, and a wide choice left
  // them a few letters a line ("Неизвестные ключи хостов" in Russian at 1.25
  // times); a keyboard shortcut's name ran out of its row.
  for (final scale in const [1.0, 1.25]) {
    testWidgets("the computer's settings, each page, 800 wide${scale == 1.0 ? '' : ' at $scale times the text size'}, "
        'in every language: no word cut in two or at its edge, every word in a font of the app, no words cut at '
        'their top and bottom, nothing runs over', (tester) async {
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      FlutterSecureStorage.setMockInitialValues({});
      final problems = <String>[];
      for (final locale in AppLocalizations.supportedLocales) {
        final found = <String>[];
        final reported = FlutterError.onError;
        FlutterError.onError = (details) => found.add(details.exceptionAsString().split(String.fromCharCode(10)).first);
        try {
          final s = await pumpShell(tester, 'default_dark', locale: locale, size: const Size(800, 3000));
          s.container.read(activeSidebarNavProvider.notifier).state = NavSection.settings;
          await settle(tester);
          for (final page in const [
            'account', 'plan', 'general', 'appearance', 'keyboard', 'notifications', 'terminal', 'files', //
            'screens', 'security', 'data', 'about',
          ]) {
            final nav = find.byKey(ValueKey('settings-nav-$page'));
            expect(nav, findsOneWidget, reason: page);
            await tester.tap(nav, warnIfMissed: false);
            await settle(tester);
            _checkFit(found, page, words: true);
          }
          await tearDownShell(tester, s);
        } finally {
          FlutterError.onError = reported;
        }
        problems.addAll(found.map((p) => '$locale: $p'));
      }
      expect(problems, isEmpty);
    });
  }

  testWidgets("at 1.5 times the system's text size the window's frame draws its words 1.15 times larger, and a page "
      'as much larger as the system says', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final s = await pumpShell(tester, 'default_dark', size: const Size(1280, 800));
    // The first words drawn in it (an icon is drawn in a font too, and never
    // grows with the text).
    double scaleIn(Type type) {
      final words = find.descendant(
          of: find.byType(type),
          matching: find.byWidgetPredicate((w) => w is RichText && RegExp('[A-Za-z]').hasMatch(w.text.toPlainText())));
      return tester.renderObject<RenderParagraph>(words.first).textScaler.scale(10) / 10;
    }

    expect(scaleIn(PillBar), closeTo(kDesktopFrameTextScale, 0.001), reason: 'the title bar');
    expect(scaleIn(NarrowSidebar), closeTo(kDesktopFrameTextScale, 0.001), reason: 'the side rail');
    expect(scaleIn(DesktopStatusBar), closeTo(kDesktopFrameTextScale, 0.001), reason: 'the status bar');
    expect(scaleIn(HostsHomePage), closeTo(1.5, 0.001), reason: 'the hosts page');
    await tearDownShell(tester, s);
  });
}

/// Each paragraph on screen cut at its top and bottom, and where [words],
/// each word cut in two, each one-line name cut at its edge and each word in
/// no font of the app, added to [found] after [where].
void _checkFit(List<String> found, String where, {required bool words}) {
  for (final e in find.byType(RichText).evaluate()) {
    final p = e.renderObject;
    if (p is! RenderParagraph || !p.hasSize) continue;
    final cut = cutTopAndBottom(p);
    if (cut != null) found.add('$where: cut at its top and bottom: $cut');
    if (!words) continue;
    found.addAll(wordsCut(p).map((c) => '$where: a word cut in two: $c'));
    final clipped = clippedAtEdge(p);
    if (clipped != null) found.add('$where: cut at its edge: $clipped');
    if (p.text.style?.fontFamily == null) {
      found.add('$where: in no font of the app: "${p.text.toPlainText(includeSemanticsLabels: false)}"');
    }
  }
}
