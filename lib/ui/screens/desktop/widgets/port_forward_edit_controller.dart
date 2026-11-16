import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';

// ══════════════════════════════════════════════════════════════════
// Enums + value types
// ══════════════════════════════════════════════════════════════════

/// The two editors of the 1.7 Port Forwarding detail pane.
enum PfEditorMode { simple, advanced }

/// Forward direction. The [name] of each value ('local' / 'remote' / 'dynamic')
/// is exactly the string persisted in [PortForwardRule.type], so it round-trips
/// through the database without a separate mapping table.
enum PfForwardType { local, remote, dynamic }

/// The SSH flags every forward runs with. `-N` (open no remote shell) and `-f`
/// (background) describe exactly what the tunnel does, so they are a committed
/// DEFAULT VALUE (rendered bright in the field), never a dim placeholder hint.
const String kPfDefaultFlags = '-N -f';

/// What Advanced can hold that Simple cannot show: the page names each in its
/// question before a switch to Simple.
enum PfSimpleCannotShow { sourceHost, destinationHost, flags }

/// The editor's unsaved state, as [PortForwardEditController.snapshot] takes it
/// and [PortForwardEditController.restore] puts it back. Held in memory only
/// (never on disk), while the page is away.
@immutable
class PfEditDraft {
  const PfEditDraft({
    required this.original,
    required this.connectionId,
    required this.mode,
    required this.simpleStep,
    required this.name,
    required this.autoStart,
    required this.reconnect,
    required this.exitOnFailure,
    required this.gatewayPorts,
    required this.forwardType,
    required this.simpleBindPort,
    required this.simpleRemotePort,
    required this.advancedType,
    required this.advSourceHost,
    required this.advSourcePort,
    required this.advDestHost,
    required this.advDestPort,
    required this.advFlags,
  });

  /// The rule being edited; null for a new rule.
  final PortForwardRule? original;
  final String? connectionId;
  final PfEditorMode mode;
  final int simpleStep;
  final String name;
  final bool autoStart;
  final bool reconnect;
  final bool exitOnFailure;
  final bool gatewayPorts;
  final PfForwardType forwardType;
  final String simpleBindPort;
  final String simpleRemotePort;
  final PfForwardType advancedType;
  final String advSourceHost;
  final String advSourcePort;
  final String advDestHost;
  final String advDestPort;
  final String advFlags;
}

// ══════════════════════════════════════════════════════════════════
// Live command preview (fix #4) - pure + testable
// ══════════════════════════════════════════════════════════════════

/// One run of characters in the previewed `ssh` command. A [isPlaceholder]
/// segment (`<port>` / `<user@host>`) stands in for an empty field and is
/// rendered DIM in place - the preview never prints a literal `?` or the bare
/// word `host`.
class PfCommandSegment {
  const PfCommandSegment(this.text, {this.isPlaceholder = false});

  final String text;
  final bool isPlaceholder;
}

/// Loopback bind addresses that ssh implies by default, so they are omitted
/// from the `[bind_address:]` prefix of a `-L`/`-R`/`-D` spec.
bool _isLoopbackBind(String addr) {
  final a = addr.trim().toLowerCase();
  return a.isEmpty || a == '127.0.0.1' || a == 'localhost' || a == '::1';
}

