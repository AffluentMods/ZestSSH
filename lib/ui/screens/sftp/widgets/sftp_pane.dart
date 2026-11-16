import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/sftp_delete_hold_provider.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/sftp_transfers_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/ui/screens/sftp/sudo_retry.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/services/sftp_transfer_safety.dart' show safeChildName;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/this_computer.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_search_results_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_tail_viewer.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_breadcrumb_bar.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_file_icon.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_permissions_dialog.dart';
import 'package:zestssh/ui/screens/sftp/widgets/transfer_queue_panel.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/features/sftp/remembered_path_resolver.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/byte_size.dart';

/// What direction `_sortBy` orders by.
enum _SortColumn { name, size, permissions, modified }

/// What the pane footer says about a selection of [count] entries, [folders]
/// of them folders, whose files hold [fileBytes] (already formatted). A
/// folder's size is not known until it is walked, so with folders selected
/// the bytes are labelled as the files' alone. [l10n] defaults to the
/// app-wide localizations, for callers without a context.
String paneSelectionLabel(int count, int folders, String fileBytes,
    {AppLocalizations? l10n}) {
  final t = l10n ?? gl10n;
  final files = count - folders;
  if (folders == 0) return t.sftpPaneSelFiles(count, fileBytes);
  if (files == 0) return t.sftpPaneSelFolders(folders);
  return t.sftpPaneSelMixed(folders, files, fileBytes);
}

/// Drag payload - carries the selected entries plus a reference to the
/// source they came from, so the destination pane's drop handler can
/// dispatch correctly (local→remote upload vs remote→local download vs
/// remote→remote bridge).
class PaneDragPayload {
  /// The pane this drag originated from. Identified by `paneSide` rather
  /// than by source directly because the caller (SftpDualPaneScreen)
  /// holds the live sources keyed by side.
  final int paneSide;
  final List<PaneFileEntry> entries;

  const PaneDragPayload({required this.paneSide, required this.entries});
}

/// The source-agnostic file pane. Renders a header with the source
/// dropdown + breadcrumb + nav buttons, then a sortable file list with
/// selection, drag-drop, and a context menu.
///
/// State flows:
///  - [source] is owned by the parent; this widget reacts when [source]
///    changes (parent picks a different host, or local files).
///  - [paneSide] is a stable id (0 = left, 1 = right) used as the
///    destination key for drag payloads originating from this pane.
///  - Source mutation lives with the parent (the rail header is the picker
///    now) - the pane just reacts when [source] changes.
class SftpPane extends ConsumerStatefulWidget {
  final PaneFileSource source;
  final SftpPaneSource sourceDescriptor;
  final int paneSide;

  /// Called when entries are dropped on this pane FROM another pane.
  /// Caller is expected to dispatch the actual transfer.
  final void Function(PaneDragPayload payload, String destPath) onInterPaneDrop;

  /// Called when the user double-clicks a file (request to open in editor).
  final void Function(PaneFileEntry entry)? onOpenFile;

  /// Called when the toolbar's Upload / Download button is pressed - push this
  /// pane's current selection to the OTHER pane's directory. The parent knows
  /// both panes and runs the same transfer pipeline a drag would; a keyboard-
  /// or button-driven transfer for people who don't drag between panes.
  final void Function(List<PaneFileEntry> entries)? onTransferSelection;

  /// "Open terminal here" - start a shell on this (remote) pane's host at
  /// [path]. Null on a local pane. This is the one thing no standalone SFTP
  /// client can do: the moment a file operation needs a command, the user is
  /// one tap from a shell in that directory.
  final void Function(String path)? onOpenTerminalHere;

  /// "Mirror to remote…" - one-way sync of this (local) pane's directory
  /// [localDir] up to the other (remote) pane. Null unless this is a local
  /// pane with a remote pane on the other side.
  final void Function(String localDir)? onMirrorFolder;

  /// Optional session id of the OTHER pane, for excluding it from the
  /// dropdown's "available sessions" list (avoids picking the same host
  /// on both sides if you don't want to - though we DO allow it).
  final String? otherPaneSessionId;

  /// Optional initial path. If null, the pane navigates to the source's
  /// home directory on first build.
  final String? initialPath;

  /// Visible header label override - if null, falls back to source.label.
  final String? headerLabel;

  /// Current source's pinned directory paths: the path-bar
  /// pin button reflects whether the current directory is already pinned. Empty
  /// when pinning isn't available for this source.
  final Set<String> pinnedPaths;

  /// Pin / unpin the current directory (the path-bar pin button). Null → the
  /// button isn't shown.
  final void Function(String path)? onTogglePin;

  /// Right-click on the bookmark button: open the bookmark menu (§4) anchored
  /// at the pointer. Null → right-click does nothing.
  final void Function(Offset globalPosition)? onBookmarkMenu;

  /// When set, this pane is the RIGHT pane of an embedded SFTP view and
  /// carries the close control at the far right of its toolbar (the same
  /// power-off glyph every session uses). Closes only the SFTP pane.
  final VoidCallback? onClose;

  /// Fired after every successful listing with the directory now shown
  /// (remember-last-folder spec: the parent records it and writes it,
  /// debounced).
  final void Function(String path)? onPathSettled;

  /// The host default to try after opening home (spec 1: where a NEW pane
  /// starts), or null. Consulted only when there is no restored pane path
  /// and no memory from this app session.
  final Future<RememberedCandidate?> Function()? rememberedPath;

  /// Spec 6: the remembered folder resolved exactly again. Returns the visit
  /// count when a pin should be offered, else null.
  final Future<int?> Function(String path)? shouldSuggestPin;

  /// The user chose "Not now" on the pin offer for [path].
  final void Function(String path)? onPinSuggestionDeclined;

  /// The one pane of the SFTP dock beside a terminal (4.0):
  /// its header is one row, Up and Refresh, the path bar, then
  /// Upload, New folder and More, with Back, Forward and Download in More.
  final bool docked;

  /// Upload in the dock's one pane: files of this computer, picked, go into
  /// the folder given (the one shown). Null where there is no Upload.
  final void Function(String folder)? onUploadHere;

  /// Whether the SFTP dock shows two panes side by side (this computer, or
  /// another host, beside this one), and what turns that on or off: More's
  /// "Two panes side by side". Null where the pane is not the dock's.
  final bool? twoPanes;
  final ValueChanged<bool>? onTwoPanes;

  const SftpPane({
    super.key,
    required this.source,
    required this.sourceDescriptor,
    required this.paneSide,
    required this.onInterPaneDrop,
    this.onOpenFile,
    this.onTransferSelection,
    this.onOpenTerminalHere,
    this.onMirrorFolder,
    this.otherPaneSessionId,
    this.initialPath,
    this.headerLabel,
    this.pinnedPaths = const {},
    this.onTogglePin,
    this.onBookmarkMenu,
    this.onClose,
    this.onPathSettled,
    this.rememberedPath,
    this.shouldSuggestPin,
    this.onPinSuggestionDeclined,
    this.docked = false,
    this.onUploadHere,
    this.twoPanes,
    this.onTwoPanes,
  });

  @override
  ConsumerState<SftpPane> createState() => SftpPaneState();
}

class SftpPaneState extends ConsumerState<SftpPane> {
  String _path = '';
  List<PaneFileEntry> _entries = [];

  /// One dismissible line under the path bar (remember-last-folder spec,
  /// section 3): what happened to the remembered folder. Never stacks; gone
  /// on the next navigation.
  String? _notice;

  /// The folder a pin is being offered for (spec 6), with its visit count.
  String? _pinSuggestion;
  int _pinSuggestionCount = 0;
  bool _loading = true;
  String? _error;
  // Raw failure text behind a "Copy details" button; the card shows the
  // friendly [_error] headline instead.
  String? _errorDetail;

  /// The home folder could not be found: Retry looks for it again.
  bool _homeFailed = false;

  /// Selected paths. Source-agnostic - uses entry.path which is unique per
  /// source (paths from different sources can collide, but this pane only
  /// ever shows one source at a time).
  final Set<String> _selected = {};
  int? _lastSelectedIndex;

  // ── Rubber-band (drag-rectangle) selection ────────────────────────
  //
  // Activates when the user starts a primary-button drag in EMPTY space
  // below the last row. Click-on-row → row drag (existing behavior),
  // click-on-empty → rubber band. The two paths never both fire - we
  // gate on "is the pointer-down position past the last row" before
  // arming the rubber band.
  //
  // Coordinates are stored in *list-local* space (i.e. content-space
  // including scroll offset), so the rectangle stays anchored to the
  // file rows when the user auto-scrolls during a drag.
  final ScrollController _scrollController = ScrollController();
  bool _rubberBandArmed = false;
  bool _rubberBandActive = false;
  Offset? _rubberBandStart; // content-space anchor
  Offset? _rubberBandCurrent; // content-space cursor
  Set<String> _rubberBandBaseSelection = const {}; // for shift-additive

  // Sort state.
  _SortColumn _sortBy = _SortColumn.name;
  bool _sortAsc = true;

  // Search state. The field is permanent in the path bar,
  // so there's no show/hide toggle any more - only the live query.
  String _searchQuery = '';
  // Search collapses to an icon by default; expanding it takes
  // over the path bar (hiding the breadcrumb). A lingering filter shows a dot on
  // the collapsed icon + "showing N of M" in the footer.
  bool _searchExpanded = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// Per-pane, session-scoped TEMPORARY reveal: the footer
  /// "M hidden" chip flips this to show everything in this pane WITHOUT changing
  /// the global 3-level setting. What each level hides is decided by
  /// [_isEntryHidden] against [sftpHiddenLevelProvider].
  bool _tempRevealAll = false;

  /// Whether [e] is hidden at [level] - SYSTEM items at every level above None,
  /// dotfile/Hidden-attribute items only at hiddenAndSystem.
  bool _isEntryHidden(PaneFileEntry e, SftpHiddenLevel level) {
    switch (level) {
      case SftpHiddenLevel.none:
        return false;
      case SftpHiddenLevel.systemOnly:
        return e.isSystemHidden;
      case SftpHiddenLevel.hiddenAndSystem:
        return e.isSystemHidden || e.isHidden;
    }
  }

  // Path edit state (double-click breadcrumb).
  bool _pathEditing = false;
  final _pathEditController = TextEditingController();
  final _pathEditFocus = FocusNode();

  /// Focus node attached to the file list so the Delete / Backspace
  /// shortcuts only fire when the user is interacting with this pane.
  /// Auto-requested on tap-to-select, cleared when focus moves to the
  /// breadcrumb editor or search field.
  final FocusNode _listFocus = FocusNode(debugLabel: 'sftpPaneList');

  // ── Type-ahead jump state ─────────────────────────────────────────
  //
  // Press a letter → select + scroll to the first visible entry whose
  // name starts with it; press the same letter again → advance to the
  // next match, wrapping around. Because the list is sorted
  // folders-first, repeated presses naturally walk all matching
  // folders before moving on to matching files - the Explorer/Finder
  // convention.
  String? _typeAheadChar;
  int _typeAheadIndex = -1;

  // Navigation history per pane.
  final List<String> _history = [];
  int _historyIndex = -1;

  // Column layout, WinSCP / Explorer style. EVERY column has an explicit,
  // resizable width; each divider sits on a column's RIGHT edge and resizes
  // THAT column, so dragging it shifts everything to its right and the header
  // stays aligned with the rows below. A trailing flex spacer fills the pane
  // when the columns are narrower than it; the list scrolls when they overflow.
  // Name is null, and fills the pane at every width, until the user drags its
  // divider; then they own it. Metadata uses the mono face so the digits align.
  double? _wName;
  double _wSize = 78; // right-aligned
  // Null until the person drags the Modified divider; until then the width
  // follows the time format (a 12-hour time is wider).
  double? _wModifiedSet;
  double get _wModified =>
      _wModifiedSet ?? (_timeFormat == SftpTimeFormat.h12 ? 140 : 118);
  SftpTimeFormat _timeFormat = SftpTimeFormat.h24;
  double _wPerms = 96;
  static const double _wNameMin = 120, _wNameMax = 1000;
  static const double _wSizeMin = 52, _wSizeMax = 260;
  static const double _wModifiedMin = 92, _wModifiedMax = 320;
  // The Name width used for the current frame: either _wName once the user has
  // dragged it, or the computed pane-filling default. Set in build() so the
  // header and the row builder share one value and stay aligned.
  double _effNameW = 240;
  // True while a column divider is being dragged, so the shared horizontal
  // scroll never competes with the resize gesture.
  bool _resizingColumn = false;
  static const double _colGutter = 10; // divider gap between every column
  static const double _kRowHPad = 12; // row + header horizontal padding
  static const double _kIconCol = 28; // leading file-type icon column

  /// Total intrinsic width of all columns for a given Name width: icon + the
  /// four columns + the four divider gaps + row padding, excluding the trailing
  /// flex filler. `_columnsWidth(0)` is the chrome around the Name column.
  double _columnsWidth(double nameW) =>
      _kRowHPad +
      _kIconCol +
      nameW +
      _colGutter +
      _wSize +
      _colGutter +
      _wModified +
      _colGutter +
      _wPerms +
      _kRowHPad;
  // Shared horizontal scroll controller for the column header + the file rows,
  // so they slide together.
  final ScrollController _hScroll = ScrollController();
  // A broken/unresolvable link is warn-tinted only when it's a genuine
  // minority; when most link rows are unresolved the "warning" is on every row
  // and stops being one, so it drops to muted. Set in _buildBody.
  bool _demoteBrokenLinks = false;

  // Hovered drop zone marker.
  bool _isBeingDroppedOn = false;

  // Free space on the pane's current volume, for the footer readout. Filled in
  // asynchronously after each listing (a statvfs round-trip remotely, a cached
  // platform query locally) so it never blocks the directory from rendering.
  PaneFreeSpace? _freeSpace;
  String? _freeSpaceKey;
  bool _freeSpaceInFlight = false;

  // Font size for Ctrl+scroll zoom.
  double _fontSize = 13.0;
  static const _minFont = 9.0;
  static const _maxFont = 22.0;


  @override
  void initState() {
    super.initState();
    _path = widget.initialPath ?? '';
    _bootstrap();
  }

  @override
  void didUpdateWidget(covariant SftpPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    // If the source has been swapped out (parent picked a different host),
    // reset path + entries and re-bootstrap on the new source. _path
    // is reset to empty here on purpose - [_bootstrap] consults the
    // last-paths registry first, so the new source still lands on
    // its own remembered location.
    if (widget.source.sourceId != oldWidget.source.sourceId ||
        widget.source.runtimeType != oldWidget.source.runtimeType) {
      _path = widget.initialPath ?? '';
      _entries = [];
      _selected.clear();
      _lastSelectedIndex = null;
      _typeAheadChar = null;
      _typeAheadIndex = -1;
      _history.clear();
      _historyIndex = -1;
      _bootstrap();
    } else if (!identical(widget.source, oldWidget.source) && _error != null) {
      // The same place through another file service (its session was
      // connected again, on a connection of its own): what failed is asked
      // again, without anybody pressing Retry.
      _retryAfterFailure();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _pathEditController.dispose();
    _pathEditFocus.dispose();
    _listFocus.dispose();
    _scrollController.dispose();
    _hScroll.dispose();
    super.dispose();
  }

  // ── Type-ahead jump ───────────────────────────────────────────────

  /// Key handler for the list's [Focus] node. Bare printable
  /// letters/digits drive type-ahead; everything else is left for the
  /// surrounding [Shortcuts] (Delete, F2, Enter, Ctrl+A) and ancestors.
  KeyEventResult _handleTypeAhead(KeyEvent event, List<PaneFileEntry> visible) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final ch = event.character;
    if (ch == null || !RegExp(r'^[a-zA-Z0-9]$').hasMatch(ch)) {
      return KeyEventResult.ignored;
    }
    _typeAheadJump(ch, visible);
    return KeyEventResult.handled;
  }

  void _typeAheadJump(String ch, List<PaneFileEntry> visible) {
    if (visible.isEmpty) return;
    final lower = ch.toLowerCase();

    // Indices of entries whose name starts with the typed character.
    // `visible` is already folders-first sorted, so cycling match
    // order walks matching folders, then matching files.
    final matches = <int>[];
    for (var i = 0; i < visible.length; i++) {
      if (visible[i].name.toLowerCase().startsWith(lower)) {
        matches.add(i);
      }
    }
    if (matches.isEmpty) return;

    final int next;
    if (_typeAheadChar == lower) {
      // Same letter again → advance past the previous jump target,
      // wrapping back to the first match at the end.
      next = matches.firstWhere(
        (i) => i > _typeAheadIndex,
        orElse: () => matches.first,
      );
    } else {
      next = matches.first;
    }
    _typeAheadChar = lower;
    _typeAheadIndex = next;

    final entry = visible[next];
    setState(() {
      _selected
        ..clear()
        ..add(entry.path);
      _lastSelectedIndex = next;
    });
    _scrollRowIntoView(next);
  }

  /// Scroll so row [index] is visible - centered when it was outside
  /// the viewport, untouched when it's already on screen.
  void _scrollRowIntoView(int index) {
    if (!_scrollController.hasClients) return;
    final rowH = _rowHeight;
    final target = index * rowH;
    final viewport = _scrollController.position.viewportDimension;
    final current = _scrollController.offset;
    if (target < current || target + rowH > current + viewport) {
      final centered = (target - viewport / 2 + rowH / 2).clamp(
        0.0,
        _scrollController.position.maxScrollExtent,
      );
      _scrollController.animateTo(
        centered,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
      );
    }
  }

  // ── Rubber-band helpers ───────────────────────────────────────────

  /// Row height the list currently uses - used to translate y-pixels into
  /// row indices. Mirrors [_buildRowContent]'s `max(24, fontSize * 2.2)`.
  double get _rowHeight => max(24, _fontSize * 2.2);

