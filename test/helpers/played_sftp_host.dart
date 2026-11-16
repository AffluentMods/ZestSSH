import 'dart:async';
import 'dart:typed_data';

import 'package:zest_ssh_core/dartssh2.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/sftp/sftp_packet.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_channel.dart';
// ignore: implementation_imports
import 'package:zest_ssh_core/src/ssh_message.dart';

/// When a file or folder on a [PlayedSftpHost] was last changed where the
/// test says nothing of it, in seconds since 1970.
const playedTime = 1760000000;

/// A file on a [PlayedSftpHost].
class PlayedFile {
  PlayedFile(List<int> content,
      {this.permissions = 420, this.owner = 1000, this.group = 1000, this.modified = playedTime})
      : bytes = Uint8List.fromList(content);

  Uint8List bytes;

  /// When it was last changed, in seconds since 1970: [playedTime] where
  /// nothing is said.
  int modified;

  /// Who may read, write and run it: 644 where nothing is said.
  int permissions;
  int owner;
  int group;

  /// The size the host reports for it, where that is not how many bytes it
  /// holds: Linux reports none for a file that its kernel makes up as it is
  /// read, and a whole page for a few bytes under /sys.
  int? reportsSize;

  /// Takes [data] at [offset], and nothing of it from [atMost] on.
  void _write(int offset, Uint8List data, int? atMost) {
    var end = offset + data.length;
    if (atMost != null && end > atMost) end = atMost;
    if (end <= offset) return;
    if (end > bytes.length) bytes = Uint8List(end)..setRange(0, bytes.length, bytes);
    bytes.setRange(offset, end, data);
  }
}

/// An SFTP server played by a test, for the app's own file service: hand it
/// [client] as its connection. It keeps a few files in memory, notes every
/// request in the order it came, and answers them in that order, one after
/// the other, as OpenSSH's server does; a test can have it refuse a request,
/// or keep the answer to one waiting. What cannot be had from a real server
/// is what it is for: a close that fails, a write that fails half way, a
/// connection that drops. It answers what the tests that use it ask (lstat,
/// stat, realpath, a listing, open, read, write, fstat, fsetstat, close,
/// remove, rename, and the rename in one step), and says of anything else
/// that it does not have it.
///
/// A folder is there where a file lies in it or under it, where it is named
/// in [folders], and at the root.
class PlayedSftpHost {
  PlayedSftpHost({this.oneStepRename = true});

  /// Whether it can put a file in the place of another in one step
  /// (posix-rename@openssh.com).
  final bool oneStepRename;

  /// Its files, by path.
  final files = <String, PlayedFile>{};

  /// Folders with nothing in them.
  final folders = <String>{};

  /// When each folder named here was last changed, in seconds since 1970;
  /// any other, at [playedTime].
  final folderTimes = <String, int>{};

  /// The folder a session begins in.
  var home = '/';

  /// Whether [path] is a folder.
  bool isFolder(String path) =>
      path == '/' ||
      folders.contains(path) ||
      files.keys.followedBy(folders).any((held) => held.startsWith(path.endsWith('/') ? path : '$path/'));

  /// The names that lie straight in the folder [path], in the order of the alphabet.
  List<String> namesIn(String path) {
    final under = path.endsWith('/') ? path : '$path/';
    return {
      for (final held in files.keys.followedBy(folders))
        if (held.startsWith(under) && held.length > under.length) held.substring(under.length).split('/').first,
    }.toList()
      ..sort();
  }

  /// Folders in which no file may be made, removed or renamed.
  final sealedFolders = <String>{};

  /// Folders whose files the kernel of the host makes up (/proc): a file
  /// that is not there cannot be made, and the host says of it that there is
  /// no such file.
  final madeUpFolders = <String>{};

  /// Every request, in the order they came: 'lstat /srv/conf',
  /// 'open /srv/conf.zestpart', 'write /srv/conf.zestpart', 'close
  /// /srv/conf.zestpart', 'posix-rename /srv/conf.zestpart /srv/conf'.
  final asked = <String>[];

