import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The tabs of a computer's Automation section, in the order it shows them.
enum AutomationTab { workflows, runs, triggers }

/// A tab of Automation that another part of the app sends the person to,
/// taken (and cleared) by the Automation section: the notice of a request
/// refused for its API key goes to Triggers, where the keys are (it went to
/// the Triggers of the sidebar, the terminal's output triggers, which have
/// no keys: found in the 3.0 docs check).
final automationTabWantedProvider = StateProvider<AutomationTab?>((ref) => null);

/// Bumped by the New workflow button of the Automation page's head; the
/// workflows view opens a new workflow each time it changes.
final automationNewWorkflowProvider = StateProvider<int>((ref) => 0);
