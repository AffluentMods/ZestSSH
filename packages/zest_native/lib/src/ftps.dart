// FTPS (3.4): the Dart side of rust/src/ftps. The Rust library speaks FTP over TLS (suppaftp with
// rustls); this file runs its blocking calls off the UI isolate, gives them types, and holds the
// certificate rule: a certificate is trusted when it is the one the person accepted (or a public
// authority signed it), and any other is asked about, like an SSH host key.
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// The native layer an [FtpsClient] talks to: the Rust library ([RustFtpsNative]), or a fake in
/// tests. Requests and answers are the JSON of rust/src/ftps/mod.rs.
abstract interface class FtpsNative {
  /// A new handle, not connected yet.
  int open();

  /// Runs [request] on [handle] off the UI isolate and returns its answer: `{"ok": ...}` or
  /// `{"error": {...}}`.
  Future<Map<String, Object?>> call(int handle, Map<String, Object?> request);

  /// Asks the transfer running on [handle] to stop. Returns at once.
  void cancel(int handle);

  /// Bytes the transfer running on [handle] has moved so far. Returns at once.
  int progress(int handle);

  /// Ends [handle] (QUIT, close_notify), off the UI isolate.
  Future<void> close(int handle);
}

/// [FtpsNative] over the Rust library. Each call runs on a short-lived isolate, since it blocks
/// for as long as the server takes.
class RustFtpsNative implements FtpsNative {
  const RustFtpsNative();

  @override
  int open() => zestFtpsOpenC();

  @override
  Future<Map<String, Object?>> call(int handle, Map<String, Object?> request) async {
    final text = jsonEncode(request);
    final answer = await Isolate.run(() => _callBlocking(handle, text));
    return (jsonDecode(answer) as Map).cast<String, Object?>();
  }

  static String _callBlocking(int handle, String request) {
    final req = request.toNativeUtf8();
    try {
      final out = zestFtpsCallC(handle, req);
      try {
        return out.toDartString();
      } finally {
        zestStringFreeC(out);
      }
    } finally {
      malloc.free(req);
    }
  }

  @override
  void cancel(int handle) => zestFtpsCancelC(handle);

  @override
  int progress(int handle) => zestFtpsProgressC(handle);

  @override
  Future<void> close(int handle) => Isolate.run(() => zestFtpsCloseC(handle));
}

/// What failed, as the Rust library says it.
enum FtpsErrorKind {
  /// The host name has no address.
  resolve,

  /// Nothing listens there, or a firewall turned the connection away.
  refused,

  /// No answer within the time limit (often a server's passive ports that cannot be reached).
  timeout,

  /// The connection broke, or could not be made.
  connection,

  /// The server refused AUTH TLS: it offers plain FTP only, which is never spoken. Nothing was
  /// sent after the refusal (no user name, no password).
  noTls,

  /// TLS failed for another reason than the certificate.
  tls,

  /// The server's certificate is not trusted: [FtpsException.certificate] is what it showed.
  certificate,

  /// The user name or the password was refused (530).
  login,

  /// The server refused a command: [FtpsException.code] is its reply code (550 for a file that
  /// is not there or may not be touched, for example).
  reply,

  /// The server's reply could not be read.
  protocol,

  /// A transfer is running on this connection already.
  busy,

  /// The transfer was cancelled.
  cancelled,

  /// A file on this device could not be read or written.
  local,

  /// The file is larger than allowed where it was asked for.
  tooLarge,

  /// The connection is closed.
  closed,

  /// The request was malformed (a bug in the app).
  request;

  static FtpsErrorKind of(String? s) => switch (s) {
    'resolve' => resolve,
    'refused' => refused,
    'timeout' => timeout,
    'connection' => connection,
    'no-tls' => noTls,
    'tls' => tls,
    'certificate' => certificate,
    'login' => login,
    'reply' => reply,
    'protocol' => protocol,
    'busy' => busy,
    'cancelled' => cancelled,
    'local' => local,
    'too-large' => tooLarge,
    'closed' => closed,
    _ => request,
  };
}

