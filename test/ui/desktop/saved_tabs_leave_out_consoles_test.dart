import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/local_state_store.dart';
import 'package:zestssh/services/session_persistence_service.dart';
import 'package:zestssh/ui/screens/desktop/app_closing.dart';

/// Sessions the test names as an X program's or a Proxmox console's.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref);

  final xPrograms = <String>{};
  final consoles = <String>{};

  @override
  bool isXProgram(String sessionId) => xPrograms.contains(sessionId);

  @override
  bool isConsole(String sessionId) => consoles.contains(sessionId);
}

/// The tabs saved for the next start leave out what cannot be brought back as
/// it was: an X program's tab and a Proxmox console's. Both are sessions of a
/// host's own id, so saved under that id they came back as the host's SSH
/// terminal: a console tab open at the close opened a terminal to the machine
/// at the next start. Made-up hosts.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  testWidgets('a connected terminal is saved; an X program and a Proxmox console are not', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final store = LocalStateStore(db);
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        databaseProvider.overrideWithValue(db),
        localStateStoreProvider.overrideWithValue(store),
        activeSessionsProvider.overrideWith(_Sessions.new),
      ],
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));
    final sessions = ref.read(activeSessionsProvider.notifier) as _Sessions;
    sessions.xPrograms.add('s-x');
    sessions.consoles.add('s-console');
    SessionState open(String connectionId, String label) =>
        SessionState(status: SessionStatus.connected, connectionId: connectionId, connectionLabel: label);

    await tester.runAsync(() => saveOpenTabs(ref, {
          's-web': open('c-web', 'web-01'),
          's-x': open('c-web', 'xterm on web-01'),
          's-console': open('c-vm', 'vm-104'),
        }));

    final saved = await tester.runAsync(() => SessionPersistenceService(prefs, store).loadSavedSessions());
    expect(saved!.map((s) => s.connectionId), ['c-web'],
        reason: 'the terminal alone: the console of c-vm would come back as an SSH terminal to it');
    expect(saved.single.label, 'web-01');
  });
}
