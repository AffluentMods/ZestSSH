import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/security_providers.dart';

SecretKey _key() => SecretKey(List.filled(32, 7));

void main() {
  group('VaultSessionNotifier (S2)', () {
    test('starts locked - no cached key', () {
      final n = VaultSessionNotifier();
      addTearDown(n.dispose);
      expect(n.state.isUnlocked, isFalse);
      expect(n.mek, isNull);
    });

    test('unlock caches the MEK and reports unlocked with time remaining', () {
      final n = VaultSessionNotifier();
      addTearDown(n.dispose);
      final key = _key();
      n.unlock(key);
      expect(n.state.isUnlocked, isTrue);
      expect(n.mek, same(key));
      expect(n.state.remaining, isNotNull);
      expect(n.state.remaining!.inMinutes, greaterThan(25));
    });

    test('lock clears the cached MEK', () {
      final n = VaultSessionNotifier();
      addTearDown(n.dispose);
      n.unlock(_key());
      n.lock();
      expect(n.state.isUnlocked, isFalse);
      expect(n.state.mek, isNull);
      expect(n.mek, isNull);
    });

    test('an already-expired session reads as locked (mek getter never leaks)',
        () {
      final n = VaultSessionNotifier();
      addTearDown(n.dispose);
      // Zero TTL → expiresAt == now → not "before now" → locked immediately.
      n.unlock(_key(), ttl: Duration.zero);
      expect(n.state.isUnlocked, isFalse);
      expect(n.mek, isNull);
    });
  });
}