  /// Begin a rubber-band selection on pointer-down in EMPTY space.
  /// Only arms - the band doesn't actually appear until the pointer
  /// moves more than a few pixels (avoids flicker on plain clicks).
  /// Right-click handler for the EMPTY-directory subtree: every point in an
  /// empty dir is "empty space", so any secondary-button press opens the same
  /// New folder / New file / Refresh / Paste background menu the populated list
  /// shows. Deferred with a microtask (this runs no setState, so no frame is
  /// scheduled and a post-frame callback would never fire) - the same reason
  /// documented in [_onListPointerDown].
  void _onEmptyDirPointerDown(PointerDownEvent e) {
    if (e.kind != PointerDeviceKind.mouse) return;
    if (e.buttons & kSecondaryMouseButton == 0) return;
    final global = e.position;
    Future.microtask(() {
      if (mounted) _showEmptyAreaContextMenu(global);
    });
  }

  void _onListPointerDown(PointerDownEvent e, int visibleCount) {
    // Only mouse events drive rubber-band / right-click handling.
    if (e.kind != PointerDeviceKind.mouse) return;

    final scroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final contentY = e.localPosition.dy + scroll;
    final rowIndex = (contentY / _rowHeight).floor();
    final onRow = rowIndex >= 0 && rowIndex < visibleCount;

    // ── Right-click in EMPTY space → context menu ─────────────────
    //
    // The row-level menu (which has Rename / Delete / etc.) is wired
    // to each row's GestureDetector and fires when you right-click
    // on a file. But right-clicking BELOW the last file got no menu
    // at all, even though that's exactly where the user expects
    // Explorer / Finder's "New folder / Refresh / Paste" menu.
    if (e.buttons & kSecondaryMouseButton != 0 && !onRow) {
      // Don't arm the rubber band - we're handling this click.
      _rubberBandArmed = false;
      // e.position is ALREADY in global coordinates, so show the menu there
      // directly. (The old code converted e.localPosition through the wrong
      // render object, which misplaced the menu.) Defer with a microtask,
      // NOT addPostFrameCallback: this branch runs no setState, so no frame
      // is scheduled and a post-frame callback would never fire - which is
      // exactly why the menu didn't appear, most visibly in an empty
      // directory with no hover repaints to trigger an incidental frame. A
      // microtask runs as soon as this pointer event finishes dispatching.
      final global = e.position;
      Future.microtask(() {
        if (mounted) _showEmptyAreaContextMenu(global);
      });
      return;
    }

    // Primary button only arms rubber-band selection.
    if (e.buttons & kPrimaryMouseButton == 0) return;

    if (onRow) {
      // Pointer is on a row - let the row's tap / Draggable handle it.
      _rubberBandArmed = false;
      return;
    }

    // Empty space: arm and remember anchor + the existing selection
    // (so SHIFT-drag extends rather than replaces).
    _rubberBandArmed = true;
    _rubberBandStart = Offset(e.localPosition.dx, contentY);
    _rubberBandCurrent = _rubberBandStart;
    _rubberBandBaseSelection = HardwareKeyboard.instance.isShiftPressed
        ? {..._selected}
        : const {};
  }

  void _onListPointerMove(PointerMoveEvent e, List<PaneFileEntry> visible) {
    if (!_rubberBandArmed || _rubberBandStart == null) return;

    final scroll = _scrollController.hasClients
        ? _scrollController.offset
        : 0.0;
    final contentPos = Offset(e.localPosition.dx, e.localPosition.dy + scroll);

    // 5px threshold before the band actually becomes visible / starts
    // mutating selection - keeps single empty-area clicks from clearing
    // selection when the user wiggled the mouse a hair.
    if (!_rubberBandActive) {
      final delta = (contentPos - _rubberBandStart!).distance;
      if (delta < 5) return;
      setState(() {
        _rubberBandActive = true;
      });
    }

    setState(() {
      _rubberBandCurrent = contentPos;
      _applyRubberBandSelection(visible);
    });
  }

  void _onListPointerUp(PointerUpEvent e) {
    final wasActive = _rubberBandActive;
    if (_rubberBandArmed && !_rubberBandActive) {
      // Plain click on empty area → clear selection (Explorer / Finder
      // behavior). Skip when shift was held - the user is mid-additive.
      if (!HardwareKeyboard.instance.isShiftPressed) {
        setState(() {
          _selected.clear();
          _lastSelectedIndex = null;
        });
      }
    }
    _rubberBandArmed = false;
    _rubberBandStart = null;
    _rubberBandCurrent = null;
    _rubberBandBaseSelection = const {};
    if (wasActive) {
      setState(() {
        _rubberBandActive = false;
      });
      // Pull focus into the list so Delete / Enter shortcuts work on
      // the freshly-selected rows.
      _listFocus.requestFocus();
    }
  }

  /// Compute which visible rows intersect the current rubber-band
  /// rectangle and overwrite [_selected] accordingly.
  void _applyRubberBandSelection(List<PaneFileEntry> visible) {
    if (_rubberBandStart == null || _rubberBandCurrent == null) return;
    final yMin = min(_rubberBandStart!.dy, _rubberBandCurrent!.dy);
    final yMax = max(_rubberBandStart!.dy, _rubberBandCurrent!.dy);
    final firstIndex = (yMin / _rowHeight).floor().clamp(0, visible.length);
    final lastIndex = (yMax / _rowHeight).floor().clamp(0, visible.length - 1);

    final hit = <String>{};
    for (var i = firstIndex; i <= lastIndex; i++) {
      hit.add(visible[i].path);
    }
    _selected
      ..clear()
      ..addAll(_rubberBandBaseSelection)
      ..addAll(hit);
    _lastSelectedIndex = lastIndex >= 0 ? lastIndex : null;
  }

  /// Resolve the starting directory then load. Precedence (remember-last-
  /// folder spec, section 1):
  ///   1. `widget.initialPath`: this pane's RESTORED folder (a restart or a
  ///      saved workspace).
  ///   2. This app session's memory for the source ([lastSftpPathsProvider]):
  ///      a remount (tab switch, pane tree rebuild) lands straight back
  ///      where the user was; it was listable a moment ago.
  ///   3. The host default ([SftpPane.rememberedPath]): where a NEW pane on
  ///      this host starts.
  ///   4. Home.
  ///
  /// Anything older than this app session is only a hint: the pane opens
  /// HOME immediately, then resolves the hint in the background and
  /// navigates (spec 3), so a dead folder never blocks the pane.
  Future<void> _bootstrap() async {
    _homeFailed = false;
    final restored = _path; // an explicit initialPath, or ''
    if (restored.isEmpty) {
      final remembered =
          ref.read(lastSftpPathsProvider).get(widget.source.sourceId);
      if (remembered != null && remembered.isNotEmpty) {
        _path = remembered;
        await _loadDirectory(record: true);
        if (_error == null) return;
        // Gone while we were away: forget it and fall through to home.
        ref.read(lastSftpPathsProvider).forget(widget.source.sourceId);
      }
    }
    String? candidate;
    var suggestion = false;
    if (restored.isNotEmpty) {
      candidate = restored;
    } else {
      try {
        final hostDefault = await widget.rememberedPath?.call();
        candidate = hostDefault?.path;
        suggestion = hostDefault?.suggestion ?? false;
      } catch (_) {
        candidate = null;
      }
    }
    try {
      _path = await widget.source.homeDirectory();
    } catch (e, stack) {
      if (mounted) {
        final said = sftpErrorMessage(e, name: AppLocalizations.of(context)!.sftpPlaceHome, op: SftpOp.list);
        setState(() {
          _homeFailed = true;
          _error = said;
          _errorDetail = ErrorReport.build(what: said, where: 'Files: finding the home folder', error: e, stack: stack);
          _loading = false;
        });
      }
      return;
    }
    await _loadDirectory(record: true);
    if (!mounted || _error != null) return;
    if (candidate != null && candidate != _path) {
      unawaited(_resolveRemembered(candidate, suggestion: suggestion));
    }
  }

  /// Spec 3: home is open; now try the remembered folder, walking up to the
  /// nearest listable ancestor (at most four climbs), and say what happened
  /// in one line. A [suggestion] (a folder seen under another user) fails
  /// quietly. Spec 6: an exact hit may earn a pin offer.
  Future<void> _resolveRemembered(String candidate,
      {bool suggestion = false}) async {
    final res = await resolveRemembered(widget.source, candidate, maxClimb: 4);
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final landed = res.path;
    if (landed != null) {
      await _navigateTo(landed);
      if (!mounted) return;
      if (res.exact) {
        final count = await widget.shouldSuggestPin?.call(landed);
        if (mounted && count != null && _path == landed) {
          setState(() {
            _pinSuggestion = landed;
            _pinSuggestionCount = count;
          });
        }
        return;
      }
      if (suggestion) return;
      setState(() {
        _notice = res.failure == RememberedFailure.noAccess
            ? l10n.sftpPathNoAccess(candidate, landed)
            : l10n.sftpPathGone(candidate, landed);
      });
      return;
    }
    if (suggestion) return;
    setState(() => _notice = l10n.sftpPathUnreachable(candidate));
  }

