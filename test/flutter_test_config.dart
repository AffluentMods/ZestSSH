import 'dart:async';

import 'package:cryptography/cryptography.dart';

import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/services/own_network_http.dart' show ownNetworkLookup;
import 'package:zestssh/theme/ui_density.dart' show PointerInputTracker;

import 'helpers/test_cryptography.dart';

/// Runs around every test file under test/ (the test runner looks for a file
/// of this name).
///
/// Key derivation is stood in for: see [TestCryptography] for why. A test
/// about the derivation itself asks for the real one with
/// `useRealKeyDerivation()`.
///
/// The app's root hears no pointer's kind ([PointerInputTracker]): a test's
/// taps are a finger's, and would make a computer's pages touch sized under
/// it. A test of the density turns it on.
///
/// The build under test is ZestSSH, the release: a test command names no
/// build setting, and without ZEST_OFFICIAL a build is a community build
/// with no sign-in, Cloud, updater or website (lib/config/official_identity.dart).
/// A test of the community build asks for it with `debugZestOfficial = false`
/// and puts it back.
///
/// No test asks the network where a name leads (lib/services/own_network_http.dart):
/// here every name resolves to nothing, which the rule passes. A test of the
/// rule gives it a resolver of its own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  Cryptography.instance = TestCryptography();
  PointerInputTracker.enabled = false;
  debugZestOfficial = true;
  ownNetworkLookup = (host) async => const [];
  await testMain();
}