/// Build the previewed `ssh` command as a list of [PfCommandSegment]s, so an
/// empty field dims IN PLACE rather than printing a literal `?`. The mapping is
/// faithful to what the app actually does (forwards run through
/// `zest_ssh_core`, not a shelled `ssh`):
///
///  * local (`-L`):  binds `bindPort` locally, tunnels to `remoteHost:remotePort`
///                   reachable from the server → `-L bindPort:remoteHost:remotePort`.
///  * remote (`-R`): the server listens on `remoteHost:remotePort` and relays
///                   back to the local `bindAddress:bindPort` → `-R remotePort:bindAddress:bindPort`.
///  * dynamic (`-D`): a local SOCKS5 proxy on `bindPort` → `-D bindPort`.
///
/// [flags] is the leading flag run (default `-N -f`). The Options toggles inject
/// `-o ExitOnForwardFailure=yes` ([exitOnFailure]) and `-g` ([gatewayPorts])
/// after it, before the mapping. A non-loopback bind address surfaces as the
/// `[bind_address:]` prefix (the GatewayPorts / expose-to-LAN case).
List<PfCommandSegment> buildForwardCommandSegments({
  required PfForwardType type,
  required String bindAddress,
  required int? bindPort,
  required String remoteHost,
  required int? remotePort,
  required String host,
  String? username,
  String flags = kPfDefaultFlags,
  bool exitOnFailure = false,
  bool gatewayPorts = false,
}) {
  final segments = <PfCommandSegment>[];
  void plain(String s) => segments.add(PfCommandSegment(s));
  void port(int? p) {
    if (p == null) {
      segments.add(const PfCommandSegment('<port>', isPlaceholder: true));
    } else {
      plain('$p');
    }
  }

  plain('ssh');

  final trimmedFlags = flags.trim();
  if (trimmedFlags.isNotEmpty) plain(' $trimmedFlags');
  if (exitOnFailure) plain(' -o ExitOnForwardFailure=yes');
  // -g lets other machines reach a port this device listens on; a forward
  // from a port on the host asks the host for every address instead (below).
  if (gatewayPorts && type != PfForwardType.remote) plain(' -g');

  final ba = bindAddress.trim();
  final rh = remoteHost.trim().isEmpty ? 'localhost' : remoteHost.trim();

  switch (type) {
    case PfForwardType.local:
      plain(' -L ');
      if (!_isLoopbackBind(ba)) plain('$ba:');
      port(bindPort);
      plain(':$rh:');
      port(remotePort);
    case PfForwardType.remote:
      plain(' -R ');
      if (gatewayPorts && _isLoopbackBind(remoteHost)) {
        plain('0.0.0.0:');
      } else if (!_isLoopbackBind(remoteHost)) {
        plain('$rh:');
      }
      port(remotePort);
      final localDest = ba.isEmpty ? 'localhost' : ba;
      plain(':$localDest:');
      port(bindPort);
    case PfForwardType.dynamic:
      plain(' -D ');
      if (!_isLoopbackBind(ba)) plain('$ba:');
      port(bindPort);
  }

  // Destination host: real `user@host`, or a dim `<user@host>` when unset -
  // never the bare literal word `host`.
  plain(' ');
  final trimmedHost = host.trim();
  if (trimmedHost.isEmpty) {
    segments.add(
      const PfCommandSegment('<user@host>', isPlaceholder: true),
    );
  } else {
    final user = username?.trim();
    plain((user != null && user.isNotEmpty)
        ? '$user@$trimmedHost'
        : trimmedHost);
  }

  return segments;
}

/// The one-line string form of [buildForwardCommandSegments], for the copy
/// button and tests. Placeholders render as their literal `<port>` /
/// `<user@host>` text.
String buildForwardCommand({
  required PfForwardType type,
  required String bindAddress,
  required int? bindPort,
  required String remoteHost,
  required int? remotePort,
  required String host,
  String? username,
  String flags = kPfDefaultFlags,
  bool exitOnFailure = false,
  bool gatewayPorts = false,
}) {
  return buildForwardCommandSegments(
    type: type,
    bindAddress: bindAddress,
    bindPort: bindPort,
    remoteHost: remoteHost,
    remotePort: remotePort,
    host: host,
    username: username,
    flags: flags,
    exitOnFailure: exitOnFailure,
    gatewayPorts: gatewayPorts,
  ).map((s) => s.text).join();
}

// ══════════════════════════════════════════════════════════════════
// Saved-rule runtime state (fix #6) - pure + testable
// ══════════════════════════════════════════════════════════════════

/// The runtime state a saved rule row shows as a WORD next to Start/Stop.
enum PfRuleState { stopped, running, error }

/// Derive the rule state from the live signals: a failed start wins (Error),
/// else a running forward (Running), else Stopped.
PfRuleState pfRuleStateFor({required bool active, required bool errored}) {
  if (errored) return PfRuleState.error;
  return active ? PfRuleState.running : PfRuleState.stopped;
}

