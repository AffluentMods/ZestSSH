import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/core/models/shared_pins.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules, mayChangeItem;
import 'package:zestssh/features/orchards/spaces.dart' show OrchardSpace;
import 'package:zestssh/features/orchards/team_write.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/daos/sftp_sync_manifest_dao.dart';
import 'package:zestssh/core/latency_format.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart' show hostsByIdProvider;
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_source_picker.dart';
import 'package:zestssh/ui/screens/sftp/widgets/this_computer.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/ui/screens/sftp/sudo_retry.dart';
import 'package:zestssh/ui/screens/sftp/session_ready.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_sync_compare.dart';
import 'package:zestssh/services/sftp_sync_service.dart';
import 'package:zestssh/services/sftp_drop_names.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart';
import 'package:zestssh/ui/screens/sftp/transfer_scan.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_locations_rail.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_mirror_preview_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_context_menu.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_image_preview_dialog.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/services/session_ssh.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/services/ftps/ftps_pane_file_source.dart';
import 'package:zestssh/services/ftps/ftps_session.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/screens/editor/editor_hosts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_selection_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/overwrite_conflict_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/split_pane.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/features/sftp/debounced_writer.dart';
import 'package:zestssh/features/sftp/local_places.dart';
import 'package:zestssh/features/sftp/forget_last_folder.dart';
import 'package:zestssh/features/sftp/remembered_path_resolver.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/type_name.dart';
import 'package:zestssh/ui/screens/sftp/transfer_pool.dart';

const _uuid = Uuid();

/// Unified SFTP dual-pane file manager.
///
/// Each pane can be backed by any source - Local Files or any open SFTP
/// session - chosen via a dropdown in the pane header. The two panes
/// don't have to be the same type, so common flows like "transfer from
/// db-primary → build-runner" work without first staging through the
/// local disk.
///
/// Default layout:
///  - Left pane: Local Files (the OS filesystem on this machine).
///  - Right pane: the host the screen was opened on (if [sftp] was
///    supplied), otherwise Local Files.
///
/// The screen does NOT own SFTP services it merely consumes from the
/// [sftpSessionsProvider] registry - those are owned by whoever opened
/// them (typically the terminal pane or a previous incarnation of this
/// screen). It DOES own services it opens itself via the in-pane
/// "Connect to host…" flow, and closes them on dispose.
class SftpDualPaneScreen extends ConsumerStatefulWidget {
  /// SFTP service for the right pane's initial host. Null means start
  /// the right pane on Local Files.
  final SftpService? sftp;

  /// Display label for the initial right-pane host. Ignored if [sftp] is
  /// null.
  final String? connectionLabel;

  /// Session id for the initial right-pane host. Optional - when
  /// supplied, the dropdown's "exclude this session" plumbing can use it.
  final String? initialSessionId;

  /// Optional remote SFTP service for the LEFT pane. Null means the left
  /// pane starts on Local Files (the common case). Supplying BOTH [leftSftp]
  /// and [sftp] seeds a remote↔remote layout - this is how the (retired)
  /// SftpRemoteDualPaneScreen route is now served, so remote↔remote inherits
  /// the full reference surface (chmod, editor, symlinks, queued transfers).
  final SftpService? leftSftp;
  final String? leftLabel;
  final String? leftSessionId;

  /// An FTPS host's files for the right pane (3.4), in place of [sftp]: the
  /// session of an FTPS host opens its files here.
  final FtpsPaneFileSource? ftps;

  /// When true, renders without Scaffold/AppBar for inline embedding
  /// (e.g. desktop split pane alongside terminal).
  final bool embedded;

  /// Called when the user closes the embedded SFTP view (the toolbar
  /// power-off control on the right pane). Closes only this pane.
  final VoidCallback? onClose;

  /// Restored pane state (remember-last-folder spec, section 1): where the
  /// remote and local panes were when this pane pair was last open. Only
  /// hints; the panes open at home and resolve them in the background.
  final String? initialRemotePath;
  final String? initialLocalPath;

  /// In the SFTP dock beside a terminal (4.0): the
  /// host's files in one pane, with no rail, unless [twoPanes]. Its Upload
  /// takes files of this computer picked in the system's dialog, and its
  /// Download (in More) puts the selection in a folder of this computer
  /// picked there: a drop of them, with the same questions and transfers.
  final bool docked;

  /// Whether the dock shows the two panes and the rail, as before 4.0
  /// (this computer, or another host, beside this one); [onTwoPanes] turns
  /// that on or off, from either layout's More.
  final bool twoPanes;
  final ValueChanged<bool>? onTwoPanes;

  const SftpDualPaneScreen({
    super.key,
    this.sftp,
    this.connectionLabel,
    this.initialSessionId,
    this.leftSftp,
    this.leftLabel,
    this.leftSessionId,
    this.ftps,
    this.embedded = false,
    this.onClose,
    this.initialRemotePath,
    this.initialLocalPath,
    this.docked = false,
    this.twoPanes = false,
    this.onTwoPanes,
  });

  @override
  ConsumerState<SftpDualPaneScreen> createState() =>
      _SftpDualPaneScreenState();
}

