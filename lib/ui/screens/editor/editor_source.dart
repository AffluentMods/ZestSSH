import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:zest_ssh_core/dartssh2.dart' show SftpStatusCode, SftpStatusError;
import 'package:zestssh/services/sftp_service.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_pane_source.dart';

/// Largest file the in-app editor will open. Above this, callers offer a
/// download instead: a size gate that does not match the read cap could
/// silently truncate and then save. One shared value keeps every entry
/// point's gate AND read cap in lock-step.
const int kMaxInlineEditBytes = 4 * 1024 * 1024; // 4 MB

/// What the editor knows of a file on its host, to tell whether it changed
/// since it was read: its hash where the host can say it, else its time and
/// size.
class FileVersion {
  const FileVersion({this.modified, this.size, this.sha256});

  /// The version of [bytes] as they were read, at [modified].
  factory FileVersion.of(Uint8List bytes, {DateTime? modified}) =>
      FileVersion(modified: modified, size: bytes.length, sha256: hashOf(bytes));

  final DateTime? modified;
  final int? size;

  /// The SHA-256 of its bytes, in lowercase hex.
  final String? sha256;

  static String hashOf(List<int> bytes) => sha256Of(bytes);

  /// Whether the file is not the one [before] was: by its hash where both
  /// have one (so a file put back from an older copy, whose time is older,
  /// is caught), else by a size or a time that differs.
  bool changedSince(FileVersion before) {
    if (sha256 != null && before.sha256 != null) return sha256 != before.sha256;
    if (size != null && before.size != null && size != before.size) return true;
    if (modified != null && before.modified != null) return !modified!.isAtSameMomentAs(before.modified!);
    return false;
  }
}

/// The SHA-256 of [bytes], in lowercase hex.
String sha256Of(List<int> bytes) => sha256.convert(bytes).toString();

/// What the editor shows of who may write a file: its owner and group
/// ("root:root") and mode ("644"), whether the login account may write it
/// (null where not known), and whether it can be saved as root.
class FileAccess {
  const FileAccess({this.owner, this.mode, this.writable, this.canSudo = false});

  final String? owner;
  final String? mode;
  final bool? writable;
  final bool canSudo;

  /// Whether Save as root is offered for it at once: the login account may
  /// not write it, and the host has sudo.
  bool get needsRoot => writable == false && canSudo;
}

/// Which host a file in the editor is on, as the editor tells hosts apart:
/// never by the label it shows, which two hosts can share (a host in
/// Personal and one in a team, two teams, or two panes with no label at
/// all), so a tab, a save and a draft are always the one host's.
class EditorHost {
  /// A saved host: the space it is kept in ([team], a team's id, or null for
  /// Personal), its id there, and the account its session signs in as (null
  /// for the host's own).
  EditorHost.saved({this.team, required this.connectionId, String? account})
      : key = 'host\u0000${team ?? ''}\u0000$connectionId\u0000${account ?? ''}',
        known = true;

  /// This computer's own files.
  const EditorHost.thisComputer()
      : key = 'local',
        team = null,
        connectionId = null,
        known = true;

  /// A host the editor cannot name for sure (a pane whose connection has no
  /// session behind it): one of its own, shared only with the files opened
  /// beside it from the same place ([EditorSource.sibling]). Its files never
  /// share a tab with another host's, and no draft is kept for them, as one
  /// could not be found again for the same host.
  EditorHost.unknown()
      : key = 'unknown\u0000${_unknowns++}',
        team = null,
        connectionId = null,
        known = false;

  /// A host as another of the app's windows named it (an editor in a
  /// window of its own is handed its tabs' hosts): the same [key], so its
  /// files are the same files there ([EditorSource.identity]) and their
  /// drafts the same drafts.
  const EditorHost.named(this.key, {this.team, this.connectionId, required this.known});

  static int _unknowns = 0;

  /// What tells it apart; it names the host's id, never its label.
  final String key;

