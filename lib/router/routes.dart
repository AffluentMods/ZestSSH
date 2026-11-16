/// Centralised route path constants.
///
/// Using constants avoids typo-related navigation bugs and makes
/// it easy to refactor paths from one place.
abstract final class Routes {
  static const home = '/';
  static const onboarding = '/onboarding';
  static const connectionEdit = '/connection/edit';
  static const connectionEditId = '/connection/edit/:id';
  static const connectionScanQr = '/connection/scan-qr';
  static const identityList = '/identities';
  static const identityEdit = '/identity/edit';
  static const identityEditId = '/identity/edit/:id';
  static const keyGeneration = '/identity/keygen';
  static const terminal = '/terminal/:sessionId';
  static const settings = '/settings';
  static const securityLock = '/lock';
  static const pinSetup = '/lock/pin-setup';
  static const sshConfigImport = '/import/ssh-config';
  static const lanScan = '/scan';
  static const puttyImport = '/import/putty';
  static const upgrade = '/upgrade';
  static const snippets = '/snippets';
  static const networks = '/networks';
  // The phone's More tab (3.0 UI).
  static const keys = '/keys';
  static const portForwards = '/port-forwards';
  static const team = '/team';
  static const teamPage = '/team/:page';
  static const networkEditId = '/networks/edit/:id';
  static const profile = '/profile';
  static const emailAuth = '/profile/email';
  static const recoveryKey = '/profile/recovery-key';
  static const syncBackend = '/profile/sync-storage';
  static const monitor = '/monitor';
  static const serverDetail = '/monitor/server/:connectionId';

  /// Mobile notifications history (pushed route: hides the tab bar + home button).
  static const notifications = '/notifications';

  /// Dedicated notification settings screen (reached from the Settings tab and
  /// the notifications overflow).
  static const notificationSettings = '/settings/notifications';
  static const setupGuide = '/setup-guide';

  /// Mobile settings drill-down sub-screens (category rows on the settings
  /// root push into these).
  static const terminalSettings = '/settings/terminal';
  static const keyboardRow = '/settings/terminal/keyboard-row';
  static const sessionLogs = '/settings/terminal/session-logs';
  static const sftpSettings = '/settings/sftp';
  static const screenSettings = '/settings/screens';
  static const automationSettings = '/settings/automation';
  static const dataSettings = '/settings/data';
  static const editor = '/editor';
  static const appearance = '/appearance';
  static const about = '/about';
  static const knownHosts = '/settings/known-hosts';
  static const triggers = '/settings/triggers';
  static const commandHistory = '/settings/command-history';
  static const help = '/help';
  static const report = '/report';
  static const tickets = '/tickets';
  static const ticket = '/tickets/view';
  static const contactSupport = '/support/new';
  // Ask Astryx on a phone (4.0, a named preview).
  static const askAstryx = '/help/ask';
  // The Support Hub on a phone (3.4): My tickets, Known issues, Ideas; the
  // tab to open on as the route's extra (HubTab).
  static const supportHub = '/support/hub';
  // Help > Guides (3.0): the search over the feature guides, and one guide
  // (its slug as the route's extra).
  static const guides = '/guides';
  static const guide = '/guides/view';
  static const shareView = '/share/view';
  static const replay = '/replay';
  static const transcripts = '/transcripts';
  static const transcriptView = '/transcripts/view';
  static const sftpRemote = '/sftp/remote';
  static const automationGuide = '/automation-guide';
  static const automationHistory = '/automation-history';
  static const automationWizard = '/automation-wizard';
  static const workflowList = '/workflows';
  static const workflowEditor = '/workflow/edit';
  static const scheduledTasks = '/scheduled-tasks';
  static const iosBackgrounding = '/ios-backgrounding';
}
