import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/notification_service.dart';

/// Whether the OS currently permits posting notifications.
///
/// The notifications screen watches this to show the permission-denied banner
/// only on a REAL denial (the check defaults to true when unknown / on desktop).
/// `app.dart` invalidates it on app resume, so returning from the system
/// settings page re-checks and clears the banner.
final notificationsEnabledProvider = FutureProvider<bool>((ref) async {
  return NotificationService.areEnabled();
});