/// Map the rule state onto the unified status vocabulary: Stopped = neutral,
/// Running = healthy, Error = critical.
ZestStatusKind pfRuleStatusKind(PfRuleState state) => switch (state) {
      PfRuleState.stopped => ZestStatusKind.neutral,
      PfRuleState.running => ZestStatusKind.healthy,
      PfRuleState.error => ZestStatusKind.critical,
    };

// ══════════════════════════════════════════════════════════════════
// Controller
// ══════════════════════════════════════════════════════════════════

/// Editor state + dirty tracking for the 1.7 Port Forwarding detail pane.
///
/// A repository-free [ChangeNotifier] (the [NetworkEditController] pattern): it
/// owns the working draft, the dirty flag and the Simple/Advanced mode, but does
/// NO database I/O - the screen loads/saves through the DAO and calls [bind] /
/// [markSaved]. Keeping persistence out makes the build/validate logic testable
/// without a live database.
class PortForwardEditController extends ChangeNotifier {
  // ── Binding ────────────────────────────────────────────────────
  PortForwardRule? _original;
  PortForwardRule? get original => _original;
  bool get isCreating => _original == null;

  /// The host this forward is scoped to (chosen in the picker for a new rule,
  /// or carried from the edited rule).
  String? connectionId;

  // ── Mode + Simple-mode step ────────────────────────────────────
  PfEditorMode _mode = PfEditorMode.simple;
  PfEditorMode get mode => _mode;

  /// Simple mode collapses to a two-step flow ONLY when the pane is too narrow
  /// to show the fields + diagram side by side. 1 = pick a direction, 2 =
  /// configure it. In the wide (inline) layout the step is ignored.
  int simpleStep = 1;

  // ── Shared fields ──────────────────────────────────────────────
  /// The rule nickname. Persists to [PortForwardRule.label] in both editors.
  final TextEditingController nameController = TextEditingController();

  // ── Options (shared toggles, wired to the new schema columns) ───
  bool autoStart = false;
  bool reconnect = true;
  bool exitOnFailure = true;
  bool gatewayPorts = false;

  // ── Simple mode fields ─────────────────────────────────────────
  PfForwardType forwardType = PfForwardType.local;

  /// The port on THIS device (the rule's bindPort). Also the SOCKS/proxy port
  /// for a dynamic forward.
  final TextEditingController simpleBindPortController = TextEditingController();

  /// The service / server-side port (the rule's remotePort). Unused for dynamic.
  final TextEditingController simpleRemotePortController =
      TextEditingController();

  // ── Advanced mode fields ───────────────────────────────────────
  PfForwardType advancedType = PfForwardType.local;
  final TextEditingController advSourceHostController =
      TextEditingController(text: 'localhost');
  final TextEditingController advSourcePortController = TextEditingController();
  final TextEditingController advDestHostController =
      TextEditingController(text: 'localhost');
  final TextEditingController advDestPortController = TextEditingController();
  final TextEditingController advFlagsController =
      TextEditingController(text: kPfDefaultFlags);

  bool _dirty = false;
  bool get isDirty => _dirty;

  // ── Load / reset ───────────────────────────────────────────────

  /// Point the editor at [rule] (null = creating a new one). An existing rule
  /// opens in Advanced (its fields map 1:1 to the stored columns); a new rule
  /// opens in Simple. Resets the dirty flag.
  void bind(PortForwardRule? rule, {String? connectionId}) {
    _original = rule;
    this.connectionId = connectionId ?? rule?.connectionId;
    simpleStep = 1;

    nameController.text = rule?.label ?? '';

    // Options: seed from the rule, or the schema defaults for a new one.
    autoStart = rule?.autoStart ?? false;
    reconnect = rule?.reconnect ?? true;
    exitOnFailure = rule?.exitOnFailure ?? true;
    gatewayPorts = rule?.gatewayPorts ?? false;

    // Reset both field sets to their defaults.
    forwardType = PfForwardType.local;
    simpleBindPortController.clear();
    simpleRemotePortController.clear();

    advancedType = PfForwardType.local;
    advSourceHostController.text = 'localhost';
    advSourcePortController.clear();
    advDestHostController.text = 'localhost';
    advDestPortController.clear();
    advFlagsController.text = rule?.sshFlags ?? kPfDefaultFlags;

    if (rule != null) {
      _mode = PfEditorMode.advanced;
      final t = _typeFromString(rule.type);
      forwardType = t;
      advancedType = t;

      // Advanced fields map 1:1 to the columns.
      advSourceHostController.text = rule.bindAddress;
      advSourcePortController.text = rule.bindPort.toString();
      if (t != PfForwardType.dynamic) {
        advDestHostController.text = rule.remoteHost;
        advDestPortController.text = rule.remotePort.toString();
      }

      // Seed the Simple fields too so flipping to Simple shows the rule.
      simpleBindPortController.text = rule.bindPort.toString();
      if (t != PfForwardType.dynamic) {
        simpleRemotePortController.text = rule.remotePort.toString();
      }
    } else {
      _mode = PfEditorMode.simple;
    }

    _dirty = false;
    notifyListeners();
  }