  /// Load entries for [_path] and replace the pane state. Pass `record:
  /// true` to push the path onto the back/forward history (set false when
  /// a navigation IS itself a history move).
  Future<void> _loadDirectory({
    bool record = false,
    bool forceFreeSpace = false,
  }) async {
    if (mounted) {
      setState(() {
        _loading = true;
        _error = null;
        _errorDetail = null;
        _selected.clear();
        _lastSelectedIndex = null;
      });
    }
    try {
      // Always fetch EVERYTHING (with per-entry isHidden flags) and let the
      // pane apply the hidden filter - so toggling hidden is a rebuild, not a
      // re-list, and the footer can count what's filtered.
      final list = await widget.source.list(_path, includeHidden: true);
      list.sort(_compareEntries);
      if (!mounted) return;
      setState(() {
        _entries = list;
        _loading = false;
        // New directory contents - restart any type-ahead cycle so the
        // next keystroke jumps from the top instead of a stale index.
        _typeAheadChar = null;
        _typeAheadIndex = -1;
      });
      // Fill the footer free-space readout without blocking the listing - it's
      // a statvfs round-trip remotely / a platform query locally.
      unawaited(_refreshFreeSpace(force: forceFreeSpace));
      if (record) _pushHistory(_path);
      // Remember this path so a pane remount (tab switch, pane tree
      // rebuild) lands the user back where they were instead of
      // resetting to the home directory.
      ref.read(lastSftpPathsProvider).set(widget.source.sourceId, _path);
      // And tell the parent, which persists it (debounced, realpath form).
      widget.onPathSettled?.call(_path);
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _error = sftpErrorMessage(e, name: _lastSegment(_path), op: SftpOp.list);
          _errorDetail = ErrorReport.build(
            what: sftpErrorMessage(e, op: SftpOp.list),
            where: 'Files: listing a folder',
            error: e,
            stack: stack,
          );
          _loading = false;
        });
      }
    }
  }

  /// The last name in [path] (a folder's own name), "/" or the drive for a
  /// root.
  static String _lastSegment(String path) =>
      path.split(RegExp(r'[\\/]')).lastWhere((s) => s.isNotEmpty, orElse: () => path);

  /// Retry after a failure: the home folder again when it was never found
  /// (it listed the empty path instead), else the folder that failed.
  void _retryAfterFailure() {
    if (!_homeFailed) {
      _loadDirectory(record: false);
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _errorDetail = null;
    });
    _bootstrap();
  }

  /// Sort comparator. Folders always before files, then by the chosen
  /// column. Asc/desc toggle multiplies the result.
  int _compareEntries(PaneFileEntry a, PaneFileEntry b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    final mul = _sortAsc ? 1 : -1;
    switch (_sortBy) {
      case _SortColumn.name:
        return a.name.toLowerCase().compareTo(b.name.toLowerCase()) * mul;
      case _SortColumn.size:
        return a.size.compareTo(b.size) * mul;
      case _SortColumn.permissions:
        return (_windowsLocal
                ? (a.windowsAttributes ?? '')
                    .compareTo(b.windowsAttributes ?? '')
                : (a.permissions ?? '').compareTo(b.permissions ?? '')) *
            mul;
      case _SortColumn.modified:
        final ma = a.modifiedAt?.millisecondsSinceEpoch ?? 0;
        final mb = b.modifiedAt?.millisecondsSinceEpoch ?? 0;
        return ma.compareTo(mb) * mul;
    }
  }

  void _pushHistory(String path) {
    // Truncate forward history when navigating to a new path.
    if (_historyIndex < _history.length - 1) {
      _history.removeRange(_historyIndex + 1, _history.length);
    }
    if (_history.isEmpty || _history.last != path) {
      _history.add(path);
      _historyIndex = _history.length - 1;
    }
  }

  Future<void> _navigateTo(String path) async {
    // A navigation retires the remembered-folder notice and any pin offer
    // (spec 3: gone on next navigation, never stacks).
    if (_notice != null || _pinSuggestion != null) {
      setState(() {
        _notice = null;
        _pinSuggestion = null;
      });
    }
    // Navigating collapses search and drops any active filter -
    // a filter for the old directory shouldn't silently apply to the new one.
    if (_searchExpanded || _searchQuery.isNotEmpty) {
      setState(() {
        _searchExpanded = false;
        _searchQuery = '';
        _searchController.clear();
      });
    }
    _path = path;
    await _loadDirectory(record: true);
  }

  Future<void> _navigateBack() async {
    if (_historyIndex <= 0) return;
    _historyIndex--;
    _path = _history[_historyIndex];
    await _loadDirectory(record: false);
  }

  Future<void> _navigateForward() async {
    if (_historyIndex >= _history.length - 1) return;
    _historyIndex++;
    _path = _history[_historyIndex];
    await _loadDirectory(record: false);
  }

  Future<void> _navigateUp() async {
    final parent = widget.source.parentOf(_path);
    if (parent != _path) {
      await _navigateTo(parent);
    }
  }

  void _onHeaderTap(_SortColumn col) {
    setState(() {
      if (_sortBy == col) {
        _sortAsc = !_sortAsc;
      } else {
        _sortBy = col;
        _sortAsc = true;
      }
      _entries.sort(_compareEntries);
    });
  }

  void _onFileTap(
    PaneFileEntry entry,
    int index,
    List<PaneFileEntry> visible,
    bool isCtrl,
    bool isShift,
  ) {
    setState(() {
      if (isShift && _lastSelectedIndex != null) {
        // SHIFT+click → range select from the last anchor to this row.
        // Matches Windows Explorer / macOS Finder / WinSCP / FileZilla /
        // every other file manager. Don't update _lastSelectedIndex on
        // range select so the user can keep shift-extending from the
        // same anchor.
        _selected.clear();
        final start = min(_lastSelectedIndex!, index);
        final end = max(_lastSelectedIndex!, index);
        for (var i = start; i <= end; i++) {
          _selected.add(visible[i].path);
        }
      } else if (isCtrl) {
        // CTRL+click → toggle this row in/out of the selection without
        // touching the rest. Standard file-manager convention. Updates
        // the anchor so a follow-up SHIFT+click ranges from here.
        if (_selected.contains(entry.path)) {
          _selected.remove(entry.path);
        } else {
          _selected.add(entry.path);
        }
        _lastSelectedIndex = index;
      } else {
        // Plain click → select only this row.
        _selected.clear();
        _selected.add(entry.path);
        _lastSelectedIndex = index;
      }
    });
    // Pull keyboard focus into the list so Delete / Enter / F2 fire
    // immediately after a click. Without this the user has to Tab
    // into the pane before the shortcuts work, which is the bug.
    _listFocus.requestFocus();
  }

  void _onFileDoubleTap(PaneFileEntry entry) {
    if (entry.isDirectory) {
      _navigateTo(entry.path);
    } else if (entry.isSymlink) {
      // Follow the link instead of opening it as a file: `stat` (which follows)
      // tells us whether the target is a directory to enter or a file to open.
      unawaited(_followSymlink(entry));
    } else if (entry.name.toLowerCase().endsWith('.lnk')) {
      // A Windows shortcut: follow it straight to its target directory (or the
      // target's containing folder for a file shortcut) instead of opening the
      // .lnk blob in the editor.
      unawaited(_followShortcut(entry));
    } else {
      widget.onOpenFile?.call(entry);
    }
  }

  /// Follow a Windows `.lnk` shortcut on activation: resolve its target and, if
  /// it points at a directory, go straight there; a file shortcut jumps to the
  /// target's folder. Non-resolvable (or a remote pane) falls back to opening.
  Future<void> _followShortcut(PaneFileEntry entry) async {
    final target = await widget.source.resolveShortcut(entry.path);
    if (!mounted) return;
    if (target == null || target.isEmpty) {
      widget.onOpenFile?.call(entry);
      return;
    }
    final targetStat = await widget.source.stat(target);
    if (!mounted) return;
    if (targetStat != null && targetStat.isDirectory) {
      _navigateTo(target);
    } else {
      _navigateTo(widget.source.parentOf(target));
    }
  }

  /// Follow a symlink on activation. The server resolves the link when we list
  /// or open its path, so navigating / opening [entry].path lands on the
  /// target. A failed stat means a broken or unreadable target - said in words
  /// rather than silently opening an empty editor.
  Future<void> _followSymlink(PaneFileEntry entry) async {
    PaneFileEntry? target;
    Object? failure;
    try {
      target = await widget.source.stat(entry.path);
    } catch (e) {
      target = null;
      failure = e;
    }
    if (!mounted) return;
    if (target == null) {
      showTopSnackBar(
        context,
        AppLocalizations.of(context)!.sftpLinkUnreachable,
        isError: true,
        details: failure == null ? null : '$failure',
      );
      return;
    }
    if (target.isDirectory) {
      _navigateTo(entry.path);
    } else {
      widget.onOpenFile?.call(entry);
    }
  }

  /// Return entries currently selected (in display order).
  List<PaneFileEntry> _selectedEntries(List<PaneFileEntry> visible) =>
      visible.where((e) => _selected.contains(e.path)).toList();

  /// Public refresh hook so the parent can ask the pane to reload after
  /// a transfer completes.
  Future<void> refresh() => _loadDirectory(record: false, forceFreeSpace: true);

  /// Public path getter for the parent (used as drop target's destination
  /// path when files are dropped between panes).
  String get currentPath => _path;

  /// Navigate this pane to [path] (used by the locations rail).
  Future<void> navigateTo(String path) => _navigateTo(path);

  /// Refresh the footer's free-space readout for the current volume. Local
  /// drives are keyed by drive/root so same-volume navigation doesn't re-spawn
  /// the platform query; [force] (a refresh after a transfer/delete) always
  /// re-queries so the number reflects what just changed.
  Future<void> _refreshFreeSpace({bool force = false}) async {
    final key = _freeSpaceRootKey(_path);
    if (!force && key == _freeSpaceKey && _freeSpace != null) return;
    if (_freeSpaceInFlight) return;
    _freeSpaceInFlight = true;
    try {
      final fs = await widget.source.freeSpace(_path);
      if (!mounted) return;
      setState(() {
        _freeSpace = fs;
        _freeSpaceKey = key;
      });
    } catch (_) {
      // Best-effort - leave the last value (or none) in place.
    } finally {
      _freeSpaceInFlight = false;
    }
  }

  /// A Windows local pane: NTFS has no Unix permission bits, so it shows the
  /// Windows attributes that are really set (Read-only, Hidden, System) under
  /// "Attributes", and offers no Permissions action, which could not change
  /// anything there.
  bool get _windowsLocal =>
      widget.source is LocalPaneFileSource && !widget.source.isPosix;

  /// The "volume" key the current free-space value belongs to. On local Windows
  /// that's the drive letter; elsewhere the source id (one volume per host /
  /// mount for our purposes).
  String _freeSpaceRootKey(String path) {
    if (widget.source is LocalPaneFileSource && !widget.source.isPosix) {
      return path.length >= 2 && path[1] == ':'
          ? path.substring(0, 2).toUpperCase()
          : path;
    }
    return widget.source.sourceId;
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Apply BOTH filters here: the global 3-level hidden setting (except
    // while this pane is temporarily revealing) and the live search.
    // _entries always holds everything the source returned (with both hidden
    // flags), so the footer can count what the hidden filter drops.
    final level = ref.watch(sftpHiddenLevelProvider);
    // Read here, not in the row builder (rows build during layout).
    _timeFormat = ref.watch(sftpTimeFormatProvider);
    // The path bar and breadcrumb mask through Redactable (spec 4); watching
    // the mode here re-renders them on a toggle.
    ref.watch(recordingModeProvider);
    final q = _searchQuery.toLowerCase();
    final visible = _entries.where((e) {
      if (!_tempRevealAll && _isEntryHidden(e, level)) return false;
      if (q.isNotEmpty && !e.name.toLowerCase().contains(q)) return false;
      return true;
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        // Name fills the pane until the person drags its divider; from then on
        // they own its width. Every column is explicit; a trailing spacer fills
        // any slack and the row scrolls horizontally only when the columns
        // genuinely overflow. (Name kept the width of the pane's first layout:
        // the SFTP dock moved from the bottom to the right kept the bottom's
        // Name, and Size and Modified were pushed out of sight.)
        final avail = constraints.maxWidth;
        final nameFill = max(_wNameMin, avail - _columnsWidth(0));
        _effNameW = _wName ?? nameFill;
        final contentWidth = max(_columnsWidth(_effNameW), avail);
        final hScrollable = contentWidth > avail + 0.5;
        return Container(
          // Pane surface is --panel; rows hover UP to --raised,
          // so the pane must be the darker --panel or the hover wash is invisible.
          color: AppColors.sftpPanel,
          child: Column(
            children: [
              // Toolbar + path bar are ONE header block, not two stacked bands:
              // a single --panel container, one bottom border,
              // the path bar a --sunken pill one step down the surface ladder.
              _buildPaneHeader(),
              // Column header + file rows share ONE horizontal scroll so they slide
              // together; the toolbar/path-bar header and the footer stay fixed.
              Expanded(
                child: Scrollbar(
                  controller: _hScroll,
                  thumbVisibility: hScrollable,
                  notificationPredicate: (n) =>
                      n.metrics.axis == Axis.horizontal,
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    controller: _hScroll,
                    physics: (hScrollable && !_resizingColumn)
                        ? const ClampingScrollPhysics()
                        : const NeverScrollableScrollPhysics(),
                    child: SizedBox(
                      width: contentWidth,
                      child: Column(
                        children: [
                          _buildColumnHeader(),
                          // Wrapping the body in a Focus + Shortcuts/Actions bundle
                          // lets the user delete the current selection with the
                          // keyboard, exactly like every native file manager. The
                          // node's `requestFocus` is fired from the row tap handler
                          // so simply clicking a file is enough to "own" the
                          // keyboard.
                          Expanded(
                            child: Shortcuts(
                              shortcuts: const <ShortcutActivator, Intent>{
                                SingleActivator(LogicalKeyboardKey.delete):
                                    _DeleteIntent(),
                                // Backspace goes UP a directory - what Explorer, Nautilus
                                // and every other file manager do. It was previously a
                                // second Delete binding, so a user reaching for "back"
                                // got a delete prompt on their selection instead.
                                SingleActivator(LogicalKeyboardKey.backspace):
                                    _ParentDirIntent(),
                                SingleActivator(
                                  LogicalKeyboardKey.arrowLeft,
                                  alt: true,
                                ): _ParentDirIntent(),
                                SingleActivator(LogicalKeyboardKey.f2):
                                    _RenameIntent(),
                                SingleActivator(LogicalKeyboardKey.enter):
                                    _OpenIntent(),
                                SingleActivator(LogicalKeyboardKey.numpadEnter):
                                    _OpenIntent(),
                                SingleActivator(
                                  LogicalKeyboardKey.keyA,
                                  control: true,
                                ): _SelectAllIntent(),
                                // Ctrl+F focuses the permanent search field.
                                SingleActivator(
                                  LogicalKeyboardKey.keyF,
                                  control: true,
                                ): _FocusSearchIntent(),
                              },
                              child: Actions(
                                actions: <Type, Action<Intent>>{
                                  _FocusSearchIntent:
                                      CallbackAction<_FocusSearchIntent>(
                                        onInvoke: (_) {
                                          _expandSearch();
                                          return null;
                                        },
                                      ),
                                  _DeleteIntent: CallbackAction<_DeleteIntent>(
                                    onInvoke: (_) {
                                      final targets = _selectedEntries(visible);
                                      if (targets.isNotEmpty)
                                        _runDelete(targets);
                                      return null;
                                    },
                                  ),
                                  _ParentDirIntent:
                                      CallbackAction<_ParentDirIntent>(
                                        onInvoke: (_) {
                                          _navigateUp();
                                          return null;
                                        },
                                      ),
                                  _RenameIntent: CallbackAction<_RenameIntent>(
                                    onInvoke: (_) {
                                      final targets = _selectedEntries(visible);
                                      if (targets.length == 1) {
                                        _runRename(targets.first);
                                      }
                                      return null;
                                    },
                                  ),
                                  _OpenIntent: CallbackAction<_OpenIntent>(
                                    onInvoke: (_) {
                                      final targets = _selectedEntries(visible);
                                      if (targets.length == 1) {
                                        _onFileDoubleTap(targets.first);
                                      }
                                      return null;
                                    },
                                  ),
                                  _SelectAllIntent:
                                      CallbackAction<_SelectAllIntent>(
                                        onInvoke: (_) {
                                          setState(() {
                                            _selected
                                              ..clear()
                                              ..addAll(
                                                visible.map((e) => e.path),
                                              );
                                          });
                                          return null;
                                        },
                                      ),
                                },
                                child: Focus(
                                  focusNode: _listFocus,
                                  onKeyEvent: (node, event) =>
                                      _handleTypeAhead(event, visible),
                                  child: _buildBody(visible),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
              _buildPaneFooter(visible, level),
            ],
          ),
        );
      },
    );
  }

  /// The per-pane footer: item count and, when something is
  /// selected, the selection count + size - so "did that upload land" is on
  /// screen instead of in a refresh. (Free space is a follow-up: it needs a
  /// statvfs on the remote, which the client doesn't surface yet.)
  Widget _buildPaneFooter(List<PaneFileEntry> visible, SftpHiddenLevel level) {
    final selectedEntries = visible
        .where((e) => _selected.contains(e.path))
        .toList();
    final selCount = selectedEntries.length;
    final selFolders = selectedEntries.where((e) => e.isDirectory).length;
    final selBytes = selectedEntries.fold<int>(
      0,
      (sum, e) => sum + (e.isDirectory ? 0 : e.size),
    );
    // "M hidden" in the footer is a TEMPORARY per-pane reveal,
    // counting the items hidden BY THE CURRENT LEVEL - clicking it reveals them
    // in this pane without changing the global setting. Renders only when there
    // ARE hidden items, so someone hunting a filtered-out file finds the answer
    // next to the item count.
    final hiddenInDir = _entries.where((e) => _isEntryHidden(e, level)).length;
    final l10n = AppLocalizations.of(context)!;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: AppColors.sftpPanel,
        border: Border(top: BorderSide(color: AppColors.divider, width: 1)),
      ),
      // What does not fit a narrow pane is left out whole, the item count
      // last (shortened at the very least widths): the selection, then the
      // hidden items' toggle, then the free space go first, the free space
      // first of all.
      child: LayoutBuilder(builder: (context, box) {
        final mono = TextStyle(fontSize: 11, fontFamily: 'JetBrainsMono', color: AppColors.textSecondary);
        final scaler = MediaQuery.textScalerOf(context);
        double widthOf(String text, [TextStyle? style]) {
          final painter = TextPainter(
            text: TextSpan(text: text, style: style ?? mono),
            textDirection: TextDirection.ltr,
            textScaler: scaler,
            maxLines: 1,
          )..layout();
          final w = painter.width;
          painter.dispose();
          return w + 1;
        }

        final countText = _searchQuery.isEmpty
            ? l10n.sftpItemCount(visible.length)
            : l10n.sftpPaneShowingOf(visible.length, _entries.length);
        final selectionText = selCount > 0 ? _selectionLabel(selCount, selFolders, selBytes) : null;
        final hiddenText = hiddenInDir > 0 ? l10n.sftpHiddenCount(hiddenInDir) : null;
        final freeText = _freeSpace == null ? null : _freeSpaceLabel(_freeSpace!);
        var used = widthOf(countText);
        bool fits(double w) {
          if (used + w > box.maxWidth) return false;
          used += w;
          return true;
        }

        final showSelection =
            selectionText != null && fits(12 + widthOf(selectionText, mono.copyWith(fontWeight: FontWeight.w600)));
        final showHidden = hiddenText != null && fits(widthOf(',  ') + widthOf(hiddenText));
        final showFree = freeText != null && fits(12 + widthOf(freeText));
        return Row(
        children: [
          Flexible(
            child: Text(
              // While a filter is active the footer reads "showing N of M" so the
              // short list explains itself at a glance (spec 2.4).
              countText,
              key: const ValueKey('sftp-footer-count'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: mono,
            ),
          ),
          if (showHidden) ...[
            Text(
              ',  ',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.onSurfaceDim,
                fontFamily: 'JetBrainsMono',
              ),
            ),
            Tooltip(
              message: _tempRevealAll
                  ? l10n.sftpHideHiddenItems
                  : l10n.sftpShowHiddenItems,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  onTap: () => setState(() => _tempRevealAll = !_tempRevealAll),
                  child: Text(
                    hiddenText,
                    style: TextStyle(
                      fontSize: 11,
                      fontFamily: 'JetBrainsMono',
                      // Bright when temporarily revealed (the "on" state), muted
                      // when filtered out. Underline signals it's the toggle.
                      color: _tempRevealAll
                          ? AppColors.onSurface
                          : AppColors.onSurfaceDim,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.divider,
                    ),
                  ),
                ),
              ),
            ),
          ],
          if (showSelection) ...[
            const SizedBox(width: 12),
            Text(
              selectionText,
              key: const ValueKey('sftp-footer-selection'),
              style: TextStyle(
                fontSize: 11,
                color: AppColors.onSurface,
                fontFamily: 'JetBrainsMono',
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
          // Free space sits at the far right - the answer to "did that upload
          // land / do I have room" belongs in the footer, not a refresh.
          if (showFree) ...[
            const Spacer(),
            const SizedBox(width: 12),
            Text(freeText, style: mono),
          ],
        ],
      );
      }),
    );
  }

  /// What the footer says about the selection. A folder's size is not known
  /// until it is walked, so once folders are selected the bytes are labelled
  /// as the files' alone instead of passing for the whole selection ("3
  /// selected, 333 B" for two big folders and a small file). The transfer
  /// dialog walks the folders and states the real total.
  String _selectionLabel(int count, int folders, int bytes) =>
      paneSelectionLabel(count, folders, _formatBytes(bytes),
          l10n: AppLocalizations.of(context)!);

  String _freeSpaceLabel(PaneFreeSpace fs) {
    final l10n = AppLocalizations.of(context)!;
    final free = l10n.sftpFreeSpace(_formatSpace(fs.freeBytes));
    if (fs.totalBytes <= 0) return free;
    return '$free  •  '
        '${l10n.sftpUsedPercent((fs.usedFraction * 100).round())}';
  }

  String _formatSpace(int bytes) => formatByteSize(bytes);

  String _formatBytes(int bytes) => formatByteSize(bytes);

  /// Standalone, full-width breadcrumb row that sits between the
  /// nav-button strip and the column headers. Mirrors the address-bar
  /// layout you see in Windows Explorer / macOS Finder column view.
  ///
  /// The source picker leads the row as a pinned pill - changing the source
  /// is what changes the path, so the control sits next to the path it
  /// determines. It stays fixed while the breadcrumb segments
  /// scroll in the remaining space. For a remote source the pill also shows
  /// the live connection state + latency.
  /// The pane header: ONE block wrapping the toolbar row and
  /// the path bar, with a single bottom border. Background is --panel; the path
  /// bar inside is a --sunken pill, one step of the surface ladder down, so the
  /// header reads as one unit rather than a stack of separately-bordered bands.
  Widget _buildPaneHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.sftpPanel,
        border: Border(bottom: BorderSide(color: AppColors.divider, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.docked)
            _buildDockedRow()
          else ...[
            _buildToolbarRow(),
            const SizedBox(height: 8),
            _buildBreadcrumbRow(),
          ],
          if (_notice != null || _pinSuggestion != null) _buildNoticeLine(),
        ],
      ),
    );
  }

  /// The header of the SFTP dock's one pane, on one row (4.0):
  /// Up and Refresh, the path bar (its folders, search and
  /// bookmark, as in any pane), then Upload, New folder and More. Back,
  /// Forward and Download are in More. Where the dock is narrow, Upload and
  /// New folder lose their words first, so the path bar keeps its room.
  Widget _buildDockedRow() {
    final l10n = AppLocalizations.of(context)!;
    final touch = Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded;
    final upload = widget.onUploadHere;
    return LayoutBuilder(builder: (context, box) {
      final iconW = touch ? _kToolbarIconTouch : _kToolbarIcon;
      final fixed = 2 * iconW + (touch ? _kToolbarMenuTouch : _kToolbarMenu) + 14;
      final labelled = _kToolbarLabelExtra +
          _toolbarLabelWidth(l10n.sftpNewFolderAction) +
          (upload != null ? _kToolbarLabelExtra + _toolbarLabelWidth(l10n.sftpUpload) : 0);
      // The words, where the path bar still has room for a few folders.
      final labels = box.maxWidth >= fixed + labelled + 180;

      Widget icon(String tooltip, IconData glyph, VoidCallback? onPressed, {Key? key}) => IconButton(
            key: key,
            tooltip: tooltip,
            icon: Icon(glyph, size: 16),
            onPressed: onPressed,
            visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
          );
      Widget action(Key key, String label, IconData glyph, VoidCallback onPressed) => labels
          ? Padding(
              padding: const EdgeInsets.only(left: 4),
              child: OutlinedButton.icon(
                key: key,
                onPressed: onPressed,
                icon: Icon(glyph, size: 15),
                label: Text(label, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 13)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.onSurface,
                  side: BorderSide(color: AppColors.divider),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  minimumSize: Size(0, touch ? 48 : 30),
                  tapTargetSize: touch ? MaterialTapTargetSize.padded : MaterialTapTargetSize.shrinkWrap,
                  visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
                ),
              ),
            )
          : icon(label, glyph, onPressed, key: key);

      return Row(
        key: const ValueKey('sftp-toolbar'),
        children: [
          icon(l10n.sftpUp, LucideIcons.arrowUp, _navigateUp, key: const ValueKey('sftp-toolbar-up')),
          icon(l10n.refresh, LucideIcons.refreshCw, () => _loadDirectory(record: false),
              key: const ValueKey('sftp-toolbar-refresh')),
          const SizedBox(width: 6),
          Expanded(child: _buildBreadcrumbRow()),
          const SizedBox(width: 4),
          if (upload != null)
            action(const ValueKey('sftp-toolbar-upload'), l10n.sftpUpload, LucideIcons.upload, () => upload(_path)),
          action(const ValueKey('sftp-toolbar-new-folder'), l10n.sftpNewFolderAction, LucideIcons.folderPlus,
              _runMkdir),
          const SizedBox(width: 2),
          PopupMenuButton<void Function()>(
            key: const ValueKey('sftp-toolbar-menu'),
            tooltip: l10n.zestCommonMoreActions,
            icon: const Icon(LucideIcons.moreHorizontal, size: 18),
            color: AppColors.v3Elevated,
            position: PopupMenuPosition.under,
            padding: EdgeInsets.zero,
            onSelected: (fn) => fn(),
            itemBuilder: (_) => [
              _actionMenuItem('back', LucideIcons.arrowLeft, l10n.sftpBack, _historyIndex > 0 ? _navigateBack : null),
              _actionMenuItem('forward', LucideIcons.arrowRight, l10n.sftpForward,
                  _historyIndex < _history.length - 1 ? _navigateForward : null),
              // To a folder of this computer, picked: the one pane has no
              // other pane to send it to.
              if (widget.onTransferSelection != null)
                _actionMenuItem('transfer', LucideIcons.download, l10n.sftpDownload,
                    _selected.isNotEmpty ? _transferSelection : null),
              const PopupMenuDivider(),
              if (widget.onTwoPanes != null) ...[
                _twoPanesMenuItem(),
                const PopupMenuDivider(),
              ],
              ..._viewMenuItems(),
            ],
          ),
        ],
      );
    });
  }

  /// "Two panes side by side" in the SFTP dock's More: checked while the dock
  /// shows two panes, and turns them on or off.
  PopupMenuEntry<void Function()> _twoPanesMenuItem() {
    final on = widget.twoPanes ?? false;
    return CheckedPopupMenuItem<void Function()>(
      key: const ValueKey('sftp-menu-two-panes'),
      value: () => widget.onTwoPanes?.call(!on),
      checked: on,
      child: Text(
        AppLocalizations.of(context)!.sftpDockTwoPanes,
        style: TextStyle(fontSize: 13, color: AppColors.onSurface),
      ),
    );
  }

  /// One dismissible line under the path bar (spec 3): what happened to the
  /// remembered folder, or the pin offer (spec 6). Not a dialog, never
  /// stacks, gone on the next navigation. Masked like the path bar in
  /// recording mode (spec 4).
  Widget _buildNoticeLine() {
    final l10n = AppLocalizations.of(context)!;
    final pin = _pinSuggestion;
    final text = pin != null
        ? l10n.sftpPinSuggestion(pin, _pinSuggestionCount)
        : (_notice ?? '');
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: [
          Icon(
            pin != null ? LucideIcons.bookmark : LucideIcons.info,
            size: 13,
            color: AppColors.onSurfaceDim,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              Redactable.freeText(text).displayIn(ref),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
          if (pin != null) ...[
            TextButton(
              onPressed: () {
                widget.onTogglePin?.call(pin);
                setState(() => _pinSuggestion = null);
              },
              child: Text(l10n.sftpPinSuggestionAccept,
                  style: const TextStyle(fontSize: 12)),
            ),
            TextButton(
              onPressed: () {
                widget.onPinSuggestionDeclined?.call(pin);
                setState(() => _pinSuggestion = null);
              },
              child: Text(l10n.sftpPinSuggestionDecline,
                  style: const TextStyle(fontSize: 12)),
            ),
          ] else
            _PathBarButton(
              tooltip: l10n.close,
              onTap: () => setState(() => _notice = null),
              child: const Icon(LucideIcons.x, size: 13),
            ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumbRow() {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      // As high as a finger's target where the controls are touch sized.
      constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 32),
      // While searching, the field owns the full geometry (icon at 10px, text
      // at 30px, clear button 4px from the edge - spec 2.2), so the pill drops
      // its own horizontal padding and lets the field lay out edge to edge.
      padding: _searchExpanded
          ? EdgeInsets.zero
          : const EdgeInsets.only(left: 8, right: 4),
      decoration: BoxDecoration(
        // Path bar is a --sunken input pill, radius 8, one
        // hairline border - NOT a full-width band. It sits on the --panel
        // header, one step down the surface ladder. While searching, the pill
        // itself becomes the brand ring (so the field needs no second border).
        color: AppColors.sftpSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _searchExpanded
              ? AppColors.brandOrange.withValues(alpha: 0.30)
              : AppColors.divider,
          width: 1,
        ),
      ),
      // In a pane dragged narrow, the bookmark button and then the search
      // button give way, so the path keeps a little room and nothing runs
      // past the pill (search stays on its key).
      child: LayoutBuilder(builder: (context, box) {
        const pathRoom = 32.0;
        final pin = widget.onTogglePin != null;
        final showSearch = box.maxWidth >= pathRoom + 24;
        final showPin = pin && box.maxWidth >= pathRoom + 24 + 26;
        return Row(
        children: [
          // The source picker lives ONLY in the rail (its group header when
          // expanded, its icon strip when collapsed) - never in the path bar.
          // The bar is breadcrumb + search + pin, nothing else.
          Expanded(
            // Search takes over the path bar when expanded;
            // otherwise the breadcrumb owns the width.
            child: _searchExpanded
                ? _buildSearchField()
                : (_pathEditing
                      ? _buildPathEditor()
                      : GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTap: () {
                            setState(() {
                              _pathEditing = true;
                              _pathEditController.text = _path;
                            });
                            WidgetsBinding.instance.addPostFrameCallback((_) {
                              if (mounted) _pathEditFocus.requestFocus();
                            });
                          },
                          child: SftpBreadcrumbBar(
                            path: _path,
                            onNavigate: _navigateTo,
                          ),
                        )),
          ),
          // Path-bar buttons: 24px square, radius 5, icon 13,
          // right aligned. Search first, then bookmark, in that order. Source
          // switching is never here - it lives in the rail.
          if (!_searchExpanded && showSearch)
            _PathBarButton(
              tooltip: l10n.sftpSearchTooltip,
              onTap: _expandSearch,
              child: _DottedSearchIcon(active: _searchQuery.isNotEmpty),
            ),
          // Bookmark button: bookmark the current directory into
          // this source's rail group. A ribbon glyph (not a
          // pushpin) that FILLS when bookmarked and outlines when not - the
          // shape carries the state, never colour, so it stays grey. Left-click
          // toggles; right-click opens the bookmark menu (§4). Hidden while
          // searching so the filter field fills the whole bar.
          if (showPin && !_searchExpanded) ...[
            const SizedBox(width: 2),
            Builder(
              builder: (_) {
                final pinned = widget.pinnedPaths.contains(_path);
                return _PathBarButton(
                  tooltip: pinned
                      ? l10n.sftpRemoveBookmark
                      : l10n.sftpBookmarkThisFolder,
                  onTap: () => widget.onTogglePin!(_path),
                  onSecondaryTapDown: widget.onBookmarkMenu == null
                      ? null
                      : (d) => widget.onBookmarkMenu!(d.globalPosition),
                  child: _BookmarkRibbonIcon(active: pinned),
                );
              },
            ),
          ],
        ],
      );
      }),
    );
  }

  /// The toolbar's buttons, by width, where taps are a mouse's (a computer)
  /// and where they are a finger's (padded to a bigger target): an icon
  /// button of the toolbar (compact), the overflow menu's button, the close
  /// control behind its separator; and what a labelled action adds to its
  /// label's width (padding 8 + 8, icon 15, gap 8, a little to spare).
  static const double _kToolbarIcon = 32, _kToolbarIconTouch = 48;
  static const double _kToolbarMenu = 40, _kToolbarMenuTouch = 48;
  static const double _kToolbarClose = 41, _kToolbarCloseTouch = 59;
  static const double _kToolbarLabelExtra = 39 + 4;

  /// The width [label] takes as a labelled toolbar action's text.
  double _toolbarLabelWidth(String label) {
    final style = (Theme.of(context).textTheme.labelLarge ?? const TextStyle()).merge(const TextStyle(fontSize: 12));
    final painter = TextPainter(
      text: TextSpan(text: label, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = painter.width;
    painter.dispose();
    return w;
  }

  /// Pushes the selection to the other pane's directory.
  void _transferSelection() {
    final sel = _entries.where((e) => _selected.contains(e.path)).toList();
    if (sel.isNotEmpty) widget.onTransferSelection!(sel);
  }

  /// The toolbar, as much of it as the pane's width holds (a pane can be
  /// dragged narrow, and the docked file panel's panes are narrow already):
  /// first the actions lose their labels, then they move into the overflow
  /// menu, then Refresh and Up, then Back and Forward. The overflow menu and
  /// the close control always stay.
  Widget _buildToolbarRow() {
    return LayoutBuilder(builder: (context, box) => _toolbarFor(box.maxWidth));
  }

  Widget _toolbarFor(double width) {
    final l10n = AppLocalizations.of(context)!;
    final transfer = widget.onTransferSelection != null;
    final local = widget.source is LocalPaneFileSource;
    final transferLabel = local ? l10n.sftpUpload : l10n.sftpDownload;
    final transferIcon = local ? LucideIcons.upload : LucideIcons.download;
    final touch = Theme.of(context).materialTapTargetSize == MaterialTapTargetSize.padded;
    final iconW = touch ? _kToolbarIconTouch : _kToolbarIcon;
    final fixed = (touch ? _kToolbarMenuTouch : _kToolbarMenu) +
        (widget.onClose != null ? (touch ? _kToolbarCloseTouch : _kToolbarClose) : 0);
    final labelled = _kToolbarLabelExtra +
        _toolbarLabelWidth(l10n.sftpNewFolderAction) +
        (transfer ? _kToolbarLabelExtra + _toolbarLabelWidth(transferLabel) : 0);
    final actionCount = transfer ? 2 : 1;
    // How much stays out of the menu.
    final labels = width >= fixed + 4 * iconW + labelled;
    final actionsShown = labels || width >= fixed + (4 + actionCount) * iconW;
    final upRefreshShown = actionsShown || width >= fixed + 4 * iconW;
    final backForwardShown = upRefreshShown || width >= fixed + 2 * iconW;

    final transferEnabled = _selected.isNotEmpty;
    final canBack = _historyIndex > 0;
    final canForward = _historyIndex < _history.length - 1;

    Widget icon(String tooltip, IconData glyph, VoidCallback? onPressed, {Key? key}) => IconButton(
          key: key,
          tooltip: tooltip,
          icon: Icon(glyph, size: 16),
          onPressed: onPressed,
          visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
        );

    final row = Row(
      key: const ValueKey('sftp-toolbar'),
      mainAxisSize: backForwardShown ? MainAxisSize.max : MainAxisSize.min,
      children: [
        // The source picker used to lead this toolbar; it now lives in the
        // path bar (see [_buildBreadcrumbRow]) next to the path it
        // determines, so the toolbar carries only navigation + actions.
        if (backForwardShown) ...[
          icon(l10n.sftpBack, LucideIcons.arrowLeft, canBack ? _navigateBack : null),
          icon(l10n.sftpForward, LucideIcons.arrowRight, canForward ? _navigateForward : null),
        ],
        if (upRefreshShown) ...[
          icon(l10n.sftpUp, LucideIcons.arrowUp, _navigateUp),
          icon(l10n.refresh, LucideIcons.refreshCw, () => _loadDirectory(record: false)),
        ],
        // Search is no longer a toolbar toggle - it's a
        // permanent field in the path bar (see [_buildSearchField]). Having it
        // here too would be the same control twice in one pane.
        // New folder is a directory action people hunt for, and it used to be
        // reachable only from the right-click menu (§1 diagnosis). A labeled
        // button makes it discoverable; where the pane is narrow, its icon.
        if (labels)
          TextButton.icon(
            key: const ValueKey('sftp-toolbar-new-folder'),
            onPressed: _runMkdir,
            icon: const Icon(LucideIcons.folderPlus, size: 15),
            label: Text(l10n.sftpNewFolderAction,
                maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size(0, touch ? 48 : 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
            ),
          )
        else if (actionsShown)
          icon(l10n.sftpNewFolderAction, LucideIcons.folderPlus, _runMkdir,
              key: const ValueKey('sftp-toolbar-new-folder')),
        // Cross-pane transfer as a labeled button for people who don't drag:
        // "Upload" on a local pane, "Download" on a remote one. Pushes the
        // current selection to the other pane's directory (§1: half the
        // actions used to exist only as a drag or a context menu).
        if (transfer && labels)
          TextButton.icon(
            key: const ValueKey('sftp-toolbar-transfer'),
            onPressed: transferEnabled ? _transferSelection : null,
            icon: Icon(transferIcon, size: 15),
            label: Text(transferLabel, maxLines: 1, softWrap: false, style: const TextStyle(fontSize: 12)),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.textSecondary,
              disabledForegroundColor: AppColors.textSecondary.withValues(
                alpha: 0.4,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size(0, touch ? 48 : 30),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: touch ? VisualDensity.standard : VisualDensity.compact,
            ),
          )
        else if (transfer && actionsShown)
          icon(transferLabel, transferIcon, transferEnabled ? _transferSelection : null,
              key: const ValueKey('sftp-toolbar-transfer')),
        // Pushes the nav buttons to the left; the breadcrumb now
        // lives in its own full-width row below the header (see
        // [_buildBreadcrumbRow]), so this row no longer needs to
        // host it inline.
        if (backForwardShown) const Spacer(),
        // Hidden files are no longer a toolbar action: a
        // preference doesn't belong beside New folder / Upload, and it's a
        // different predicate per side. The control moved to the footer count
        // ("N items, M hidden"), where someone hunting for a filtered-out file
        // finds it at the moment they ask.
        // Overflow for the remaining preferences - view density + sort -
        // so they don't each take a permanent toolbar slot (§1); and, in a
        // narrow pane, for the toolbar's buttons that do not fit.
        PopupMenuButton<void Function()>(
          key: const ValueKey('sftp-toolbar-menu'),
          tooltip: actionsShown && backForwardShown ? l10n.sftpViewOptions : l10n.zestCommonMoreActions,
          icon: const Icon(LucideIcons.moreVertical, size: 16),
          color: AppColors.v3Elevated,
          position: PopupMenuPosition.under,
          padding: EdgeInsets.zero,
          onSelected: (fn) => fn(),
          itemBuilder: (_) => [
            // What the toolbar has no room for, in its order.
            if (!backForwardShown) ...[
              _actionMenuItem('back', LucideIcons.arrowLeft, l10n.sftpBack,
                  _historyIndex > 0 ? _navigateBack : null),
              _actionMenuItem('forward', LucideIcons.arrowRight, l10n.sftpForward,
                  _historyIndex < _history.length - 1 ? _navigateForward : null),
            ],
            if (!upRefreshShown) ...[
              _actionMenuItem('up', LucideIcons.arrowUp, l10n.sftpUp, _navigateUp),
              _actionMenuItem('refresh', LucideIcons.refreshCw, l10n.refresh, () => _loadDirectory(record: false)),
            ],
            if (!actionsShown) ...[
              _actionMenuItem('new-folder', LucideIcons.folderPlus, l10n.sftpNewFolderAction, _runMkdir),
              if (transfer)
                _actionMenuItem('transfer', transferIcon, transferLabel,
                    _selected.isNotEmpty ? _transferSelection : null),
              const PopupMenuDivider(),
            ],
            // The SFTP dock's two panes: one again from here.
            if (widget.onTwoPanes != null) ...[
              _twoPanesMenuItem(),
              const PopupMenuDivider(),
            ],
            ..._viewMenuItems(),
          ],
        ),
        // Close control - only on the right pane of an embedded SFTP view.
        // Far right, behind a separator, the same power-off glyph, size and
        // error tint every session's disconnect uses. Closes the SFTP pane
        // only; the SSH session and its terminal are untouched.
        if (widget.onClose != null) ...[
          Container(
            width: 1,
            height: 18,
            margin: const EdgeInsets.symmetric(horizontal: 5),
            color: AppColors.divider,
          ),
          IconButton(
            tooltip: l10n.sftpDockClose,
            icon: Icon(
              LucideIcons.powerOff,
              size: 16,
              color: AppColors.v3Error,
            ),
            hoverColor: AppColors.v3Error.withValues(alpha: 0.15),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 30, minHeight: 30),
            onPressed: widget.onClose,
          ),
        ],
      ],
    );
    if (backForwardShown) return Container(color: Colors.transparent, child: row);
    // Narrower than even the menu and the close control: they keep to the
    // right, and what is left of them past the pane's edge is cut off
    // rather than drawn over the next pane.
    return ClipRect(
      child: UnconstrainedBox(
        alignment: AlignmentDirectional.centerEnd,
        constrainedAxis: Axis.vertical,
        clipBehavior: Clip.hardEdge,
        child: row,
      ),
    );
  }

  /// The overflow menu's own rows, after the toolbar's buttons that have no
  /// room: the text size, and which files are hidden.
  List<PopupMenuEntry<void Function()>> _viewMenuItems() {
    final l10n = AppLocalizations.of(context)!;
    return [
      // Zoom stays open so a repeated tap keeps stepping the text size
      // until it looks right - the list behind the menu resizes live.
      // Sorting used to live here too but the column headers already do
      // it (name/size/modified/permissions), so it was the same control
      // twice; removed.
      _zoomControlsItem(),
      const PopupMenuDivider(),
      // Hidden files - a shortcut to the SAME 3-level setting as Settings
      // Radio-marked. Not a second setting.
      _hiddenLevelMenuItem(
        SftpHiddenLevel.systemOnly,
        l10n.sftpHideSystemOnly,
      ),
      _hiddenLevelMenuItem(
        SftpHiddenLevel.hiddenAndSystem,
        l10n.sftpHideHiddenAndSystem,
      ),
      _hiddenLevelMenuItem(
        SftpHiddenLevel.none,
        l10n.sftpShowAllFiles,
      ),
    ];
  }

  /// A toolbar button that has no room in a narrow pane, as a row of the
  /// overflow menu; greyed where the button would be disabled.
  PopupMenuItem<void Function()> _actionMenuItem(String id, IconData icon, String label, VoidCallback? onTap) {
    final enabled = onTap != null;
    return PopupMenuItem<void Function()>(
      key: ValueKey('sftp-menu-$id'),
      enabled: enabled,
      value: onTap,
      child: Row(
        children: [
          Icon(icon, size: 14, color: enabled ? AppColors.textSecondary : AppColors.onSurfaceDim),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: enabled ? AppColors.onSurface : AppColors.onSurfaceDim)),
        ],
      ),
    );
  }

  /// The zoom control in the overflow menu. Unlike a normal menu row it does
  /// NOT close the menu: each inner row claims its own tap (winning the gesture
  /// arena over the PopupMenuItem), so repeated taps keep stepping the font
  /// while the list resizes live behind the menu. A local [StatefulBuilder]
  /// re-reads [_fontSize] so each row greys out once it hits the min/max clamp.
  PopupMenuItem<void Function()> _zoomControlsItem() {
    return PopupMenuItem<void Function()>(
      padding: EdgeInsets.zero,
      // No-op: taps land on the inner rows and never reach this; it only fires
      // if a tap somehow hits the item's own edge, where closing is harmless.
      value: () {},
      child: StatefulBuilder(
        builder: (context, setLocal) {
          Widget zoomRow(IconData icon, String label, int steps, bool enabled) {
            final fg = enabled ? AppColors.onSurface : AppColors.onSurfaceDim;
            // Always claim the tap (even at the clamp) so the menu never closes
            // from a zoom press; _adjustFont clamps, so a press at the limit is a
            // harmless no-op and the row just greys to show there's no room left.
            return InkWell(
              onTap: () {
                _adjustFont(steps);
                setLocal(() {});
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 9,
                ),
                child: Row(
                  children: [
                    Icon(
                      icon,
                      size: 14,
                      color: enabled
                          ? AppColors.textSecondary
                          : AppColors.onSurfaceDim,
                    ),
                    const SizedBox(width: 10),
                    Text(label, style: TextStyle(fontSize: 13, color: fg)),
                  ],
                ),
              ),
            );
          }

          final l10n = AppLocalizations.of(context)!;
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              zoomRow(
                LucideIcons.zoomIn,
                l10n.desktopShortcutZoomIn,
                1,
                _fontSize < _maxFont,
              ),
              zoomRow(
                LucideIcons.zoomOut,
                l10n.desktopShortcutZoomOut,
                -1,
                _fontSize > _minFont,
              ),
            ],
          );
        },
      ),
    );
  }

  /// A hidden-files level in the overflow. Radio-marked;
  /// selecting it writes the SAME global [sftpHiddenLevelProvider] as Settings.
  PopupMenuItem<void Function()> _hiddenLevelMenuItem(
    SftpHiddenLevel level,
    String label,
  ) {
    final active = ref.read(sftpHiddenLevelProvider) == level;
    return PopupMenuItem<void Function()>(
      value: () => ref.read(sftpHiddenLevelProvider.notifier).setLevel(level),
      child: Row(
        children: [
          Icon(
            active ? LucideIcons.check : LucideIcons.eyeOff,
            size: 14,
            color: active ? AppColors.accentInk : AppColors.textSecondary,
          ),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: active ? AppColors.onSurface : AppColors.textSecondary,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }

  void _adjustFont(int steps) {
    setState(() {
      _fontSize = (_fontSize + steps).clamp(_minFont, _maxFont);
    });
  }

  Widget _buildPathEditor() {
    return TextField(
      controller: _pathEditController,
      focusNode: _pathEditFocus,
      style: const TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono'),
      // Borderless / transparent so the editor fills the --sunken pill instead
      // of drawing a second box inside it.
      decoration: const InputDecoration(
        isDense: true,
        contentPadding: EdgeInsets.symmetric(horizontal: 2, vertical: 6),
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        disabledBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        focusedErrorBorder: InputBorder.none,
      ),
      onSubmitted: (v) async {
        setState(() => _pathEditing = false);
        if (v.trim().isNotEmpty) {
          await _navigateTo(v.trim());
        }
      },
      onTapOutside: (_) => setState(() => _pathEditing = false),
    );
  }

  /// Expand the search field over the breadcrumb and focus it.
  void _expandSearch() {
    setState(() => _searchExpanded = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _searchFocus.requestFocus();
    });
  }

  /// The search field, shown while expanded and filling the path bar:
  /// typing filters the current directory live; on a remote pane Enter
  /// escalates to a recursive server-side search; Escape collapses back to the
  /// breadcrumb (the filter lingers, marked by the icon dot); the X clears it.
  Widget _buildSearchField() {
    final isRemote = widget.source is RemotePaneFileSource;
    final l10n = AppLocalizations.of(context)!;
    // The placeholder states the split so the two behaviours are discoverable.
    final hint = isRemote
        ? l10n.sftpFilterRemoteHint(_path)
        : l10n.sftpFilterFilesHint;
    // The query and the visible list are ONE state: there is never a filter
    // applied without its field on screen (spec 2.3). So Escape with text
    // clears the filter but keeps the field; Escape on an empty field collapses.
    void clearFilter() {
      setState(() {
        _searchQuery = '';
        _searchController.clear();
      });
      _searchFocus.requestFocus();
    }

    void collapse() {
      setState(() => _searchExpanded = false);
      _searchFocus.unfocus();
      _listFocus.requestFocus();
    }

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (_searchQuery.isNotEmpty) {
            clearFilter();
          } else {
            collapse();
          }
        },
      },
      // Explicit geometry (spec 2.2): icon 10px in at 12px square, 8px gap so
      // text starts at 30px, clear button 24px square 4px from the right. The
      // pill (which drops its padding while searching) supplies the fill and
      // brand ring, so the field is transparent, borderless, vertically centred.
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            const SizedBox(width: 10),
            Icon(
              LucideIcons.search,
              size: 12,
              color: AppColors.textSecondary,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: _searchController,
                focusNode: _searchFocus,
                style: const TextStyle(fontSize: 12.5),
                textInputAction: isRemote
                    ? TextInputAction.search
                    : TextInputAction.none,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                  hintText: hint,
                  hintStyle: TextStyle(
                    fontSize: 11.5,
                    color: AppColors.textSecondary,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                ),
                onChanged: (v) => setState(() => _searchQuery = v),
                onSubmitted: (_) {
                  if (isRemote) unawaited(_runRecursiveSearch());
                },
                // Clicking away from an EMPTY filter collapses back to the
                // breadcrumb. A non-empty filter stays put and visible - the
                // list is never filtered with the field off screen (spec 2.3).
                onTapOutside: (_) {
                  if (_searchExpanded && _searchQuery.trim().isEmpty) {
                    setState(() => _searchExpanded = false);
                    _searchFocus.unfocus();
                  }
                },
              ),
            ),
            if (_searchQuery.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: SizedBox(
                  width: 24,
                  height: 24,
                  child: IconButton(
                    tooltip: l10n.zestCommonClear,
                    icon: const Icon(LucideIcons.x, size: 13),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 24,
                      minHeight: 24,
                    ),
                    // Same as Escape with text: clear the filter, restore the
                    // full listing, keep focus in the field (spec 2.3).
                    onPressed: clearFilter,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Escalate the current filter query to a recursive remote name search, then
  /// reveal whatever the user picks (navigate into a folder, or to a file's
  /// parent with it selected).
  Future<void> _runRecursiveSearch() async {
    final source = widget.source;
    if (source is! RemotePaneFileSource) return;
    final query = _searchQuery.trim();
    if (query.isEmpty) return;
    final picked = await SftpSearchResultsDialog.show(
      context,
      service: source.service,
      root: _path,
      query: query,
    );
    if (picked == null || !mounted) return;
    if (picked.isDirectory) {
      await _navigateTo(picked.path);
    } else {
      await _navigateTo(widget.source.parentOf(picked.path));
      if (mounted) {
        setState(() {
          _selected
            ..clear()
            ..add(picked.path);
        });
      }
    }
  }

  /// A subtle draggable divider that resizes the metadata column to its right;
  /// the flexible Name column absorbs the delta, so nothing clips and the pane
  /// scrolls horizontally only once the columns genuinely overflow.
  Widget _colResizeHandle(void Function(double dx) apply) {
    return _ColumnResizeHandle(
      width: _colGutter,
      onStart: () => setState(() => _resizingColumn = true),
      onDelta: (dx) => setState(() => apply(dx)),
      onEnd: () => setState(() => _resizingColumn = false),
    );
  }

  Widget _buildColumnHeader() {
    final l10n = AppLocalizations.of(context)!;
    Widget cell(
      String label,
      _SortColumn col, {
      double? width,
      bool flex = false,
      bool rightAlign = false,
    }) {
      final active = _sortBy == col;
      final touch = touchSizedAt(context);
      final row = Row(
        mainAxisAlignment: rightAlign
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              // Sort state is not an action: the active header reads
              // as bright --text, inactive headers as dim --muted-2 - never
              // accent. The column stays identifiable by weight + the caret.
              color: active ? AppColors.onSurface : AppColors.onSurfaceDim,
            ),
          ),
          if (active) ...[
            const SizedBox(width: 2),
            Icon(
              _sortAsc ? LucideIcons.chevronUp : LucideIcons.chevronDown,
              size: 11,
              color: AppColors.onSurfaceDim,
            ),
          ],
        ],
      );
      // To a screen reader the column and how the list is sorted by it (the
      // caret said it to the eye only); 48 high to a finger.
      final tappable = Semantics(
        button: true,
        label: active ? '$label, ${_sortAsc ? l10n.a11ySortedUp : l10n.a11ySortedDown}' : label,
        excludeSemantics: true,
        onTap: () => _onHeaderTap(col),
        child: InkWell(
          onTap: () => _onHeaderTap(col),
          child: ConstrainedBox(constraints: BoxConstraints(minHeight: touch ? 48 : 0), child: row),
        ),
      );
      return flex
          ? Expanded(child: tappable)
          : SizedBox(width: width, child: tappable);
    }

    return Container(
      padding: EdgeInsets.symmetric(horizontal: 12, vertical: touchSizedAt(context) ? 0 : 6),
      decoration: BoxDecoration(
        // Column header is pane chrome, so it sits on --panel like the pane,
        // separated only by its bottom hairline.
        color: AppColors.sftpPanel,
        border: Border(bottom: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          const SizedBox(width: _kIconCol),
          // WinSCP-style: each column is explicit and its RIGHT-edge divider
          // resizes THAT column, so a drag shifts everything to its right; the
          // trailing spacer fills any slack.
          cell(l10n.sftpColumnName, _SortColumn.name, width: _effNameW),
          _colResizeHandle(
            (dx) => _wName = ((_wName ?? _effNameW) + dx)
                .clamp(_wNameMin, _wNameMax)
                .toDouble(),
          ),
          cell(l10n.sftpColumnSize, _SortColumn.size,
              width: _wSize, rightAlign: true),
          _colResizeHandle(
            (dx) =>
                _wSize = (_wSize + dx).clamp(_wSizeMin, _wSizeMax).toDouble(),
          ),
          cell(l10n.sftpColumnModified, _SortColumn.modified,
              width: _wModified),
          _colResizeHandle(
            (dx) => _wModifiedSet = (_wModified + dx)
                .clamp(_wModifiedMin, _wModifiedMax)
                .toDouble(),
          ),
          // Perms is the last column, so it has no right-edge divider (nothing
          // is to its right to push); it stays a fixed width. On Windows it
          // holds the Windows attributes instead (see [_windowsLocal]).
          cell(
              _windowsLocal
                  ? l10n.sftpColumnAttributes
                  : l10n.sftpColumnPerms,
              _SortColumn.permissions,
              width: _wPerms),
          const Spacer(),
        ],
      ),
    );
  }

  Widget _buildBody(List<PaneFileEntry> visible) {
    // A "target not readable" warning that fires on most rows isn't a warning.
    // Warn-tint broken links only when they're a genuine
    // minority; otherwise they drop to muted so the eye isn't pulled to noise.
    final linkRows = visible.where((e) => e.isSymlink).length;
    final brokenRows = visible
        .where((e) => e.isSymlink && e.linkTarget == null)
        .length;
    _demoteBrokenLinks = linkRows > 0 && brokenRows > linkRows / 4;
    final l10n = AppLocalizations.of(context)!;
    if (_loading) {
      // A spinner WITH the path being listed - never a bare spinner that could
      // be mistaken for an empty directory (§8).
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.brandOrange),
            const SizedBox(height: 14),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                _path.isEmpty ? l10n.sftpLoading : l10n.sftpLoadingPath(_path),
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                maxLines: 2,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ),
          ],
        ),
      );
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.alertCircle, size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: 6),
            // Name the path the error is about - "permission denied" is far more
            // actionable when you can see which directory refused you (§8).
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: Text(
                _path,
                textAlign: TextAlign.center,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: AppColors.textSecondary,
                  fontFamily: 'JetBrainsMono',
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _retryAfterFailure,
              icon: const Icon(LucideIcons.refreshCw),
              label: Text(l10n.retry),
            ),
            if (_errorDetail != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: CopyDetailsButton(detail: _errorDetail!),
              ),
          ],
        ),
      );
    }
    if (visible.isEmpty) {
      // Empty directory - still wire it up as a DragTarget so users
      // can drop files INTO an empty folder without having to first
      // upload a placeholder. Search-no-matches is also "empty" but
      // dropping there doesn't make sense (the filter, not the dir,
      // is what's hiding things), so it stays inert.
      if (_searchQuery.isNotEmpty) {
        return ZestEmptyState(
          icon: LucideIcons.searchX,
          title: l10n.sftpNoFilesMatching(_searchQuery),
        );
      }
      // Right-click anywhere in an EMPTY directory must still open the "New
      // folder / New file / …" background menu. The populated list wires this
      // through _onListPointerDown, but this branch renders a different subtree
      // with no row list, so without its own pointer hook an empty folder has
      // nothing to right-click (the reported regression).
      return Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onEmptyDirPointerDown,
        child: DragTarget<PaneDragPayload>(
        onWillAcceptWithDetails: (d) => d.data.paneSide != widget.paneSide,
        onAcceptWithDetails: (d) {
          setState(() => _isBeingDroppedOn = false);
          widget.onInterPaneDrop(d.data, _path);
        },
        onMove: (_) {
          if (!_isBeingDroppedOn) {
            setState(() => _isBeingDroppedOn = true);
          }
        },
        onLeave: (_) => setState(() => _isBeingDroppedOn = false),
        builder: (context, candidates, _) {
          final hovering = candidates.isNotEmpty;
          return Container(
            decoration: BoxDecoration(
              color: hovering
                  ? AppColors.brandOrange.withValues(alpha: 0.06)
                  : null,
              border: hovering
                  ? Border.all(color: AppColors.brandOrange, width: 2)
                  : null,
            ),
            child: hovering
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.folderInput,
                          size: 48,
                          color: AppColors.accentInk,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          l10n.sftpDropToTransfer,
                          style: TextStyle(
                            color: AppColors.accentInk,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : ZestEmptyState(
                    icon: LucideIcons.folderOpen,
                    title: l10n.sftpEmptyDirectory,
                    // The "drop files here" hint only makes sense on the remote
                    // side - the common flow is uploading INTO a remote dir (§8).
                    message: widget.source is RemotePaneFileSource
                        ? l10n.sftpEmptyDragHint
                        : null,
                  ),
          );
        },
        ),
      );
    }

    return DragTarget<PaneDragPayload>(
      // Accept drops from the OTHER pane only - our own selection
      // shouldn't bounce back as a drop.
      onWillAcceptWithDetails: (d) => d.data.paneSide != widget.paneSide,
      onAcceptWithDetails: (d) {
        setState(() => _isBeingDroppedOn = false);
        widget.onInterPaneDrop(d.data, _path);
      },
      onMove: (_) {
        if (!_isBeingDroppedOn) {
          setState(() => _isBeingDroppedOn = true);
        }
      },
      onLeave: (_) => setState(() => _isBeingDroppedOn = false),
      builder: (context, candidates, _) {
        return Container(
          decoration: BoxDecoration(
            border: _isBeingDroppedOn
                ? Border.all(color: AppColors.brandOrange, width: 2)
                : null,
          ),
          // The Listener observes pointer events without participating
          // in the gesture arena - the row Draggables still claim
          // pointer-down on rows. We only act when the pointer-down
          // landed in EMPTY space (past the last row), which is the
          // rubber-band trigger.
          child: Listener(
            behavior: HitTestBehavior.translucent,
            onPointerDown: (e) => _onListPointerDown(e, visible.length),
            onPointerMove: (e) => _onListPointerMove(e, visible),
            onPointerUp: _onListPointerUp,
            onPointerCancel: (_) =>
                _onListPointerUp(const PointerUpEvent(position: Offset.zero)),
            onPointerSignal: (event) {
              if (event is PointerScrollEvent &&
                  HardwareKeyboard.instance.isControlPressed) {
                final delta = event.scrollDelta.dy;
                setState(() {
                  _fontSize = (_fontSize + (delta < 0 ? 1 : -1)).clamp(
                    _minFont,
                    _maxFont,
                  );
                });
              }
            },
            child: Stack(
              children: [
                ListView.builder(
                  controller: _scrollController,
                  // Bottom breathing room so the horizontal scrollbar (drawn at
                  // the bottom of the list area on a narrow pane) never overlaps
                  // the last row.
                  padding: const EdgeInsets.only(bottom: 18),
                  itemCount: visible.length,
                  itemBuilder: (context, index) {
                    final entry = visible[index];
                    return _buildRow(entry, index, visible);
                  },
                ),
                // Rubber-band rectangle overlay. Drawn in viewport
                // (local) coordinates - converted from content-space
                // via the live scroll offset so it stays anchored to
                // the rows even when the list auto-scrolls.
                if (_rubberBandActive &&
                    _rubberBandStart != null &&
                    _rubberBandCurrent != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: CustomPaint(
                        painter: _RubberBandPainter(
                          start: _rubberBandStart!,
                          current: _rubberBandCurrent!,
                          scrollOffset: _scrollController.hasClients
                              ? _scrollController.offset
                              : 0.0,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildRow(
    PaneFileEntry entry,
    int index,
    List<PaneFileEntry> visible,
  ) {
    final isSelected = _selected.contains(entry.path);
    final color = _fileColor(entry.name, entry.isDirectory);
    final fontSize = _fontSize;

    return Draggable<PaneDragPayload>(
      // Under a finger (a tablet, 4.0) a drag up or down scrolls the
      // list; files are dragged sideways (to the other pane).
      affinity: touchSizedAt(context) ? Axis.horizontal : null,
      data: PaneDragPayload(
        paneSide: widget.paneSide,
        // If the dragged row is one of the selected ones, drag the whole
        // selection. Otherwise just this single row.
        entries: isSelected ? _selectedEntries(visible) : [entry],
      ),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.surfaceLight,
            borderRadius: BorderRadius.circular(6),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 8,
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Builder(
                builder: (_) {
                  final glyph = _iconForEntry(entry);
                  return Icon(glyph.icon, size: 16, color: glyph.color);
                },
              ),
              const SizedBox(width: 6),
              Text(
                isSelected && _selected.length > 1
                    ? AppLocalizations.of(context)!
                        .sftpFileCount(_selected.length)
                    : visibleCommand(entry.name),
                style: TextStyle(fontSize: fontSize - 1, color: color),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        // Drag-in-progress placeholder doesn't need hover styling
        // since the cursor is on the floating feedback widget.
        child: _buildRowContent(entry, isSelected, false, color, fontSize),
      ),
      child: entry.isDirectory
          ? DragTarget<PaneDragPayload>(
              // Folder rows act as drop targets so the user can drop
              // files DIRECTLY into a folder without navigating into
              // it first. Standard Explorer / Finder behaviour.
              onWillAcceptWithDetails: (d) {
                // Cross-pane drop = copy/transfer INTO this folder. Same-pane
                // drop = MOVE into this folder - accepted now (it used to be
                // rejected as unwired), except onto the folder itself.
                if (d.data.paneSide != widget.paneSide) return true;
                return !d.data.entries.any((e) => e.path == entry.path);
              },
              onAcceptWithDetails: (d) {
                if (d.data.paneSide != widget.paneSide) {
                  widget.onInterPaneDrop(d.data, entry.path);
                } else {
                  // Same-pane move into the folder: a rename, so no confirm -
                  // it happens with an Undo toast (spec 1.4).
                  unawaited(
                    _moveIntoFolder(d.data.entries, entry.path, entry.name),
                  );
                }
              },
              builder: (context, candidates, _) {
                final dropping = candidates.isNotEmpty;
                return Container(
                  decoration: BoxDecoration(
                    color: dropping
                        ? AppColors.brandOrange.withValues(alpha: 0.18)
                        : null,
                  ),
                  // Painted over the row, so the highlight takes no room (as
                  // the row's own border it narrowed the row by 3 px, which
                  // then overflowed while something was dragged over it).
                  foregroundDecoration: BoxDecoration(
                    border: dropping
                        ? Border.all(color: AppColors.brandOrange, width: 1.5)
                        : null,
                  ),
                  child: _HoverableSftpRow(
                    semanticLabel: _rowSentence(entry),
                    selected: isSelected,
                    onTap: (ctrl, shift) =>
                        _onFileTap(entry, index, visible, ctrl, shift),
                    onDoubleTap: () => _onFileDoubleTap(entry),
                    onSecondaryTapDown: (pos) =>
                        _showRowContextMenu(context, pos, entry, visible),
                    builder: (hovering) => _buildRowContent(
                      entry,
                      isSelected,
                      hovering,
                      color,
                      fontSize,
                    ),
                  ),
                );
              },
            )
          : _HoverableSftpRow(
              semanticLabel: _rowSentence(entry),
              selected: isSelected,
              onTap: (ctrl, shift) =>
                  _onFileTap(entry, index, visible, ctrl, shift),
              onDoubleTap: () => _onFileDoubleTap(entry),
              onSecondaryTapDown: (pos) =>
                  _showRowContextMenu(context, pos, entry, visible),
              builder: (hovering) => _buildRowContent(
                entry,
                isSelected,
                hovering,
                color,
                fontSize,
              ),
            ),
    );
  }

  /// A row as a screen reader says it: its name, a folder or where a link
  /// points, its size, when it changed, and Hidden where it is.
  String _rowSentence(PaneFileEntry entry) {
    final l10n = AppLocalizations.of(context)!;
    final name = visibleCommand(entry.name);
    final unreadable =
        (entry.isSymlink && entry.linkTarget == null) || (entry.permissions == null && entry.modifiedAt == null);
    return [
      name,
      if (entry.isSymlink)
        entry.linkTarget == null ? l10n.sftpTargetNotReadable : l10n.sftpLinkTo(visibleCommand(entry.linkTarget!))
      else if (entry.isDirectory)
        l10n.a11yFileKindFolder,
      if (!entry.isDirectory && entry.formattedSize.isNotEmpty) entry.formattedSize,
      if (unreadable)
        l10n.sftpOverwriteNotReadable
      else if (entry.modifiedAt != null)
        l10n.a11yFileModified(_timeFormat.dateTime(entry.modifiedAt!)),
      if (entry.isHidden || entry.isSystemHidden) l10n.a11yFileHidden,
    ].join(', ');
  }

  Widget _buildRowContent(
    PaneFileEntry entry,
    bool isSelected,
    bool hovering,
    Color color,
    double fontSize,
  ) {
    // Background priority: selected (strongest) > hovering (subtle)
    // > nothing. Keeps the row that has the cursor visually obvious
    // even when nothing is selected - the user always knows which
    // entry their next click / drag will land on.
    final Color? bg;
    if (isSelected) {
      // Selected: brand wash 7% + a 1px brand-30% inset border.
      // The border, not the wash, is what separates it from hover.
      bg = AppColors.brandOrange.withValues(alpha: 0.07);
    } else if (hovering) {
      // Hover lifts the row to --raised (#161619).
      bg = AppColors.surface;
    } else {
      bg = null;
    }
    // A link we couldn't resolve, or a stat that came back empty, can't show
    // trustworthy perms/date - render "Not readable" rather than the link's own
    // stat, blank cells, or a zeroed 1970/---------- fallback. This
    // is the fix for a Windows deny-ACL junction that stats to mode 0 + epoch.
    final brokenLink = entry.isSymlink && entry.linkTarget == null;
    final unreadable =
        brokenLink || (entry.permissions == null && entry.modifiedAt == null);
    // Orange is reserved for actions + selection. A broken link is
    // warn-tinted only when broken links are a genuine minority in this listing
    // (see [_demoteBrokenLinks]); otherwise it reads muted, not alarmed.
    final warn = brokenLink && !_demoteBrokenLinks;
    final Color issueColor = warn ? AppColors.warning : AppColors.onSurfaceDim;
    // "Not readable" cells sit in --dim - never a value, never mono.
    final TextStyle metaStyle = TextStyle(
      fontSize: fontSize - 2,
      color: AppColors.textSecondary,
      fontFamily: 'JetBrainsMono',
    );
    final TextStyle naStyle = TextStyle(
      fontSize: fontSize - 2,
      color: AppColors.onSurfaceDim,
      fontStyle: FontStyle.italic,
    );
    // Hidden entries (dotfiles + OS-hidden) render dimmed even while shown, so a
    // directory whose hidden items are revealed still reads at a glance - the
    // useful files stay bright, the usually-noise ones (.git, .DS_Store, .env)
    // sit back. Mirrors Explorer's faded treatment. Icon, name, and metadata all
    // dim together; the row's selection/hover chrome stays full strength.
    final hidden = entry.isHidden || entry.isSystemHidden;
    final l10n = AppLocalizations.of(context)!;
    // The name is the server's to choose: what would hide or reorder it, or be
    // a key in a terminal, shows as what it is (`\x15`, `\u202e`), so the row
    // reads what is there.
    final shownName = visibleCommand(entry.name);
    return Container(
      height: max(24, fontSize * 2.2),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: bg),
      // A 1px brand inset border on the SELECTED row so selection reads
      // distinct from the hover wash. It is painted over the
      // row, so it takes no room: as part of the row's decoration it narrowed
      // every row by 2 px that the column widths do not count, so each row
      // overflowed and its last column was cut short (3.0).
      foregroundDecoration: BoxDecoration(
        border: Border.all(
          color: isSelected
              ? AppColors.brandOrange.withValues(alpha: 0.30)
              : Colors.transparent,
          width: 1,
        ),
      ),
      child: Opacity(
        opacity: hidden ? 0.55 : 1.0,
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: Builder(
                builder: (_) {
                  final glyph = _iconForEntry(entry);
                  return Icon(
                    glyph.icon,
                    size: fontSize + 2,
                    // A resolvable entry keeps its category tint; an unreadable one
                    // takes the issue colour - warn for the genuine-broken minority,
                    // otherwise muted, so a list full of unresolved links stays calm.
                    color: unreadable ? issueColor : glyph.color,
                  );
                },
              ),
            ),
            // Name is an explicit column (WinSCP-style), sharing _effNameW with
            // the header so the divider stays aligned with the rows below.
            SizedBox(
              width: _effNameW,
              // Hovering the name reveals the full, untruncated name (and a
              // symlink's target) so a clipped long name can still be read in
              // full without widening the column.
              child: Tooltip(
                message: entry.isSymlink && entry.linkTarget != null
                    ? l10n.sftpLinkTooltip(shownName, visibleCommand(entry.linkTarget!))
                    : shownName,
                waitDuration: const Duration(milliseconds: 500),
                child: entry.isSymlink
                  ? Row(
                      children: [
                        Flexible(
                          child: Text(
                            shownName,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: fontSize - 1,
                              color: color,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        if (entry.linkTarget != null)
                          // "to <target>" in mono muted - the link IS the
                          // information, not a 1970 fallback row.
                          // The target is the click target: tapping it follows
                          // the link (underlined to read as actionable).
                          Flexible(
                            child: MouseRegion(
                              cursor: SystemMouseCursors.click,
                              child: GestureDetector(
                                onTap: () => unawaited(_followSymlink(entry)),
                                child: Text(
                                  l10n.sftpLinkTo(visibleCommand(entry.linkTarget!)),
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: fontSize - 2,
                                    color: AppColors.textSecondary,
                                    fontFamily: 'JetBrainsMono',
                                    decoration: TextDecoration.underline,
                                    decorationColor: AppColors.divider,
                                  ),
                                ),
                              ),
                            ),
                          )
                        else
                          // Couldn't resolve where it points - say so, but muted
                          // (warn only for a genuine minority), never a blank
                          // target or a 1970 fallback stat.
                          Text(
                            l10n.sftpTargetNotReadable,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: fontSize - 2,
                              color: issueColor,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                      ],
                    )
                  // End-ellipsis like every other column, so a long name reads
                  // left to right and clips on the right (not mid-name).
                  : Text(
                      shownName,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: fontSize - 1, color: color),
                    ),
              ),
            ),
            const SizedBox(width: _colGutter),
            SizedBox(
              width: _wSize,
              child: Text(
                entry.formattedSize,
                textAlign: TextAlign.right,
                style: metaStyle,
              ),
            ),
            const SizedBox(width: _colGutter),
            SizedBox(
              width: _wModified,
              child: Text(
                unreadable
                    ? l10n.sftpOverwriteNotReadable
                    : (entry.modifiedAt != null
                          ? _timeFormat.dateTime(entry.modifiedAt!)
                          : ''),
                overflow: TextOverflow.ellipsis,
                style: unreadable ? naStyle : metaStyle,
              ),
            ),
            const SizedBox(width: _colGutter),
            SizedBox(
              width: _wPerms,
              child: _windowsLocal && !unreadable
                  ? _attributeCell(entry, metaStyle)
                  : Text(
                      unreadable
                          ? l10n.sftpOverwriteNotReadable
                          : (entry.permissions ?? ''),
                      overflow: TextOverflow.ellipsis,
                      style: unreadable ? naStyle : metaStyle,
                    ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  /// The name of a Windows attribute letter (R, H, S), for its tooltip.
  String? _attributeName(AppLocalizations l10n, String letter) =>
      switch (letter) {
        'R' => l10n.sftpAttrReadOnly,
        'H' => l10n.sftpAttrHidden,
        'S' => l10n.sftpAttrSystem,
        _ => null,
      };

  /// A Windows row's Attributes cell: a small badge per attribute that is set
  /// (R, H, S, each named in a tooltip), or a dash when none is.
  Widget _attributeCell(PaneFileEntry entry, TextStyle metaStyle) {
    final l10n = AppLocalizations.of(context)!;
    final letters = entry.windowsAttributes ?? '';
    if (letters.isEmpty) {
      return Text('-',
          style: metaStyle.copyWith(color: AppColors.onSurfaceDim));
    }
    final badgeStyle = metaStyle.copyWith(
      fontSize: (metaStyle.fontSize ?? 11) - 2,
      fontWeight: FontWeight.w600,
    );
    return Row(
      children: [
        for (final letter in letters.split(''))
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Tooltip(
              message: _attributeName(l10n, letter) ?? letter,
              waitDuration: const Duration(milliseconds: 400),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.surfaceContainer,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(letter, style: badgeStyle),
              ),
            ),
          ),
      ],
    );
  }

  /// Color for the *text* of a file row. Folders → orange, files → the
  /// default text color so the long filenames stay readable. The icon
  /// gets its category tint separately (see [_iconForEntry]).
  Color _fileColor(String name, bool isDirectory) {
    // Colour discipline (B1): directories read as a BRIGHT neutral and files
    // as a DIMMER neutral - they're told apart by the folder icon, not by
    // hue. Accent is reserved for the selected row (its background tint) and
    // the current path segment, so selection stays legible instead of being
    // lost in a listing where every directory was already orange.
    return isDirectory ? AppColors.onSurface : AppColors.onSurfaceVariant;
  }

  /// Resolve the (icon, color) pair for a row's leading glyph. Folders
  /// always render as the standard folder icon in orange.
  SftpIconStyle _iconForEntry(PaneFileEntry entry) {
    // Symbolic links get their own glyph. They behave differently from
    // what they point at - a recursive copy skips a linked directory and a
    // recursive delete removes the link rather than its target - so the
    // list has to make them distinguishable instead of showing a link to a
    // folder as an ordinary folder.
    if (entry.isSymlink) {
      return SftpIconStyle(LucideIcons.link, AppColors.v3TextSecondary);
    }
    if (entry.isDirectory) {
      // Directories are the one file-TYPE distinction worth a colour:
      // the lighter brand tint, distinct from the accent reserved for
      // actions + selection. Files stay muted; the glyph does the rest.
      return SftpIconStyle(LucideIcons.folder, AppColors.brandHi);
    }
    return resolveSftpFileIcon(entry.name);
  }

  // ── Context menu ─────────────────────────────────────────────────

  Future<void> _showRowContextMenu(
    BuildContext context,
    Offset position,
    PaneFileEntry entry,
    List<PaneFileEntry> visible,
  ) async {
    // If clicked row is not in selection, replace selection with just it.
    if (!_selected.contains(entry.path)) {
      setState(() {
        _selected
          ..clear()
          ..add(entry.path);
      });
    }
    // Pull keyboard focus to the list so the user can press Enter to
    // dismiss the right-click → Delete confirmation without Tab-ing.
    _listFocus.requestFocus();

    final selectionTargets = _selectedEntries(visible);
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final l10n = AppLocalizations.of(context)!;

    final selected = await showMenu<_PaneMenuAction>(
      context: context,
      color: AppColors.v3Elevated,
      position: RelativeRect.fromRect(
        position & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        if (selectionTargets.length == 1)
          PopupMenuItem(
            value: _PaneMenuAction.openInEditor,
            child: _MenuRow(
              icon: entry.isSymlink
                  ? LucideIcons.externalLink
                  : (entry.isDirectory
                        ? LucideIcons.folderOpen
                        : LucideIcons.fileEdit),
              label: entry.isSymlink
                  ? l10n.sftpFollowLink
                  : (entry.isDirectory
                        ? l10n.hostsHomeMenuOpen
                        : l10n.sftpOpenInEditor),
            ),
          ),
        // Live-tail a remote log - the sysadmin's daily driver, and something a
        // downloaded snapshot can't do. Single remote file only.
        if (selectionTargets.length == 1 &&
            widget.source is RemotePaneFileSource &&
            !entry.isDirectory &&
            !entry.isSymlink)
          PopupMenuItem(
            value: _PaneMenuAction.tailFile,
            child: _MenuRow(
              icon: LucideIcons.scrollText,
              label: l10n.sftpFollowLiveTail,
            ),
          ),
        // "Open terminal here" belongs on the DIRECTORY menu -
        // the highest-value action in the audit, one click from a shell in that
        // folder. Remote directories only.
        if (entry.isDirectory && widget.onOpenTerminalHere != null)
          PopupMenuItem(
            value: _PaneMenuAction.openTerminalHere,
            child: _MenuRow(
              icon: LucideIcons.terminal,
              label: l10n.sftpOpenTerminalHere,
            ),
          ),
        PopupMenuItem(
          value: _PaneMenuAction.rename,
          child: _MenuRow(
              icon: LucideIcons.pencil, label: l10n.sftpRenameEllipsis),
        ),
        PopupMenuItem(
          value: _PaneMenuAction.mkdir,
          child: _MenuRow(
              icon: LucideIcons.folderPlus, label: l10n.sftpNewFolderEllipsis),
        ),
        // Windows has no Unix permissions: the dialog could change nothing.
        if (!_windowsLocal)
          PopupMenuItem(
            value: _PaneMenuAction.chmod,
            child: _MenuRow(
                icon: LucideIcons.shield, label: l10n.sftpPermissionsEllipsis),
          ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PaneMenuAction.copyPath,
          child: _MenuRow(
              icon: LucideIcons.copy, label: l10n.sftpCopyPathAction),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PaneMenuAction.delete,
          child: _MenuRow(
            icon: LucideIcons.trash2,
            label: l10n.delete,
            destructive: true,
          ),
        ),
      ],
    );

    if (!mounted || selected == null) return;
    switch (selected) {
      case _PaneMenuAction.openInEditor:
        // Route through the same activation path as double-tap/Enter so a
        // symlink follows its target (dir→navigate, file→open) and a directory
        // opens, instead of trying to open the link/dir itself in the editor.
        _onFileDoubleTap(entry);
      case _PaneMenuAction.tailFile:
        await _runLiveTail(entry);
      case _PaneMenuAction.rename:
        await _runRename(entry);
      case _PaneMenuAction.mkdir:
        await _runMkdir();
      case _PaneMenuAction.chmod:
        await _runChmod(selectionTargets);
      case _PaneMenuAction.copyPath:
        // A real remote path goes to the clipboard: reveal gate (spec 5).
        if (!await confirmRevealWhileRecording(context, ref)) break;
        if (!context.mounted) break;
        await Clipboard.setData(ClipboardData(text: entry.path));
        // The `context` parameter belongs to the caller of
        // _showRowContextMenu - check it explicitly rather than the
        // State's `mounted` so we don't paint a snackbar into a torn-
        // down menu host.
        if (context.mounted) {
          showTopSnackBar(
            context,
            l10n.sftpPathCopied,
            duration: const Duration(seconds: 1),
          );
        }
      case _PaneMenuAction.delete:
        await _runDelete(selectionTargets);
      case _PaneMenuAction.openTerminalHere:
        // Open a shell in the right-clicked directory.
        widget.onOpenTerminalHere?.call(entry.path);
      // Empty-area-only actions; not reachable from this row menu.
      case _PaneMenuAction.newFile:
      case _PaneMenuAction.refresh:
      case _PaneMenuAction.pastePath:
      case _PaneMenuAction.mirrorFolder:
        break;
    }
  }

  Future<void> _runRename(PaneFileEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    // A rename the host refused for want of permission, where sudo may do it
    // (3.4): the dialog closes, and the notice offers Retry with sudo.
    ({String to, Object error})? denied;
    final result = await showZestInputDialog(
      context: context,
      title: l10n.sftpRename,
      icon: LucideIcons.pencil,
      fieldLabel: l10n.sftpNewNameLabel,
      initialValue: entry.name,
      confirmLabel: l10n.sftpRename,
      busyLabel: l10n.sftpRenaming,
      // Preselect the stem, leave the extension untouched (A1); a folder's
      // whole name, as file managers do.
      selectOnFocus:
          entry.isDirectory ? ZestFieldSelect.all : ZestFieldSelect.stem,
      validator: (v) => _validateFileName(v, l10n),
      // Do the rename inside the dialog so a failure surfaces inline
      // instead of closing the dialog and firing a toast (A1).
      onConfirm: (v) async {
        final name = v.trim();
        if (name == entry.name) return null; // no-op - just close
        final newPath = widget.source.join(
          widget.source.parentOf(entry.path),
          name,
        );
        try {
          await widget.source.rename(entry.path, newPath);
          return null;
        } catch (e) {
          // (Said in the dialog, as before, where sudo could not run it.)
          if (isPermissionDenied(e) && widget.source.sudoOps() != null && SudoMove(entry.path, newPath).runnable) {
            denied = (to: newPath, error: e);
            return null;
          }
          return sftpErrorMessage(e, name: entry.name, op: SftpOp.rename);
        }
      },
    );
    if (result == null) return;
    final refused = denied;
    if (refused != null) {
      _offerSudo([SudoMove(entry.path, refused.to)], shownPath: entry.path, details: '${refused.error}');
      return;
    }
    if (mounted) await refresh();
  }

  /// The host's name, for what is said of what it refused.
  String get _hostLabel => widget.sourceDescriptor.hostName ?? '';

  /// Says that the host refused [ops] for want of permission, with Retry
  /// with sudo where this pane's host can run it (3.4); the folder is listed
  /// again once something was done.
  void _offerSudo(List<SudoFileOp> ops, {required String shownPath, String? details}) {
    if (!mounted || ops.isEmpty) return;
    offerSudoRetry(
      context,
      sudo: widget.source.sudoOps(),
      host: _hostLabel,
      ops: ops,
      shownPath: shownPath,
      details: details,
      onDone: () {
        if (mounted) unawaited(refresh());
      },
    );
  }

  /// Move [entries] INTO the folder [targetDir] (a same-pane drag onto a folder
  /// row). A move within one host is a rename: atomic, instant, and trivially
  /// reversible, so it does NOT confirm - it performs the move and offers Undo
  /// in a toast for a few seconds (spec 1.4). Never moves a folder into itself.
  Future<void> _moveIntoFolder(
    List<PaneFileEntry> entries,
    String targetDir,
    String targetName,
  ) async {
    final moving = entries.where((e) => e.path != targetDir).toList();
    if (moving.isEmpty) return;

    final failures = <({String name, Object error})>[];
    // Those the host refused for want of permission, where sudo may move them
    // (3.4: Retry with sudo).
    final denied = <({String from, String to, Object error})>[];
    final canSudo = widget.source.sudoOps() != null;
    // (destination, original path, name) for each successful move, so Undo can
    // rename each back to where it came from.
    final undo = <({String from, String to, String name})>[];
    for (final e in moving) {
      // safeChildName strips separators / `..` so a malicious server-supplied
      // entry name can't escape targetDir on the move (matches every other
      // join site - see sftp_dual_pane_screen._safeChild).
      final dest = widget.source.join(targetDir, safeChildName(e.name));
      try {
        await widget.source.rename(e.path, dest);
        undo.add((from: dest, to: e.path, name: e.name));
      } catch (err) {
        if (canSudo && isPermissionDenied(err)) {
          denied.add((from: e.path, to: dest, error: err));
        } else {
          failures.add((name: e.name, error: err));
        }
      }
    }
    if (!mounted) return;
    setState(() {
      for (final e in moving) {
        _selected.remove(e.path);
      }
    });
    await refresh();
    if (!mounted) return;

    final l10n = AppLocalizations.of(context)!;
    final moved = undo.length;
    if (denied.isNotEmpty) {
      _offerSudo(
        [for (final d in denied) SudoMove(d.from, d.to)],
        shownPath: denied.first.from,
        details: [for (final d in denied) '${d.error}'].join('\n'),
      );
      if (moved == 0 && failures.isEmpty) return;
    }
    if (moved > 0) {
      final base = moved == 1
          ? l10n.sftpMovedOne(undo.first.name, targetName)
          : l10n.sftpMovedMany(moved, targetName);
      showTopSnackBar(
        context,
        failures.isEmpty
            ? base
            : l10n.sftpMovedPartial(base, failures.length),
        isSuccess: failures.isEmpty,
        isWarning: failures.isNotEmpty,
        duration: const Duration(seconds: 10),
        actionLabel: l10n.sftpDeleteUndo,
        onAction: () => unawaited(_undoMoves(undo)),
        details: failures.isEmpty ? null : _thrown(failures),
      );
    } else if (failures.isNotEmpty) {
      showTopSnackBar(
        context,
        failures.length == 1
            ? sftpErrorMessage(failures.single.error, name: failures.single.name, op: SftpOp.rename)
            : l10n.sftpMoveFailedMany(failures.length),
        isError: true,
        details: _thrown(failures),
      );
    }
  }

  /// Reverse a same-host move: rename each item back to where it came from.
  /// Best effort - anything that can't be put back is surfaced, the rest still
  /// return home.
  Future<void> _undoMoves(
    List<({String from, String to, String name})> moves,
  ) async {
    final failures = <({String name, Object error})>[];
    for (final m in moves) {
      try {
        await widget.source.rename(m.from, m.to);
      } catch (err) {
        failures.add((name: m.name, error: err));
      }
    }
    if (!mounted) return;
    await refresh();
    if (mounted && failures.isNotEmpty) {
      final l10n = AppLocalizations.of(context)!;
      showTopSnackBar(
        context,
        failures.length == 1
            ? l10n.sftpUndoMoveFailedOne
            : l10n.sftpUndoMoveFailedMany(failures.length),
        isError: true,
        details: _thrown(failures),
      );
    }
  }

  /// What was thrown for each of [failures], a line each, for the details of
  /// a notice (no name: a report names no file).
  static String _thrown(List<({String name, Object error})> failures) =>
      [for (final f in failures) '${f.error}'].join('\n');

  Future<void> _runMkdir() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showZestInputDialog(
      context: context,
      title: l10n.sftpNewFolderAction,
      icon: LucideIcons.folderPlus,
      fieldLabel: l10n.sftpFolderNameLabel,
      hintText: l10n.sftpFolderName,
      confirmLabel: l10n.create,
      busyLabel: l10n.sftpCreating,
      validator: (v) => _validateFileName(v, l10n),
      // The dialog only collects (and validates) the name; the create itself
      // runs through the unified Activity queue below so mkdir shares the one
      // operations model with delete/chmod/upload, and on a
      // high-latency link it gets a home for its outcome instead of a bare
      // toast. The predictable "already exists" collision is still caught
      // inline here so the user can fix the name without a failed op row.
      onConfirm: (v) async {
        final newPath = widget.source.join(_path, v.trim());
        if (await widget.source.exists(newPath)) {
          return l10n.sftpNameExists(v.trim());
        }
        return null;
      },
    );
    if (result == null) return;
    final name = result.trim();
    final newPath = widget.source.join(_path, name);

    final notifier = ref.read(sftpTransfersProvider.notifier);
    final opId = 'mkdir_${DateTime.now().microsecondsSinceEpoch}';
    final op = TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.mkdir,
      title: l10n.sftpCreatingName(name),
      subtitle: newPath,
      totalItems: 1,
      status: TransferStatus.active,
    );
    notifier.add(op);
    try {
      await widget.source.mkdir(newPath);
      op.processedItems = 1;
      op.status = TransferStatus.completed;
    } catch (e, stack) {
      // Why, in the app's language, with its report (it was the raw error).
      op.failWith(e, stack: stack, op: SftpOp.mkdir, name: name);
      if (isPermissionDenied(e)) _offerSudo([SudoMkdir(newPath)], shownPath: newPath, details: '$e');
    }
    op.completedAt = DateTime.now();
    notifier.touch();
    if (mounted) await refresh();
  }

  /// Create an empty file at the current path. Same modal shape as
  /// [_runMkdir]; uses [PaneFileSource.writeBytes] with a zero-byte
  /// payload. An existing file at the same name is refused inline
  /// (UX choice - we don't silently overwrite).
  Future<void> _runNewFile() async {
    final l10n = AppLocalizations.of(context)!;
    final result = await showZestInputDialog(
      context: context,
      title: l10n.sftpNewFile,
      icon: LucideIcons.filePlus,
      fieldLabel: l10n.sftpFileNameLabel,
      hintText: l10n.sftpFileNameLabel,
      confirmLabel: l10n.create,
      busyLabel: l10n.sftpCreating,
      validator: (v) => _validateFileName(v, l10n),
      onConfirm: (v) async {
        final name = v.trim();
        final newPath = widget.source.join(_path, name);
        try {
          // Refuse silent overwrite - match Explorer behavior.
          if (await widget.source.exists(newPath)) {
            return l10n.sftpNameExists(name);
          }
          await widget.source.writeBytes(newPath, Uint8List(0));
          return null;
        } catch (e) {
          return sftpErrorMessage(e, name: name, op: SftpOp.upload);
        }
      },
    );
    if (result == null) return;
    if (mounted) await refresh();
  }

  /// Shared inline validator for rename / new-file / new-folder names.
  /// Returns an error string (shown under the field) or null when valid.
  String? _validateFileName(String value, AppLocalizations l10n) {
    final name = value.trim();
    if (name.isEmpty) return l10n.sftpNameRequired;
    // A backslash is a path separator on a local Windows pane, so "a\b"
    // escapes the current directory exactly like "/" does elsewhere; reject
    // both regardless of pane type so the rule is uniform.
    if (name.contains('/') || name.contains('\\')) {
      return l10n.sftpNameNoSeparator;
    }
    // NUL truncates the path at the syscall boundary and other control chars
    // are invalid/unrenderable - a name containing them is never legitimate.
    if (name.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return l10n.sftpNameNoControlChars;
    }
    // Windows silently strips trailing dots/spaces, so "..  " collapses to
    // ".." - a directory reference. Compare after that same stripping.
    final stripped = name.replaceAll(RegExp(r'[. ]+$'), '');
    if (stripped == '.' || stripped == '..' || stripped.isEmpty) {
      return l10n.sftpNameChooseDifferent;
    }
    return null;
  }

  /// Right-click in empty space menu - modeled after Explorer / Finder.
  /// Options apply to the CURRENT DIRECTORY (no row context required):
  /// create a new folder / file, toggle hidden files, refresh, paste
  /// the path of the current directory to the clipboard.
  Future<void> _showEmptyAreaContextMenu(Offset globalPosition) async {
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final l10n = AppLocalizations.of(context)!;

    final selected = await showMenu<_PaneMenuAction>(
      context: context,
      color: AppColors.v3Elevated,
      position: RelativeRect.fromRect(
        globalPosition & const Size(40, 40),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem(
          value: _PaneMenuAction.mkdir,
          child: _MenuRow(
              icon: LucideIcons.folderPlus, label: l10n.sftpNewFolderEllipsis),
        ),
        PopupMenuItem(
          value: _PaneMenuAction.newFile,
          child: _MenuRow(
              icon: LucideIcons.filePlus, label: l10n.sftpNewFileEllipsis),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PaneMenuAction.refresh,
          child: _MenuRow(icon: LucideIcons.refreshCw, label: l10n.refresh),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _PaneMenuAction.pastePath,
          child: _MenuRow(
            icon: LucideIcons.clipboardCopy,
            label: l10n.sftpCopyCurrentPath,
          ),
        ),
        // The one thing no standalone SFTP client can do: a shell in this
        // directory, one click away. Remote panes only.
        if (widget.onOpenTerminalHere != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _PaneMenuAction.openTerminalHere,
            child: _MenuRow(
              icon: LucideIcons.terminal,
              label: l10n.sftpOpenTerminalHere,
            ),
          ),
        ],
        // One-way mirror of this local folder up to the remote pane, with a
        // preview of exactly what will be created/replaced before it runs.
        if (widget.onMirrorFolder != null) ...[
          const PopupMenuDivider(),
          PopupMenuItem(
            value: _PaneMenuAction.mirrorFolder,
            child: _MenuRow(
              icon: LucideIcons.folderSync,
              label: l10n.sftpSyncAction,
            ),
          ),
        ],
      ],
    );

    if (!mounted || selected == null) return;
    switch (selected) {
      case _PaneMenuAction.mkdir:
        await _runMkdir();
      case _PaneMenuAction.newFile:
        await _runNewFile();
      case _PaneMenuAction.refresh:
        await _loadDirectory(record: false);
      case _PaneMenuAction.pastePath:
        // A real path goes to the clipboard: reveal gate (spec 5), the same
        // as the per-entry "Copy path" in the row menu.
        if (!await confirmRevealWhileRecording(context, ref)) break;
        if (!mounted) break;
        await Clipboard.setData(ClipboardData(text: _path));
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.sftpPathCopied,
            duration: const Duration(seconds: 1),
          );
        }
      case _PaneMenuAction.openTerminalHere:
        widget.onOpenTerminalHere?.call(_path);
      case _PaneMenuAction.mirrorFolder:
        widget.onMirrorFolder?.call(_path);
      // Row-only actions - not reachable from this menu.
      case _PaneMenuAction.openInEditor:
      case _PaneMenuAction.rename:
      case _PaneMenuAction.chmod:
      case _PaneMenuAction.copyPath:
      case _PaneMenuAction.delete:
      case _PaneMenuAction.tailFile:
        break;
    }
  }

  /// Open the live `tail -f` viewer for a remote log file.
  Future<void> _runLiveTail(PaneFileEntry entry) async {
    final source = widget.source;
    if (source is! RemotePaneFileSource) return;
    await SftpTailViewer.show(
      context,
      service: source.service,
      path: entry.path,
      fileName: entry.name,
      hostLabel: widget.headerLabel ?? widget.sourceDescriptor.label,
    );
  }

  Future<void> _runChmod(List<PaneFileEntry> targets) async {
    if (targets.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    // rwx grid + octal field, two representations of one value,
    // instead of a bare octal text box.
    final initialMode =
        (targets.first.modeBits ?? int.parse('644', radix: 8)) & 0x1FF;
    // Offer "Apply to enclosed items" when any target is a directory.
    final isDirectory = targets.any((t) => t.isDirectory);
    final result = await showSftpPermissionsDialog(
      context: context,
      pathLabel: targets.first.path,
      initialMode: initialMode,
      itemCount: targets.length,
      isDirectory: isDirectory,
    );
    if (result == null) return;
    final mode = result.mode;
    final recursive = result.recursive;

    // Route through the Activity queue like delete: one op row, per-item
    // progress, a cancel, and failures collected into ONE row instead of the
    // dialog swallowing an all-or-nothing loop. A recursive apply walks every
    // enclosed entry, so it earns the queue exactly as a recursive delete does.
    final notifier = ref.read(sftpTransfersProvider.notifier);
    final opId = 'chmod_${DateTime.now().microsecondsSinceEpoch}';
    final op = TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.chmod,
      title: targets.length == 1
          ? l10n.sftpChmodOne(targets.first.name)
          : l10n.sftpChmodMany(targets.length),
      subtitle: targets.length == 1
          ? targets.first.path
          : widget.source.parentOf(targets.first.path),
      totalItems: targets.length,
      status: TransferStatus.active,
    );
    notifier.add(op);
    var cancelled = false;
    notifier.registerCanceller(opId, () => cancelled = true);

    // Recursive apply visits every enclosed entry, so the determinate total is
    // a read-only recursive count up front (best-effort - an unreadable subtree
    // just contributes fewer). Non-recursive stays one chmod per target.
    if (recursive) {
      var total = 0;
      for (final t in targets) {
        if (cancelled) break;
        if (t.isDirectory) {
          try {
            total += await widget.source.countEntriesRecursive(t.path);
          } catch (_) {
            total += 1;
          }
        } else {
          total += 1;
        }
      }
      op.totalItems = total;
      notifier.touch();
    }

    var done = 0;
    final failures = <({String name, Object error})>[];
    for (final t in targets) {
      if (cancelled) break;
      if (recursive && t.isDirectory) {
        // Same op, per-entry progress via onDone, cancellable mid-walk -
        // exactly how _runDelete drives deleteDirectoryRecursive.
        try {
          await widget.source.chmodRecursive(
            t.path,
            mode,
            isCancelled: () => cancelled,
            onDone: (_) {
              done++;
              op.processedItems = done;
              notifier.touch();
            },
          );
        } catch (e) {
          failures.add((name: t.name, error: e));
        }
      } else {
        try {
          await widget.source.chmod(t.path, mode);
        } catch (e) {
          failures.add((name: t.name, error: e));
        }
        // Advance whether the item succeeded or failed, so the bar reaches the
        // end and the op resolves rather than hanging at a partial count.
        done++;
        op.processedItems = done;
        notifier.touch();
      }
    }

    notifier.unregisterCanceller(opId);
    op.completedAt = DateTime.now();
    if (cancelled) {
      op.status = TransferStatus.cancelled;
    } else if (failures.isNotEmpty) {
      // Each failure said for itself when it is one, every one in the report
      // (it was the raw '<name>: <error>').
      op.failWithAll(failures, several: l10n.sftpItemsFailed(failures.length, targets.length), op: SftpOp.chmod);
    } else {
      op.status = TransferStatus.completed;
    }
    notifier.touch();
    if (mounted) await refresh();
  }

  /// Delete safety (spec): a LOCAL delete goes to the OS trash / Recycle Bin;
  /// a REMOTE delete gets a hold window (the unlink is deferred, with Undo /
  /// Delete now in Activity) so an accidental big-folder delete can be undone
  /// with zero risk - nothing was sent. The confirm dialog NAMES the source so
  /// you can tell which side of the two-pane window you are about to delete on.
  Future<void> _runDelete(List<PaneFileEntry> targets) async {
    if (targets.isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    final label = targets.length == 1
        ? '"${targets.first.name}"'
        : l10n.sftpItemCount(targets.length);
    final desc = widget.sourceDescriptor;
    final isLocal =
        desc is LocalPaneSource || widget.source is LocalPaneFileSource;
    final holdSeconds = ref.read(sftpDeleteHoldSecondsProvider);
    final binName = thisComputerBinName(l10n);

    // Name the source + path: "web-01 /home/deploy/dist", not just the file.
    // (An FTPS host's by its own name too, never this computer's.)
    final hostName = desc.hostName;
    final srcName = hostName ?? thisComputerName(l10n);
    // The painted form: a host name is masked in recording mode. The hold
    // below keeps the real [srcName] for its own bookkeeping.
    final srcShown = hostName != null ? Redactable.host(srcName).display : srcName;
    final firstPath = targets.length == 1
        ? targets.first.path
        : widget.source.parentOf(targets.first.path);
    final hasDirectory = targets.any((t) => t.isDirectory);
    final target = hasDirectory
        ? l10n.sftpTargetAndContents('$srcShown $firstPath')
        : '$srcShown $firstPath';

    final String body;
    if (isLocal) {
      body = l10n.sftpDeleteConfirmLocalTrash(target, binName);
    } else if (holdSeconds > 0) {
      body = l10n.sftpDeleteConfirmRemote(target, holdSeconds);
    } else {
      body = l10n.sftpDeleteConfirmRemoteNoHold(target);
    }

    final confirm = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.sftpDeleteConfirmTitle(label),
      body: body,
      confirmLabel: l10n.delete,
    );
    if (confirm != true || !mounted) return;

    // LOCAL: try the OS trash first (recoverable from Explorer/Finder). Success
    // = an instant, one-shot "Deleted" row, no hold. Failure falls through to
    // the hold window (spec-allowed "trash unavailable").
    if (isLocal) {
      // A large Recycle Bin / Trash move blocks for seconds with no OS-level
      // progress, which reads as a frozen dialog. Show our own progress while it
      // runs so a big-folder delete is never a silent hang.
      // (The app's work-under-way dialog, 3.4: it closes exactly itself.)
      final closeMoving = showZestBusy(context, label: l10n.sftpMovingToBin(label, binName));
      TrashResult trash;
      try {
        trash = await widget.source.trashPathsDetailed(
          targets.map((t) => t.path).toList(),
        );
      } finally {
        closeMoving();
      }
      if (!mounted) return;
      final trashed = trash.ok;
      if (!trashed) {
        // The bin refused (a network drive, a volume with the bin disabled,
        // an item over its size limit, the shell's own warning declined). A
        // permanent delete is never the silent next step: ask, in so many
        // words, and only then run the hold path below.
        if (trash.cancelled) return;
        final really = await ZestConfirmDialog.show(
          context,
          tone: ZestDialogTone.destructive,
          title: l10n.sftpTrashUnavailableTitle(binName),
          body: l10n.sftpTrashUnavailableBody(target,
              trash.reason.isEmpty ? l10n.sftpTrashReasonUnknown : trash.reason),
          confirmLabel: l10n.sftpDeletePermanently,
        );
        if (really != true || !mounted) return;
      }
      if (trashed) {
        final op =
            TransferItem.operation(
                id: 'del_${DateTime.now().microsecondsSinceEpoch}',
                kind: SftpOperationKind.delete,
                title: targets.length == 1
                    ? l10n.sftpDeletedOne(targets.first.name)
                    : l10n.sftpDeletedMany(targets.length),
                subtitle: l10n.sftpMovedToBin(binName),
                status: TransferStatus.completed,
                totalItems: targets.length,
              )
              ..processedItems = targets.length
              ..completedAt = DateTime.now();
        ref.read(sftpTransfersProvider.notifier).add(op);
        setState(() {
          for (final t in targets) {
            _entries.removeWhere((e) => e.path == t.path);
            _selected.remove(t.path);
          }
        });
        return;
      }
    }

    final sessionId = desc is RemotePaneSource ? desc.sessionId : null;
    final manager = ref.read(sftpDeleteHoldProvider);

    // REMOTE (or local-without-trash): hold window. Hide the rows now so it
    // feels done; the unlink is issued when the countdown expires, on Delete
    // now, or on a lifecycle commit. Undo just re-lists (nothing was sent). All
    // commit logic - re-stat-skip, progress, connection-loss - lives in the
    // app-scoped hold manager so it survives this pane being torn down.
    final opId = 'del_${DateTime.now().microsecondsSinceEpoch}';
    final deadline = DateTime.now().add(Duration(seconds: holdSeconds));
    final op = TransferItem.operation(
      id: opId,
      kind: SftpOperationKind.delete,
      title: targets.length == 1
          ? l10n.sftpDeletingOne(targets.first.name)
          : l10n.sftpDeletingMany(targets.length),
      subtitle: firstPath,
      status: TransferStatus.holding,
    )..holdUntil = deadline;
    ref.read(sftpTransfersProvider.notifier).add(op);
    setState(() {
      for (final t in targets) {
        _entries.removeWhere((e) => e.path == t.path);
        _selected.remove(t.path);
      }
    });

    manager.hold(
      DeleteHold(
        opId: opId,
        sessionId: sessionId,
        hostLabel: srcName,
        source: widget.source,
        targets: targets,
        deadline: deadline,
        connectionLostText: l10n.sftpDeleteConnectionLost,
        skippedText: l10n.sftpDeleteSkippedChanged,
        failedText: l10n.sftpDeleteItemsFailed,
        onRefresh: () {
          if (mounted) unawaited(refresh());
        },
        // What the host refused for want of permission: Retry with sudo
        // (3.4), the delete having been asked about already.
        onDone: (outcome) {
          if (outcome.cancelled || outcome.connectionLost) return;
          final byName = {for (final t in targets) t.name: t};
          final refused = [
            for (final f in outcome.failures)
              if (isPermissionDenied(f.error) && byName[f.name] != null) (entry: byName[f.name]!, error: f.error),
          ];
          if (refused.isEmpty) return;
          _offerSudo(
            [for (final r in refused) SudoDelete(r.entry.path, folder: r.entry.isDirectory)],
            shownPath: refused.first.entry.path,
            details: [for (final r in refused) '${r.error}'].join('\n'),
          );
        },
      ),
    );
    // Hold off = commit immediately (the manager still owns the delete loop, so
    // there is one code path for issuing unlinks).
    if (holdSeconds <= 0) {
      unawaited(manager.commitNow(opId));
    }
  }
}

// ── Keyboard intents ─────────────────────────────────────────────
// Tiny private Intent classes so the pane's Shortcuts/Actions block
// stays type-safe and self-contained.

class _DeleteIntent extends Intent {
  const _DeleteIntent();
}

/// Navigate to the parent directory (Backspace / Alt+Left).
class _ParentDirIntent extends Intent {
  const _ParentDirIntent();
}

class _RenameIntent extends Intent {
  const _RenameIntent();
}

class _OpenIntent extends Intent {
  const _OpenIntent();
}

class _SelectAllIntent extends Intent {
  const _SelectAllIntent();
}

class _FocusSearchIntent extends Intent {
  const _FocusSearchIntent();
}

enum _PaneMenuAction {
  openInEditor,
  rename,
  mkdir,
  chmod,
  copyPath,
  delete,
  newFile,
  refresh,
  pastePath,
  openTerminalHere,
  mirrorFolder,
  tailFile,
}

class _MenuRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;

  const _MenuRow({
    required this.icon,
    required this.label,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : null;
    return Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 8),
        Text(label, style: TextStyle(fontSize: 13, color: color)),
      ],
    );
  }
}

/// Per-row hover wrapper for SFTP file lists.
///
/// Each row owns its own `_hovering` state and re-renders the row
/// content via [builder] with the current hover value.  Used over a
/// global state map because each [MouseRegion]'s onEnter/onExit
/// already gives us the right granularity - no need to track a Set
/// of hovered paths in the parent.
///
/// Wraps the inner [InkWell] so taps + double-taps + secondary-tap
/// (context-menu) all still fire.  The row's selection state and
/// styling are owned by [builder].
class _HoverableSftpRow extends StatefulWidget {
  const _HoverableSftpRow({
    required this.builder,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSecondaryTapDown,
    required this.semanticLabel,
    required this.selected,
  });

  /// The row as one sentence to a screen reader (its name, kind, size and
  /// when it changed), [selected] as its state; its tap selects it, Open
  /// opens it and More actions opens its menu (4.0 accessibility pass: the
  /// row was a tap with no name, its cells read apart).
  final String semanticLabel;
  final bool selected;

  /// Rebuild the row content with the current hover state.
  final Widget Function(bool hovering) builder;

  /// Tap handler. Receives the Ctrl / Shift state captured at PRESS time
  /// (onTapDown), not at fire time - InkWell delays onTap ~300ms to rule out a
  /// double-tap, and by then a quickly-released modifier reads as up, which used
  /// to collapse a Ctrl/Shift-click down to a plain click.
  final void Function(bool ctrl, bool shift) onTap;
  final VoidCallback onDoubleTap;

  /// Right-click handler - receives the global cursor position
  /// suitable for [showMenu]'s `position` argument.
  final void Function(Offset globalPosition) onSecondaryTapDown;

  @override
  State<_HoverableSftpRow> createState() => _HoverableSftpRowState();
}

class _HoverableSftpRowState extends State<_HoverableSftpRow> {
  bool _hovering = false;
  // Modifier state captured at press, used when onTap fires later (see onTap
  // doc on the widget).
  bool _downCtrl = false;
  bool _downShift = false;

  /// The row's menu, from a screen reader: at the row's middle.
  void _menuHere() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    widget.onSecondaryTapDown(box.localToGlobal(box.size.center(Offset.zero)));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      container: true,
      button: true,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: () => widget.onTap(false, false),
      onLongPress: _menuHere,
      customSemanticsActions: {
        CustomSemanticsAction(label: l10n.a11yRowOpen): widget.onDoubleTap,
        CustomSemanticsAction(label: l10n.a11yRowMenu): _menuHere,
      },
      child: MouseRegion(
      onEnter: (_) {
        if (!_hovering) setState(() => _hovering = true);
      },
      onExit: (_) {
        if (_hovering) setState(() => _hovering = false);
      },
      child: GestureDetector(
        onSecondaryTapDown: (d) => widget.onSecondaryTapDown(d.globalPosition),
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (d) => widget.onSecondaryTapDown(d.globalPosition) : null,
        child: InkWell(
          onTapDown: (_) {
            _downCtrl =
                HardwareKeyboard.instance.isControlPressed ||
                HardwareKeyboard.instance.isMetaPressed;
            _downShift = HardwareKeyboard.instance.isShiftPressed;
          },
          onTap: () => widget.onTap(_downCtrl, _downShift),
          onDoubleTap: widget.onDoubleTap,
          // Suppress InkWell hover overlay - our [Container]'s
          // explicit background colour does the highlight more
          // visibly than the default tint, and lets selection
          // contrast properly against hover.
          hoverColor: Colors.transparent,
          child: widget.builder(_hovering),
        ),
      ),
      ),
    );
  }
}

