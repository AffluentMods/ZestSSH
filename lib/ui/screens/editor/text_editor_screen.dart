import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:re_editor/re_editor.dart';
import 'package:xterm/xterm.dart' show TerminalTheme;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/enums.dart' show TerminalFontFamily;
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/sftp_service.dart' show SudoFailedException, SudoRefusedException;
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/editor/editor_codec.dart';
import 'package:zestssh/ui/screens/editor/editor_dialogs.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_hosts.dart';
import 'package:zestssh/ui/screens/editor/editor_language.dart';
import 'package:zestssh/ui/screens/editor/editor_look.dart';
import 'package:zestssh/ui/screens/editor/editor_reply.dart';
import 'package:zestssh/ui/screens/editor/editor_source.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_chrome.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_gutter.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_line_reader.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_minimap.dart';
import 'package:zestssh/ui/screens/editor/widgets/editor_phone.dart';
import 'package:zestssh/ui/widgets/sudo_password_dialog.dart' show sudoRefusalSaid, sudoWordsShown;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart' show showZestSheet;
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/l10n/time_text.dart';

export 'package:zestssh/ui/screens/editor/editor_source.dart' show kMaxInlineEditBytes;

/// The file editor (3.4):
/// several files in tabs, from several hosts, each naming its host; a
/// code editor (re_editor) with line numbers that stay with their lines when
/// wrapped, folding and highlighting for the files people edit on servers;
/// find and replace in one row; go to line; a status bar that tells the
/// truth (encoding, line endings, indentation, line and column, language);
/// the terminal's theme and font by default; and a phone layout of its own.
///
/// [TextEditorScreen.new] edits one file whose text comes and goes through
/// callbacks (a window of its own, the router); [TextEditorScreen.tabs]
/// shows the app's tabs ([editorWorkspaceProvider], [openInEditor]).
class TextEditorScreen extends ConsumerStatefulWidget {
  /// The remote file name (used for title and syntax detection).
  final String fileName;

  /// The initial content of the file.
  final String initialContent;

  /// Callback to save content back (e.g. via SFTP upload). If null, save is
  /// disabled.
  final Future<void> Function(String content)? onSave;

  /// The host the file lives on ("web-01"), shown on its tab so a remote file
  /// never looks local. Null for a local file.
  final String? hostLabel;

  /// The file's full path.
  final String? filePath;

  /// In a window of its own, which has no settings to read: whether it was
  /// handed them ([initialNanoKeys]), and who keeps a change of them.
  final bool handedSettings;
  final bool? initialNanoKeys;
  final void Function(bool on)? onNanoKeysChanged;

  /// The same for the minimap: what it was handed, and who keeps a change.
  final bool? initialMinimap;
  final void Function(bool on)? onMinimapChanged;

  /// The file's modified time when it was opened, with [fetchRemoteModified]
  /// to tell the file changing underneath the editor.
  final DateTime? originalModified;
  final Future<DateTime?> Function()? fetchRemoteModified;

  /// Re-read the file's content, for the conflict question's Reload.
  final Future<String?> Function()? onReload;

  /// Whether to offer the "open in a separate window" control.
  final bool popOutEnabled;

  /// What the main window said the file is in, for a window of its own.
  final EditorEncoding? encoding;

  /// Whether this shows the app's tabs.
  final bool tabs;

  /// How it reaches the other editor windows: given in a window of its own;
  /// the main window's own where null (on a computer).
  final EditorWindowLink? link;

  /// Shown by the desktop shell in its workspace area, not as a page over
  /// the whole window (4.0.1, [EditorWorkspace.hostedInShell]): it goes
  /// behind and comes back with its tab in the strip, and closing it closes
  /// its files in place of leaving a page.
  final bool hosted;

  const TextEditorScreen({
    super.key,
    required this.fileName,
    required this.initialContent,
    this.onSave,
    this.hostLabel,
    this.filePath,
    this.originalModified,
    this.fetchRemoteModified,
    this.onReload,
    this.popOutEnabled = true,
    this.handedSettings = false,
    this.initialNanoKeys,
    this.onNanoKeysChanged,
    this.initialMinimap,
    this.onMinimapChanged,
    this.encoding,
    this.link,
  })  : tabs = false,
        hosted = false;

  /// The app's tabs ([editorWorkspaceProvider]): the main window's, or, with
  /// [link], a window of its own's (which is handed its settings).
  const TextEditorScreen.tabs({
    super.key,
    this.popOutEnabled = true,
    this.link,
    this.handedSettings = false,
    this.initialNanoKeys,
    this.onNanoKeysChanged,
    this.initialMinimap,
    this.onMinimapChanged,
    this.hosted = false,
  })  : tabs = true,
        fileName = '',
        initialContent = '',
        onSave = null,
        hostLabel = null,
        filePath = null,
        originalModified = null,
        fetchRemoteModified = null,
        onReload = null,
        encoding = null;

  @override
  ConsumerState<TextEditorScreen> createState() => _TextEditorScreenState();
}

/// The user's choice when a file changed on its host underneath the editor.
enum _SaveConflictChoice { cancel, reload, saveAnyway }

/// Opens the file of [source] in the editor's tabs: as a new tab where it is
/// not open (from [bytes] already read, else read now), else its tab; the
/// editor's screen is opened where it is not showing. A 13th file asks which
/// open one to close. Errors reading it are said with what was thrown.
///
/// On a computer (3.4.1) a file is open in one editor at most: one open in a
/// window of its own is brought to the front there; while the main window
/// shows no editor (none, not even minimized) and a window of its own has
/// one, the file opens there; else it joins the main window's editor, shown
/// again where it was minimized.
Future<void> openInEditor(BuildContext context, EditorSource source, {Uint8List? bytes, FileVersion? version}) async {
  final container = ProviderScope.containerOf(context);
  final ws = container.read(editorWorkspaceProvider);
  final open = ws.byIdentity(source.identity);
  if (open != null) {
    ws.activate(open);
    if (context.mounted) showEditorTabs(context);
    return;
  }
  final windows = EditorWindows.instance;
  if (isDesktopPlatform && windows.hasWindows) {
    final there = await windows.windowShowing(source.identity);
    if (there != null) {
      await windows.focusTab(there, source.identity);
      return;
    }
    if (!context.mounted) return;
  }
  var data = bytes;
  try {
    data ??= await source.read();
  } catch (e) {
    if (!context.mounted) return;
    showTopSnackBar(
      context,
      AppLocalizations.of(context)!.sftpNotOpened(sftpErrorMessage(e, name: source.fileName, op: SftpOp.download)),
      isError: true,
      details: '$e',
    );
    return;
  }
  if (!context.mounted) return;
  final doc = EditorDocument.fromBytes(source, data, version: version ?? FileVersion.of(data));
  if (isDesktopPlatform && windows.hasWindows && ws.isEmpty) {
    final target = await windows.windowForNewFile();
    if (target != null) {
      final sent = await windows.send(doc, to: target);
      if (sent != EditorMoveResult.failed) {
        // In that window now, or its question there was answered Cancel.
        doc.dispose();
        return;
      }
    }
    if (!context.mounted) {
      doc.dispose();
      return;
    }
  }
  if (!await takeIntoEditor(context, doc)) doc.dispose();
}

/// Puts [doc] in the editor's tabs of [context]'s window and shows them;
/// false where it was not taken (the file is open there already, its tab
/// now in front, or the question of which tab to close was answered Cancel).
Future<bool> takeIntoEditor(BuildContext context, EditorDocument doc) async {
  final ws = ProviderScope.containerOf(context).read(editorWorkspaceProvider);
  final open = ws.byIdentity(doc.source.identity);
  if (open != null) {
    ws.activate(open);
    showEditorTabs(context);
    return false;
  }
  if (!await makeRoomFor(context, ws, doc.source.fileName) || !context.mounted) return false;
  ws.add(doc);
  showEditorTabs(context);
  return true;
}

/// Where [ws] holds as many tabs as it may, asks which open one to close for
/// [fileName] (and, where that one holds changes, whether to save them) and
/// closes it; false where the person said Cancel.
Future<bool> makeRoomFor(BuildContext context, EditorWorkspace ws, String fileName) async {
  if (!ws.isFull) return true;
  final close = await askWhichToClose(context, ws.docs, fileName);
  if (close == null || !context.mounted) return false;
  if (close.modified) {
    final choice = await askSaveChanges(context, close);
    if (choice == EditorCloseChoice.cancel || !context.mounted) return false;
    if (choice == EditorCloseChoice.discard) close.discarded = true;
    if (choice == EditorCloseChoice.save) {
      try {
        await close.save();
      } catch (e) {
        if (context.mounted) {
          showTopSnackBar(context,
              AppLocalizations.of(context)!.editorNotSaved(editorFailureSaid(e, name: close.source.fileName, op: SftpOp.upload)),
              isError: true, details: '$e');
        }
        return false;
      }
    }
  }
  ws.remove(close);
  return true;
}

/// Shows the editor's tabs of [context]'s window: its screen is opened
/// where it is not showing (minimized, or not open yet).
void showEditorTabs(BuildContext context) {
  final ws = ProviderScope.containerOf(context).read(editorWorkspaceProvider);
  ws.minimized = false;
  // On a computer the shell shows it in its workspace area, in front.
  if (ws.hostedInShell) {
    ws.front = true;
    return;
  }
  if (ws.shown || ws.isEmpty) return;
  unawaited(Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const TextEditorScreen.tabs())));
}

class _TextEditorScreenState extends ConsumerState<TextEditorScreen> {
  late final EditorWorkspace _ws;
  final Map<EditorDocument, FocusNode> _focus = {};

  /// The tabs this screen listens to, with what it listens with.
  final Map<EditorDocument, VoidCallback> _seen = {};

  /// A phone's bar at the top (close, the file, Done while typing): the
  /// app's messages stand below it, never over its controls.
  final _phoneTopBar = GlobalKey(debugLabel: 'editor-phone-top');

  bool _wrap = true;

  /// nano-style keys (Ctrl+A/E line start and end, Ctrl+K cut a line, Ctrl+U
  /// paste it, ...). On by default; the status bar chip turns them off, and
  /// the choice is remembered on this device.
  bool _nanoKeys = true;
  static const _nanoKeysPref = 'editor_nano_keys';