  /// How many bytes of a file it keeps, where that is fewer than it is sent:
  /// it says yes to every write all the same.
  int? keepsAtMost;

  /// Whether it reports a size for a file at all.
  var saysSizes = true;

  /// The status to refuse a request with, where the test gives one (the
  /// request as [asked] notes it). A request that is refused changes nothing.
  int? Function(String request)? refuses;

  /// What the answer to a request waits for, where the test gives something.
  /// Nothing that came after it is answered before it.
  Future<void>? Function(String request)? waitsFor;

  /// The connection to hand the app's file service.
  late final SSHClient client = connect().client;

  /// A connection of its own to this host: what a session has that was
  /// connected again.
  PlayedConnection connect() => PlayedConnection._(this);

  /// What [asked] holds from the first request that begins with [start].
  List<String> askedFrom(String start) => asked.sublist(asked.indexWhere((request) => request.startsWith(start)));
}

/// One connection to a [PlayedSftpHost], which can drop.
class PlayedConnection {
  PlayedConnection._(this._host);

  final PlayedSftpHost _host;
  final _sessions = <_Session>[];
  Object? _dropped;

  /// How many file sessions were asked of it, opened or not.
  var asked = 0;

  /// What it refuses a file session with, where the test gives something (a
  /// host with no SFTP).
  Object? refuses;

  /// The connection, for the app's file service.
  late final SSHClient client = _PlayedClient(this);

  /// The connection drops, with [error]: every session on it ends with
  /// that, and none can be opened on it any more.
  void drop(Object error) {
    _dropped = error;
    endSessions(error);
  }

  /// The host ends the file sessions on it, and the connection goes on:
  /// [error] where the connection said why, as it does not when the host
  /// only closes them.
  void endSessions([Object? error]) {
    for (final session in _sessions.toList()) {
      session._controller.destroy(error);
    }
    _sessions.clear();
  }
}

class _PlayedClient implements SSHClient {
  _PlayedClient(this._connection);

  final PlayedConnection _connection;

  @override
  Future<SftpClient> sftp() async {
    _connection.asked++;
    final dropped = _connection._dropped;
    if (dropped != null) throw dropped;
    final refused = _connection.refuses;
    if (refused != null) throw refused;
    final session = _Session(_connection._host);
    _connection._sessions.add(session);
    return session.client;
  }

  /// The played host's key and who is signed in to it: what a download's
  /// note names its server by.
  @override
  Uint8List? get verifiedHostKey => Uint8List.fromList(const [7, 7, 7, 7]);

  @override
  String get username => 'deploy';

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError('not played: ${invocation.memberName}');
}

/// One SFTP session on a [PlayedSftpHost].
class _Session {
  _Session(this._host) {
    _controller = SSHChannelController(
      localId: 1,
      localMaximumPacketSize: 1 << 20,
      localInitialWindowSize: 1 << 30,
      remoteId: 2,
      remoteMaximumPacketSize: 1 << 20,
      remoteInitialWindowSize: 1 << 30,
      sendMessage: _fromClient,
    );
    client = SftpClient(_controller.channel);
  }

  final PlayedSftpHost _host;
  late final SSHChannelController _controller;
  late final SftpClient client;

  /// What came from the client and is no whole packet yet.
  var _unread = Uint8List(0);

  /// The requests that are not answered yet: what is noted of each, its
  /// number, and what answers it.
  final _waiting = <(String, int, void Function())>[];
  var _answering = false;

  /// The folders that are being listed, by their handle, and whether what
  /// is in them was sent.
  final _listing = <int, (String, bool)>{};

  /// The files that are open, by their handle.
  final _open = <int, (String, PlayedFile)>{};
  var _handles = 0;

