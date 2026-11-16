import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart' show isAppLockedProvider;
import 'package:zestssh/services/shortcut_service.dart';

/// The hosts on the app icon's shortcuts (Android's app shortcuts, an iPad's
/// and an iPhone's quick actions), the last used first: kept up to date while
/// Home is on screen, whichever Home it is (the phone's tabs or, on a large
/// screen, the computer's shell). A Squeezed feature: without it there are
/// none. Call from a build.
void keepAppIconShortcuts(WidgetRef ref) {
  final isPro = ref.watch(isProProvider);
  ref.listen(connectionsWithDetailsProvider, (_, next) {
    if (!isPro) {
      ShortcutService.clearShortcuts();
      return;
    }
    next.whenData((connections) {
      final sorted = [...connections]
        ..sort((a, b) {
          final aTime = a.connection.lastConnected;
          final bTime = b.connection.lastConnected;
          if (aTime == null && bTime == null) return 0;
          if (aTime == null) return 1;
          if (bTime == null) return -1;
          return bTime.compareTo(aTime);
        });
      ShortcutService.updateShortcuts(sorted.map((c) => c.connection).toList());
    });
  });
}

/// The host of a shortcut picked from the app icon, once the app is open and
/// its hosts are loaded, given to [connect] (as a tap on it in the list);
/// nothing while there is none, or while the app is locked or its hosts are
/// still loading (asked again then).
void connectAppIconShortcut(WidgetRef ref, void Function(ConnectionWithDetails item) connect) {
  if (ShortcutService.pendingConnection.value == null || ref.read(isAppLockedProvider)) return;
  final connections = ref.read(connectionsWithDetailsProvider).valueOrNull;
  if (connections == null) return;
  final id = ShortcutService.consumePendingConnectionId();
  final match = connections.where((c) => c.connection.id == id).firstOrNull;
  if (match != null) connect(match);
}
