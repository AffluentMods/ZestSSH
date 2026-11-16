import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';

/// Dedicated help screen explaining iOS backgrounding limitations for SSH.
///
/// Covers what happens when the app is backgrounded, why it happens,
/// what ZestSSH does to mitigate it, and recommended solutions.
class IosBackgroundingHelpScreen extends StatelessWidget {
  const IosBackgroundingHelpScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.iosBackgroundingHelpTitle),
        backgroundColor: AppColors.background,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
        children: [
          // Header
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.warning.withValues(alpha: 0.25),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  LucideIcons.info,
                  color: AppColors.warning,
                  size: 24,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    l10n.iosBackgroundingHelpIntro,
                    style: TextStyle(
                      fontSize: 14,
                      color: AppColors.onSurface,
                      height: 1.5,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 24),

          // Section 1: What happens
          _buildSection(
            icon: LucideIcons.wifiOff,
            title: l10n.iosBackgroundingHelpWhatHappensTitle,
            children: [
              _BulletPoint(l10n.iosBackgroundingHelpWhatHappensBullet1),
              _BulletPoint(l10n.iosBackgroundingHelpWhatHappensBullet2),
              _BulletPoint(l10n.iosBackgroundingHelpWhatHappensBullet3),
            ],
          ),

          // Section 2: Why
          _buildSection(
            icon: LucideIcons.batteryCharging,
            title: l10n.iosBackgroundingHelpWhyTitle,
            children: [
              _BulletPoint(l10n.iosBackgroundingHelpWhyBullet1),
              _BulletPoint(l10n.iosBackgroundingHelpWhyBullet2),
              _BulletPoint(l10n.iosBackgroundingHelpWhyBullet3),
            ],
          ),

          // Section 3: What ZestSSH does
          _buildSection(
            icon: LucideIcons.refreshCw,
            title: l10n.iosBackgroundingHelpWhatZestDoesTitle,
            children: [
              _BulletPoint(l10n.iosBackgroundingHelpWhatZestDoesBullet1),
              _BulletPoint(l10n.iosBackgroundingHelpWhatZestDoesBullet2),
              _BulletPoint(l10n.iosBackgroundingHelpWhatZestDoesBullet3),
            ],
          ),

          // Section 4: Recommended solutions
          _buildSection(
            icon: LucideIcons.lightbulb,
            title: l10n.iosBackgroundingHelpSolutionsTitle,
            children: [
              _SolutionTile(
                title: l10n.iosBackgroundingHelpTmuxTitle,
                description: l10n.iosBackgroundingHelpTmuxDescription,
                command: 'tmux new -s work',
              ),
              // Mosh again (4.0): ZestSSH has its own Mosh client on every
              // device, iPhones and iPads included, and a Mosh session lives
              // through iOS suspending the app. (It was taken out in the 3.0
              // docs check, while iOS had no Mosh.) The
              // command is the host's: mosh-server is what it needs.
              _SolutionTile(
                title: l10n.iosBackgroundingHelpMoshTitle,
                description: l10n.iosBackgroundingHelpMoshDescription,
                command: 'sudo apt install mosh',
              ),
              _BulletPoint(l10n.iosBackgroundingHelpCombineBullet),
            ],
          ),

          // Section 5: Why no background hack
          _buildSection(
            icon: LucideIcons.shield,
            title: l10n.iosBackgroundingHelpNoWorkaroundsTitle,
            children: [
              _BulletPoint(l10n.iosBackgroundingHelpNoWorkaroundsBullet1),
              _BulletPoint(l10n.iosBackgroundingHelpNoWorkaroundsBullet2),
              _BulletPoint(l10n.iosBackgroundingHelpNoWorkaroundsBullet3),
            ],
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  static Widget _buildSection({
    required IconData icon,
    required String title,
    required List<Widget> children,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: AppColors.accentInk),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppColors.accentInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...children,
        ],
      ),
    );
  }
}

/// A simple bullet point row.
class _BulletPoint extends StatelessWidget {
  final String text;
  const _BulletPoint(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, left: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Icon(LucideIcons.circle, size: 6, color: AppColors.textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 14,
                color: AppColors.onSurface,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A styled solution card with a terminal command example.
class _SolutionTile extends StatelessWidget {
  final String title;
  final String description;
  final String command;

  const _SolutionTile({
    required this.title,
    required this.description,
    required this.command,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12, left: 4),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.background,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              '\$ $command',
              style: TextStyle(
                fontSize: 13,
                fontFamily: 'JetBrainsMono',
                color: AppColors.accentInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
