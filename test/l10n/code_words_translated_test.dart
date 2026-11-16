import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/desktop_auth_server.dart';

/// Words the code made up in English reach the screen in the app's language
/// (found in a review): a workflow's step list said "Wait 5 seconds"
/// and a sign-in that came back without its token two English sentences, in
/// every language.
void main() {
  tearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));

  test('a workflow step says what it does in the app\'s language', () {
    L10nGlobal.update(lookupAppLocalizations(const Locale('de')));
    expect(const WorkflowStep(id: 'w', type: WorkflowStepType.delay, timeoutSeconds: 5).displaySummary, '5 Sekunden warten');
    expect(const WorkflowStep(id: 's', type: WorkflowStepType.snippet).displaySummary, 'Unbekanntes Snippet');
    expect(const WorkflowStep(id: 'n', type: WorkflowStepType.notify).displaySummary, 'Benachrichtigung senden');
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    expect(const WorkflowStep(id: 'w', type: WorkflowStepType.delay, timeoutSeconds: 1).displaySummary, 'Wait 1 second');
  });

  test('a sign-in that came back broken says so in the app\'s language', () {
    L10nGlobal.update(lookupAppLocalizations(const Locale('fr')));
    expect(const AuthCallbackError(AuthCallbackErrorKind.missingToken).userMessage, startsWith('La connexion est revenue'));
    expect(const AuthCallbackError(AuthCallbackErrorKind.stateMismatch).userMessage, contains('@'));
  });
}
