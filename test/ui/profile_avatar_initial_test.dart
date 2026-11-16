import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';

// The avatar's letter: the name's first, else the email's. A password account
// signed in on a computer has a name that is empty, not missing, and showed
// a '?'.
void main() {
  Future<void> pumpFor(WidgetTester tester, UserProfile? user) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        currentUserProvider.overrideWith((_) => user),
      ],
      child: const MaterialApp(home: Scaffold(body: Center(child: ProfileAvatar(size: 40)))),
    ));
    await tester.pump();
  }

  testWidgets('an empty name falls back to the email', (tester) async {
    await pumpFor(tester, const UserProfile(uid: 'u1', email: 'alex@example.com', displayName: ''));
    expect(find.text('A'), findsOneWidget);
    expect(find.text('?'), findsNothing);
  });

  testWidgets('a name of spaces falls back to the email too', (tester) async {
    await pumpFor(tester, const UserProfile(uid: 'u1', email: 'robin@example.com', displayName: '   '));
    expect(find.text('R'), findsOneWidget);
  });

  testWidgets('a name wins over the email', (tester) async {
    await pumpFor(tester, const UserProfile(uid: 'u1', email: 'alex@example.com', displayName: 'Jordan Lee'));
    expect(find.text('J'), findsOneWidget);
  });

  testWidgets('nobody signed in shows a ?', (tester) async {
    await pumpFor(tester, null);
    expect(find.text('?'), findsOneWidget);
  });
}