/// Paints the rubber-band selection rectangle over the file list.
///
/// Inputs are in *content space* (with scroll offset added in). The
/// painter subtracts the scroll offset on the fly so the rectangle
/// renders in viewport coordinates - that way the band stays anchored
/// to the file rows as the user (eventually, when we wire it) auto-
/// scrolls during a drag.
class _RubberBandPainter extends CustomPainter {
  _RubberBandPainter({
    required this.start,
    required this.current,
    required this.scrollOffset,
  });

  final Offset start;
  final Offset current;
  final double scrollOffset;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromPoints(
      Offset(start.dx, start.dy - scrollOffset),
      Offset(current.dx, current.dy - scrollOffset),
    );

    final fill = Paint()
      ..color = AppColors.brandOrange.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = AppColors.brandOrange.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawRect(rect, fill);
    canvas.drawRect(rect, stroke);
  }

  @override
  bool shouldRepaint(_RubberBandPainter old) =>
      old.start != start ||
      old.current != current ||
      old.scrollOffset != scrollOffset;
}

/// Renders a filename with MIDDLE truncation so the extension survives on a
/// long name: the head ellipsizes at its end while the short final
/// extension is always shown (`verylongname….gz`, never `verylongarchivenam…`).
/// Only the LAST extension is protected - for `a.tar.gz` that's `.gz`, with
/// `.tar` in the ellipsizable head. Falls back to plain end-ellipsis when there
/// is no short trailing extension worth protecting.
/// A thin, subtle column-resize divider for the SFTP header. At rest it is a
/// faint 1px hairline centered in the inter-column gutter; on hover or while
/// dragging it brightens, thickens slightly, and shows the resize cursor.
/// Horizontal drags are reported as raw deltas to the parent, which applies
/// them to the adjacent column width.
class _ColumnResizeHandle extends StatefulWidget {
  const _ColumnResizeHandle({
    required this.width,
    required this.onStart,
    required this.onDelta,
    required this.onEnd,
  });

