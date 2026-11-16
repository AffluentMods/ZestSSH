import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/utils/logger.dart';

Future<void> autoSaveLastSession(WidgetRef ref) async {
  try {
    final sessions = ref.read(activeSessionsProvider);
    final connectedIds = sessions.entries
        .where((e) => e.value.status == SessionStatus.connected)
        .map((e) => e.key)
        .toList();
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setStringList('lastOpenSessions', connectedIds);
  } catch (e) {
    AppLogger.error('Failed to auto-save session state', e);
  }
}