/// A server's TLS certificate.
class FtpsCertificate {
  const FtpsCertificate({required this.sha256, required this.byAuthority, required this.der});

  /// The SHA-256 of [der], 64 lower-case hexadecimal digits.
  final String sha256;

  /// Whether a public authority (Mozilla's roots) signed it for the host asked for.
  final bool byAuthority;

  /// The certificate itself.
  final Uint8List der;

  /// The fingerprint as server tools print it (`openssl x509 -fingerprint -sha256`): pairs of
  /// upper-case hexadecimal digits with colons between them.
  String get fingerprint => colonHex(sha256);

  static String colonHex(String hex) {
    final up = hex.toUpperCase();
    final pairs = <String>[for (var i = 0; i + 1 < up.length; i += 2) up.substring(i, i + 2)];
    return pairs.join(':');
  }

  static FtpsCertificate? fromJson(Object? json) {
    if (json is! Map) return null;
    final sha = json['sha256'];
    final der = json['der'];
    if (sha is! String || der is! String) return null;
    return FtpsCertificate(sha256: sha, byAuthority: json['byAuthority'] == true, der: _unhex(der));
  }

  static Uint8List _unhex(String hex) {
    final out = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }
}

/// A call that failed.
class FtpsException implements Exception {
  const FtpsException(this.kind, this.message, {this.code, this.certificate});

  final FtpsErrorKind kind;

  /// What the library or the server said, in English (for the report; screens say it in the
  /// person's language from [kind] and [code]).
  final String message;

  /// The server's reply code, for [FtpsErrorKind.reply] and [FtpsErrorKind.login].
  final int? code;

  /// The certificate shown, for [FtpsErrorKind.certificate].
  final FtpsCertificate? certificate;

  /// Whether the server said the file or folder is not there (or may not be touched: FTP says
  /// both with 550).
  bool get notThere => kind == FtpsErrorKind.reply && code == 550;

  /// The type's name, for the log (thrown types are named, never printed whole).
  String get typeName => 'FtpsException';

  static FtpsException fromJson(Map<String, Object?> error) => FtpsException(
    FtpsErrorKind.of(error['kind'] as String?),
    (error['message'] as String?) ?? '',
    code: (error['code'] as num?)?.toInt(),
    certificate: FtpsCertificate.fromJson(error['certificate']),
  );

  @override
  String toString() => 'FtpsException(${kind.name}${code == null ? '' : ' $code'}): $message';
}

/// A file or folder on the server.
class FtpsEntry {
  const FtpsEntry({
    required this.name,
    required this.isDirectory,
    this.isSymlink = false,
    this.size = 0,
    this.modified,
    this.mode,
    this.linkTarget,
  });

  final String name;
  final bool isDirectory;
  final bool isSymlink;
  final int size;
  final DateTime? modified;

  /// The Unix permission bits, where the server said them.
  final int? mode;
  final String? linkTarget;

  static FtpsEntry fromJson(Map json) {
    final mtime = (json['mtime'] as num?)?.toInt();
    return FtpsEntry(
      name: json['name'] as String,
      isDirectory: json['dir'] == true,
      isSymlink: json['link'] == true,
      size: (json['size'] as num?)?.toInt() ?? 0,
      modified: mtime == null ? null : DateTime.fromMillisecondsSinceEpoch(mtime * 1000, isUtc: true),
      mode: (json['mode'] as num?)?.toInt(),
      linkTarget: json['target'] as String?,
    );
  }
}

/// What the server said it can do (FEAT).
class FtpsFeatures {
  const FtpsFeatures({this.mlst = false, this.epsv = false, this.rest = false, this.utf8 = false, this.hash = false});

  final bool mlst;
  final bool epsv;
  final bool rest;
  final bool utf8;

  /// It can say a file's SHA-256 (`HASH`, or `XSHA256`), which verifies a transfer.
  final bool hash;

