import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/spaces.dart' show TreeSpace;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/local_shell_service.dart';

/// Whether this device has a shell of its own to open: a computer, or an
/// Android device. Not an iPhone or an iPad, whose sandbox lets no app start a
/// process ([LocalShellService.isAvailable]).
bool get localTerminalOnThisDevice => debugLocalTerminalOnThisDevice ?? LocalShellService.isAvailable;

/// A test's answer to [localTerminalOnThisDevice], for the platform it plays;
/// null, as always in the app, for the device's own.
@visibleForTesting
bool? debugLocalTerminalOnThisDevice;

/// The host a terminal on this device is opened as: made for the moment,
/// never saved, with an id of its own so each opens a fresh shell.
Connection localTerminalConnection(AppLocalizations l10n) {
  final now = DateTime.now();
  return Connection(
    id: 'local_${now.microsecondsSinceEpoch}',
    label: l10n.homeLocalShellLabel,
    host: 'localhost',
    port: 0,
    colorIndex: 0,
    protocol: 'localShell',
    zlibCompression: false,
    forwardAgent: false,
    compatibilityMode: false,
    keepAliveSeconds: 0,
    envVars: '',
    sortOrder: 0,
    sizeTier: 1,
    pinned: false,
    monitored: false,
    createdAt: now,
    updatedAt: now,
  );
}

/// Opens a terminal on this device (a computer's own shell, or Android's): a
/// host made for the moment ([localTerminalConnection]). It is the person's
/// own whichever space is on screen: nothing of it goes to a team's log, and a
/// team's host could not open one. The new session's id, or null where the
/// free plan's limit of open sessions is reached.
String? openLocalTerminal(WidgetRef ref, AppLocalizations l10n) => openLocalTerminalWith(ref.read, l10n);

/// [openLocalTerminal] with a provider reader of its own ([read]), for a
/// caller whose widget may be gone by the time it opens one (a snippet's run,
/// after its questions).
String? openLocalTerminalWith(T Function<T>(ProviderListenable<T> provider) read, AppLocalizations l10n) =>
    read(activeSessionsProvider.notifier).startSession(localTerminalConnection(l10n), space: const TreeSpace());
