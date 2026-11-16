import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/models/workflow.dart';

// The names the app shows for the entries of some of its lists, in the
// person's language. Each list kept its names in English, and the screens
// showed them as they were, whatever the language (3.0, 17 October 2026).
// A product's or a protocol's own name is shown as it is written; each
// list's `englishName` is for the log alone.

extension TerminalCursorShapeName on TerminalCursorShape {
  /// The shape's name, with the shape itself after it.
  String nameIn(AppLocalizations l10n) => switch (this) {
        TerminalCursorShape.verticalBar => '${l10n.cursorShapeBar} |',
        TerminalCursorShape.block => '${l10n.cursorShapeBlock} █',
        TerminalCursorShape.underline => '${l10n.cursorShapeUnderline} _',
      };
}

extension TerminalCursorVisibilityName on TerminalCursorVisibility {
  /// When the cursor is drawn, in words.
  String nameIn(AppLocalizations l10n) => switch (this) {
        TerminalCursorVisibility.always => l10n.cursorVisibilityAlways,
        TerminalCursorVisibility.notDuringOutput => l10n.cursorVisibilityNotDuringOutput,
        TerminalCursorVisibility.never => l10n.cursorVisibilityNever,
      };

  /// What a choice is good for, under its name: the one for full-screen
  /// programs says so.
  String? noteIn(AppLocalizations l10n) =>
      this == TerminalCursorVisibility.notDuringOutput ? l10n.cursorVisibilityNotDuringOutputNote : null;
}

extension TerminalFontFamilyName on TerminalFontFamily {
  /// A font's own name; the system's, said as the system's font.
  String nameIn(AppLocalizations l10n) =>
      this == TerminalFontFamily.system ? l10n.terminalFontSystem : englishName;
}

extension ConnectionProtocolName on ConnectionProtocol {
  /// A protocol's own name; the kinds of host that are not one, in words.
  String nameIn(AppLocalizations l10n) => switch (this) {
        ConnectionProtocol.serial => l10n.protocolNameSerial,
        // Said with what it is for: files, and no terminal.
        ConnectionProtocol.sftp => l10n.protocolNameSftp,
        ConnectionProtocol.localShell => l10n.protocolNameLocalShell,
        ConnectionProtocol.demo => l10n.protocolNameDemo,
        ConnectionProtocol.ftpsImplicit => l10n.protocolNameFtpsImplicit,
        ConnectionProtocol.ssh ||
        ConnectionProtocol.mosh ||
        ConnectionProtocol.et ||
        ConnectionProtocol.telnet ||
        ConnectionProtocol.ftps ||
        ConnectionProtocol.vnc ||
        ConnectionProtocol.rdp =>
          englishName,
      };
}

extension WorkflowStepTypeName on WorkflowStepType {
  /// What a step does, as the editor offers it.
  String nameIn(AppLocalizations l10n) => switch (this) {
        WorkflowStepType.execute => l10n.wfEditOptExecuteLabel,
        WorkflowStepType.snippet => l10n.wfEditOptSnippetLabel,
        WorkflowStepType.delay => l10n.wfEditOptDelayLabel,
        WorkflowStepType.notify => l10n.wfEditOptNotifyLabel,
      };
}

extension StepFailureActionName on StepFailureAction {
  /// What a failed step does next, as the editor offers it.
  String nameIn(AppLocalizations l10n) => switch (this) {
        StepFailureAction.abort => l10n.wfEditSegAbort,
        StepFailureAction.continueNext => l10n.wfEditSegContinue,
        StepFailureAction.gotoStep => l10n.wfEditSegGoTo,
      };
}

extension ScheduledTaskActionName on ScheduledTaskAction {
  /// What a scheduled task runs, as the automation wizard names it.
  String nameIn(AppLocalizations l10n) => switch (this) {
        ScheduledTaskAction.execute => l10n.autoWizExecuteTitle,
        ScheduledTaskAction.snippet => l10n.autoWizSnippetTitle,
        ScheduledTaskAction.workflow => l10n.autoWizWorkflowTitle,
      };
}

extension ScheduleTypeName on ScheduleType {
  /// How often a scheduled task runs.
  String nameIn(AppLocalizations l10n) => switch (this) {
        ScheduleType.interval => l10n.schedTaskTypeInterval,
        ScheduleType.daily => l10n.schedTaskTypeDaily,
        ScheduleType.weekly => l10n.schedTaskTypeWeekly,
      };
}