  /// The team whose database keeps its drafts; null for Personal.
  final String? team;

  /// The saved host's id; null for this computer and an unknown host.
  final String? connectionId;

  /// Whether it is a host the app keeps (or this computer), so that a draft
  /// kept for one of its files can be found again for it alone.
  final bool known;
}

/// Where a file in the editor comes from and goes back to: a host over SFTP,
/// this computer, or (in a window of its own) the main window, which holds
/// the connection.
abstract class EditorSource {
  /// The file's name, for its tab and its language.
  String get fileName;

  /// Its full path on its host ('' where not known).
  String get path;

  /// The host it is on, as its label ("web-01"), for showing only: two hosts
  /// can share a label, so the editor tells them apart by [host].
  String? get hostLabel;

  /// The host it is on, as the editor tells hosts apart.
  EditorHost get host;

  /// Whether it can be saved, and read again, from where it was opened.
  bool get canSave => true;
  bool get canReload => true;

  /// A key that names this file on its host, the same each time it is
  /// opened: two tabs never hold one file, and its draft is found by it. It
  /// names the host by its id ([host]), never by its label: one path on two
  /// hosts that share a label is two files.
  String get identity => '${host.key}\u0000$path';

  /// The key a draft of it was kept under before drafts named the host by
  /// its id (by its label): looked at only where that label is one saved
  /// host's alone, and that host is [host].
  String get labelIdentity => '${hostLabel ?? ''}\u0000$path';

  /// Whether this source moves text rather than bytes (a window of its own
  /// hands text to the main window, which writes it): [readText] and
  /// [writeText] are used then, and the encoding is not changed here.
  bool get movesText => false;

  /// Whether its unsaved text is kept as a draft on this device: a file of a
  /// host the app can name for sure, whose bytes come and go here (a window
  /// of its own keeps its tabs' drafts through the main window instead).
  bool get keepsDrafts => !movesText && host.known;

  /// The file's bytes as they are on its host now.
  Future<Uint8List> read() => throw UnsupportedError('read');

  /// Writes [bytes] as the file.
  Future<void> write(Uint8List bytes) => throw UnsupportedError('write');

  /// For a source that [movesText].
  Future<String> readText() => throw UnsupportedError('readText');
  Future<void> writeText(String text) => throw UnsupportedError('writeText');

  /// The file as it is on its host now; null where that cannot be told.
  Future<FileVersion?> version();

  /// Who may write it; null where that cannot be told.
  Future<FileAccess?> access() async => null;

  /// Writes [bytes] as the file as root, with [password] given to sudo for
  /// this one write ([SftpService.writeFileAsRoot]).
  Future<void> writeAsRoot(Uint8List bytes, String password) => throw UnsupportedError('writeAsRoot');

  /// Whether its connection is up (a file on this computer always is).
  bool get isConnected => true;

  /// Connects again where it dropped; whether it is up now.
  Future<bool> reconnect() async => isConnected;

  /// Another file on the same host, at [path], for the tab strip's "+";
  /// null where this source cannot open others.
  EditorSource? sibling(String path) => null;

  /// Whether [error], from [write], means the login account may not write
  /// the file (where Save as root is offered).
  static bool isPermissionDenied(Object error) {
    if (error is SftpStatusError) return error.code == SftpStatusCode.permissionDenied;
    if (error is SftpWrittenInPlaceException) return isPermissionDenied(error.cause);
    return false;
  }
}

/// A file on a host over SFTP.
class SftpEditorSource extends EditorSource {
  SftpEditorSource({
    required SftpService service,
    required this.path,
    required this.hostLabel,
    EditorHost? host,
    this.onSaved,
    this.reconnectWith,
  })  : _service = service,
        host = host ?? EditorHost.unknown();

  SftpService _service;
  SftpService get service => _service;

  @override
  final String path;

  @override
  final String hostLabel;

  @override
  final EditorHost host;

