/// Formats a measured round-trip latency for display.
///
/// A TCP round-trip to a host on the same LAN often completes in a few hundred
/// microseconds, which truncates to a whole-millisecond `0` and reads as if the
/// probe were broken. Render anything that fast as "<1" instead, so a real
/// sub-millisecond reading is never shown as a misleading "0". Callers append
/// their own unit ("ms" / " ms") so each keeps its existing spacing.
///
/// A null value (never probed) is shown as "?" so it can't be mistaken for a
/// real reading; callers that guard against null never hit that branch.
String latencyText(int? ms) => ms == null ? '?' : (ms <= 0 ? '<1' : '$ms');
