import 'dart:convert';

import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/utils/host_address.dart';

/// Changes to team-pinned host keys that each member is told of (3.0):
/// a pin replaced with another key, or removed. A replaced pin means
/// every device now trusts a different key for that host; a removed one
/// means each device decides on its own again.
enum HostKeyNoticeKind { replaced, removed }

class HostKeyNotice {
  const HostKeyNotice(this.kind, {required this.id, required this.host, required this.port, this.by});

  final HostKeyNoticeKind kind;

  /// The pin.
  final String id;
  final String host;
  final int port;

  /// Who replaced it (as the Crate has the version); null for a removal.
  final String? by;
}

/// Where an Orchard's own database keeps the pins as its person last heard
/// of them: pin id -> {k: keys, h: host, p: port}.
const _seenKey = 'hostkeys.seen';

Future<Map<String, Object?>> _pins(AppDatabase db) async => {
      for (final r in await db
          .customSelect('SELECT t.id, t.host, t.port, t.host_keys, m.author FROM team_host_keys t '
              "LEFT JOIN crate_items_meta m ON m.kind = 'hostkey' AND m.item_key = t.id")
          .get())
        r.read<String>('id'): {
          'k': r.read<String>('host_keys'),
          'h': r.read<String>('host'),
          'p': r.read<int>('port'),
          'a': r.read<String?>('author'),
        },
    };

/// The pins in [db] replaced or removed since this device last looked,
/// counted as heard of from now on. The first look notes where things stand
/// and says nothing (what came before is the team's history). Changes [me]
/// made are not repeated back.
Future<List<HostKeyNotice>> takeHostKeyNotices(AppDatabase db, {String? me}) async {
  final store = LocalStateStore(db);
  final now = await _pins(db);
  final raw = await store.read(_seenKey);
  await store.write(_seenKey, jsonEncode({for (final e in now.entries) e.key: _seen(e.value)}));
  if (raw == null) return const [];
  Map<String, dynamic> seen;
  try {
    seen = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return const [];
  }
  final out = <HostKeyNotice>[];
  for (final e in now.entries) {
    final pin = e.value! as Map<String, Object?>;
    final before = seen[e.key];
    if (before is! Map<String, dynamic> || before['k'] == pin['k']) continue;
    final by = pin['a'] as String?;
    if (by != null && by == me) continue;
    out.add(HostKeyNotice(HostKeyNoticeKind.replaced,
        id: e.key, host: pin['h']! as String, port: pin['p']! as int, by: by));
  }
  for (final e in seen.entries) {
    if (now.containsKey(e.key) || e.value is! Map<String, dynamic>) continue;
    final before = e.value as Map<String, dynamic>;
    out.add(HostKeyNotice(HostKeyNoticeKind.removed,
        id: e.key, host: '${before['h'] ?? ''}', port: before['p'] is int ? before['p'] as int : 22));
  }
  return out;
}

Map<String, Object?> _seen(Object? pin) {
  final p = pin! as Map<String, Object?>;
  return {'k': p['k'], 'h': p['h'], 'p': p['p']};
}

/// Notes that this device's person made the pin [id] what it is now (or
/// removed it), so it is not told of it again.
Future<void> markHostKeySeen(AppDatabase db, String id) async {
  final store = LocalStateStore(db);
  final raw = await store.read(_seenKey);
  if (raw == null) return; // nothing noted yet: the first look will note it
  Map<String, dynamic> seen;
  try {
    seen = jsonDecode(raw) as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final now = await _pins(db);
  if (now.containsKey(id)) {
    seen[id] = _seen(now[id]);
  } else {
    seen.remove(id);
  }
  await store.write(_seenKey, jsonEncode(seen));
}

/// [n] as the notification this device shows, in [orchard] (its name), with
/// people named by [nameOf]. A security change, so it stays until read.
AppNotification hostKeyNoticeNotification(
  HostKeyNotice n, {
  required String orchardId,
  required String orchard,
  required String Function(String? uid) nameOf,
  required AppLocalizations l10n,
}) {
  final target = Redactable.address(hostWithPort(n.host, n.port)).display;
  final (title, body) = switch (n.kind) {
    HostKeyNoticeKind.replaced => (
        l10n.noticeHostKeyReplacedTitle(target, orchard),
        l10n.noticeHostKeyReplacedBody(n.by == null ? l10n.noticeSomeone : nameOf(n.by)),
      ),
    HostKeyNoticeKind.removed => (l10n.noticeHostKeyRemovedTitle(target, orchard), l10n.noticeHostKeyRemovedBody),
  };
  return AppNotification(
    id: 'orchard-hostkey-$orchardId-${n.id}-${n.kind.name}-${DateTime.now().millisecondsSinceEpoch}',
    title: title,
    body: body,
    severity: NotificationSeverity.warning,
  );
}
