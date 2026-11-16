import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Per-host override that mutates the effective connection config when a
/// specific network matches.
///
/// Each field is nullable: missing means "fall through to the base host
/// config." `skipHost` short-circuits everything else - when true, the
/// resolver throws `HostUnreachableException` instead of building a
/// connection.
@immutable
class HostNetworkOverride {
  const HostNetworkOverride({
    required this.id,
    required this.hostId,
    required this.networkId,
    this.address,
    this.port,
    this.username,
    this.identityKeyId,
    this.jumpHostId,
    this.jumpHostChain,
    this.skipHost,
  }) : assert(
          jumpHostId == null || jumpHostChain == null,
          'jumpHostId and jumpHostChain are mutually exclusive - '
          'use one or the other.',
        );

  /// Stable id (uuid). Used as the primary key in storage so we can update
  /// in place.
  final String id;

  /// FK to the host's connection id.
  final String hostId;

  /// FK to the network id.
  final String networkId;

  /// Override the hostname or IP. Null = inherit from base host.
  final String? address;

  /// Override the port. Null = inherit.
  final int? port;

  /// Override the SSH username. Null = inherit.
  final String? username;

  /// Override the identity (key) id. Null = inherit.
  final String? identityKeyId;

  /// Single jump host id, OR a chain. Use one or the other, not both -
  /// the constructor asserts mutual exclusion in debug builds.
  ///
  /// An explicit empty list (not null) on [jumpHostChain] means "no jump
  /// host" and overrides any base config.
  final String? jumpHostId;
  final List<String>? jumpHostChain;

  /// If true, this host is unreachable from this network.
  final bool? skipHost;

  HostNetworkOverride copyWith({
    String? id,
    String? hostId,
    String? networkId,
    Object? address = _sentinel,
    Object? port = _sentinel,
    Object? username = _sentinel,
    Object? identityKeyId = _sentinel,
    Object? jumpHostId = _sentinel,
    Object? jumpHostChain = _sentinel,
    Object? skipHost = _sentinel,
  }) {
    return HostNetworkOverride(
      id: id ?? this.id,
      hostId: hostId ?? this.hostId,
      networkId: networkId ?? this.networkId,
      address: address == _sentinel ? this.address : address as String?,
      port: port == _sentinel ? this.port : port as int?,
      username: username == _sentinel ? this.username : username as String?,
      identityKeyId: identityKeyId == _sentinel
          ? this.identityKeyId
          : identityKeyId as String?,
      jumpHostId: jumpHostId == _sentinel
          ? this.jumpHostId
          : jumpHostId as String?,
      jumpHostChain: jumpHostChain == _sentinel
          ? this.jumpHostChain
          : jumpHostChain as List<String>?,
      skipHost: skipHost == _sentinel ? this.skipHost : skipHost as bool?,
    );
  }

  /// True if this override has no actionable fields set - i.e. it would
  /// behave identically to the absence of an override. The UI uses this
  /// to decide whether to delete the row when the user collapses it.
  bool get isEmpty {
    return address == null &&
        port == null &&
        username == null &&
        identityKeyId == null &&
        jumpHostId == null &&
        jumpHostChain == null &&
        (skipHost == null || skipHost == false);
  }

  /// Encode the optional jump chain as JSON (or null). Storage layer.
  String? jumpHostChainJson() {
    if (jumpHostChain == null) return null;
    return jsonEncode(jumpHostChain);
  }

  /// Decode the optional jump chain JSON. Returns null on bad input
  /// rather than throwing - a corrupt single override row should not
  /// poison the entire host's load path.
  static List<String>? parseJumpHostChainJson(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return null;
      return decoded.whereType<String>().toList();
    } catch (_) {
      return null;
    }
  }
}

const Object _sentinel = Object();
