// A remote screen's session (4.0) where the app keeps its sessions:
// a ShellService, so a screen tab is counted, connected, dropped, connected
// again and ended as a terminal is. It holds the connection to its carrier
// SSH host (signed in with no terminal and no shell: connectForScreen), the
// channel to the VNC server through it, and the ScreenSession running over
// that channel. Nothing listens on a local port. A screen with no carrier is
// reached over a socket of its own, and takes VeNCrypt with a certificate only.
//
// It has no terminal: its stdout says nothing and what is written to it goes
// nowhere. The screen's view talks to [session].
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zest_native/screen.dart';
import 'package:zest_ssh_core/dartssh2.dart' show SSHChannelOpenError;
import 'package:zestssh/features/screens/model/screen_options.dart';
import 'package:zestssh/features/screens/model/screen_view_size.dart';
import 'package:zestssh/features/screens/proxmox/proxmox_console.dart';
import 'package:zestssh/features/screens/session/rdp_account.dart';
import 'package:zestssh/features/screens/session/screen_errors.dart';
import 'package:zestssh/features/screens/session/screen_gateway_route.dart';
import 'package:zestssh/features/screens/session/screen_target.dart';
import 'package:zestssh/features/screens/xprogram/x_program_run.dart';
import 'package:zestssh/services/ssh_service.dart';

/// The VNC encodings asked of the server for a picture [quality], in order:
/// null for Auto (the engine's own list: Tight with JPEG quality 7). High
/// asks for Tight with no JPEG quality level, which servers send lossless,
/// and light compression; Low for JPEG quality 3 and more compression, for a
/// slow link. The engine adds Raw, continuous updates and fences itself.
List<String>? screenEncodingsFor(ScreenQuality quality) {
  const pseudo = ['Cursor', 'ExtendedDesktopSize', 'DesktopSize', 'LastRect', 'QemuExtendedKeyEvent', 'ExtendedClipboard'];
  const kinds = ['Tight', 'ZRLE', 'Hextile', 'Zlib', 'RRE', 'CopyRect'];
  return switch (quality) {
    ScreenQuality.auto => null,
    ScreenQuality.high => const [...kinds, 'CompressionLevel1', ...pseudo],
    ScreenQuality.low => const [...kinds, 'JpegQuality3', 'CompressionLevel6', ...pseudo],
  };
}

/// How a password is asked for: [again] when the one given was refused.
/// Throws to stop (the person cancelled).
typedef ScreenPasswordAsker = Future<String> Function({required bool again});

/// How an RDP account is asked for where the host has no key to say who signs
/// in: its user name (with its domain where it has one, as typed) and its
/// password; [again] when the ones given were refused. Throws to stop.
typedef ScreenAccountAsker = Future<({String username, String password})> Function({required bool again});

/// The path of [target]'s socket on [carrier] once its leading `~` is put as
/// the home folder of the account the carrier signs in as (read once); null
/// for a target that is no socket, or whose path has no `~`.
Future<String?> screenSocketPathOn(SshService carrier, ScreenTarget target) async {
  if (target is! UnixSocketTarget || !target.needsHome) return null;
  final home = await carrier.runOnce(r'printf %s "$HOME"');
  return target.expandedWith(home);
}

/// The channel to [target] through [carrier], signed in already: SSH's
/// direct-tcpip to an address and port, or direct-streamlocal to a socket
/// ([socketPath], expanded, where it had a `~`). Nothing listens on a local
/// port. A channel the carrier refuses is said as a screen's failure
/// ([ScreenFailure.ofChannel]).
Future<ScreenChannel> openScreenChannelVia(SshService carrier, ScreenTarget target,
    {String? socketPath, String? carrierLabel}) async {
  switch (target) {
    case TcpTarget():
      try {
        final ch = await carrier.client.forwardLocal(target.host, target.port);
        return ScreenChannel(ch.stream, ch.sink, connectionDone: carrier.client.done);
      } on SSHChannelOpenError catch (e) {
        throw ScreenFailure.ofChannel(e, unix: false, carrier: carrierLabel, address: target.describe());
      }
    case UnixSocketTarget():
      final path = socketPath ?? target.path;
      try {
        final ch = await carrier.client.forwardLocalUnix(path);
        return ScreenChannel(ch.stream, ch.sink, connectionDone: carrier.client.done);
      } on SSHChannelOpenError catch (e) {
        throw ScreenFailure.ofChannel(e, unix: true, carrier: carrierLabel, address: path);
      }
    case XProgramTarget():
      // The socket the host script named once its Xvnc was up.
      if (socketPath == null) throw ArgumentError('an X program\'s socket is known only once it started');
      try {
        final ch = await carrier.client.forwardLocalUnix(socketPath);
        return ScreenChannel(ch.stream, ch.sink, connectionDone: carrier.client.done);
      } on SSHChannelOpenError catch (e) {
        throw ScreenFailure.ofChannel(e, unix: true, carrier: carrierLabel, address: socketPath);
      }
    case DirectTlsTarget() || ProxmoxConsoleTarget():
      throw ArgumentError('a screen reached directly has no carrier');
  }
}

