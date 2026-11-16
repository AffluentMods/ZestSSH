import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/locked_feature_view.dart';

/// What command history gives, on its page before Squeezed is bought: each
/// true as the app is (the search, Run again on a host, and the secrets
/// left out by default; an opt-in on the page's menu keeps them).
List<LockedFeatureBenefit> lockedHistoryBenefits(AppLocalizations l10n) => [
      LockedFeatureBenefit(LucideIcons.search, l10n.lockedHistorySearch),
      LockedFeatureBenefit(LucideIcons.play, l10n.lockedHistoryRunAgain),
      LockedFeatureBenefit(LucideIcons.shield, l10n.lockedHistorySecrets),
    ];

/// Made-up commands for the History page's preview before Squeezed is
/// bought (the locked page, 4.0): what the page looks like in use, never
/// anyone's own hosts or commands. Today's first, then two earlier days.
List<CommandHistoryEntry> demoHistoryEntries(DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  CommandHistoryEntry e(int n, int dayAgo, int h, int m, String host, String command,
          {String? cwd, int exit = 0, int ms = 100}) =>
      CommandHistoryEntry(
        id: 'demo-$n',
        command: command,
        hostLabel: host,
        createdAt: today.subtract(Duration(days: dayAgo)).add(Duration(hours: h, minutes: m)),
        exitCode: exit,
        durationMs: ms,
        cwd: cwd,
      );
  return [
    e(1, 0, 9, 42, 'web-01', 'tail -n 100 /var/log/nginx/error.log', cwd: '/var/log'),
    e(2, 0, 9, 40, 'web-01', 'sudo nginx -t && sudo systemctl reload nginx', cwd: '~', ms: 400),
    e(3, 0, 9, 15, 'db-primary', 'df -h /var/lib/postgresql'),
    e(4, 0, 8, 57, 'cache-01', 'redis-cli info memory'),
    e(5, 1, 18, 20, 'build-runner', 'git pull --rebase && make release', ms: 48000),
    e(6, 1, 17, 58, 'web-02', 'npm run test -- --watch=false', exit: 1, ms: 12000),
    e(7, 1, 17, 40, 'log-store', 'du -sh /srv/logs/* | sort -h', ms: 2400),
    e(8, 1, 16, 5, 'edge-router', 'ip -br addr'),
    e(9, 1, 15, 31, 'vpn-gateway', 'wg show wg0 latest-handshakes'),
    e(10, 1, 14, 12, 'hypervisor-a', 'qm list', ms: 600),
    e(11, 3, 11, 3, 'monitoring', 'docker compose ps', cwd: '/opt/grafana', ms: 800),
    e(12, 3, 10, 47, 'mac-studio', 'brew upgrade --dry-run', cwd: '~', ms: 3100),
  ];
}