  /// After a successful save, rebind to the persisted [rule] so the title flips
  /// from "New rule" to the rule name and the dirty flag clears - without
  /// rebuilding the controllers (their in-place text is already the saved truth).
  ///
  /// Saved from Simple, the hosts and flags Advanced still held (kept so that
  /// going straight back showed them) are no longer the rule's: Advanced now
  /// shows what was saved.
  void markSaved(PortForwardRule rule) {
    _original = rule;
    connectionId = rule.connectionId;
    if (_mode == PfEditorMode.simple) {
      advSourceHostController.text = rule.bindAddress;
      if (rule.type != PfForwardType.dynamic.name) {
        advDestHostController.text = rule.remoteHost;
      }
      advFlagsController.text = rule.sshFlags ?? kPfDefaultFlags;
    }
    _dirty = false;
    notifyListeners();
  }

  // ── Kept while the page is away (memory only) ──────────────────

  /// Everything the person has typed or chosen, to be put back with [restore]
  /// when the page comes back (a terminal was shown in its place).
  PfEditDraft snapshot() => PfEditDraft(
        original: _original,
        connectionId: connectionId,
        mode: _mode,
        simpleStep: simpleStep,
        name: nameController.text,
        autoStart: autoStart,
        reconnect: reconnect,
        exitOnFailure: exitOnFailure,
        gatewayPorts: gatewayPorts,
        forwardType: forwardType,
        simpleBindPort: simpleBindPortController.text,
        simpleRemotePort: simpleRemotePortController.text,
        advancedType: advancedType,
        advSourceHost: advSourceHostController.text,
        advSourcePort: advSourcePortController.text,
        advDestHost: advDestHostController.text,
        advDestPort: advDestPortController.text,
        advFlags: advFlagsController.text,
      );

  /// Put back what [snapshot] took. It is shown as unsaved (the dirty dot, Save
  /// on): it is not the rule as saved.
  void restore(PfEditDraft d) {
    _original = d.original;
    connectionId = d.connectionId;
    _mode = d.mode;
    simpleStep = d.simpleStep;
    nameController.text = d.name;
    autoStart = d.autoStart;
    reconnect = d.reconnect;
    exitOnFailure = d.exitOnFailure;
    gatewayPorts = d.gatewayPorts;
    forwardType = d.forwardType;
    simpleBindPortController.text = d.simpleBindPort;
    simpleRemotePortController.text = d.simpleRemotePort;
    advancedType = d.advancedType;
    advSourceHostController.text = d.advSourceHost;
    advSourcePortController.text = d.advSourcePort;
    advDestHostController.text = d.advDestHost;
    advDestPortController.text = d.advDestPort;
    advFlagsController.text = d.advFlags;
    _dirty = true;
    notifyListeners();
  }

  // ── Edits (all funnel through markDirty) ───────────────────────

  /// Notify listeners on every edit - even when already dirty - so live
  /// artifacts (the command preview, Save-enabled, the dirty dot) refresh.
  void markDirty() {
    _dirty = true;
    notifyListeners();
  }

  void setConnectionId(String? id) {
    connectionId = id;
    markDirty();
  }