  static FtpsFeatures fromJson(Object? json) {
    if (json is! Map) return const FtpsFeatures();
    return FtpsFeatures(
      mlst: json['mlst'] == true,
      epsv: json['epsv'] == true,
      rest: json['rest'] == true,
      utf8: json['utf8'] == true,
      hash: json['hash'] == true,
    );
  }
}

/// Where and how to connect.
class FtpsConnectOptions {
  const FtpsConnectOptions({
    required this.host,
    required this.port,
    required this.username,
    required this.password,
    this.implicitTls = false,
    this.timeout = const Duration(seconds: 20),
  });

  final String host;
  final int port;

  /// TLS from the first byte (port 990), rather than AUTH TLS after the greeting (port 21).
  final bool implicitTls;
  final String username;
  final String password;

  /// For connecting, and for each wait on the server after that.
  final Duration timeout;

  /// The default port: 990 for implicit TLS, else 21.
  static int defaultPort({required bool implicitTls}) => implicitTls ? 990 : 21;
}

/// What an app keeps of the certificates people accepted, and how it asks them about one.
abstract interface class FtpsTrust {
  /// The SHA-256 (hex) of the certificate accepted for [host]:[port], or null.
  Future<String?> pinnedFor(String host, int port);

  /// Asks whether to trust [presented], a certificate no authority vouches for. [previous] is
  /// the one accepted before for this host where there was one (a changed certificate, which is
  /// asked about as loudly as a changed host key). False: the connection stops.
  Future<bool> ask(FtpsCertificate presented, {required String host, required int port, String? previous});

  /// Keeps [cert] as the one for [host]:[port].
  Future<void> remember(String host, int port, FtpsCertificate cert);
}

/// One FTPS connection: its control connection, one command at a time.
class FtpsClient {
  FtpsClient._(this._native, this._handle, this.options, this.certificate, this.home, this.features);

  final FtpsNative _native;
  final int _handle;
  final FtpsConnectOptions options;

  /// The certificate this connection was made with.
  final FtpsCertificate certificate;

  /// The folder the server put the account in (PWD after logging in).
  final String home;
  final FtpsFeatures features;

  bool _closed = false;
  Future<void> _last = Future.value();

  bool get isClosed => _closed;

  /// Connects and logs in. The certificate must be the one of [pinnedSha256], or, where
  /// [allowAuthority], one a public authority signed for the host; any other fails with
  /// [FtpsErrorKind.certificate] before the user name is sent. A server without TLS fails with
  /// [FtpsErrorKind.noTls], also before.
  static Future<FtpsClient> connect(
    FtpsConnectOptions options, {
    String? pinnedSha256,
    bool allowAuthority = true,
    FtpsNative native = const RustFtpsNative(),
  }) async {
    final handle = native.open();
    final Map<String, Object?> answer;
    try {
      answer = await native.call(handle, {
        'op': 'connect',
        'host': options.host,
        'port': options.port,
        'implicit': options.implicitTls,
        'user': options.username,
        'password': options.password,
        'timeoutMs': options.timeout.inMilliseconds,
        'pinned': pinnedSha256,
        'allowAuthority': allowAuthority,
      });
    } catch (_) {
      await native.close(handle);
      rethrow;
    }
    final error = answer['error'];
    if (error is Map) {
      await native.close(handle);
      throw FtpsException.fromJson(error.cast<String, Object?>());
    }
    final ok = (answer['ok'] as Map).cast<String, Object?>();
    final cert = FtpsCertificate.fromJson(ok['certificate']);
    if (cert == null) {
      await native.close(handle);
      throw const FtpsException(FtpsErrorKind.tls, 'no certificate was checked');
    }
    return FtpsClient._(
      native,
      handle,
      options,
      cert,
      (ok['home'] as String?) ?? '/',
      FtpsFeatures.fromJson(ok['features']),
    );
  }

