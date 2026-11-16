import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/services/cloud/cloud_status_config.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// ZestSSH Cloud's API, or the SYNC_API_BASE_URL a build names.
String get kCloudApiBase => kZestApiBase;

/// How long the service is given to say how it is.
const Duration kCloudHealthTimeout = Duration(seconds: 6);

/// Asks ZestSSH Cloud how it is: the HTTP status of its health check. It
/// asks nothing about anyone (no sign-in goes with it; the server sees an
/// address and a time, as with any request), and it is asked only after
/// something the app needed from the service failed, and then until the
/// service answers again. Throws when nothing answers.
Future<int> cloudHealthStatus({http.Client? client}) async {
  final response =
      await (client ?? PinnedHttpClient.client).get(Uri.parse('$kCloudApiBase/health')).timeout(kCloudHealthTimeout);
  return response.statusCode;
}

/// The status service as this build is set up for it
/// (lib/services/cloud/cloud_status_config.dart). A statement has to be
/// about the very host this build talks to: a build pointed at another API
/// believes nothing said about ZestSSH Cloud.
final cloudStatusConfigProvider = Provider<CloudStatusConfig>((ref) => cloudStatusConfigOf(
      url: kCloudStatusUrl,
      service: Uri.tryParse(kCloudApiBase)?.host ?? '',
      keys: kCloudStatusKeys,
    ));

/// Asks the status service how ZestSSH Cloud stands: its statement, signed
/// and believed, or null. It goes over a connection of its own with the
/// system's certificate checks and nothing of the app's with it: no sign-in,
/// no identifier. It is asked only after ZestSSH Cloud itself gave no answer.
Future<CloudStatement?> cloudStatusNow(CloudStatusConfig config, {http.Client? client, int Function()? nowSeconds}) async {
  final asking = client ?? http.Client();
  try {
    return await askCloudStatus(
      config,
      client: asking,
      nowSeconds: nowSeconds ?? () => DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );
  } finally {
    if (client == null) asking.close();
  }
}

/// What the app's own reach service asks the status service with; null in a
/// build that is set up for none.
final cloudStatusAskerProvider = Provider<Future<CloudStatement?> Function()?>((ref) {
  final config = ref.watch(cloudStatusConfigProvider);
  return config.isSet ? () => cloudStatusNow(config) : null;
});

/// What the app's own reach service asks ZestSSH Cloud with how it is.
final cloudHealthCheckProvider = Provider<Future<int> Function()>((ref) => cloudHealthStatus);

/// How ZestSSH Cloud stands from this device, kept true by everything that
/// talks to it (lib/services/cloud/cloud_reach.dart). The app ties it to
/// the client its requests go through, to the device's network and to what
/// catches up when the service is back, as it starts (lib/app.dart).
final cloudReachProvider = Provider<CloudReachService>((ref) {
  final service = CloudReachService(
    check: ref.watch(cloudHealthCheckProvider),
    status: ref.watch(cloudStatusAskerProvider),
  );
  currentCloudReach = service;
  // Signed out, nothing on this device uses the service any more: what was
  // known of it is forgotten. Nobody is told that something they do not use
  // is not responding, and it is not asked how it is on their account. (The
  // next thing that does use it, signing in for one, says how that went.)
  ref.listen<UserProfile?>(currentUserProvider, (was, now) {
    if (was != null && now == null) service.forget();
  });
  ref.onDispose(() {
    if (identical(currentCloudReach, service)) currentCloudReach = null;
    service.dispose();
  });
  return service;
});

/// [cloudReachProvider]'s state, for whatever shows it.
final cloudReachStateProvider = StreamProvider<CloudReachState>((ref) {
  final service = ref.watch(cloudReachProvider);
  final controller = StreamController<CloudReachState>();
  void push() => controller.add(service.state.value);
  service.state.addListener(push);
  push();
  ref.onDispose(() {
    service.state.removeListener(push);
    unawaited(controller.close());
  });
  return controller.stream;
});