  /// The terminal's theme and font for the code (3.4: an option, on by
  /// default), and the code's text size where it was set here (pinch, the
  /// More sheet), else the terminal's.
  bool _terminalLook = true;
  double? _textSize;
  static const _terminalLookPref = 'editor_terminal_look';
  static const _textSizePref = 'editor_text_size';

  /// The minimap at the right of the code (3.4): computers only, off by
  /// default, switched in the More menu and remembered on this device.
  bool _minimap = false;
  static const _minimapPref = 'editor_minimap';

  /// The code's scrolling, per tab, which the minimap follows and moves.
  final Map<EditorDocument, CodeScrollController> _scrolls = {};

  /// What Ctrl+K cut, for Ctrl+U. Cuts in a row collect lines, as in nano.
  String _cutBuffer = '';
  CodeLineEditingValue? _afterLastCut;

  Timer? _connectionTimer;

  /// Unsaved text kept on this device (3.4: encrypted, 7 days), where this
  /// profile's database is open; null in a window of its own and while the
  /// app is locked.
  EditorDraftStore? _drafts;
  final Map<EditorDocument, Timer> _draftTimers = {};

  /// The main window's link to the editor windows of their own, on a
  /// computer ([TextEditorScreen.link] in a window of its own).
  EditorWindowLink? _mainLink;
  EditorWindowLink? get _link => widget.link ?? _mainLink;

  /// Whether this is the main window's editor (not a window of its own's).
  bool get _inMainWindow => widget.link == null;

  // Pinch to change the text size (phones).
  final Map<int, Offset> _pointers = {};
  double? _pinchStartDistance;
  double? _pinchStartSize;