  /// TLS with the server and the check of its certificate, and nothing after (QUIT): no user
  /// name, no password (the host editor's TLS test). The certificate it accepted, by [pinnedSha256]
  /// or, where [allowAuthority], an authority's; any other fails with
  /// [FtpsErrorKind.certificate], the certificate in it.
  static Future<FtpsCertificate> probeTls(
    FtpsConnectOptions options, {
    String? pinnedSha256,
    bool allowAuthority = true,
    FtpsNative native = const RustFtpsNative(),
  }) async {
    final handle = native.open();
    try {
      final answer = await native.call(handle, {
        'op': 'connect',
        'login': false,
        'host': options.host,
        'port': options.port,
        'implicit': options.implicitTls,
        'user': '',
        'password': '',
        'timeoutMs': options.timeout.inMilliseconds,
        'pinned': pinnedSha256,
        'allowAuthority': allowAuthority,
      });
      final error = answer['error'];
      if (error is Map) throw FtpsException.fromJson(error.cast<String, Object?>());
      final ok = (answer['ok'] as Map).cast<String, Object?>();
      final cert = FtpsCertificate.fromJson(ok['certificate']);
      if (cert == null) throw const FtpsException(FtpsErrorKind.tls, 'no certificate was checked');
      return cert;
    } finally {
      await native.close(handle);
    }
  }

  /// [connect] with [trust]'s rule: the certificate accepted before for the host, or one a
  /// public authority signed (kept as the host's from then on, so a certificate without one
  /// later is asked about as a change); any other is asked about, and on a yes kept, and the
  /// connection made again with exactly that one.
  static Future<FtpsClient> connectTrusting(
    FtpsConnectOptions options,
    FtpsTrust trust, {
    FtpsNative native = const RustFtpsNative(),
  }) async {
    final pinned = await trust.pinnedFor(options.host, options.port);
    try {
      final client = await connect(options, pinnedSha256: pinned, native: native);
      if (client.certificate.sha256 != pinned) {
        await trust.remember(options.host, options.port, client.certificate);
      }
      return client;
    } on FtpsException catch (e) {
      final shown = e.certificate;
      if (e.kind != FtpsErrorKind.certificate || shown == null) rethrow;
      final yes = await trust.ask(shown, host: options.host, port: options.port, previous: pinned);
      if (!yes) throw FtpsException(FtpsErrorKind.certificate, 'not trusted', certificate: shown);
      // Kept once the person says yes, as an SSH host key is: before the user name is sent.
      await trust.remember(options.host, options.port, shown);
      return connect(options, pinnedSha256: shown.sha256, allowAuthority: false, native: native);
    }
  }

  /// Another connection to the same server, with this one's certificate and no other (for
  /// transfers beside browsing: FTP moves one file at a time on a connection).
  Future<FtpsClient> another() =>
      connect(options, pinnedSha256: certificate.sha256, allowAuthority: false, native: _native);

