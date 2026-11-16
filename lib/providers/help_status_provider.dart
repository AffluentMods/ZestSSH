import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:zestssh/features/feedback/feedback_service.dart';
import 'package:zestssh/services/pinned_http_client.dart';

/// Whether ZestSSH Cloud is reachable, for the Help panel footer.
enum CloudStatus {
  /// `GET /v1/health` answered 200 with `status: ok`.
  ok,

  /// The service answered, but reports itself degraded (503).
  degraded,

  /// No answer at all (offline, DNS, timeout).
  unreachable,
}

/// The running app's version, for the Help panel footer.
final appVersionLabelProvider = FutureProvider<String>((ref) async {
  final info = await PackageInfo.fromPlatform();
  return info.version;
});

/// A real check, not a static "all systems operational" (fixes spec, section
/// 13): one GET of the API's health route while the Help panel is open,
/// cached for five minutes. Nothing about the user or the device is sent; the
/// server sees an IP and a time, as with any web request. Disclosed next to
/// the update check in the whitepaper and the privacy policy.
final cloudStatusProvider = FutureProvider.autoDispose<CloudStatus>((ref) async {
  final link = ref.keepAlive();
  final timer = Timer(const Duration(minutes: 5), link.close);
  ref.onDispose(timer.cancel);
  try {
    final resp = await PinnedHttpClient.client
        .get(Uri.parse('${FeedbackService.base}/health'))
        .timeout(const Duration(seconds: 4));
    if (resp.statusCode == 200) return CloudStatus.ok;
    if (resp.statusCode == 503) return CloudStatus.degraded;
    return CloudStatus.degraded;
  } catch (_) {
    return CloudStatus.unreachable;
  }
});
