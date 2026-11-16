import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_counts.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/session_log_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/logger.dart';

/// Where a session's tmux integration is.
enum TmuxHostStage {
  /// tmux mode is off: the session shows its normal terminal.
  idle,

  /// Listing the sessions on the host over a plain exec.
  listing,

  /// Sessions exist: the user is choosing one (or naming a new one).
  picking,

  /// A control-mode channel is open (or has just ended: see
  /// [TmuxController.exited]).
  attached,

  /// The probe found no tmux binary.
  notInstalled,

  /// Something failed; [TmuxSessionHost.failure] has the text.
  failed,

  /// The SSH session has no in-process client (worker isolate, local shell).
  noLiveSession,
}

/// The tmux integration for ONE SSH session, independent of any widget: it
/// lists the host's tmux sessions, opens the `tmux -CC` channel on the
/// session's existing connection and owns the [TmuxController]. The desktop
/// pane renders it inside the session's tab; the mobile route renders it
/// full screen. Both observe the same object, so tmux mode survives tab
/// switches, splits and screen rotations.
class TmuxSessionHost extends ChangeNotifier {
  TmuxSessionHost(this._ref, this.sessionId, {this.keepAlive, this.listSessionsForTest});

  final Ref _ref;
  final String sessionId;

  /// Pins the owning provider while tmux mode is on, so the object outlives
  /// the widgets that happen to be showing it.
  final KeepAliveLink Function()? keepAlive;

  /// Stands in for `tmux list-sessions` on the host (its exit code and what
  /// it printed), in tests.
  @visibleForTesting
  final Future<(int?, String)> Function()? listSessionsForTest;

  /// The controller whose end was counted ([_recount]).
  TmuxController? _endCounted;

  TmuxHostStage _stage = TmuxHostStage.idle;
  String _failure = '';
  List<TmuxSessionInfo> _listed = const [];
  TmuxController? _controller;
  SSHSession? _channel;
  StreamSubscription<Uint8List>? _sub;
  KeepAliveLink? _link;
  bool _disposed = false;
  int _generation = 0;

  /// In-band mode: the controller rides the session's own shell channel and
  /// is owned by the watcher, not by a channel of ours.
  bool _inband = false;
  VoidCallback? _inbandForceExit;
  Timer? _detachWatchdog;

  TmuxHostStage get stage => _stage;
  String get failure => _failure;
  List<TmuxSessionInfo> get listed => _listed;
  TmuxController? get controller => _controller;

  /// tmux mode is on for this session (any stage but idle).
  bool get active => _stage != TmuxHostStage.idle;

  /// Attached and live: the workspace should have the keyboard.
  bool get live =>
      _stage == TmuxHostStage.attached && _controller?.exited == false;

  /// Control mode was started by typing `tmux -CC` in the terminal itself.
  bool get inband => _inband;

  /// The watcher saw the marker on the session's own stream: show the
  /// workspace for its controller. [forceExit] abandons control mode when
  /// tmux stops answering.
  void attachInband(TmuxController c, {required VoidCallback forceExit}) {
    if (_disposed) return;
    _generation++;
    _teardownChannel();
    _inband = true;
    _inbandForceExit = forceExit;
    _controller = c;
    _wirePaneHooks(c);
    c.addListener(_onControllerChanged);
    _set(TmuxHostStage.attached);
  }

  /// Pane hooks that belong to the session rather than the workspace: OSC 52
  /// from a pane goes to the same handler as a plain session's (so the
  /// clipboard setting and its refusals apply inside tmux too), and decoded
  /// pane text feeds the session log when one is open.
  void _wirePaneHooks(TmuxController c) {
    c.onPrivateOSC = (code, args) => _ref
        .read(activeSessionsProvider.notifier)
        .handlePrivateOsc(sessionId, code, args);
    c.onPaneText = (paneId, text) {
      SessionLogService.appendPane(sessionId, paneId, text);
      // Its team's log too (3.0).
      TeamSessionLogs.append(sessionId, text);
    };
    // What is typed into a pane is typed into the session: a tab that
    // broadcasts types it into its other terminals.
    c.onPaneTyped = (_, data, typed) =>
        _ref.read(activeSessionsProvider.notifier).typedInTmuxPane(sessionId, data, typed);
  }

