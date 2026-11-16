import 'package:flutter/semantics.dart' show Assertiveness;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart' show zestAnnounce;

/// Says to a screen reader when the session [sessionId] comes up and when it
/// drops (4.0 accessibility pass): "Connected to web-01" once it connects,
/// "web-01 disconnected" when a connected session ends without its person
/// ending it (ended by its person, it leaves the list and nothing is said).
/// A connection that never came up is said by what shows its failure
/// (ConnectionErrorView, the failure's dialog), so it is not said here
/// again. Nothing while [speaks] says no: a pane of a split not in front.
///
/// Called from a build, as [WidgetRef.listen] is.
void listenSessionChanges(WidgetRef ref, BuildContext context, String sessionId, {bool Function()? speaks}) {
  ref.listen<SessionStatus?>(activeSessionsProvider.select((m) => m[sessionId]?.status), (was, now) {
    if (was == null || now == null || was == now || !(speaks?.call() ?? true) || !context.mounted) return;
    final s = ref.read(activeSessionsProvider)[sessionId];
    if (s == null) return;
    final l10n = AppLocalizations.of(context)!;
    final name = Redactable.host(s.connectionLabel).display;
    if (now == SessionStatus.connected && was == SessionStatus.connecting) {
      zestAnnounce(context, l10n.a11ySessionConnected(name));
    } else if (was == SessionStatus.connected && (now == SessionStatus.disconnected || now == SessionStatus.error)) {
      zestAnnounce(context, l10n.a11ySessionDropped(name), assertiveness: Assertiveness.assertive);
    }
  });
}