  void _fromClient(SSHMessage message) {
    if (message is! SSH_Message_Channel_Data) return;
    _unread = _unread.isEmpty ? message.data : (BytesBuilder()..add(_unread)..add(message.data)).takeBytes();
    while (_unread.length >= 4) {
      final length = ByteData.sublistView(_unread).getUint32(0);
      if (_unread.length < 4 + length) break;
      final packet = Uint8List.sublistView(_unread, 4, 4 + length);
      _unread = Uint8List.sublistView(_unread, 4 + length);
      _arrived(packet);
    }
  }

  void _arrived(Uint8List packet) {
    if (packet[0] == SftpInitPacket.packetType) {
      return _send(SftpVersionPacket(3, {if (_host.oneStepRename) 'posix-rename@openssh.com': '1'}));
    }
    final (note, id, answer) = _read(packet);
    _host.asked.add(note);
    _waiting.add((note, id, answer));
    unawaited(_answer());
  }

  Future<void> _answer() async {
    if (_answering) return;
    _answering = true;
    while (_waiting.isNotEmpty) {
      final (note, id, answer) = _waiting.removeAt(0);
      await _host.waitsFor?.call(note);
      final refusal = _host.refuses?.call(note);
      if (refusal == null) {
        answer();
      } else {
        _status(id, refusal);
      }
    }
    _answering = false;
  }

