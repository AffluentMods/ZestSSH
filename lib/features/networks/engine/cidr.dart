import 'package:flutter/foundation.dart';

/// Lightweight CIDR matcher. Handles IPv4, IPv6, and v4-mapped v6
/// (`::ffff:192.0.2.1/96` and friends).
///
/// Deliberately does not pull a package: the spec requires it ("write a
/// small one rather than pulling a package") and the rules are simple
/// enough to inline.
@immutable
class Cidr {
  const Cidr._(this._network, this._prefixLength, this._isV4);

  final List<int> _network; // bytes (4 for v4, 16 for v6)
  final int _prefixLength;
  final bool _isV4;

  /// Parse a CIDR string. Returns null on any kind of malformed input
  /// rather than throwing - the editor uses null as the "show inline
  /// error" signal.
  static Cidr? tryParse(String input) {
    final slash = input.indexOf('/');
    if (slash == -1) return null;
    final addr = input.substring(0, slash);
    final prefix = int.tryParse(input.substring(slash + 1));
    if (prefix == null) return null;

    final v4Bytes = _parseIPv4(addr);
    if (v4Bytes != null) {
      if (prefix < 0 || prefix > 32) return null;
      return Cidr._(v4Bytes, prefix, true);
    }
    final v6Bytes = _parseIPv6(addr);
    if (v6Bytes != null) {
      if (prefix < 0 || prefix > 128) return null;
      return Cidr._(v6Bytes, prefix, false);
    }
    return null;
  }

  /// True if [ip] falls inside this CIDR. Type mismatches (passing a v4
  /// address to a v6 CIDR or vice versa) return false rather than throw.
  bool contains(String ip) {
    final List<int>? bytes = _isV4 ? _parseIPv4(ip) : _parseIPv6(ip);
    if (bytes == null) return false;
    return _containsBytes(bytes);
  }

  /// True if this CIDR fully contains [other] - every address in [other] also
  /// falls inside this range. Requires the same address family and [other] to
  /// be equal-or-more-specific (a longer/equal prefix). Drives the shadowing
  /// ("never matches") analysis: a broader subnet trigger positioned earlier in
  /// evaluation order always wins over a narrower one below it.
  bool containsCidr(Cidr other) {
    if (_isV4 != other._isV4) return false;
    // A broader-or-equal prefix cannot contain a strictly broader one.
    if (other._prefixLength < _prefixLength) return false;
    return _containsBytes(other._network);
  }

  /// Shared prefix-mask comparison used by [contains] and [containsCidr].
  bool _containsBytes(List<int> bytes) {
    if (bytes.length != _network.length) return false;
    var bitsLeft = _prefixLength;
    for (var i = 0; i < _network.length && bitsLeft > 0; i++) {
      final take = bitsLeft >= 8 ? 8 : bitsLeft;
      final mask = take == 8 ? 0xFF : (0xFF << (8 - take)) & 0xFF;
      if ((_network[i] & mask) != (bytes[i] & mask)) return false;
      bitsLeft -= take;
    }
    return true;
  }

  /// True if this CIDR is the catch-all `0.0.0.0/0` or `::/0`.
  bool get isWildcard => _prefixLength == 0;

  /// Re-emit the parsed CIDR as canonical text. Useful in tests and
  /// debug output. Note: address bytes are emitted as-is (we do not
  /// zero out host bits), matching what the user typed.
  @override
  String toString() {
    if (_isV4) {
      return '${_network.join(".")}/$_prefixLength';
    }
    // Compress to canonical IPv6 form (longest run of zeros → ::).
    final groups = <String>[];
    for (var i = 0; i < 16; i += 2) {
      final word = (_network[i] << 8) | _network[i + 1];
      groups.add(word.toRadixString(16));
    }
    return '${_compressV6(groups)}/$_prefixLength';
  }

  // ── IPv4 parsing ────────────────────────────────────────────────

