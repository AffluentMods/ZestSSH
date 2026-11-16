import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/models/saved_tab_group.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// Keeps the [Redactor]'s visible set current.
///
/// Fixed-width name masks collide (`app-server-01` and `app-router-01` are
/// both `ap00001`), and the only way to resolve a collision with a stable
/// counter is to know the whole fleet up front (spec 3c). This provider
/// listens to every source of identifying values that can render and
/// registers them by KIND: host labels, group names, workspace names, network
/// profile names and the Wi-Fi SSIDs their triggers match on go through the
/// name rule; host addresses through the address rule (so a bare `db-primary.local`
/// embedded in free text is masked as an address, not as a name). Usernames
/// are not registered with the Redactor: a bare username is indistinguishable
/// from a word on screen, and `user@host` is already caught by the free-text
/// scan. They are given to [ReportScrub], with the hosts, for what leaves the
/// app in a report (3.4 security review).
///
/// It returns nothing and is instantiated once from [recordingModeProvider],
/// which every recording-mode surface reads at startup, so it lives for the
/// whole container without any screen having to remember to watch it.
final redactionFleetRegistrar = Provider<void>((ref) {
  ref.listen<AsyncValue<List<ConnectionWithDetails>>>(
    connectionsWithDetailsProvider,
    (_, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      Redactor.instance
        ..registerNames([for (final c in list) c.connection.label])
        ..registerAddresses([for (final c in list) c.connection.host]);
      // What a report and a public report's words are scrubbed of
      // (ReportScrub): a host by its label or its address is `<host>`.
      ReportScrub.registerHosts([for (final c in list) ...[c.connection.label, c.connection.host]]);
    },
    fireImmediately: true,
  );
  ref.listen<AsyncValue<List<ConnectionGroup>>>(
    connectionGroupsProvider,
    (_, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      Redactor.instance.registerNames([for (final g in list) g.name]);
    },
    fireImmediately: true,
  );
  // The saved workspaces (the one store the Hosts page and the command
  // palette use; the palette's own old store is brought into it once).
  ref.listen<List<SavedTabGroup>>(
    savedTabGroupsProvider,
    (_, next) =>
        Redactor.instance.registerNames([for (final w in next) w.name]),
    fireImmediately: true,
  );
  // A network profile's name and the SSIDs its triggers match on name the
  // user's environment as surely as a host does (RedactKind.network). Both
  // join the name set, so they get collision counters and a bare SSID or
  // profile name embedded in free text (a "why it matched" caption, the
  // derived match expression) is masked wherever it appears.
  ref.listen<AsyncValue<List<Network>>>(
    allNetworksProvider,
    (_, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      Redactor.instance.registerNames([
        for (final n in list) ...[
          n.name,
          for (final t in n.triggers)
            if (t is SsidTrigger) t.ssid,
        ],
      ]);
    },
    fireImmediately: true,
  );
  // Identity / key display names ("Alex", "work-laptop") name the user as
  // surely as a host label, and they surface as FREE TEXT in notifications (a
  // reminder reads "The certificate of <label> has run out"), where the
  // generic scan cannot recognise a bare label. Register the LABELS - not the
  // usernames, which are ordinary words the scan must not touch - so the name
  // rule masks them wherever they render. The Keys screen still shows a label
  // through the keyName rule (`key-NN`); both stand-ins are non-identifying,
  // and masking at display keeps a notification produced before recording was
  // turned on from leaking when the list is opened during a screen share.
  ref.listen<AsyncValue<List<Identity>>>(
    identitiesProvider,
    (_, next) {
      final list = next.valueOrNull;
      if (list == null) return;
      Redactor.instance.registerNames([for (final i in list) i.label]);
      // A report's words are scrubbed of the usernames the app signs in
      // with (ReportScrub: `<user>`; accounts every server has stay).
      ReportScrub.registerUsernames([for (final i in list) i.username]);
    },
    fireImmediately: true,
  );
});