class _SftpDualPaneScreenState extends ConsumerState<SftpDualPaneScreen>
    with AutomaticKeepAliveClientMixin, WidgetsBindingObserver {
  // Keep the SFTP state alive when the user switches to the terminal
  // tab (or any other sidebar item) and back. Without this, the parent
  // widget tree tears the SFTP screen down on visibility change, losing
  // the current directory, scroll position, and active transfers, and
  // briefly flashing the empty default state on the next mount.
  @override
  bool get wantKeepAlive => true;

  /// Per-side descriptor (label + icon for the dropdown trigger) and the
  /// matching operations facade. The two are kept in lock-step.
  late SftpPaneSource _leftSource;
  late PaneFileSource _leftFileSource;
  late SftpPaneSource _rightSource;
  late PaneFileSource _rightFileSource;

  /// The transfer queue used to live here as a `List<TransferItem> _transfers`
  /// field. That tied it to the lifecycle of this
  /// screen's State - so navigating to a terminal pane while a transfer
  /// was running would tear the queue down, and on return the user saw
  /// an empty panel (and couldn't tell if the transfer was still
  /// running). It now lives at app scope via [sftpTransfersProvider]
  /// so the queue survives any widget-tree churn - see the provider
  /// docs for the full reasoning.

  /// Sessions THIS screen opened via the in-pane "Connect to host…"
  /// flow. We're responsible for closing those on dispose; sessions
  /// fetched from the registry are NOT in here.
  final Set<String> _ownedSessionIds = {};

  /// The saved host of each session that was seen, kept so that a pane
  /// whose session is gone can still say which host that was, and connect
  /// it again.
  final Map<String, String> _hostOfSession = {};

  /// The connection of its session for which each side was last given a
  /// file service, or was refused one: asked once for each.
  final Map<int, TerminalSession?> _givenFor = {};

  /// Whether the panes are being looked after ([_followSessions]), and
  /// whether the sessions changed again meanwhile.
  bool _following = false;
  bool _followAgain = false;

  /// Pane refresh keys - used to call `refresh()` after a transfer or
  /// edit lands so the destination pane immediately shows the new file.
  final _leftPaneKey = GlobalKey<SftpPaneState>();
  final _rightPaneKey = GlobalKey<SftpPaneState>();

  /// Cancellation flags for in-flight transfers, keyed by transfer id.
  /// A `true` value means the user clicked Cancel - the active transfer
  /// loop checks this and bails out cleanly.
  final Map<String, bool> _cancelled = {};

  /// Real cancel tokens for in-flight transfers, keyed by transfer id. Unlike
  /// [_cancelled] (only observed on a progress tick, so it can't stop a wedged
  /// write), a token is passed all the way into the SFTP write loop and lets
  /// Cancel abort an in-flight transfer immediately.
  final Map<String, TransferCancelToken> _cancelTokens = {};

  /// Drops (by operationId) whose Cancel all was pressed: their walk stops
  /// and no file of them that has not started
  /// starts.
  final Set<String> _cancelledOperations = {};

  /// Files that DIFFERED from their destination but were skipped because the
  /// user chose "replace only when local is newer" and the local copy was not
  /// newer. Keyed by operationId. Surfaced when the operation ends, with a
  /// one-click "send them anyway" - never silently swallowed (that silence was
  /// the originally reported bug). [SFTP sync spec 1a]
  final Map<String, List<_SkippedOlder>> _skippedOlder = {};

  /// Captured in [initState] so [dispose] can do its session cleanup
  /// without touching `ref` - by the time `dispose` runs, the
  /// [ConsumerStatefulElement] is already torn down and reading `ref`
  /// throws "Cannot use 'ref' after the widget was disposed".
  late final SftpSessionsNotifier _sessionsNotifier;

  /// Captured at initState so background transfer work that outlives
  /// this State (the user navigates away while an upload is running)
  /// can still publish progress updates without touching `ref`.
  late final SftpTransfersNotifier _transfersNotifier;

  /// App-scoped delete-hold manager, captured so dispose can commit outstanding
  /// holds without touching `ref` (which throws after deactivation).
  late final SftpDeleteHoldManager _holdManager;

  @override
  void initState() {
    super.initState();
    _sessionsNotifier = ref.read(sftpSessionsProvider.notifier);
    _transfersNotifier = ref.read(sftpTransfersProvider.notifier);
    _holdManager = ref.read(sftpDeleteHoldProvider);
    // App background is a write trigger for the remembered folder (spec 2).
    WidgetsBinding.instance.addObserver(this);
    _watchLocalPlaces();
    // Repair any local pins that were seeded with a now-wrong path (a Desktop /
    // Documents seeded before OneDrive redirect moved them), dedupe, THEN seed
    // the stale-pin set. Heal first so a just-repaired pin isn't flagged stale.
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // The repair never holds the marks up for long: a pin on a server that
      // is off answers in its own time.
      try {
        await _healLocalPins().timeout(const Duration(seconds: 10));
      } catch (_) {}
      if (mounted) unawaited(_refreshStalePins());
    });
    if (widget.leftSftp != null) {
      // Remote↔remote: seed the left pane with its own remote (mirrors the
      // right-pane seeding below), replacing the old SftpRemoteDualPaneScreen.
      final lsid = widget.leftSessionId ?? 'initial-left';
      _leftSource = RemotePaneSource(
        sessionId: lsid,
        // No context in initState: the app-wide localizations.
        hostLabel: widget.leftLabel ?? gl10n.sftpRemote,
        service: widget.leftSftp!,
      );
      _leftFileSource = RemotePaneFileSource(
        service: widget.leftSftp!,
        sourceId: lsid,
      );
    } else {
      _leftSource = const LocalPaneSource();
      _leftFileSource = LocalPaneFileSource();
    }
    if (widget.ftps != null) {
      _rightSource = FtpsPaneSource(
        sessionId: widget.initialSessionId ?? widget.ftps!.sourceId,
        hostLabel: widget.connectionLabel ?? gl10n.sftpRemote,
        files: widget.ftps!,
      );
      _rightFileSource = widget.ftps!;
    } else if (widget.sftp != null) {
      final sid = widget.initialSessionId ?? 'initial';
      _rightSource = RemotePaneSource(
        sessionId: sid,
        hostLabel: widget.connectionLabel ?? gl10n.sftpRemote,
        service: widget.sftp!,
      );
      _rightFileSource = RemotePaneFileSource(
        service: widget.sftp!,
        sourceId: sid,
      );
    } else {
      _rightSource = const LocalPaneSource();
      _rightFileSource = LocalPaneFileSource();
    }
    _noteSessions(ref.read(activeSessionsProvider));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden) {
      _flushPathWriters();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _placesSub?.cancel();
    // Pane close is a write trigger (spec 2): land any pending folder memory
    // now, quick if a transfer holds the channel.
    _flushPathWriters();
    for (final w in _pathWriters.values) {
      w.dispose();
    }
    // The SFTP view is closing: commit every outstanding delete hold before the
    // session is torn down (delete safety spec §3). A hold is a delay, never a
    // cancellation - a user who deletes then closes must NOT return to find the
    // files still there. The commit runs against the app-scoped session via the
    // app-scoped manager, so it completes even though this screen is gone.
    //
    // Close only the services we opened ourselves, and only AFTER their holds
    // have committed (§7: closing a session out from under an in-flight commit
    // is exactly how this feature loses data). Adopted sessions are someone
    // else's problem. Uses [_sessionsNotifier] captured in [initState] rather
    // than `ref.read(...)` - dispose runs after the element is deactivated.
    for (final sid in _ownedSessionIds) {
      final svc = _sessionsNotifier.get(sid);
      if (svc != null) {
        // (Once this frame is done: a screen taken away with its tab cannot
        // change a provider while the tree is taken down.)
        _sessionsNotifier.unregisterLater(sid, svc);
        _holdManager.commitSessionThenClose(sid, () async {
          try {
            await svc.close();
          } catch (e) {
            AppLogger.warning('SFTP close on dispose failed: $e');
          }
        });
      }
    }
    // Adopted-session holds + local-fallback holds have no session for us to
    // close; just commit them.
    _holdManager.commitSession(null);
    super.dispose();
  }

  // ── Remember the last folder (spec sections 1-3, 6) ────────────────

  /// The SFTP leaf's own session: the key this pane pair's state is kept and
  /// restored under. Null for a screen with no session (local <-> local).
  String? get _paneStateKey => widget.initialSessionId ?? widget.leftSessionId;

  /// One debounced writer per side (spec 2: ten rapid navigations = one
  /// write; never during a transfer).
  final Map<int, DebouncedWriter> _pathWriters = {};

  DebouncedWriter _writerFor(int side) => _pathWriters.putIfAbsent(
        side,
        () => DebouncedWriter(
          canWriteNow: () => !ref.read(sftpHasActiveTransferProvider),
        ),
      );

  void _flushPathWriters() {
    for (final w in _pathWriters.values) {
      // ignore: discarded_futures
      w.flush();
    }
  }

  /// The live session behind a remote pane, or null for a local one.
  SessionState? _sessionFor(int side) {
    final desc = side == 0 ? _leftSource : _rightSource;
    if (desc is! RemotePaneSource) return null;
    return ref.read(activeSessionsProvider)[desc.sessionId];
  }

  /// A pane finished listing [path]: remember it at once in memory (keyed by
  /// the leaf session, so a restart or a saved workspace brings the pane
  /// back here) and, after the debounce, in `realpath` form: the remote pane
  /// also updates the host default on the connection record.
  void _onPathSettled(int side, String path) {
    final key = _paneStateKey;
    if (key == null) return;
    final desc = side == 0 ? _leftSource : _rightSource;
    final fs = side == 0 ? _leftFileSource : _rightFileSource;
    // Captured now: the write may run after this State is gone.
    final notifier = ref.read(sftpPanePathsProvider.notifier);
    if (desc is RemotePaneSource) {
      final session = _sessionFor(side);
      final connId = session?.connectionId;
      final user = session?.username;
      final dao = ref.read(connectionsDaoProvider);
      notifier.setRemote(key, path: path, user: user, connectionId: connId);
      _writerFor(side).schedule(({required bool quick}) async {
        var canonical = path;
        if (!quick) {
          try {
            canonical = await fs.realpath(path);
          } catch (_) {
            // Keep the navigated form; the next settle canonicalises it.
          }
        }
        notifier.setRemote(key,
            path: canonical, user: user, connectionId: connId);
        if (connId == null) return;
        try {
          await dao.setLastRemotePath(connId, path: canonical, user: user);
        } catch (e) {
          AppLogger.warning('Could not remember the SFTP folder: $e');
        }
      });
    } else if (desc is LocalPaneSource) {
      notifier.setLocal(key, path);
      _writerFor(side).schedule(({required bool quick}) async {
        if (quick) return;
        try {
          notifier.setLocal(key, await fs.realpath(path));
        } catch (_) {}
      });
    }
  }

  /// The host default for a remote pane (spec 1: where a NEW pane starts).
  /// A folder seen under a different username is still offered, as a
  /// suggestion: the pane tries it and falls back quietly, no notice.
  Future<RememberedCandidate?> _hostDefaultFor(int side) async {
    final session = _sessionFor(side);
    final connId = session?.connectionId;
    if (connId == null) return null;
    final conn = await ref.read(connectionsDaoProvider).getById(connId);
    final path = conn?.lastRemotePath;
    if (conn == null || path == null || path.isEmpty) return null;
    final sameUser =
        conn.lastRemoteUser == null || conn.lastRemoteUser == session?.username;
    return RememberedCandidate(path, suggestion: !sameUser);
  }

  /// Spec 6: the same folder resolved on this host again. Returns the visit
  /// count once it is worth offering a pin, null otherwise (already pinned,
  /// declined before, or not yet often enough).
  Future<int?> _shouldSuggestPin(int side, String path) async {
    final connId = _sessionFor(side)?.connectionId;
    if (connId == null) return null;
    // The counters name the host and the folder, so they live in the
    // encrypted database, not in preferences.
    final store = ref.read(localStateStoreProvider);
    if (await store.readBool('$kSftpPinDeclinedPrefix$connId:$path')) {
      return null;
    }
    if (_pinsForSide(side).any((p) => p.path == path)) return null;
    // Nor a folder the team already keeps a bookmark for.
    if (_sharedPinsForSide(side).any((p) => p.path == path)) return null;
    final key = '$kSftpFolderVisitsPrefix$connId:$path';
    final n = (await store.readInt(key) ?? 0) + 1;
    await store.writeInt(key, n);
    return n >= kSftpPinSuggestionThreshold ? n : null;
  }

  /// "Not now" suppresses the offer for that folder for good (spec 6).
  Future<void> _declinePinSuggestion(int side, String path) async {
    final connId = _sessionFor(side)?.connectionId;
    if (connId == null) return;
    await ref
        .read(localStateStoreProvider)
        .writeBool('$kSftpPinDeclinedPrefix$connId:$path', true);
  }

  // ── Pane source change ────────────────────────────────────────────

  /// Build the operations facade matching a descriptor. For
  /// disconnected sources the placeholder pane is rendered separately,
  /// so this returns a Local source as a harmless fallback (it'll be
  /// thrown away the moment the user reconnects).
  PaneFileSource _fileSourceFor(SftpPaneSource desc) {
    return switch (desc) {
      LocalPaneSource() => LocalPaneFileSource(),
      RemotePaneSource(:final service, :final sessionId) =>
        RemotePaneFileSource(service: service, sourceId: sessionId),
      FtpsPaneSource(:final files) => files,
      DisconnectedPaneSource() => LocalPaneFileSource(),
    };
  }

  /// Commit the holds for the host [prev] was on before a pane switches away
  /// from it (delete safety spec §3: "commit that host's holds first, then
  /// switch"). A no-op unless [prev] was a remote source AND the pane's OTHER
  /// side isn't still on that same session (in which case its holds stay live).
  void _commitHoldsLeavingSource(SftpPaneSource prev, SftpPaneSource other) {
    if (prev is! RemotePaneSource) return;
    if (other is RemotePaneSource && other.sessionId == prev.sessionId) return;
    _holdManager.commitSession(prev.sessionId);
  }

  void _onLeftSourceChanged(SftpPaneSource next) {
    _commitHoldsLeavingSource(_leftSource, _rightSource);
    if (next is RemotePaneSource && !next.service.isOpen) {
      // Defence in depth: a closed service shouldn't reach this point
      // (the dropdown filters them) but if it does - re-open before
      // letting the pane try to listdir() and crash with "SFTP not
      // open. Call open() first.".
      _reopenAndApply(next, 0);
      return;
    }
    setState(() {
      _leftSource = next;
      _leftFileSource = _fileSourceFor(next);
    });
  }

  void _onRightSourceChanged(SftpPaneSource next) {
    _commitHoldsLeavingSource(_rightSource, _leftSource);
    if (next is RemotePaneSource && !next.service.isOpen) {
      _reopenAndApply(next, 1);
      return;
    }
    setState(() {
      _rightSource = next;
      _rightFileSource = _fileSourceFor(next);
    });
  }

  /// A pane on a host follows what becomes of its session.
  ///
  /// The file service of a pane is no longer open once its connection has
  /// dropped ([SftpService.isOpen]). While its session is still there and
  /// not connected, the pane stays as it is: what it listed stays, and what
  /// it is asked says that the connection was lost. When the session is
  /// connected again, which it is on a connection of its own, the pane is
  /// given a file service on that one ([_reopenAndApply]), once for each
  /// connection, and lists again by itself where a listing had failed. When
  /// the session is gone (its tab was closed), the pane says that the host
  /// is disconnected and offers to connect it again.
  ///
  /// (A pane kept the file service of the connection that had dropped for
  /// as long as the file screen was open: every listing said that the
  /// connection was lost, and so did Retry.)
  Future<void> _followSessions() async {
    if (_following) {
      _followAgain = true;
      return;
    }
    _following = true;
    try {
      do {
        _followAgain = false;
        for (final side in const [0, 1]) {
          if (!mounted) return;
          final sessions = ref.read(activeSessionsProvider);
          _noteSessions(sessions);
          final source = side == 0 ? _leftSource : _rightSource;
          if (source is FtpsPaneSource && sessions[source.sessionId] == null) {
            final host = _hostOfSession[source.sessionId];
            if (host != null) _showDisconnectedLabel(side, source.hostLabel, host);
            continue;
          }
          if (source is! RemotePaneSource) continue;
          final session = sessions[source.sessionId];
          if (session == null) {
            final host = _hostOfSession[source.sessionId];
            if (host != null) _showDisconnected(side, source, host);
          } else if (!source.service.isOpen &&
              // (A session has a shell while it is connected, and only then.)
              session.session?.shell is SshService &&
              !identical(_givenFor[side], session.session)) {
            _givenFor[side] = session.session;
            await _reopenAndApply(source, side);
          }
        }
      } while (_followAgain);
    } finally {
      _following = false;
    }
  }

  void _noteSessions(Map<String, SessionState> sessions) {
    for (final entry in sessions.entries) {
      final host = entry.value.connectionId;
      if (host != null) _hostOfSession[entry.key] = host;
    }
  }

  /// The pane on [side], which was on [was], says that its host is
  /// disconnected.
  void _showDisconnected(int side, RemotePaneSource was, String connectionId) =>
      _showDisconnectedLabel(side, was.hostLabel, connectionId);

  void _showDisconnectedLabel(int side, String hostLabel, String connectionId) {
    final gone = DisconnectedPaneSource(
      connectionId: connectionId,
      hostLabel: hostLabel,
      lastPath: (side == 0 ? _leftPaneKey : _rightPaneKey).currentState?.currentPath,
    );
    if (side == 0) {
      _onLeftSourceChanged(gone);
    } else {
      _onRightSourceChanged(gone);
    }
  }

  /// Connects the host a pane was on again, and opens the pane where it
  /// was. A host that is no longer saved cannot be: the hosts are offered
  /// to pick from.
  Future<void> _reconnectHost(int side, DisconnectedPaneSource gone) async {
    final saved = await ref.read(connectionsDaoProvider).getById(gone.connectionId);
    if (!mounted) return;
    if (saved == null) return _onConnectRequested(side);
    await _connectToConnection(side, ConnectionWithDetails(connection: saved), openAt: gone.lastPath);
  }

  /// Gives a pane whose file service is not open one that is: the one its
  /// session has registered, where that goes on (another pane of the session
  /// was given it); else its own opened again, on the connection it has
  /// (cheap - just re-creates the SFTP subsystem on the same SshClient); or,
  /// if that fails because the connection is gone too, a new one on the
  /// connection the session has now. Then applies the resulting source to
  /// the requested side.
  Future<void> _reopenAndApply(RemotePaneSource closed, int side) async {
    // The host's Crate must still allow SFTP.
    final connectionId = ref.read(activeSessionsProvider)[closed.sessionId]?.connectionId;
    if (connectionId != null &&
        !await ref.read(activeSessionsProvider.notifier).hostAllows(connectionId, CrateSwitches.sftp)) {
      if (mounted) {
        showTopSnackBar(context, AppLocalizations.of(context)!.orchardSftpNotAllowed, isWarning: true);
      }
      return;
    }
    SftpService usable = closed.service;
    final registered = ref.read(sftpSessionsProvider.notifier).get(closed.sessionId);
    if (registered != null && registered.isOpen) {
      usable = registered;
    } else {
      try {
        await usable.open();
      } catch (_) {
        usable = await _openOnLiveSession(closed) ?? usable;
      }
    }
    if (!mounted || !usable.isOpen) return;
    final fresh = RemotePaneSource(
      sessionId: closed.sessionId,
      hostLabel: closed.hostLabel,
      service: usable,
      serverId: closed.serverId,
    );
    setState(() {
      if (side == 0) {
        _leftSource = fresh;
        _leftFileSource = _fileSourceFor(fresh);
      } else {
        _rightSource = fresh;
        _rightFileSource = _fileSourceFor(fresh);
      }
    });
  }

  /// A file service on the connection the session of [closed] has now,
  /// registered for it; null, with why said, where it has none.
  Future<SftpService?> _openOnLiveSession(RemotePaneSource closed) async {
    final session = ref.read(activeSessionsProvider)[closed.sessionId];
    if (sshServiceOfShell(session?.session?.shell) == null) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.sftpSessionGone,
          isError: true,
        );
      }
      return null;
    }
    final usable = SftpService(sshServiceOfShell(session!.session!.shell)!.client);
    try {
      await usable.open();
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, sftpErrorMessage(e, op: SftpOp.list),
          isError: true, details: e.toString());
      }
      return null;
    }
    ref.read(sftpSessionsProvider.notifier).register(closed.sessionId, usable);
    _ownedSessionIds.add(closed.sessionId);
    return usable;
  }

  // ── Connect-to-host (in-pane) ─────────────────────────────────────

  /// Run the picker → start session → open SFTP → register → push
  /// source pipeline for a pane that picked "Connect to host…" from
  /// the dropdown. Side: 0 = left, 1 = right.
  ///
  /// Reuses an existing SSH session for the picked connection if one is
  /// already running (no `allowDuplicate` - the user expects "Connect
  /// to host" to swap THIS pane to that host, not to spawn a duplicate
  /// connection). Calls [WorkTabsNotifier.expectSplitSession] before
  /// `startSession` so any newly-created session goes into THIS pane
  /// rather than spawning a fresh terminal tab - without that hint the
  /// activeSessionsProvider listener auto-tabs the new session, which
  /// is exactly the "loaded as a whole new tab" symptom users hit.
  Future<void> _onConnectRequested(int side) async {
    final result = await ConnectionPickerDialog.show(
      context,
      title: AppLocalizations.of(context)!.sftpConnectToHost,
      includeLocalFiles: false,
    );
    if (!mounted) return;
    final picked = result.connection;
    if (picked == null) return;
    await _connectToConnection(side, picked);
  }

  /// Connect to a specific saved host and adopt it into [side]. Extracted from
  /// [_onConnectRequested] so the filterable source picker can
  /// connect to a saved host directly, without re-opening the picker dialog.
  Future<void> _connectToConnection(
      int side, ConnectionWithDetails picked, {String? openAt}) async {
    // A Telnet host has no files to give: said before anything connects,
    // rather than an unencrypted session opened unasked that cannot give them.
    if (isTelnetHost(picked.connection)) {
      showTopSnackBar(context, AppLocalizations.of(context)!.desktopShellSftpRequiresSsh, isError: true);
      return;
    }
    final notifier = ref.read(activeSessionsProvider.notifier);
    // The host's Crate must allow SFTP: no session is opened
    // for a host whose files this account may not browse.
    if (!await notifier.hostAllows(picked.connection.id, CrateSwitches.sftp)) {
      if (mounted) {
        final l10n = AppLocalizations.of(context)!;
        showTopSnackBar(
            context,
            ConnectionProtocol.storedIsFtps(picked.connection.protocol)
                ? l10n.orchardFtpsNotAllowed
                : l10n.orchardSftpNotAllowed,
            isWarning: true);
      }
      return;
    }
    if (!mounted) return;
    // Suppress auto-tabbing of the next added session: the SFTP pane
    // adopts it directly, no new terminal tab.
    ref.read(workTabsProvider.notifier).expectSplitSession();
    final sid = notifier.startSession(picked.connection);
    if (sid == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpFreeTierLimit,
        isError: true,
      );
      return;
    }

    // Wait for the session to reach `connected` (or surface its error).
    SessionState? session;
    try {
      session = await _waitForSession(sid);
    } on SessionNotReady catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, e.said, isError: true, details: e.happened);
      return;
    }

    if (!mounted) return;

    // An FTPS host's session (3.4): its own connection, its files here.
    final ftpsShell = session.session?.shell;
    if (ftpsShell is FtpsShellService && ftpsShell.client != null) {
      final ftps = FtpsPaneSource(
        sessionId: sid,
        hostLabel: session.connectionLabel,
        files: FtpsPaneFileSource(client: ftpsShell.client!, sourceId: sid, reconnect: ftpsShell.reconnect),
      );
      if (openAt != null) ref.read(lastSftpPathsProvider).set(sid, openAt);
      if (side == 0) {
        _onLeftSourceChanged(ftps);
      } else {
        _onRightSourceChanged(ftps);
      }
      return;
    }

    if (sshServiceOfShell(session.session?.shell) == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpShellUnavailable,
        isError: true,
      );
      return;
    }

    // If an SFTP service is already registered AND open for this
    // session (typical when reusing an existing connection), reuse it
    // - opening a second subsystem on the same SshClient just for this
    // pane is wasteful.
    final registered =
        ref.read(sftpSessionsProvider.notifier).get(sid);
    SftpService sftp;
    if (registered != null && registered.isOpen) {
      sftp = registered;
    } else {
      final ssh = sshServiceOfShell(session.session!.shell)!;
      sftp = SftpService(ssh.client);
      try {
        await sftp.open();
      } catch (e) {
        if (!mounted) return;
        showTopSnackBar(context, sftpStartFailure(e), isError: true, details: e.toString());
        return;
      }

      if (!mounted) {
        // Tab was disposed mid-open - close the orphan to avoid leaking
        // the SFTP channel.
        // ignore: discarded_futures
        sftp.close();
        return;
      }

      ref.read(sftpSessionsProvider.notifier).register(sid, sftp);
      _ownedSessionIds.add(sid);
    }

    // Stable per-server identity for the folder-sync manifest (a label is
    // neither unique nor stable). Best effort: null falls back to the label.
    String? serverId;
    try {
      final shell = session.session?.shell;
      if (shell is SshService) {
        serverId = '${shell.username}@${shell.host}:${shell.port}';
      }
    } catch (_) {}
    final descriptor = RemotePaneSource(
      sessionId: sid,
      hostLabel: session.connectionLabel,
      service: sftp,
      serverId: serverId,
    );
    // (Where a pane opens is where its source was last: see [SftpPane].)
    if (openAt != null) ref.read(lastSftpPathsProvider).set(sid, openAt);
    if (side == 0) {
      _onLeftSourceChanged(descriptor);
    } else {
      _onRightSourceChanged(descriptor);
    }
  }

  /// Polls [activeSessionsProvider] until the session for [sid] is
  /// connected (returns its state), or throws [SessionNotReady] saying why
  /// not. Times out at 30s - which is well past any realistic SSH handshake
  /// but short enough that a hung session isn't permanent.
  Future<SessionState> _waitForSession(String sid) =>
      // (A screen closed while it waits reads as the session gone: its ref
      // may not be read any more.)
      waitForSessionReady(() => mounted ? ref.read(activeSessionsProvider)[sid] : null);

  // ── Drop dispatch / transfer queue ────────────────────────────────

  /// Resolve the pane source descriptor + file source for a given side.
  // ── Locations rail ─────────────────────────────────────────────────

  /// Local quick-jump places, computed once. `root: true` = a drive / filesystem
  /// root (fixed, never a pin, sits below the hairline); `root: false` = a seed
  /// default (steps aside once the pane has its first pin).
  List<({String label, String path, IconData icon, bool root})> _localPlaces =
      const [];

  /// Common remote directories offered on any remote pane. `/` is the root
  /// (fixed); the rest are seed guesses that step aside once a host is pinned.
  static const List<({String label, String path, IconData icon, bool root})>
      _remotePlaces = [
    (label: '/', path: '/', icon: LucideIcons.hardDrive, root: true),
    (label: '/root', path: '/root', icon: LucideIcons.folder, root: false),
    (label: '/home', path: '/home', icon: LucideIcons.folder, root: false),
    (label: '/etc', path: '/etc', icon: LucideIcons.folder, root: false),
    (label: '/var/log', path: '/var/log', icon: LucideIcons.folder, root: false),
    (label: '/tmp', path: '/tmp', icon: LucideIcons.folder, root: false),
  ];

  /// Finds [_localPlaces] without the UI thread ever waiting on a disk: the
  /// drives come from the list Windows keeps in memory, and each folder check
  /// answers in its own time (a drive letter mapped to a server that is off
  /// used to freeze this whole window for as long as Windows waited on it).
  final LocalPlacesFinder _placesFinder = LocalPlacesFinder();
  StreamSubscription<List<LocalPlace>>? _placesSub;

  static IconData _placeIcon(LocalPlaceKind kind) => switch (kind) {
        LocalPlaceKind.home => LucideIcons.home,
        LocalPlaceKind.downloads => LucideIcons.download,
        LocalPlaceKind.desktop => LucideIcons.monitor,
        LocalPlaceKind.documents => LucideIcons.fileText,
        LocalPlaceKind.drive => LucideIcons.hardDrive,
      };

  void _setLocalPlaces(List<LocalPlace> places) {
    _localPlaces = [
      for (final pl in places)
        (
          label: pl.label,
          path: pl.path,
          icon: _placeIcon(pl.kind),
          root: pl.isRoot,
        ),
    ];
  }

  /// Home and the listed drives are there at once; Desktop / Documents /
  /// Downloads (only when they resolve to a real folder, OneDrive aware, so a
  /// click never lands on "Directory not found") and any drive Windows had
  /// not reconnected yet join the rail as each answers.
  void _watchLocalPlaces() {
    _setLocalPlaces(_placesFinder.immediate());
    _placesSub = _placesFinder.watch().listen((places) {
      if (!mounted) return;
      setState(() => _setLocalPlaces(places));
    });
  }

  /// Rail groups derived from the two panes' current sources: a "This PC" group
  /// for a local pane, the host's common dirs for a remote pane. Each item
  /// navigates the pane it belongs to.
  // ── SFTP pins ─────────────────────────────────

  String? _connectionIdForSide(int side) {
    final desc = side == 0 ? _leftSource : _rightSource;
    if (desc is RemotePaneSource) {
      return ref.read(activeSessionsProvider)[desc.sessionId]?.connectionId;
    }
    return null;
  }

  /// Pins for [side]: device-local pins for a This-PC pane, the connection's
  /// synced host pins for a remote pane. Uses `ref.read` so it's safe from both
  /// build and button handlers; the rail's reactivity comes from build()
  /// watching the two pin sources directly.
  List<SftpPin> _pinsForSide(int side) {
    final desc = side == 0 ? _leftSource : _rightSource;
    if (desc is LocalPaneSource) {
      // Show the seed defaults VIRTUALLY until the user first modifies pins for
      // this source; once modified (even to empty) the stored list is respected,
      // so a removed default stays removed and is never re-seeded.
      // Persistence happens on the first mutation via _applyPins.
      final notifier = ref.read(sftpLocalPinsProvider.notifier);
      return notifier.isSeeded
          ? ref.read(sftpLocalPinsProvider)
          : _defaultLocalPins();
    }
    final connId = _connectionIdForSide(side);
    if (connId == null) return const [];
    final conns =
        ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    for (final c in conns) {
      if (c.connection.id == connId) {
        // pins == null → never modified → show defaults; non-null (incl "[]") →
        // respect exactly what the user has.
        return c.connection.pins != null
            ? decodePins(c.connection.pins)
            : _defaultRemotePins();
      }
    }
    return const [];
  }

  // ── A team host's shared bookmarks (4.0) ─────────────────────────

  /// The connection [side] shows when it is a team's host: a remote pane
  /// on a host of the team on screen (the rail reads hosts from the space on
  /// screen, as [_pinsForSide] does). Null for This PC, a personal host, and
  /// a host the space on screen does not have.
  String? _teamHostForSide(int side) {
    if (ref.read(activeSpaceProvider) is! OrchardSpace) return null;
    final connId = _connectionIdForSide(side);
    if (connId == null) return null;
    final conns = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    return conns.any((c) => c.connection.id == connId) ? connId : null;
  }

  /// The bookmarks the team shares for [side]'s host, in the order they were
  /// added; none for anything but a team's host.
  List<SftpPin> _sharedPinsForSide(int side) {
    final connId = _teamHostForSide(side);
    if (connId == null) return const [];
    final conns = ref.read(connectionsWithDetailsProvider).valueOrNull ?? const [];
    for (final c in conns) {
      if (c.connection.id == connId) return decodePins(c.connection.sharedPins);
    }
    return const [];
  }

  /// Whether this account may change the team's bookmarks of [side]'s host:
  /// exactly when it may edit the host (the host editor's own check; the
  /// team's database refuses anyone else's write anyway). [watch] in build.
  bool _mayEditSharedPins(int side, {bool watch = false}) {
    final connId = _teamHostForSide(side);
    return connId != null && mayChangeItem(ref, 'host', connId, watch: watch);
  }

  /// Saves [next] as the team's bookmarks of [side]'s host. A refusal (the
  /// role changed meanwhile) is said, and nothing changes.
  Future<void> _applySharedPins(int side, List<SftpPin> next) async {
    final connId = _teamHostForSide(side);
    if (connId == null || !mounted) return;
    final dao = ref.read(connectionsDaoProvider);
    await runTeamWrite(
      context,
      () => dao.setSharedPins(connId, next.isEmpty ? null : encodePins(next)),
      where: 'SFTP team bookmarks',
    );
  }

  /// Whether [path] can join [side]'s team bookmarks now: a team host this
  /// account may edit, a folder not shared yet, room in the list, and a path
  /// short enough to keep whole.
  bool _canShareFolder(int side, String? path) {
    if (path == null || !_mayEditSharedPins(side)) return false;
    final shared = _sharedPinsForSide(side);
    return shared.length < kMaxSharedPins &&
        !shared.any((p) => p.path == path) &&
        canSharePinPath(path);
  }

  Future<void> _addSharedPin(int side, String path) async {
    if (!_canShareFolder(side, path)) return;
    await _applySharedPins(side, [
      ..._sharedPinsForSide(side),
      SftpPin(label: _pinLabelFor(path), path: path),
    ]);
  }

  Future<void> _removeSharedPin(int side, String path) async {
    if (!_mayEditSharedPins(side)) return;
    final shared = _sharedPinsForSide(side);
    if (!shared.any((p) => p.path == path)) return;
    await _applySharedPins(side, [for (final p in shared) if (p.path != path) p]);
  }

  Future<void> _renameSharedPin(int side, String path) async {
    if (!_mayEditSharedPins(side)) return;
    final pin = _sharedPinsForSide(side).where((p) => p.path == path).firstOrNull;
    if (pin == null) return;
    final l10n = AppLocalizations.of(context)!;
    // The shell's one field (the dialog rules, 3.4).
    final label = await showZestInputDialog(
      context: context,
      title: l10n.sftpRenameTeamBookmark,
      icon: LucideIcons.pencil,
      hintText: l10n.snippetsLabel,
      initialValue: pin.label,
      confirmLabel: l10n.sftpRename,
    );
    if (label == null || label.trim() == pin.label || !mounted) return;
    // Read again: the team's list may have changed while the dialog was open.
    await _applySharedPins(side, [
      for (final p in _sharedPinsForSide(side))
        if (p.path == path) p.withLabel(label.trim()) else p,
    ]);
  }

  /// The menu of a team bookmark in the rail, for a member who may change
  /// them: rename it, or take it out of the team's list.
  Future<void> _showSharedPinMenu(int side, SftpPin pin, Offset pos) async {
    final l10n = AppLocalizations.of(context)!;
    final action = await showSftpContextMenu(
      context,
      globalPosition: pos,
      header: SftpMenuHeader(icon: SftpMenuIcons.teamBookmark, path: pin.path),
      entries: [
        const SftpMenuSeparator(),
        SftpMenuItem(
          icon: SftpMenuIcons.rename,
          label: l10n.sftpRenameEllipsis,
          value: 'rename',
        ),
        const SftpMenuSeparator(),
        // A bookmark, not a file: not danger.
        SftpMenuItem(
          icon: SftpMenuIcons.removePin,
          label: l10n.sftpRemoveTeamBookmark,
          value: 'remove',
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'rename':
        await _renameSharedPin(side, pin.path);
      case 'remove':
        await _removeSharedPin(side, pin.path);
    }
  }

  /// The seed defaults surfaced as ordinary, removable pins on first use. Only
  /// the FOLDER seeds - drives / filesystem roots are NOT pins;
  /// they render below a divider, fixed and non-removable, via [_rootRows].
  List<SftpPin> _defaultLocalPins() => [
        for (final pl in _localPlaces)
          if (!pl.root) SftpPin(label: pl.label, path: pl.path),
      ];
  List<SftpPin> _defaultRemotePins() => [
        for (final pl in _remotePlaces)
          if (!pl.root) SftpPin(label: pl.label, path: pl.path),
      ];

  /// The label a pin is SHOWN with. A seeded local place keeps its English
  /// label ('Home', 'Downloads', ...) in storage, because [_healLocalPins]
  /// finds a seed by that label and joins it as the folder name; so only the
  /// display is translated, and only for the seed itself (same label AND same
  /// path), never for a user's own folder that happens to share the name.
  String _pinDisplayLabel(SftpPin pin, bool isLocal) {
    if (!isLocal) return pin.label;
    for (final pl in _localPlaces) {
      if (!pl.root && pl.label == pin.label && pl.path == pin.path) {
        return _placeLabel(pl.label);
      }
    }
    return pin.label;
  }

  /// The translated name of a seeded local place, by its stored label.
  String _placeLabel(String label) {
    final l10n = AppLocalizations.of(context)!;
    return switch (label) {
      'Home' => l10n.sftpPlaceHome,
      'Downloads' => l10n.sftpPlaceDownloads,
      'Desktop' => l10n.sftpPlaceDesktop,
      'Documents' => l10n.sftpPlaceDocuments,
      _ => label,
    };
  }

  /// Local pins whose path no longer resolves. Computed ASYNC off the build
  /// path and cached here - the existence check is blocking disk I/O, and doing
  /// it inside build (which reruns many times/sec during a transfer) froze the
  /// UI, badly on an offline mapped network drive.
  Set<String> _stalePins = {};

  /// Rail collapsed to a thin strip; the picker then
  /// returns to each path bar as a compact pill. Session-scoped.
  bool _railCollapsed = false;

  /// Which pane side a hovered rail group drives - outlines that pane (A1).
  int? _hoveredRailSide;

  /// Repair persisted LOCAL pins in place: a default (Home / Desktop /
  /// Documents / Downloads) whose stored path no longer exists but whose label
  /// names a folder that NOW resolves elsewhere (OneDrive redirect moved it
  /// after it was first seeded) is repointed to the resolved path. Then dedupe
  /// by path, so a "Restore defaults" that added the OneDrive copy alongside the
  /// old broken one collapses back to a single entry. A no-op when nothing needs
  /// fixing, so it's cheap to run on every open.
  Future<void> _healLocalPins() async {
    final env = Platform.environment;
    final home = env['USERPROFILE'] ?? env['HOME'];
    if (home == null || home.isEmpty) return;
    final current = ref.read(sftpLocalPinsProvider);
    if (current.isEmpty) return;
    // Asked off the UI thread and all at once: a blocking check here froze
    // the window on a pin that points at a drive whose server is off.
    final paths = await Future.wait(
        [for (final pin in current) _healedPinPath(pin, home)]);
    // The pins changed while the disk was being asked: leave them be, the
    // next open repairs what is still wrong.
    if (!mounted || !identical(ref.read(sftpLocalPinsProvider), current)) {
      return;
    }
    var changed = false;
    final repaired = <SftpPin>[];
    for (var i = 0; i < current.length; i++) {
      final pin = current[i];
      if (paths[i] == pin.path) {
        repaired.add(pin);
      } else {
        repaired.add(SftpPin(label: pin.label, path: paths[i]));
        changed = true;
      }
    }
    // Dedupe by path (case-insensitive on Windows), first occurrence wins.
    final seen = <String>{};
    final deduped = <SftpPin>[];
    for (final pin in repaired) {
      final key = Platform.isWindows ? pin.path.toLowerCase() : pin.path;
      if (seen.add(key)) {
        deduped.add(pin);
      } else {
        changed = true;
      }
    }
    if (changed) {
      ref.read(sftpLocalPinsProvider.notifier).setAll(deduped);
    }
  }

  static const _seedPinLabels = {'home', 'desktop', 'documents', 'downloads'};

  /// Where [pin] should point: its own path, unless it is a seeded default
  /// whose folder is gone and now resolves somewhere else. Only a seed can be
  /// repaired, so only a seed is asked about.
  Future<String> _healedPinPath(SftpPin pin, String home) async {
    final labelKey = pin.label.toLowerCase();
    if (!_seedPinLabels.contains(labelKey)) return pin.path;
    // Slow to answer is not the same as gone: only a clear "no" repairs.
    if (await _folderExistsSoon(pin.path) != false) return pin.path;
    final String? resolved;
    if (labelKey == 'home') {
      resolved = await _folderExistsSoon(home) == true ? home : null;
    } else {
      resolved = await _placesFinder
          .resolveUserFolder(pin.label)
          .timeout(_pinCheckPatience, onTimeout: () => null);
    }
    return resolved ?? pin.path;
  }

  static const _pinCheckPatience = Duration(seconds: 4);

  /// Whether [path] is a folder, or null when the disk has not said within
  /// [_pinCheckPatience] (a network location that is off takes far longer).
  Future<bool?> _folderExistsSoon(String path) async {
    try {
      return await Directory(path).exists().timeout(_pinCheckPatience);
    } on TimeoutException {
      return null;
    } catch (_) {
      return false;
    }
  }

  /// Bumped per refresh, so an answer from an earlier one is dropped.
  int _staleRun = 0;

  /// Marks the local pins whose folder is gone. Each pin is asked on its own
  /// and the mark lands when its answer does: one that points at a server
  /// that is off takes Windows most of a minute to answer, and must not hold
  /// up the marks of the others.
  Future<void> _refreshStalePins() async {
    if (!mounted) return;
    final run = ++_staleRun;
    final paths = {for (final pin in ref.read(sftpLocalPinsProvider)) pin.path};
    // A pin that left the list has nothing left to mark.
    if (_stalePins.any((path) => !paths.contains(path))) {
      setState(() => _stalePins = _stalePins.where(paths.contains).toSet());
    }
    for (final path in paths) {
      unawaited(() async {
        bool gone;
        try {
          gone = !await Directory(path).exists();
        } catch (_) {
          gone = true;
        }
        if (!mounted || run != _staleRun) return;
        if (gone == _stalePins.contains(path)) return; // already marked right
        setState(() {
          _stalePins = gone
              ? {..._stalePins, path}
              : _stalePins.where((other) => other != path).toSet();
        });
      }());
    }
  }

  /// Free-space label per drive / filesystem root, keyed by
  /// `side|path` so the two panes don't share a remote "/" reading. Filled
  /// lazily off the UI thread and cached for the session, so [_rootRows] can ask
  /// on every rebuild without ever spawning a probe twice.
  final Map<String, String> _rootFreeLabel = {};
  final Set<String> _rootFreeInFlight = {};

  /// One-time free-space probe for a drive / filesystem [path] on [side].
  /// Local roots read "234 GB free"; remote roots read "78% used" (the form the
  /// spec asks for on the filesystem entry). A no-op once cached or in flight.
  void _ensureRootFree(int side, String path, {required bool isLocal}) {
    final key = '$side|$path';
    if (_rootFreeLabel.containsKey(key) || _rootFreeInFlight.contains(key)) {
      return;
    }
    _rootFreeInFlight.add(key);
    // Captured now: the probe finishes after an await.
    final l10n = AppLocalizations.of(context)!;
    unawaited(() async {
      String? label;
      try {
        final fs = side == 0 ? _leftFileSource : _rightFileSource;
        final space = await fs.freeSpace(path);
        if (space != null && space.totalBytes > 0) {
          label = isLocal
              ? l10n.sftpFreeSpace(_formatShortBytes(space.freeBytes))
              : l10n.sftpUsedPercent((space.usedFraction * 100).round());
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _rootFreeInFlight.remove(key);
        // Always cache, even an empty result (server has no statvfs), so a root
        // that can't report free space isn't re-probed on every rebuild.
        _rootFreeLabel[key] = label ?? '';
      });
    }());
  }

  /// Compact byte size for the rail free-space readout: "234 GB", "1.5 TB".
  static String _formatShortBytes(int bytes) {
    return formatByteSize(bytes, digits: SizeDigits.belowHundred);
  }

  String _pinLabelFor(String path) {
    final norm = path.replaceAll('\\', '/');
    final trimmed = norm.length > 1 && norm.endsWith('/')
        ? norm.substring(0, norm.length - 1)
        : norm;
    final i = trimmed.lastIndexOf('/');
    final base = i >= 0 ? trimmed.substring(i + 1) : trimmed;
    return base.isEmpty ? trimmed : base;
  }

  /// Persist [next] as the pins for [side] (local prefs or the synced column).
  Future<void> _applyPins(int side, List<SftpPin> next) async {
    final desc = side == 0 ? _leftSource : _rightSource;
    if (desc is LocalPaneSource) {
      ref.read(sftpLocalPinsProvider.notifier).setAll(next);
      return;
    }
    final connId = _connectionIdForSide(side);
    if (connId == null) return;
    await ref
        .read(connectionsDaoProvider)
        .setPins(connId, next.isEmpty ? null : encodePins(next));
  }

  /// Pin/unpin [path] on [side] - the path-bar pin button + the rail.
  Future<void> _togglePinForSide(int side, String path) async {
    final pins = _pinsForSide(side);
    if (pins.any((p) => p.path == path)) {
      await _applyPins(side, [for (final p in pins) if (p.path != path) p]);
    } else {
      await _applyPins(
          side, [...pins, SftpPin(label: _pinLabelFor(path), path: path)]);
    }
  }

  Future<void> _showPinMenu(
      int side, List<SftpPin> pins, int index, Offset pos) async {
    if (index < 0 || index >= pins.length) return;
    final pin = pins[index];
    final stale = (side == 0 ? _leftSource : _rightSource) is LocalPaneSource &&
        _stalePins.contains(pin.path);
    final l10n = AppLocalizations.of(context)!;
    // Fixed geometry (§3, §8): Move up / Move down are always present and simply
    // disable at the ends, so every pin menu on the same list is one height and
    // Remove pin never shifts under the cursor. The header carries the stored
    // path (mono, middle-elided); the label stays in the rail row it belongs to.
    final action = await showSftpContextMenu(
      context,
      globalPosition: pos,
      header: SftpMenuHeader(
        icon: stale ? SftpMenuIcons.stale : SftpMenuIcons.pin,
        path: pin.path,
        stale: stale,
        trailing: stale ? l10n.sftpPinNotFound : null,
      ),
      entries: [
        // Separator between the path header and the actions (§2/§8): the header
        // is a caption, not an item, so it is fenced off from the clickable rows.
        const SftpMenuSeparator(),
        SftpMenuItem(
          icon: SftpMenuIcons.rename,
          label: l10n.sftpRenameEllipsis,
          value: 'rename',
          shortcut: 'F2',
        ),
        SftpMenuItem(
          icon: SftpMenuIcons.moveUp,
          label: l10n.zestNetworkMoveUp,
          value: 'up',
          shortcut: 'Alt+Up',
          enabled: index > 0,
        ),
        SftpMenuItem(
          icon: SftpMenuIcons.moveDown,
          label: l10n.zestNetworkMoveDown,
          value: 'down',
          shortcut: 'Alt+Down',
          enabled: index < pins.length - 1,
        ),
        const SftpMenuSeparator(),
        // Removing a pin deletes a shortcut, not a file, so it is not danger.
        SftpMenuItem(
          icon: SftpMenuIcons.removePin,
          label: l10n.sftpRemovePin,
          value: 'remove',
          shortcut: 'Del',
        ),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case 'rename':
        await _renamePin(side, pins, index);
      case 'up':
        await _movePin(side, pins, index, index - 1);
      case 'down':
        await _movePin(side, pins, index, index + 1);
      case 'remove':
        await _applyPins(side,
            [for (var i = 0; i < pins.length; i++) if (i != index) pins[i]]);
    }
  }

  Future<void> _renamePin(int side, List<SftpPin> pins, int index) async {
    final isLocal = (side == 0 ? _leftSource : _rightSource) is LocalPaneSource;
    // The field starts from the name the rail shows (a seeded place reads in
    // the app language); see [_pinDisplayLabel].
    final shown = _pinDisplayLabel(pins[index], isLocal);
    final l10n = AppLocalizations.of(context)!;
    // The shell's one field (the dialog rules, 3.4).
    final label = await showZestInputDialog(
      context: context,
      title: l10n.sftpRenamePin,
      icon: LucideIcons.pencil,
      hintText: l10n.snippetsLabel,
      initialValue: shown,
      confirmLabel: l10n.sftpRename,
    );
    if (label == null || !mounted) return;
    // Confirming the shown name unchanged keeps the stored label, so a
    // seeded place keeps the English label its repair looks it up by.
    final keep = label.trim() == shown;
    final next = [
      for (var i = 0; i < pins.length; i++)
        if (i == index && !keep) pins[i].withLabel(label.trim()) else pins[i],
    ];
    await _applyPins(side, next);
  }

  Future<void> _movePin(int side, List<SftpPin> pins, int from, int to) async {
    if (to < 0 || to >= pins.length) return;
    final next = List.of(pins);
    final pin = next.removeAt(from);
    next.insert(to, pin);
    await _applyPins(side, next);
  }

  /// Rail items for [side]: the removable pins, then a divider, then the fixed
  /// drives / filesystem roots (drives are NOT pins).
  List<RailItem> _railItemsForSide(int side) {
    final isLocal = (side == 0 ? _leftSource : _rightSource) is LocalPaneSource;
    final pins = _pinsForSide(side);
    final shared = _sharedPinsForSide(side);
    final roots = _rootRows(side, isLocal);
    // Called from build, so the rail follows a change of the role.
    final mayEditShared = _mayEditSharedPins(side, watch: true);
    final l10n = AppLocalizations.of(context)!;
    return [
      for (var i = 0; i < pins.length; i++)
        _pinRailItem(side, pins, i, isLocal),
      // A team host's shared bookmarks: their own group under your own pins,
      // not reorderable, changed only by a member who may edit the host.
      if (shared.isNotEmpty) ...[
        RailItem.section(
          label: l10n.sftpTeamBookmarks,
          note: mayEditShared ? null : l10n.sftpTeamBookmarksViewOnly,
        ),
        for (final pin in shared) _sharedPinRailItem(side, pin, mayEditShared),
      ],
      if (roots.isNotEmpty) const RailItem.divider(),
      ...roots,
    ];
  }

  RailItem _sharedPinRailItem(int side, SftpPin pin, bool mayEdit) => RailItem(
        icon: LucideIcons.folder,
        label: pin.label,
        id: 'team:${pin.path}',
        pathHint: pin.label != pin.path ? pin.path : null,
        onTap: () => _navigateSide(side, pin.path),
        onSecondaryTap: mayEdit ? (pos) => _showSharedPinMenu(side, pin, pos) : null,
      );

  // `i` is a parameter (captured by value) so each item's closures reference its
  // own index - a C-style for-loop variable would be shared across closures.
  RailItem _pinRailItem(int side, List<SftpPin> pins, int i, bool isLocal) {
    final pin = pins[i];
    final stale = isLocal && _stalePins.contains(pin.path);
    // Folder glyph (icons carry TYPE, not membership - everything here is a
    // pin), label only, and the path on the right ONLY when it differs from the
    // label.
    return RailItem(
      icon: LucideIcons.folder,
      label: _pinDisplayLabel(pin, isLocal),
      id: pin.path,
      reorderable: true,
      pathHint: pin.label != pin.path ? pin.path : null,
      stale: stale,
      onTap: () => _navigateSide(side, pin.path),
      onSecondaryTap: (pos) => _showPinMenu(side, pins, i, pos),
    );
  }

  /// Fixed drives / filesystem roots: NOT pins - no right-click
  /// menu, not reorderable, and they carry free space rather than a path. Sit
  /// below a divider from the pins.
  List<RailItem> _rootRows(int side, bool isLocal) {
    final places = isLocal ? _localPlaces : _remotePlaces;
    return [
      for (final pl in places)
        if (pl.root)
          () {
            // Probe (once) and read the cached free-space label for this root.
            _ensureRootFree(side, pl.path, isLocal: isLocal);
            final free = _rootFreeLabel['$side|${pl.path}'];
            return RailItem(
              icon: pl.icon,
              label: pl.label,
              trailing: (free == null || free.isEmpty) ? null : free,
              onTap: () => _navigateSide(side, pl.path),
            );
          }(),
    ];
  }

  /// Reorder [side]'s pins by dragging in the rail (oldIndex → newIndex).
  Future<void> _reorderPins(int side, int oldIndex, int newIndex) async {
    await _movePin(side, _pinsForSide(side), oldIndex, newIndex);
  }

  /// The bookmark menu (§4). From the path-bar bookmark button ([fromButton]
  /// true) it acts on the current folder's bookmark, which the button sits on
  /// and whose state it shows - so it can offer Remove / Rename. From a
  /// right-click on EMPTY rail space there is no visible target, so it never
  /// offers to remove one: it can only add the current folder (disabled when
  /// that folder is already pinned) or restore missing seeds - both
  /// non-destructive. "Restore default pins" disables when every seed is present.
  Future<void> _showBookmarkMenu(int side, Offset pos,
      {bool fromButton = false}) async {
    final paneKey = side == 0 ? _leftPaneKey : _rightPaneKey;
    final currentPath = paneKey.currentState?.currentPath;
    final pins = _pinsForSide(side);
    final alreadyPinned =
        currentPath != null && pins.any((p) => p.path == currentPath);
    final desc = side == 0 ? _leftSource : _rightSource;
    final defaults =
        desc is LocalPaneSource ? _defaultLocalPins() : _defaultRemotePins();
    final have = pins.map((p) => p.path).toSet();
    final allDefaultsPresent = defaults.every((d) => have.contains(d.path));
    final l10n = AppLocalizations.of(context)!;
    // A team host: a member who may edit it shares the folder with the team
    // (or, from the bookmark button on a folder already shared, takes it out).
    final mayEditShared = _mayEditSharedPins(side);
    final alreadyShared = currentPath != null &&
        _sharedPinsForSide(side).any((p) => p.path == currentPath);

    final entries = <SftpMenuEntry>[
      if (fromButton && alreadyPinned) ...[
        SftpMenuItem(
          icon: SftpMenuIcons.removePin,
          label: l10n.sftpRemoveBookmark,
          value: 'remove-current',
        ),
        SftpMenuItem(
          icon: SftpMenuIcons.rename,
          label: l10n.sftpRenameBookmark,
          value: 'rename-current',
        ),
      ] else
        SftpMenuItem(
          icon: SftpMenuIcons.bookmark,
          label: l10n.sftpBookmarkThisFolder,
          value: 'bookmark',
          enabled: currentPath != null && !alreadyPinned,
        ),
      if (mayEditShared)
        if (fromButton && alreadyShared)
          SftpMenuItem(
            icon: SftpMenuIcons.removePin,
            label: l10n.sftpRemoveTeamBookmark,
            value: 'team-remove',
          )
        else
          SftpMenuItem(
            icon: SftpMenuIcons.teamBookmark,
            label: l10n.sftpAddTeamBookmark,
            value: 'team-add',
            enabled: _canShareFolder(side, currentPath),
          ),
      const SftpMenuSeparator(),
      SftpMenuItem(
        icon: SftpMenuIcons.restore,
        label: l10n.sftpRestoreDefaultPins,
        value: 'restore',
        enabled: !allDefaultsPresent,
      ),
    ];

    final selected = await showSftpContextMenu(
      context,
      globalPosition: pos,
      entries: entries,
    );
    if (!mounted) return;
    switch (selected) {
      case 'bookmark':
      case 'remove-current':
        if (currentPath != null) await _togglePinForSide(side, currentPath);
      case 'rename-current':
        final idx = pins.indexWhere((p) => p.path == currentPath);
        if (idx >= 0) await _renamePin(side, pins, idx);
      case 'restore':
        await _restoreDefaults(side);
      case 'team-add':
        if (currentPath != null) await _addSharedPin(side, currentPath);
      case 'team-remove':
        if (currentPath != null) await _removeSharedPin(side, currentPath);
    }
  }

  /// Re-add any missing seed defaults without disturbing the user's own pins
  /// ("Restore defaults" in the group overflow).
  Future<void> _restoreDefaults(int side) async {
    final desc = side == 0 ? _leftSource : _rightSource;
    final defaults =
        desc is LocalPaneSource ? _defaultLocalPins() : _defaultRemotePins();
    final current = _pinsForSide(side);
    final have = current.map((p) => p.path).toSet();
    await _applyPins(side, [
      ...current,
      for (final d in defaults) if (!have.contains(d.path)) d,
    ]);
  }

  /// The collapsed rail: a 44px icon strip with one 30px
  /// source icon per side. The remote icon keeps its live reachability dot.
  /// Clicking an icon opens the same source picker as the expanded rail header;
  /// the chevron at the top restores the full rail.
  Widget _buildCollapsedRail() {
    return Container(
      width: 44,
      decoration: BoxDecoration(
        color: AppColors.sftpPanel,
        border: Border(right: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 6),
          IconButton(
            tooltip: AppLocalizations.of(context)!.sftpShowSidebar,
            icon: const Icon(LucideIcons.chevronsRight, size: 15),
            color: AppColors.textSecondary,
            visualDensity: VisualDensity.compact,
            onPressed: () => setState(() => _railCollapsed = false),
          ),
          const SizedBox(height: 2),
          const Divider(height: 1, thickness: 1, indent: 8, endIndent: 8),
          const SizedBox(height: 8),
          for (var side = 0; side < 2; side++) ...[
            _buildCollapsedSourceIcon(side),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }

  /// One 30px source icon in the collapsed rail. Tapping opens the source
  /// picker for [side], anchored just to the right of the strip - identical to
  /// tapping the header in the expanded rail. A live remote source carries a
  /// small reachability dot in the corner. A saved host's source shows the
  /// host's own icon ([HostGlyph]); the server glyph is for one of no saved
  /// host.
  Widget _buildCollapsedSourceIcon(int side) {
    final desc = side == 0 ? _leftSource : _rightSource;
    IconData icon = LucideIcons.server;
    Color iconColor = AppColors.textSecondary;
    Color? dotColor;
    // The host's own icon, where the source is a saved host's session.
    Widget? glyph;
    Widget? glyphOf(String? connectionId) {
      final host = connectionId == null ? null : ref.watch(hostsByIdProvider)[connectionId];
      return host == null ? null : HostGlyph(host: host.connection, group: host.group, size: 16);
    }
    String tooltip;
    if (desc is LocalPaneSource) {
      icon = LucideIcons.hardDrive;
      iconColor = AppColors.textSecondary;
      tooltip = thisComputerName(AppLocalizations.of(context)!);
    } else if (desc is RemotePaneSource) {
      final sess = ref.watch(activeSessionsProvider)[desc.sessionId];
      final connId = sess?.connectionId;
      final health =
          connId == null ? null : ref.watch(connectionHealthProvider)[connId];
      // A live session IS online, even for an unmonitored host: the health
      // poller only runs for monitored hosts, so its status stays null/unknown
      // (grey) otherwise even while you are actively browsing over SFTP.
      final online = sess?.status == SessionStatus.connected ||
          health?.status == ConnectionHealth.online;
      glyph = glyphOf(connId);
      dotColor = online
          ? AppColors.v3Success
          : (health?.status == ConnectionHealth.offline
              ? AppColors.v3Error
              : AppColors.v3TextTertiary);
      tooltip = Redactable.host(desc.hostLabel).displayIn(ref);
    } else if (desc is FtpsPaneSource) {
      // An FTPS host (3.4): online while its session is connected.
      final sess = ref.watch(activeSessionsProvider)[desc.sessionId];
      final online = sess?.status == SessionStatus.connected;
      glyph = glyphOf(sess?.connectionId);
      dotColor = online ? AppColors.v3Success : AppColors.v3TextTertiary;
      tooltip = Redactable.host(desc.hostLabel).displayIn(ref);
    } else {
      icon = LucideIcons.serverOff;
      iconColor = AppColors.error;
      tooltip = desc is DisconnectedPaneSource
          ? _disconnectedLabel(desc)
          : desc.label;
    }

    return Tooltip(
      message: tooltip,
      child: Builder(
        builder: (btnContext) => InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () {
            final box = btnContext.findRenderObject() as RenderBox?;
            final anchor = box == null
                ? Offset.zero
                : box.localToGlobal(
                    Offset(box.size.width, box.size.height / 2));
            _openSourcePickerForSide(side, anchor);
          },
          child: Container(
            width: 30,
            height: 30,
            // 30px --raised-2 box, radius 6, hairline border.
            decoration: BoxDecoration(
              color: AppColors.sftpRaised2,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppColors.divider, width: 1),
            ),
            child: Stack(
              alignment: Alignment.center,
              clipBehavior: Clip.none,
              children: [
                glyph ?? Icon(icon, size: 16, color: iconColor),
                if (dotColor != null)
                  Positioned(
                    right: -2,
                    top: -2,
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: dotColor,
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppColors.sftpPanel, width: 1.5),
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

  /// A dropped source's rail / tooltip label with the host name masked in
  /// recording mode. The model composes its label around the raw name, so the
  /// name is swapped for its display form rather than recomposed here.
  String _disconnectedLabel(DisconnectedPaneSource desc) => desc.label
      .replaceFirst(
          desc.hostLabel, Redactable.host(desc.hostLabel).displayIn(ref));

  List<RailGroup> _buildRailGroups() {
    final l10n = AppLocalizations.of(context)!;
    final groups = <RailGroup>[];
    for (var side = 0; side < 2; side++) {
      final desc = side == 0 ? _leftSource : _rightSource;
      if (desc is LocalPaneSource) {
        groups.add(RailGroup(
          label: thisComputerName(l10n),
          paneSide: side,
          sourceIcon: LucideIcons.hardDrive,
          sourceIconColor: AppColors.textSecondary,
          onHeaderTap: (anchor) => _openSourcePickerForSide(side, anchor),
          onHeaderHover: (h) =>
              setState(() => _hoveredRailSide = h ? side : null),
          onEmptyAreaMenu: (pos) => _showBookmarkMenu(side, pos),
          onReorderPins: (o, n) => _reorderPins(side, o, n),
          items: _railItemsForSide(side),
        ));
      } else if (desc is RemotePaneSource) {
        // Live reachability dot + latency on the header, matching the picker.
        final sess = ref.watch(activeSessionsProvider)[desc.sessionId];
        final connId = sess?.connectionId;
        final health =
            connId == null ? null : ref.watch(connectionHealthProvider)[connId];
        // A live session IS online even for an unmonitored host (see above).
        final online = sess?.status == SessionStatus.connected ||
            health?.status == ConnectionHealth.online;
        groups.add(RailGroup(
          label: Redactable.host(desc.hostLabel).displayIn(ref),
          paneSide: side,
          dotColor: online
              ? AppColors.v3Success
              : (health?.status == ConnectionHealth.offline
                  ? AppColors.v3Error
                  : AppColors.v3TextTertiary),
          latencyLabel: online && health?.latencyMs != null
              ? l10n.sftpLatencyMs(latencyText(health!.latencyMs))
              : null,
          onHeaderTap: (anchor) => _openSourcePickerForSide(side, anchor),
          onHeaderHover: (h) =>
              setState(() => _hoveredRailSide = h ? side : null),
          onEmptyAreaMenu: (pos) => _showBookmarkMenu(side, pos),
          onReorderPins: (o, n) => _reorderPins(side, o, n),
          items: _railItemsForSide(side),
        ));
      } else if (desc is FtpsPaneSource) {
        // An FTPS host (3.4): its header, online while its session is.
        final online = ref.watch(activeSessionsProvider)[desc.sessionId]?.status == SessionStatus.connected;
        groups.add(RailGroup(
          label: Redactable.host(desc.hostLabel).displayIn(ref),
          paneSide: side,
          dotColor: online ? AppColors.v3Success : AppColors.v3TextTertiary,
          onHeaderTap: (anchor) => _openSourcePickerForSide(side, anchor),
          onHeaderHover: (h) => setState(() => _hoveredRailSide = h ? side : null),
          onEmptyAreaMenu: (pos) => _showBookmarkMenu(side, pos),
          onReorderPins: (o, n) => _reorderPins(side, o, n),
          items: _railItemsForSide(side),
        ));
      } else {
        // Disconnected - still offer a header so the source can be changed.
        groups.add(RailGroup(
          label: desc is DisconnectedPaneSource
              ? _disconnectedLabel(desc)
              : desc.label,
          paneSide: side,
          sourceIcon: LucideIcons.serverOff,
          sourceIconColor: AppColors.error,
          onHeaderTap: (anchor) => _openSourcePickerForSide(side, anchor),
          onHeaderHover: (h) =>
              setState(() => _hoveredRailSide = h ? side : null),
          onEmptyAreaMenu: (pos) => _showBookmarkMenu(side, pos),
          items: const [],
        ));
      }
    }
    return groups;
  }

  /// Open the filterable source picker for [side], anchored under
  /// its rail header, and apply the choice: switch to This PC, swap to a
  /// connected session (instant), or connect to a saved host.
  Future<void> _openSourcePickerForSide(int side, Offset anchor) async {
    final desc = side == 0 ? _leftSource : _rightSource;
    final otherDesc = side == 0 ? _rightSource : _leftSource;
    final otherSessionId =
        otherDesc is RemotePaneSource ? otherDesc.sessionId : null;
    final currentSessionId =
        desc is RemotePaneSource ? desc.sessionId : null;

    final entries = ref.read(activeSftpSessionEntriesProvider);
    final sessions = ref.read(activeSessionsProvider);
    final health = ref.read(connectionHealthProvider);
    // Map connectionId -> its live SFTP session (with latency), so the picker
    // can render a saved host IN its group as connected + switch to it
    // instantly. The other pane's own session is excluded so it can't pick
    // itself.
    final l10n = AppLocalizations.of(context)!;
    final sftpByConnId = <String, SftpPickerConnected>{};
    for (final e in entries) {
      if (e.sessionId == otherSessionId) continue; // avoid picking-self
      final connId = sessions[e.sessionId]?.connectionId;
      if (connId == null) continue;
      final h = health[connId];
      final online = h?.status == ConnectionHealth.online;
      sftpByConnId[connId] = SftpPickerConnected(
        entry: e,
        latencyLabel: online && h?.latencyMs != null
            ? l10n.sftpLatencyMs(latencyText(h!.latencyMs))
            : null,
      );
    }
    // ALL saved hosts (folder-grouped in the picker); the map above marks which
    // are live.
    final saved = ref.read(connectionsWithDetailsProvider).valueOrNull ??
        const <ConnectionWithDetails>[];
    final groups =
        ref.read(connectionGroupsProvider).valueOrNull ?? const [];

    final choice = await showSftpSourcePicker(
      context,
      anchor: anchor,
      saved: saved,
      groups: groups,
      sftpByConnId: sftpByConnId,
      currentSessionId: currentSessionId,
      currentIsLocal: desc is LocalPaneSource,
    );
    if (choice == null || !mounted) return;
    final apply = side == 0 ? _onLeftSourceChanged : _onRightSourceChanged;
    switch (choice) {
      case SftpChooseLocal():
        apply(const LocalPaneSource());
      case SftpChooseSession(:final entry):
        apply(RemotePaneSource(
          sessionId: entry.sessionId,
          hostLabel: entry.label,
          service: entry.service,
        ));
      case SftpChooseConnect(:final connection):
        await _connectToConnection(side, connection);
    }
  }

  void _navigateSide(int side, String path) {
    (side == 0 ? _leftPaneKey : _rightPaneKey).currentState?.navigateTo(path);
  }

  /// The folder of a terminal said by the last miss while following, so that
  /// a host without the terminal's folders (a shell on another computer,
  /// reached with ssh from this one) is said once, not at every `cd`.
  String? _followMissed;

  /// Opens [request]'s folder, the terminal's (4.0, the dock's "Go to the
  /// terminal's folder" and "Follow the terminal"), in the pane that shows
  /// the session's host: the folder is looked up first, and where the host
  /// has no such folder that is said, the pane staying where it was.
  Future<void> _openTerminalFolder(TerminalFolderRequest request) async {
    final l10n = AppLocalizations.of(context)!;
    final sessionId = widget.initialSessionId;
    final hostLabel = widget.connectionLabel ?? '';
    final host = Redactable.host(hostLabel).displayIn(ref);
    final folder = Redactable.path(request.path).displayIn(ref);
    // The pane on the session's host: the one shown alone in the dock, or
    // whichever of two shows it now.
    int? side;
    for (final s in [1, 0]) {
      final desc = _sideOf(s).desc;
      final id = switch (desc) {
        RemotePaneSource(:final sessionId) => sessionId,
        FtpsPaneSource(:final sessionId) => sessionId,
        _ => null,
      };
      if (id != null && id == sessionId && (s == 1 || !widget.docked || widget.twoPanes)) {
        side = s;
        break;
      }
    }
    if (side == null) {
      if (!request.following) showTopSnackBar(context, l10n.sftpTerminalFolderNoPane(host), isWarning: true);
      return;
    }
    final pane = _sideOf(side);
    if (pane.key.currentState?.currentPath == request.path) {
      _followMissed = null;
      return;
    }
    // Asked of the SFTP service itself where there is one: the pane's own
    // stat says null for every remote path that has a mode (it reads a
    // getter SftpFileMode has not).
    var there = false;
    try {
      final desc = pane.desc;
      there = desc is RemotePaneSource
          ? (await desc.service.statOrNull(request.path))?.isDirectory ?? false
          : (await pane.fs.stat(request.path))?.isDirectory ?? false;
    } catch (_) {
      there = false;
    }
    if (!mounted) return;
    if (!there) {
      if (request.following && _followMissed != null) return;
      if (request.following) _followMissed = request.path;
      showTopSnackBar(context, l10n.sftpTerminalFolderMissing(folder, host), isWarning: true);
      return;
    }
    _followMissed = null;
    await pane.key.currentState?.navigateTo(request.path);
  }

  ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key})
      _sideOf(int side) {
    return side == 0
        ? (desc: _leftSource, fs: _leftFileSource, key: _leftPaneKey)
        : (desc: _rightSource, fs: _rightFileSource, key: _rightPaneKey);
  }

  /// Toolbar Upload/Download: push [entries] selected in [fromSide] to the
  /// other pane's current directory, reusing the same transfer pipeline a drag
  /// would. A non-drag path for keyboard users and touchpads.
  Future<void> _transferSelectionToOther(
      int fromSide, List<PaneFileEntry> entries) async {
    if (entries.isEmpty) return;
    final toSide = fromSide == 0 ? 1 : 0;
    final otherState = _sideOf(toSide).key.currentState;
    if (otherState == null) {
      // The other pane is a disconnected placeholder, not a live SftpPane.
      showTopSnackBar(
          context, AppLocalizations.of(context)!.sftpConnectOtherPaneFirst,
          isError: true);
      return;
    }
    await _onInterPaneDrop(
      PaneDragPayload(paneSide: fromSide, entries: entries),
      toSide,
      otherState.currentPath,
    );
  }

  /// "Open terminal here": cd a terminal on [side]'s remote host into [path].
  /// Prefers an existing live terminal for that host - the one the user has been
  /// using - and just sends it a `cd`, opening a fresh cd'd session only if none
  /// exists. Everything shows in-app via the WorkTab / active-session providers;
  /// the old code always spawned a duplicate session and pushed a full-screen
  /// `/terminal` route, which is why the shell "popped out" of the app.
  Future<void> _openTerminalHere(int side, String path) async {
    final desc = _sideOf(side).desc;
    if (desc is! RemotePaneSource) return;
    final sessions = ref.read(activeSessionsProvider);
    final connId = sessions[desc.sessionId]?.connectionId;
    final l10n = AppLocalizations.of(context)!;
    if (connId == null) {
      showTopSnackBar(context, l10n.sftpTerminalNoSession, isError: true);
      return;
    }
    // A folder's name is the server's to choose, and a control character in
    // it would act as a key on the way in ([CommandText.mayBeTyped]); a quote,
    // a backslash or an `&` in it ends POSIX quotes in the shell of a Windows
    // host or in fish ([CommandText.standsInAnyShell]). The row shows what is
    // there; so does what is told here.
    final cd = CommandText.cdInto(path);
    if (cd == null) {
      showTopSnackBar(
          context, CommandText.mayBeTyped(path) ? l10n.remoteNameNotInCommand : l10n.terminalNameNotTyped,
          isError: true, details: withHiddenCharactersShown(path));
      return;
    }
    final wt = ref.read(workTabsProvider.notifier);

    // Reuse an existing live terminal on this host, preferring one that already
    // has a tab (what the user last used); fall back to the first connected one.
    String? targetSid;
    for (final entry in sessions.entries) {
      final s = entry.value;
      if (s.connectionId != connId ||
          s.status != SessionStatus.connected ||
          s.session == null) {
        continue;
      }
      if (wt.tabContaining(entry.key) != null) {
        targetSid = entry.key;
        break;
      }
      targetSid ??= entry.key;
    }
    if (targetSid != null) {
      sessions[targetSid]!
          .session
          ?.shell
          .write(Uint8List.fromList(
              utf8.encode(CommandText.entered(cd))));
      wt.onSessionCreated(targetSid); // activate its WorkTab (no route push)
      ref.read(v3ActiveSessionTabProvider.notifier).state = targetSid;
      return;
    }

    // No terminal on this host yet: open one, cd'd, shown as an in-app tab.
    final connection = await ref.read(connectionsDaoProvider).getById(connId);
    if (!mounted) return;
    if (connection == null) {
      showTopSnackBar(context, l10n.sftpTerminalNoConnection, isError: true);
      return;
    }
    final sid = ref.read(activeSessionsProvider.notifier).startSession(
          connection,
          allowDuplicate: true,
          initialCommand: cd,
        );
    if (!mounted) return;
    if (sid == null) {
      showTopSnackBar(context, l10n.sftpSessionLimit, isError: true);
      return;
    }
    wt.onSessionCreated(sid); // open/focus its tab instead of pushing a route
    ref.read(v3ActiveSessionTabProvider.notifier).state = sid;
  }

  bool _mirrorInFlight = false;

  /// One-way mirror of [localRoot] (on [localSide], a local pane) up to the
  /// remote pane's current directory. Builds a plan behind a cancellable scan
  /// dialog, shows a preview of exactly what will be created/replaced (and,
  /// only if opted in, deleted), and only on confirm runs it through the
  /// Activity queue. Never two-way. Deletions the user opts into
  /// run LAST, only after every upload succeeded, and go through the same
  /// hold-with-undo window as a manual delete.
  Future<void> _mirrorFolderToOther(int localSide, String localRoot) async {
    final l10n = AppLocalizations.of(context)!;
    if (_mirrorInFlight) {
      showTopSnackBar(context, l10n.sftpSyncInProgress, isWarning: true);
      return;
    }
    final remoteSide = localSide == 0 ? 1 : 0;
    final other = _sideOf(remoteSide);
    final remoteDesc = other.desc;
    if (remoteDesc is! RemotePaneSource) {
      showTopSnackBar(context, l10n.sftpSyncNeedRemotePane, isError: true);
      return;
    }
    final remoteState = other.key.currentState;
    if (remoteState == null) {
      showTopSnackBar(context, l10n.sftpSyncRemoteNotReady, isError: true);
      return;
    }
    _mirrorInFlight = true;
    try {
      await _runMirror(
          localRoot, other, remoteDesc, remoteState.currentPath, l10n);
    } finally {
      _mirrorInFlight = false;
    }
  }

  Future<void> _runMirror(
    String localRoot,
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key})
        other,
    RemotePaneSource remoteDesc,
    String remoteRoot,
    AppLocalizations l10n,
  ) async {
    // Level-0 manifest (spec §4): device-local, best-effort. A closed DB
    // simply disables it. The key must be unique per SERVER and stable across
    // sessions (a display label is neither); the label is only the fallback
    // when the server identity is unknown, and the engine's level-0 guard
    // (the file must still exist remotely at the same size) means even a
    // shared key can never hide a missing or changed file.
    SftpSyncManifestDao? manifestDao;
    try {
      // Device-local records live in the Tree's database.
      manifestDao = ref.read(treeDatabaseProvider).sftpSyncManifestDao;
    } catch (_) {
      manifestDao = null;
    }
    final sync = SftpSyncService(
      remoteDesc.service,
      manifest: manifestDao,
      hostId: remoteDesc.serverId ?? remoteDesc.hostLabel,
    );

    // Per-pair memory: a folder pair last synced with Verify-by-content on
    // comes back on, so a rebuild-heavy deploy folder does not need the toggle
    // re-ticked; new pairs default to size+mtime. Device-local, per (server,
    // local root, remote root).
    final rememberedVerify =
        await sync.loadRememberedVerify(localRoot, remoteRoot);
    if (!mounted) return;
    // Plan first - read-only (directory listings only), no bytes moved. The
    // scan runs behind a cancellable progress dialog: one READDIR per folder
    // over a slow link takes seconds and must never look like a hang (spec 3).
    final baseOptions =
        SftpSyncOptions(recursive: true, verifyContent: rememberedVerify);
    var scanCancelled = false;
    // The app's own work-under-way dialog (the dialog rules, 3.4); its Stop
    // ends the scan, which then closes it.
    final scanning = ValueNotifier<String>(l10n.sftpSyncScanning(0));
    final closeScanning = showZestBusy(
      context,
      label: scanning.value,
      updates: scanning,
      cancel: (label: l10n.sftpSyncScanCancel, onPressed: () => scanCancelled = true),
    );

    SyncPlan planResult;
    try {
      planResult = await sync.buildPlan(
        localRoot: localRoot,
        remoteRoot: remoteRoot,
        options: baseOptions,
        shouldCancel: () => scanCancelled,
        onProgress: (n) => scanning.value = l10n.sftpSyncScanning(n),
      );
    } catch (e) {
      closeScanning();
      if (mounted) {
        showTopSnackBar(context, l10n.sftpSyncScanFailed,
            isError: true, details: e.toString());
      }
      return;
    }
    closeScanning();
    if (!mounted) return;
    // A cancelled scan changed nothing on the server; just stop.
    if (planResult.cancelled) return;
    // Spec 3: the walk stopped at the entry cap, so the plan is partial.
    // Running it would mistake un-walked files for "only on the server" and
    // offer to delete them, so refuse and say why.
    if (planResult.truncated) {
      showTopSnackBar(
        context,
        l10n.sftpSyncTooManyEntries(SftpSyncService.maxEntries),
        isError: true,
      );
      return;
    }

    final sourceLabel = p.basename(localRoot).isEmpty
        ? localRoot
        : p.basename(localRoot);
    // The preview is the dry run: closing it syncs nothing. Verify-by-content
    // and Force re-plan through onReplan so the counts always match the run.
    final choice = await SftpMirrorPreviewDialog.show(
      context,
      sourceLabel: sourceLabel,
      destPath: remoteRoot,
      initialPlan: planResult,
      initialOptions: baseOptions,
      verifyRemembered: rememberedVerify,
      onReplan: (opts) => sync.buildPlan(
        localRoot: localRoot,
        remoteRoot: remoteRoot,
        options: opts,
      ),
    );
    if (choice == null || !choice.run || !mounted) return;
    // A re-plan can hit the cap too; the dialog disables Run, this is the belt.
    if (choice.plan.truncated || choice.plan.cancelled) {
      showTopSnackBar(
        context,
        l10n.sftpSyncTooManyEntries(SftpSyncService.maxEntries),
        isError: true,
      );
      return;
    }
    // Remember this pair's Verify-by-content choice so the next sync of the
    // same folder pair defaults to it (device-local, best-effort).
    await sync.saveRememberedVerify(
        localRoot, remoteRoot, choice.options.verifyContent);

    final plan = choice.plan.items;
    // Deletes are never issued by the engine here: they are handed to the
    // hold manager afterwards, only if EVERY upload succeeded, so they get the
    // same Undo / Delete now window as a manual delete.
    final options = choice.options.copyWith(deleteRemoteOnly: false);
    final uploads =
        plan.where((it) => it.action == SyncAction.upload).toList();
    final deleteItems = choice.deleteRemoteOnly
        ? plan.where((it) => it.action == SyncAction.deleteRemote).toList()
        : const <SyncPlanItem>[];
    final opId = 'mirror_${DateTime.now().microsecondsSinceEpoch}';
    final op = TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.sync,
      title: l10n.sftpSyncOpTitle(sourceLabel),
      subtitle: l10n.sftpSyncOpSubtitle(remoteRoot),
      totalItems: uploads.length,
      status: TransferStatus.active,
    );
    _transfersNotifier.add(op);
    var cancelled = false;
    _transfersNotifier.registerCanceller(opId, () => cancelled = true);

    var done = 0;
    final summary = await sync.runSync(
      plan: plan,
      options: options,
      shouldCancel: () => cancelled,
      onItem: (item, i, total) {
        if (item.action == SyncAction.upload) {
          done++;
          op.processedItems = done;
          _transfersNotifier.touch();
        }
      },
    );

    _transfersNotifier.unregisterCanceller(opId);
    op.completedAt = DateTime.now();
    final attempted = uploads.length;
    if (summary.cancelled || cancelled) {
      op.status = TransferStatus.cancelled;
    } else if (summary.failed > 0) {
      // Each failure said for itself when it is one, with every one in the
      // report (it was the raw '<path>: <error>').
      op.failWithAll(
        [for (final f in summary.failures) (name: f.path, error: f.error)],
        several: l10n.sftpSyncFailedSummary(summary.failed, attempted),
        op: SftpOp.upload,
      );
    } else {
      op.status = TransferStatus.completed;
    }
    if (op.status == TransferStatus.completed ||
        op.status == TransferStatus.failed) {
      _notifyTransferBatch(
        failed: op.status == TransferStatus.failed,
        total: attempted,
        label: sourceLabel,
        detail: op.errorMessage,
        report: op.errorReport,
      );
    }
    _transfersNotifier.touchNow();
    if (!mounted) return;

    // Spec 5c: say ONCE that the server did not keep our timestamps. The
    // engine has already switched this folder to size comparison for future
    // runs, so the message is true, and Verify by content is the way to be
    // certain. Not shown for a cancelled run (the probe may not have run).
    if (summary.mtimeNotPreserved && !summary.cancelled) {
      showTopSnackBar(
        context,
        l10n.sftpMtimeNotPreserved,
        isWarning: true,
        duration: const Duration(seconds: 8),
      );
    }
    if (summary.unverified > 0) {
      showTopSnackBar(
        context,
        l10n.sftpSyncNotVerified(summary.unverified),
        isWarning: true,
        duration: const Duration(seconds: 8),
      );
    }

    // Opted-in deletions: only after EVERY upload landed and nothing was
    // cancelled (a renamed file is "upload new + delete old"; a failed upload
    // followed by the delete would leave the server with neither). Otherwise
    // say why nothing was removed.
    if (deleteItems.isNotEmpty) {
      if (summary.failed > 0 || summary.cancelled || cancelled) {
        showTopSnackBar(
          context,
          l10n.sftpSyncDeletesSkipped(deleteItems.length),
          isWarning: true,
          duration: const Duration(seconds: 8),
        );
      } else {
        _holdSyncDeletes(other, remoteDesc, deleteItems, l10n);
      }
    }
    final refreshed = other.key.currentState?.refresh();
    if (refreshed != null) unawaited(refreshed);
  }

  /// Hand a sync's opted-in remote deletions to the app-scoped hold manager,
  /// so they get the same countdown / Undo / Delete now as a manual delete and
  /// survive this screen being torn down (the manager owns the unlink loop).
  void _holdSyncDeletes(
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key})
        other,
    RemotePaneSource remoteDesc,
    List<SyncPlanItem> deleteItems,
    AppLocalizations l10n,
  ) {
    final targets = deleteItems
        .map((it) => SftpEntry(
              name: p.posix.basename(it.remotePath),
              path: it.remotePath,
              isDirectory: false,
              size: it.size,
              modifiedAt: null,
              permissions: '',
              isSymlink: false,
              modeBits: null,
            ))
        .toList();
    final holdSeconds = ref.read(sftpDeleteHoldSecondsProvider);
    final opId = 'del_${DateTime.now().microsecondsSinceEpoch}';
    final deadline = DateTime.now().add(Duration(seconds: holdSeconds));
    final op = TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.delete,
      title: targets.length == 1
          ? l10n.sftpDeletingOne(targets.first.name)
          : l10n.sftpDeletingMany(targets.length),
      subtitle: targets.first.path,
      status: TransferStatus.holding,
    )..holdUntil = deadline;
    _transfersNotifier.add(op);
    _holdManager.hold(
      DeleteHold(
        opId: opId,
        sessionId: remoteDesc.sessionId,
        hostLabel: remoteDesc.hostLabel,
        source: other.fs,
        targets: targets,
        deadline: deadline,
        connectionLostText: l10n.sftpDeleteConnectionLost,
        skippedText: l10n.sftpDeleteSkippedChanged,
        failedText: l10n.sftpDeleteItemsFailed,
        onRefresh: () {
          if (!mounted) return;
          final f = other.key.currentState?.refresh();
          if (f != null) unawaited(f);
        },
      ),
    );
    // Hold off = commit immediately (one code path for issuing unlinks).
    if (holdSeconds <= 0) unawaited(_holdManager.commitNow(opId));
  }

  /// Drop handler - called when entries are dragged from one pane and
  /// released over the other. Spawns a transfer for each entry,
  /// resolving overwrite conflicts up front so the user only gets
  /// prompted once per batch.
  Future<void> _onInterPaneDrop(
    PaneDragPayload payload,
    int destSide,
    String destPath,
  ) async {
    if (payload.paneSide == destSide) return; // dropped on self
    final src = _sideOf(payload.paneSide);
    final dst = _sideOf(destSide);
    final l10n = AppLocalizations.of(context)!;

    // ── PRE-TRANSFER CONFIRMATION ─────────────────────────────────
    //
    // Show a single "Transfer N items to X?" dialog before any byte
    // moves. This is the only thing standing between the user and
    // a 300-file accidental overwrite of their remote tree (e.g.
    // dragging a project root with node_modules / dist into the
    // wrong pane). It runs in addition to the per-conflict dialog
    // - the conflict dialog still pops if individual files collide
    // after the user has confirmed the batch.
    //
    // Skip the prompt for a single plain file with no destination
    // collision - that's the fast-path "small drag" case where an
    // extra modal would be annoying.
    final isSingleFile = payload.entries.length == 1 &&
        !payload.entries.first.isDirectory;
    var totalConflicts = 1;
    // Whether totalConflicts is the exact count of prompts to come. The scan
    // compares the whole tree with the destination, but a same-size file only
    // a content compare can settle, or a tree too big to compare in time,
    // leaves it a bound; the dialog then shows a running "Conflict N".
    var totalIsExact = true;
    // Paths the user pruned in the selection dialog (each a top-most excluded
    // subtree root). Stays empty for a single-file drag or an untouched confirm.
    Set<String> excluded = const {};
    if (!isSingleFile) {
      final scan = await _scanTransferTree(
        src.fs,
        dst.fs,
        payload.entries,
        destPath,
      );
      if (!mounted) return;
      final result = await TransferSelectionDialog.show(
        context,
        root: scan.root,
        destPath: destPath,
        verb: _bulkVerb(src.desc, dst.desc),
        conflictCount: scan.conflicts.length,
        conflictCountIsFloor: !scan.conflictsComplete || scan.truncated,
        truncated: scan.truncated,
      );
      if (result == null) return; // cancelled - nothing moved
      excluded = result;
      // Feed the conflicts outside the pruned subtrees into the "N of M"
      // counter the per-file conflict dialog shows. Exact only when the scan
      // compared the whole tree and no same-size file awaits a content
      // compare; otherwise the dialog shows "Conflict N".
      final counted = scan.conflictCountExcluding(excluded);
      if (counted > 0) totalConflicts = counted;
      totalIsExact = scan.isExactExcluding(excluded);
    }

    // Shared "apply to all" decision - a holder object (not a
    // bare nullable) so EVERY recursive _transferDirectory stack
    // frame sees mutations made by any deeper frame. The previous
    // by-value + callback approach only updated the root frame's
    // copy, so the user's "Apply to all" got forgotten the moment
    // the recursion popped back to a parent directory.
    final sticky = _StickyResolution()
      ..totalConflicts = totalConflicts
      ..totalIsExact = totalIsExact
      ..isBatch = !isSingleFile
      ..sourceVerb = _sourceVerb(src.desc, dst.desc, l10n)
      // This computer's disk takes `A` and `a` for one name on Windows and
      // macOS; a host is taken at its word.
      ..names = DropDestinationNames(
          caseInsensitive: dst.fs is LocalPaneFileSource && (Platform.isWindows || Platform.isMacOS));
    final destKey = dst.key;

    // ── Operation grouping ───────────────────────────────────────
    //
    // One drop = one transfer "operation". We generate an id + a
    // human label up front and tag every TransferItem that comes
    // out of this drop with it, so the transfer panel can collapse
    // all those rows under a single expandable parent row instead
    // of spamming the user with 300 individual progress bars.
    //
    // Label heuristic:
    //   * Dragged 1 entry  → use its name (folder name for dirs,
    //                        file name for files)
    //   * Dragged N>1 entries → "{N} items"
    final operationId = _uuid.v4();
    final String operationLabel = payload.entries.length == 1
        ? payload.entries.first.name
        : l10n.sftpItemCount(payload.entries.length);
    // What an "N items" row previews when collapsed: the names of the entries
    // that were dragged (less any pruned in the selection dialog). One list,
    // shared by every item of the drop. A single-entry drop needs none: its
    // label already names it.
    final List<String>? operationRoots = payload.entries.length > 1
        ? List.unmodifiable([
            for (final e in payload.entries)
              if (!excluded.contains(e.path)) e.name,
          ])
        : null;
    // The display root each child row's path is shown relative to. A single
    // dropped folder shows its files relative to INSIDE it (the operation row
    // already names the folder), e.g. `scripts/deploy.sh`. A multi-item drop
    // instead roots at the folder the items were dragged FROM (their shared
    // parent) so every row keeps its top-level folder name: `scripts/deploy.sh`
    // instead of a bare `deploy.sh` that loses which dropped folder it came
    // from (the operation label is only "N items"). Bare top-level files stay
    // bare, since their parent IS the root.
    final String? operationSourceRoot = payload.entries.isEmpty
        ? null
        : (payload.entries.length == 1 && payload.entries.first.isDirectory
            ? payload.entries.first.path
            : _dropParent(payload.entries.first.path));

    // Per-drop concurrency pool. The walk + prompt resolution runs
    // sequentially (it needs UI gates for the overwrite dialog), but
    // the actual byte-mover for each leaf file fans out via the pool
    // so we don't wait round-trip-per-file. concurrency=3 mirrors
    // WinSCP / FileZilla defaults - enough parallelism to hide
    // latency, conservative enough that the server doesn't trip on
    // open-file limits or rate limits.
    final pool = TransferPool(3);
    final inFlight = <Future<void>>[];

    for (final entry in payload.entries) {
      // A deeper frame (or a previous sibling) hit Cancel - stop the whole
      // drop, letting already-dispatched transfers settle below.
      if (sticky.cancelled || _cancelledOperations.contains(operationId)) break;
      // A top-level entry the user pruned in the selection dialog.
      if (excluded.contains(entry.path)) continue;
      // Recurse into directories: each leaf becomes its own transfer.
      if (entry.isDirectory) {
        // Materialize a directory at the destination then walk its
        // contents on the source side. We bail out cleanly if anything
        // fails - the partial files left behind are still correct.
        await _transferDirectory(
          src.fs,
          dst.fs,
          entry,
          destPath,
          sticky: sticky,
          operationId: operationId,
          operationLabel: operationLabel,
          operationRoots: operationRoots,
          operationSourceRoot: operationSourceRoot ?? entry.path,
          pool: pool,
          inFlight: inFlight,
          excluded: excluded,
        );
      } else {
        final safeName = _safeChild(entry.name);
        final destFile = dst.fs.join(destPath, safeName);
        // A place this drop gave to an earlier file already (two names of
        // the source that come to one here): no question about a file that
        // is this drop's own, it keeps both (DropDestinationNames).
        final destExists = !sticky.names.isTaken(destFile) && await dst.fs.exists(destFile);
        if (!mounted) return;
        final dstStat = destExists ? await dst.fs.stat(destFile) : null;
        if (!mounted) return;
        // Byte-identical: the destination already has this exact file, so
        // skip it WITHOUT prompting - and do this BEFORE reading any "apply to
        // all" resolution, so a re-sync (even one where the user chose
        // "overwrite all") never re-sends a file that has not changed. This is
        // what makes an "overwrite all" run behave as "send only what actually
        // changed". Same size + same mtime settles it cheaply (transfers carry
        // the mtime across); a same-size file whose mtime was re-stamped (a
        // rebuilt tree) is settled by hashing both ends. See _sameBytes.
        if (destExists &&
            dstStat != null &&
            await _sameBytes(src.fs, entry, dst.fs, dstStat)) {
          sticky.skippedUnchanged++;
          continue;
        }
        if (!mounted) return;
        // A sticky "apply to all" answer only ever applies to a REAL conflict.
        // A file with no destination is not a conflict: it must upload, never
        // be skipped by Skip-all, renamed by Keep-both-all, or falsely reported
        // as "older" by Replace-if-newer-all.
        OverwriteResolution? resolution = destExists ? sticky.value : null;
        if (resolution == null) {
          if (destExists) {
            sticky.seen += 1;
            resolution = await OverwriteConflictDialog.show(
              context,
              timeFormat: ref.read(sftpTimeFormatProvider),
              source: OverwriteFileInfo(
                path: entry.path,
                size: entry.size,
                modified: entry.modifiedAt,
              ),
              destination: OverwriteFileInfo(
                path: destFile,
                size: dstStat?.size,
                modified: dstStat?.modifiedAt,
              ),
              index: sticky.seen,
              total: sticky.totalConflicts,
              totalIsExact: sticky.totalIsExact,
              sourceVerb: sticky.sourceVerb,
              applyToAllEnabled: sticky.isBatch,
            );
            if (resolution.applyToAll) sticky.value = resolution;
            if (resolution.action == OverwriteAction.cancel) {
              // User bailed mid-batch - wait for already-dispatched
              // transfers to settle before returning so we don't leave
              // orphan futures running after the screen tears down.
              sticky.cancelled = true;
              await Future.wait(inFlight);
              // Even a cancelled batch must not swallow the files it skipped as
              // "older" before the cancel. [SFTP sync spec 1a]
              _reportSkippedOlder(operationId);
              return;
            }
          } else {
            resolution = const OverwriteResolution(OverwriteAction.overwrite);
          }
        }
        // Capture in locals so the closure binds the resolved values
        // and not the for-loop's mutating variables.
        final entryCaptured = entry;
        final resolutionCaptured = resolution;
        final destName = await _claimDestName(sticky, dst.fs, destPath, safeName, resolution);
        inFlight.add(pool.run(cancelled: () => _cancelledOperations.contains(operationId), () => _enqueueAndRun(
              src.fs,
              dst.fs,
              entryCaptured,
              destPath,
              resolution: resolutionCaptured,
              claimedName: destName,
              operationId: operationId,
              operationLabel: operationLabel,
              operationRoots: operationRoots,
              operationSourceRoot: operationSourceRoot,
            )));
      }
    }

    // Wait for every queued transfer to finish before refreshing the
    // destination pane - otherwise the user sees a partial listing
    // and has to manually refresh once everything settles.
    await Future.wait(inFlight);

    if (mounted) {
      final items = ref
          .read(sftpTransfersProvider)
          .where((t) => t.operationId == operationId)
          .toList();
      if (items.isNotEmpty) {
        final failed =
            items.where((t) => t.status == TransferStatus.failed).length;
        _notifyTransferBatch(
          failed: failed > 0,
          total: items.length,
          label: operationLabel,
          detail: failed > 0
              ? l10n.sftpSyncFailedSummary(failed, items.length)
              : null,
          report: failed > 0
              ? ErrorReport.build(
                  what: l10n.sftpSyncFailedSummary(failed, items.length),
                  where: 'Files: a drop',
                  // (What was thrown for each; a report names no file.)
                  details: [
                    for (final t in items)
                      if (t.status == TransferStatus.failed && t.failure != null) '${t.failure}',
                  ].join('\n'),
                )
              : null,
        );
      }
      // Files skipped because the destination already held the same bytes
      // are said out loud, never silent: a drop where everything was already
      // up to date used to end with no sign that anything had been checked.
      if (sticky.skippedUnchanged > 0) {
        showTopSnackBar(
          context,
          items.isEmpty
              ? l10n.sftpNothingToTransferUnchanged(sticky.skippedUnchanged)
              : l10n.sftpSkippedUnchanged(sticky.skippedUnchanged),
          isSuccess: items.isEmpty,
        );
      }
    }

    if (!mounted) return;
    // Refresh the destination pane so the new files are visible.
    destKey.currentState?.refresh();

    // Surface files that differed but were skipped by "replace only when local
    // is newer", with a one-click resend. Never silent. [SFTP sync spec 1a]
    _reportSkippedOlder(operationId);

    // What the host refused for want of permission: one Retry with sudo for
    // all of them (3.4).
    _offerSudoForDrop(src, dst, operationId);
  }

  /// The host (and its sudo) a transfer from [src] to [dst] would run as root
  /// on: the remote end of an upload or a download, the one host of a copy
  /// within it; null between two hosts or on this computer alone.
  ({SudoFileOps sudo, String host})? _sudoEnd(
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key}) src,
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key}) dst,
  ) {
    final srcRemote = src.fs is RemotePaneFileSource;
    final dstRemote = dst.fs is RemotePaneFileSource;
    if (!srcRemote && !dstRemote) return null;
    if (srcRemote && dstRemote && !src.fs.sharesBackendWith(dst.fs)) return null;
    final end = srcRemote ? src : dst;
    final desc = end.desc;
    final sudo = end.fs.sudoOps();
    if (sudo == null) return null;
    return (sudo: sudo, host: desc is RemotePaneSource ? desc.hostLabel : '');
  }

  /// Offers Retry with sudo for the files of drop [operationId] that the host
  /// refused for want of permission (3.4).
  void _offerSudoForDrop(
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key}) src,
    ({SftpPaneSource desc, PaneFileSource fs, GlobalKey<SftpPaneState> key}) dst,
    String operationId,
  ) {
    final end = _sudoEnd(src, dst);
    if (end == null || !mounted) return;
    final refused = [
      for (final t in ref.read(sftpTransfersProvider))
        if (t.operationId == operationId &&
            t.status == TransferStatus.failed &&
            t.failure != null &&
            isPermissionDenied(t.failure!))
          t,
    ];
    if (refused.isEmpty) return;
    offerSudoRetry(
      context,
      sudo: end.sudo,
      host: end.host,
      ops: [for (final t in refused) sudoOpForTransfer(src.fs, dst.fs, t)],
      shownPath: refused.first.remotePath,
      details: [for (final t in refused) '${t.failure}'].join('\n'),
      onDone: () {
        _leftPaneKey.currentState?.refresh();
        _rightPaneKey.currentState?.refresh();
      },
    );
  }


  /// Tell the user, once per operation, about files that DIFFERED but were
  /// skipped because the local copy was not newer under "replace only when
  /// local is newer", and offer a one-click resend of exactly those files.
  /// Silence here was the originally reported bug. [SFTP sync spec 1a]
  void _reportSkippedOlder(String? operationId) {
    if (operationId == null) return;
    final pending = _skippedOlder[operationId];
    if (pending == null || pending.isEmpty) return;
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(
      context,
      l10n.sftpSkippedOlder(pending.length),
      isWarning: true,
      duration: const Duration(seconds: 10),
      actionLabel: l10n.sftpSkippedOlderAction,
      onAction: () => _resendSkippedOlder(operationId),
    );
  }

  /// Re-run exactly the files recorded by [_reportSkippedOlder] as a forced
  /// overwrite: the user explicitly asked to send them despite the older
  /// timestamp. Consumes the list so a second tap is a no-op. [SFTP sync 1a]
  Future<void> _resendSkippedOlder(String operationId) async {
    final pending = _skippedOlder.remove(operationId);
    if (pending == null || pending.isEmpty) return;
    for (final s in pending) {
      await _enqueueAndRun(
        s.src,
        s.dst,
        s.entry,
        s.destDir,
        resolution: const OverwriteResolution(OverwriteAction.overwrite),
        operationId: operationId,
        operationLabel: s.operationLabel,
        operationRoots: s.operationRoots,
      );
    }
    if (!mounted) return;
    _leftPaneKey.currentState?.refresh();
    _rightPaneKey.currentState?.refresh();
  }

  /// The SFTP operation [item] is, for what is said about its failure.
  static SftpOp _sftpOpOf(TransferItem item) =>
      item.direction == TransferDirection.upload ? SftpOp.upload : SftpOp.download;

  /// One notification per finished transfer operation (a drop or a sync),
  /// never per file. Gated by the user's Transfer complete / Transfer failed
  /// notification toggles.
  void _notifyTransferBatch({
    required bool failed,
    required int total,
    String? label,
    String? detail,
    String? report,
  }) {
    // The run that reports here may outlive the screen (a long sync, the
    // user closes the SFTP view): ref after dispose throws.
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final center = ref.read(notificationCenterProvider.notifier);
    if (failed) {
      if (ref.read(notifyTransferFailedProvider)) {
        center.error(l10n.notifPrefsTransferFailed,
            body: detail ?? label ?? l10n.sftpNFiles(total), details: report);
      }
    } else {
      if (ref.read(notifyTransferCompleteProvider)) {
        center.success(l10n.notifPrefsTransferComplete,
            body: label != null
                ? l10n.sftpTransferDoneWhat(label, l10n.sftpNFiles(total))
                : l10n.sftpNFiles(total));
      }
    }
  }

  /// Walk the source recursively and produce totals for the
  /// pre-transfer confirmation dialog.
  ///
  /// Capped at [_summaryWalkLimit] recursive descents so a pathological
  /// source (think `/` or a million-file tree) doesn't freeze the UI
  /// for seconds before the dialog appears. When the cap is hit we
  /// still show the dialog with the partial count + a "+ more" feel
  /// (the user still gets to cancel).
  static const int _summaryWalkLimit = 5000;

  /// Walk the source and compare it with the destination for the selection
  /// dialog and the conflict counter (see [scanTransferTree]).
  Future<TransferScan> _scanTransferTree(
    PaneFileSource src,
    PaneFileSource dst,
    List<PaneFileEntry> roots,
    String destPath,
  ) =>
      scanTransferTree(
        src: src,
        dst: dst,
        roots: roots,
        destPath: destPath,
        safeChild: _safeChild,
        walkLimit: _summaryWalkLimit,
      );

  /// The pre-transfer dialog's action (its title + button read "Upload N
  /// items" / "Download N items" / "Copy N items").
  TransferVerb _bulkVerb(SftpPaneSource src, SftpPaneSource dst) {
    final fromLocal = src is LocalPaneSource;
    final toLocal = dst is LocalPaneSource;
    if (fromLocal && !toLocal) return TransferVerb.upload;
    if (!fromLocal && toLocal) return TransferVerb.download;
    return TransferVerb.copy;
  }

  /// Gerund form for the conflict dialog's source row ("Uploading" etc.).
  String _sourceVerb(
      SftpPaneSource src, SftpPaneSource dst, AppLocalizations l10n) {
    final fromLocal = src is LocalPaneSource;
    final toLocal = dst is LocalPaneSource;
    if (fromLocal && !toLocal) return l10n.sftpVerbUploading;
    if (!fromLocal && toLocal) return l10n.sftpVerbDownloading;
    return l10n.sftpVerbCopying;
  }

  /// Recursive directory transfer. Creates the destination directory
  /// then walks the source recursively, dispatching one file transfer
  /// per leaf and creating intermediate directories on demand.
  ///
  /// [operationId] / [operationLabel] / [operationSourceRoot] thread
  /// through to every child's [TransferItem] so the queue panel can
  /// group all files from one directory drop under a single
  /// expandable parent row.
  ///
  /// [pool] / [inFlight] are the per-drop concurrency limiter and the
  /// shared list of in-flight futures. The walk itself stays
  /// sequential (it needs to await listings + overwrite prompts),
  /// but individual file transfers are dispatched through the pool
  /// so up to N=3 run in parallel - masking SFTP round-trip latency
  /// on small files.
  ///
  /// [stickyResolution] is a shared MUTABLE holder, not a value
  /// parameter. The previous version passed it by value + funneled
  /// updates back through `onResolutionApplied(...)`, which broke
  /// "Apply to all remaining conflicts" for any tree deeper than two
  /// levels: a parent stack frame's local copy never saw the update,
  /// so when the recursion returned and the parent kept iterating
  /// siblings it would re-prompt with a fresh dialog. The holder
  /// pattern fixes that - every stack frame reads/writes the same
  /// box, so once the user ticks "Apply to all" once it sticks for
  /// the rest of the drop.
  Future<void> _transferDirectory(
    PaneFileSource src,
    PaneFileSource dst,
    PaneFileEntry srcDirEntry,
    String destParent, {
    required _StickyResolution sticky,
    String? operationId,
    String? operationLabel,
    List<String>? operationRoots,
    String? operationSourceRoot,
    TransferPool? pool,
    List<Future<void>>? inFlight,
    Set<String>? excluded,
    int depth = 0,
    Set<String>? visitedSourcePaths,
  }) async {
    // Depth + cycle guard. A malicious or misconfigured server can report a
    // directory tree that is arbitrarily deep, or one whose listings loop back
    // on themselves (a hard-linked/bind-mounted directory readdir'd under two
    // names) - either recurses until the stack blows or the drop never ends.
    // Cap the depth at the same limit the recursive-delete path uses, and
    // refuse to descend into a source path already visited in this drop.
    if (depth > SftpService.maxRecursionDepth) {
      if (!mounted) return;
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!
            .sftpCopyTooDeep(srcDirEntry.name, SftpService.maxRecursionDepth),
        isError: true,
      );
      return;
    }
    final visited = visitedSourcePaths ?? <String>{};
    if (!visited.add(srcDirEntry.path)) {
      // Already walked this exact source path in this drop → a cycle.
      AppLogger.info(
          'SFTP recursive copy: skipping already-visited ${srcDirEntry.path}');
      return;
    }
    final destDir = dst.join(destParent, _safeChild(srcDirEntry.name));
    // Whether the destination directory already existed. When WE just created
    // it, nothing inside it can exist yet, so the per-child overwrite check
    // below is skipped: that check is a remote STAT round-trip per file, and on
    // a fresh upload of a large tree it was thousands of sequential round-trips
    // that could never find a conflict.
    final bool destDirExisted;
    try {
      destDirExisted = await dst.exists(destDir);
      if (!destDirExisted) {
        await dst.mkdir(destDir, recursive: true);
      }
    } catch (e) {
      if (!mounted) return;
      // Refused for want of permission: Retry with sudo puts the whole
      // folder there as root (3.4).
      final asRoot = isPermissionDenied(e) ? sudoOpsForFolder(src, dst, srcDirEntry.path, destDir, excluded ?? const {}) : null;
      final sudo = asRoot == null
          ? null
          : (src is RemotePaneFileSource ? src : dst).sudoOps();
      if (asRoot != null && sudo != null) {
        final desc = identical(dst, _leftFileSource) ? _leftSource : _rightSource;
        final srcDesc = identical(src, _leftFileSource) ? _leftSource : _rightSource;
        final hostDesc = dst is RemotePaneFileSource ? desc : srcDesc;
        offerSudoRetry(
          context,
          sudo: sudo,
          host: hostDesc is RemotePaneSource ? hostDesc.hostLabel : '',
          ops: asRoot,
          shownPath: destDir,
          details: e.toString(),
          onDone: () {
            _leftPaneKey.currentState?.refresh();
            _rightPaneKey.currentState?.refresh();
          },
        );
        return;
      }
      showTopSnackBar(
          context,
          sftpErrorMessage(e, name: p.basename(destDir), op: SftpOp.mkdir),
          isError: true, details: e.toString());
      return;
    }

    List<PaneFileEntry> children;
    try {
      children = await src.list(srcDirEntry.path);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(
          context,
          sftpErrorMessage(e, name: srcDirEntry.name, op: SftpOp.list),
          isError: true, details: e.toString());
      return;
    }

    for (final child in children) {
      // Cancel propagates up the recursion: once any frame sets it, every
      // frame stops walking so the drop ends instead of prompting the next
      // sibling. Already-dispatched leaf transfers are awaited at the top.
      if (sticky.cancelled || (operationId != null && _cancelledOperations.contains(operationId))) return;
      // Honor the pre-transfer selection: skip any subtree the user pruned in
      // the selection dialog. Each excluded entry is a top-most pruned root, so
      // an exact-path match is enough - we never recurse into a pruned folder.
      if (excluded != null && excluded.contains(child.path)) continue;
      // Never descend through a symbolic link during a recursive copy.
      // Following one can walk out of the tree the user selected (a link
      // to `/` copies the whole remote filesystem) or loop forever if the
      // link points back at an ancestor. A link to a plain FILE still
      // transfers normally below - opening it follows the link, which is
      // what scp does and what users expect - so only the directory case
      // is skipped, and cleanly rather than as an "open failed" error.
      if (child.isSymlink) {
        final linkTarget = await src.stat(child.path);
        if (linkTarget == null || linkTarget.isDirectory) {
          AppLogger.info(
              'SFTP recursive copy: skipping symlinked directory '
              '${child.path}');
          continue;
        }
      }
      if (child.isDirectory) {
        await _transferDirectory(
          src,
          dst,
          child,
          destDir,
          sticky: sticky,
          operationId: operationId,
          operationLabel: operationLabel,
          operationRoots: operationRoots,
          operationSourceRoot: operationSourceRoot,
          pool: pool,
          inFlight: inFlight,
          excluded: excluded,
          depth: depth + 1,
          visitedSourcePaths: visited,
        );
      } else {
        final safeName = _safeChild(child.name);
        final destFile = dst.join(destDir, safeName);
        // A freshly-created destDir cannot contain destFile: skip the STAT.
        // Nor is a place this drop gave to an earlier file asked about: the
        // file keeps both (DropDestinationNames).
        final destExists = destDirExisted && !sticky.names.isTaken(destFile) && await dst.exists(destFile);
        if (!mounted) return;
        final dstStat = destExists ? await dst.stat(destFile) : null;
        if (!mounted) return;
        // Byte-identical => skip silently, BEFORE reading any "apply to all"
        // resolution, so a re-sync (even "overwrite all") never re-sends an
        // unchanged file (same rationale as the top-level path, including the
        // content compare for a re-stamped same-size file). See _sameBytes.
        if (destExists &&
            dstStat != null &&
            await _sameBytes(src, child, dst, dstStat)) {
          sticky.skippedUnchanged++;
          continue;
        }
        if (!mounted) return;
        // Re-read the holder on every iteration - a recursive
        // descent may have set it since the previous round.
        // A sticky "apply to all" answer only ever applies to a REAL conflict.
        // A file with no destination is not a conflict: it must upload, never
        // be skipped by Skip-all, renamed by Keep-both-all, or falsely reported
        // as "older" by Replace-if-newer-all.
        OverwriteResolution? resolution = destExists ? sticky.value : null;
        if (resolution == null) {
          if (destExists) {
            sticky.seen += 1;
            resolution = await OverwriteConflictDialog.show(
              context,
              timeFormat: ref.read(sftpTimeFormatProvider),
              source: OverwriteFileInfo(
                path: child.path,
                size: child.size,
                modified: child.modifiedAt,
              ),
              destination: OverwriteFileInfo(
                path: destFile,
                size: dstStat?.size,
                modified: dstStat?.modifiedAt,
              ),
              index: sticky.seen,
              total: sticky.totalConflicts,
              totalIsExact: sticky.totalIsExact,
              sourceVerb: sticky.sourceVerb,
              applyToAllEnabled: sticky.isBatch,
            );
            if (resolution.applyToAll) {
              // Visible to every ancestor + sibling frame now.
              sticky.value = resolution;
            }
            if (resolution.action == OverwriteAction.cancel) {
              // Signal every other frame to stop, then unwind this one.
              sticky.cancelled = true;
              return;
            }
          } else {
            resolution = const OverwriteResolution(OverwriteAction.overwrite);
          }
        }
        // Dispatch through the pool when one is provided (drop flow
        // wires this through); fall back to a synchronous await when
        // called from a non-pooled path. Local captures bind the
        // for-loop variables so the closure doesn't see them mutate.
        final childCaptured = child;
        final resolutionCaptured = resolution;
        final destName = await _claimDestName(sticky, dst, destDir, safeName, resolution);
        if (pool != null && inFlight != null) {
          inFlight.add(pool.run(
              cancelled: () => operationId != null && _cancelledOperations.contains(operationId), () => _enqueueAndRun(
                src,
                dst,
                childCaptured,
                destDir,
                resolution: resolutionCaptured,
                claimedName: destName,
                operationId: operationId,
                operationLabel: operationLabel,
                operationRoots: operationRoots,
                operationSourceRoot: operationSourceRoot,
              )));
        } else {
          await _enqueueAndRun(
            src,
            dst,
            childCaptured,
            destDir,
            resolution: resolutionCaptured,
            claimedName: destName,
            operationId: operationId,
            operationLabel: operationLabel,
            operationRoots: operationRoots,
            operationSourceRoot: operationSourceRoot,
          );
        }
      }
    }
  }

  /// Reduce a directory-entry name to one safe path component before it is
  /// joined onto a destination path.
  ///
  /// Delegates to the shared, unit-tested [safeChildName], which also covers
  /// the cases this local copy missed: NTFS alternate data streams
  /// (`notes.txt:hidden`), Win32 reserved device names (`CON`, `NUL`,
  /// `COM1`), trailing dots/spaces that Win32 silently strips (letting
  /// "evil " and "evil" collide past an overwrite check), unicode direction
  /// overrides that spoof the displayed extension, and unbounded length.
  String _safeChild(String name) {
    final safe = safeChildName(name);
    // Belt-and-suspenders (defense-in-depth): safeChildName already guarantees a
    // single leaf with no separators or `.`/`..`, but re-assert the invariant
    // here so a future regression in it can never let a joined destination
    // escape the target dir. Fail CLOSED to a constant safe leaf rather than
    // throwing into a transfer. This branch is unreachable today.
    if (safe.isEmpty ||
        safe == '.' ||
        safe == '..' ||
        safe.contains('/') ||
        safe.contains('\\')) {
      return 'unsafe_name';
    }
    return safe;
  }

  /// Apply the overwrite resolution to a single transfer and dispatch
  /// it. The actual byte-mover lives in [_runTransfer].
  /// Parent directory of [path], preserving the original separators (local `\`
  /// or remote `/`). Used as the display root for a multi-item drop so each row
  /// keeps its top-level folder name. Returns null when [path] has no
  /// separator; '/' when the parent is the filesystem root.
  String? _dropParent(String path) {
    final norm = path.replaceAll('\\', '/');
    final i = norm.lastIndexOf('/');
    if (i < 0) return null;
    if (i == 0) return '/';
    // norm is the same length as path (each '\' maps to one '/'), so the index
    // is valid in the original string and keeps its native separators.
    return path.substring(0, i);
  }

  /// The name a file of a drop is written to in [destDir]: [safeName], or a
  /// name of its own where the drop gave that place to an earlier file, or
  /// where the person chose Keep both. Asked for in the walk, one file after
  /// the other, since the files themselves are written three at a time. Null
  /// for a file that is not written (skipped).
  Future<String?> _claimDestName(
    _StickyResolution sticky,
    PaneFileSource dst,
    String destDir,
    String safeName,
    OverwriteResolution resolution,
  ) async {
    if (resolution.action == OverwriteAction.skip || resolution.action == OverwriteAction.cancel) return null;
    return sticky.names.claim(
      destDir,
      safeName,
      join: dst.join,
      exists: dst.exists,
      keepBoth: resolution.action == OverwriteAction.rename,
    );
  }

  Future<void> _enqueueAndRun(
    PaneFileSource src,
    PaneFileSource dst,
    PaneFileEntry srcEntry,
    String destDir, {
    required OverwriteResolution resolution,
    // The name the drop's walk claimed for it ([_claimDestName]); without
    // one (a retry, a file sent again) the file's own name.
    String? claimedName,
    String? operationId,
    String? operationLabel,
    List<String>? operationRoots,
    String? operationSourceRoot,
  }) async {
    // Its drop was cancelled while it waited its turn: nothing of it starts.
    if (operationId != null && _cancelledOperations.contains(operationId)) return;
    // Sanitize the server-supplied leaf to a single safe component before
    // joining it onto a (possibly LOCAL) destination - otherwise a
    // malicious/compromised SFTP server could return an absolute name
    // (which package:path's join treats as the whole path) or "../.." and
    // write outside the destination directory. See _safeChild.
    var destName = claimedName ?? _safeChild(srcEntry.name);
    final destFileInitial = dst.join(destDir, destName);

    switch (resolution.action) {
      case OverwriteAction.skip:
        return;
      case OverwriteAction.cancel:
        return;
      case OverwriteAction.newer:
        final dstStat = await dst.stat(destFileInitial);
        // Skip unless source is strictly newer than destination.
        final srcModified = srcEntry.modifiedAt;
        final dstModified = dstStat?.modifiedAt;
        if (srcModified == null ||
            dstModified == null ||
            !srcModified.isAfter(dstModified)) {
          // Byte-identical files were already skipped before dispatch, so
          // reaching here means this file DIFFERS but the local copy is not
          // newer. Under "replace only when local is newer" we do not
          // overwrite - but we must NEVER do that silently (silent skipping of
          // changed files was the reported bug). Record it so the operation can
          // report the count and offer a one-click "send them anyway". [1a]
          if (operationId != null) {
            (_skippedOlder[operationId] ??= <_SkippedOlder>[]).add(
              _SkippedOlder(
                src: src,
                dst: dst,
                entry: srcEntry,
                destDir: destDir,
                operationLabel: operationLabel,
                operationRoots: operationRoots,
              ),
            );
          }
          return;
        }
      case OverwriteAction.rename:
        // Find a non-conflicting name like "foo (1).txt" (a drop's walk has
        // claimed one already).
        if (claimedName == null) {
          destName = await uniqueRenameFor(
            destName,
            exists: (candidate) => dst.exists(dst.join(destDir, candidate)),
          );
        }
      case OverwriteAction.overwrite:
        // Default - fall through.
        break;
    }

    final destPath = dst.join(destDir, destName);
    final id = _uuid.v4();
    // Record exactly which panes this transfer runs between, so Retry can
    // re-run it against the same source/destination instead of guessing from
    // direction (which is ambiguous for local→local and remote→remote).
    final srcSide = identical(src, _leftFileSource) ? 0 : 1;
    final dstSide = identical(dst, _leftFileSource) ? 0 : 1;
    final item = TransferItem(
      id: id,
      localPath: srcEntry.path,
      remotePath: destPath,
      fileName: srcEntry.name,
      // Toward a host (SFTP or FTPS) is an upload.
      direction: dst is! LocalPaneFileSource
          ? TransferDirection.upload
          : TransferDirection.download,
      totalBytes: srcEntry.size,
      status: TransferStatus.active,
      srcSide: srcSide,
      dstSide: dstSide,
      srcSourceId: src.sourceId,
      dstSourceId: dst.sourceId,
      operationId: operationId,
      operationLabel: operationLabel,
      operationRoots: operationRoots,
      operationSourceRoot: operationSourceRoot,
    );
    _transfersNotifier.add(item);
    final cancelToken = TransferCancelToken();
    _cancelTokens[id] = cancelToken;

    // NOTE: we deliberately do NOT bail on `!mounted` for the
    // status / progress writes any more. Mutating the item + calling
    // `notifier.touch()` is safe even after this State is gone - the
    // transfer keeps running in the background pool and updates the
    // queue panel wherever it's currently rendered.
    try {
      await _runTransfer(src, dst, srcEntry.path, destPath, item, cancelToken);
      item.status = TransferStatus.completed;
      item.completedAt = DateTime.now();
      _transfersNotifier.touchNow();
    } catch (e, stack) {
      if (_cancelled[id] == true || cancelToken.isCancelled) {
        item.status = TransferStatus.cancelled;
      } else {
        // Why, in the app's language, with its report (it was the raw error).
        item.failWith(e, stack: stack, op: _sftpOpOf(item));
      }
      _transfersNotifier.touchNow();
    } finally {
      _cancelled.remove(id);
      _cancelTokens.remove(id);
    }
  }

  /// Move bytes from [srcPath] on [src] to [destPath] on [dst]. Picks
  /// the fastest path available for each combination. Throws on cancel.
  Future<void> _runTransfer(
    PaneFileSource src,
    PaneFileSource dst,
    String srcPath,
    String destPath,
    TransferItem item,
    TransferCancelToken cancelToken,
  ) async {
    // Throttle the UI-facing rebuilds. Several service transfer paths fire
    // onProgress per chunk (every 16-128 KB), and each touch() rebuilds the
    // WHOLE Activity queue on the UI isolate - so per-chunk touches saturate
    // the isolate and freeze the ENTIRE app during a large/fast transfer.
    // This is the single choke point every transfer flows through, so
    // throttling here fixes it regardless of which service path is used
    // (the download path in particular fires unthrottled). We still record
    // every byte on the item so the data stays current; we just rebuild the
    // UI at most ~15x/sec. The caller does a final touch() on completion so
    // the last frame always lands on the true final byte count.
    var lastTouchMs = 0;
    void progress(int transferred, int total) {
      // Throw a cancellation if the user pressed Cancel mid-flight. The
      // transfer mechanics don't natively support cancellation, so we
      // surface it as an exception which the surrounding catch turns
      // into TransferStatus.cancelled. Checked EVERY call so Cancel stays
      // instant even though the UI touch below is throttled.
      if (_cancelled[item.id] == true) {
        throw const _CancelledException();
      }
      item.transferredBytes = transferred;
      if (total > 0) item.totalBytes = total;
      // No `!mounted` bail - progress writes go to the global transfers
      // provider, so the UI updates wherever the queue panel is currently
      // mounted (and the data survives this State going away mid-transfer).
      final nowMs = DateTime.now().millisecondsSinceEpoch;
      if (nowMs - lastTouchMs >= 66) {
        lastTouchMs = nowMs;
        _transfersNotifier.touch();
      }
    }

    final srcIsLocal = src is LocalPaneFileSource;
    final dstIsLocal = dst is LocalPaneFileSource;

    if (srcIsLocal && dstIsLocal) {
      // Local → Local: native file copy is fastest. No SFTP channel involved,
      // so there is nothing to route off the interactive channel here.
      await dst.uploadFile(srcPath, destPath,
          onProgress: progress, cancelToken: cancelToken);
    } else if (srcIsLocal && !dstIsLocal) {
      // Local → Remote (upload). bulk:true runs the byte stream on the remote's
      // dedicated transfer channel so it can't freeze interactive browsing.
      await dst.uploadFile(srcPath, destPath,
          onProgress: progress, cancelToken: cancelToken, bulk: true);
    } else if (!srcIsLocal && dstIsLocal) {
      // Remote → Local (download). bulk:true, same reasoning as the upload.
      await src.downloadFile(srcPath, destPath,
          onProgress: progress, cancelToken: cancelToken, bulk: true);
    } else if (src is! RemotePaneFileSource || dst is! RemotePaneFileSource) {
      // Between hosts of which one at least is FTPS (3.4): FTP has no copy on
      // the server, so through a file on this device, as two SFTP hosts are.
      await _bridgedThroughHere(src, dst, srcPath, destPath, progress, cancelToken);
    } else if (src.sharesBackendWith(dst)) {
      // Same-host remote → remote: pipe through the one channel.
      await _remoteToRemoteSameHost(
        src,
        srcPath,
        destPath,
        progress,
      );
    } else {
      // Remote↔Remote, different hosts - bridge through a local temp file.
      await _remoteToRemoteBridged(
        src,
        dst,
        srcPath,
        destPath,
        progress,
      );
    }

    // Verify-after-transfer: checksum both ends and record the verdict on the
    // item. Best-effort and non-fatal - the transfer already succeeded; this
    // just confirms (or flags) integrity. Skipped for large files and the
    // local↔local / remote↔remote cases (see _maybeVerifyTransfer).
    await _maybeVerifyTransfer(src, dst, srcPath, destPath, item);
  }

  /// Largest transfer we'll checksum. A server-side `sha256sum` reads the whole
  /// file, so verifying a multi-GB transfer would add minutes - cap it.
  static const int _maxVerifyBytes = 256 * 1024 * 1024; // 256 MB

  /// Smallest transfer we'll checksum. Verify costs a full SSH exec channel
  /// (open, `sha256sum` process spawn on the server, read, close = ~6 packets
  /// and several round-trips) plus a local hash - PER FILE. For a folder of
  /// thousands of tiny files that was thousands of server process spawns and
  /// the single largest source of per-file overhead. Integrity is already
  /// guaranteed below this size by the AEAD transport (no undetected
  /// corruption in transit) and the .zestpart size-verify-then-rename staging;
  /// a checksum only earns its exec channel on a file large enough to matter.
  static const int _minVerifyBytes = 4 * 1024 * 1024; // 4 MB

  /// Checksum both ends of a completed byte transfer and stamp the result on
  /// [item]. Only meaningful for an upload or a download (one local + one
  /// remote end); local↔local is a trusted native copy and remote↔remote would
  /// need two server hashes, so both are skipped.
  Future<void> _maybeVerifyTransfer(
    PaneFileSource src,
    PaneFileSource dst,
    String srcPath,
    String destPath,
    TransferItem item,
  ) async {
    final size = item.totalBytes;
    if (size < _minVerifyBytes || size > _maxVerifyBytes) return;
    final srcLocal = src is LocalPaneFileSource;
    final dstLocal = dst is LocalPaneFileSource;
    if (srcLocal == dstLocal) return; // local↔local or remote↔remote

    String? srcHash;
    String? dstHash;
    try {
      // The host's SHA-256: sha256sum over SSH for SFTP, HASH or XSHA256 for
      // an FTPS server that has one ([_sha256On]).
      if (srcLocal) {
        srcHash = await _sha256Local(srcPath);
        dstHash = await _sha256On(dst, destPath);
      } else {
        srcHash = await _sha256On(src, srcPath);
        dstHash = await _sha256Local(destPath);
      }
    } catch (_) {
      // Leave it unverified rather than crash a finished transfer.
    }

    if (srcHash == null || dstHash == null) {
      item.verify = SftpVerifyResult.unavailable;
    } else if (srcHash == dstHash) {
      item.verify = SftpVerifyResult.ok;
    } else {
      item.verify = SftpVerifyResult.mismatch;
      AppLogger.warning(
          'SFTP verify: checksum mismatch for ${item.fileName} '
          '(src $srcHash != dst $dstHash)');
    }
    _transfersNotifier.touch();
  }

  /// Whether [entry] (on [src]) and the existing destination file [dstStat]
  /// (on [dst]) already hold the same bytes, so "Replace changed files" skips
  /// the transfer without a prompt. Size and mtime settle it cheaply; the
  /// same-size-different-mtime case (every file of a rebuilt `build/` tree,
  /// an unzip, a `cp` without `-p`, a server that refused SETSTAT) is settled
  /// by hashing both ends: a server-side `sha256sum` for a remote file, a
  /// streaming sha256 on a helper isolate for a local one. Any doubt answers
  /// "changed", so the file is transferred. This is what rsync's checksum
  /// pass does for the same situation; without it the user re-sends a whole
  /// tree of unchanged installers every time the build re-stamps them.
  Future<bool> _sameBytes(
    PaneFileSource src,
    PaneFileEntry entry,
    PaneFileSource dst,
    PaneFileEntry dstStat,
  ) {
    if (dstStat.isDirectory || entry.isDirectory) return Future.value(false);
    return kSftpSyncCompare.isSameContent(
      localSize: entry.size,
      localMtime: entry.modifiedAt,
      remoteSize: dstStat.size,
      remoteMtime: dstStat.modifiedAt,
      hashLocal: () => _sha256On(src, entry.path),
      hashRemote: () => _sha256On(dst, dstStat.path),
    );
  }

  /// SHA-256 of [path] on whichever side [fs] is; null when it cannot be had.
  Future<String?> _sha256On(PaneFileSource fs, String path) {
    if (fs is RemotePaneFileSource) return fs.service.sha256Remote(path);
    if (fs is FtpsPaneFileSource) return fs.sha256(path);
    if (fs is LocalPaneFileSource) return _sha256Local(path);
    return Future.value(null);
  }

  /// SHA-256 of a local file, streamed so a large file never lands in memory.
  /// Hashes on a helper isolate. Dart's sha256 runs at roughly 150 MB/s, so a
  /// 100 MB file (node_modules is full of them) is ~0.7 s of pure CPU that
  /// must not land on the UI isolate; the old version streamed the file
  /// through sha256 on the main isolate.
  Future<String?> _sha256Local(String path) async {
    try {
      return await Isolate.run(() => _sha256FileHex(path));
    } catch (_) {
      return null;
    }
  }

  /// Same-host remote→remote copy. Reads the source remote file in
  /// chunks and writes to the destination in the same SFTP channel.
  /// Avoids the local-disk round trip.
  Future<void> _remoteToRemoteSameHost(
    RemotePaneFileSource src,
    String srcPath,
    String destPath,
    PaneTransferProgress progress,
  ) async {
    // SftpService doesn't currently expose a streaming server-side
    // copy. Rather than carve a new method now (and risk subtle bugs
    // in a hot path), bridge via a local temp file. The data still
    // moves locally, but only once - and the user-visible result is
    // identical. Future optimisation: open both SftpFile handles on
    // the same SftpClient and pipe between them.
    final tmp = await Directory.systemTemp.createTemp('zest_sftp_xfer_');
    final tmpPath = p.join(tmp.path, 'xfer.bin');
    try {
      await src.service.downloadFileToPath(
        srcPath,
        tmpPath,
        onProgress: (sent, total) => progress(sent ~/ 2, total),
        useTransferChannel: true,
      );
      await src.service.uploadFileFromPath(
        tmpPath,
        destPath,
        onProgress: (sent, total) =>
            progress((total ~/ 2) + (sent ~/ 2), total),
        useTransferChannel: true,
      );
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best effort */}
    }
  }

  /// Different-host remote→remote: download to a temp file on the
  /// local machine, then upload to the destination host. The progress
  /// readout shows total wall-clock progress (download = first half,
  /// upload = second half) so the user sees something moving the
  /// whole time.
  /// [_remoteToRemoteBridged] for any two sources (an FTPS host on either
  /// side): down to a file on this device, then up, each half of the progress.
  Future<void> _bridgedThroughHere(
    PaneFileSource src,
    PaneFileSource dst,
    String srcPath,
    String destPath,
    PaneTransferProgress progress,
    TransferCancelToken cancelToken,
  ) async {
    final tmp = await Directory.systemTemp.createTemp('zest_sftp_bridge_');
    final tmpPath = p.join(tmp.path, 'bridge.bin');
    try {
      await src.downloadFile(srcPath, tmpPath,
          onProgress: (sent, total) => progress(sent ~/ 2, total), cancelToken: cancelToken, bulk: true);
      await dst.uploadFile(tmpPath, destPath,
          onProgress: (sent, total) => progress((total ~/ 2) + (sent ~/ 2), total),
          cancelToken: cancelToken,
          bulk: true);
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best effort */}
    }
  }

  Future<void> _remoteToRemoteBridged(
    RemotePaneFileSource src,
    RemotePaneFileSource dst,
    String srcPath,
    String destPath,
    PaneTransferProgress progress,
  ) async {
    final tmp = await Directory.systemTemp.createTemp('zest_sftp_bridge_');
    final tmpPath = p.join(tmp.path, 'bridge.bin');
    try {
      // Download phase - first half of overall progress.
      await src.service.downloadFileToPath(
        srcPath,
        tmpPath,
        onProgress: (sent, total) => progress(sent ~/ 2, total),
        useTransferChannel: true,
      );
      // Upload phase - second half.
      await dst.service.uploadFileFromPath(
        tmpPath,
        destPath,
        onProgress: (sent, total) =>
            progress((total ~/ 2) + (sent ~/ 2), total),
        useTransferChannel: true,
      );
    } finally {
      try {
        await tmp.delete(recursive: true);
      } catch (_) {/* best effort */}
    }
  }

  // ── Edit-and-save-back (remote text files) ─────────────────────────

  /// Open a remote (or local) file in the bundled text editor. On save,
  /// write the new contents back to the source. Used for quickly
  /// tweaking config files on a server without an external editor.
  Future<void> _onOpenFile(int side, PaneFileEntry entry) async {
    if (entry.isDirectory) return;
    // Images preview in-app instead of being refused as binary. This works for
    // both remote and local files and renders identically on every platform,
    // Flutter decodes the bytes, so it never touches the OS file explorer.
    if (_isImageByName(entry.name)) {
      await _previewImage(side, entry);
      return;
    }
    // Refuse files larger than the shared inline-edit cap - the editor isn't
    // built for huge log dumps, and the gate must match the read cap below or a
    // too-large file would be truncated then saved back short. Point the user
    // at the toolbar's Download button, which exists for exactly this.
    if (entry.size > kMaxInlineEditBytes) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpTooLargeToEdit(
            entry.name, kMaxInlineEditBytes ~/ (1024 * 1024)),
        isError: true,
      );
      return;
    }
    // Refuse to open files with extensions we know are binary
    // before we even pay the network round-trip.  Saves the user
    // from seeing a screen of mojibake when they double-click a
    // .lnk / .png / .zip by mistake.
    if (_isLikelyBinaryByName(entry.name)) {
      _showBinaryRefusal(entry.name);
      return;
    }

    final fs = side == 0 ? _leftFileSource : _rightFileSource;
    final paneKey = side == 0 ? _leftPaneKey : _rightPaneKey;
    List<int> bytes;
    try {
      // Hard cap enforced against bytes actually received - the size gate above
      // trusts the READDIR size, which a hostile server controls and can
      // under-report to slip a huge file through the editor. This ceiling can't
      // be lied past, and it MUST equal the gate so a passing file is never
      // truncated here and then saved back short.
      bytes = await fs.readBytes(entry.path, maxBytes: kMaxInlineEditBytes);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, sftpErrorMessage(e, op: SftpOp.download),
          isError: true, details: e.toString());
      return;
    }

    // Content sniff - null bytes or a high ratio of un-printable
    // bytes in the first sample is the universal "binary" tell
    // and catches everything the extension allowlist misses
    // (mis-named files, sketchy MIMEs, unknown formats).
    if (_looksLikeBinary(bytes)) {
      if (!mounted) return;
      _showBinaryRefusal(entry.name);
      return;
    }

    if (!mounted) return;
    final desc = side == 0 ? _leftSource : _rightSource;
    // The editor's tabs (3.4): the file opens in its own tab, naming its
    // host so a remote file never looks local. It is read in its own
    // encoding (a file that is not UTF-8 opens in the closest match with a
    // notice, where it was refused), its line endings kept, and a save
    // checks the file's hash on the host first.
    final EditorSource source;
    if (desc is RemotePaneSource && fs is RemotePaneFileSource) {
      source = SftpEditorSource(
        service: fs.service,
        path: entry.path,
        hostLabel: desc.hostLabel,
        host: editorHostOfSession(ref, desc.sessionId),
        onSaved: () => paneKey.currentState?.refresh(),
        reconnectWith: () async {
          final registered = ref.read(sftpSessionsProvider.notifier).get(desc.sessionId);
          if (registered != null && registered.isOpen) return registered;
          try {
            await fs.service.open();
            return fs.service;
          } catch (_) {
            return null;
          }
        },
      );
    } else {
      // This computer's file, or an FTPS host's: that host's everywhere (its
      // tab, its draft, its save through the FTPS session), never local.
      source = PaneEditorSource.ofPane(
        pane: desc,
        files: fs,
        path: entry.path,
        fileName: entry.name,
        thisComputer: thisComputerName(AppLocalizations.of(context)!),
        hostOfSession: (sessionId) => editorHostOfSession(ref, sessionId),
        onSaved: () => paneKey.currentState?.refresh(),
      );
    }
    final data = Uint8List.fromList(bytes);
    await openInEditor(
      context,
      source,
      bytes: data,
      version: FileVersion(modified: entry.modifiedAt, size: data.length, sha256: sha256Of(data)),
    );
  }

  /// Extension-based fast-path rejection.  Catches the obvious cases
  /// (.lnk, images, archives, executables, fonts, video, etc.) before
  /// we even read a byte from disk or the network.
  static const Set<String> _binaryExtensions = {
    // Windows-specific
    'lnk', 'exe', 'dll', 'sys', 'msi', 'cab', 'pdb', 'ocx',
    // Archives + compression
    'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'zst', 'lz4',
    'iso', 'dmg', 'pkg', 'deb', 'rpm', 'apk', 'aab', 'ipa', 'jar',
    // Images
    'png', 'jpg', 'jpeg', 'gif', 'bmp', 'tiff', 'tif', 'webp', 'ico',
    'heic', 'heif', 'avif', 'svgz', 'psd', 'ai', 'eps', 'raw',
    // Audio / video
    'mp3', 'wav', 'flac', 'ogg', 'opus', 'aac', 'm4a',
    'mp4', 'mkv', 'mov', 'avi', 'webm', 'wmv', 'flv', 'm4v', 'vob',
    // Documents (binary)
    'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'odt', 'ods',
    // Fonts
    'ttf', 'otf', 'woff', 'woff2', 'eot',
    // Compiled code / data
    'class', 'pyc', 'pyo', 'so', 'dylib', 'a', 'o', 'obj', 'lib',
    'wasm', 'bin', 'dat', 'db', 'sqlite', 'sqlite3', 'mdb',
  };

  static const int _kMaxImagePreviewBytes = 32 * 1024 * 1024;
  static const int _kMaxImagePreviewPixels = 50 * 1000 * 1000; // 50 MP
  static const int _kMaxImagePreviewDim = 20000; // per side

  /// Whether an image's header declares dimensions too large to decode safely.
  /// The 32 MB byte cap bounds the ENCODED size, but a highly compressible file
  /// (a solid-colour PNG or lossless WebP) can be tiny while declaring enormous
  /// dimensions that decode to a multi-gigabyte bitmap and OOM the app. Reading
  /// the header lets us refuse it without decoding. Covers the compressible bomb
  /// formats (PNG, GIF, WebP extended/lossless); an unrecognised format returns
  /// false and relies on the byte cap plus the decode-time cacheWidth. Each side
  /// is bounded before the product so a header claiming 0xFFFFFFFF cannot
  /// overflow the multiply into a negative that slips past the check.
  bool _imageDeclaredTooLarge(Uint8List b) {
    int w = 0, h = 0;
    if (b.length >= 24 &&
        b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      // PNG: IHDR width/height, big-endian uint32 at offsets 16 and 20.
      w = (b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19];
      h = (b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23];
    } else if (b.length >= 10 &&
        b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      // GIF: logical screen width/height, little-endian uint16 at 6 and 8.
      w = b[6] | (b[7] << 8);
      h = b[8] | (b[9] << 8);
    } else if (b.length >= 30 &&
        b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46 &&
        b[8] == 0x57 && b[9] == 0x45 && b[10] == 0x42 && b[11] == 0x50) {
      // WebP: RIFF....WEBP; VP8X (extended) and VP8L (lossless) are the
      // compressible bomb vectors, lossy VP8 is DCT-based and not a bomb.
      final fourcc = String.fromCharCodes(b.sublist(12, 16));
      if (fourcc == 'VP8X') {
        w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
      } else if (fourcc == 'VP8L' && b.length >= 25 && b[20] == 0x2F) {
        final b1 = b[21], b2 = b[22], b3 = b[23], b4 = b[24];
        w = 1 + (((b2 & 0x3F) << 8) | b1);
        h = 1 + (((b4 & 0x0F) << 10) | (b3 << 2) | ((b2 & 0xC0) >> 6));
      } else {
        return false;
      }
    } else {
      return false;
    }
    if (w <= 0 || h <= 0) return false;
    if (w > _kMaxImagePreviewDim || h > _kMaxImagePreviewDim) return true;
    return w * h > _kMaxImagePreviewPixels;
  }

  bool _isImageByName(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0) return false;
    final ext = name.substring(dot + 1).toLowerCase();
    return const {'png', 'jpg', 'jpeg', 'gif', 'webp', 'bmp'}.contains(ext);
  }

  Future<void> _previewImage(int side, PaneFileEntry entry) async {
    if (entry.size > _kMaxImagePreviewBytes) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpTooLargeToPreview(
            entry.name, _kMaxImagePreviewBytes ~/ (1024 * 1024)),
        isError: true,
      );
      return;
    }
    final fs = side == 0 ? _leftFileSource : _rightFileSource;
    Uint8List bytes;
    try {
      bytes = await fs.readBytes(entry.path, maxBytes: _kMaxImagePreviewBytes);
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(context, sftpErrorMessage(e, op: SftpOp.download),
          isError: true, details: e.toString());
      return;
    }
    if (!mounted) return;
    // Refuse a decompression bomb (tiny file, enormous declared dimensions)
    // before it reaches the decoder and OOMs the app.
    if (_imageDeclaredTooLarge(bytes)) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpImageTooLarge(entry.name),
        isError: true,
      );
      return;
    }
    await SftpImagePreviewDialog.show(
      context,
      name: entry.name,
      bytes: bytes,
      sizeLabel: entry.formattedSize,
    );
  }

  bool _isLikelyBinaryByName(String filename) {
    final dot = filename.lastIndexOf('.');
    if (dot < 0 || dot == filename.length - 1) return false;
    final ext = filename.substring(dot + 1).toLowerCase();
    return _binaryExtensions.contains(ext);
  }

  /// Content-sniffing heuristic.  Inspects the first 1 KB of the
  /// file for the two universal tells:
  ///   * any NUL byte - every binary format includes them, every
  ///     text encoding except UTF-16/32 avoids them
  ///   * a high ratio of un-printable control bytes (>30%) -
  ///     catches UTF-16 LE/BE, binary-with-random-text, and the
  ///     long tail of obscure formats the extension list misses
  bool _looksLikeBinary(List<int> bytes) {
    if (bytes.isEmpty) return false;
    final sampleLen = bytes.length < 1024 ? bytes.length : 1024;
    var nulls = 0;
    var control = 0;
    for (var i = 0; i < sampleLen; i++) {
      final b = bytes[i];
      if (b == 0) nulls++;
      // Printable ASCII or common whitespace: \t \n \r and 32-126.
      // Above 127 is allowed (UTF-8 multibyte sequences); we only
      // count the C0 control range minus tab/lf/cr as "binary tell".
      if (b < 9 || (b > 13 && b < 32) || b == 127) {
        control++;
      }
    }
    if (nulls > 0) return true;
    return control / sampleLen > 0.30;
  }

  void _showBinaryRefusal(String name) {
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.sftpBinaryFile(name),
      isError: true,
    );
  }

  // ── Transfer queue actions ─────────────────────────────────────────

  /// Cancel all on an operation's row: every file of the drop, the ones
  /// running and the ones still waiting their turn, and the walk of its
  /// folders. It cancelled only the rows there were (the three running), and
  /// the next files then started.
  void _cancelOperation(String operationId) {
    _cancelledOperations.add(operationId);
    for (final t in ref.read(sftpTransfersProvider)) {
      if (t.operationId == operationId &&
          (t.status == TransferStatus.active || t.status == TransferStatus.pending)) {
        _cancelTransfer(t.id);
      }
    }
  }

  void _cancelTransfer(String id) {
    // Fire the real token first - it aborts an in-flight write immediately
    // (even a wedged one). The _cancelled flag is the belt-and-suspenders
    // progress-tick path.
    _cancelTokens[id]?.cancel();
    setState(() => _cancelled[id] = true);
    // Count operations (delete / chmod / mkdir) carry no transfer token - they
    // run inside a pane and register a canceller on the queue keyed by op id, so
    // the same Activity cancel button reaches them through the registry.
    _transfersNotifier.requestCancel(id);
  }

  void _retryTransfer(String id) {
    final item = _transfersNotifier.findById(id);
    if (item == null) return;
    // Resolve the ORIGINAL source/destination panes by the sides recorded at
    // enqueue time. Guessing from direction (the old behaviour) sent
    // local→local and remote→remote retries to the wrong pane - in the worst
    // case uploading a file to the wrong server.
    PaneFileSource? src;
    PaneFileSource? dst;
    if (item.srcSide != null && item.dstSide != null) {
      src = item.srcSide == 0 ? _leftFileSource : _rightFileSource;
      dst = item.dstSide == 0 ? _leftFileSource : _rightFileSource;
      // A pane may have been reconnected to a different host since the
      // transfer ran - the side is still there but points somewhere else.
      // Refuse rather than silently transfer against the wrong endpoint.
      if (src.sourceId != item.srcSourceId ||
          dst.sourceId != item.dstSourceId) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!.sftpRetryPaneChanged(item.fileName),
          isError: true,
        );
        return;
      }
    } else {
      // Legacy items enqueued before sides were tracked: fall back to the
      // old best-effort guess.
      if (item.direction == TransferDirection.upload) {
        src = _leftFileSource is LocalPaneFileSource
            ? _leftFileSource
            : _rightFileSource;
        dst = src == _leftFileSource ? _rightFileSource : _leftFileSource;
      } else {
        src = _leftFileSource is RemotePaneFileSource
            ? _leftFileSource
            : _rightFileSource;
        dst = src == _leftFileSource ? _rightFileSource : _leftFileSource;
      }
    }
    item.status = TransferStatus.active;
    item.transferredBytes = 0;
    item.errorMessage = null;
    item.errorReport = null;
    item.failure = null;
    item.startedAt = DateTime.now();
    _transfersNotifier.touch();
    _cancelled.remove(id);
    final cancelToken = TransferCancelToken();
    _cancelTokens[id] = cancelToken;
    // Fire and forget - the running flag isn't visible here.
    // ignore: discarded_futures
    _runTransfer(src, dst, item.localPath, item.remotePath, item, cancelToken)
        .then((_) {
      item.status = TransferStatus.completed;
      item.completedAt = DateTime.now();
      _transfersNotifier.touchNow();
    }).catchError((Object e, StackTrace stack) {
      if (_cancelled[id] == true || cancelToken.isCancelled) {
        item.status = TransferStatus.cancelled;
      } else {
        item.failWith(e, stack: stack, op: _sftpOpOf(item));
      }
      _transfersNotifier.touchNow();
    }).whenComplete(() {
      _cancelled.remove(id);
      _cancelTokens.remove(id);
    });
  }

  void _clearCompleted() {
    _transfersNotifier.clearCompleted();
  }

  /// Drop a single finished row (the per-row dismiss ×). Only fired for a
  /// terminal item, so there's no in-flight token to release beyond what the
  /// notifier clears.
  void _dismissTransfer(String id) {
    _cancelTokens.remove(id);
    _cancelled.remove(id);
    _transfersNotifier.remove(id);
  }

  // ── Build ──────────────────────────────────────────────────────────

  /// Render either a real [SftpPane] or a "Click to reconnect"
  /// placeholder if the source is in [DisconnectedPaneSource] state.
  Widget _buildPane({
    required int side,
    required SftpPaneSource desc,
    required PaneFileSource fs,
    required GlobalKey<SftpPaneState> key,
    required ValueChanged<SftpPaneSource> onSourceChanged,
    required Future<void> Function() onConnectRequested,
    String? otherSessionId,
    VoidCallback? onClose,
    // The dock's one pane: no other pane beside it ([SftpDualPaneScreen.docked]).
    bool onePane = false,
  }) {
    final Widget pane;
    if (desc is DisconnectedPaneSource) {
      pane = _DisconnectedPlaceholder(
        source: desc,
        onReconnect: () => _reconnectHost(side, desc),
        onPickOther: () async {
          // Open the picker so the user can swap to a connected session
          // instead of reviving the dropped one.
          final result = await ConnectionPickerDialog.show(
            context,
            title: AppLocalizations.of(context)!.sftpSwitchSource,
            includeLocalFiles: true,
          );
          if (!mounted) return;
          if (result.localFiles) {
            onSourceChanged(const LocalPaneSource());
          } else if (result.connection != null) {
            await onConnectRequested();
          }
        },
      );
    } else {
      pane = SftpPane(
      key: key,
      source: fs,
      sourceDescriptor: desc,
      paneSide: side,
      // The source picker moved to the rail header, so the pane
      // no longer owns it - the rail drives source changes via the dual-pane.
      onInterPaneDrop: (payload, destPath) =>
          _onInterPaneDrop(payload, side, destPath),
      onOpenFile: (entry) => _onOpenFile(side, entry),
      // The dock's one pane has no other pane: Download asks for a folder of
      // this computer.
      onTransferSelection: (entries) =>
          onePane ? _downloadPicked(entries) : _transferSelectionToOther(side, entries),
      docked: onePane,
      onUploadHere: onePane ? _uploadPicked : null,
      // The dock's More turns its two panes on and off, from the one pane or
      // from the right one of the two.
      twoPanes: widget.docked && side == 1 ? widget.twoPanes : null,
      onTwoPanes: widget.docked && side == 1 ? widget.onTwoPanes : null,
      // Only remote panes can open a shell "here" - a local pane's terminal is
      // a separate launch path, deferred.
      onOpenTerminalHere: desc is RemotePaneSource
          ? (path) => _openTerminalHere(side, path)
          : null,
      // Mirror is one-way local → remote, so it's offered on local panes only.
      onMirrorFolder: desc is LocalPaneSource
          ? (localDir) => _mirrorFolderToOther(side, localDir)
          : null,
      // Per-host / local directory pins: the path-bar pin button
      // toggles the current dir into this source's rail group.
      pinnedPaths: _pinsForSide(side).map((p) => p.path).toSet(),
      onTogglePin: (path) => _togglePinForSide(side, path),
      onBookmarkMenu: (pos) => _showBookmarkMenu(side, pos, fromButton: true),
      otherPaneSessionId: otherSessionId,
      onClose: onClose,
      // Remember the last folder (spec 1-3, 6). The restored paths belong to
      // this pane pair's own session / local side only, never to a host the
      // rail swapped in later.
      initialPath: desc is RemotePaneSource
          ? (desc.sessionId == _paneStateKey ? widget.initialRemotePath : null)
          : (desc is LocalPaneSource ? widget.initialLocalPath : null),
      onPathSettled: (path) => _onPathSettled(side, path),
      rememberedPath:
          desc is RemotePaneSource ? () => _hostDefaultFor(side) : null,
      shouldSuggestPin: desc is RemotePaneSource
          ? (path) => _shouldSuggestPin(side, path)
          : null,
      onPinSuggestionDeclined: (path) => _declinePinSuggestion(side, path),
      );
    }
    // Hovering a rail group outlines the pane it drives.
    // Constant 2px border (transparent unless hovered) - no layout shift.
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      decoration: BoxDecoration(
        border: Border.all(
          color: _hoveredRailSide == side
              ? AppColors.brandOrange.withValues(alpha: 0.6)
              : Colors.transparent,
          width: 2,
        ),
      ),
      child: pane,
    );
  }

  @override
  Widget build(BuildContext context) {
    // Required by AutomaticKeepAliveClientMixin so the framework knows
    // to register this state with the nearest KeepAlive marker. Without
    // this call the mixin is silently a no-op.
    super.build(context);

    // Rebuild the rail when pins change (device-local pins or the synced host
    // pins on any connection) - [_pinsForSide] reads them with ref.read.
    ref.watch(sftpLocalPinsProvider);
    ref.watch(connectionsWithDetailsProvider);
    // A team's rules for its hosts, read and kept, so whether this account
    // may change a team host's shared bookmarks is known when a menu asks.
    if (ref.watch(activeSpaceProvider) is OrchardSpace) ItemRules.of(ref, 'host');
    // Recompute stale local pins OFF the build path whenever the local pin set
    // changes (never a blocking existsSync inside build).
    ref.listen(sftpLocalPinsProvider, (_, _) => unawaited(_refreshStalePins()));
    // A pane on a host follows what becomes of its session.
    ref.listen(activeSessionsProvider, (_, _) => unawaited(_followSessions()));
    // The dock's terminal's folder, asked from its header (4.0).
    final terminalSession = widget.initialSessionId;
    if (widget.docked && terminalSession != null) {
      ref.listen<TerminalFolderRequest?>(terminalFolderRequestProvider(terminalSession), (_, request) {
        if (request != null) unawaited(_openTerminalFolder(request));
      });
    }

    final leftOtherId = _rightSource is RemotePaneSource
        ? (_rightSource as RemotePaneSource).sessionId
        : null;
    final rightOtherId = _leftSource is RemotePaneSource
        ? (_leftSource as RemotePaneSource).sessionId
        : null;

    // The SFTP dock beside a terminal (4.0): the
    // host's files alone, with no rail. The left side stays as it was, for
    // when the two panes are shown again.
    final onePane = widget.docked && !widget.twoPanes;
    final Widget railAndPanes = onePane
        ? _buildPane(
            side: 1,
            desc: _rightSource,
            fs: _rightFileSource,
            key: _rightPaneKey,
            onSourceChanged: _onRightSourceChanged,
            onConnectRequested: () => _onConnectRequested(1),
            onClose: widget.onClose,
            onePane: true,
          )
        : _buildRailAndPanes(leftOtherId: leftOtherId, rightOtherId: rightOtherId);

    // The Activity panel spans the FULL width along the bottom - under the rail
    // too, not just under the panes - and is ALWAYS present so it doubles as a
    // transfer history for as long as the SFTP view stays open (user request).
    // It is the ONLY thing that watches the transfers provider, scoped to a
    // Consumer so a progress tick rebuilds only the panel,
    // never the panes or the rail.
    final body = Column(
      children: [
        Expanded(child: railAndPanes),
        Consumer(
          builder: (context, ref, _) => TransferQueuePanel(
            transfers: ref.watch(sftpTransfersProvider),
            onCancel: _cancelTransfer,
            onCancelOperation: _cancelOperation,
            onRetry: _retryTransfer,
            onDismiss: _dismissTransfer,
            onClearCompleted: _clearCompleted,
            onUndoHold: (id) => ref.read(sftpDeleteHoldProvider).undo(id),
            onCommitHold: (id) =>
                unawaited(ref.read(sftpDeleteHoldProvider).commitNow(id)),
          ),
        ),
      ],
    );

    if (widget.embedded) return body;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SFTP'),
        backgroundColor: AppColors.surfaceDark,
      ),
      backgroundColor: AppColors.background,
      body: body,
    );
  }

  /// The two panes side by side, with the rail of places beside them.
  Widget _buildRailAndPanes({String? leftOtherId, String? rightOtherId}) {
    final panes = SplitPane(
      initialRatio: 0.5,
      first: _buildPane(
        side: 0,
        desc: _leftSource,
        fs: _leftFileSource,
        key: _leftPaneKey,
        onSourceChanged: _onLeftSourceChanged,
        onConnectRequested: () => _onConnectRequested(0),
        otherSessionId: leftOtherId,
      ),
      second: _buildPane(
        side: 1,
        desc: _rightSource,
        fs: _rightFileSource,
        key: _rightPaneKey,
        onSourceChanged: _onRightSourceChanged,
        onConnectRequested: () => _onConnectRequested(1),
        otherSessionId: rightOtherId,
        onClose: widget.onClose,
      ),
    );

    // Left rail with quick locations for each pane's source.
    // Collapsible to a thin strip.
    return Row(
      children: [
        if (_railCollapsed)
          _buildCollapsedRail()
        else
          SftpLocationsRail(
            groups: _buildRailGroups(),
            onCollapse: () => setState(() => _railCollapsed = true),
          ),
        Expanded(child: panes),
      ],
    );
  }

  // ── The dock's one pane: this computer through the system's dialogs ──

  /// The left side as this computer's files, where it is something else (a
  /// host the rail put there while the dock showed two panes): what the dock's
  /// one pane uploads from and downloads to.
  void _thisComputerOnTheLeft() {
    if (_leftSource is LocalPaneSource) return;
    _commitHoldsLeavingSource(_leftSource, _rightSource);
    setState(() {
      _leftSource = const LocalPaneSource();
      _leftFileSource = LocalPaneFileSource();
    });
  }

  /// Upload in the dock's one pane: files of this computer, picked in the
  /// system's dialog, go into [folder] of the pane's host, as a drop of them
  /// on it would (the same questions about files already there, the same
  /// transfers in Activity).
  Future<void> _uploadPicked(String folder) async {
    final picked = await FilePicker.platform.pickFiles(
      dialogTitle: AppLocalizations.of(context)!.sftpUpload,
      allowMultiple: true,
      lockParentWindow: true,
    );
    final paths = [
      for (final f in picked?.files ?? const <PlatformFile>[])
        if (f.path != null) f.path!,
    ];
    if (paths.isEmpty || !mounted) return;
    _thisComputerOnTheLeft();
    final entries = <PaneFileEntry>[];
    for (final path in paths) {
      final entry = await _leftFileSource.stat(path);
      if (entry != null) entries.add(entry);
    }
    if (entries.isEmpty || !mounted) return;
    await _onInterPaneDrop(PaneDragPayload(paneSide: 0, entries: entries), 1, folder);
  }

  /// Download in the dock's one pane: [entries] go into a folder of this
  /// computer, picked in the system's dialog, as a drop of them there would.
  Future<void> _downloadPicked(List<PaneFileEntry> entries) async {
    if (entries.isEmpty) return;
    final folder = await FilePicker.platform.getDirectoryPath(
      dialogTitle: AppLocalizations.of(context)!.sftpDownload,
      lockParentWindow: true,
    );
    if (folder == null || !mounted) return;
    _thisComputerOnTheLeft();
    await _onInterPaneDrop(PaneDragPayload(paneSide: 1, entries: entries), 0, folder);
  }
}

