import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);

  @override
  Future<void> refresh() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's session knows its account from its own token when the id was
/// not saved with it. Without it the app took the session
/// for "an unknown account", and sent every account's team keys it held into
/// the sync data of whichever was signed in.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const storage = FlutterSecureStorage();

  /// A session token as ZestSSH Cloud makes one, with [claims] (not signed:
  /// the app only reads it, the server checks it).
  String token(Object? claims) =>
      'eyJhbGciOiJIUzI1NiJ9.${base64Url.encode(utf8.encode(jsonEncode(claims))).replaceAll('=', '')}.c2ln';

  final demo = token({'userId': 7, 'firebaseUid': 'aB3dE5fG7hJ9kL1m', 'email': 'alex@example.com'});

  group('the account a session token is for', () {
    test("is read from the token's firebaseUid", () {
      expect(sessionAccountUid(demo), 'aB3dE5fG7hJ9kL1m');
    });

    test('is nothing for a token without one, or for what is not a token', () {
      expect(sessionAccountUid(null), isNull);
      expect(sessionAccountUid('demo-session'), isNull);
      expect(sessionAccountUid('a.%%%.c'), isNull);
      expect(sessionAccountUid(token({'userId': 7})), isNull);
      expect(sessionAccountUid(token({'firebaseUid': ''})), isNull);
      expect(sessionAccountUid(token({'firebaseUid': 42})), isNull);
      expect(sessionAccountUid(token({'firebaseUid': 'x' * 129})), isNull);
      expect(sessionAccountUid(token(['firebaseUid'])), isNull);
    });
  });

  group('at the start, the session kept on this computer', () {
    test('kept before its id was: the token says it, and it is saved from now on', () async {
      FlutterSecureStorage.setMockInitialValues({});
      expect(await keptSessionUid(storage, demo), 'aB3dE5fG7hJ9kL1m');
      expect(await storage.read(key: 'session_uid'), 'aB3dE5fG7hJ9kL1m');
    });

    test('kept with its id: that one, nothing written over', () async {
      FlutterSecureStorage.setMockInitialValues({'session_uid': 'zY8xW6vU4tS2rQ0p'});
      expect(await keptSessionUid(storage, demo), 'zY8xW6vU4tS2rQ0p');
      expect(await storage.read(key: 'session_uid'), 'zY8xW6vU4tS2rQ0p');
    });

    test('neither says: still unknown, and nothing is saved', () async {
      FlutterSecureStorage.setMockInitialValues({});
      expect(await keptSessionUid(storage, token({'userId': 7})), isNull);
      expect(await storage.read(key: 'session_uid'), isNull);
    });
  });

  testWidgets('signed in from a website that sent no id, the session takes the token\'s', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      ],
      child: Consumer(builder: (context, r, _) {
        ref = r;
        return const SizedBox();
      }),
    ));

    await tester.runAsync(() => storeDesktopSession(ref, BrowserSession(token: demo, email: 'alex@example.com')));
    expect(ref.read(desktopSessionProvider)?.uid, 'aB3dE5fG7hJ9kL1m');
    expect(await tester.runAsync(() => storage.read(key: 'session_uid')), 'aB3dE5fG7hJ9kL1m');
  });
}