  /// Switch between Simple and Advanced, carrying what was typed across: the
  /// kind of forward and both ports (the port on this side is the rule's
  /// bindPort in both editors, the other its remotePort). A switch is not an
  /// edit: it never marks the form dirty.
  ///
  /// The hosts and the flags are never touched by a switch. Going to Simple,
  /// Advanced keeps them, so going straight back shows them again; Simple
  /// cannot show them ([simpleCannotShow], which the page asks about first),
  /// and a save from Simple writes localhost and the default flags.
  void setMode(PfEditorMode mode) {
    if (mode == _mode) return;
    if (mode == PfEditorMode.advanced) {
      advancedType = forwardType;
      advSourcePortController.text = simpleBindPortController.text;
      if (forwardType != PfForwardType.dynamic) {
        advDestPortController.text = simpleRemotePortController.text;
      }
    } else {
      forwardType = advancedType;
      simpleBindPortController.text = advSourcePortController.text;
      if (advancedType != PfForwardType.dynamic) {
        simpleRemotePortController.text = advDestPortController.text;
      }
    }
    _mode = mode;
    notifyListeners();
  }

  /// What Advanced holds that Simple cannot show (Simple always uses
  /// localhost at both ends and the default flags): empty when going to Simple
  /// loses nothing, so the switch needs no question.
  Set<PfSimpleCannotShow> get simpleCannotShow {
    final found = <PfSimpleCannotShow>{};
    if (!_isLoopbackBind(advSourceHostController.text)) {
      found.add(PfSimpleCannotShow.sourceHost);
    }
    final dest = advDestHostController.text.trim().toLowerCase();
    if (advancedType != PfForwardType.dynamic && dest.isNotEmpty && dest != 'localhost') {
      found.add(PfSimpleCannotShow.destinationHost);
    }
    final flags = advFlagsController.text.trim().split(RegExp(r'\s+')).where((f) => f.isNotEmpty).toSet();
    if (flags.isNotEmpty && !(flags.length == 2 && flags.containsAll(const {'-N', '-f'}))) {
      found.add(PfSimpleCannotShow.flags);
    }
    return found;
  }

  /// Simple-mode step navigation is NOT an edit - it must not flip the dirty
  /// flag - but it must rebuild the body.
  void setSimpleStep(int step) {
    if (simpleStep == step) return;
    simpleStep = step;
    notifyListeners();
  }

  void setForwardType(PfForwardType type) {
    forwardType = type;
    markDirty();
  }

  void setAdvancedType(PfForwardType type) {
    advancedType = type;
    markDirty();
  }

  void setAutoStart(bool value) {
    autoStart = value;
    markDirty();
  }

  void setReconnect(bool value) {
    reconnect = value;
    markDirty();
  }

  void setExitOnFailure(bool value) {
    exitOnFailure = value;
    markDirty();
  }

  void setGatewayPorts(bool value) {
    gatewayPorts = value;
    markDirty();
  }

  // ── Build / validate ───────────────────────────────────────────

  static PfForwardType _typeFromString(String s) => PfForwardType.values
      .firstWhere((t) => t.name == s, orElse: () => PfForwardType.local);

  static bool _portValid(int? p) => p != null && p >= 1 && p <= 65535;

  String? get _labelOrNull {
    final t = nameController.text.trim();
    return t.isEmpty ? null : t;
  }

  /// Assemble the Drift companion for the current form state, or return a
  /// human-readable error to surface. Mirrors the wizard's two build paths.
  ///
  /// [l10n] localizes the Simple-mode port validation messages; it is optional
  /// (English fallbacks) so the pure build logic stays testable without a
  /// [BuildContext].
  ({PortForwardRulesCompanion? companion, String? error}) buildCompanion(
      {AppLocalizations? l10n}) {
    final connId = connectionId;
    if (connId == null) {
      return (
        companion: null,
        error: l10n?.portForwardEditPickConnectionFirst ??
            'Pick a host first - port forwards are scoped to a host.',
      );
    }
    final id = _original?.id ?? const Uuid().v4();
    final now = _original?.createdAt ?? DateTime.now();
    return _mode == PfEditorMode.simple
        ? _buildSimple(id, connId, now, l10n)
        : _buildAdvanced(id, connId, now, l10n);
  }

