import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/providers/terminal_folder_providers.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart' show safeChildName;
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/transfer_cancel_token.dart';
import 'package:zestssh/utils/android_save_folder.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_hosts.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/text_editor_screen.dart';
import 'package:zestssh/ui/screens/sftp/widgets/overwrite_conflict_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart'
    show RemotePaneFileSource, remoteNameHiddenAt;
import 'package:zestssh/ui/screens/sftp/sudo_retry.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_breadcrumb_bar.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_file_icon.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart'
    show SftpOperationKind, TransferItem, TransferStatus;
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/error_details_panel.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/terminal_folder_help.dart';
import 'dart:async';
import 'package:zestssh/features/sftp/debounced_writer.dart';
import 'package:zestssh/features/sftp/remembered_path_resolver.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/ui/widgets/haptics.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/utils/number_text.dart';

/// Sort field for SFTP entries.
enum _SortBy { name, size, date, type }

/// SFTP file browser screen.
///
/// Allows navigating remote directories, uploading, downloading,
/// creating directories, renaming, and deleting files.
/// What a phone's held deletes are kept under: one name for each SFTP
/// connection.
String phoneSftpHoldKey(SftpService sftp) => 'phone-sftp-${identityHashCode(sftp)}';

/// Closes a phone's SFTP connection once its held deletes are made: those
/// still waiting are made at once, and the close waits for every one under
/// way (closed under them, they would fail).
Future<void> closePhoneSftp(SftpDeleteHoldManager holds, SftpService sftp) =>
    holds.commitSessionThenClose(phoneSftpHoldKey(sftp), sftp.close);
/// A server's file name as the phone's browser draws it: every character
/// showing as what it is (found in security audits).
/// The list, the row's sheet and what is said
/// of a file drew the name as the server sent it, so one with a direction
/// override inside read as another kind of file (a name ending in "gnp.exe"
/// after U+202E reads as a ".png"). The computer's pane has drawn names this
/// way before; the name a file is saved under was cleaned already
/// (safeChildName), and the name sent back to the server is never this one.
String _shownName(String name) => visibleCommand(name);

class SftpBrowserScreen extends ConsumerStatefulWidget {
  final SftpService sftp;
  final String connectionLabel;

  /// The host record behind [sftp], for the remembered folder (remember-
  /// last-folder spec): read on open, written back debounced. Null for an
  /// ad-hoc session, which has nowhere to remember to.
  final String? connectionId;
  final String? username;

  /// The session [sftp] works on, so that the editor knows the file's host
  /// by its id and space, never by [connectionLabel] (which two hosts can
  /// share). Null: the editor takes it for a host of its own.
  final String? sessionId;

  const SftpBrowserScreen({
    super.key,
    required this.sftp,
    required this.connectionLabel,
    this.connectionId,
    this.username,
    this.sessionId,
  });

  @override
  ConsumerState<SftpBrowserScreen> createState() => _SftpBrowserScreenState();
}

class _SftpBrowserScreenState extends ConsumerState<SftpBrowserScreen> {
  String _currentPath = '/';
  List<SftpEntry> _entries = [];
  bool _isLoading = true;

  /// Why the folder (or the home folder) could not be listed, in the app's
  /// language, and its report to copy ([ErrorReport.build]: no folder named).
  String? _error;
  String? _errorReport;

  /// The home folder was found: Retry lists the folder that failed. Until
  /// then it looks for the home folder again (it listed "/" instead).
  bool _homeFound = false;
  final List<String> _pathHistory = [];
  double _transferProgress = 0;
  bool _isTransferring = false;
  String _transferLabel = '';

  /// Live cancel handle for the in-flight transfer. Non-null only while
  /// [_isTransferring]. The Cancel button on the progress card flips it;
  /// the SFTP transfer loop polls it per chunk and throws
  /// [TransferCancelledException], which each transfer method catches.
  TransferCancelToken? _cancelToken;

  // Sort state
  _SortBy _sortBy = _SortBy.name;
  bool _sortAscending = true;

  // Multi-select mode
  bool _selectMode = false;
  final _selectedEntries = <String>{}; // paths of selected entries

  /// Debounced host-default write (spec 2: ten navigations, one write).
  final DebouncedWriter _folderWriter = DebouncedWriter();

  /// The app's held deletes, and when the app leaves the screen for the
  /// background, which makes this connection's at once (the system may stop
  /// the app before their time is out).
  late final SftpDeleteHoldManager _holds;
  late final AppLifecycleListener _life;

  @override
  void initState() {
    super.initState();
    _holds = ref.read(sftpDeleteHoldProvider);
    _life = AppLifecycleListener(onPause: () => _holds.commitSession(phoneSftpHoldKey(widget.sftp)));
    _loadInitialDirectory();
  }

  @override
  void dispose() {
    _life.dispose();
    // Closing the browser is a write trigger (spec 2).
    // ignore: discarded_futures
    _folderWriter.flush();
    _folderWriter.dispose();
    super.dispose();
  }

  Future<void> _loadInitialDirectory() async {
    final String home;
    try {
      home = await widget.sftp.getHomeDirectory();
    } catch (e, stack) {
      AppLogger.error('SFTP failed to get home directory: $e');
      if (!mounted) return;
      final l10n = AppLocalizations.of(context)!;
      final said = sftpErrorMessage(e, name: l10n.sftpPlaceHome, op: SftpOp.list);
      setState(() {
        _error = said;
        _errorReport = ErrorReport.build(what: said, where: 'Files: finding the home folder', error: e, stack: stack);
        _isLoading = false;
      });
      return;
    }
    _homeFound = true;
    _currentPath = home;
    AppLogger.info('SFTP home directory: $home');
    await _loadDirectory();
    // Home is open; now the remembered folder, in the background (spec 3).
    unawaited(_openRememberedFolder());
  }

  /// Retry after a failure: the home folder again when it was never found,
  /// else the folder that failed.
  void _retry() {
    if (_homeFound) {
      _loadDirectory();
      return;
    }
    setState(() {
      _isLoading = true;
      _error = null;
      _errorReport = null;
    });
    _loadInitialDirectory();
  }

  /// The host default (spec 1): try the record's last folder, walking up to
  /// the nearest listable ancestor; land there quietly. A folder seen under
  /// another user is a suggestion that fails silently, like any failure
  /// here: the mobile browser has no notice line, home is already open.
  Future<void> _openRememberedFolder() async {
    final connId = widget.connectionId;
    if (connId == null) return;
    try {
      final conn = await ref.read(connectionsDaoProvider).getById(connId);
      final stored = conn?.lastRemotePath;
      if (stored == null || stored.isEmpty || stored == _currentPath) return;
      final source =
          RemotePaneFileSource(service: widget.sftp, sourceId: 'mobile-$connId');
      final res = await resolveRemembered(source, stored, maxClimb: 4);
      final landed = res.path;
      if (!mounted || landed == null || landed == _currentPath) return;
      _navigateTo(landed);
    } catch (e) {
      AppLogger.warning('Remembered SFTP folder not opened: $e');
    }
  }

  /// Spec 2: remember where the browser settled, in realpath form, after the
  /// debounce; a same-path revisit is a no-op in the DAO.
  void _rememberFolder(String path) {
    final connId = widget.connectionId;
    if (connId == null) return;
    final dao = ref.read(connectionsDaoProvider);
    final sftp = widget.sftp;
    final user = widget.username;
    _folderWriter.schedule(({required bool quick}) async {
      var canonical = path;
      if (!quick) {
        try {
          final real = await sftp.realPath(path);
          if (real.isNotEmpty) canonical = real;
        } catch (_) {}
      }
      try {
        await dao.setLastRemotePath(connId, path: canonical, user: user);
      } catch (e) {
        AppLogger.warning('Could not remember the SFTP folder: $e');
      }
    });
  }

