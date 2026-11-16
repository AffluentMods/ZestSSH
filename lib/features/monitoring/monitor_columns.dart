import 'dart:convert';

import 'package:zestssh/features/monitoring/monitor_thresholds.dart';

/// The chooser-managed metric columns of the desktop Server-Monitor table
/// The Host / Status / "Last 24 checks" / Checked columns are
/// FIXED (always shown, never in the chooser); everything here can be reordered
/// and toggled, with the choice persisted device-locally.
///
/// CPU / RAM / Swap / Disk are percentage gauges (track + threshold tick, and
/// drag-to-override); Load / Temp / Ping / Uptime / Updates are value-only.
/// Temp / Network / Disk I/O are available but OFF by default.
enum MonitorColumn {
  cpu,
  ram,
  swap,
  disk,
  load,
  temp,
  ping,
  uptime,
  network,
  diskIo,
  updates,
}

extension MonitorColumnInfo on MonitorColumn {
  /// Stable persistence key (never localized).
  String get key => name;

  /// A percentage gauge column that renders a track + threshold tick and
  /// supports drag-to-override (spec §3 / §4).
  bool get isPercentGauge =>
      this == MonitorColumn.cpu ||
      this == MonitorColumn.ram ||
      this == MonitorColumn.swap ||
      this == MonitorColumn.disk;

  /// The scored [MonitorMetric] this column maps to, or null for value-only
  /// columns that have no threshold model (load / uptime / network / diskIo /
  /// updates). Temp and Ping map to temp / latency so their VALUE can be tinted
  /// by severity even though they render without a track.
  MonitorMetric? get metric => switch (this) {
        MonitorColumn.cpu => MonitorMetric.cpu,
        MonitorColumn.ram => MonitorMetric.ram,
        MonitorColumn.swap => MonitorMetric.swap,
        MonitorColumn.disk => MonitorMetric.disk,
        MonitorColumn.temp => MonitorMetric.temp,
        MonitorColumn.ping => MonitorMetric.latency,
        _ => null,
      };

  /// Column pixel width in the fixed-layout, horizontally-scrolling table.
  double get width => switch (this) {
        MonitorColumn.cpu ||
        MonitorColumn.ram ||
        MonitorColumn.swap ||
        MonitorColumn.disk =>
          88,
        MonitorColumn.load ||
        MonitorColumn.temp ||
        MonitorColumn.ping ||
        MonitorColumn.uptime =>
          64,
        MonitorColumn.network || MonitorColumn.diskIo => 118,
        MonitorColumn.updates => 84,
      };
}

/// Default left-to-right order of the metric columns (matches the chooser
/// order: the eight visible columns first, then the three off-by-default
/// ones).
const List<MonitorColumn> kDefaultColumnOrder = [
  MonitorColumn.cpu,
  MonitorColumn.ram,
  MonitorColumn.swap,
  MonitorColumn.disk,
  MonitorColumn.load,
  MonitorColumn.temp,
  MonitorColumn.ping,
  MonitorColumn.uptime,
  MonitorColumn.network,
  MonitorColumn.diskIo,
  MonitorColumn.updates,
];

/// Columns visible out of the box:
/// CPU, RAM, Swap, Disk, Load, Ping, Up and Updates. Temp, Network
/// and Disk I/O are OFF (§2): few hosts report a temperature.
const Set<MonitorColumn> kDefaultVisibleColumns = {
  MonitorColumn.cpu,
  MonitorColumn.ram,
  MonitorColumn.swap,
  MonitorColumn.disk,
  MonitorColumn.load,
  MonitorColumn.ping,
  MonitorColumn.uptime,
  MonitorColumn.updates,
};

/// Persisted column layout: the full metric-column order plus which are
/// visible. Immutable; edits go through [reorder] / [toggle].
class MonitorColumnConfig {
  final List<MonitorColumn> order;
  final Set<MonitorColumn> visible;

  const MonitorColumnConfig({required this.order, required this.visible});

  static const MonitorColumnConfig defaults = MonitorColumnConfig(
    order: kDefaultColumnOrder,
    visible: kDefaultVisibleColumns,
  );

  /// The visible metric columns, in the persisted order (drives the table).
  List<MonitorColumn> get visibleInOrder =>
      order.where(visible.contains).toList();

  MonitorColumnConfig toggle(MonitorColumn c, bool on) {
    final next = {...visible};
    if (on) {
      next.add(c);
    } else {
      next.remove(c);
    }
    return MonitorColumnConfig(order: order, visible: next);
  }

  /// Move the column at [oldIndex] to [newIndex] within [order] (ReorderableList
  /// semantics).
  MonitorColumnConfig reorder(int oldIndex, int newIndex) {
    final next = [...order];
    if (oldIndex < 0 || oldIndex >= next.length) return this;
    var target = newIndex;
    if (target > oldIndex) target -= 1;
    target = target.clamp(0, next.length - 1);
    final item = next.removeAt(oldIndex);
    next.insert(target, item);
    return MonitorColumnConfig(order: next, visible: visible);
  }

  Map<String, dynamic> toJson() => {
        'order': order.map((c) => c.key).toList(),
        'visible': visible.map((c) => c.key).toList(),
      };

  /// Decode, then MERGE with the defaults so a metric column added in a newer
  /// build (absent from an older persisted blob) still appears - appended in its
  /// default position, hidden unless it is a default-visible column.
  factory MonitorColumnConfig.fromJson(Map<String, dynamic> j) {
    MonitorColumn? parse(Object? raw) {
      for (final c in MonitorColumn.values) {
        if (c.key == raw) return c;
      }
      return null;
    }

    final rawOrder = (j['order'] as List?)?.map(parse).whereType<MonitorColumn>();
    final order = <MonitorColumn>[...?rawOrder];
    for (final c in kDefaultColumnOrder) {
      if (!order.contains(c)) order.add(c);
    }
    final rawVisible =
        (j['visible'] as List?)?.map(parse).whereType<MonitorColumn>();
    final visible = <MonitorColumn>{...?rawVisible};
    return MonitorColumnConfig(order: order, visible: visible);
  }

  String encode() => jsonEncode(toJson());

  static MonitorColumnConfig decode(String? raw) {
    if (raw == null || raw.isEmpty) return defaults;
    try {
      final j = jsonDecode(raw);
      if (j is Map<String, dynamic>) return MonitorColumnConfig.fromJson(j);
    } catch (_) {
      // Corrupt blob → fall back to defaults; the next write heals it.
    }
    return defaults;
  }
}
