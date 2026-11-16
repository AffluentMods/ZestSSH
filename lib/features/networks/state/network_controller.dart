import 'package:flutter/material.dart';

import '../../../l10n/generated/app_localizations.dart';
import '../../../ui/widgets/zest_detail_scaffold.dart';
import '../../hosts/models/host_network_override.dart';
import '../data/network_icon_catalog.dart';
import '../engine/cidr.dart';
import '../engine/network_state.dart';
import '../models/network.dart';
import '../models/network_trigger.dart';
import '../../../core/theme/group_color.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';

/// The two editors of the 1.7 Networks detail pane. ONE data model
/// ([Network]), two views - Advanced is a strict superset of Simple.
enum EditorMode { simple, advanced }

/// Injectable snapshot reader so "Use my current network" is unit-testable
/// without a live device - tests pass a fake that returns a canned
/// [NetworkState]. Defaults to the real [readCurrentNetworkState].
typedef NetworkStateReader = Future<NetworkState> Function({bool requestSsid});

// ══════════════════════════════════════════════════════════════════
// "Use my current network" - pure detection → suggestion
// ══════════════════════════════════════════════════════════════════

/// What the detector could read about the device's current network, distilled
/// into the two things Simple mode cares about: the Wi-Fi [ssid] and a derived
/// [subnetCidr]. Pure data so the mapping is testable in isolation.
@immutable
class CurrentNetworkSuggestion {
  const CurrentNetworkSuggestion({
    required this.connectivityKind,
    this.ssid,
    this.subnetCidr,
  });

  final ConnectivityKind connectivityKind;

  /// Current Wi-Fi network name, or null (not on Wi-Fi, or permission denied).
  final String? ssid;

  /// A `/24` CIDR derived from the first usable local IPv4 address, or null
  /// when no IPv4 address was readable (e.g. a VPN masking the LAN).
  final String? subnetCidr;

  bool get hasSsid => ssid != null && ssid!.isNotEmpty;
  bool get hasSubnet => subnetCidr != null && subnetCidr!.isNotEmpty;

  /// On Wi-Fi but no SSID → the OS withheld it (location permission on
  /// Android, entitlement on iOS). Drives the inline permission prompt.
  bool get ssidBlockedByPermission =>
      connectivityKind == ConnectivityKind.wifi && !hasSsid;

  /// True when nothing usable was detected at all.
  bool get isEmpty => !hasSsid && !hasSubnet;
}

/// Distil a raw [NetworkState] into a [CurrentNetworkSuggestion]. Picks the
/// first usable IPv4 address and widens it to a `/24` - the pragmatic "this
/// LAN" match. Pure + synchronous so it is trivially unit-testable.
CurrentNetworkSuggestion suggestCurrentNetwork(NetworkState state) {
  String? cidr;
  for (final addr in state.localAddresses) {
    final octets = _ipv4Octets(addr);
    if (octets == null) continue;
    // Skip link-local (169.254/16) - never a useful match target.
    if (octets[0] == 169 && octets[1] == 254) continue;
    cidr = '${octets[0]}.${octets[1]}.${octets[2]}.0/24';
    break;
  }
  final ssid = (state.ssid != null && state.ssid!.isNotEmpty) ? state.ssid : null;
  return CurrentNetworkSuggestion(
    connectivityKind: state.connectivityKind,
    ssid: ssid,
    subnetCidr: cidr,
  );
}

/// Parse an IPv4 dotted-quad into its four octets, or null if it is not a
/// well-formed IPv4 literal (IPv6 and garbage both return null).
List<int>? _ipv4Octets(String s) {
  final parts = s.split('.');
  if (parts.length != 4) return null;
  final out = <int>[];
  for (final p in parts) {
    if (p.isEmpty || p.length > 3) return null;
    final n = int.tryParse(p);
    if (n == null || n < 0 || n > 255) return null;
    out.add(n);
  }
  return out;
}

// ══════════════════════════════════════════════════════════════════
// preferredEditorMode persistence (per network, local - no schema change)
// ══════════════════════════════════════════════════════════════════