  (String, int, void Function()) _read(Uint8List packet) {
    switch (packet[0]) {
      case SftpLStatPacket.packetType:
        final request = SftpLStatPacket.decode(packet);
        return ('lstat ${request.path}', request.requestId, () => _attrsAt(request.requestId, request.path));
      case SftpStatPacket.packetType:
        final request = SftpStatPacket.decode(packet);
        return ('stat ${request.path}', request.requestId, () => _attrsAt(request.requestId, request.path));
      case SftpRealpathPacket.packetType:
        final request = SftpRealpathPacket.decode(packet);
        return ('realpath ${request.path}', request.requestId, () {
          final real = request.path.startsWith('/')
              ? request.path
              : request.path == '.' || request.path.isEmpty
                  ? _host.home
                  : '${_host.home == '/' ? '' : _host.home}/${request.path}';
          _send(SftpNamePacket(request.requestId, [SftpName(filename: real, longname: real, attr: SftpFileAttrs())]));
        });
      case SftpOpenDirPacket.packetType:
        final request = SftpOpenDirPacket.decode(packet);
        return ('opendir ${request.path}', request.requestId, () {
          if (!_host.isFolder(request.path)) return _status(request.requestId, SftpStatusCode.noSuchFile);
          final handle = _handles++;
          _listing[handle] = (request.path, false);
          _send(SftpHandlePacket(request.requestId, Uint8List.fromList([handle])));
        });
      case SftpReadDirPacket.packetType:
        final request = SftpReadDirPacket.decode(packet);
        final listed = _listing[request.handle.single];
        if (listed == null) {
          return ('readdir of a folder that is not open', request.requestId,
              () => _status(request.requestId, SftpStatusCode.failure));
        }
        return ('readdir ${listed.$1}', request.requestId, () {
          // All of it in one piece, and then its end.
          if (_listing[request.handle.single]!.$2) return _status(request.requestId, SftpStatusCode.eof);
          _listing[request.handle.single] = (listed.$1, true);
          final under = listed.$1.endsWith('/') ? listed.$1 : '${listed.$1}/';
          _send(SftpNamePacket(request.requestId, [
            for (final name in ['.', '..', ..._host.namesIn(listed.$1)])
              SftpName(
                filename: name,
                longname: name,
                attr: name.startsWith('.') && name.length <= 2 ? _folderAttrs : _attrs('$under$name')!,
              ),
          ]));
        });
      case SftpOpenPacket.packetType:
        final request = SftpOpenPacket.decode(packet);
        return ('open ${request.path}', request.requestId, () => _openFile(request));
      case SftpReadPacket.packetType:
        final request = SftpReadPacket.decode(packet);
        return _ofOpen('read', request.requestId, request.handle, (file) {
          if (request.offset >= file.bytes.length) return _status(request.requestId, SftpStatusCode.eof);
          final end = request.offset + request.length;
          _send(SftpDataPacket(
            request.requestId,
            Uint8List.sublistView(file.bytes, request.offset, end > file.bytes.length ? file.bytes.length : end),
          ));
        });
      case SftpWritePacket.packetType:
        final request = SftpWritePacket.decode(packet);
        return _ofOpen('write', request.requestId, request.handle, (file) {
          file._write(request.offset, request.data, _host.keepsAtMost);
          _status(request.requestId, SftpStatusCode.ok);
        });
      case SftpFStatPacket.packetType:
        final request = SftpFStatPacket.decode(packet);
        return _ofOpen('fstat', request.requestId, request.handle, (file) => _attrsOf(request.requestId, file));
      case SftpFSetStatPacket.packetType:
        final request = SftpFSetStatPacket.decode(packet);
        return _ofOpen('fsetstat', request.requestId, request.handle, (file) {
          final mode = request.attributes.mode;
          if (mode != null) file.permissions = mode.value & 511;
          _status(request.requestId, SftpStatusCode.ok);
        });
      case SftpClosePacket.packetType:
        final request = SftpClosePacket.decode(packet);
        final listed = _listing[request.handle.single];
        if (listed != null) {
          return ('close ${listed.$1}', request.requestId, () {
            _listing.remove(request.handle.single);
            _status(request.requestId, SftpStatusCode.ok);
          });
        }
        return _ofOpen('close', request.requestId, request.handle, (file) {
          _open.remove(request.handle.single);
          _status(request.requestId, SftpStatusCode.ok);
        });
      case SftpRemovePacket.packetType:
        final request = SftpRemovePacket.decode(packet);
        return ('remove ${request.filename}', request.requestId, () {
          if (!_host.files.containsKey(request.filename)) return _status(request.requestId, SftpStatusCode.noSuchFile);
          if (_sealed(request.filename)) return _status(request.requestId, SftpStatusCode.permissionDenied);
          _host.files.remove(request.filename);
          _status(request.requestId, SftpStatusCode.ok);
        });
      case SftpRenamePacket.packetType:
        final request = SftpRenamePacket.decode(packet);
        return (
          'rename ${request.oldPath} ${request.newPath}',
          request.requestId,
          // SFTP's own rename: refused for a name that is taken.
          () => _rename(request.requestId, request.oldPath, request.newPath, replacing: false),
        );
      case SftpExtendedPacket.packetType:
        final request = SftpExtendedPacket.decode(packet);
        final reader = SSHMessageReader(request.payload);
        final name = reader.readUtf8();
        if (name != 'posix-rename@openssh.com' || !_host.oneStepRename) break;
        final oldPath = reader.readUtf8();
        final newPath = reader.readUtf8();
        return (
          'posix-rename $oldPath $newPath',
          request.requestId,
          () => _rename(request.requestId, oldPath, newPath, replacing: true),
        );
    }
    final id = ByteData.sublistView(packet).getUint32(1);
    return ('request ${packet[0]}', id, () => _status(id, SftpStatusCode.opUnsupported));
  }

  /// A request of a file that is open: noted with the file's path, and
  /// refused where no file is open under [handle] (as when it was closed).
  (String, int, void Function()) _ofOpen(String what, int id, Uint8List handle, void Function(PlayedFile file) answer) {
    final opened = _open[handle.single];
    if (opened == null) return ('$what of a file that is not open', id, () => _status(id, SftpStatusCode.failure));
    return ('$what ${opened.$1}', id, () => answer(opened.$2));
  }

  bool _sealed(String path) => _host.sealedFolders.contains(path.substring(0, path.lastIndexOf('/')));

