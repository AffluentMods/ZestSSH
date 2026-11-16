import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/services/security_lock_service.dart';

/// A PIN lock whose auto-lock time the test sets.
class _Lock implements SecurityLockService {
  int timeout = 5;

  @override
  Future<SecurityLockMethod> getLockMethod() async => SecurityLockMethod.pin;
  @override
  Future<int> getAutoLockTimeout() async => timeout;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Why the app locked, as the lock screen says it (4.0): what each way of locking
/// records, and that the first lock wins while the app is locked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Lock lock;

  Future<ProviderContainer> container() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    SharedPreferences.setMockInitialValues({'security_lock_enabled': true});
    FlutterSecureStorage.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    lock = _Lock();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      securityLockServiceProvider.overrideWithValue(lock),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  test('the app starts locked "since ZestSSH started"', () async {
    final c = await container();
    expect(c.read(isAppLockedProvider), isTrue);
    expect(c.read(isAppLockedProvider.notifier).why, AppLockReason.started);
  });

  test('a lock with no reason is the person\'s; one with a reason keeps it', () async {
    final c = await container();
    final notifier = c.read(isAppLockedProvider.notifier);
    notifier.unlock();
    await notifier.lock();
    expect(notifier.why, AppLockReason.byYou);
    notifier.unlock();
    await notifier.lock(const AppLockReason(AppLockCause.idle, 5));
    expect(notifier.why, const AppLockReason(AppLockCause.idle, 5));
  });

  test('the first lock wins: another while locked does not change what is said', () async {
    final c = await container();
    final notifier = c.read(isAppLockedProvider.notifier);
    notifier.unlock();
    await notifier.lock(AppLockReason.slept);
    await notifier.lock(const AppLockReason(AppLockCause.away, 10));
    expect(notifier.why, AppLockReason.slept);
    notifier.unlock();
    await notifier.lock(AppLockReason.computerLocked);
    expect(notifier.why, AppLockReason.computerLocked, reason: 'a lock after an unlock says its own');
  });

  test('back from the background past the auto-lock time: "after N minutes away", or "when you left" for Immediately',
      () async {
    final c = await container();
    final notifier = c.read(isAppLockedProvider.notifier);
    notifier.unlock();
    lock.timeout = 0;
    notifier.onAppBackgrounded();
    await notifier.onAppResumed();
    expect(notifier.state, isTrue);
    expect(notifier.why, const AppLockReason(AppLockCause.away, 0));

    notifier.unlock();
    lock.timeout = 5;
    notifier.onAppBackgrounded();
    await notifier.onAppResumed();
    expect(notifier.state, isFalse, reason: 'not five minutes yet');
  });
}