  static List<int>? _parseIPv4(String s) {
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

  // ── IPv6 parsing with full :: expansion + v4-mapped support ─────

  /// Parse an IPv6 address. Returns 16 bytes, or null on parse failure.
  ///
  /// Supports:
  ///   - shorthand `::` (one occurrence max)
  ///   - mixed v4-mapped notation like `::ffff:192.0.2.1`
  ///   - bare `::` meaning all-zero address
  static List<int>? _parseIPv6(String s) {
    if (s.isEmpty) return null;

    // Strip optional zone id (e.g. fe80::1%eth0). We don't match against
    // zones so just drop them.
    final percent = s.indexOf('%');
    if (percent != -1) s = s.substring(0, percent);

    // Detect double-colon (`::`) shorthand. At most one is allowed.
    final dcIdx = s.indexOf('::');
    if (dcIdx != s.lastIndexOf('::')) return null;

    String head;
    String tail;
    if (dcIdx == -1) {
      head = s;
      tail = '';
    } else {
      head = s.substring(0, dcIdx);
      tail = s.substring(dcIdx + 2);
    }

    final headParts = head.isEmpty ? <String>[] : head.split(':');
    final tailParts = tail.isEmpty ? <String>[] : tail.split(':');

    // Empty groups (`::ffff:1::2` → ['','ffff','1'] etc.) are illegal.
    if (headParts.contains('')) return null;
    if (tailParts.contains('')) return null;

    // Detect a trailing v4 fragment (e.g. last "part" is a dotted-quad).
    int trailingV4Bytes = 0;
    List<int>? v4Tail;
    final lastPartList = tailParts.isNotEmpty ? tailParts : headParts;
    if (lastPartList.isNotEmpty && lastPartList.last.contains('.')) {
      final v4 = _parseIPv4(lastPartList.last);
      if (v4 == null) return null;
      v4Tail = v4;
      lastPartList.removeLast();
      trailingV4Bytes = 4;
    }

    final bytes = <int>[];
    for (final part in headParts) {
      final word = _parseV6Group(part);
      if (word == null) return null;
      bytes.add((word >> 8) & 0xFF);
      bytes.add(word & 0xFF);
    }
    final tailBytes = <int>[];
    for (final part in tailParts) {
      final word = _parseV6Group(part);
      if (word == null) return null;
      tailBytes.add((word >> 8) & 0xFF);
      tailBytes.add(word & 0xFF);
    }

    // Pad zeros into the gap left by `::`.
    final usedBytes = bytes.length + tailBytes.length + trailingV4Bytes;
    if (usedBytes > 16) return null;
    final padBytes = 16 - usedBytes;
    if (dcIdx == -1 && padBytes != 0) return null; // no shorthand; must be exact

    final result = [
      ...bytes,
      ...List.filled(padBytes, 0),
      ...tailBytes,
      ...?v4Tail,
    ];

    if (result.length != 16) return null;
    return result;
  }

  static int? _parseV6Group(String s) {
    if (s.isEmpty || s.length > 4) return null;
    final n = int.tryParse(s, radix: 16);
    if (n == null || n < 0 || n > 0xFFFF) return null;
    return n;
  }

  /// Compress a list of 8 lowercase hex group strings into canonical
  /// IPv6 form, replacing the longest run of consecutive `"0"` groups
  /// with `::`.
  static String _compressV6(List<String> groups) {
    var bestStart = -1;
    var bestLen = 0;
    var i = 0;
    while (i < groups.length) {
      if (groups[i] == '0') {
        var j = i;
        while (j < groups.length && groups[j] == '0') {
          j++;
        }
        final len = j - i;
        if (len > bestLen) {
          bestStart = i;
          bestLen = len;
        }
        i = j;
      } else {
        i++;
      }
    }
    if (bestLen < 2) return groups.join(':');
    final left = groups.sublist(0, bestStart).join(':');
    final right = groups.sublist(bestStart + bestLen).join(':');
    return '$left::$right';
  }
}