  final double width;
  final VoidCallback onStart;
  final void Function(double dx) onDelta;
  final VoidCallback onEnd;

  @override
  State<_ColumnResizeHandle> createState() => _ColumnResizeHandleState();
}

class _ColumnResizeHandleState extends State<_ColumnResizeHandle> {
  bool _hover = false;
  bool _dragging = false;

  void _endDrag() {
    if (_dragging) {
      setState(() => _dragging = false);
      widget.onEnd();
    }
  }

  @override
  Widget build(BuildContext context) {
    final active = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      // Raw Listener, NOT a GestureDetector: the header and rows live inside a
      // horizontal scroll view, and that scroll's drag recognizer wins the
      // gesture arena, so a GestureDetector drag here never fired, the pane
      // just scrolled the wrong way instead of resizing. A Listener sees the
      // pointer events directly and keeps receiving them across the whole drag
      // once the pointer goes down on the handle; onStart flips _resizingColumn,
      // which switches the shared scroll to NeverScrollableScrollPhysics so it
      // cannot slide while a column is being dragged.
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) {
          setState(() => _dragging = true);
          widget.onStart();
        },
        onPointerMove: (e) {
          if (_dragging) widget.onDelta(e.delta.dx);
        },
        onPointerUp: (_) => _endDrag(),
        onPointerCancel: (_) => _endDrag(),
        child: SizedBox(
          width: widget.width,
          child: Center(
            child: Container(
              width: active ? 2 : 1,
              height: 16,
              color: active ? AppColors.onSurfaceDim : AppColors.divider,
            ),
          ),
        ),
      ),
    );
  }
}