/// Persists the last editor mode a user chose FOR A GIVEN NETWORK, so the
/// pane reopens in the same view. A purely local editor preference - stored in
/// `shared_preferences` (key `zest_network_mode_<id>`) rather than a DB column,
/// exactly as the 1.7 §1 spec calls for. New networks default to Simple.
abstract final class NetworkEditModePrefs {
  static String keyFor(String networkId) => 'zest_network_mode_$networkId';

  /// Load the remembered mode for [networkId]; Simple when unset/unknown.
  static Future<EditorMode> load(String networkId) async {
    try {
      final prefs = await appPreferences();
      final raw = prefs.getString(keyFor(networkId));
      return raw == EditorMode.advanced.name
          ? EditorMode.advanced
          : EditorMode.simple;
    } catch (_) {
      return EditorMode.simple;
    }
  }

  /// Remember [mode] for [networkId]. Failures are swallowed - a lost
  /// preference just means the next open uses the default.
  static Future<void> save(String networkId, EditorMode mode) async {
    try {
      final prefs = await appPreferences();
      await prefs.setString(keyFor(networkId), mode.name);
    } catch (_) {
      // best-effort
    }
  }
}

// ══════════════════════════════════════════════════════════════════
// Mutable drafts
// ══════════════════════════════════════════════════════════════════

/// The kinds of trigger the Advanced editor can add.
enum TriggerKind { subnet, ssid, cellular, connectivity }

/// A mutable, editor-side view of a single [NetworkTrigger] - mirrors the
/// approach the old modal editor used, but owned by the controller so both
/// Simple and Advanced share one draft list (invariant 1: one data model).
class TriggerDraft {
  TriggerDraft._(this.kind, {String? text, this.connectivityKind})
      : textController =
            (kind == TriggerKind.subnet || kind == TriggerKind.ssid)
                ? TextEditingController(text: text ?? '')
                : null;

  factory TriggerDraft.subnet([String cidr = '']) =>
      TriggerDraft._(TriggerKind.subnet, text: cidr);

  factory TriggerDraft.ssid([String ssid = '']) =>
      TriggerDraft._(TriggerKind.ssid, text: ssid);

  factory TriggerDraft.cellular() => TriggerDraft._(TriggerKind.cellular);

  factory TriggerDraft.connectivity(
          [ConnectivityKind kind = ConnectivityKind.wifi]) =>
      TriggerDraft._(TriggerKind.connectivity, connectivityKind: kind);

  /// Rebuild a draft from a stored trigger. AlwaysTrigger/unknown collapse to
  /// null - the caller filters those out (they are not user-editable rows).
  static TriggerDraft? fromTrigger(NetworkTrigger t) => switch (t) {
        SubnetTrigger(:final cidr) => TriggerDraft.subnet(cidr),
        SsidTrigger(:final ssid) => TriggerDraft.ssid(ssid),
        CellularTrigger() => TriggerDraft.cellular(),
        ConnectivityTrigger(:final kind) => TriggerDraft.connectivity(kind),
        _ => null,
      };

  final TriggerKind kind;
  final TextEditingController? textController;
  ConnectivityKind? connectivityKind;

  String get _text => textController?.text.trim() ?? '';

  /// Bake back into an immutable [NetworkTrigger] for persistence.
  NetworkTrigger toTrigger() => switch (kind) {
        TriggerKind.subnet => SubnetTrigger(_text),
        TriggerKind.ssid => SsidTrigger(_text),
        TriggerKind.cellular => const CellularTrigger(),
        TriggerKind.connectivity =>
          ConnectivityTrigger(connectivityKind ?? ConnectivityKind.wifi),
      };

  /// Inline validation error, or null. Subnet must be a parseable CIDR; SSID
  /// must be non-empty. Cellular/connectivity are always valid.
  String? fieldError(AppLocalizations l10n) => switch (kind) {
        TriggerKind.subnet =>
          (_text.isEmpty || Cidr.tryParse(_text) == null)
              ? l10n.networkEditorCidrInvalid
              : null,
        TriggerKind.ssid => _text.isEmpty ? l10n.networkEditorSsidEmpty : null,
        _ => null,
      };

  void dispose() => textController?.dispose();
}