  ({PortForwardRulesCompanion? companion, String? error}) _buildSimple(
      String id, String connectionId, DateTime now, AppLocalizations? l10n) {
    switch (forwardType) {
      case PfForwardType.local:
        final myPort = int.tryParse(simpleBindPortController.text.trim());
        final servicePort =
            int.tryParse(simpleRemotePortController.text.trim());
        if (!_portValid(servicePort)) {
          return (
            companion: null,
            error: l10n?.zestPfErrServicePort ?? 'Service port must be 1-65535',
          );
        }
        if (!_portValid(myPort)) {
          return (
            companion: null,
            error: l10n?.zestPfErrMyPort ?? 'My port must be 1-65535',
          );
        }
        return (
          companion: _companion(
            id: id,
            connectionId: connectionId,
            type: 'local',
            bindPort: myPort!,
            remoteHost: 'localhost',
            remotePort: servicePort!,
            now: now,
          ),
          error: null,
        );

      case PfForwardType.remote:
        final servicePort = int.tryParse(simpleBindPortController.text.trim());
        final serverPort = int.tryParse(simpleRemotePortController.text.trim());
        if (!_portValid(servicePort)) {
          return (
            companion: null,
            error: l10n?.zestPfErrServicePort ?? 'Service port must be 1-65535',
          );
        }
        if (!_portValid(serverPort)) {
          return (
            companion: null,
            error: l10n?.zestPfErrServerPort ?? 'Server port must be 1-65535',
          );
        }
        return (
          companion: _companion(
            id: id,
            connectionId: connectionId,
            type: 'remote',
            bindPort: servicePort!,
            remoteHost: 'localhost',
            remotePort: serverPort!,
            now: now,
          ),
          error: null,
        );

      case PfForwardType.dynamic:
        final proxyPort = int.tryParse(simpleBindPortController.text.trim());
        if (!_portValid(proxyPort)) {
          return (
            companion: null,
            error: l10n?.zestPfErrProxyPort ?? 'Proxy port must be 1-65535',
          );
        }
        return (
          companion: _companion(
            id: id,
            connectionId: connectionId,
            type: 'dynamic',
            bindPort: proxyPort!,
            remoteHost: '',
            remotePort: 0,
            now: now,
          ),
          error: null,
        );
    }
  }

  ({PortForwardRulesCompanion? companion, String? error}) _buildAdvanced(
      String id, String connectionId, DateTime now, AppLocalizations? l10n) {
    final srcPort = int.tryParse(advSourcePortController.text.trim());
    final dstPort = int.tryParse(advDestPortController.text.trim());
    if (!_portValid(srcPort)) {
      return (
        companion: null,
        error: l10n?.portForwardEditSourcePortRange ??
            'Source port must be 1-65535',
      );
    }
    if (advancedType != PfForwardType.dynamic && !_portValid(dstPort)) {
      return (
        companion: null,
        error: l10n?.portForwardEditDestPortRange ??
            'Destination port must be 1-65535',
      );
    }
    final srcHost = advSourceHostController.text.trim();
    final flags = advFlagsController.text.trim();
    return (
      companion: _companion(
        id: id,
        connectionId: connectionId,
        type: advancedType.name,
        bindAddress: srcHost.isEmpty ? '127.0.0.1' : srcHost,
        bindPort: srcPort!,
        remoteHost: advancedType == PfForwardType.dynamic
            ? ''
            : advDestHostController.text.trim(),
        remotePort: advancedType == PfForwardType.dynamic ? 0 : dstPort!,
        sshFlags: flags.isEmpty ? null : flags,
        now: now,
      ),
      error: null,
    );
  }