  /// The watcher saw the terminator (or was forced): back to the shell.
  void inbandEnded() {
    if (!_inband) return;
    _detachWatchdog?.cancel();
    _detachWatchdog = null;
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerChanged);
    _inband = false;
    _inbandForceExit = null;
    _listed = const [];
    _set(TmuxHostStage.idle);
  }

  SSHClient? get _client {
    final session = _ref.read(activeSessionsProvider)[sessionId]?.session;
    final shell = session?.shell;
    return shell is SshService ? shell.client : null;
  }

  String? get _connectionId =>
      _ref.read(activeSessionsProvider)[sessionId]?.connectionId;

  /// Remember how many tmux sessions this host has, for the Hosts-panel and
  /// tab badges.
  void _publishCount(int count) {
    final id = _connectionId;
    if (id == null || id.startsWith('quick_')) return;
    _ref.read(tmuxSessionCountsProvider.notifier).set(id, count);
  }

  void _set(TmuxHostStage stage, {String failure = ''}) {
    if (_disposed) return;
    _stage = stage;
    _failure = failure;
    if (active) {
      _link ??= keepAlive?.call();
    } else {
      _link?.close();
      _link = null;
    }
    notifyListeners();
  }

  /// Turn tmux mode on: probe the host, then pick or create a session.
  Future<void> begin() => _list(autoCreate: true);

  /// Re-list the host's sessions while the picker is up (after a kill). No
  /// "listing" flash and no auto-created session: an empty list stays an
  /// empty picker.
  Future<void> refreshList() => _list(autoCreate: false);

  /// Kill a listed session from the picker. The picker is not attached to
  /// anything, so a plain exec does it; then the list is refreshed. False
  /// when tmux refused (already gone, permission).
  /// What the last kill that failed said (tmux's words, or the error), for
  /// what is said about it; null after one that worked.
  String? lastKillFailure;

  Future<bool> killListedSession(String sessionInfoId) async {
    final client = _client;
    final command = TmuxController.killSessionCommand(sessionInfoId);
    if (client == null || command == null) return false;
    var ok = false;
    lastKillFailure = null;
    try {
      final run = await client.execute(command);
      final out = StringBuffer();
      // tmux says what went wrong on stderr.
      final err = StringBuffer();
      final errRead = run.stderr.forEach((chunk) {
        if (err.length < 4096) err.write(utf8.decode(chunk, allowMalformed: true));
      });
      await run.stdout
          .forEach((chunk) {
            if (out.length < 4096) {
              out.write(utf8.decode(chunk, allowMalformed: true));
            }
          })
          .timeout(const Duration(seconds: 10));
      await run.done.timeout(const Duration(seconds: 5), onTimeout: () {});
      await errRead.timeout(const Duration(seconds: 5), onTimeout: () {});
      ok = (run.exitCode ?? 0) == 0;
      if (!ok) {
        lastKillFailure = [err.toString().trim(), out.toString().trim()].where((s) => s.isNotEmpty).join('\n');
        AppLogger.warning(
            'tmux: kill-session $sessionInfoId failed: ${out.toString().trim()}');
      }
    } catch (e, st) {
      lastKillFailure = '$e';
      AppLogger.error('tmux: kill-session failed', e, st);
    }
    if (!_disposed) await refreshList();
    return ok;
  }

  Future<void> _list({required bool autoCreate}) async {
    final gen = ++_generation;
    final client = _client;
    if (client == null) {
      _set(TmuxHostStage.noLiveSession);
      return;
    }
    if (autoCreate || _stage != TmuxHostStage.picking) {
      _set(TmuxHostStage.listing);
    }
    try {
      final (code, text) = await _listedOn(client);
      if (gen != _generation || _disposed) return;
      // Only a missing binary means "not installed". tmux itself answers
      // "no server running" or "error connecting to ... (No such file or
      // directory)" when it is installed but idle; those fall through to an
      // empty list and a fresh session.
      if (code == 127 || RegExp(r'tmux: (command )?not found').hasMatch(text)) {
        _set(TmuxHostStage.notInstalled);
        return;
      }
      final sessions = _sessionsIn(code, text);
      _listed = sessions;
      _publishCount(sessions.length);
      if (sessions.isEmpty && autoCreate) {
        await createSession('main');
      } else {
        _set(TmuxHostStage.picking);
      }
    } catch (e, st) {
      AppLogger.error('tmux: listing sessions failed', e, st);
      if (gen == _generation) _set(TmuxHostStage.failed, failure: '$e');
    }
  }

  /// `tmux list-sessions` on the host: its exit code and what it printed.
  Future<(int?, String)> _listedOn(SSHClient client) async {
    final probe = await client.execute(TmuxController.listSessionsCommand());
    final out = StringBuffer();
    await probe.stdout
        .forEach((chunk) {
          if (out.length < 64 * 1024) {
            out.write(utf8.decode(chunk, allowMalformed: true));
          }
        })
        .timeout(const Duration(seconds: 20));
    await probe.done.timeout(const Duration(seconds: 5), onTimeout: () {});
    return (probe.exitCode, out.toString());
  }

  /// The sessions a `list-sessions` answer names (none where tmux said it
  /// has no server, or failed).
  static List<TmuxSessionInfo> _sessionsIn(int? code, String text) => [
        if (code == 0 || code == null)
          for (final line in const LineSplitter().convert(text)) ?parseSessionLine(line),
      ];

  /// tmux ended in this tab (its session killed, its last window closed, a
  /// detach): the host is asked again how many sessions it has, so the
  /// tab's count names none that is gone (after the last window was closed
  /// the tab still showed one).
  Future<void> _recount() async {
    final stand = listSessionsForTest;
    final client = _client;
    if (stand == null && client == null) return;
    try {
      final (code, text) = stand != null ? await stand() : await _listedOn(client!);
      if (_disposed) return;
      _publishCount(_sessionsIn(code, text).length);
    } catch (e) {
      AppLogger.debug('tmux: counting the sessions after tmux ended failed: $e');
    }
  }

  /// One `list-sessions -F sessionFormat` line.
  static TmuxSessionInfo? parseSessionLine(String line) {
    final p = line.split(' ');
    if (p.length < 6 || !TmuxController.isSessionId(p[0])) return null;
    DateTime? ts(String s) {
      final n = int.tryParse(s);
      return n == null || n <= 0
          ? null
          : DateTime.fromMillisecondsSinceEpoch(n * 1000);
    }

    return TmuxSessionInfo(
      id: p[0],
      name: TmuxController.shownName(p.sublist(5).join(' ')),
      windows: int.tryParse(p[1]) ?? 0,
      attached: int.tryParse(p[2]) ?? 0,
      activity: ts(p[3]),
      created: ts(p[4]),
    );
  }

  /// Attach to a listed session.
  Future<void> attach(String sessionInfoId) =>
      _launch(TmuxController.launchCommand(attachTarget: sessionInfoId));

  /// Create (or attach to) a named session.
  Future<void> createSession(String name) => _launch(
      TmuxController.launchCommand(sessionName: name.trim().isEmpty ? 'main' : name.trim()));

  Future<void> _launch(String command) async {
    final gen = ++_generation;
    final client = _client;
    if (client == null) {
      _set(TmuxHostStage.noLiveSession);
      return;
    }
    _teardownChannel();
    try {
      // -CC needs a tty (it puts the client's tty in raw mode); the size is
      // irrelevant for a control client, which is sized by refresh-client.
      final channel = await client.execute(
        command,
        pty: const SSHPtyConfig(type: 'xterm-256color', width: 80, height: 24),
      );
      if (gen != _generation || _disposed) {
        channel.close();
        return;
      }
      final controller = TmuxController(
        sendBytes: (bytes) => channel.write(Uint8List.fromList(bytes)),
        scrollback: _scrollback(),
        platform: _detectPlatform(),
        log: AppLogger.debug,
      );
      _wirePaneHooks(controller);
      controller.addListener(_onControllerChanged);
      _sub = channel.stdout.listen(
        controller.onData,
        onError: (Object e) => AppLogger.error('tmux stdout error', e),
      );
      channel.done.then((_) {
        if (_disposed || _controller != controller) return;
        controller.onTransportClosed();
        if (!controller.controlStarted) {
          final text = controller.preControlText.trim();
          _set(TmuxHostStage.failed,
              failure: text.isEmpty ? 'exit ${channel.exitCode ?? '?'}' : text);
        } else {
          notifyListeners();
        }
      });
      _channel = channel;
      _controller = controller;
      _set(TmuxHostStage.attached);
    } catch (e, st) {
      AppLogger.error('Failed to start tmux control mode', e, st);
      if (gen == _generation) _set(TmuxHostStage.failed, failure: '$e');
    }
  }

  int _scrollback() {
    final n = _ref.read(scrollbackLinesProvider);
    if (n <= 0) return 20000;
    return n.clamp(500, 20000);
  }

  static TerminalTargetPlatform _detectPlatform() {
    if (Platform.isAndroid) return TerminalTargetPlatform.android;
    if (Platform.isMacOS) return TerminalTargetPlatform.macos;
    if (Platform.isWindows) return TerminalTargetPlatform.windows;
    if (Platform.isLinux) return TerminalTargetPlatform.linux;
    return TerminalTargetPlatform.unknown;
  }

  void _onControllerChanged() {
    if (_disposed) return;
    final c = _controller;
    if (c != null && c.phase == TmuxPhase.ready) {
      _publishCount(c.sessions.length);
    }
    if (c != null && c.exited && !identical(_endCounted, c)) {
      _endCounted = c;
      unawaited(_recount());
    }
    notifyListeners();
  }

  /// Back to the session list (after an exit or a failure).
  Future<void> restart() async {
    _teardownChannel();
    await begin();
  }

  /// Turn tmux mode off: detach (the tmux session keeps running on the
  /// host) and show the normal terminal again.
  void stop() {
    _generation++;
    if (_inband) {
      // Ask tmux to detach; the terminator on the stream ends the mode.
      // If tmux never answers (the inner host died), force the stream back
      // to passthrough so the user is never stuck.
      final c = _controller;
      if (c != null && !c.exited) {
        c.detach();
        _detachWatchdog?.cancel();
        _detachWatchdog = Timer(const Duration(seconds: 3), () {
          if (_inband) _inbandForceExit?.call();
        });
      } else {
        _inbandForceExit?.call();
      }
      return;
    }
    _teardownChannel();
    _listed = const [];
    _set(TmuxHostStage.idle);
  }

  void _teardownChannel() {
    if (_inband) {
      // The watcher owns an in-band controller; just stop looking at it.
      _controller?.removeListener(_onControllerChanged);
      _controller = null;
      _inband = false;
      _inbandForceExit = null;
      _detachWatchdog?.cancel();
      _detachWatchdog = null;
      return;
    }
    final c = _controller;
    _controller = null;
    c?.removeListener(_onControllerChanged);
    c?.detach();
    _sub?.cancel();
    _sub = null;
    _channel?.close();
    _channel = null;
    c?.dispose();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _teardownChannel();
    _link?.close();
    super.dispose();
  }
}

/// One host per SSH session. Auto-disposed once nothing shows it AND tmux
/// mode is off; pinned by the host itself while tmux mode is on.
final tmuxHostProvider =
    ChangeNotifierProvider.autoDispose.family<TmuxSessionHost, String>(
  (ref, sessionId) {
    final host = TmuxSessionHost(ref, sessionId, keepAlive: ref.keepAlive);
    // The session layer knows which sessions show tmux: typing that reaches
    // one from a broadcast goes to its tmux pane in front.
    final sessions = ref.read(activeSessionsProvider.notifier);
    sessions.tmuxHostCreated(host);
    ref.onDispose(() => sessions.tmuxHostDisposed(host));
    // The SSH session going away (closed tab, dropped connection) ends tmux
    // mode: the tab shows its normal state again, which on a drop is the
    // reconnect UI. The tmux session itself keeps running on the host.
    ref.listen<Map<String, SessionState>>(activeSessionsProvider, (_, next) {
      final state = next[sessionId];
      if (state == null ||
          (state.status != SessionStatus.connected &&
              state.status != SessionStatus.connecting)) {
        host.stop();
      }
    });
    return host;
  },
);