/// Placeholder shown when a pane's source is a [DisconnectedPaneSource]
/// (the host that pane was on has dropped). One tap kicks off a
/// reconnect; the secondary action lets the user pick a different
/// source instead.
class _DisconnectedPlaceholder extends ConsumerWidget {
  final DisconnectedPaneSource source;
  final Future<void> Function() onReconnect;
  final Future<void> Function() onPickOther;

  const _DisconnectedPlaceholder({
    required this.source,
    required this.onReconnect,
    required this.onPickOther,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      color: AppColors.surfaceDark,
      child: ZestEmptyState(
        icon: LucideIcons.serverOff,
        title: Redactable.host(source.hostLabel).displayIn(ref),
        message: l10n.sftpDisconnectedMessage,
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: onReconnect,
              icon: const Icon(LucideIcons.refreshCw, size: 16),
              label: Text(l10n.sftpReconnect),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.v3AccentPrimary,
                foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: onPickOther,
              child: Text(l10n.sftpPickDifferentSource),
            ),
          ],
        ),
      ),
    );
  }
}

/// Internal signal used to differentiate user-cancelled transfers from
/// true errors when a transfer's progress callback is interrupted.
class _CancelledException implements Exception, HasTypeName {
  const _CancelledException();
  @override
  String toString() => 'Transfer cancelled';