/// The collapsed search icon; carries a small brand dot when a filter is still
/// active, so the user knows the list is filtered.
class _DottedSearchIcon extends StatelessWidget {
  const _DottedSearchIcon({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(LucideIcons.search, size: 13, color: AppColors.onSurfaceDim),
        if (active)
          Positioned(
            right: -2,
            top: -2,
            child: Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(
                color: AppColors.brandHi,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );
  }
}

/// A 24px-square path-bar button: radius 5, a hovered
/// --raised-2 fill, holding a 13px glyph. Used for the search and bookmark
/// controls at the right of the path bar.
class _PathBarButton extends StatelessWidget {
  const _PathBarButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
    this.onSecondaryTapDown,
  });

  final String tooltip;
  final VoidCallback onTap;
  final Widget child;

  /// Right-click on the button, carrying the pointer position so a menu can
  /// anchor at the cursor (used by the bookmark button).
  final void Function(TapDownDetails details)? onSecondaryTapDown;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        onSecondaryTapDown: onSecondaryTapDown,
        // The right click's menu under a long press too where the controls are
        // touch sized (a tablet, 4.0): a finger has no right button.
        onLongPress: onSecondaryTapDown == null || !touchSizedAt(context)
            ? null
            : () {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                final at = box.localToGlobal(box.size.center(Offset.zero));
                onSecondaryTapDown!(TapDownDetails(globalPosition: at, kind: PointerDeviceKind.touch));
              },
        borderRadius: BorderRadius.circular(5),
        hoverColor: AppColors.sftpRaised2,
        // 48 square to a finger (4.0 accessibility pass; it was 24 there too).
        child: SizedBox.square(dimension: touchSizedAt(context) ? 48 : 24, child: Center(child: child)),
      ),
    );
  }
}