  @override
  void initState() {
    super.initState();
    keepTopToastsBelow(_phoneTopBar);
    if (widget.tabs) {
      _ws = ref.read(editorWorkspaceProvider);
      _ws.shownBy = this;
      if (widget.hosted) _ws.closeAsked = _closeAll;
    } else {
      _ws = EditorWorkspace();
      _ws.add(_handedDoc());
    }
    if (widget.link == null && isDesktopPlatform && widget.popOutEnabled) _mainLink = MainEditorLink();
    // The drafts: this profile's databases, or, in a window of its own, the
    // main window's (through it).
    try {
      _drafts = ref.read(editorDraftStoreProvider);
      unawaited(_drafts!.forgetOld().catchError((_) {}));
    } catch (_) {
      // No database open here: no drafts.
      _drafts = null;
    }
    _ws.addListener(_onWorkspace);
    _syncDocs();
    unawaited(_loadPrefs());
    // A host that drops greys its tabs: looked at every few seconds (the
    // file service has no word of its own for it).
    _connectionTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted && _ws.docs.any((d) => !d.source.isConnected)) setState(() {});
    });
  }

  /// The one file of [TextEditorScreen.new], whose text comes and goes
  /// through its callbacks.
  EditorDocument _handedDoc() {
    final source = TextEditorSource(
      fileName: widget.fileName,
      initialText: widget.initialContent,
      path: widget.filePath ?? '',
      hostLabel: widget.hostLabel,
      onSave: widget.onSave,
      onReload: widget.onReload,
      fetchModified: widget.fetchRemoteModified,
      originalModified: widget.originalModified,
    );
    return EditorDocument.fromText(
      source,
      widget.initialContent,
      encoding: widget.encoding,
      version: widget.fetchRemoteModified != null && widget.originalModified != null
          ? FileVersion(modified: widget.originalModified)
          : null,
    );
  }

  @override
  void didUpdateWidget(TextEditorScreen old) {
    super.didUpdateWidget(old);
    if (widget.tabs) return;
    final before = _ws.current;
    if (old.fileName != widget.fileName || old.initialContent != widget.initialContent || old.filePath != widget.filePath) {
      // Handed another file: that one.
      _ws.add(_handedDoc());
      if (before != null) _ws.remove(before);
    } else if (before?.source case final TextEditorSource source) {
      // The same file, with its ways to save and read it as handed now
      // (what is typed stays).
      source
        ..onSave = widget.onSave
        ..onReload = widget.onReload
        ..fetchModified = widget.fetchRemoteModified;
      setState(() {});
    }
  }

  /// A hosted editor put behind (a session tab or a page chosen): where each
  /// file was scrolled to is kept for when it comes back. (Here, before its
  /// code is taken down with the scrolling it reads.)
  @override
  void deactivate() {
    if (widget.hosted) {
      for (final d in _ws.docs) {
        _noteScroll(d);
      }
    }
    super.deactivate();
  }

  @override
  void dispose() {
    stopKeepingTopToastsBelow(_phoneTopBar);
    _connectionTimer?.cancel();
    for (final t in _draftTimers.values) {
      t.cancel();
    }
    // A tab left with changes nobody threw away (the editor taken away
    // without its question): its draft is kept now.
    for (final d in _ws.docs) {
      if (d.modified && !d.discarded) unawaited(_keepDraft(d));
    }
    _ws.removeListener(_onWorkspace);
    for (final e in _seen.entries) {
      e.key.removeListener(e.value);
    }
    if (widget.tabs) {
      // Leaving the editor closes its tabs (it asked first where any held
      // changes); a minimized one keeps them, as does a screen that is not
      // the one showing them any more.
      if (identical(_ws.shownBy, this)) {
        _ws.shownBy = null;
        // A hosted editor put behind keeps its tabs; one that closed has
        // cleared them already (_leave).
        if (!widget.hosted) _ws.clear(quietly: true);
      }
      if (identical(_ws.closeAsked, _closeAll)) _ws.closeAsked = null;
    } else {
      _ws.clear(quietly: true);
      _ws.dispose();
    }
    for (final f in _focus.values) {
      f.dispose();
    }
    _scrolls.values.forEach(_disposeScroll);
    super.dispose();
  }

  void _onWorkspace() {
    _syncDocs();
    if (mounted) setState(() {});
  }

  void _syncDocs() {
    for (final d in _ws.docs) {
      if (!_seen.containsKey(d)) {
        void listener() => _onDocChanged(d);
        _seen[d] = listener;
        unawaited(d.loadAccess());
        d.addListener(listener);
        unawaited(_offerDraft(d));
      }
    }
    for (final gone in _seen.keys.where((d) => !_ws.docs.contains(d)).toList()) {
      _draftTimers.remove(gone)?.cancel();
      gone.removeListener(_seen.remove(gone)!);
      // Thrown away on purpose: its draft goes. Left with changes otherwise
      // (moved to another window, made room for another): its draft is kept.
      if (gone.discarded) {
        unawaited(_forgetDraft(gone));
      } else if (gone.modified) {
        unawaited(_keepDraft(gone));
      }
    }
    _focus.removeWhere((d, f) {
      if (_ws.docs.contains(d)) return false;
      f.dispose();
      return true;
    });
    _scrolls.removeWhere((d, c) {
      if (_ws.docs.contains(d)) return false;
      // Its code editor lets go of it as this frame is built: after that.
      WidgetsBinding.instance.addPostFrameCallback((_) => _disposeScroll(c));
      return true;
    });
  }

  /// The code's scrolling of [doc], from where it was when a screen last let
  /// it go (an editor minimized and shown again, a tab moved here).
  CodeScrollController _scrollOf(EditorDocument doc) => _scrolls.putIfAbsent(
        doc,
        () => CodeScrollController(
          verticalScroller: ScrollController(initialScrollOffset: doc.scrollTop),
          horizontalScroller: ScrollController(initialScrollOffset: doc.scrollLeft),
        ),
      );

  /// Notes where [doc]'s code is scrolled to, for the screen that shows it
  /// next.
  void _noteScroll(EditorDocument doc) {
    final c = _scrolls[doc];
    if (c == null) return;
    if (c.verticalScroller.hasClients) doc.scrollTop = c.verticalScroller.offset;
    if (c.horizontalScroller.hasClients) doc.scrollLeft = c.horizontalScroller.offset;
  }

  static void _disposeScroll(CodeScrollController c) {
    c.dispose();
    c.verticalScroller.dispose();
    c.horizontalScroller.dispose();
  }

  /// The code's focus, per tab; the screen is drawn again as it comes and
  /// goes (a phone's keys row shows while the code has the keyboard).
  FocusNode _focusOf(EditorDocument doc) => _focus.putIfAbsent(doc, () {
        final node = FocusNode(debugLabel: 'editor-${doc.source.fileName}');
        node.addListener(() {
          if (mounted) setState(() {});
        });
        return node;
      });

  EditorDocument? get _doc => _ws.current;

  bool get _phone => MediaQuery.sizeOf(context).width < 600;

  // ── Drafts ────────────────────────────────────────────────────────

  /// A few seconds after each change the unsaved text is kept; once nothing
  /// is unsaved (saved, or back as it was) the draft goes.
  void _onDocChanged(EditorDocument doc) {
    if (_drafts == null || !_ws.docs.contains(doc)) return;
    _draftTimers.remove(doc)?.cancel();
    if (doc.modified) {
      _draftTimers[doc] = Timer(const Duration(seconds: 2), () => unawaited(_keepDraft(doc)));
    } else if (doc.drafted || doc.draftRestored != null) {
      unawaited(_forgetDraft(doc));
    }
  }

  Future<void> _keepDraft(EditorDocument doc) async {
    final store = _drafts;
    // A host the editor cannot name for sure keeps none: it could not be
    // found again for that host alone.
    if (store == null || !doc.source.keepsDrafts) return;
    _draftTimers.remove(doc)?.cancel();
    final EditorDraft draft;
    try {
      draft = EditorDraft(
        text: doc.controller.text,
        encoding: doc.encoding.name,
        lineBreak: doc.lineBreak.name,
        baseHash: doc.baseline?.sha256,
        keptAt: DateTime.now(),
      );
    } catch (_) {
      return; // Closed meanwhile.
    }
    try {
      await store.write(doc.source.identity, draft, team: doc.source.host.team);
      doc.drafted = true;
      if (mounted && _ws.docs.contains(doc)) setState(() {});
    } catch (_) {
      // Not kept this time (the database closed as the app locked).
    }
  }

  Future<void> _forgetDraft(EditorDocument doc) async {
    _draftTimers.remove(doc)?.cancel();
    final identity = doc.source.identity;
    final team = doc.source.host.team;
    doc
      ..drafted = false
      ..draftRestored = null;
    if (mounted) setState(() {});
    try {
      await _drafts?.remove(identity, team: team);
    } catch (_) {}
  }

  /// A file opened with a draft kept for it: the draft is put back as
  /// unsaved text, and the notice says when it was kept and whether the
  /// file on its host changed since (by the file's hash).
  Future<void> _offerDraft(EditorDocument doc) async {
    final store = _drafts;
    if (store == null || !doc.source.keepsDrafts) return;
    EditorDraft? draft;
    try {
      draft = await store.read(doc.source.identity, team: doc.source.host.team) ?? await _labelDraft(store, doc.source);
    } catch (_) {
      draft = null;
    }
    if (draft == null || !mounted || !_ws.docs.contains(doc) || doc.modified) return;
    if (draft.text == doc.controller.text) {
      unawaited(_forgetDraft(doc));
      return;
    }
    final encoding = EditorEncoding.values.asNameMap()[draft.encoding];
    final lineBreak = EditorLineBreak.values.asNameMap()[draft.lineBreak];
    if (encoding != null) doc.saveWith(encoding);
    if (lineBreak != null && lineBreak != doc.lineBreak) doc.setLineBreak(lineBreak);
    doc.restoreText(draft.text);
    final now = doc.baseline?.sha256;
    setState(() {
      doc
        ..draftRestored = (keptAt: draft!.keptAt, hostChanged: draft.baseHash == null || now == null ? null : draft.baseHash != now)
        ..drafted = true;
    });
  }

  /// A draft kept before drafts named the host by its id, under its label:
  /// taken only where that label is one saved host's alone and that host is
  /// [source]'s, and moved under the host's id then. Anywhere else (two
  /// hosts with the label, a pane named "Remote", this computer) it is left
  /// unopened, to go after its 7 days: it is never put in another host's tab.
  Future<EditorDraft?> _labelDraft(EditorDraftStore store, EditorSource source) async {
    final host = source.host;
    final label = source.hostLabel;
    if (host.connectionId == null || label == null || label.isEmpty) return null;
    final owners = await ref.read(editorLabelOwnersProvider)(label);
    if (owners.length != 1 || owners.single.connectionId != host.connectionId || owners.single.team != host.team) {
      return null;
    }
    final draft = await store.read(source.labelIdentity);
    if (draft == null) return null;
    await store.write(source.identity, draft, team: host.team);
    await store.remove(source.labelIdentity);
    return draft;
  }

  Future<void> _discardDraft(EditorDocument doc) async {
    doc.discardChanges();
    await _forgetDraft(doc);
  }

  /// The draft against the file on its host, line by line.
  Future<void> _showChanges(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    String before;
    try {
      before = doc.source.movesText
          ? await doc.source.readText()
          : EditorCodec.decode(await doc.source.read(), as: doc.encoding).text;
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.editorNotReloaded(editorFailureSaid(e, name: doc.source.fileName, op: SftpOp.download)),
            isError: true, details: '$e');
      }
      return;
    }
    if (!mounted) return;
    final diff = compareLines(before, doc.controller.text);
    final host = editorHostShown(doc.source);
    Widget line(String sign, String text, Color color) => Container(
          color: color.withValues(alpha: 0.10),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Text('$sign $text', style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: AppColors.v3TextPrimary)),
        );
    await ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.gitCompare,
      title: l10n.editorChangesTitle(doc.source.fileName),
      subtitle: l10n.editorChangesSubtitle(host),
      body: Column(
        key: const ValueKey('editor-changes'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (diff.removed.isEmpty && diff.added.isEmpty)
            Text(l10n.editorChangesNone, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary))
          else ...[
            Text(l10n.editorChangesAt(diff.at), style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
            const SizedBox(height: 6),
            for (final r in diff.removed) line('-', r, AppColors.v3Error),
            if (diff.moreRemoved > 0) Text(l10n.editorChangesMore(diff.moreRemoved)),
            for (final a in diff.added) line('+', a, AppColors.v3Success),
            if (diff.moreAdded > 0) Text(l10n.editorChangesMore(diff.moreAdded)),
          ],
        ],
      ),
      primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
    );
  }

  // ── Preferences ───────────────────────────────────────────────────

  Future<void> _loadPrefs() async {
    if (widget.handedSettings) {
      final on = widget.initialNanoKeys;
      final minimap = widget.initialMinimap;
      if (!mounted) return;
      setState(() {
        if (on != null) _nanoKeys = on;
        if (minimap != null) _minimap = minimap;
      });
      return;
    }
    try {
      final prefs = await appPreferences();
      final nano = prefs.getBool(_nanoKeysPref);
      final look = prefs.getBool(_terminalLookPref);
      final size = prefs.getDouble(_textSizePref);
      final minimap = prefs.getBool(_minimapPref);
      if (!mounted) return;
      setState(() {
        if (nano != null) _nanoKeys = nano;
        if (minimap != null) _minimap = minimap;
        if (look != null) _terminalLook = look;
        if (size != null) _textSize = size.clamp(kTerminalFontSizeMin, kTerminalFontSizeMax).toDouble();
      });
    } catch (_) {
      // Preferences unavailable: keep the defaults.
    }
  }

  Future<void> _setNanoKeys(bool on) async {
    setState(() => _nanoKeys = on);
    if (widget.handedSettings) {
      widget.onNanoKeysChanged?.call(on);
      return;
    }
    try {
      await (await appPreferences()).setBool(_nanoKeysPref, on);
    } catch (_) {
      // Not remembered this time; the editor still switches.
    }
  }

  Future<void> _setMinimap(bool on) async {
    setState(() => _minimap = on);
    if (widget.handedSettings) {
      widget.onMinimapChanged?.call(on);
      return;
    }
    try {
      await (await appPreferences()).setBool(_minimapPref, on);
    } catch (_) {
      // Not remembered this time; the editor still switches.
    }
  }

  /// Whether the minimap shows: switched on, on a computer's layout (never
  /// a phone's, never a tablet's).
  bool get _showMinimap => _minimap && !isTouchLayout && !_phone;

  Future<void> _setTerminalLook(bool on) async {
    setState(() => _terminalLook = on);
    if (widget.handedSettings) return;
    try {
      await (await appPreferences()).setBool(_terminalLookPref, on);
    } catch (_) {}
  }

  Future<void> _setTextSize(double size) async {
    final clamped = size.clamp(kTerminalFontSizeMin, kTerminalFontSizeMax).roundToDouble();
    if (clamped == _textSize) return;
    setState(() => _textSize = clamped);
    if (widget.handedSettings) return;
    try {
      await (await appPreferences()).setDouble(_textSizePref, clamped);
    } catch (_) {}
  }

  // ── Look ──────────────────────────────────────────────────────────

  /// The look of the last build, for what acts outside one.
  EditorLook? _lastLook;

  EditorLook _look() {
    if (_terminalLook && !widget.handedSettings) {
      try {
        final TerminalTheme theme = ref.watch(terminalThemeProvider);
        final TerminalFontFamily family = ref.watch(terminalFontFamilyProvider);
        final double size = ref.watch(terminalFontSizeProvider);
        return EditorLook.terminal(theme, fontFamily: family.fontFamily, fontSize: _textSize ?? size);
      } catch (_) {
        // No terminal settings here: the app's look.
      }
    }
    return EditorLook.app(fontSize: _textSize ?? (_phone ? 12 : 13));
  }

  String _fontName(EditorLook look) {
    for (final f in TerminalFontFamily.values) {
      if (f.fontFamily == look.fontFamily) return f.nameIn(AppLocalizations.of(context)!);
    }
    return look.fontFamily == 'JetBrainsMono' ? 'JetBrains Mono' : look.fontFamily;
  }

  String _languageLabel(EditorLanguage language) =>
      language == EditorLanguage.plainText ? AppLocalizations.of(context)!.editorLangPlainText : language.label;

  // ── Saving ────────────────────────────────────────────────────────

  Future<bool> _save(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    if (doc.saving) return false;
    if (!doc.source.canSave) {
      showTopSnackBar(context, l10n.editorReadOnly, isError: true);
      return false;
    }
    // A file the login account may not write, on a host with sudo: Save
    // (and Ctrl+S) asks what Save as root asks (3.4).
    if (doc.access?.needsRoot ?? false) return _saveAsRoot(doc);
    // Whether the file changed on its host since it was read: by its hash
    // where the host can say it, so a file put back from an older copy is
    // caught too.
    if (!await _checkedOnHost(doc)) return false;
    try {
      await doc.save();
      if (!mounted) return true;
      showTopSnackBar(context, l10n.editorSaved(doc.source.fileName), isSuccess: true, duration: const Duration(seconds: 2));
      return true;
    } on EditorEncodeException catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.editorCannotEncode(e.char, e.line, e.encoding.label), isError: true, details: '$e');
      }
      return false;
    } catch (e) {
      // Refused for want of the right to write it: where the host has sudo,
      // Save as root is asked (the text is still here).
      if (EditorSource.isPermissionDenied(e) && mounted) {
        if (doc.access == null) await doc.loadAccess();
        if (mounted && (doc.access?.canSudo ?? false)) return _saveAsRoot(doc, checked: true);
      }
      if (mounted) {
        // Why, in the app's language, with what was thrown to copy.
        showTopSnackBar(
          context,
          l10n.editorNotSaved(editorFailureSaid(e, name: doc.source.fileName, op: SftpOp.upload)),
          isError: true,
          details: '$e',
        );
      }
      return false;
    }
  }

  /// Whether to go on with a save after a look at the file on its host: yes
  /// where it did not change, or the person said to save anyway; a Reload
  /// reads it again (and no save follows).
  Future<bool> _checkedOnHost(EditorDocument doc) async {
    if (await doc.changedOnHost()) {
      if (!mounted) return false;
      final choice = await _promptSaveConflict(doc);
      if (!mounted || choice == _SaveConflictChoice.cancel) return false;
      if (choice == _SaveConflictChoice.reload) {
        await _reload(doc);
        return false;
      }
    }
    return mounted;
  }

  /// Save as root (3.4): asks first, the sudo password typed each time and
  /// never kept; the save goes through sudo on the host ([EditorSource.
  /// writeAsRoot]). [checked]: the look at the file on its host was made.
  Future<bool> _saveAsRoot(EditorDocument doc, {bool checked = false}) async {
    final l10n = AppLocalizations.of(context)!;
    if (!checked && !await _checkedOnHost(doc)) return false;
    if (!mounted) return false;
    final saved = await askSaveAsRoot(
      context,
      doc,
      save: (password) => doc.save(rootPassword: password),
      said: (e) => switch (e) {
        SudoRefusedException() => sudoRefusalSaid(e, l10n, host: Redactable.host(doc.source.hostLabel ?? '').display)!,
        SudoFailedException(:final said) => l10n.editorSudoFailed(sudoWordsShown(said)),
        EditorEncodeException(:final char, :final line, :final encoding) => l10n.editorCannotEncode(char, line, encoding.label),
        _ => editorFailureSaid(e, name: doc.source.fileName, op: SftpOp.upload),
      },
    );
    if (saved && mounted) {
      showTopSnackBar(context, l10n.editorSavedAsRoot(doc.source.fileName), isSuccess: true, duration: const Duration(seconds: 2));
    }
    return saved;
  }

  /// Ask what to do when the file changed on its host since it was read.
  Future<_SaveConflictChoice> _promptSaveConflict(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final res = await showZestModal<_SaveConflictChoice>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (ctx) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.warning,
          icon: LucideIcons.fileWarning,
          title: l10n.textEditorFileChangedTitle,
          body: ZestCallout(l10n.textEditorFileChangedBody),
          tertiaryKey: const ValueKey('editor-conflict-reload'),
          tertiaryAction: !doc.source.canReload
              ? null
              : (label: l10n.textEditorReload, onPressed: () => Navigator.pop(ctx, _SaveConflictChoice.reload)),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx, _SaveConflictChoice.cancel)),
          primaryKey: const ValueKey('editor-conflict-save'),
          primaryDanger: true,
          primaryAction: (
            label: l10n.textEditorSaveAnyway,
            icon: null,
            onPressed: () => Navigator.pop(ctx, _SaveConflictChoice.saveAnyway),
          ),
        ),
      ),
    );
    return res ?? _SaveConflictChoice.cancel;
  }

  Future<void> _reload(EditorDocument doc, {EditorEncoding? as}) async {
    final l10n = AppLocalizations.of(context)!;
    try {
      await doc.reload(as: as);
      if (!mounted) return;
      showTopSnackBar(context, l10n.textEditorReloadedFromServer, duration: const Duration(seconds: 2));
    } catch (e) {
      if (!mounted) return;
      showTopSnackBar(
        context,
        l10n.editorNotReloaded(editorFailureSaid(e, name: doc.source.fileName, op: SftpOp.download)),
        isError: true,
        details: '$e',
      );
    }
  }

  // ── Closing, minimizing, moving ───────────────────────────────────

  /// Closes [doc]'s tab, asking first where it holds changes; the last tab
  /// closes the editor.
  Future<void> _closeTab(EditorDocument doc) async {
    if (doc.modified) {
      final choice = await askSaveChanges(context, doc);
      if (!mounted || choice == EditorCloseChoice.cancel) return;
      if (choice == EditorCloseChoice.save && !await _save(doc)) return;
      // Don't save throws the draft away too.
      if (choice == EditorCloseChoice.discard) doc.discarded = true;
    }
    if (!mounted) return;
    final last = _ws.length == 1;
    _link?.closed(doc);
    if (last) {
      if (doc.discarded) unawaited(_forgetDraft(doc));
      _leave();
    } else {
      _ws.remove(doc);
    }
  }

  /// Closes the editor and every tab, asking once where any hold changes.
  Future<void> _closeAll() async {
    final unsaved = _ws.unsaved;
    if (unsaved.isNotEmpty) {
      final choice = await askSaveMany(context, unsaved);
      if (!mounted || choice == EditorCloseChoice.cancel) return;
      if (choice == EditorCloseChoice.save) {
        for (final d in unsaved) {
          _ws.activate(d);
          if (!await _save(d)) return;
          if (!mounted) return;
        }
      }
      if (choice == EditorCloseChoice.discard) {
        for (final d in unsaved) {
          d.discarded = true;
          unawaited(_forgetDraft(d));
        }
      }
    }
    if (!mounted) return;
    for (final d in _ws.docs) {
      _link?.closed(d);
    }
    _leave();
  }

  /// The editor goes: in a window of its own, the window closes; else its
  /// page.
  void _leave() {
    if (!_inMainWindow) {
      widget.link!.lastClosed();
      return;
    }
    if (widget.hosted) {
      // Its files close, and the workspace area shows what was in front
      // before (the shell puts it behind as it empties).
      _ws.shownBy = null;
      _ws.clear();
      return;
    }
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// Whether the editor can be minimized: the main window's, on a computer.
  bool get _canMinimize => widget.tabs && _inMainWindow && isDesktopPlatform && !_phone && !widget.hosted;

  /// Puts the editor away to the status bar (3.4.1): every tab stays, with
  /// its unsaved text, caret and scrolling; the status bar's chip, or a file
  /// opened, shows it again.
  void _minimize() {
    for (final d in _ws.docs) {
      _noteScroll(d);
    }
    // This screen goes, the tabs stay.
    _ws.shownBy = null;
    _ws.minimized = true;
    final navigator = Navigator.of(context);
    if (navigator.canPop()) navigator.pop();
  }

  /// Moves [doc] to editor window [to] (the main window's with
  /// [kMainWindowId], a new window where null), or, where [dragged], to the
  /// window it was dropped on. Its text goes with it, saved or not, and its
  /// tab here closes without asking; its saves, looks and reads are made in
  /// the main window, where the connection is.
  Future<void> _moveTo(EditorDocument doc, {int? to, bool dragged = false}) async {
    final link = _link;
    if (link == null) return;
    _noteScroll(doc);
    final result = dragged ? await link.draggedOut(doc) : await link.moveTo(doc, to: to);
    switch (result) {
      case EditorMoveResult.moved:
        // The text, saved or not, is in the other window now: the tab here
        // closes without the unsaved changes question (pop, not maybePop:
        // found in a UI review). Its draft stays the
        // file's, kept by the window that has it now.
        if (!widget.tabs) {
          // The one file of this screen: the screen goes (a navigator's only
          // page stays), and its tab with it.
          if (mounted) _leave();
          return;
        }
        if (!_ws.take(doc)) return;
        doc.dispose();
        if (_ws.isEmpty && mounted) _leave();
      case EditorMoveResult.failed:
        if (!mounted) return;
        final l10n = AppLocalizations.of(context)!;
        final error = link.lastError;
        showTopSnackBar(
          context,
          to == null && !dragged ? l10n.textEditorCouldNotOpenWindow : l10n.editorMoveFailed(doc.source.fileName),
          isError: true,
          details: error == null ? null : '$error',
        );
      case EditorMoveResult.refused:
      case EditorMoveResult.stayed:
        break;
    }
  }

  /// A tab's menu (a right click on it, on a computer): move it to another
  /// editor window, or close it.
  Future<void> _tabMenu(EditorDocument doc, Offset at) async {
    final l10n = AppLocalizations.of(context)!;
    final link = _link;
    final targets = link == null ? const <EditorWindowTarget>[] : await link.targets();
    if (!mounted || !_ws.docs.contains(doc)) return;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(at & const Size(1, 1), Offset.zero & overlay.size),
      items: [
        if (link != null)
          PopupMenuItem(
            key: const ValueKey('editor-tab-move-new'),
            value: 'new',
            child: Text(l10n.editorMoveToNewWindow),
          ),
        for (final t in targets)
          PopupMenuItem(
            key: ValueKey('editor-tab-move-${t.isMain ? 'main' : t.number}'),
            value: 'to:${t.id}',
            child: Text(t.isMain ? l10n.editorMoveToMainWindow : l10n.editorMoveToWindow(t.number)),
          ),
        if (link != null) const PopupMenuDivider(),
        PopupMenuItem(key: const ValueKey('editor-tab-menu-close'), value: 'close', child: Text(l10n.editorCloseTab)),
      ],
    );
    if (picked == null || !mounted || !_ws.docs.contains(doc)) return;
    if (picked == 'close') return _closeTab(doc);
    if (picked == 'new') return _moveTo(doc);
    final id = int.tryParse(picked.substring(3));
    if (id != null) await _moveTo(doc, to: id);
  }

  Future<void> _reconnect(EditorDocument doc) async {
    final ok = await doc.source.reconnect();
    if (!mounted) return;
    setState(() {});
    if (!ok) {
      showTopSnackBar(context, AppLocalizations.of(context)!.editorStillDisconnected(Redactable.host(doc.source.hostLabel ?? '').display), isError: true);
    }
  }

  /// The tab strip's "+": another file on the current file's host.
  Future<void> _openSibling() async {
    final doc = _doc;
    if (doc == null) return;
    final l10n = AppLocalizations.of(context)!;
    final path = doc.source.path;
    final slash = path.lastIndexOf('/');
    final folder = slash < 0 ? '' : path.substring(0, slash + 1);
    final picked = await showZestInputDialog(
      context: context,
      title: l10n.editorOpenFileTitle,
      subtitle: doc.source.hostLabel == null ? null : Redactable.host(doc.source.hostLabel!).display,
      icon: LucideIcons.filePlus,
      fieldLabel: l10n.editorOpenFilePath,
      initialValue: folder,
      selectOnFocus: ZestFieldSelect.end,
      confirmLabel: l10n.editorOpenFileAction,
      validator: (v) => v.trim().isEmpty || v.trim().endsWith('/') ? l10n.editorOpenFileNeedsName : null,
    );
    if (picked == null || !mounted) return;
    final sibling = doc.source.sibling(picked.trim());
    if (sibling == null) return;
    await openInEditor(context, sibling);
  }

  // ── Find, go to line, keys ────────────────────────────────────────

  void _openFind({bool replace = false}) {
    final doc = _doc;
    if (doc == null) return;
    if (replace) {
      doc.find.replaceMode();
    } else {
      doc.find.findMode();
    }
    setState(() {});
  }

  void _closeFind() {
    final doc = _doc;
    if (doc == null) return;
    doc.find.close();
    _focusOf(doc).requestFocus();
    setState(() {});
  }

  Future<void> _goToLine() async {
    final doc = _doc;
    if (doc == null) return;
    final l10n = AppLocalizations.of(context)!;
    final lines = doc.controller.codeLines;
    final count = lines.lineCount;
    final current = lines.index2lineIndex(doc.controller.selection.extentIndex) + 1;
    final picked = await showZestInputDialog(
      context: context,
      title: l10n.editorGoToLineTitle,
      icon: LucideIcons.hash,
      fieldLabel: l10n.editorGoToLineLabel(count),
      initialValue: '$current',
      confirmLabel: l10n.editorGoToLineAction,
      cancelLabel: l10n.cancel,
      keyboardType: TextInputType.number,
      validator: (v) {
        final n = int.tryParse(v.trim());
        return n == null || n < 1 || n > count ? l10n.editorGoToLineInvalid(count) : null;
      },
    );
    if (picked == null || !mounted) return;
    final line = int.tryParse(picked.trim());
    if (line == null) return;
    _moveToLine(doc, line - 1);
  }

  /// Puts the caret at the start of [line] (from 0, counting folded lines),
  /// opening the fold it is in.
  void _moveToLine(EditorDocument doc, int line) {
    final c = doc.controller;
    var at = c.codeLines.lineIndex2Index(line);
    while (at.chunkIndex >= 0) {
      c.expandChunk(at.index);
      at = c.codeLines.lineIndex2Index(line);
    }
    c.selection = CodeLineSelection.collapsed(index: at.index, offset: 0);
    _focusOf(doc).requestFocus();
    try {
      c.makeCursorCenterIfInvisible();
    } catch (_) {}
  }

  /// Tab: a tab character in a file indented with tabs, else the file's
  /// spaces (YAML never gets a tab); with lines selected, they are indented.
  void _indent(EditorDocument doc) {
    final c = doc.controller;
    if (c.selection.isCollapsed && doc.typesTabs) {
      c.replaceSelection('\t');
    } else if (c.selection.isCollapsed) {
      final col = c.selection.extentOffset;
      final size = doc.indent.size;
      c.replaceSelection(' ' * (size - col % size));
    } else {
      c.applyIndent();
    }
  }

  void _cutLine(EditorDocument doc) {
    final c = doc.controller;
    String cut;
    if (!c.selection.isCollapsed) {
      cut = c.selectedText;
      c.deleteSelection();
    } else {
      final i = c.selection.extentIndex;
      if (c.codeLines[i].chunks.isNotEmpty) c.expandChunk(i);
      final lines = c.codeLines;
      final text = lines[i].text;
      if (lines.length == 1 && text.isEmpty) return;
      cut = '$text\n';
      if (i + 1 < lines.length) {
        c.replaceSelection('', CodeLineSelection(baseIndex: i, baseOffset: 0, extentIndex: i + 1, extentOffset: 0));
      } else {
        c.replaceSelection('', CodeLineSelection(baseIndex: i, baseOffset: 0, extentIndex: i, extentOffset: text.length));
      }
    }
    if (cut.isEmpty) return;
    _cutBuffer = identical(_afterLastCut, _before) ? _cutBuffer + cut : cut;
    _afterLastCut = c.value;
    // The system clipboard gets it too, so Ctrl+V and other apps can use it.
    unawaited(Clipboard.setData(ClipboardData(text: _cutBuffer)));
  }

  /// The editor's value as it was before the edit being made (see
  /// [_cutLine]): set by the key handler.
  CodeLineEditingValue? _before;

  void _uncut(EditorDocument doc) {
    if (_cutBuffer.isEmpty) return;
    doc.controller.replaceSelection(_cutBuffer);
    _afterLastCut = null;
  }

  Map<ShortcutActivator, VoidCallback> _keys(EditorDocument doc) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    final c = doc.controller;
    return {
      const SingleActivator(LogicalKeyboardKey.keyS, control: true): () => _save(doc),
      const SingleActivator(LogicalKeyboardKey.keyF, control: true): _openFind,
      const SingleActivator(LogicalKeyboardKey.keyH, control: true): () => _openFind(replace: true),
      if (mac) ...{
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): () => _save(doc),
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true): _openFind,
      },
      const SingleActivator(LogicalKeyboardKey.tab, control: true): () => _ws.activateIndex((_ws.activeIndex + 1) % _ws.length),
      const SingleActivator(LogicalKeyboardKey.tab, control: true, shift: true): () =>
          _ws.activateIndex((_ws.activeIndex - 1 + _ws.length) % _ws.length),
      if (!_nanoKeys) const SingleActivator(LogicalKeyboardKey.keyW, control: true): () => _closeTab(doc),
      if (!_nanoKeys) const SingleActivator(LogicalKeyboardKey.keyG, control: true): _goToLine,
      if (_nanoKeys) ...{
        const SingleActivator(LogicalKeyboardKey.keyA, control: true): c.moveCursorToLineStart,
        const SingleActivator(LogicalKeyboardKey.keyE, control: true): c.moveCursorToLineEnd,
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          _before = c.value;
          _cutLine(doc);
        },
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => _uncut(doc),
        const SingleActivator(LogicalKeyboardKey.keyO, control: true): () => _save(doc),
        const SingleActivator(LogicalKeyboardKey.keyW, control: true): _openFind,
        const SingleActivator(LogicalKeyboardKey.backslash, control: true): () => _openFind(replace: true),
        const SingleActivator(LogicalKeyboardKey.keyG, control: true): _showKeys,
        const SingleActivator(LogicalKeyboardKey.slash, control: true): _goToLine,
        const SingleActivator(LogicalKeyboardKey.keyG, alt: true): _goToLine,
        const SingleActivator(LogicalKeyboardKey.keyU, alt: true): c.undo,
        const SingleActivator(LogicalKeyboardKey.keyE, alt: true): c.redo,
      },
    };
  }

  /// Ctrl+G, as in nano: every editor key in one list.
  Future<void> _showKeys() async {
    final l10n = AppLocalizations.of(context)!;
    final c = l10n.editorKeyCtrl;
    final keys = <(String, String)>[
      ('$c+A', l10n.editorKeyLineStart),
      ('$c+E', l10n.editorKeyLineEnd),
      ('$c+K', l10n.editorKeyCut),
      ('$c+U', l10n.editorKeyPaste),
      ('$c+S   $c+O', l10n.editorKeySave),
      ('$c+F   $c+W', l10n.editorKeyFind),
      ('$c+H   $c+\\', l10n.editorKeyReplace),
      ('$c+/   Alt+G', l10n.editorKeyGoToLine),
      ('$c+Z   Alt+U', l10n.editorKeyUndo),
      ('$c+Y   Alt+E', l10n.editorKeyRedo),
      ('$c+Shift+A', l10n.editorKeySelectAll),
      ('$c+G', l10n.editorKeyHelp),
    ];
    await ZestDialogShell.showModal<void>(
      context,
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.keyboard,
      title: l10n.editorKeysTitle,
      subtitle: l10n.editorKeysSubtitle(c),
      body: Column(
        key: const ValueKey('editor-keys-list'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (key, what) in keys)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 150,
                    child: Text(key, style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: AppColors.v3AccentInk)),
                  ),
                  Expanded(child: Text(what, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary))),
                ],
              ),
            ),
        ],
      ),
      primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
    );
  }

  // ── Choices from the status bar ───────────────────────────────────

  Future<void> _pickEncoding(EditorDocument doc) async {
    final pick = await pickEncoding(
      context,
      doc,
      canReopen: doc.source.canReload && !doc.source.movesText,
      canChange: !doc.source.movesText,
    );
    if (pick == null || !mounted) return;
    if (pick.reopen) {
      if (doc.modified) {
        final choice = await askSaveChanges(context, doc);
        if (!mounted || choice == EditorCloseChoice.cancel) return;
        if (choice == EditorCloseChoice.save && !await _save(doc)) return;
      }
      await _reload(doc, as: pick.encoding);
    } else {
      doc.saveWith(pick.encoding);
    }
  }

  Future<void> _pickLineBreak(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showZestChoice<EditorLineBreak>(
      context,
      title: l10n.editorLineEndingsTitle,
      subtitle: l10n.editorLineEndingsNote,
      icon: LucideIcons.cornerDownLeft,
      selected: doc.lineBreak,
      choices: [
        ZestChoice(value: EditorLineBreak.lf, label: 'LF', detail: l10n.editorLineBreakLf, key: const ValueKey('editor-eol-lf')),
        ZestChoice(value: EditorLineBreak.crlf, label: 'CRLF', detail: l10n.editorLineBreakCrlf, key: const ValueKey('editor-eol-crlf')),
        ZestChoice(value: EditorLineBreak.cr, label: 'CR', detail: l10n.editorLineBreakCr, key: const ValueKey('editor-eol-cr')),
      ],
    );
    if (picked != null && mounted) doc.setLineBreak(picked);
  }

  Future<void> _pickLanguage(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showZestChoice<EditorLanguage>(
      context,
      title: l10n.editorLanguageTitle,
      icon: LucideIcons.braces,
      selected: doc.language,
      choices: [
        for (final lang in EditorLanguage.values) ZestChoice(value: lang, label: _languageLabel(lang), key: ValueKey('editor-lang-${lang.name}')),
      ],
    );
    if (picked != null && mounted) doc.setLanguage(picked);
  }

  Future<void> _pickIndent(EditorDocument doc) async {
    final l10n = AppLocalizations.of(context)!;
    final picked = await showZestChoice<EditorIndent>(
      context,
      title: l10n.editorIndentTitle,
      icon: LucideIcons.indent,
      selected: doc.indent,
      choices: [
        for (final n in const [2, 4, 8]) ZestChoice(value: EditorIndent.spaces(n), label: l10n.editorIndentSpaces(n), key: ValueKey('editor-indent-$n')),
        if (doc.language.allowsTabs) ZestChoice(value: const EditorIndent.tabs(), label: l10n.editorIndentTabs, key: const ValueKey('editor-indent-tabs')),
      ],
    );
    if (picked != null && mounted) doc.setIndent(picked);
  }

  // ── Building ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // What names a host here (its notices among them) is masked while
    // recording mode is on, and shown again as it changes.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);
    final doc = _doc;
    final look = _lastLook = _look();
    final phone = _phone;
    // Back on Android and a swipe back on an iPhone or iPad ask first while
    // changes are not saved, as closing does.
    return PopScope(
      canPop: _ws.unsaved.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(_closeAll());
      },
      child: CallbackShortcuts(
        bindings: doc == null ? const {} : _keys(doc),
        // The code takes the keys at once on a computer (its own autofocus);
        // this holds the screen's keys for whatever has focus under it.
        child: Focus(
          // The bars keep clear of a phone's status and navigation bars,
          // over black, with the system's icons light on it (3.3).
          child: AnnotatedRegion<SystemUiOverlayStyle>(
            value: const SystemUiOverlayStyle(
              statusBarColor: Colors.transparent,
              statusBarIconBrightness: Brightness.light,
              statusBarBrightness: Brightness.dark,
              systemNavigationBarColor: AppColors.systemBarsBlack,
              systemNavigationBarIconBrightness: Brightness.light,
            ),
            child: Scaffold(
              backgroundColor: AppColors.systemBarsBlack,
              body: SafeArea(
                child: ColoredBox(
                  color: AppColors.v3Background,
                  // A tap on the editor's own bars (the keys row, the
                  // toolbar) leaves the code its keyboard and its keys.
                  child: doc == null
                      ? const SizedBox.expand()
                      : CodeEditorTapRegion(child: phone ? _phoneLayout(doc, look) : _desktopLayout(doc, look)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _desktopLayout(EditorDocument doc, EditorLook look) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      children: [
        EditorTabStrip(
          workspace: _ws,
          onClose: _closeTab,
          onReconnect: _reconnect,
          onOpenFile: widget.tabs && doc.source.sibling('') != null ? _openSibling : null,
          onMenu: _link == null ? null : _tabMenu,
          onDraggedOut: _link == null ? null : (d) => _moveTo(d, dragged: true),
          onReorder: _ws.move,
          trailing: [
            // (In a window of its own, its one tab is in a window of its
            // own already.)
            if (_link != null && (_inMainWindow || _ws.length > 1))
              IconButton(
                key: const ValueKey('editor-pop-out'),
                tooltip: l10n.textEditorOpenInSeparateWindow,
                onPressed: () => _moveTo(doc),
                icon: Icon(LucideIcons.externalLink, size: 15, color: AppColors.v3TextSecondary),
              ),
            if (_canMinimize)
              IconButton(
                key: const ValueKey('editor-minimize'),
                tooltip: l10n.editorMinimize,
                onPressed: _minimize,
                icon: Icon(LucideIcons.minus, size: 16, color: AppColors.v3TextSecondary),
              ),
            IconButton(
              key: const ValueKey('editor-close'),
              tooltip: l10n.close,
              onPressed: _closeAll,
              icon: Icon(LucideIcons.x, size: 16, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(width: 6),
          ],
        ),
        ListenableBuilder(listenable: doc.find, builder: (context, _) => _toolbar(doc)),
        _findBar(doc),
        ..._notices(doc),
        Expanded(child: _code(doc, look)),
        ListenableBuilder(listenable: doc.controller, builder: (context, _) => _statusBar(doc, look)),
      ],
    );
  }

  Widget _findBar(EditorDocument doc) => ValueListenableBuilder(
        valueListenable: doc.find,
        builder: (context, value, _) =>
            value == null ? const SizedBox.shrink() : EditorFindBar(find: doc.find, onClose: _closeFind),
      );

  Widget _toolbar(EditorDocument doc) {
    final l10n = AppLocalizations.of(context)!;
    final source = doc.source;
    final path = source.path.isEmpty ? source.fileName : source.path;
    final slash = path.lastIndexOf('/');
    final folder = slash < 0 ? '' : path.substring(0, slash + 1);
    final access = doc.access;
    final canSave = source.canSave && doc.modified && !doc.saving;
    return LayoutBuilder(builder: (context, c) {
      final labels = c.maxWidth >= 980;
      return Container(
        key: const ValueKey('editor-toolbar'),
        height: 48,
        padding: const EdgeInsets.only(left: 12, right: 8),
        decoration: BoxDecoration(
          color: AppColors.v3Surface,
          border: Border(bottom: BorderSide(color: AppColors.v3BorderSubtle)),
        ),
        child: Row(
          children: [
            // The file at the left takes what the actions leave, so the
            // actions stand at the right edge however short the path (as the
            // design; a Flexible path beside a Spacer kept half the room
            // empty after them).
            Expanded(
              child: Row(
                children: [
                  if (source.hostLabel != null) ...[
                    Container(
                      height: 26,
                      padding: const EdgeInsets.symmetric(horizontal: 9),
                      decoration: BoxDecoration(
                        color: AppColors.v3Background,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: AppColors.v3BorderSubtle),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: source.isConnected ? AppColors.v3Success : AppColors.v3Error,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 7),
                          EditorHostText(
                            source.hostLabel!,
                            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: AppColors.v3TextPrimary),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                  ],
                  Flexible(
                    child: Text.rich(
                      TextSpan(children: [
                        TextSpan(text: folder, style: TextStyle(color: AppColors.v3TextTertiary)),
                        TextSpan(text: path.substring(slash + 1), style: TextStyle(color: AppColors.v3TextPrimary, fontWeight: FontWeight.w600)),
                      ]),
                      key: const ValueKey('editor-path'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5),
                    ),
                  ),
                  if (access?.owner != null) ...[
                    const SizedBox(width: 8),
                    Container(
                      key: const ValueKey('editor-owner'),
                      height: 22,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      decoration: BoxDecoration(color: AppColors.v3Elevated, borderRadius: BorderRadius.circular(6)),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.lock, size: 11, color: AppColors.v3TextTertiary),
                          const SizedBox(width: 5),
                          Text('${access!.owner} ${access.mode ?? ''}'.trim(),
                              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextTertiary)),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            EditorToolButton(
              key: const ValueKey('editor-tool-find'),
              icon: LucideIcons.search,
              label: l10n.editorKeyFind,
              tooltip: l10n.editorFindTooltip,
              showLabel: labels,
              on: doc.find.isOpen,
              onPressed: () => doc.find.isOpen ? _closeFind() : _openFind(),
            ),
            EditorToolButton(
              key: const ValueKey('editor-tool-wrap'),
              icon: LucideIcons.wrapText,
              label: l10n.editorWrap,
              tooltip: _wrap ? l10n.editorDisableWordWrap : l10n.editorEnableWordWrap,
              showLabel: labels,
              on: _wrap,
              onPressed: () => setState(() => _wrap = !_wrap),
            ),
            EditorToolButton(
              key: const ValueKey('editor-tool-language'),
              icon: LucideIcons.braces,
              label: _languageLabel(doc.language),
              tooltip: l10n.editorLanguageTitle,
              showLabel: true,
              onPressed: () => _pickLanguage(doc),
              trailing: Icon(LucideIcons.chevronDown, size: 12, color: AppColors.v3TextTertiary),
            ),
            Container(width: 1, height: 22, margin: const EdgeInsets.symmetric(horizontal: 6), color: AppColors.v3BorderSubtle),
            // Only for a file the login account may not write, on a host
            // with sudo (an SFTP-only host has no shell to run it).
            if (source.canSave && (access?.needsRoot ?? false)) ...[
              OutlinedButton.icon(
                key: const ValueKey('editor-save-as-root'),
                onPressed: doc.saving ? null : () => _saveAsRoot(doc),
                icon: const Icon(LucideIcons.shield, size: 14),
                label: Text(l10n.editorSaveAsRoot, style: const TextStyle(fontSize: 12.5)),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.v3TextPrimary,
                  side: BorderSide(color: AppColors.v3BorderDefault),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              const SizedBox(width: 6),
            ],
            if (source.canSave)
              FilledButton.icon(
                key: const ValueKey('editor-save'),
                onPressed: canSave ? () => _save(doc) : null,
                icon: doc.saving
                    ? const SizedBox(width: 13, height: 13, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(LucideIcons.save, size: 14),
                label: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(l10n.save, style: const TextStyle(fontSize: 12.5)),
                    if (labels) ...[
                      const SizedBox(width: 8),
                      Text(defaultTargetPlatform == TargetPlatform.macOS ? '⌘S' : 'Ctrl+S',
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: AppColors.onBrand(AppColors.v3AccentPrimary).withValues(alpha: 0.7))),
                    ],
                  ],
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.v3AccentPrimary,
                  foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  minimumSize: const Size(0, 32),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
            const SizedBox(width: 4),
            _moreMenu(doc),
          ],
        ),
      );
    });
  }

  Widget _moreMenu(EditorDocument doc) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      key: const ValueKey('editor-more'),
      tooltip: l10n.editorMore,
      icon: Icon(LucideIcons.moreHorizontal, size: 16, color: AppColors.v3TextSecondary),
      onSelected: (v) {
        switch (v) {
          case 'reload':
            unawaited(_reload(doc));
          case 'look':
            unawaited(_setTerminalLook(!_terminalLook));
          case 'nano':
            unawaited(_setNanoKeys(!_nanoKeys));
          case 'minimap':
            unawaited(_setMinimap(!_minimap));
          case 'bigger':
            unawaited(_setTextSize((_textSize ?? _lastLook?.fontSize ?? 13) + 1));
          case 'smaller':
            unawaited(_setTextSize((_textSize ?? _lastLook?.fontSize ?? 13) - 1));
          case 'line':
            unawaited(_goToLine());
          case 'keys':
            unawaited(_showKeys());
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'line', child: Text(l10n.editorGoToLineTitle)),
        if (doc.source.canReload) PopupMenuItem(value: 'reload', child: Text(l10n.textEditorReload)),
        const PopupMenuDivider(),
        CheckedPopupMenuItem(
          key: const ValueKey('editor-more-look'),
          value: 'look',
          checked: _terminalLook,
          child: Text(l10n.editorTerminalLook),
        ),
        CheckedPopupMenuItem(value: 'nano', checked: _nanoKeys, child: Text(l10n.editorNanoKeys)),
        // Computers only: never on a tablet, whose layout this menu is too.
        if (!isTouchLayout)
          CheckedPopupMenuItem(
            key: const ValueKey('editor-more-minimap'),
            value: 'minimap',
            checked: _minimap,
            child: Text(l10n.editorMinimap),
          ),
        PopupMenuItem(value: 'bigger', child: Text(l10n.editorTextBigger)),
        PopupMenuItem(value: 'smaller', child: Text(l10n.editorTextSmaller)),
        PopupMenuItem(value: 'keys', child: Text(l10n.editorKeysTitle)),
      ],
    );
  }

  List<Widget> _notices(EditorDocument doc) {
    final l10n = AppLocalizations.of(context)!;
    final restored = doc.draftRestored;
    final host = editorHostShown(doc.source);
    return [
      if (restored != null && !doc.draftNoticeHidden)
        EditorNotice(
          key: const ValueKey('editor-draft-restored'),
          icon: LucideIcons.history,
          title: l10n.editorDraftRestoredTitle,
          body: l10n.editorDraftRestoredBody(
            doc.changedLines,
            DateFormat.MMMEd(l10n.localeName).add_Hm().formatPlain(restored.keptAt),
          ),
          secondLine: switch (restored.hostChanged) {
            false => l10n.editorDraftSame(host),
            true => l10n.editorDraftChanged(host),
            null => null,
          },
          actions: [
            OutlinedButton(
              key: const ValueKey('editor-draft-show'),
              onPressed: () => _showChanges(doc),
              child: Text(l10n.editorShowChanges),
            ),
            TextButton(
              key: const ValueKey('editor-draft-discard'),
              onPressed: () => _discardDraft(doc),
              style: TextButton.styleFrom(foregroundColor: AppColors.v3Error),
              child: Text(l10n.editorDiscardDraft),
            ),
          ],
          onHide: () => setState(() => doc.draftNoticeHidden = true),
        ),
      if (doc.openedNotUtf8 && !doc.encodingNoticeHidden)
        EditorNotice(
          key: const ValueKey('editor-not-utf8'),
          icon: LucideIcons.languages,
          title: l10n.editorNotUtf8Title,
          body: l10n.editorNotUtf8Body(doc.encoding.label),
          actions: [
            OutlinedButton(onPressed: () => _pickEncoding(doc), child: Text(l10n.editorPickEncoding)),
          ],
          onHide: () => setState(() => doc.encodingNoticeHidden = true),
        ),
    ];
  }

  Widget _code(EditorDocument doc, EditorLook look) {
    final mode = doc.language.mode;
    final editor = CodeEditor(
      key: ObjectKey(doc),
      controller: doc.controller,
      findController: doc.find,
      scrollController: _scrollOf(doc),
      focusNode: _focusOf(doc),
      autofocus: !_phone,
      wordWrap: _wrap,
      padding: const EdgeInsets.only(left: 6, right: 10, top: 8, bottom: 8),
      style: CodeEditorStyle(
        fontSize: look.fontSize,
        fontFamily: look.fontFamily,
        fontHeight: 1.5,
        textColor: look.foreground,
        backgroundColor: look.background,
        selectionColor: look.selection,
        highlightColor: look.match,
        cursorColor: look.cursor,
        cursorLineColor: look.currentLine,
        chunkIndicatorColor: look.gutterText,
        codeTheme: CodeHighlightTheme(
          languages: {
            if (mode != null && EditorLanguages.modes[mode] != null) mode: CodeHighlightThemeMode(mode: EditorLanguages.modes[mode]!),
          },
          theme: look.syntax,
        ),
      ),
      indicatorBuilder: (context, editing, chunks, notifier) => Row(
        children: [
          EditorGutter(doc: doc, notifier: notifier, look: look),
          DefaultCodeChunkIndicator(width: 16, controller: chunks, notifier: notifier),
        ],
      ),
      shortcutsActivatorsBuilder: _EditorKeyMap(nano: _nanoKeys),
      shortcutOverrideActions: {
        CodeShortcutIndentIntent: CallbackAction<CodeShortcutIndentIntent>(onInvoke: (_) {
          _indent(doc);
          return null;
        }),
      },
    );
    // Two fingers pinch the text size (phones); the code keeps every other
    // gesture.
    return Listener(
      onPointerDown: (e) {
        _pointers[e.pointer] = e.position;
        if (_pointers.length == 2) {
          final p = _pointers.values.toList();
          _pinchStartDistance = (p[0] - p[1]).distance;
          _pinchStartSize = look.fontSize;
        }
      },
      onPointerMove: (e) {
        if (!_pointers.containsKey(e.pointer)) return;
        _pointers[e.pointer] = e.position;
        final start = _pinchStartDistance;
        if (_pointers.length == 2 && start != null && start > 0) {
          final p = _pointers.values.toList();
          final scale = (p[0] - p[1]).distance / start;
          unawaited(_setTextSize(_pinchStartSize! * scale));
        }
      },
      onPointerUp: (e) => _endPointer(e.pointer),
      onPointerCancel: (e) => _endPointer(e.pointer),
      // A phone's or a tablet's own keyboard: the code editor takes no keys
      // there but Backspace and Enter, so Tab is typed here (on a computer
      // its own shortcut has it first).
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (node, event) {
          if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
              event.logicalKey == LogicalKeyboardKey.tab &&
              !HardwareKeyboard.instance.isShiftPressed &&
              !HardwareKeyboard.instance.isControlPressed &&
              _focusOf(doc).hasFocus) {
            _indent(doc);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        // One shape with the minimap or without, so switching it keeps the
        // code editor (and where it stands) as it is.
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: EditorLineReader(
                controller: doc.controller,
                fileName: doc.source.fileName,
                onActivate: () => _focusOf(doc).requestFocus(),
                child: editor,
              ),
            ),
            if (_showMinimap)
              EditorMinimap(
                controller: doc.controller,
                scroller: _scrollOf(doc).verticalScroller,
                look: look,
                language: doc.language,
              ),
          ],
        ),
      ),
    );
  }

  void _endPointer(int pointer) {
    _pointers.remove(pointer);
    if (_pointers.length < 2) _pinchStartDistance = null;
  }

  Widget _statusBar(EditorDocument doc, EditorLook look) {
    final l10n = AppLocalizations.of(context)!;
    final c = doc.controller;
    final sel = c.selection;
    final lines = c.codeLines;
    final line = lines.index2lineIndex(sel.extentIndex) + 1;
    final col = sel.extentOffset + 1;
    final selected = sel.isCollapsed ? 0 : c.selectedText.length;
    final changed = doc.modified ? doc.changedLines : 0;
    final source = doc.source;
    final left = Row(
      children: [
        if (source.hostLabel != null) ...[
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: source.isConnected ? AppColors.v3Success : AppColors.v3Error, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: EditorHostText(source.hostLabel!,
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextSecondary)),
          ),
          const SizedBox(width: 10),
        ],
        Flexible(
          child: Text(
            source.path.isEmpty ? source.fileName : source.path,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: AppColors.v3TextTertiary),
          ),
        ),
        const SizedBox(width: 10),
        if (doc.modified)
          EditorStatusItem(
            key: const ValueKey('editor-unsaved'),
            shrinks: true,
            leading: Container(width: 7, height: 7, decoration: BoxDecoration(color: AppColors.v3AccentPrimary, shape: BoxShape.circle)),
            label: doc.drafted
                ? l10n.editorUnsavedLinesDraft(changed)
                : changed > 0
                    ? l10n.editorUnsavedLines(changed)
                    : l10n.editorModified,
            color: AppColors.v3AccentInk,
          )
        else if (doc.savedAt != null)
          EditorStatusItem(shrinks: true, label: l10n.editorSavedAt(DateFormat.Hm(l10n.localeName).formatPlain(doc.savedAt!))),
      ],
    );
    final right = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EditorStatusItem(
          key: const ValueKey('editor-status-position'),
          label: selected > 0 ? l10n.editorLnColSelected(line, col, selected) : l10n.editorLnCol(line, col),
          tooltip: l10n.editorGoToLineTitle,
          onTap: _goToLine,
        ),
        EditorStatusItem(
          key: const ValueKey('editor-status-indent'),
          label: doc.indent.tabs && doc.language.allowsTabs ? l10n.editorIndentTabs : l10n.editorIndentSpaces(doc.indent.size),
          tooltip: l10n.editorIndentTitle,
          onTap: () => _pickIndent(doc),
        ),
        EditorStatusItem(
          key: const ValueKey('editor-status-encoding'),
          label: doc.encoding.label,
          tooltip: l10n.editorEncodingTitle,
          onTap: () => _pickEncoding(doc),
        ),
        EditorStatusItem(
          key: const ValueKey('editor-status-eol'),
          label: doc.mixedLineBreaks ? '${doc.lineBreak.label}*' : doc.lineBreak.label,
          tooltip: doc.mixedLineBreaks ? l10n.editorMixedLineBreaks(doc.lineBreak.label) : l10n.editorLineEndingsTitle,
          onTap: source.movesText ? null : () => _pickLineBreak(doc),
        ),
        EditorStatusItem(
          key: const ValueKey('editor-status-language'),
          label: _languageLabel(doc.language),
          tooltip: l10n.editorLanguageTitle,
          onTap: () => _pickLanguage(doc),
        ),
        _nanoChip(),
        EditorStatusItem(
          key: const ValueKey('editor-status-font'),
          label: '${_fontName(look)} ${look.fontSize.round()}px',
          tooltip: l10n.editorTerminalLook,
        ),
      ],
    );
    return Container(
      key: const ValueKey('editor-status'),
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: AppColors.v3ChromeBg,
        border: Border(top: BorderSide(color: AppColors.v3ChromeDivider)),
      ),
      child: LayoutBuilder(
        builder: (context, box) => Row(
          children: [
            Expanded(child: left),
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: box.maxWidth * 0.72),
              child: SingleChildScrollView(scrollDirection: Axis.horizontal, reverse: true, child: right),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nanoChip() {
    final l10n = AppLocalizations.of(context)!;
    final color = _nanoKeys ? AppColors.v3AccentInk : AppColors.v3TextTertiary;
    return Tooltip(
      message: _nanoKeys ? l10n.editorNanoKeysOnTooltip(l10n.editorKeyCtrl) : l10n.editorNanoKeysOffTooltip(l10n.editorKeyCtrl),
      child: InkWell(
        key: const ValueKey('editor-nano-keys'),
        onTap: () => _setNanoKeys(!_nanoKeys),
        borderRadius: BorderRadius.circular(5),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.keyboard, size: 12, color: color),
              const SizedBox(width: 5),
              Text(
                l10n.editorNanoKeys,
                style: TextStyle(
                  fontSize: 11.5,
                  color: color,
                  fontFamily: 'JetBrainsMono',
                  decoration: _nanoKeys ? TextDecoration.none : TextDecoration.lineThrough,
                  decorationColor: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Phone ─────────────────────────────────────────────────────────

  Widget _phoneLayout(EditorDocument doc, EditorLook look) {
    final l10n = AppLocalizations.of(context)!;
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0 && _focusOf(doc).hasFocus;
    final source = doc.source;
    final path = source.path.isEmpty ? source.fileName : source.path;
    final slash = path.lastIndexOf('/');
    final folder = slash < 0 ? '' : path.substring(0, slash + 1);
    final access = doc.access;
    return Column(
      children: [
        KeyedSubtree(
          key: _phoneTopBar,
          child: Container(
            key: const ValueKey('editor-phone-top'),
            height: 52,
            padding: const EdgeInsets.only(left: 4, right: 8),
            decoration: BoxDecoration(
              color: AppColors.v3ChromeBg,
              border: Border(bottom: BorderSide(color: AppColors.v3ChromeDivider)),
            ),
            child: Row(
              children: [
                IconButton(
                  key: const ValueKey('editor-close'),
                  tooltip: l10n.close,
                  onPressed: _closeAll,
                  icon: Icon(LucideIcons.x, size: 18, color: AppColors.v3TextSecondary),
                ),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(source.fileName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
                      Row(
                        children: [
                          if (source.hostLabel != null) ...[
                            Container(
                              width: 6,
                              height: 6,
                              decoration: BoxDecoration(
                                  color: source.isConnected ? AppColors.v3Success : AppColors.v3Error, shape: BoxShape.circle),
                            ),
                            const SizedBox(width: 5),
                            Flexible(
                              child: EditorHostText(source.hostLabel!,
                                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: AppColors.v3TextSecondary)),
                            ),
                            Text(' · ', style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary)),
                          ],
                          Flexible(
                            child: Text(folder,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: AppColors.v3TextTertiary)),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (typing)
                  TextButton(
                    key: const ValueKey('editor-phone-done'),
                    onPressed: () => FocusManager.instance.primaryFocus?.unfocus(),
                    child: Text(l10n.done),
                  )
                else if (access?.owner != null)
                  Container(
                    key: const ValueKey('editor-owner'),
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
                    decoration: BoxDecoration(color: AppColors.v3Elevated, borderRadius: BorderRadius.circular(6)),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.lock, size: 11, color: AppColors.v3TextTertiary),
                        const SizedBox(width: 4),
                        Text('${access!.owner!.split(':').first} ${access.mode ?? ''}'.trim(),
                            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11, color: AppColors.v3TextTertiary)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
        EditorTabStrip(workspace: _ws, onClose: _closeTab, onReconnect: _reconnect, compact: true),
        _findBar(doc),
        ..._notices(doc),
        Expanded(child: _code(doc, look)),
        if (typing)
          EditorKeysRow(onKey: (k) => _rowKey(doc, k), onText: (t) => doc.controller.replaceSelection(t))
        else
          ValueListenableBuilder(
            valueListenable: doc.controller,
            builder: (context, _, _) => EditorPhoneBar(
              onSave: () => _save(doc),
              canSave: source.canSave && doc.modified,
              saving: doc.saving,
              onFind: () => doc.find.isOpen ? _closeFind() : _openFind(),
              onUndo: doc.controller.canUndo ? doc.controller.undo : null,
              onRedo: doc.controller.canRedo ? doc.controller.redo : null,
              onMore: () => _moreSheet(doc, look),
            ),
          ),
      ],
    );
  }

  void _rowKey(EditorDocument doc, EditorRowKey key) {
    final c = doc.controller;
    switch (key) {
      case EditorRowKey.tab:
        _indent(doc);
      case EditorRowKey.esc:
        if (doc.find.isOpen) {
          _closeFind();
        } else {
          FocusManager.instance.primaryFocus?.unfocus();
        }
      case EditorRowKey.undo:
        c.undo();
      case EditorRowKey.redo:
        c.redo();
      case EditorRowKey.left:
        c.moveCursor(AxisDirection.left);
      case EditorRowKey.up:
        c.moveCursor(AxisDirection.up);
      case EditorRowKey.down:
        c.moveCursor(AxisDirection.down);
      case EditorRowKey.right:
        c.moveCursor(AxisDirection.right);
    }
  }

  /// Everything that does not fit a phone's bar, in one sheet (3.4, screen
  /// 5).
  Future<void> _moreSheet(EditorDocument doc, EditorLook look) async {
    final l10n = AppLocalizations.of(context)!;
    final lines = doc.controller.codeLines;
    final line = lines.index2lineIndex(doc.controller.selection.extentIndex) + 1;
    final source = doc.source;
    // The app's own sheet (zest_sheet.dart), on its own surface with its
    // handle: the phone sheet style.
    await showZestSheet<void>(
      context: context,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.v3Elevated,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        ),
        child: SafeArea(
          top: false,
          child: StatefulBuilder(
          builder: (sheet, setSheet) => SingleChildScrollView(
            child: Column(
              key: const ValueKey('editor-more-sheet'),
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(color: AppColors.v3BorderDefault, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(18, 14, 8, 6),
                  child: Row(
                    children: [
                      Icon(LucideIcons.fileText, size: 16, color: AppColors.v3TextSecondary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          [if (source.hostLabel != null) Redactable.host(source.hostLabel!).display, source.path.isEmpty ? source.fileName : source.path]
                              .join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                        ),
                      ),
                      IconButton(
                        tooltip: l10n.close,
                        onPressed: () => Navigator.of(sheet).pop(),
                        icon: Icon(LucideIcons.x, size: 16, color: AppColors.v3TextSecondary),
                      ),
                    ],
                  ),
                ),
                EditorSheetRow(
                  key: const ValueKey('editor-sheet-line'),
                  icon: LucideIcons.hash,
                  title: l10n.editorGoToLineTitle,
                  value: l10n.editorLineOf(line, lines.lineCount),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_goToLine());
                  },
                ),
                EditorSheetRow(
                  icon: LucideIcons.wrapText,
                  title: l10n.editorWrapLines,
                  trailing: Switch(
                    key: const ValueKey('editor-sheet-wrap'),
                    value: _wrap,
                    onChanged: (v) {
                      setState(() => _wrap = v);
                      setSheet(() {});
                    },
                  ),
                ),
                EditorSheetRow(
                  icon: LucideIcons.type,
                  title: l10n.editorTextSize,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        key: const ValueKey('editor-sheet-smaller'),
                        tooltip: l10n.editorTextSmaller,
                        onPressed: () async {
                          await _setTextSize((_textSize ?? look.fontSize) - 1);
                          setSheet(() {});
                        },
                        icon: const Icon(LucideIcons.minus, size: 16),
                      ),
                      Text('${(_textSize ?? look.fontSize).round()}',
                          style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 13, color: AppColors.v3TextPrimary)),
                      IconButton(
                        key: const ValueKey('editor-sheet-bigger'),
                        tooltip: l10n.editorTextBigger,
                        onPressed: () async {
                          await _setTextSize((_textSize ?? look.fontSize) + 1);
                          setSheet(() {});
                        },
                        icon: const Icon(LucideIcons.plus, size: 16),
                      ),
                    ],
                  ),
                ),
                EditorSheetRow(
                  icon: LucideIcons.languages,
                  title: l10n.editorEncodingTitle,
                  value: doc.encoding.label,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_pickEncoding(doc));
                  },
                ),
                EditorSheetRow(
                  icon: LucideIcons.cornerDownLeft,
                  title: l10n.editorLineEndingsTitle,
                  value: doc.lineBreak.label,
                  onTap: source.movesText
                      ? null
                      : () {
                          Navigator.of(sheet).pop();
                          unawaited(_pickLineBreak(doc));
                        },
                ),
                EditorSheetRow(
                  icon: LucideIcons.braces,
                  title: l10n.editorLanguageTitle,
                  value: _languageLabel(doc.language),
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_pickLanguage(doc));
                  },
                ),
                if (source.canSave && (doc.access?.needsRoot ?? false))
                  EditorSheetRow(
                    key: const ValueKey('editor-sheet-root'),
                    icon: LucideIcons.shield,
                    title: l10n.editorSaveAsRoot,
                    subtitle: l10n.editorSaveAsRootSheet(doc.access!.owner ?? 'root'),
                    onTap: () {
                      Navigator.of(sheet).pop();
                      unawaited(_saveAsRoot(doc));
                    },
                  ),
                EditorSheetRow(
                  key: const ValueKey('editor-sheet-close-tab'),
                  icon: LucideIcons.x,
                  title: l10n.editorCloseTab,
                  danger: true,
                  onTap: () {
                    Navigator.of(sheet).pop();
                    unawaited(_closeTab(doc));
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

/// The code editor's keys, with what the screen does itself taken out (Save,
/// Find, Replace), and, while nano keys are on, Ctrl+A left to them (select
/// all is Ctrl+Shift+A then) and Ctrl+/ to go to a line.
class _EditorKeyMap extends CodeShortcutsActivatorsBuilder {
  const _EditorKeyMap({required this.nano});

  final bool nano;

  @override
  List<ShortcutActivator>? build(CodeShortcutType type) {
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    switch (type) {
      case CodeShortcutType.find:
      case CodeShortcutType.replace:
      case CodeShortcutType.save:
        return null;
      case CodeShortcutType.selectAll:
        if (nano && !mac) return const [SingleActivator(LogicalKeyboardKey.keyA, control: true, shift: true)];
      case CodeShortcutType.singleLineComment:
        if (nano && !mac) return null;
      case CodeShortcutType.redo:
        if (!mac) {
          return const [
            SingleActivator(LogicalKeyboardKey.keyZ, control: true, shift: true),
            SingleActivator(LogicalKeyboardKey.keyY, control: true),
          ];
        }
      default:
        break;
    }
    return const DefaultCodeShortcutsActivatorsBuilder().build(type);
  }
}