/// A mutable per-host override draft for the Advanced [HostOverrideTable].
/// Carries the existing row id (when present) so a save updates in place
/// rather than orphaning rows.
class HostOverrideDraft {
  HostOverrideDraft({
    required this.hostId,
    this.existingId,
    String address = '',
    String port = '',
    this.skip = false,
    List<String>? jumpChain,
    this.username,
    this.identityKeyId,
    this.jumpHostId,
  })  : addressController = TextEditingController(text: address),
        portController = TextEditingController(text: port),
        jumpChain = List<String>.from(jumpChain ?? const []);

  /// Build a draft from a stored override.
  factory HostOverrideDraft.fromModel(HostNetworkOverride o) {
    return HostOverrideDraft(
      hostId: o.hostId,
      existingId: o.id.isEmpty ? null : o.id,
      address: o.address ?? '',
      port: o.port?.toString() ?? '',
      skip: o.skipHost ?? false,
      jumpChain: o.jumpHostChain ?? const [],
      // Preserved opaquely so a Networks-side save round-trips per-host
      // username / identity / single-jump overrides instead of NULLing them.
      username: o.username,
      identityKeyId: o.identityKeyId,
      jumpHostId: o.jumpHostId,
    );
  }

  final String hostId;
  String? existingId;
  final TextEditingController addressController;
  final TextEditingController portController;
  bool skip;
  List<String> jumpChain;

  /// Per-host overrides edited on the HOST side (not in this table). Carried
  /// through a Networks-side save untouched so it can never wipe them.
  final String? username;
  final String? identityKeyId;
  final String? jumpHostId;

  String get _address => addressController.text.trim();
  int? get _port => int.tryParse(portController.text.trim());

  /// True when this override would behave identically to no override at all -
  /// the row is then deleted on save rather than persisted.
  bool get isEmptyDraft =>
      _address.isEmpty &&
      _port == null &&
      !skip &&
      jumpChain.isEmpty &&
      username == null &&
      identityKeyId == null &&
      jumpHostId == null;

  bool get hasJumpChain => jumpChain.isNotEmpty;

  /// Bake into the persistence model. [jumpHostChain] uses the explicit
  /// list (empty list = "no jump on this network") the resolver understands.
  HostNetworkOverride toModel(String networkId) {
    final chain = jumpChain.isEmpty ? null : List<String>.from(jumpChain);
    return HostNetworkOverride(
      id: existingId ?? '',
      hostId: hostId,
      networkId: networkId,
      address: _address.isEmpty ? null : _address,
      port: _port,
      // Round-trip the host-side overrides untouched.
      username: username,
      identityKeyId: identityKeyId,
      // jumpHostId and jumpHostChain are mutually exclusive (the model
      // asserts): an edited chain wins; else preserve the stored single jump.
      jumpHostId: chain == null ? jumpHostId : null,
      jumpHostChain: chain,
      skipHost: skip ? true : null,
    );
  }

  void dispose() {
    addressController.dispose();
    portController.dispose();
  }
}

// ══════════════════════════════════════════════════════════════════
// Derived-artifact expression (invariant 4)
// ══════════════════════════════════════════════════════════════════

/// Build the dim mono "match expression" Simple always shows at the bottom of
/// the pane - the honest artifact the form produces, and how a user learns
/// they've outgrown Simple. Pure so it is directly testable.
///
/// [displaySsid] maps a Wi-Fi name to the form to PAINT (recording mode masks
/// it by the name rule); null keeps the real value, for tests and for the copy
/// action, which runs behind the reveal gate.
String derivedMatchExpression(
  List<TriggerDraft> triggers, {
  bool isFallback = false,
  String Function(String ssid)? displaySsid,
}) {
  if (isFallback) return 'always';
  if (triggers.isEmpty) return '-';
  final parts = <String>[];
  for (final t in triggers) {
    parts.add(switch (t.kind) {
      TriggerKind.subnet => () {
          final raw = t.textController?.text.trim() ?? '';
          final parsed = Cidr.tryParse(raw);
          return parsed != null ? 'ip ∈ $parsed' : 'ip ∈ ${raw.isEmpty ? '…' : raw}';
        }(),
      TriggerKind.ssid => () {
          final raw = t.textController?.text.trim() ?? '';
          final shown = raw.isEmpty ? '…' : (displaySsid?.call(raw) ?? raw);
          return 'ssid == "$shown"';
        }(),
      TriggerKind.cellular => 'link == cellular',
      TriggerKind.connectivity =>
        'link == ${(t.connectivityKind ?? ConnectivityKind.wifi).name}',
    });
  }
  return parts.join('  OR  ');
}