  /// Assemble a companion from the resolved values plus the shared Name +
  /// Options state, so every save path persists the full column set.
  PortForwardRulesCompanion _companion({
    required String id,
    required String connectionId,
    required String type,
    String bindAddress = '127.0.0.1',
    required int bindPort,
    required String remoteHost,
    required int remotePort,
    String? sshFlags,
    required DateTime now,
  }) {
    return PortForwardRulesCompanion(
      id: Value(id),
      connectionId: Value(connectionId),
      type: Value(type),
      bindAddress: Value(bindAddress),
      bindPort: Value(bindPort),
      remoteHost: Value(remoteHost),
      remotePort: Value(remotePort),
      autoStart: Value(autoStart),
      reconnect: Value(reconnect),
      exitOnFailure: Value(exitOnFailure),
      gatewayPorts: Value(gatewayPorts),
      sshFlags: Value(sshFlags),
      label: Value(_labelOrNull),
      createdAt: Value(now),
    );
  }

  // ── Live command preview ───────────────────────────────────────

  /// The live Advanced-mode command segments, resolved against the given
  /// connection endpoint. Reflects the Options toggles (`-o` / `-g`) and the
  /// SSH-flags field.
  List<PfCommandSegment> advancedPreviewSegments(
      {required String host, String? username}) {
    return buildForwardCommandSegments(
      type: advancedType,
      bindAddress: advSourceHostController.text,
      bindPort: int.tryParse(advSourcePortController.text.trim()),
      remoteHost: advDestHostController.text,
      remotePort: advancedType == PfForwardType.dynamic
          ? null
          : int.tryParse(advDestPortController.text.trim()),
      host: host,
      username: username,
      flags: advFlagsController.text,
      exitOnFailure: exitOnFailure,
      gatewayPorts: gatewayPorts,
    );
  }

  /// The live Simple-mode command segments - a friendly `-N -f` + mapping,
  /// without the Advanced-only Options flags.
  List<PfCommandSegment> simplePreviewSegments(
      {required String host, String? username}) {
    // "Let other machines reach it" shapes the command as it shapes the
    // forward (-g, or the host's every address for a forward from it).
    final here = int.tryParse(simpleBindPortController.text.trim());
    final there = int.tryParse(simpleRemotePortController.text.trim());
    switch (forwardType) {
      case PfForwardType.local:
        return buildForwardCommandSegments(
          type: PfForwardType.local,
          bindAddress: '127.0.0.1',
          bindPort: here,
          remoteHost: 'localhost',
          remotePort: there,
          host: host,
          username: username,
          gatewayPorts: gatewayPorts,
        );
      case PfForwardType.remote:
        return buildForwardCommandSegments(
          type: PfForwardType.remote,
          bindAddress: 'localhost',
          bindPort: here,
          remoteHost: 'localhost',
          remotePort: there,
          host: host,
          username: username,
          gatewayPorts: gatewayPorts,
        );
      case PfForwardType.dynamic:
        return buildForwardCommandSegments(
          type: PfForwardType.dynamic,
          bindAddress: '127.0.0.1',
          bindPort: here,
          remoteHost: '',
          remotePort: null,
          host: host,
          username: username,
          gatewayPorts: gatewayPorts,
        );
    }
  }

  /// The Advanced command as a one-line string (copy button + tests).
  String previewCommand({required String host, String? username}) =>
      advancedPreviewSegments(host: host, username: username)
          .map((s) => s.text)
          .join();

  // ── Discard guard ──────────────────────────────────────────────

  /// The shared dirty guard wired into every leave-the-editor path (select
  /// another row, +New, Cancel; never a mode switch, which keeps what was
  /// typed, nor leaving the page, which keeps a draft). Returns true to PROCEED, false
  /// to ABORT. On "Save" it runs [onSave] and proceeds only if the save
  /// succeeded. Never autosaves on its own.
  Future<bool> confirmDiscardIfDirty(
    BuildContext context, {
    required Future<bool> Function() onSave,
  }) async {
    if (!_dirty) return true;
    final choice = await showZestDiscardDialog(context);
    switch (choice) {
      case DiscardChoice.cancel:
        return false;
      case DiscardChoice.discard:
        return true;
      case DiscardChoice.save:
        return onSave();
    }
  }

  @override
  void dispose() {
    nameController.dispose();
    simpleBindPortController.dispose();
    simpleRemotePortController.dispose();
    advSourceHostController.dispose();
    advSourcePortController.dispose();
    advDestHostController.dispose();
    advDestPortController.dispose();
    advFlagsController.dispose();
    super.dispose();
  }
}