  /// Runs [request] after every call before it on this connection. [onStart] is told as it
  /// starts; where [skip] says so then, it does not start and fails as cancelled.
  Future<Object?> _run(Map<String, Object?> request, {void Function()? onStart, bool Function()? skip}) {
    if (_closed) return Future.error(const FtpsException(FtpsErrorKind.closed, 'closed'));
    final done = Completer<Object?>();
    final before = _last;
    _last = done.future.then<void>((_) {}, onError: (_) {});
    before.whenComplete(() async {
      try {
        if (skip?.call() ?? false) {
          done.completeError(const FtpsException(FtpsErrorKind.cancelled, 'cancelled'));
          return;
        }
        onStart?.call();
        final answer = await _native.call(_handle, request);
        final error = answer['error'];
        if (error is Map) {
          done.completeError(FtpsException.fromJson(error.cast<String, Object?>()));
        } else {
          done.complete(answer['ok']);
        }
      } catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }

  Future<String> pwd() async => (await _run({'op': 'pwd'})) as String;

  Future<void> noop() => _run({'op': 'noop'});

  Future<List<FtpsEntry>> list(String path) async {
    final out = await _run({'op': 'list', 'path': path});
    return [for (final e in (out as List?) ?? const []) FtpsEntry.fromJson(e as Map)];
  }

  /// The entry at [path], or null where there is none.
  Future<FtpsEntry?> stat(String path) async {
    final out = await _run({'op': 'stat', 'path': path});
    return out is Map ? FtpsEntry.fromJson(out) : null;
  }

  Future<void> mkdir(String path) => _run({'op': 'mkdir', 'path': path});

  Future<void> rmdir(String path) => _run({'op': 'rmdir', 'path': path});

  Future<void> delete(String path) => _run({'op': 'delete', 'path': path});

  Future<void> rename(String from, String to) => _run({'op': 'rename', 'from': from, 'to': to});

  Future<int> size(String path) async => ((await _run({'op': 'size', 'path': path})) as num).toInt();

  /// The file's SHA-256 as the server computes it, or null where the server cannot.
  Future<String?> sha256(String path) async => (await _run({'op': 'sha256', 'path': path})) as String?;

  /// Sets [path]'s Unix permission bits (SITE CHMOD; most Unix servers take it, Windows ones
  /// do not).
  Future<void> chmod(String path, int mode) => _run({'op': 'chmod', 'path': path, 'mode': mode});

  /// The whole of [path] in memory, never on this device's disk (a file the editor opens): no
  /// more than [maxBytes] of what comes, whatever the server says its size is.
  Future<Uint8List> read(String path, {int? maxBytes}) async {
    final out = await _run({'op': 'read', 'path': path, 'maxBytes': ?maxBytes});
    return base64Decode(((out as Map)['data'] as String?) ?? '');
  }

  /// Writes [bytes] to [path] from memory.
  Future<void> write(String path, Uint8List bytes) => _run({'op': 'write', 'path': path, 'data': base64Encode(bytes)});

  /// Downloads [remote] into [local]. With [offset] (what [local] holds already, from a
  /// download that broke off), the rest is appended. Returns the bytes received.
  Future<int> download(
    String remote,
    String local, {
    int offset = 0,
    int? maxBytes,
    void Function(int done)? onProgress,
    Future<void>? whenCancelled,
  }) => _transfer(
    {'op': 'get', 'remote': remote, 'local': local, 'offset': offset, 'maxBytes': ?maxBytes},
    offset,
    onProgress,
    whenCancelled,
  );

  /// Uploads [local] to [remote]. With [offset] (what [remote] holds already), the rest is
  /// sent from there on. Returns the bytes sent.
  Future<int> upload(
    String local,
    String remote, {
    int offset = 0,
    void Function(int done)? onProgress,
    Future<void>? whenCancelled,
  }) => _transfer({'op': 'put', 'local': local, 'remote': remote, 'offset': offset}, offset, onProgress, whenCancelled);

  Future<int> _transfer(
    Map<String, Object?> request,
    int offset,
    void Function(int done)? onProgress,
    Future<void>? whenCancelled,
  ) async {
    var running = false;
    var cancelled = false;
    whenCancelled?.then((_) {
      cancelled = true;
      if (running && !_closed) _native.cancel(_handle);
    });
    // Progress and cancel reach the native call while it runs: they wait for nothing. A cancel
    // is said again at each tick, in case it came just as the call started (which clears it).
    final ticker = Timer.periodic(const Duration(milliseconds: 150), (_) {
      if (!running) return;
      if (cancelled && !_closed) _native.cancel(_handle);
      onProgress?.call(offset + _native.progress(_handle));
    });
    try {
      final out = await _run(request, onStart: () => running = true, skip: () => cancelled);
      final bytes = ((out as Map?)?['bytes'] as num?)?.toInt() ?? 0;
      onProgress?.call(offset + bytes);
      return bytes;
    } finally {
      running = false;
      ticker.cancel();
    }
  }

  /// Says QUIT and closes. Safe to call twice.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _native.cancel(_handle);
    // After the calls already asked for (a cancelled transfer ends at its next block).
    try {
      await _last.timeout(options.timeout);
    } catch (_) {}
    await _native.close(_handle);
  }
}