// ══════════════════════════════════════════════════════════════════
// The controller
// ══════════════════════════════════════════════════════════════════

/// Editor state + invariants for the 1.7 Networks detail pane.
///
/// A repository-free [ChangeNotifier]: it owns the working draft, the dirty
/// flag, the Simple/Advanced mode, and the mode invariants - but does NOT do
/// database I/O. The screen loads/saves through the repositories and calls
/// [bind] / [markSaved]; keeping persistence out of here makes every invariant
/// unit-testable without a live database.
class NetworkEditController extends ChangeNotifier {
  NetworkEditController({NetworkStateReader? stateReader})
      : _stateReader = stateReader ?? readCurrentNetworkState;

  final NetworkStateReader _stateReader;

  // ── Binding ────────────────────────────────────────────────────
  Network? _original;
  Network? get original => _original;
  bool get isCreating => _original == null;
  bool get isFallback => _original?.isFallback ?? false;

  // ── Working fields ─────────────────────────────────────────────
  final TextEditingController nameController = TextEditingController();
  GroupColor color = GroupColor.blue;

  /// Optional custom accent as an ARGB int; overrides [color] when non-null so
  /// the user can pick ANY colour. Null = use the [color] token.
  int? colorValue;
  IconData icon = defaultNetworkIcon;
  final List<TriggerDraft> triggers = [];
  String? bringUpVpn;
  final List<HostOverrideDraft> overrides = [];

  /// Override rows the user removed that must be deleted from storage on save.
  final Set<String> _removedOverrideIds = {};

  EditorMode _mode = EditorMode.simple;
  EditorMode get mode => _mode;

  bool _dirty = false;
  bool get isDirty => _dirty;

  /// The most recent "Use my current network" detection, or null. Drives the
  /// Simple form's confirmation / partial-detection / permission UI.
  CurrentNetworkSuggestion? lastSuggestion;

  /// True while a detection request is in flight.
  bool detecting = false;

  // Validation surfaces (set by the screen's save path).
  String? nameError;
  String? triggersError;

  // ── Load / reset ───────────────────────────────────────────────

  /// Point the editor at [network] (null = creating a new one) with its
  /// already-loaded [overrideRows] and remembered [mode]. Resets dirty.
  void bind(
    Network? network, {
    required List<HostNetworkOverride> overrideRows,
    required EditorMode mode,
  }) {
    _disposeDrafts();
    _original = network;
    nameController.text = network?.name ?? '';
    color = network?.color ?? GroupColor.blue;
    colorValue = network?.colorValue;
    icon = network?.icon ?? defaultNetworkIcon;
    triggers
      ..clear()
      ..addAll(_editableDrafts(network?.triggers ?? const []));
    bringUpVpn = network?.bringUpVpn;
    overrides
      ..clear()
      ..addAll(overrideRows.map(HostOverrideDraft.fromModel));
    _removedOverrideIds.clear();
    _mode = _coerceMode(mode);
    lastSuggestion = null;
    detecting = false;
    nameError = null;
    triggersError = null;
    _dirty = false;
    notifyListeners();
  }

  /// Non-Always triggers become editable drafts; AlwaysTrigger/unknown drop.
  List<TriggerDraft> _editableDrafts(List<NetworkTrigger> triggers) {
    final out = <TriggerDraft>[];
    for (final t in triggers) {
      final d = TriggerDraft.fromTrigger(t);
      if (d != null) out.add(d);
    }
    return out;
  }

  /// After a successful save the editor rebinds to the persisted [network]
  /// (so the "New" title flips to the name, and dirty clears) without
  /// rebuilding text controllers or override drafts (their in-place edits are
  /// already the saved truth).
  void markSaved(Network network) {
    _original = network;
    _removedOverrideIds.clear();
    _dirty = false;
    nameError = null;
    triggersError = null;
    notifyListeners();
  }

  // ── Mode invariants ────────────────────────────────────────────

  /// Whether the network fits Simple: always now. Simple lists every rule,
  /// the way hosts are reached and every host's rule,
  /// and sends a host rule's own fields to Advanced, so
  /// nothing a network holds is out of its sight. (It held one rule and no
  /// host rules, and a network with more was Advanced only.)
  SimpleModeBlock? get simpleBlock => null;

