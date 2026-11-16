import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/sftp/sftp_pane_paths.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sftp_sessions_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/local_state_store.dart';

/// Key prefixes for the pin-suggestion counters (spec section 6), kept in the
/// encrypted database ([LocalStateStore]; the key names the host and the
/// folder). Device-local and cleared with the host's folder memory.
const String kSftpFolderVisitsPrefix = 'sftp_folder_visits:';
const String kSftpPinDeclinedPrefix = 'sftp_pin_declined:';

/// How many times the same folder must resolve on a host before the pane
/// offers to pin it (spec section 6). Offered once; declining is final.
const int kSftpPinSuggestionThreshold = 3;

/// "Forget last folder" (remember-last-folder spec, section 4): clears the
/// host default on the record (synced, so it clears everywhere), the live
/// pane state of every pane on that host, the in-session path memory of its
/// sessions, and the pin-suggestion counters. One action, all four places,
/// so nothing can quietly bring the folder back.
Future<void> forgetLastFolder(WidgetRef ref, String connectionId) async {
  await ref.read(connectionsDaoProvider).clearLastRemotePath(connectionId);
  ref.read(sftpPanePathsProvider.notifier).forgetHost(connectionId);

  final sessions = ref.read(activeSessionsProvider);
  final inSession = ref.read(lastSftpPathsProvider);
  for (final e in sessions.entries) {
    if (e.value.connectionId == connectionId) inSession.forget(e.key);
  }

  final store = ref.read(localStateStoreProvider);
  await store.removeWithPrefix('$kSftpFolderVisitsPrefix$connectionId:');
  await store.removeWithPrefix('$kSftpPinDeclinedPrefix$connectionId:');

  // Counters an older build kept in preferences.
  final prefs = ref.read(sharedPreferencesProvider);
  for (final k in prefs.getKeys().toList()) {
    if (k.startsWith('$kSftpFolderVisitsPrefix$connectionId:') ||
        k.startsWith('$kSftpPinDeclinedPrefix$connectionId:')) {
      await prefs.remove(k);
    }
  }
}
