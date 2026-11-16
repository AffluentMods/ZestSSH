// Mosh, built in (4.0): a MoshNative for tests, with no Rust behind it. It records what a session
// asks of the client, and plays the client's side: events as rust/src/mosh/mod.rs sends them,
// delivered asynchronously as a NativeCallable.listener delivers them.
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'mosh_native.dart';

/// One session the fake opened.
class FakeMoshSession {
  FakeMoshSession(this.handle, this.request, this._onEvent);
  final int handle;

  /// The start request, decoded (it holds the key: tests only).
  final Map<String, Object?> request;
  final MoshNativeEvent _onEvent;

  final typed = BytesBuilder(copy: true);
  final resizes = <(int, int)>[];
  bool closed = false;
  bool released = false;
  bool _closedSent = false;

  void emit(int kind, {int a = 0, Uint8List? data}) {
    if (_closedSent) throw StateError('the client sends nothing after CLOSED');
    if (kind == MoshEventKind.closed) _closedSent = true;
    scheduleMicrotask(() => _onEvent(kind, a, data));
  }

  void emitJson(int kind, Map<String, Object?> json) => emit(kind, data: utf8.encode(jsonEncode(json)));

  /// The server answered.
  void connect({String address = '192.0.2.10:60001'}) => emitJson(MoshEventKind.connected, {'address': address});

  /// Terminal output.
  void output(String text) => emit(MoshEventKind.hostBytes, data: Uint8List.fromList(utf8.encode(text)));

  /// The once-a-second status.
  void status({int? lastHeardMs, int srttMs = 40}) =>
      emitJson(MoshEventKind.status, {'last_heard_ms': lastHeardMs, 'srtt_ms': srttMs});

  /// The session ends, as the client reports it.
  void closeWith(String reason, String message) =>
      emitJson(MoshEventKind.closed, {'reason': reason, 'message': message});
}

/// A [MoshNative] whose sessions a test drives. [onOpen] runs for each new session (to answer at
/// once, for example); [refuse] makes [open] return 0.
class FakeMoshNative implements MoshNative {
  FakeMoshNative({this.onOpen, this.refuse = false, this.closeAnswers = true});

  final void Function(FakeMoshSession session)? onOpen;
  final bool refuse;

  /// Whether [close] answers with CLOSED (local), as the client does.
  final bool closeAnswers;

  final sessions = <FakeMoshSession>[];
  var _next = 1;

  FakeMoshSession get last => sessions.last;

  @override
  int open(String requestJson, MoshNativeEvent onEvent) {
    if (refuse) return 0;
    final s = FakeMoshSession(_next++, jsonDecode(requestJson) as Map<String, Object?>, onEvent);
    sessions.add(s);
    onOpen?.call(s);
    return s.handle;
  }

  FakeMoshSession _of(int handle) => sessions.firstWhere((s) => s.handle == handle);

  @override
  void keys(int handle, Uint8List data) => _of(handle).typed.add(data);

  @override
  void resize(int handle, int cols, int rows) => _of(handle).resizes.add((cols, rows));

  @override
  void close(int handle) {
    final s = _of(handle);
    if (s.closed) return;
    s.closed = true;
    if (closeAnswers && !s._closedSent) s.closeWith('local', 'closed');
  }

  @override
  void release(int handle) => _of(handle).released = true;
}