  /// Localized reason the Simple segment is disabled, or null when Simple is
  /// available. This is the controller-side mapping of the pure model reason
  /// code onto the pre-seeded `zestNetworkSimpleBlocked*` strings.
  String? simpleBlockedReason(AppLocalizations l10n) {
    return switch (simpleBlock) {
      SimpleModeBlock.multipleTriggers =>
        l10n.zestNetworkSimpleBlockedTriggers(triggers.length),
      SimpleModeBlock.hostOverrides => l10n.zestNetworkSimpleBlockedOverrides,
      SimpleModeBlock.jumpHostChain => l10n.zestNetworkSimpleBlockedJumpHost,
      null => null,
    };
  }

  /// If a network is bound that has outgrown Simple, force Advanced regardless
  /// of the remembered preference.
  EditorMode _coerceMode(EditorMode desired) {
    if (desired == EditorMode.simple && simpleBlock != null) {
      return EditorMode.advanced;
    }
    return desired;
  }

  /// Switch modes. Lossless by construction - both editors read the ONE draft,
  /// and Simple is disabled (never reachable) whenever the object carries
  /// Advanced-only content - so no discard prompt is needed here. Persisting
  /// the preference is the screen's job (it owns the network id).
  void setMode(EditorMode mode) {
    if (mode == _mode) return;
    if (mode == EditorMode.simple && simpleBlock != null) return; // guarded
    _mode = mode;
    notifyListeners();
  }

  // ── Edits (all funnel through markDirty) ───────────────────────

  void markDirty() {
    if (!_dirty) {
      _dirty = true;
      notifyListeners();
    } else {
      // Still notify so live artifacts (derived line, override table) refresh.
      notifyListeners();
    }
  }

  void setColor(GroupColor c) {
    color = c;
    // Picking a preset token clears any custom colour so the token wins again.
    colorValue = null;
    markDirty();
  }

  /// Persist an arbitrary custom accent (ARGB int) that overrides [color].
  void setColorValue(int value) {
    colorValue = value;
    markDirty();
  }

  void setIcon(IconData i) {
    icon = i;
    markDirty();
  }

  void setBringUpVpn(String? hostId) {
    bringUpVpn = hostId;
    markDirty();
  }

  void addTrigger(TriggerKind kind) {
    triggers.add(switch (kind) {
      TriggerKind.subnet => TriggerDraft.subnet(),
      TriggerKind.ssid => TriggerDraft.ssid(),
      TriggerKind.cellular => TriggerDraft.cellular(),
      TriggerKind.connectivity => TriggerDraft.connectivity(),
    });
    triggersError = null;
    markDirty();
  }

  void removeTrigger(TriggerDraft draft) {
    if (triggers.remove(draft)) {
      draft.dispose();
      markDirty();
    }
  }

  void reorderTriggers(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final d = triggers.removeAt(oldIndex);
    triggers.insert(newIndex, d);
    markDirty();
  }

  void setConnectivityKind(TriggerDraft draft, ConnectivityKind kind) {
    draft.connectivityKind = kind;
    markDirty();
  }

  // ── Host overrides (Advanced) ──────────────────────────────────

  HostOverrideDraft addOverride(String hostId) {
    final draft = HostOverrideDraft(hostId: hostId);
    overrides.add(draft);
    markDirty();
    return draft;
  }

  void removeOverride(HostOverrideDraft draft) {
    if (overrides.remove(draft)) {
      if (draft.existingId != null) _removedOverrideIds.add(draft.existingId!);
      draft.dispose();
      markDirty();
    }
  }

  Set<String> get removedOverrideIds => _removedOverrideIds;

  // ── "Use my current network" ───────────────────────────────────

  /// Read the live network state and fill a single subnet trigger from it
  /// (the derived CIDR - invariant 4). Keeping it to ONE trigger is what lets
  /// the result stay in Simple. The detected SSID is retained on
  /// [lastSuggestion] so the confirmation line can name the Wi-Fi too.
  Future<void> useCurrentNetwork() async {
    detecting = true;
    notifyListeners();
    NetworkState state;
    try {
      state = await _stateReader(requestSsid: true);
    } catch (_) {
      state = NetworkState.empty;
    }
    applySuggestion(suggestCurrentNetwork(state));
  }