  bool _madeUp(String path) => _host.madeUpFolders.contains(path.substring(0, path.lastIndexOf('/')));

  void _openFile(SftpOpenPacket request) {
    final writes = request.flags & 2 != 0;
    final creates = request.flags & 8 != 0;
    final truncates = request.flags & 16 != 0;
    var file = _host.files[request.path];
    if (file == null) {
      if (!creates || _madeUp(request.path)) return _status(request.requestId, SftpStatusCode.noSuchFile);
      if (_sealed(request.path)) return _status(request.requestId, SftpStatusCode.permissionDenied);
      // A new file: with what it is asked to be made with, less what this
      // host gives no new file (writing by its group and by others).
      file = _host.files[request.path] = PlayedFile([], permissions: (request.attrs.mode?.value ?? 438) & 511 & ~18);
    } else if (writes && file.permissions & 128 == 0) {
      return _status(request.requestId, SftpStatusCode.permissionDenied);
    }
    if (truncates) file.bytes = Uint8List(0);
    final handle = _handles++;
    _open[handle] = (request.path, file);
    _send(SftpHandlePacket(request.requestId, Uint8List.fromList([handle])));
  }

  void _rename(int id, String oldPath, String newPath, {required bool replacing}) {
    final file = _host.files[oldPath];
    if (file == null) return _status(id, SftpStatusCode.noSuchFile);
    if (_sealed(oldPath) || _sealed(newPath)) return _status(id, SftpStatusCode.permissionDenied);
    if (!replacing && _host.files.containsKey(newPath)) return _status(id, SftpStatusCode.failure);
    _host.files.remove(oldPath);
    _host.files[newPath] = file;
    _status(id, SftpStatusCode.ok);
  }

  void _attrsOf(int id, PlayedFile? file) {
    if (file == null) return _status(id, SftpStatusCode.noSuchFile);
    _send(SftpAttrsPacket(id, _fileAttrs(file)));
  }

  /// What is at [path], a file or a folder, or that nothing is.
  void _attrsAt(int id, String path) {
    final attrs = _attrs(path);
    if (attrs == null) return _status(id, SftpStatusCode.noSuchFile);
    _send(SftpAttrsPacket(id, attrs));
  }

  SftpFileAttrs? _attrs(String path) {
    final file = _host.files[path];
    if (file != null) return _fileAttrs(file);
    return _host.isFolder(path) ? _folderAttrsAt(_host.folderTimes[path] ?? playedTime) : null;
  }

  SftpFileAttrs _fileAttrs(PlayedFile file) => SftpFileAttrs(
        size: _host.saysSizes ? file.reportsSize ?? file.bytes.length : null,
        userID: file.owner,
        groupID: file.group,
        mode: SftpFileMode.value(0x8000 | file.permissions),
        accessTime: file.modified,
        modifyTime: file.modified,
      );

  static final _folderAttrs = _folderAttrsAt(playedTime);

  static SftpFileAttrs _folderAttrsAt(int time) => SftpFileAttrs(
        size: 4096,
        userID: 1000,
        groupID: 1000,
        mode: const SftpFileMode.value(0x4000 | 493),
        accessTime: time,
        modifyTime: time,
      );

  void _status(int id, int code) => _send(SftpStatusPacket(requestId: id, code: code, message: _said[code] ?? 'Failure'));

  static const _said = {
    SftpStatusCode.ok: 'Success',
    SftpStatusCode.eof: 'End of file',
    SftpStatusCode.noSuchFile: 'No such file',
    SftpStatusCode.permissionDenied: 'Permission denied',
    SftpStatusCode.opUnsupported: 'Operation unsupported',
  };

  void _send(SftpPacket packet) {
    final payload = packet.encode();
    final writer = SSHMessageWriter()
      ..writeUint32(payload.length)
      ..writeBytes(payload);
    _controller.handleMessage(SSH_Message_Channel_Data(recipientChannel: 1, data: writer.takeBytes()));
  }
}
