import 'dart:math';

/// This run's part of every made-up account and code the contract tests make
/// on the stand-in backend (ZestSSH Cloud's test/helpers/app_contract_server.js),
/// which the suites of every worktree on this computer share: the second it
/// started, and a random part.
///
/// The names were `kind-name-second-n`, n counted in one file's run
/// only, so two runs of the same file in the same second made the same
/// account, and the second found keys on the server it never made
/// (key_generations_contract_test failed with
/// "waitingForAnotherDevice").
final String contractRun =
    '${DateTime.now().millisecondsSinceEpoch ~/ 1000}-${Random.secure().nextInt(1 << 32).toRadixString(16).padLeft(8, '0')}';