  /// Apply an already-computed suggestion (also the seam tests drive). Fills a
  /// single subnet trigger (preferred) or, failing that, a single SSID
  /// trigger; nothing when neither was readable.
  @visibleForTesting
  void applySuggestion(CurrentNetworkSuggestion suggestion) {
    detecting = false;
    lastSuggestion = suggestion;
    if (suggestion.hasSubnet) {
      _replaceTriggers([TriggerDraft.subnet(suggestion.subnetCidr!)]);
    } else if (suggestion.hasSsid) {
      _replaceTriggers([TriggerDraft.ssid(suggestion.ssid!)]);
    }
    triggersError = null;
    markDirty();
  }

  void _replaceTriggers(List<TriggerDraft> next) {
    for (final t in triggers) {
      t.dispose();
    }
    triggers
      ..clear()
      ..addAll(next);
  }

  /// A new network for where this device is ([suggestion], from the
  /// Networks page's "Active now"): the Wi-Fi's name as its rule and its
  /// name where the Wi-Fi's name is known, else the subnet.
  void startFor(CurrentNetworkSuggestion suggestion) {
    lastSuggestion = suggestion;
    if (suggestion.hasSsid) {
      _replaceTriggers([TriggerDraft.ssid(suggestion.ssid!)]);
      if (nameController.text.trim().isEmpty) nameController.text = suggestion.ssid!;
    } else if (suggestion.hasSubnet) {
      _replaceTriggers([TriggerDraft.subnet(suggestion.subnetCidr!)]);
    }
    triggersError = null;
    markDirty();
  }

  /// Adds a rule with its value already set (the editor's quick chips: an IP
  /// range such as Tailscale's).
  void addSubnet(String cidr) {
    triggers.add(TriggerDraft.subnet(cidr));
    triggersError = null;
    markDirty();
  }

  /// Adds an "on this kind of connection" rule (Ethernet, a VPN).
  void addConnectivity(ConnectivityKind kind) {
    triggers.add(TriggerDraft.connectivity(kind));
    triggersError = null;
    markDirty();
  }

  // ── Build / validate ───────────────────────────────────────────

  /// Assemble the persistence model. [id] is the existing id or a freshly
  /// minted one. Fallback networks keep gray + a single AlwaysTrigger.
  Network buildNetwork(String id) {
    final fallback = isFallback;
    return Network(
      id: id,
      name: nameController.text.trim(),
      color: fallback ? GroupColor.gray : color,
      colorValue: fallback ? null : colorValue,
      icon: icon,
      triggers: fallback
          ? const [AlwaysTrigger()]
          : triggers.map((d) => d.toTrigger()).toList(growable: false),
      isFallback: fallback,
      bringUpVpn: bringUpVpn,
    );
  }

  String? validateName(AppLocalizations l10n) {
    final name = nameController.text.trim();
    if (name.isEmpty || name.length > 32) {
      return l10n.networkEditorNameRequired;
    }
    return null;
  }

  /// Non-fallback networks need at least one trigger, all valid.
  String? validateTriggers(AppLocalizations l10n) {
    if (isFallback) return null;
    if (triggers.isEmpty) return l10n.networkEditorAtLeastOneTrigger;
    for (final t in triggers) {
      final err = t.fieldError(l10n);
      if (err != null) return err;
    }
    return null;
  }

  void setErrors({String? name, String? triggers}) {
    nameError = name;
    triggersError = triggers;
    notifyListeners();
  }

  // ── Discard guard ──────────────────────────────────────────────

  /// The shared dirty guard the 1.7 spec wires into every leave-the-editor
  /// path (selecting another row, +New, nav-away). Returns true to PROCEED,
  /// false to ABORT. On "Save" it runs [onSave] and proceeds only if the save
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

  // ── Disposal ───────────────────────────────────────────────────

  void _disposeDrafts() {
    for (final t in triggers) {
      t.dispose();
    }
    for (final o in overrides) {
      o.dispose();
    }
  }

  @override
  void dispose() {
    _disposeDrafts();
    nameController.dispose();
    super.dispose();
  }
}