  /// Told after each save (the list behind the editor shows the file as it
  /// is now).
  final void Function()? onSaved;

  /// A live file service for the host, where its connection dropped: the
  /// session's own, opened again, or null where there is none.
  final Future<SftpService?> Function()? reconnectWith;

  @override
  String get fileName {
    final i = path.lastIndexOf('/');
    return i < 0 ? path : path.substring(i + 1);
  }

  @override
  Future<Uint8List> read() => _service.downloadFile(path, maxBytes: kMaxInlineEditBytes);

  @override
  Future<void> write(Uint8List bytes) async {
    await _service.uploadFile(path, bytes);
    onSaved?.call();
  }

  @override
  Future<FileVersion?> version() async {
    final attrs = await _service.statOrNull(path);
    final hash = await _service.sha256Remote(path);
    final seconds = attrs?.modifyTime;
    if (attrs == null && hash == null) return null;
    return FileVersion(
      modified: seconds == null ? null : DateTime.fromMillisecondsSinceEpoch(seconds * 1000),
      size: attrs?.size,
      sha256: hash,
    );
  }

  @override
  Future<FileAccess?> access() async {
    final a = await _service.fileAccess(path);
    if (a == null) return null;
    return FileAccess(owner: a.owner, mode: a.mode, writable: a.writable, canSudo: a.sudo);
  }

  @override
  Future<void> writeAsRoot(Uint8List bytes, String password) async {
    await _service.writeFileAsRoot(path, bytes, password);
    onSaved?.call();
  }

  @override
  bool get isConnected => _service.isOpen;

  @override
  Future<bool> reconnect() async {
    if (_service.isOpen) return true;
    final fresh = await reconnectWith?.call();
    if (fresh != null && fresh.isOpen) _service = fresh;
    return _service.isOpen;
  }

  @override
  EditorSource? sibling(String path) => SftpEditorSource(
        service: _service,
        path: path,
        hostLabel: hostLabel,
        host: host,
        onSaved: onSaved,
        reconnectWith: reconnectWith,
      );
}

/// A file in one of the file manager's panes ([PaneFileSource]): this
/// computer's, or a host's (where the pane's own SFTP is used for what only
/// SFTP can tell).
class PaneEditorSource extends EditorSource {
  PaneEditorSource({
    required this.files,
    required this.path,
    required this.hostLabel,
    required this.fileName,
    EditorHost? host,
    this.onSaved,
    this.isLocal = false,
  }) : host = host ?? (isLocal ? const EditorHost.thisComputer() : EditorHost.unknown());

  /// A file at [path] in a pane browsing [pane] through [files]: this
  /// computer's where the pane is, else its host's, named and told apart as
  /// an SFTP host is ([hostOfSession], so its tab names the host and its
  /// draft is that host's, a team host's in the team's database). An FTPS
  /// host's file is read and saved through [files], the FTPS session's own,
  /// in memory; it has no Save as root ([access] says nothing without SFTP).
  factory PaneEditorSource.ofPane({
    required SftpPaneSource pane,
    required PaneFileSource files,
    required String path,
    required String fileName,
    required String thisComputer,
    required EditorHost Function(String sessionId) hostOfSession,
    void Function()? onSaved,
  }) {
    final sessionId = switch (pane) {
      RemotePaneSource(:final sessionId) => sessionId,
      FtpsPaneSource(:final sessionId) => sessionId,
      _ => null,
    };
    if (sessionId == null) {
      return PaneEditorSource(
        files: files,
        path: path,
        hostLabel: thisComputer,
        fileName: fileName,
        onSaved: onSaved,
        isLocal: true,
      );
    }
    return PaneEditorSource(
      files: files,
      path: path,
      hostLabel: pane.hostName,
      host: hostOfSession(sessionId),
      fileName: fileName,
      onSaved: onSaved,
    );
  }

  final PaneFileSource files;

  @override
  final String path;