  Future<void> _loadDirectory() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _errorReport = null;
    });

    try {
      final entries = await widget.sftp.listDirectory(_currentPath);
      if (mounted) {
        setState(() {
          _entries = entries;
          _isLoading = false;
        });
        _rememberFolder(_currentPath);
      }
    } catch (e, stack) {
      AppLogger.error('SFTP listDirectory($_currentPath) failed: $e');
      if (mounted) {
        // Why, about the folder by its name (the app's language, from what
        // was thrown: it matched words in the raw error), with its report.
        final name = _currentPath.split('/').lastWhere((p) => p.isNotEmpty, orElse: () => '/');
        setState(() {
          _error = sftpErrorMessage(e, name: name, op: SftpOp.list);
          _errorReport = ErrorReport.build(
            what: sftpErrorMessage(e, op: SftpOp.list),
            where: 'Files: listing a folder',
            error: e,
            stack: stack,
          );
          _isLoading = false;
        });
      }
    }
  }

  /// Whether dotfiles are shown at the hidden-files setting.
  bool get _dotfilesShown => ref.read(sftpHiddenLevelProvider) != SftpHiddenLevel.hiddenAndSystem;

  /// Returns sorted and filtered entries.
  List<SftpEntry> get _displayEntries {
    var list = _entries.toList();

    // Hidden files as the setting has them (Settings > SFTP, the same one a
    // computer uses): Windows-protected system names hidden by default,
    // dotfiles too at its strictest. (A switch of the screen's own hid both
    // whatever the setting said, and was off again on every visit.)
    final level = ref.read(sftpHiddenLevelProvider);
    list = list.where((e) => !remoteNameHiddenAt(level, e.name)).toList();

    // Sort: directories first, then by selected field
    list.sort((a, b) {
      // Directories always first
      if (a.isDirectory && !b.isDirectory) return -1;
      if (!a.isDirectory && b.isDirectory) return 1;

      int cmp;
      switch (_sortBy) {
        case _SortBy.name:
          cmp = a.name.toLowerCase().compareTo(b.name.toLowerCase());
        case _SortBy.size:
          cmp = a.size.compareTo(b.size);
        case _SortBy.date:
          final aTime = a.modifiedAt ?? DateTime(1970);
          final bTime = b.modifiedAt ?? DateTime(1970);
          cmp = aTime.compareTo(bTime);
        case _SortBy.type:
          final aExt = a.name.contains('.') ? a.name.split('.').last : '';
          final bExt = b.name.contains('.') ? b.name.split('.').last : '';
          cmp = aExt.compareTo(bExt);
      }
      return _sortAscending ? cmp : -cmp;
    });

    return list;
  }

  void _navigateTo(String path) {
    _pathHistory.add(_currentPath);
    _currentPath = path;
    _loadDirectory();
  }

  void _navigateUp() {
    // This control is the "Parent directory" button (up arrow), so it must
    // always go to the PARENT of the current path - the old code popped
    // navigation history instead, so from a deep path reached via breadcrumb
    // it jumped somewhere unrelated instead of one level up. Push the current
    // path onto history so the move stays consistent with _navigateTo.
    if (_currentPath == '/' || _currentPath.isEmpty) return;
    final cut = _currentPath.lastIndexOf('/');
    final parentPath = cut <= 0 ? '/' : _currentPath.substring(0, cut);
    _pathHistory.add(_currentPath);
    _currentPath = parentPath;
    _loadDirectory();
  }

  /// Join a remote directory and a leaf name into a full remote path,
  /// tolerating a trailing slash on the directory.
  String _joinRemote(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';

  /// Light tactile confirmation on transfer completion / cancellation.
  /// No-op on desktop (the plugin ignores it there anyway, but we gate
  /// to keep intent clear).
  void _haptic() {
    if (Platform.isAndroid || Platform.isIOS) {
      haptic(ref, Haptic.medium);
    }
  }

  /// Guards leaving the browser while a transfer is running. Returns
  /// true if the screen may close (cancelling any in-flight transfer).
  Future<bool> _confirmLeaveDuringTransfer() async {
    if (!_isTransferring) return true;
    final l10n = AppLocalizations.of(context)!;
    final leave = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.sftpTransferInProgressTitle,
      body: l10n.sftpTransferInProgressBody,
      confirmLabel: l10n.cancel,
      cancelLabel: l10n.sftpKeepTransferring,
    );
    if (leave == true) {
      _cancelToken?.cancel();
      return true;
    }
    return false;
  }

  /// AppBar close button + system back both route here so the
  /// in-progress-transfer guard is honoured consistently.
  Future<void> _handleClose() async {
    if (await _confirmLeaveDuringTransfer() && mounted) {
      context.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(sftpHiddenLevelProvider);
    final displayed = _displayEntries;
    final dirCount = displayed.where((e) => e.isDirectory).length;
    final fileCount = displayed.where((e) => !e.isDirectory).length;
    final upload = sftpUploadButtonColors(
        transferring: _isTransferring, page: Theme.of(context).scaffoldBackgroundColor);

    return PopScope(
      // Block the automatic pop while a transfer runs so we can prompt.
      canPop: !_isTransferring,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        if (await _confirmLeaveDuringTransfer() && context.mounted) {
          context.pop();
        }
      },
      child: Scaffold(
      appBar: _selectMode
          ? AppBar(
              title: Text(AppLocalizations.of(context)!.sftpSelectedCount(_selectedEntries.length)),
              leading: IconButton(
                tooltip: AppLocalizations.of(context)!.close,
                icon: const Icon(LucideIcons.x),
                onPressed: _exitSelectMode,
              ),
              actions: [
                IconButton(
                  icon: const Icon(LucideIcons.boxSelect),
                  onPressed: () => setState(() {
                    final files = displayed
                        .where((e) => !e.isDirectory)
                        .map((e) => e.path);
                    if (_selectedEntries.length == files.length) {
                      _selectedEntries.clear();
                    } else {
                      _selectedEntries.addAll(files);
                    }
                  }),
                  tooltip: AppLocalizations.of(context)!.sftpSelectAllFiles,
                ),
                IconButton(
                  icon: const Icon(LucideIcons.download),
                  onPressed: _selectedEntries.isEmpty
                      ? null
                      : _downloadSelected,
                  tooltip: AppLocalizations.of(context)!.sftpDownloadSelected,
                ),
                IconButton(
                  icon: Icon(LucideIcons.trash2,
                      color: AppColors.error),
                  onPressed: _selectedEntries.isEmpty
                      ? null
                      : _deleteSelected,
                  tooltip: AppLocalizations.of(context)!.sftpDeleteSelected,
                ),
              ],
            )
          : AppBar(
              // Bare connection label - no "SFTP:" prefix; every
              // source in an SFTP view is an SFTP source.
              title: RedactedText(Redactable.host(widget.connectionLabel),
                  style: const TextStyle(fontSize: 16)),
              leading: IconButton(
                tooltip: AppLocalizations.of(context)!.close,
                icon: const Icon(LucideIcons.x),
                onPressed: _handleClose,
              ),
              actions: [
                if (_currentPath != '/')
                  IconButton(
                    icon: const Icon(LucideIcons.arrowUp),
                    onPressed: _navigateUp,
                    tooltip: AppLocalizations.of(context)!.sftpParentDirectory,
                  ),
                // Sort button
                PopupMenuButton<_SortBy>(
                  icon: const Icon(LucideIcons.arrowDownWideNarrow),
                  tooltip: AppLocalizations.of(context)!.sftpSort,
                  onSelected: (sort) {
                    setState(() {
                      if (_sortBy == sort) {
                        _sortAscending = !_sortAscending;
                      } else {
                        _sortBy = sort;
                        _sortAscending = true;
                      }
                    });
                  },
                  itemBuilder: (context) => [
                    for (final sort in _SortBy.values)
                      PopupMenuItem(
                        value: sort,
                        child: Row(
                          children: [
                            Expanded(child: Text(_sortLabel(sort))),
                            if (_sortBy == sort)
                              Icon(
                                _sortAscending
                                    ? LucideIcons.arrowUp
                                    : LucideIcons.arrowDown,
                                size: 16,
                                color: AppColors.accentInk,
                              ),
                          ],
                        ),
                      ),
                  ],
                ),
                // Overflow menu
                PopupMenuButton<String>(
                  onSelected: _handleMenuAction,
                  itemBuilder: (context) {
                    final l10n = AppLocalizations.of(context)!;
                    return [
                      PopupMenuItem(
                        value: 'select',
                        child: ListTile(
                          leading: const Icon(LucideIcons.listChecks),
                          title: Text(l10n.sftpSelectFiles),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'mkdir',
                        child: ListTile(
                          leading: const Icon(LucideIcons.folderPlus),
                          title: Text(l10n.sftpNewFolder),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      PopupMenuItem(
                        value: 'goto',
                        child: ListTile(
                          leading: const Icon(LucideIcons.folderInput),
                          title: Text(l10n.sftpGoToPath),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                      // Opened from a session: the folder its terminal is
                      // in (4.0).
                      if (widget.sessionId != null)
                        PopupMenuItem(
                          key: const ValueKey('sftp-terminal-folder'),
                          value: 'terminal',
                          child: ListTile(
                            leading: const Icon(LucideIcons.folderSymlink),
                            title: Text(l10n.sftpTerminalFolderGo),
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      PopupMenuItem(
                        value: 'hidden',
                        child: ListTile(
                          leading: Icon(
                            _dotfilesShown
                                ? LucideIcons.eyeOff
                                : LucideIcons.eye,
                          ),
                          title: Text(_dotfilesShown
                              ? l10n.sftpHideHiddenFiles
                              : l10n.sftpShowHiddenFiles),
                          contentPadding: EdgeInsets.zero,
                        ),
                      ),
                    ];
                  },
                ),
              ],
            ),
      // Upload FAB
      floatingActionButton: _selectMode
          ? null
          : FloatingActionButton(
              // Disable while a transfer is in flight: this screen keeps a
              // SINGLE _cancelToken / progress state, so starting a second
              // transfer would overwrite the first's token (making it
              // uncancellable) and scramble its progress bar. Dim the FAB to
              // signal it's unavailable rather than silently clobbering.
              onPressed: _isTransferring ? null : _uploadFile,
              backgroundColor: upload.fill,
              foregroundColor: upload.ink,
              tooltip: AppLocalizations.of(context)!.sftpUploadFile,
              child: const Icon(LucideIcons.fileUp),
            ),
      body: Column(
        children: [
          // Breadcrumb bar
          SftpBreadcrumbBar(
            path: _currentPath,
            onNavigate: (path) {
              _pathHistory.add(_currentPath);
              _currentPath = path;
              _loadDirectory();
            },
          ),

          // Transfer progress
          if (_isTransferring)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceContainer,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: AppColors.brandOrange.withValues(alpha: 0.2),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(LucideIcons.refreshCw,
                          size: 16,
                          color: AppColors.accentInk.withValues(alpha: 0.8)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(_transferLabel,
                            style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w500)),
                      ),
                      Text(
                        formatPercentNumber(_transferProgress * 100),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.accentInk,
                        ),
                      ),
                      // Cancel button - flips the token; the transfer
                      // loop unwinds on its next per-chunk poll.
                      if (_cancelToken != null)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Tooltip(message: AppLocalizations.of(context)!.cancel, child: InkWell(
                            onTap: _cancelToken!.isCancelled
                                ? null
                                : () {
                                    _cancelToken?.cancel();
                                    setState(() {
                                      _transferLabel =
                                          AppLocalizations.of(context)!
                                              .sftpCancelling;
                                    });
                                  },
                            borderRadius: BorderRadius.circular(12),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                LucideIcons.xCircle,
                                size: 20,
                                color: _cancelToken!.isCancelled
                                    ? AppColors.textSecondary
                                    : AppColors.error,
                              ),
                            ),
                          )),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _transferProgress,
                      color: AppColors.brandOrange,
                      backgroundColor:
                          AppColors.brandOrange.withValues(alpha: 0.1),
                      minHeight: 6,
                    ),
                  ),
                ],
              ),
            ),

          // File list
          Expanded(child: _buildBody(displayed)),

          // Footer: file/folder count. Its words above the phone's gesture
          // bar, its colour under it, as the phone's tab bar has them
          // (ZestBottomNav); they sat under the bar (found on a Pixel 3a, 5
          // November 2026).
          if (!_isLoading && _error == null)
            Container(
              key: const ValueKey('sftp-browser-footer'),
              width: double.infinity,
              color: AppColors.surfaceContainer,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text(
                    _buildFooterText(dirCount, fileCount),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
      ),
    );
  }

  String _buildFooterText(int dirCount, int fileCount) {
    final l10n = AppLocalizations.of(context)!;
    final parts = <String>[];
    if (dirCount > 0) {
      parts.add(l10n.sftpFolderCount(dirCount));
    }
    if (fileCount > 0) {
      parts.add(l10n.sftpFileCount(fileCount));
    }
    if (parts.isEmpty) return l10n.sftpEmptyDirectory;
    return parts.join(', ');
  }

  String _sortLabel(_SortBy sort) {
    final l10n = AppLocalizations.of(context)!;
    return switch (sort) {
      _SortBy.name => l10n.sftpSortName,
      _SortBy.size => l10n.sftpSortSize,
      _SortBy.date => l10n.sftpSortDateModified,
      _SortBy.type => l10n.sftpSortType,
    };
  }

  Widget _buildBody(List<SftpEntry> displayed) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.alertCircle, size: 48, color: AppColors.error),
                const SizedBox(height: 16),
                Text(_error!, key: const ValueKey('sftp-browser-error'), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                FilledButton.icon(
                  onPressed: _retry,
                  icon: const Icon(LucideIcons.refreshCw),
                  label: Text(AppLocalizations.of(context)!.retry),
                ),
                if (_errorReport != null) ...[
                  const SizedBox(height: 16),
                  ErrorDetailsPanel(report: _errorReport!),
                ],
              ],
            ),
          ),
        ),
      );
    }

    if (displayed.isEmpty) {
      final l10n = AppLocalizations.of(context)!;
      return ZestEmptyState(
        icon: LucideIcons.folderOpen,
        title: l10n.sftpEmptyDirectory,
        message: l10n.sftpEmptyBrowserHint,
      );
    }

    return RefreshIndicator(
      onRefresh: _loadDirectory,
      child: ListView.builder(
        itemCount: displayed.length,
        itemBuilder: (context, index) {
          final entry = displayed[index];
          return _buildEntryTile(entry);
        },
      ),
    );
  }

  Widget _buildEntryTile(SftpEntry entry) {
    // Build subtitle with modified time
    String subtitle;
    if (entry.isDirectory) {
      subtitle = entry.permissions ??
          AppLocalizations.of(context)!.sftpPropertyDirectory;
      if (entry.modifiedAt != null) {
        subtitle += '  \u00b7  ${_formatModifiedAt(entry.modifiedAt!)}';
      }
    } else {
      subtitle = entry.formattedSize;
      if (entry.permissions != null) {
        subtitle += '  ${entry.permissions}';
      }
      if (entry.modifiedAt != null) {
        subtitle += '  \u00b7  ${_formatModifiedAt(entry.modifiedAt!)}';
      }
    }

    final isSelected = _selectedEntries.contains(entry.path);

    return ListTile(
      leading: _selectMode
          ? Checkbox(
              value: isSelected,
              onChanged: (v) => _toggleSelection(entry),
              activeColor: AppColors.brandOrange,
            )
          : Icon(
              entry.isDirectory ? LucideIcons.folder : sftpFileIcon(entry.name),
              color: entry.isDirectory
                  ? AppColors.accentInk
                  : _fileIconColor(entry.name),
            ),
      title: Text(_shownName(entry.name), overflow: TextOverflow.ellipsis),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
        overflow: TextOverflow.ellipsis,
      ),
      selected: isSelected && _selectMode,
      selectedTileColor: AppColors.brandOrange.withValues(alpha: 0.08),
      onTap: _selectMode
          ? () => _toggleSelection(entry)
          : entry.isDirectory
              ? () => _navigateTo(entry.path)
              : entry.isSymlink
                  ? () => _openLink(entry)
                  : () => _showFileActions(entry),
      // A folder's tap opens it, so its actions (copy its path, rename it,
      // its properties, delete it) are here; they were out of reach.
      trailing: _selectMode
          ? null
          : IconButton(
              icon: const Icon(LucideIcons.moreVertical),
              tooltip: AppLocalizations.of(context)!.zestCommonMoreActions,
              onPressed: () => _showFileActions(entry),
            ),
      onLongPress: _selectMode
          ? null
          : () {
              // Long press enters select mode
              setState(() {
                _selectMode = true;
                _selectedEntries.add(entry.path);
              });
            },
    );
  }

  /// A link opens where it points: one to a folder like a folder (`bin`, a
  /// link to `usr/bin`), anything else, or one that leads nowhere, with a
  /// file's actions. A listing reports a link as a link, never as what it
  /// points at (so recursive work never follows one), and a tap on a link to
  /// a folder showed a file's actions (found on an Android
  /// emulator).
  Future<void> _openLink(SftpEntry entry) async {
    final target = await widget.sftp.statOrNull(entry.path);
    if (!mounted) return;
    if (target?.isDirectory == true) {
      _navigateTo(entry.path);
    } else {
      _showFileActions(entry);
    }
  }

  /// Returns a color hint based on file type.
  Color _fileIconColor(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'key' || 'pem' || 'pub' || 'ppk' => AppColors.warning,
      'sh' || 'bash' || 'py' || 'js' || 'ts' || 'dart' || 'go' ||
      'rs' || 'rb' || 'php' || 'java' || 'c' || 'cpp' || 'h' =>
        AppColors.fileTypeCode,
      'conf' || 'cfg' || 'ini' || 'yml' || 'yaml' || 'json' || 'xml' ||
      'toml' || 'env' =>
        AppColors.fileTypeConfig,
      'log' => AppColors.textSecondary,
      'zip' || 'tar' || 'gz' || 'bz2' || 'xz' || '7z' || 'rar' =>
        AppColors.orangeLight,
      'jpg' || 'jpeg' || 'png' || 'gif' || 'bmp' || 'svg' || 'webp' =>
        AppColors.fileTypeImage,
      _ => AppColors.textSecondary,
    };
  }

  String _formatModifiedAt(DateTime dt) {
    final now = DateTime.now();
    final diff = now.difference(dt);

    if (diff.inDays == 0) {
      return ref.read(sftpTimeFormatProvider).time(dt);
    }
    // Month names in the app language ("Sep 25" / "Sep 25, 2025" in English).
    final locale = AppLocalizations.of(context)!.localeName;
    if (diff.inDays < 365) {
      return DateFormat.MMMd(locale).format(dt);
    }
    return DateFormat.yMMMd(locale).format(dt);
  }

  /// When the file at [path] was changed last on the host, or null where the
  /// host does not say.
  Future<DateTime?> _changedLast(String path) async {
    final seconds = (await widget.sftp.statOrNull(path))?.modifyTime;
    return seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000);
  }

  Future<void> _openInEditor(SftpEntry entry) async {
    if (_guardBusy()) return;
    // The in-app editor loads the whole file into memory; refuse anything
    // large so a misclick on a huge file can't OOM-crash the app.
    const maxEditableBytes = 4 * 1024 * 1024; // 4 MB
    if (entry.size > maxEditableBytes) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!
            .sftpFileTooLargeForEditor(entry.formattedSize),
        isError: true,
      );
      return;
    }
    setState(() {
      _isTransferring = true;
      _transferLabel = AppLocalizations.of(context)!.sftpOpening(_shownName(entry.name));
      _transferProgress = 0;
    });

    try {
      // When the file was changed last, for the editor, which asks before it
      // saves over a file that has changed since. Asked of the host, since
      // the list may be older than the file, and before the file is read: a
      // change between the two is then asked about once too often, and none
      // is missed.
      final heldAsOf = await _changedLast(entry.path);
      final data = await widget.sftp.downloadFile(
        entry.path,
        // Enforce the 4 MB editor ceiling against bytes actually received, not
        // just the READDIR size the gate above checked (which a server can lie
        // about to slip a huge file through and OOM the editor).
        maxBytes: maxEditableBytes,
        onProgress: (transferred, total) {
          if (total > 0 && mounted) {
            setState(() => _transferProgress = transferred / total);
          }
        },
      );

      if (mounted) {
        setState(() => _isTransferring = false);
        // The editor's tabs (3.4): read in the file's own encoding (one that
        // is not UTF-8 opens in the closest match with a notice, where it
        // was refused), its line endings kept, and saved through the same
        // upload, after a look at the file's hash on the host.
        unawaited(openInEditor(
          context,
          SftpEditorSource(
            service: widget.sftp,
            path: entry.path,
            hostLabel: widget.connectionLabel,
            host: widget.sessionId == null ? null : editorHostOfSession(ref, widget.sessionId!),
            // The list behind the editor shows the file as it is now.
            onSaved: () {
              if (mounted) unawaited(_loadDirectory());
            },
            reconnectWith: () async {
              try {
                await widget.sftp.open();
                return widget.sftp;
              } catch (_) {
                return null;
              }
            },
          ),
          bytes: data,
          version: FileVersion(modified: heldAsOf, size: data.length, sha256: sha256Of(data)),
        ));
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isTransferring = false);
        // Why, in the app's language, with what was thrown to copy (it said
        // to try again, whatever it was).
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!
              .sftpNotOpened(sftpErrorMessage(e, name: _shownName(entry.name), op: SftpOp.download)),
          isError: true,
          details: '$e',
        );
      }
    }
  }

  void _showFileActions(SftpEntry entry) {
    final parentContext = context;
    showModalBottomSheet(
      context: context,
      // As tall as its actions, and scrolling where the screen is shorter: a
      // sheet held to the default nine sixteenths of a phone cut off
      // Properties and Delete (found on an emulator,
      // a phone 393 by 807).
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with file name + size
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Icon(
                    entry.isDirectory
                        ? LucideIcons.folder
                        : sftpFileIcon(entry.name),
                    color: entry.isDirectory
                        ? AppColors.accentInk
                        : _fileIconColor(entry.name),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _shownName(entry.name),
                          style: const TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!entry.isDirectory)
                          Text(
                            entry.formattedSize,
                            style: TextStyle(
                              fontSize: 12,
                              color: AppColors.textSecondary,
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),

            if (!entry.isDirectory) ...[
              ListTile(
                leading: const Icon(LucideIcons.fileEdit),
                title: Text(AppLocalizations.of(parentContext)!.sftpEditInEditor),
                onTap: () {
                  Navigator.pop(context);
                  _openInEditor(entry);
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.download),
                title: Text(AppLocalizations.of(parentContext)!.sftpDownload),
                onTap: () {
                  Navigator.pop(context);
                  _downloadFile(entry);
                },
              ),
              ListTile(
                leading: const Icon(LucideIcons.share2),
                title: Text(AppLocalizations.of(parentContext)!.sftpDownloadAndShare),
                onTap: () {
                  Navigator.pop(context);
                  _downloadAndShareFile(entry);
                },
              ),
            ],
            ListTile(
              leading: const Icon(LucideIcons.copy),
              title: Text(AppLocalizations.of(parentContext)!.sftpCopyPath),
              onTap: () async {
                Navigator.pop(context);
                // A real remote path goes to the clipboard: reveal gate
                // (spec 5). The toast paints the display form.
                if (!await confirmRevealWhileRecording(parentContext, ref)) {
                  return;
                }
                if (!parentContext.mounted) return;
                await Clipboard.setData(ClipboardData(text: entry.path));
                if (!parentContext.mounted) return;
                ScaffoldMessenger.of(parentContext).showSnackBar(
                  SnackBar(
                    content: Text(AppLocalizations.of(parentContext)!
                        .sftpCopiedPath(
                            Redactable.freeText(entry.path).display)),
                    backgroundColor: AppColors.surfaceLight,
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.pencil),
              title: Text(AppLocalizations.of(parentContext)!.sftpRename),
              onTap: () {
                Navigator.pop(context);
                _renameEntry(entry);
              },
            ),
            ListTile(
              leading: const Icon(LucideIcons.info),
              title: Text(AppLocalizations.of(parentContext)!.sftpProperties),
              onTap: () {
                Navigator.pop(context);
                _showProperties(entry);
              },
            ),
            ListTile(
              leading: Icon(LucideIcons.trash2, color: AppColors.error),
              title: Text(AppLocalizations.of(parentContext)!.delete,
                  style: TextStyle(color: AppColors.error)),
              onTap: () {
                Navigator.pop(context);
                _deleteEntry(entry);
              },
            ),
          ],
          ),
        ),
      ),
    );
  }

  void _showProperties(SftpEntry entry) {
    final l10n = AppLocalizations.of(context)!;
    // The shell, as every dialog (the dialog rules, 3.4): Close in the footer.
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(builder: (context) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: entry.isDirectory ? LucideIcons.folder : LucideIcons.file,
        title: l10n.sftpProperties,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _propertyRow(l10n.sftpPropertyName, _shownName(entry.name)),
            _propertyRow(l10n.sftpPropertyPath, entry.path),
            _propertyRow(l10n.sftpPropertyType, entry.isDirectory ? l10n.sftpPropertyDirectory : l10n.sftpPropertyFile),
            if (!entry.isDirectory) _propertyRow(l10n.sftpPropertySize, entry.formattedSize),
            if (entry.permissions != null)
              _propertyRow(l10n.sftpPropertyPermissions, entry.permissions!),
            if (entry.modifiedAt != null)
              _propertyRow(
                l10n.sftpPropertyModified,
                ref.read(sftpTimeFormatProvider).localeDateTime(entry.modifiedAt!),
              ),
          ],
        ),
        primaryAction: (label: l10n.close, icon: null, onPressed: () => Navigator.pop(context)),
        autofocusPrimary: true,
      )),
    );
  }

  Widget _propertyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              label,
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 13)),
          ),
        ],
      ),
    );
  }

  /// Validates that a file or directory name does not contain path traversal
  /// characters or other dangerous values.
  bool _isValidFileName(String name) {
    if (name.isEmpty) return false;
    if (name.contains('/') || name.contains('\\')) return false;
    if (name == '.' || name == '..') return false;
    if (name.contains('\x00')) return false;
    return true;
  }

  Future<void> _downloadAndShareFile(SftpEntry entry) async {
    if (_guardBusy()) return;
    final token = TransferCancelToken();
    setState(() {
      _isTransferring = true;
      _cancelToken = token;
      _transferLabel = AppLocalizations.of(context)!.sftpDownloadingForShare(_shownName(entry.name));
      _transferProgress = 0;
    });

    // Stage into a folder of its own (as every share is) so we can delete the
    // WHOLE thing in finally - the previous code wrote into the shared app
    // cache and never removed the file, leaking every shared file (including
    // sensitive ones) into cache until the OS eventually reclaimed it. Made
    // in the try, so a folder that cannot be made ends the share as any
    // failure does (made before it, it left the screen busy for good).
    Directory? shareDir;
    try {
      shareDir = await ConnectionShareService.newShareFolder();
      // Stream straight to the temp file instead of buffering the whole file
      // in memory - sharing a large file used to OOM-crash the app a few
      // hundred MB in.
      // The server's name, made one safe name here: no folder of its own,
      // no control character, no direction override, not too long
      // ([safeChildName], as a computer's transfers make it).
      final safeName = safeChildName(entry.name);
      final file = File('${shareDir.path}/$safeName');
      await widget.sftp.downloadFileToPath(
        entry.path,
        file.path,
        cancelToken: token,
        onProgress: (transferred, total) {
          if (total > 0 && mounted) {
            setState(() {
              _transferProgress = transferred / total;
            });
          }
        },
      );

      final downloadedBytes = await file.length();
      if (mounted) {
        _haptic();
        // Show feedback BEFORE share sheet so the user knows the
        // download completed even if they dismiss the share sheet.
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!
              .sftpDownloadedChooseTarget(safeName, formatByteSize(downloadedBytes)),
          isSuccess: true,
          duration: const Duration(seconds: 4),
        );
        await Share.shareXFiles([XFile(file.path)]);
      }
    } on TransferCancelledException {
      if (mounted) {
        _haptic();
        showTopSnackBar(
            context, AppLocalizations.of(context)!.sftpDownloadCancelled);
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          AppLocalizations.of(context)!
              .sftpNotShared(sftpErrorMessage(e, name: _shownName(entry.name), op: SftpOp.download)),
          isError: true,
          details: '$e',
        );
      }
    } finally {
      // Share.shareXFiles has returned (the sheet was dismissed or completed),
      // so the staged file is no longer needed - delete the whole temp dir.
      // Best-effort: a failure here must never mask the share result.
      try {
        if (shareDir != null && await shareDir.exists()) await shareDir.delete(recursive: true);
      } catch (_) {}
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _cancelToken = null;
        });
      }
    }
  }

  /// Where a download is saved, made where it is not there yet
  /// ([downloadSaveFolder]: on an iPhone or an iPad the app's Documents,
  /// which the Files app shows).
  Future<Directory> _getDownloadDirectory() => downloadSaveFolder();

  /// How a message names the folder [dir]: Android's shared Download folder
  /// and the Files app's ZestSSH folder (an iPhone shows no path) by the
  /// names the device gives them, any other by its path.
  String _placeName(AppLocalizations l10n, Directory dir) {
    if (dir.path == androidDownloadFolder) return l10n.sftpPlaceDownloads;
    if (downloadsGoToIosFiles) return l10n.sftpPlaceIosFiles;
    return dir.path;
  }

  /// True (and shows a note) when a transfer is already running. This screen
  /// tracks a SINGLE in-flight transfer (one _cancelToken + one progress
  /// bar), so a second one started from the row sheet or FAB would clobber
  /// the first's cancel token and progress - refuse instead.
  bool _guardBusy() {
    if (_isTransferring) {
      showTopSnackBar(
          context, AppLocalizations.of(context)!.sftpTransferAlreadyRunning);
      return true;
    }
    return false;
  }

  Future<void> _downloadFile(SftpEntry entry) async {
    if (_guardBusy()) return;
    final l10n = AppLocalizations.of(context)!;
    final dir = await _getDownloadDirectory();
    // The server's name, made one safe name here ([safeChildName]).
    final safeName = safeChildName(entry.name);
    var localPath = '${dir.path}/$safeName';

    // Overwrite guard: if the local destination already exists, ask the
    // user before clobbering it (Overwrite / Keep both / Newer / Skip).
    final destFile = File(localPath);
    if (await destFile.exists()) {
      final destSize = await destFile.length();
      final destMtime = await destFile.lastModified();
      if (!mounted) return;
      final res = await OverwriteConflictDialog.show(
        context,
        timeFormat: ref.read(sftpTimeFormatProvider),
        source: OverwriteFileInfo(
          path: entry.name,
          size: entry.size,
          modified: entry.modifiedAt,
        ),
        destination: OverwriteFileInfo(
          path: localPath,
          size: destSize,
          modified: destMtime,
        ),
        sourceVerb: l10n.sftpVerbDownloading,
      );
      switch (res.action) {
        case OverwriteAction.cancel:
        case OverwriteAction.skip:
          return;
        case OverwriteAction.newer:
          if (entry.modifiedAt == null ||
              !entry.modifiedAt!.isAfter(destMtime)) {
            return; // local copy is newer or same → nothing to do
          }
        case OverwriteAction.rename:
          final newName = await uniqueRenameFor(
            safeName,
            exists: (c) => File('${dir.path}/$c').exists(),
          );
          localPath = '${dir.path}/$newName';
        case OverwriteAction.overwrite:
          break;
      }
    }

    if (!mounted) return;
    final token = TransferCancelToken();
    setState(() {
      _isTransferring = true;
      _cancelToken = token;
      _transferLabel = l10n.sftpDownloading(_shownName(entry.name));
      _transferProgress = 0;
    });

    try {
      // Stream directly to disk - no full-file memory buffering
      await widget.sftp.downloadFileToPath(
        entry.path,
        localPath,
        cancelToken: token,
        onProgress: (transferred, total) {
          if (total > 0 && mounted) {
            setState(() {
              _transferProgress = transferred / total;
            });
          }
        },
      );

      if (mounted) {
        _haptic();
        // Android's public Download folder and the Files app's folder, named
        // the way the device shows them; any other (the app's own folder on
        // Android 8 to 10, a computer's) by its path.
        final location = _placeName(l10n, dir);
        showTopSnackBar(
          context,
          l10n.sftpDownloadedTo(_shownName(entry.name), location),
          isSuccess: true,
        );
      }
    } on TransferCancelledException {
      if (mounted) {
        _haptic();
        showTopSnackBar(context, l10n.sftpDownloadCancelled);
      }
    } catch (e) {
      if (mounted && isPermissionDenied(e)) {
        // Retry with sudo (3.4): `sudo cat` into the same file.
        _offerSudo([SudoDownload(entry.path, localPath)], shownPath: entry.path, details: '$e', relist: false);
      } else if (mounted) {
        showTopSnackBar(
          context,
          l10n.sftpNotDownloaded(sftpErrorMessage(e, name: _shownName(entry.name), op: SftpOp.download)),
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _cancelToken = null;
        });
      }
    }
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'select':
        setState(() => _selectMode = true);
      case 'upload':
        _uploadFile();
      case 'mkdir':
        _createDirectory();
      case 'goto':
        _showGoToPathDialog();
      case 'terminal':
        _goToTerminalFolder();
      case 'hidden':
        // Shows or hides dotfiles in the setting itself, as a computer's
        // menu does; system names stay hidden either way.
        ref.read(sftpHiddenLevelProvider.notifier).setLevel(
            _dotfilesShown ? SftpHiddenLevel.hiddenAndSystem : SftpHiddenLevel.systemOnly);
    }
  }

  void _exitSelectMode() {
    setState(() {
      _selectMode = false;
      _selectedEntries.clear();
    });
  }

  void _toggleSelection(SftpEntry entry) {
    setState(() {
      if (_selectedEntries.contains(entry.path)) {
        _selectedEntries.remove(entry.path);
        if (_selectedEntries.isEmpty) _selectMode = false;
      } else {
        _selectedEntries.add(entry.path);
      }
    });
  }

  Future<void> _downloadSelected() async {
    final selected = _entries
        .where((e) => _selectedEntries.contains(e.path) && !e.isDirectory)
        .toList();
    if (selected.isEmpty) return;

    _exitSelectMode();

    final l10n = AppLocalizations.of(context)!;
    final dir = await _getDownloadDirectory();

    // Resolve name conflicts up front so the whole batch's prompts are
    // answered before any bytes move (not interrupted mid-transfer).
    final jobs = <({SftpEntry entry, String localPath})>[];
    OverwriteAction? applyToAll;
    // Pre-count conflicts (cheap local existence checks) so the dialog shows
    // an honest "N of M" counter.
    var conflictTotal = 0;
    for (final entry in selected) {
      if (await File('${dir.path}/${safeChildName(entry.name)}').exists()) {
        conflictTotal++;
      }
    }
    var conflictSeen = 0;
    // The local paths this batch has given out already. Two files of the
    // server can come to one local name (safeChildName trims a name and cuts
    // it at 200 characters, a phone's folders take `A` and `a` for one name,
    // Keep both can pick the name of a file further on), and nothing is on
    // the disk yet to show it: the second replaced the first (found in a
    // code review). Such a file keeps both, under a name of its own.
    final taken = <String>{};
    Future<bool> inUse(String name) async =>
        taken.contains('${dir.path}/$name'.toLowerCase()) ||
        await File('${dir.path}/$name').exists();
    for (final entry in selected) {
      final safeName = safeChildName(entry.name);
      var localPath = '${dir.path}/$safeName';
      final destFile = File(localPath);
      if (taken.contains(localPath.toLowerCase())) {
        localPath = '${dir.path}/${await uniqueRenameFor(safeName, exists: inUse)}';
      } else if (await destFile.exists()) {
        var action = applyToAll;
        if (action == null) {
          final destSize = await destFile.length();
          final destMtime = await destFile.lastModified();
          if (!mounted) return;
          final res = await OverwriteConflictDialog.show(
            context,
            timeFormat: ref.read(sftpTimeFormatProvider),
            source: OverwriteFileInfo(
              path: entry.name,
              size: entry.size,
              modified: entry.modifiedAt,
            ),
            destination: OverwriteFileInfo(
              path: localPath,
              size: destSize,
              modified: destMtime,
            ),
            index: ++conflictSeen,
            total: conflictTotal,
            sourceVerb: l10n.sftpVerbDownloading,
          );
          action = res.action;
          if (res.applyToAll) applyToAll = action;
        }
        switch (action) {
          case OverwriteAction.cancel:
            return; // abort the whole batch
          case OverwriteAction.skip:
            continue;
          case OverwriteAction.newer:
            final localMtime = await destFile.lastModified();
            if (entry.modifiedAt == null ||
                !entry.modifiedAt!.isAfter(localMtime)) {
              continue;
            }
          case OverwriteAction.rename:
            final newName = await uniqueRenameFor(safeName, exists: inUse);
            localPath = '${dir.path}/$newName';
          case OverwriteAction.overwrite:
            break;
        }
      }
      taken.add(localPath.toLowerCase());
      jobs.add((entry: entry, localPath: localPath));
    }

    if (jobs.isEmpty || !mounted) return;

    final token = TransferCancelToken();
    setState(() {
      _isTransferring = true;
      _cancelToken = token;
      _transferLabel = l10n.sftpDownloadingMultiple(jobs.length);
      _transferProgress = 0;
    });

    var completed = 0;
    String? current;
    try {
      for (final job in jobs) {
        if (!mounted) break;
        current = job.entry.name;
        setState(() {
          _transferLabel = l10n.sftpDownloadingProgress(
              _shownName(job.entry.name), completed + 1, jobs.length);
        });
        await widget.sftp.downloadFileToPath(
          job.entry.path,
          job.localPath,
          cancelToken: token,
          onProgress: (transferred, total) {
            if (total > 0 && mounted) {
              setState(() {
                _transferProgress =
                    (completed + transferred / total) / jobs.length;
              });
            }
          },
        );
        completed++;
      }

      if (mounted) {
        _haptic();
        final location = _placeName(l10n, dir);
        showTopSnackBar(
          context,
          l10n.sftpDownloadedMultiple(completed, location),
          isSuccess: true,
        );
      }
    } on TransferCancelledException {
      if (mounted) {
        _haptic();
        showTopSnackBar(
          context,
          completed > 0
              ? l10n.sftpCancelledDownloaded(completed, jobs.length)
              : l10n.sftpDownloadCancelled,
        );
      }
    } catch (e) {
      if (mounted && isPermissionDenied(e)) {
        // Retry with sudo (3.4): the one refused and those not tried yet,
        // with one password.
        final left = jobs.skip(completed).toList();
        _offerSudo([for (final j in left) SudoDownload(j.entry.path, j.localPath)],
            shownPath: left.first.entry.path, details: '$e', relist: false);
      } else if (mounted) {
        showTopSnackBar(
          context,
          l10n.sftpNotDownloaded(sftpErrorMessage(e, name: current, op: SftpOp.download)),
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _cancelToken = null;
        });
      }
    }
  }

  Future<void> _deleteSelected() async {
    final toDelete = _entries.where((e) => _selectedEntries.contains(e.path)).toList();
    if (await _delete(toDelete)) _exitSelectMode();
  }

  /// Deletes [targets] once asked, as a computer does: where Settings holds
  /// a remote delete (Delete hold), it waits that long with Undo, its rows
  /// gone from the list, and is made once its time is out, the browser is
  /// left or the app goes to the background (a phone deleted at once, though
  /// its Settings offered the hold and promised Undo). True where it was
  /// asked for.
  Future<bool> _delete(List<SftpEntry> targets) async {
    if (targets.isEmpty) return false;
    final l10n = AppLocalizations.of(context)!;
    final holdSeconds = ref.read(sftpDeleteHoldSecondsProvider);
    final label = targets.length == 1 ? '"${targets.first.name}"' : l10n.sftpItemCount(targets.length);
    // The host and the path, as a computer names them (the host masked
    // while the screen is recorded).
    final host = Redactable.host(widget.connectionLabel).display;
    final where = targets.length == 1 ? targets.first.path : _currentPath;
    final target = targets.any((t) => t.isDirectory) ? l10n.sftpTargetAndContents('$host $where') : '$host $where';
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.sftpDeleteConfirmTitle(label),
      body: holdSeconds > 0
          ? l10n.sftpDeleteConfirmRemote(target, holdSeconds)
          : l10n.sftpDeleteConfirmRemoteNoHold(target),
      confirmLabel: l10n.delete,
    );
    if (confirmed != true || !mounted) return false;

    final key = phoneSftpHoldKey(widget.sftp);
    final opId = 'del_${DateTime.now().microsecondsSinceEpoch}';
    final deadline = DateTime.now().add(Duration(seconds: holdSeconds));
    ref.read(sftpTransfersProvider.notifier).add(TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.delete,
      title: targets.length == 1 ? l10n.sftpDeletingOne(_shownName(targets.first.name)) : l10n.sftpDeletingMany(targets.length),
      subtitle: where,
      status: TransferStatus.holding,
    )..holdUntil = deadline);
    final paths = {for (final t in targets) t.path};
    setState(() => _entries.removeWhere((e) => paths.contains(e.path)));
    final notices = ref.read(notificationCenterProvider.notifier);
    _holds.hold(DeleteHold(
      opId: opId,
      sessionId: key,
      hostLabel: widget.connectionLabel,
      source: RemotePaneFileSource(service: widget.sftp, sourceId: key),
      targets: targets,
      deadline: deadline,
      connectionLostText: l10n.sftpDeleteConnectionLost,
      skippedText: l10n.sftpDeleteSkippedChanged,
      failedText: l10n.sftpDeleteItemsFailed,
      onRefresh: () {
        if (mounted) unawaited(_loadDirectory());
      },
      onDone: (outcome) => _sayDeleted(targets, outcome, notices, l10n),
    ));
    if (holdSeconds <= 0) {
      unawaited(_holds.commitNow(opId));
    } else {
      showTopSnackBar(
        context,
        l10n.sftpDeleteHolding(holdSeconds),
        duration: Duration(seconds: holdSeconds),
        actionLabel: l10n.sftpDeleteUndo,
        onAction: () => _holds.undo(opId),
      );
    }
    return true;
  }

  /// What a delete did: said here while the browser is open; once it is
  /// gone, among the app's notices where it failed. One that failed says
  /// why; several, how many were deleted; what was thrown for each is in the
  /// details (no name: a report names none).
  void _sayDeleted(List<SftpEntry> targets, DeleteOutcome outcome, NotificationCenter notices, AppLocalizations l10n) {
    if (outcome.cancelled) return;
    final failed = outcome.failures;
    final deleted = outcome.connectionLost ? 0 : targets.length - failed.length;
    final details = [for (final f in failed) '${f.error}'].join('\n');
    final String said;
    if (outcome.connectionLost) {
      said = l10n.sftpDeleteConnectionLost;
    } else if (failed.isEmpty) {
      said = targets.length == 1 ? l10n.sftpDeletedOne(_shownName(targets.first.name)) : l10n.sftpDeletedCount(deleted, targets.length);
    } else if (failed.length == 1 && deleted == 0) {
      said = l10n.sftpNotDeleted(sftpErrorMessage(failed.single.error, name: failed.single.name, op: SftpOp.delete));
    } else {
      said = l10n.sftpDeletedCount(deleted, targets.length);
    }
    final ok = failed.isEmpty && !outcome.connectionLost;
    // What the host refused for want of permission: Retry with sudo (3.4),
    // the delete having been asked about already.
    final byName = {for (final t in targets) t.name: t};
    final refused = [
      for (final f in failed)
        if (!outcome.connectionLost && isPermissionDenied(f.error) && byName[f.name] != null) byName[f.name]!,
    ];
    if (mounted && refused.isNotEmpty) {
      // Where some went, how many, with Retry with sudo for the rest.
      _offerSudo([for (final t in refused) SudoDelete(t.path, folder: t.isDirectory)],
          shownPath: refused.first.path,
          details: details,
          said: deleted > 0 ? l10n.sftpDeletedCount(deleted, targets.length) : null);
      return;
    }
    if (mounted) {
      showTopSnackBar(context, said,
          isSuccess: ok, isError: !ok && deleted == 0, isWarning: !ok && deleted > 0, details: ok ? null : details);
    } else if (!ok) {
      notices.error(said, details: details);
    }
  }

  /// The folder the session's terminal said it is in (4.0):
  /// opened where the host has it; where the terminal said none,
  /// how to make the shell say it; where the host has no such folder (the
  /// terminal is on another computer, after ssh from this one), that.
  Future<void> _goToTerminalFolder() async {
    final id = widget.sessionId;
    if (id == null) return;
    final folder = ref.read(terminalFolderProvider(id));
    if (folder == null) {
      await showTerminalFolderHelp(context, ref);
      return;
    }
    if (folder == _currentPath) return;
    final there = await widget.sftp.statOrNull(folder);
    if (!mounted) return;
    if (there == null || !there.isDirectory) {
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(
        context,
        l10n.sftpTerminalFolderMissing(
            Redactable.path(folder).displayIn(ref), Redactable.host(widget.connectionLabel).displayIn(ref)),
        isWarning: true,
      );
      return;
    }
    _navigateTo(folder);
  }

  Future<void> _showGoToPathDialog() async {
    final l10n = AppLocalizations.of(context)!;
    final path = await showZestInputDialog(
      context: context,
      title: l10n.sftpGoToPath,
      icon: LucideIcons.folderTree,
      fieldLabel: l10n.sftpRemotePath,
      hintText: '/home/user/...',
      initialValue: _currentPath,
      confirmLabel: l10n.sftpGo,
      cancelLabel: l10n.cancel,
      validator: (v) => v.trim().isEmpty ? l10n.sftpNameRequired : null,
    );
    if (path == null || path.trim().isEmpty) return;
    _navigateTo(path.trim());
  }

  Future<void> _uploadFile() async {
    if (_guardBusy()) return;
    // withData: false - avoids loading entire file into memory.
    // allowMultiple - pick several files in one go (common on mobile
    // when sending a batch of photos / logs).
    final result = await FilePicker.platform.pickFiles(
      withData: false,
      allowMultiple: true,
    );
    if (result == null || result.files.isEmpty) return;
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final picked = result.files.where((f) => f.path != null).toList();
    if (picked.isEmpty) return;

    // Resolve remote-side name conflicts up front (Overwrite / Keep both
    // / Newer / Skip), so all prompts happen before any bytes move.
    final jobs = <({String localPath, String remotePath, String name})>[];
    OverwriteAction? applyToAll;
    // Pre-count remote conflicts so the dialog shows an honest "N of M".
    var conflictTotal = 0;
    for (final file in picked) {
      if (await widget.sftp.statOrNull(_joinRemote(_currentPath, file.name)) !=
          null) {
        conflictTotal++;
      }
    }
    var conflictSeen = 0;
    // The remote paths this batch has given out already: two files picked
    // from different folders can share a name, and the first is not on the
    // server yet to be found, so the second replaced it. Such a file keeps
    // both, under a name of its own (as a download's batch does).
    final taken = <String>{};
    Future<bool> inUse(String name) async {
      final path = _joinRemote(_currentPath, name);
      return taken.contains(path.toLowerCase()) || await widget.sftp.statOrNull(path) != null;
    }
    for (final file in picked) {
      final name = file.name;
      var remotePath = _joinRemote(_currentPath, name);
      final existing = await widget.sftp.statOrNull(remotePath);
      if (taken.contains(remotePath.toLowerCase())) {
        remotePath = _joinRemote(_currentPath, await uniqueRenameFor(name, exists: inUse));
      } else if (existing != null) {
        var action = applyToAll;
        if (action == null) {
          final remoteMtime = existing.modifyTime != null
              ? DateTime.fromMillisecondsSinceEpoch(existing.modifyTime! * 1000)
              : null;
          if (!mounted) return;
          final res = await OverwriteConflictDialog.show(
            context,
            timeFormat: ref.read(sftpTimeFormatProvider),
            source: OverwriteFileInfo(path: name, size: file.size),
            destination: OverwriteFileInfo(
              path: remotePath,
              size: existing.size,
              modified: remoteMtime,
            ),
            index: ++conflictSeen,
            total: conflictTotal,
            sourceVerb: l10n.sftpVerbUploading,
          );
          action = res.action;
          if (res.applyToAll) applyToAll = action;
        }
        switch (action) {
          case OverwriteAction.cancel:
            return; // abort the whole batch
          case OverwriteAction.skip:
            continue;
          case OverwriteAction.newer:
            // Compare local mtime against the remote's; skip unless the
            // local file is strictly newer.
            final localMtime = await File(file.path!).lastModified();
            final remoteMtime = existing.modifyTime != null
                ? DateTime.fromMillisecondsSinceEpoch(
                    existing.modifyTime! * 1000)
                : null;
            if (remoteMtime != null && !localMtime.isAfter(remoteMtime)) {
              continue;
            }
          case OverwriteAction.rename:
            final newName = await uniqueRenameFor(name, exists: inUse);
            remotePath = _joinRemote(_currentPath, newName);
          case OverwriteAction.overwrite:
            break;
        }
      }
      taken.add(remotePath.toLowerCase());
      jobs.add((localPath: file.path!, remotePath: remotePath, name: name));
    }

    if (jobs.isEmpty || !mounted) return;

    final token = TransferCancelToken();
    setState(() {
      _isTransferring = true;
      _cancelToken = token;
      _transferProgress = 0;
      _transferLabel = jobs.length == 1
          ? l10n.sftpUploading(jobs.first.name)
          : l10n.sftpUploadingFiles(jobs.length);
    });

    var completed = 0;
    String? current;
    try {
      for (final job in jobs) {
        if (!mounted) break;
        current = job.name;
        setState(() {
          _transferLabel = jobs.length == 1
              ? l10n.sftpUploading(job.name)
              : l10n.sftpUploadingProgress(
                  job.name, completed + 1, jobs.length);
        });
        // Stream from disk - no full-file memory buffering
        await widget.sftp.uploadFileFromPath(
          job.localPath,
          job.remotePath,
          cancelToken: token,
          onProgress: (transferred, total) {
            if (total > 0 && mounted) {
              setState(() {
                _transferProgress =
                    (completed + transferred / total) / jobs.length;
              });
            }
          },
        );
        completed++;
      }

      await _loadDirectory();

      if (mounted) {
        _haptic();
        showTopSnackBar(
          context,
          jobs.length == 1
              ? l10n.sftpUploaded(jobs.first.name)
              : l10n.sftpUploadedFiles(completed),
          isSuccess: true,
        );
      }
    } on TransferCancelledException {
      // Partial remote file already removed by the service layer.
      await _loadDirectory();
      if (mounted) {
        _haptic();
        showTopSnackBar(
          context,
          completed > 0
              ? l10n.sftpCancelledUploaded(completed, jobs.length)
              : l10n.sftpUploadCancelled,
        );
      }
    } catch (e) {
      if (mounted && isPermissionDenied(e)) {
        // Retry with sudo (3.4): the one refused and those not tried yet,
        // with one password, each through /tmp and `cp`.
        final left = jobs.skip(completed).toList();
        _offerSudo([for (final j in left) SudoUpload(j.localPath, j.remotePath)],
            shownPath: left.first.remotePath, details: '$e');
      } else if (mounted) {
        showTopSnackBar(
          context,
          l10n.sftpNotUploaded(sftpErrorMessage(e, name: current, op: SftpOp.upload)),
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isTransferring = false;
          _cancelToken = null;
        });
      }
    }
  }

  Future<void> _createDirectory() async {
    final l10n = AppLocalizations.of(context)!;
    // Refused for want of permission (3.4): the dialog closes, and the notice
    // offers Retry with sudo.
    ({String path, Object error})? denied;
    final name = await showZestInputDialog(
      context: context,
      title: l10n.sftpNewFolder,
      icon: LucideIcons.folderPlus,
      fieldLabel: l10n.sftpFolderNameLabel,
      confirmLabel: l10n.create,
      cancelLabel: l10n.cancel,
      validator: (v) {
        final n = v.trim();
        if (n.isEmpty) return l10n.sftpNameRequired;
        if (!_isValidFileName(n)) return l10n.sftpInvalidFolderName;
        return null;
      },
      onConfirm: (v) async {
        final n = v.trim();
        final remotePath = _currentPath.endsWith('/')
            ? '$_currentPath$n'
            : '$_currentPath/$n';
        try {
          await widget.sftp.createDirectory(remotePath);
          return null;
        } catch (e) {
          // (Said in the dialog, as before, where sudo could not run it.)
          if (isPermissionDenied(e) && SudoMkdir(remotePath).runnable) {
            denied = (path: remotePath, error: e);
            return null;
          }
          return sftpErrorMessage(e, name: n, op: SftpOp.mkdir);
        }
      },
    );
    if (name == null) return;
    final refused = denied;
    if (refused != null) {
      _offerSudo([SudoMkdir(refused.path)], shownPath: refused.path, details: '${refused.error}');
      return;
    }
    if (mounted) await _loadDirectory();
  }

  /// Says that the host refused [ops] for want of permission, with Retry
  /// with sudo (3.4); where something was done as root, the folder is listed
  /// again ([relist]).
  void _offerSudo(List<SudoFileOp> ops,
      {required String shownPath, String? details, bool relist = true, String? said}) {
    if (!mounted || ops.isEmpty) return;
    offerSudoRetry(
      context,
      sudo: widget.sftp.sudoFileOps(),
      host: widget.connectionLabel,
      ops: ops,
      shownPath: shownPath,
      details: details,
      said: said,
      partly: said != null,
      onDone: () {
        if (relist && mounted) unawaited(_loadDirectory());
      },
    );
  }

  Future<void> _renameEntry(SftpEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    // Refused for want of permission (3.4): the dialog closes, and the notice
    // offers Retry with sudo.
    ({String to, Object error})? denied;
    final newName = await showZestInputDialog(
      context: context,
      title: l10n.sftpRename,
      icon: LucideIcons.pencil,
      fieldLabel: l10n.sftpNewNameLabel,
      initialValue: entry.name,
      confirmLabel: l10n.sftpRename,
      cancelLabel: l10n.cancel,
      // Preselect the stem, leave the extension untouched (A1); a folder's
      // whole name, as file managers do.
      selectOnFocus:
          entry.isDirectory ? ZestFieldSelect.all : ZestFieldSelect.stem,
      validator: (v) {
        final n = v.trim();
        if (n.isEmpty) return l10n.sftpNameRequired;
        if (!_isValidFileName(n)) return l10n.sftpInvalidName;
        return null;
      },
      onConfirm: (v) async {
        final n = v.trim();
        if (n == entry.name) return null; // no-op - just close
        final newPath = _currentPath.endsWith('/')
            ? '$_currentPath$n'
            : '$_currentPath/$n';
        try {
          await widget.sftp.rename(entry.path, newPath);
          return null;
        } catch (e) {
          // (Said in the dialog, as before, where sudo could not run it.)
          if (isPermissionDenied(e) && SudoMove(entry.path, newPath).runnable) {
            denied = (to: newPath, error: e);
            return null;
          }
          return sftpErrorMessage(e, name: _shownName(entry.name), op: SftpOp.rename);
        }
      },
    );
    if (newName == null) return;
    final refused = denied;
    if (refused != null) {
      _offerSudo([SudoMove(entry.path, refused.to)], shownPath: entry.path, details: '${refused.error}');
      return;
    }
    if (mounted) await _loadDirectory();
  }

  Future<void> _deleteEntry(SftpEntry entry) => _delete([entry]);
}

/// The upload button's fill and ink on [page]: dimmed while a transfer runs,
/// with the ink that reads on the dimmed fill (white was 1.7:1 on
/// Daylight's dim orange).
({Color fill, Color ink}) sftpUploadButtonColors({required bool transferring, required Color page}) {
  if (!transferring) return (fill: AppColors.brandOrange, ink: Colors.white);
  final fill = Color.alphaBlend(AppColors.brandOrange.withValues(alpha: 0.4), page);
  return (fill: fill, ink: ZestColors.onFill(fill));
}