/// The socket to a screen reached directly (VeNCrypt only).
Future<ScreenChannel> openDirectScreenSocket(String host, int port, Duration timeout) async {
  final socket = await Socket.connect(host, port, timeout: timeout);
  socket.setOption(SocketOption.tcpNoDelay, true);
  return ScreenChannel(socket, socket);
}

/// An X program's screen takes no certificate: its VNC server is the private
/// Xvnc on a socket in a 0700 folder, with security None, inside SSH. A
/// certificate question there would be a server that is not the one started.
class XProgramScreenTrust implements ScreenTrust {
  const XProgramScreenTrust();

  @override
  Future<String?> pinned() async => null;

  @override
  Future<bool> ask(ScreenCertificate presented, {String? previous}) async => false;

  @override
  Future<void> remember(ScreenCertificate cert) async {}
}

class ScreenShellService implements ShellService, ShellEndReason, ShellExit {
  ScreenShellService({
    required this.target,
    required this.trust,
    this.carrier,
    this.carrierLabel,
    this.protocol = ScreenProtocol.vnc,
    this.username,
    this.domain,
    this.password,
    this.askPassword,
    this.askAccount,
    this.onPasswordAccepted,
    this.onTlsConnected,
    this.shared = true,
    this.options = ScreenOptions.defaults,
    this.inTeam = false,
    this.connectionId,
    this.native,
    this.onLog,
    this.openDirect,
    this.openConsole,
    this.gateway,
    this.gatewayTrust,
    this.connectTimeout = const Duration(seconds: 15),
    this.handshakeTimeout = kScreenHandshakeTimeout,
  }) : assert(carrier != null || target is DirectTlsTarget || (target is ProxmoxConsoleTarget && openConsole != null),
            'a screen through a carrier needs its connection, a console its opening');

  /// How many times a password the VNC server refused is asked for again in
  /// one try (then ZS-1803: no loop that would lock the person out).
  static const maxPasswordAsks = 3;

  /// How long the server has, once the connection is open, to finish
  /// connecting (ZS-1828).
  final Duration handshakeTimeout;

  final ScreenTarget target;

  /// VNC, or RDP (4.0): which engine the bytes are for.
  final ScreenProtocol protocol;

  /// RDP: the Windows domain of [username], where the key's user name was
  /// written with one (rdpAccount).
  final String? domain;

  /// The certificate rule of this screen's route ([ScreenTrust]).
  final ScreenTrust trust;

  /// The connection to the carrier SSH host, not signed in yet; null for a
  /// screen reached directly.
  final SshService? carrier;

  /// What the carrier is called (said in what fails at it).
  final String? carrierLabel;

  /// For Apple's sign-in and VeNCrypt's X509Plain; the VNC password, from the
  /// host's key. Neither is ever logged. Apple's sign-in is used only where
  /// the host's options chose it ([ScreenOptions.auth]); otherwise it is
  /// taken out of what the server offers ([VncSecurityOfferFilter]), so the
  /// user name and password go only into VeNCrypt's pinned TLS (X509Plain).
  final String? username;
  final String? password;

  /// Asks the person for the password where the server wants one and none
  /// was saved, or the one given was refused; null where nobody can be
  /// asked (a password saved with the host's key, a run with nobody there).
  final ScreenPasswordAsker? askPassword;

