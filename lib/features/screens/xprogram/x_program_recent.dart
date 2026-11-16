// The X programs opened lately on each SSH host, on this device (4.0):
// newest first, at most [XProgramRecent.max], kept in the encrypted
// database's local state (never synced, never in a backup), not in plain
// preferences: a command line can name paths and servers, as the restored
// tab snapshot does.
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/screens/xprogram/x_program_script.dart';
import 'package:zestssh/services/local_state_store.dart';

class XProgramRecent {
  XProgramRecent(this._store);

  final LocalStateStore _store;

  /// The local state key of a host's list: this and the host's id.
  static const prefix = 'xprogram_recent.';

  /// How many are kept for a host.
  static const max = 8;

  /// [hostId]'s recent programs, newest first; what is not a program line
  /// (a damaged value) is left out.
  Future<List<String>> of(String hostId) async {
    final raw = await _store.read('$prefix$hostId');
    if (raw == null) return const [];
    try {
      final list = jsonDecode(raw);
      if (list is! List) return const [];
      return [
        for (final p in list)
          if (p is String && xProgramProblem(p) == null) p,
      ].take(max).toList();
    } on FormatException {
      return const [];
    }
  }

  /// [program] opened on [hostId]: first in its list, once.
  Future<void> used(String hostId, String program) async {
    final now = [program, for (final p in await of(hostId)) if (p != program) p].take(max).toList();
    await _store.write('$prefix$hostId', jsonEncode(now));
  }

  /// [hostId]'s list forgotten.
  Future<void> forget(String hostId) => _store.remove('$prefix$hostId');
}

final xProgramRecentProvider = Provider<XProgramRecent>((ref) => XProgramRecent(ref.watch(localStateStoreProvider)));