  /// The host's label, or this computer's name for a local pane.
  @override
  final String? hostLabel;

  @override
  final String fileName;

  @override
  final EditorHost host;

  final void Function()? onSaved;

  /// Whether it is this computer's.
  final bool isLocal;

  SftpService? get _sftp => files is RemotePaneFileSource ? (files as RemotePaneFileSource).service : null;

  @override
  Future<Uint8List> read() => files.readBytes(path, maxBytes: kMaxInlineEditBytes);

  @override
  Future<void> write(Uint8List bytes) async {
    await files.writeBytes(path, bytes);
    onSaved?.call();
  }

  @override
  Future<FileVersion?> version() async {
    final entry = await files.stat(path);
    String? hash;
    final sftp = _sftp;
    if (sftp != null) {
      hash = await sftp.sha256Remote(path);
    } else if (isLocal && entry != null && entry.size <= kMaxInlineEditBytes) {
      try {
        hash = sha256Of(await files.readBytes(path, maxBytes: kMaxInlineEditBytes));
      } catch (_) {
        hash = null;
      }
    }
    if (entry == null && hash == null) return null;
    return FileVersion(modified: entry?.modifiedAt, size: entry?.size, sha256: hash);
  }

  @override
  Future<FileAccess?> access() async {
    final a = await _sftp?.fileAccess(path);
    if (a == null) return null;
    return FileAccess(owner: a.owner, mode: a.mode, writable: a.writable, canSudo: a.sudo);
  }

  @override
  Future<void> writeAsRoot(Uint8List bytes, String password) async {
    final sftp = _sftp;
    if (sftp == null) throw UnsupportedError('writeAsRoot');
    await sftp.writeFileAsRoot(path, bytes, password);
    onSaved?.call();
  }

  @override
  bool get isConnected => _sftp?.isOpen ?? true;

  @override
  EditorSource? sibling(String path) {
    final slash = path.lastIndexOf(RegExp(r'[/\\]'));
    return PaneEditorSource(
      files: files,
      path: path,
      hostLabel: hostLabel,
      fileName: slash < 0 ? path : path.substring(slash + 1),
      host: host,
      onSaved: onSaved,
      isLocal: isLocal,
    );
  }
}

/// A file whose text comes and goes through callbacks: a window of its own,
/// whose main window holds the connection and writes the bytes, and the
/// router's editor.
class TextEditorSource extends EditorSource {
  TextEditorSource({
    required this.fileName,
    required this.initialText,
    this.path = '',
    this.hostLabel,
    this.onSave,
    this.onReload,
    this.fetchModified,
    this.originalModified,
  });

  @override
  final String fileName;

  @override
  final String path;

  @override
  final String? hostLabel;

  final String initialText;
  Future<void> Function(String content)? onSave;
  Future<String?> Function()? onReload;
  Future<DateTime?> Function()? fetchModified;
  final DateTime? originalModified;

  /// Its text comes and goes through callbacks, so the editor cannot name
  /// its host: one of its own, so it never shares a tab with another file
  /// (it keeps no draft either).
  @override
  final EditorHost host = EditorHost.unknown();

  @override
  bool get movesText => true;

  @override
  bool get canSave => onSave != null;

  @override
  bool get canReload => onReload != null;

  @override
  String get identity => '${host.key}\u0000${path.isEmpty ? fileName : path}';

  /// The file read again (the text it was opened with was handed to it).
  @override
  Future<String> readText() async {
    final text = await onReload?.call();
    if (text == null) throw StateError('Nothing was read');
    return text;
  }

  @override
  Future<void> writeText(String text) async {
    final save = onSave;
    if (save == null) throw UnsupportedError('writeText');
    await save(text);
  }

  @override
  Future<FileVersion?> version() async {
    final fetch = fetchModified;
    if (fetch == null) return null;
    final at = await fetch();
    return at == null ? null : FileVersion(modified: at);
  }
}