  /// RDP with NLA and no [username]: asks the person for the account, name
  /// and password, before the first try and again where the server refused
  /// it. Null where the host's key says who signs in.
  final ScreenAccountAsker? askAccount;

  /// Called once connected with a password that was asked for (where it may
  /// be saved with the host now that the server took it).
  final Future<void> Function()? onPasswordAccepted;

  /// Connected over VeNCrypt TLS with the certificate whose SHA-256 this is.
  final void Function(String sha256)? onTlsConnected;

  /// Other viewers of the screen stay connected.
  final bool shared;

  /// The host's saved options: the tab applies its scaling and view only,
  /// and its picture quality is asked of the server here ([screenEncodingsFor]).
  final ScreenOptions options;

  /// Whether the host is a team's (its clipboard is off by default there,
  /// and may be locked off: screen_clipboard.dart).
  final bool inTeam;

  /// The saved host, for what this device remembers of it (its clipboard
  /// choice); null for a screen with no saved host.
  final String? connectionId;

  /// The engine (a fake in tests); the Rust one where null.
  final ScreenNative? native;
  final ConnectionLogCallback? onLog;

  /// Opens the socket to a screen reached directly (tests).
  final Future<ScreenChannel> Function(String host, int port)? openDirect;

  /// A Proxmox guest's console ([ProxmoxConsoleTarget]): asks the API for
  /// the console and opens its websocket, once a try (a ticket is for one
  /// connection). Throws [ProxmoxConsoleError].
  final Future<ProxmoxConsole> Function()? openConsole;

  ProxmoxConsole? _console;

  /// RDP: the RD Gateway the session goes through (4.0): the socket
  /// is then the gateway's, and the PC is asked of it by [target]'s address
  /// and port. Never with a [carrier].
  final ScreenGatewayRoute? gateway;

  /// The certificate rule of the gateway's own address, apart from the PC's
  /// ([trust]).
  final ScreenTrust? gatewayTrust;
  final Duration connectTimeout;

  ScreenSession? _session;
  XProgramRun? _xRun;
  StreamSubscription<ScreenEvent>? _events;
  ScreenClosed? _closedWith;
  ScreenConnected? _connected;
  bool _isConnected = false;
  bool _exitedCleanly = false;
  Future<void>? _carrierClosing;
  final _state = StreamController<bool>.broadcast();
  final _endReason = Completer<String?>();

  /// The screen's session once connected: what its view draws and sends input to.
  ScreenSession? get session => _session;

  /// The server's facts from the handshake.
  ScreenConnected? get connectedInfo => _connected;

  /// How the session ended, once it has.
  ScreenClosed? get closedWith => _closedWith;

  /// Whether the screen is reached through an SSH host.
  bool get viaCarrier => carrier != null;

  /// Whether this device's system is a phone's or a tablet's (Android, iOS),
  /// whatever layout the app shows on it: the remote's sound is off there by
  /// default ([ScreenOptions.soundOn]). A test's word where set.
  @visibleForTesting
  static bool? debugOnPhoneSystem;
  static bool get _onPhoneSystem => debugOnPhoneSystem ?? (Platform.isAndroid || Platform.isIOS);

  /// Whether a session of this host asks its RDP server for the remote's
  /// sound: the server sends none otherwise. A view offers the session's
  /// sound switch by this, so that a large tablet in the computer's layout
  /// does not show the switch on for a session that asked for no sound.
  bool get soundAsked => protocol == ScreenProtocol.rdp && options.soundOn(phone: _onPhoneSystem);

  /// RDP with Network Level Authentication, once connected: the account the
  /// server let in (DOMAIN\user, or the name alone). Null for VNC, without
  /// NLA (the server's own sign-in screen then knows, not the app) and
  /// until it connected.
  String? get signedInAs => _signedInAs;
  String? _signedInAs;

  /// The account of the host's key, before anything is dialled: what a
  /// team's log of the session names in its header. Null where the key
  /// names none (it is asked for, and said once it signed in).
  String? get keyAccount => protocol == ScreenProtocol.rdp && options.nla && username != null
      ? rdpAccountText(username!, domain)
      : null;

