import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/auto_sync_service.dart';
import 'package:zestssh/ui/screens/sync/cloud_device_room.dart';

/// Past the seven devices ZestSSH Cloud syncs for one person, the way on is
/// a device signed out right where the pause is said:
/// the account's
/// other devices are listed, this one is not, and one signed out makes sync
/// run again.
class _Api extends Fake implements DeviceSessionsApi {
  final signedOut = <String>[];
  List<DeviceSessionInfo> devices = [
    DeviceSessionInfo(id: 'here', kind: 'registration', platform: 'windows', createdAt: DateTime(2026, 10, 1), current: true),
    DeviceSessionInfo(id: 'old-phone', kind: 'registration', platform: 'android', createdAt: DateTime(2025, 3, 2)),
    DeviceSessionInfo(id: 'old-laptop', kind: 'session_token', platform: 'linux', createdAt: DateTime(2024, 11, 20)),
  ];

  @override
  Future<List<DeviceSessionInfo>> list() async => devices;

  @override
  Future<void> signOut(String id, {String? as}) async => signedOut.add(id);
}

class _Service extends Fake implements DeviceSessionService {
  _Service(this.api);

  @override
  final DeviceSessionsApi api;
}

class _Sync extends Fake implements AutoSyncService {
  int runs = 0;

  @override
  Future<void> retryAfterFix() async => runs++;
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<(_Api, _Sync)> open(WidgetTester tester, {List<DeviceSessionInfo>? devices}) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _Api();
    if (devices != null) api.devices = devices;
    final sync = _Sync();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        deviceSessionServiceProvider.overrideWithValue(_Service(api)),
        autoSyncServiceProvider.overrideWithValue(sync),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(onPressed: () => showCloudDeviceRoom(context), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return (api, sync);
  }

  testWidgets('the other devices are listed, this one is not, and one signed out makes sync run again', (tester) async {
    final (api, sync) = await open(tester);
    expect(find.text(l10n.syncDeviceRoomTitle), findsOneWidget);
    expect(find.text(l10n.syncDeviceRoomBody), findsOneWidget);
    expect(find.byKey(const ValueKey('device-room-here')), findsNothing, reason: 'this device is not offered');
    expect(find.byKey(const ValueKey('device-room-old-phone')), findsOneWidget);
    expect(find.byKey(const ValueKey('device-room-old-laptop')), findsOneWidget);
    expect(find.text('Android'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('device-room-sign-out-old-laptop')));
    await tester.pumpAndSettle();
    // Asked first: nothing is signed out by a slip of the finger.
    expect(find.text(l10n.devicesSignOutConfirmTitle), findsOneWidget);
    expect(api.signedOut, isEmpty);
    await tester.tap(find.text(l10n.devicesSignOut).last);
    await tester.pumpAndSettle();
    expect(api.signedOut, ['old-laptop']);
    expect(sync.runs, 1, reason: 'sync goes on, its pause lifted');
    expect(find.text(l10n.syncDeviceRoomTitle), findsNothing, reason: 'closed once there is room');
    // (The message goes by itself.)
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
  });

  testWidgets('a sign-out that is not confirmed signs nothing out', (tester) async {
    final (api, sync) = await open(tester);
    await tester.tap(find.byKey(const ValueKey('device-room-sign-out-old-phone')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.cancel).last);
    await tester.pumpAndSettle();
    expect(api.signedOut, isEmpty);
    expect(sync.runs, 0);
    expect(find.text(l10n.syncDeviceRoomTitle), findsOneWidget, reason: 'the list stays');
  });

  // Where Sign out everywhere is: Settings, Account (on a computer it was
  // Account and security until 4.0); each in its own words (it named the
  // computer's on a phone too, as a 3.0 docs check found).
  testWidgets("with no other device listed, a computer is told the computer's way", (tester) async {
    await open(tester, devices: [
      const DeviceSessionInfo(id: 'here', kind: 'registration', platform: 'windows', current: true),
    ]);
    expect(find.byKey(const ValueKey('device-room-empty')), findsOneWidget);
    expect(find.text(l10n.syncDeviceRoomEmpty), findsOneWidget);
    // Both name Settings, Account since 4.0 (one structure on every device).
    expect(l10n.syncDeviceRoomEmpty, contains(l10n.settingsAccount));
  }, variant: const TargetPlatformVariant({TargetPlatform.windows, TargetPlatform.macOS, TargetPlatform.linux}));

  testWidgets("with no other device listed, a phone is told the phone's way", (tester) async {
    await open(tester, devices: [
      const DeviceSessionInfo(id: 'here', kind: 'registration', platform: 'android', current: true),
    ]);
    expect(find.text(l10n.syncDeviceRoomEmptyPhone), findsOneWidget);
    expect(l10n.syncDeviceRoomEmptyPhone, contains(l10n.settingsAccount));
  }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.iOS}));
}