  @override
  String get typeName => '_CancelledException';
}

/// One file that differed from its destination but was skipped under "replace
/// only when local is newer" because the local copy was not newer. Carries
/// everything needed to resend it as a forced overwrite on the user's request.
/// [SFTP sync spec 1a]
class _SkippedOlder {
  const _SkippedOlder({
    required this.src,
    required this.dst,
    required this.entry,
    required this.destDir,
    this.operationLabel,
    this.operationRoots,
  });

  final PaneFileSource src;
  final PaneFileSource dst;
  final PaneFileEntry entry;
  final String destDir;
  final String? operationLabel;
  final List<String>? operationRoots;
}

/// Tiny concurrency limiter - runs at most [concurrency] futures at the
/// same time, queues the rest, and resolves them as slots free up.
///
/// SFTP transfers benefit from a small amount of parallelism: a single
/// SSH connection can multiplex multiple file-handle operations, so
/// running 3-ish files concurrently masks round-trip latency on small
/// files and tops out the bandwidth on large ones - without overwhelming
/// the server. WinSCP / FileZilla default to 2-3 parallel transfers for
/// the same reasons.
///
/// Keep concurrency conservative (~3): too many concurrent transfers
/// can trigger rate limits / "too many open files" on the server, and
/// fragment bandwidth across them so each individual file feels slow.