  @override
  Future<void> connect() async {
    final carrier = this.carrier;
    try {
      final rdp = protocol == ScreenProtocol.rdp;
      final gateway = rdp ? this.gateway : null;
      if (gateway != null && (carrier != null || target is! DirectTlsTarget)) {
        // Not in this version: a gateway reached through an SSH host.
        throw _withPlace(const ScreenFailure(ScreenFailureKind.rdpGateway, 'an RD Gateway with an SSH host to reach it through',
            hint: 'gateway_unavailable'));
      }
      if (carrier != null) {
        await carrier.connectForScreen();
      } else if (gateway != null) {
        onLog?.call('screen: Connecting to ${target.describe()} through the RD Gateway ${gateway.describe()} '
            '(its TLS, and the PC\'s own TLS inside it; '
            '${gateway.sameSignIn ? 'the gateway signs in with the PC\'s account' : 'the gateway signs in with a key of its own'})');
      } else if (rdp) {
        onLog?.call('screen: Connecting directly to ${target.describe()} (RDP, always inside TLS)');
      } else if (target is ProxmoxConsoleTarget) {
        onLog?.call('screen: Opening ${target.describe()} (VNC inside the Proxmox API\'s TLS)');
      } else {
        onLog?.call('screen: Connecting directly to ${target.describe()}: only VeNCrypt with a certificate is taken');
      }
      final String? socketPath;
      final t = target;
      if (t is XProgramTarget) {
        // The host script starts the private Xvnc and the program, and says
        // where its socket is (4.0).
        final run = _xRun = await XProgramRun.start(carrier!.client,
            program: t.program, width: t.width, height: t.height, host: carrierLabel, onLog: onLog);
        socketPath = run.socketPath;
      } else {
        socketPath = carrier == null ? null : await screenSocketPathOn(carrier, target);
      }
      onLog?.call('screen: Opening the screen at ${target.describe()}');
      var password = this.password;
      // A console's password is the API's, for this connection only: asked
      // for with the console itself, before the engine starts.
      final console = openConsole;
      if (target is ProxmoxConsoleTarget && console != null) {
        try {
          final opened = _console = await console();
          password = opened.password;
          onLog?.call('screen: The console of a ${opened.kind == 'lxc' ? 'container' : 'VM'} is open');
        } on ProxmoxConsoleError catch (e) {
          throw _withPlace(ScreenFailure(ScreenFailureKind.proxmoxConsole, e.detail, hint: e.failure.name));
        }
      }
      var username = this.username;
      var domain = this.domain;
      var asked = 0;
      // RDP with NLA and nobody to sign in as: the account is asked for, its
      // name as typed (DOMAIN\user, user@domain or the name alone). A gateway
      // that signs in with the PC's account needs it too, NLA or not.
      final gatewaySignsInAsPc = gateway?.sameSignIn ?? false;
      final account = rdp && (options.nla || gatewaySignsInAsPc) && username == null ? askAccount : null;
      Future<void> askForAccount({required bool again}) async {
        final answer = await account!(again: again);
        final typed = rdpAccount(answer.username);
        username = typed.username;
        domain = typed.domain;
        password = answer.password;
        asked++;
      }

      if (account != null) {
        onLog?.call('screen: The account is asked for (the host has no key; Network Level Authentication signs in first)');
        await askForAccount(again: false);
      }
      // RDP with NLA signs in before the server shows anything, so a password
      // that is not saved is asked for before the first try (VNC's server says
      // when it wants one). Without NLA none is asked for or sent: the server
      // shows its own sign-in screen.
      if (rdp && (options.nla || gatewaySignsInAsPc) && password == null && askPassword != null) {
        onLog?.call(options.nla
            ? 'screen: The password is asked for (Network Level Authentication signs in first)'
            : 'screen: The password is asked for (the RD Gateway signs in with it)');
        password = await askPassword!(again: false);
        asked++;
      }
      // The name TLS and CredSSP use for the server: its address as it is reached.
      final serverName = switch (target) {
        TcpTarget(:final host) => host,
        DirectTlsTarget(:final host) => host,
        _ => null,
      };
      // The gateway's sign-in: the PC's account as it now is (asked for, where
      // it was), or its key's.
      ScreenGatewayOptions? gatewayOptions() {
        final g = gateway;
        final t = target;
        if (g == null || t is! DirectTlsTarget) return null;
        return ScreenGatewayOptions(
          host: g.host,
          port: g.port,
          target: t.host,
          targetPort: t.port,
          username: g.sameSignIn ? username : g.username,
          password: g.sameSignIn ? password : g.password,
          domain: g.sameSignIn ? domain : g.domain,
        );
      }

      final followed = ScreenViewSize.lastFollowed;
      final follows = rdp && options.scaling == ScreenScaling.remoteResize && followed != null;
      // Followed: in the screen's own pixels, its text made as much larger,
      // so the picture is sharp on a screen scaled above 100%.
      final ratio = follows ? ScreenViewSize.lastFollowedRatio : 1.0;
      final startScale = follows ? ScreenViewSize.scaleOn(options.textScale, ratio) : options.textScale;
      final startAt = follows
          ? (() {
              final d = ScreenViewSize.displaysOf(1, ScreenViewSize.pixelsOf(followed, ratio)).first;
              return (d.width, d.height);
            })()
          : null;
      // Several displays (4.0): each the size a view last had here, or the size a
      // session starts at. A phone asks for as many as a computer, under its own ceiling of pixels.
      final displayCount = rdp ? options.displayCount : 1;
      final displays = displayCount > 1
          ? ScreenViewSize.displaysOf(
              displayCount,
              follows ? ScreenViewSize.pixelsOf(followed, ratio) : ScreenViewSize.startSize,
              scale: startScale,
              maxDesktopPixels: ScreenOptions.maxDesktopPixelsOn(phone: Platform.isAndroid || Platform.isIOS),
            )
          : null;
      while (true) {
        try {
          _session = await ScreenSession.connectTrusting(
            rdp
                ? ScreenConnectOptions.rdp(
                    username: username,
                    domain: domain,
                    password: password,
                    serverName: serverName,
                    nla: options.nla,
                    // The clipboard's channel only where the clipboard can ever be on for
                    // this host: a team's host that is locked gets none, so its server has
                    // nothing to ask through. Shared once a view says so.
                    clipboard: options.clipboardTogglable(inTeam: inTeam),
                    // "Resize the remote": the size a screen's view last had here, so the
                    // remote starts at it and is not resized a moment after it connects.
                    width: startAt?.$1,
                    height: startAt?.$2,
                    displays: displays,
                    // How large the remote draws its text: said where the host's person
                    // chose a size, or where the remote follows a view on a screen scaled
                    // above 100% (drawn in its own pixels, the text as much larger).
                    scale: startScale == 0 ? null : startScale,
                    // Asked for only by a host whose person turned it on: it changes the
                    // client version the connection says.
                    relativeMouse: options.relativeMouse,
                    // The remote's sound where this host plays it here: the server
                    // sends none otherwise. Silent until a view of it is seen
                    // (ScreenController.soundAllowed): not under a cover, not locked.
                    sound: soundAsked,
                    soundOn: false,
                    graphics: rdpGraphicsName(options.graphics.name),
                    // H.264 where the host's Graphics says Modern (and the device has a
                    // decoder: the engine offers none otherwise).
                    h264: rdpH264Name(options.graphics.name),
                    gateway: gatewayOptions(),
                  )
                : ScreenConnectOptions.vnc(
                    username: username,
                    password: password,
                    // Plain VNC never goes over a network: a screen reached
                    // directly takes VeNCrypt only. A Proxmox console is the one
                    // exception, by name: its VNC is inside the API's TLS.
                    requireTls: !target.viaCarrier && target is! ProxmoxConsoleTarget,
                    shared: shared,
                    encodings: screenEncodingsFor(options.quality),
                    allowAppleSignIn: options.auth == ScreenAuth.apple,
                  ),
            openChannel: () => _openChannel(socketPath),
            trust: trust,
            gatewayTrust: gatewayTrust,
            native: native,
            handshakeTimeout: handshakeTimeout,
            // Closed by a Disconnect that comes while it is still connecting.
            onSession: (s) {
              _opening = s;
              if (_disconnected) s.close();
            },
          );
          break;
        } on ScreenConnectException catch (e) {
          final ask = askPassword;
          // A gateway that signs in with the PC's account and refused it: the
          // account is asked for again, as the PC's own refusal is.
          final gatewayRefusedPc = gatewaySignsInAsPc && e.closed.detail == 'gateway_sign_in';
          final mayAsk = !rdp || options.nla || gatewayRefusedPc;
          // Refused for a reason the server named (locked, turned off, its
          // password run out, not allowed): another password cannot help.
          final named = rdp && e.closed.detail != null && !gatewayRefusedPc;
          if (e.reason == ScreenCloseReason.auth && account != null && !named && asked < maxPasswordAsks) {
            onLog?.call('screen: The server refused the sign-in');
            await askForAccount(again: true);
            continue;
          }
          if (e.reason == ScreenCloseReason.auth &&
              ask != null &&
              mayAsk &&
              !named &&
              asked < maxPasswordAsks &&
              target is! ProxmoxConsoleTarget) {
            onLog?.call(gatewayRefusedPc
                ? 'screen: The RD Gateway refused the sign-in'
                : rdp
                ? 'screen: The server refused the sign-in'
                : password == null
                    ? 'screen: The VNC server asks for its password'
                    : 'screen: The VNC server refused the password');
            password = await ask(again: password != null);
            asked++;
            continue;
          }
          throw _withPlace(ScreenFailure.ofClosed(e.closed, rdp: rdp));
        }
      }
      final session = _session!;
      final info = _connected = await session.connected;
      // Who the server let in, for a team's log of the session: the account
      // of the host's key, or the one typed when it was asked for.
      if (rdp && options.nla && username != null) _signedInAs = rdpAccountText(username!, domain);
      final tls = info.tls;
      final sha = tls?['cert_sha256'];
      onLog?.call('screen: Connected (${rdp ? (options.nla ? 'RDP, NLA' : 'RDP, without NLA') : info.security.isEmpty ? 'VNC' : info.security}'
          '${tls == null ? '' : ', TLS ${tls['protocol'] ?? ''}, certificate pinned'}), '
          '${info.width}x${info.height}${carrier == null ? '' : ', through SSH'}'
          '${gateway == null ? '' : ', through the RD Gateway ${gateway.describe()}'}');
      if (sha is String) onTlsConnected?.call(sha);
      if (asked > 0) await onPasswordAccepted?.call();
      _events = session.events.listen((e) {
        if (e is ScreenClosed) _ended(e);
      });
      // Ended between its handshake and here.
      final closed = session.closedWith;
      if (closed != null) {
        _ended(closed);
        return;
      }
      _isConnected = true;
      _state.add(true);
    } catch (e) {
      _session?.close();
      // An X program that ended as its screen opened: said as that, not as
      // the socket or the server that went with it.
      final ended = e is ScreenFailure && e.kind == ScreenFailureKind.xProgramEnded ? null : await _programEnded();
      await _closeCarrier();
      if (ended != null) throw ended;
      // An RDP host's failure is said as an RDP host's (the channel's own
      // failures come from the SSH side and do not know the kind).
      if (e is ScreenFailure && protocol == ScreenProtocol.rdp && !e.rdp) throw e.asRdp();
      rethrow;
    }
  }

  /// An X program that has ended (its exit line waited for a moment), as
  /// [ScreenFailureKind.xProgramEnded]; null for any other screen, or a
  /// program that runs.
  Future<ScreenFailure?> _programEnded() async {
    final run = _xRun;
    final t = target;
    if (run == null || t is! XProgramTarget) return null;
    final status = run.exitStatus ?? await run.exited.timeout(_exitLineWait, onTimeout: () => null);
    if (status == null) return null;
    return ScreenFailure(ScreenFailureKind.xProgramEnded, 'exit status $status',
        carrier: carrierLabel, hint: t.name, exitStatus: status);
  }

  /// How long an X program's exit line is waited for once its screen ended.
  static const _exitLineWait = Duration(seconds: 1);

  /// [f] with where it happened. (What else it holds stays: an RDP session's
  /// reason was dropped here, so a server that refused a connection for a
  /// reason it named was said to have "ended the session", no more.)
  ScreenFailure _withPlace(ScreenFailure f) => ScreenFailure(f.kind, f.detail,
      carrier: carrierLabel,
      address: f.address ?? target.describe(),
      hint: f.hint,
      exitStatus: f.exitStatus,
      rdp: f.rdp || protocol == ScreenProtocol.rdp);

  Future<ScreenChannel> _openChannel(String? socketPath) async {
    final t = target;
    if (t is ProxmoxConsoleTarget) {
      final console = _console;
      // Once: a second try would need a new ticket.
      if (console == null) throw StateError('the console is opened once a try');
      _console = null;
      return console.channel;
    }
    if (t is DirectTlsTarget) {
      // Through an RD Gateway, the socket is the gateway's; the PC is asked of
      // it inside.
      final g = protocol == ScreenProtocol.rdp ? gateway : null;
      final (host, port) = g == null ? (t.host, t.port) : (g.host, g.port);
      final open = openDirect;
      if (open != null) return open(host, port);
      return openDirectScreenSocket(host, port, connectTimeout);
    }
    return openScreenChannelVia(carrier!, t, socketPath: socketPath, carrierLabel: carrierLabel);
  }

  void _ended(ScreenClosed closed) {
    if (_closedWith != null) return;
    _closedWith = closed;
    unawaited(_events?.cancel());
    // An X program's screen ends because the program did (the host script
    // then stops the Xvnc): its exit status comes on the script's channel a
    // moment before or after, and is what the tab says ([exitCode]).
    final run = _xRun;
    if (run != null && run.exitStatus == null && closed.reason == ScreenCloseReason.serverClosed) {
      unawaited(run.exited.timeout(_exitLineWait, onTimeout: () => null).then((_) => _endedNow(closed)));
      return;
    }
    _endedNow(closed);
  }

  void _endedNow(ScreenClosed closed) {
    final run = _xRun;
    if (run != null && run.exitStatus != null) {
      onLog?.call('xprogram: ${(target as XProgramTarget).name} ended (exit status ${run.exitStatus})');
    }
    // A screen whose server ended it is not connected to again by itself
    // (its person chooses Reconnect); a dropped one is, as a terminal is.
    _exitedCleanly = closed.reason == ScreenCloseReason.serverClosed;
    if (closed.reason != ScreenCloseReason.local) onLog?.call('screen: Ended (${closed.reason.name}: ${closed.message})');
    final carrier = this.carrier;
    if (!_endReason.isCompleted) {
      _endReason.complete(closed.reason.isDrop
          ? (carrier == null ? Future.value(closed.message) : carrier.endReason)
          : null);
    }
    if (_isConnected) {
      _isConnected = false;
      _state.add(false);
    }
    unawaited(_closeCarrier());
  }

  /// Closes the carrier once; every caller waits for that one closing (the
  /// session's own end starts it before [disconnect] does, and [disconnect]
  /// returns only once the carrier is closed).
  Future<void> _closeCarrier() => _carrierClosing ??= _closeCarrierOnce();

  Future<void> _closeCarrierOnce() async {
    // An X program's script first: its input ends, and it stops the program
    // and the Xvnc and removes their folder on the host.
    _xRun?.close();
    try {
      await carrier?.disconnect();
    } catch (_) {
      // Closing what is gone already.
    }
  }

  /// The session of the try under way, before it has connected: a
  /// Disconnect closes it too.
  ScreenSession? _opening;
  bool _disconnected = false;

  @override
  Future<void> disconnect() async {
    _disconnected = true;
    _opening?.close();
    _session?.close();
    await _closeCarrier();
  }

  @override
  Future<String?> get endReason => _endReason.future;

  /// An X program's exit status, once it ended by itself; null for any
  /// other screen.
  @override
  int? get exitCode => _xRun?.exitStatus;

  @override
  String? get exitSignal => null;

  /// The X program running on the host, once it started (4.0).
  XProgramRun? get xProgram => _xRun;

  @override
  Stream<Uint8List> get stdout => const Stream<Uint8List>.empty();

  @override
  Stream<Uint8List> get stderr => const Stream<Uint8List>.empty();

  /// A screen has no shell: what is typed goes to its [session].
  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _isConnected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => _exitedCleanly;

  /// Encrypted by SSH where it goes through a carrier (a direct screen is
  /// encrypted by its own TLS, which is no SSH).
  @override
  bool get isEncryptedSsh => carrier != null;
}