/// The bookmark ribbon glyph: the SVG path
/// `M7 4h10v16l-5-4-5 4z` in a 24-unit box, painted at 13px. Filled at --text-2
/// when the current folder is bookmarked, a muted outline otherwise - the shape
/// is the state channel so orange never carries state. Not a pushpin.
class _BookmarkRibbonIcon extends StatelessWidget {
  const _BookmarkRibbonIcon({required this.active});
  final bool active;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(13, 13),
      painter: _BookmarkRibbonPainter(
        color: active ? AppColors.sftpMenuText : AppColors.onSurfaceDim,
        filled: active,
      ),
    );
  }
}

class _BookmarkRibbonPainter extends CustomPainter {
  _BookmarkRibbonPainter({required this.color, required this.filled});
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    // Path authored in a 24x24 viewBox; scale it down to the icon size.
    final s = size.width / 24.0;
    final path = Path()
      ..moveTo(7 * s, 4 * s)
      ..relativeLineTo(10 * s, 0)
      ..relativeLineTo(0, 16 * s)
      ..relativeLineTo(-5 * s, -4 * s)
      ..relativeLineTo(-5 * s, 4 * s)
      ..close();
    final paint = Paint()..color = color;
    if (filled) {
      paint.style = PaintingStyle.fill;
    } else {
      paint.style = PaintingStyle.stroke;
      paint.strokeWidth = 1.8 * s;
      paint.strokeJoin = StrokeJoin.round;
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_BookmarkRibbonPainter old) =>
      old.color != color || old.filled != filled;
}
