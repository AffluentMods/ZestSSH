import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../core/theme/group_color.dart';
import 'network_trigger.dart';

/// Stable id used for the system Default fallback network.
///
/// Persisted in storage and referenced by host overrides - never change
/// this string. If you do, every existing user's overrides become orphans.
const String kDefaultNetworkId = 'system_default';

/// A user-defined network is a named environment with a list of triggers
/// and a precedence position in the evaluation order.
///
/// The list is evaluated top to bottom; first match wins. The Default
/// network is pinned to the bottom and always matches via [AlwaysTrigger].
@immutable
class Network {
  const Network({
    required this.id,
    required this.name,
    required this.color,
    required this.icon,
    required this.triggers,
    required this.isFallback,
    this.colorValue,
    this.bringUpVpn,
  });

  /// Stable id used in storage and host overrides. Never change after
  /// the network is created.
  final String id;

  /// Display name. Editable; capped to 32 chars at the editor layer.
  final String name;

  /// User-pickable color token (also used for Default which always uses
  /// [GroupColor.gray]).
  final GroupColor color;

  /// Optional custom accent colour as an ARGB int (from `Color.toARGB32()`).
  /// When non-null it OVERRIDES [color], letting the user persist any colour;
  /// null falls back to the [color] token. See [effectiveColor].
  final int? colorValue;

  /// The concrete accent colour to draw: a custom [colorValue] wins, otherwise
  /// the [color] token's value. Single source of truth for every network draw
  /// site so a custom colour shows up consistently.
  Color get effectiveColor =>
      colorValue != null ? Color(colorValue!) : color.value;

  /// Lucide or Material icon. Persisted via codePoint + fontFamily +
  /// fontPackage so we can reconstruct the exact same `IconData`.
  final IconData icon;

  /// Triggers are OR'd. An empty list means "never matches" - the editor
  /// blocks save in that state for non-Default networks.
  final List<NetworkTrigger> triggers;

  /// True only for the system Default network. Cannot be deleted, always
  /// last in evaluation order, has a single [AlwaysTrigger].
  final bool isFallback;

  /// Optional: bring up a VPN host (by host id) before any host
  /// overrides on this network are applied. Used for Headscale-style
  /// auto-bring-up.
  final String? bringUpVpn;

  Network copyWith({
    String? id,
    String? name,
    GroupColor? color,
    Object? colorValue = _sentinel,
    IconData? icon,
    List<NetworkTrigger>? triggers,
    bool? isFallback,
    Object? bringUpVpn = _sentinel,
  }) {
    return Network(
      id: id ?? this.id,
      name: name ?? this.name,
      color: color ?? this.color,
      colorValue:
          colorValue == _sentinel ? this.colorValue : colorValue as int?,
      icon: icon ?? this.icon,
      triggers: triggers ?? this.triggers,
      isFallback: isFallback ?? this.isFallback,
      bringUpVpn:
          bringUpVpn == _sentinel ? this.bringUpVpn : bringUpVpn as String?,
    );
  }

  /// Build the Default fallback network. Centralised so [NetworkRepository]
  /// and migration can share the same definition.
  factory Network.systemDefault({String name = 'Default'}) {
    return Network(
      id: kDefaultNetworkId,
      name: name,
      color: GroupColor.gray,
      icon: LucideIcons.globe,
      triggers: const [AlwaysTrigger()],
      isFallback: true,
    );
  }

  /// Encode `triggers` as a JSON string for storage in a single TEXT column.
  ///
  /// Kept as a method (not a field) so we don't redundantly hold both
  /// the structured list and its serialised form in memory.
  String triggersJson() =>
      jsonEncode(triggers.map((t) => t.toJson()).toList());

  /// Decode a JSON string previously produced by [triggersJson]. Tolerates
  /// malformed input - returns an empty list rather than throwing so a
  /// single corrupt row doesn't blow up the networks page.
  static List<NetworkTrigger> parseTriggersJson(String? json) {
    if (json == null || json.isEmpty) return const [];
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map(NetworkTrigger.fromJson)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Which Simple-mode invariant (if any) this network violates - the 1.7
  /// §1 rule that "Simple is DISABLED (not hidden) when the object outgrows
  /// it." Returns the FIRST blocking reason in priority order, or null when
  /// the network still fits Simple.
  ///
  /// This is deliberately PURE and l10n-free: it reports the *reason code*,
  /// and the editor controller (which owns localization + BuildContext) maps
  /// it to the pre-seeded `zestNetworkSimpleBlocked*` strings. Keeping the
  /// domain model free of `AppLocalizations` is intentional - the decision is
  /// centralized here, the wording lives at the UI edge.
  ///
  /// The override facts ([hasHostOverrides] / [hasHostJumpChain]) live outside
  /// the [Network] row (they are per-host [HostNetworkOverride] rows keyed by
  /// this network's id), so the caller supplies them. Ordering: more triggers
  /// than Simple can edit wins first; then a jump-host chain (the most
  /// specific override reason); then any other host override.
  SimpleModeBlock? simpleModeBlock({
    required bool hasHostOverrides,
    required bool hasHostJumpChain,
  }) {
    // The fallback network's single AlwaysTrigger is not a user-editable
    // trigger, so it never counts toward the "more than one" limit.
    final editableTriggers =
        triggers.where((t) => t is! AlwaysTrigger).length;
    if (editableTriggers > 1) return SimpleModeBlock.multipleTriggers;
    if (hasHostJumpChain) return SimpleModeBlock.jumpHostChain;
    if (hasHostOverrides) return SimpleModeBlock.hostOverrides;
    return null;
  }
}

/// The reasons a [Network] can outgrow the Simple editor (1.7 §1 invariant 2).
/// Pure reason codes - the controller localizes them to the pre-seeded
/// `zestNetworkSimpleBlocked{Triggers,Overrides,JumpHost}` strings.
enum SimpleModeBlock { multipleTriggers, hostOverrides, jumpHostChain }

/// Sentinel for `copyWith` to distinguish "leave unchanged" from
/// "explicitly set to null". Has to be top-level (not a static const inside
/// the class) because Dart const-evaluation doesn't permit referencing
/// `Network._sentinel` inside the parameter default of a method on the
/// same class.
const Object _sentinel = Object();