/// Mutable box for the user's "Apply to all remaining conflicts"
/// choice. Lives for the duration of a single drop operation and is
/// shared by every recursive [_transferDirectory] stack frame -
/// passing a nullable value parameter wouldn't work because Dart
/// passes function arguments by value, and a callback would only
/// update one specific stack frame at a time.
///
/// Once set, every subsequent file (in the same drop, at any depth)
/// applies the stored resolution silently instead of re-prompting.
class _StickyResolution {
  OverwriteResolution? value;

  /// Conflict prompts shown so far in this drop, and the pre-scanned total -
  /// together they drive the "N of M" counter in the conflict dialog. Prompts
  /// run sequentially (the walk gates on the dialog), so the plain increment is
  /// safe. [sourceVerb] labels the source row ("Uploading" / "Downloading" /
  /// "Copying").
  int seen = 0;
  int totalConflicts = 1;
  bool totalIsExact = true;
  String sourceVerb = gl10n.sftpVerbCopying;

  /// Files the drop skipped because the destination already held the same
  /// bytes. Reported at the end so "nothing happened" is never silent.
  int skippedUnchanged = 0;

  /// Set once the user picks "Cancel" on any conflict prompt. Every loop (the
  /// top-level drop loop and every recursive [_transferDirectory] frame) checks
  /// this and bails, so Cancel aborts the WHOLE drop instead of just skipping
  /// the current file. A bare `return` only unwound one stack frame, leaving
  /// the parent loop to keep prompting the next sibling.
  bool cancelled = false;

  /// True when the drop is a batch (a folder, or more than one file) rather
  /// than a single plain file. Drives the conflict dialog's "apply to all
  /// remaining" control: a recursive folder copy can't pre-count its total, so
  /// the control is enabled on batches regardless of the running count.
  bool isBatch = false;

  /// The destination paths this drop has given out, so that no two of its
  /// files are written to one place.
  DropDestinationNames names = DropDestinationNames(caseInsensitive: false);
}

/// Streaming SHA-256 of a local file as lowercase hex. Top-level so it can run
/// under [Isolate.run] (only the path crosses the isolate boundary).
Future<String> _sha256FileHex(String path) async {
  final digest = await sha256.bind(File(path).openRead()).first;
  return digest.toString();
}
