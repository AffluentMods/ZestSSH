import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:share_plus/share_plus.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/widgets/api_key_once_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' show noCommandReason;
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// The four automation action types a user can build.
enum _ActionType {
  execute,
  snippet,
  batch,
  connect,
  workflow,
}

/// What the wizard tells Tasker's Send Intent to send for [action] (execute,
/// snippet, batch, connect or workflow): its action, the app's package, its
/// target and its extras, each in Tasker's own form, key:value, and each one
/// MainActivity reads. The target is an Activity: the app has no receiver for
/// these actions, and the broadcast the wizard said to send reached nothing;
/// and a batch's hosts went as an extra MainActivity did not read (found
/// in the client's security review). The package is named so
/// that no other app is offered the intent and its key.
/// What the wizard's examples carry where the key goes, when no key was made
/// on its page: a key is shown once, when it is made, so the person pastes
/// theirs over it.
const automationKeyPlaceholder = 'YOUR_KEY';

@visibleForTesting
String taskerIntentText({
  required String action,
  String? key,
  String? connection,
  List<String> connections = const [],
  String command = '',
  int timeout = 0,
  Map<String, String> filters = const {},
  String? snippet,
  Map<String, String> variables = const {},
  String? workflow,
}) {
  final lines = [
    'Action: com.affluentlabs.zestssh.${action.toUpperCase()}',
    'Package: com.affluentlabs.zestssh',
    'Target: Activity',
  ];
  void extra(String name, Object? value) => lines.add('Extra: $name:$value');
  if (key != null) extra('key', key);
  switch (action) {
    case 'execute':
      extra('connection_id', connection);
      extra('command', command);
      if (timeout > 0) extra('timeout', timeout);
      filters.forEach(extra);
    case 'snippet':
      extra('connection_id', connection);
      extra('snippet_name', snippet);
      variables.forEach((name, value) => extra('var_$name', value));
    case 'batch':
      extra('connections', connections.join(','));
      extra('command', command);
      extra('parallel', true);
      if (timeout > 0) extra('timeout', timeout);
      filters.forEach(extra);
    case 'connect':
      extra('connection_id', connection);
    case 'workflow':
      if (workflow != null) extra('workflow_name', workflow);
  }
  return lines.join('\n');
}

/// Step-by-step wizard that helps users build automation URLs and intents.
///
/// Uses a [PageView] with five steps:
/// 1. Choose Action
/// 2. Pick Connection(s)
/// 3. Configure
/// 4. Filters (optional, Execute/Batch only)
/// 5. Result (generated URL, Tasker intent, ADB command)
class AutomationWizardScreen extends ConsumerStatefulWidget {
  const AutomationWizardScreen({super.key});

  @override
  ConsumerState<AutomationWizardScreen> createState() =>
      _AutomationWizardScreenState();
}

class _AutomationWizardScreenState
    extends ConsumerState<AutomationWizardScreen> {
  final _pageController = PageController();
  int _currentPage = 0;

  /// Highest page the user has reached - pages up to this stay tappable
  /// even when navigating back.
  int _maxVisitedPage = 0;

  // ── Step 1 state ──
  _ActionType? _selectedAction;

  // ── Step 2 state ──
  Connection? _selectedConnection;
  final Set<String> _selectedConnectionIds = {};
  Workflow? _selectedWorkflow;

  // ── Step 3 state ──
  final _commandController = TextEditingController();
  double _timeout = 0;
  Snippet? _selectedSnippet;
  final Map<String, TextEditingController> _variableControllers = {};

  // ── Step 4 state ──
  final _grepController = TextEditingController();
  final _headController = TextEditingController();
  final _tailController = TextEditingController();
  final _webhookController = TextEditingController();

  // ── The key in the URL / intent ──
  // A key is shown once, when it is made, and only its hash is kept: the
  // examples carry a key itself only when it was made here, on this page
  // (held in memory while the wizard is open, never stored); otherwise they
  // carry [automationKeyPlaceholder] for the person to paste their key over.
  ({AutomationApiKey key, String secret})? _madeHere;

  String get _keyInExamples => _madeHere?.secret ?? automationKeyPlaceholder;

  @override
  void initState() {
    super.initState();
    // Rebuild when text fields change so _canAdvance re-evaluates
    _commandController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  int get _totalSteps {
    if (_selectedAction == _ActionType.connect) return 3;
    if (_selectedAction == _ActionType.workflow) return 3;
    if (_selectedAction == _ActionType.snippet) return 4;
    return 5;
  }

  /// Map logical page index to actual step index, accounting for
  /// steps that are skipped depending on the action type.
  int _logicalStep(int page) {
    if (_selectedAction == _ActionType.connect) {
      // Steps: 0 (action), 1 (connection), 2 (result)
      const mapping = [0, 1, 4];
      return mapping[page.clamp(0, 2)];
    }
    if (_selectedAction == _ActionType.workflow) {
      // Steps: 0 (action), 1 (pick workflow), 2 (result)
      // Logical step 5 = workflow picker, 4 = result
      const mapping = [0, 5, 4];
      return mapping[page.clamp(0, 2)];
    }
    if (_selectedAction == _ActionType.snippet) {
      // Steps: 0 (action), 1 (connection), 2 (configure), 3 (result)
      const mapping = [0, 1, 2, 4];
      return mapping[page.clamp(0, 3)];
    }
    // Execute / Batch: all 5 steps
    return page;
  }

  bool get _canAdvance {
    final step = _logicalStep(_currentPage);
    switch (step) {
      case 0:
        return _selectedAction != null;
      case 1:
        if (_selectedAction == _ActionType.batch) {
          return _selectedConnectionIds.isNotEmpty;
        }
        return _selectedConnection != null;
      case 2:
        if (_selectedAction == _ActionType.execute ||
            _selectedAction == _ActionType.batch) {
          return _commandController.text.trim().isNotEmpty;
        }
        if (_selectedAction == _ActionType.snippet) {
          return _selectedSnippet != null;
        }
        return true;
      case 3:
        return true; // Filters are optional
      case 4:
        return true; // Result page
      case 5:
        return _selectedWorkflow != null; // Workflow picker
      default:
        return false;
    }
  }

  void _nextPage() {
    if (!_canAdvance) return;
    if (_currentPage < _totalSteps - 1) {
      setState(() {
        _currentPage++;
        if (_currentPage > _maxVisitedPage) _maxVisitedPage = _currentPage;
      });
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  void _goToPage(int page) {
    if (page < 0 || page >= _totalSteps || page == _currentPage) return;
    // Allow navigating to any previously visited page
    if (page > _maxVisitedPage) return;
    setState(() => _currentPage = page);
    _pageController.animateToPage(
      page,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  bool get _hasProgress =>
      _selectedAction != null || _selectedConnection != null;

  Future<void> _confirmExit(BuildContext context) async {
    if (!_hasProgress) {
      Navigator.of(context).pop();
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.autoWizDiscardTitle,
      body: l10n.autoWizDiscardMessage,
      confirmLabel: l10n.autoWizDiscard,
    );
    if (confirmed == true && context.mounted) {
      Navigator.of(context).pop();
    }
  }

  void _prevPage() {
    if (_currentPage > 0) {
      setState(() => _currentPage--);
      _pageController.animateToPage(
        _currentPage,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeInOut,
      );
    }
  }

  // ── URL generation ──────────────────────────────────────────────

  String _buildUrl() {
    final params = <String, String>{};

    // Every generated URL carries the key: the one made here, or the
    // placeholder to paste a key over.
    params['key'] = _keyInExamples;

    switch (_selectedAction!) {
      case _ActionType.execute:
        params['connection'] = _selectedConnection!.label;
        params['command'] = _commandController.text.trim();
        if (_timeout > 0) params['timeout'] = _timeout.round().toString();
        _addFilters(params);
        return _formatUrl('execute', params);

      case _ActionType.snippet:
        params['connection'] = _selectedConnection!.label;
        params['name'] = _selectedSnippet!.label;
        for (final entry in _variableControllers.entries) {
          final value = entry.value.text.trim();
          if (value.isNotEmpty) {
            params['var_${entry.key}'] = value;
          }
        }
        return _formatUrl('snippet', params);

      case _ActionType.batch:
        // Resolve IDs to labels from the connection list
        final connectionsAsync = ref.read(filteredConnectionsProvider);
        final allConnections = connectionsAsync.valueOrNull ?? [];
        final selectedLabels = allConnections
            .where((c) => _selectedConnectionIds.contains(c.id))
            .map((c) => c.label)
            .toList();
        params['connections'] = selectedLabels.join(',');
        params['command'] = _commandController.text.trim();
        if (_timeout > 0) params['timeout'] = _timeout.round().toString();
        params['parallel'] = 'true';
        _addFilters(params);
        return _formatUrl('batch', params);

      case _ActionType.connect:
        params['host'] = _selectedConnection!.host;
        params['port'] = _selectedConnection!.port.toString();
        return _formatUrl('connect', params);

      case _ActionType.workflow:
        if (_selectedWorkflow != null) {
          params['name'] = _selectedWorkflow!.name;
        }
        return _formatUrl('workflow', params);
    }
  }

  void _addFilters(Map<String, String> params) {
    final grep = _grepController.text.trim();
    final head = _headController.text.trim();
    final tail = _tailController.text.trim();
    final webhook = _webhookController.text.trim();
    if (grep.isNotEmpty) params['grep'] = grep;
    if (head.isNotEmpty) params['head'] = head;
    if (tail.isNotEmpty) params['tail'] = tail;
    if (webhook.isNotEmpty) params['callback'] = webhook;
  }

  String _formatUrl(String action, Map<String, String> params) {
    final query = params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    return 'zestssh://$action?$query';
  }

  String _buildTaskerIntent() {
    final filters = <String, String>{};
    _addFilters(filters);
    final allConnections = ref.read(filteredConnectionsProvider).valueOrNull ?? [];
    return taskerIntentText(
      action: _selectedAction!.name,
      key: _keyInExamples,
      connection: _selectedConnection?.label,
      connections: [
        for (final c in allConnections)
          if (_selectedConnectionIds.contains(c.id)) c.label,
      ],
      command: _commandController.text.trim(),
      timeout: _timeout.round(),
      filters: filters,
      snippet: _selectedSnippet?.label,
      variables: {
        for (final entry in _variableControllers.entries)
          if (entry.value.text.trim().isNotEmpty) entry.key: entry.value.text.trim(),
      },
      workflow: _selectedWorkflow?.name,
    );
  }

  String _buildAdbCommand() {
    final url = _buildUrl();
    return 'adb shell am start -a android.intent.action.VIEW '
        '-d "$url"';
  }

  @override
  void dispose() {
    _commandController.removeListener(_onFieldChanged);
    _pageController.dispose();
    _commandController.dispose();
    _grepController.dispose();
    _headController.dispose();
    _tailController.dispose();
    _webhookController.dispose();
    for (final c in _variableControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.autoWizTitle),
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          icon: const Icon(LucideIcons.arrowLeft),
          onPressed: () => _confirmExit(context),
        ),
      ),
      body: Column(
        children: [
          // ── Step indicator ────────────────────────────────────────
          _StepIndicator(
            currentStep: _currentPage,
            totalSteps: _totalSteps,
            maxVisitedStep: _maxVisitedPage,
            onTap: _goToPage,
          ),
          const SizedBox(height: 8),

          // ── Page content ─────────────────────────────────────────
          Expanded(
            child: PageView(
              controller: _pageController,
              physics: const NeverScrollableScrollPhysics(),
              children: _buildPages(),
            ),
          ),

          // ── Navigation bar ───────────────────────────────────────
          _NavigationBar(
            currentPage: _currentPage,
            totalSteps: _totalSteps,
            canAdvance: _canAdvance,
            onBack: _prevPage,
            onNext: _nextPage,
            isLastStep: _currentPage == _totalSteps - 1,
          ),
        ],
      ),
    );
  }

  List<Widget> _buildPages() {
    final pages = <Widget>[
      _ActionStep(
        selected: _selectedAction,
        onSelect: (action) => setState(() {
          _selectedAction = action;
          // Reset downstream state on action change
          _selectedConnection = null;
          _selectedConnectionIds.clear();
          _selectedSnippet = null;
          _selectedWorkflow = null;
          _commandController.clear();
          _timeout = 0;
          _grepController.clear();
          _headController.clear();
          _tailController.clear();
          _webhookController.clear();
          for (final c in _variableControllers.values) {
            c.dispose();
          }
          _variableControllers.clear();
        }),
      ),
      if (_selectedAction == _ActionType.workflow)
        _WorkflowPickerStep(
          selectedWorkflow: _selectedWorkflow,
          onSelect: (w) => setState(() => _selectedWorkflow = w),
        )
      else
        _ConnectionStep(
          isBatch: _selectedAction == _ActionType.batch,
          selectedConnection: _selectedConnection,
          selectedIds: _selectedConnectionIds,
          onSingleSelect: (c) => setState(() => _selectedConnection = c),
          onToggleBatch: (id) => setState(() {
            if (_selectedConnectionIds.contains(id)) {
              _selectedConnectionIds.remove(id);
            } else {
              _selectedConnectionIds.add(id);
            }
          }),
        ),
    ];

    // Configure step (skipped for Connect and Workflow)
    if (_selectedAction != _ActionType.connect &&
        _selectedAction != _ActionType.workflow) {
      pages.add(
        _ConfigureStep(
          action: _selectedAction ?? _ActionType.execute,
          commandController: _commandController,
          timeout: _timeout,
          onTimeoutChanged: (v) => setState(() => _timeout = v),
          selectedSnippet: _selectedSnippet,
          onSnippetSelected: (s) {
            setState(() {
              _selectedSnippet = s;
              // Rebuild variable controllers for the new snippet
              for (final c in _variableControllers.values) {
                c.dispose();
              }
              _variableControllers.clear();
              if (s != null) {
                final vars = parseVariables(s.command);
                for (final v in vars) {
                  _variableControllers[v] = TextEditingController();
                }
              }
            });
          },
          variableControllers: _variableControllers,
          selectedConnectionCount: _selectedConnectionIds.length,
        ),
      );
    }

    // Filters step (Execute and Batch only)
    if (_selectedAction == _ActionType.execute ||
        _selectedAction == _ActionType.batch) {
      pages.add(
        _FiltersStep(
          grepController: _grepController,
          headController: _headController,
          tailController: _tailController,
          webhookController: _webhookController,
        ),
      );
    }

    // Result step (always last) - only build URL when all required
    // selections are made to avoid null errors during earlier steps
    final bool isReady;
    if (_selectedAction == _ActionType.workflow) {
      isReady = _selectedWorkflow != null;
    } else {
      final hasConnection = _selectedAction == _ActionType.batch
          ? _selectedConnectionIds.isNotEmpty
          : _selectedConnection != null;
      isReady = _selectedAction != null &&
          hasConnection &&
          (_selectedAction == _ActionType.connect ||
              _selectedAction == _ActionType.snippet
                  ? _selectedSnippet != null
                  : _commandController.text.trim().isNotEmpty);
    }

    pages.add(
      _ResultStep(
        url: isReady ? _buildUrl() : '',
        taskerIntent: isReady ? _buildTaskerIntent() : '',
        adbCommand: isReady ? _buildAdbCommand() : '',
        actionType: _selectedAction,
        madeHere: _madeHere,
        onMade: (made) => setState(() => _madeHere = made),
      ),
    );

    return pages;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step indicator
// ═══════════════════════════════════════════════════════════════════════

class _StepIndicator extends StatelessWidget {
  final int currentStep;
  final int totalSteps;
  final int maxVisitedStep;
  final ValueChanged<int>? onTap;

  const _StepIndicator({
    required this.currentStep,
    required this.totalSteps,
    required this.maxVisitedStep,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // Swipe left/right on the bar area to navigate
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -200) {
          // Swipe left → next page
          if (currentStep < maxVisitedStep) {
            onTap?.call(currentStep + 1);
          }
        } else if (details.primaryVelocity! > 200) {
          // Swipe right → previous page
          if (currentStep > 0) {
            onTap?.call(currentStep - 1);
          }
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        // Tall hit area for easy tapping, bar itself is inside
        child: SizedBox(
          height: 32,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: List.generate(totalSteps, (i) {
              final isActive = i == currentStep;
              final isVisited = i <= maxVisitedStep;
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i < totalSteps - 1 ? 6 : 0),
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: isVisited && i != currentStep
                        ? () => onTap?.call(i)
                        : null,
                    // Full 32px hit area, bar is 6px centered inside
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        height: 6,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(3),
                          color: isActive
                              ? AppColors.orange
                              : isVisited
                                  ? AppColors.orange.withValues(alpha: 0.4)
                                  : AppColors.surfaceLight,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Bottom navigation bar
// ═══════════════════════════════════════════════════════════════════════

class _NavigationBar extends StatelessWidget {
  final int currentPage;
  final int totalSteps;
  final bool canAdvance;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final bool isLastStep;

  const _NavigationBar({
    required this.currentPage,
    required this.totalSteps,
    required this.canAdvance,
    required this.onBack,
    required this.onNext,
    required this.isLastStep,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      padding: EdgeInsets.fromLTRB(
        24,
        12,
        24,
        12 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: AppColors.surface,
        border: Border(top: BorderSide(color: AppColors.divider)),
      ),
      child: Row(
        children: [
          if (currentPage > 0)
            TextButton.icon(
              onPressed: onBack,
              icon: const Icon(LucideIcons.arrowLeft, size: 18),
              label: Text(l10n.back),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.onSurfaceVariant,
              ),
            )
          else
            const SizedBox.shrink(),
          const Spacer(),
          if (!isLastStep)
            FilledButton.icon(
              onPressed: canAdvance ? onNext : null,
              icon: const Icon(LucideIcons.arrowRight, size: 18),
              label: Text(l10n.next),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: AppColors.onBrand(AppColors.orange),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding:
                    const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              ),
            ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 1 -- Choose Action
// ═══════════════════════════════════════════════════════════════════════

class _ActionStep extends StatelessWidget {
  final _ActionType? selected;
  final ValueChanged<_ActionType> onSelect;

  const _ActionStep({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.autoWizChooseAction,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.autoWizChooseActionSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),
          _ActionCard(
            icon: LucideIcons.terminal,
            title: l10n.autoWizExecuteTitle,
            description: l10n.autoWizExecuteDesc,
            isSelected: selected == _ActionType.execute,
            onTap: () => onSelect(_ActionType.execute),
          ),
          const SizedBox(height: 10),
          _ActionCard(
            icon: LucideIcons.code,
            title: l10n.autoWizSnippetTitle,
            description: l10n.autoWizSnippetDesc,
            isSelected: selected == _ActionType.snippet,
            onTap: () => onSelect(_ActionType.snippet),
          ),
          const SizedBox(height: 10),
          _ActionCard(
            icon: LucideIcons.server,
            title: l10n.autoWizBatchTitle,
            description: l10n.autoWizBatchDesc,
            isSelected: selected == _ActionType.batch,
            onTap: () => onSelect(_ActionType.batch),
          ),
          const SizedBox(height: 10),
          _ActionCard(
            icon: LucideIcons.link,
            title: l10n.commonConnect,
            description: l10n.autoWizConnectDesc,
            isSelected: selected == _ActionType.connect,
            onTap: () => onSelect(_ActionType.connect),
          ),
          const SizedBox(height: 10),
          _ActionCard(
            icon: LucideIcons.gitFork,
            title: l10n.autoWizWorkflowTitle,
            description: l10n.autoWizWorkflowDesc,
            isSelected: selected == _ActionType.workflow,
            onTap: () => onSelect(_ActionType.workflow),
          ),
        ],
      ),
    );
  }
}

class _ActionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final bool isSelected;
  final VoidCallback onTap;

  const _ActionCard({
    required this.icon,
    required this.title,
    required this.description,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.orange.withValues(alpha: 0.08)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppColors.orange
                : AppColors.divider,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isSelected
                    ? AppColors.orange.withValues(alpha: 0.15)
                    : AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 22,
                color: isSelected ? AppColors.accentInk : AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: isSelected
                          ? AppColors.accentInk
                          : AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: TextStyle(
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            if (isSelected)
              Icon(LucideIcons.checkCircle2,
                  size: 20, color: AppColors.accentInk),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 2 -- Pick Connection(s)
// ═══════════════════════════════════════════════════════════════════════

class _ConnectionStep extends ConsumerWidget {
  final bool isBatch;
  final Connection? selectedConnection;
  final Set<String> selectedIds;
  final ValueChanged<Connection> onSingleSelect;
  final ValueChanged<String> onToggleBatch;

  const _ConnectionStep({
    required this.isBatch,
    required this.selectedConnection,
    required this.selectedIds,
    required this.onSingleSelect,
    required this.onToggleBatch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(filteredConnectionsProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            isBatch ? l10n.autoWizSelectServers : l10n.autoWizPickConnection,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            isBatch
                ? l10n.autoWizSelectServersSubtitle
                : l10n.autoWizPickConnectionSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          if (isBatch && selectedIds.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              l10n.autoWizServersSelected(selectedIds.length),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.accentInk,
              ),
            ),
          ],
          const SizedBox(height: 16),
          Expanded(
            child: connectionsAsync.when(
              data: (connections) {
                if (connections.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.server,
                            size: 48, color: AppColors.onSurfaceDim),
                        const SizedBox(height: 12),
                        Text(
                          l10n.autoWizNoConnections,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.autoWizNoConnectionsHint,
                          style: TextStyle(
                            color: AppColors.onSurfaceDim,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  itemCount: connections.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 6),
                  itemBuilder: (context, index) {
                    final conn = connections[index];
                    final isSelected = isBatch
                        ? selectedIds.contains(conn.id)
                        : selectedConnection?.id == conn.id;
                    // A host that runs no command: dimmed, with why.
                    final why = noCommandReason(conn, l10n);
                    return _ConnectionTile(
                      connection: conn,
                      isSelected: isSelected,
                      isBatch: isBatch,
                      unavailableReason: why,
                      onTap: why != null
                          ? null
                          : () {
                              if (isBatch) {
                                onToggleBatch(conn.id);
                              } else {
                                onSingleSelect(conn);
                              }
                            },
                    );
                  },
                );
              },
              loading: () => Center(
                child: CircularProgressIndicator(color: AppColors.orange),
              ),
              error: (_, _) => Center(
                child: Text(
                  l10n.autoWizErrorConnections,
                  style: TextStyle(color: AppColors.error),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  final Connection connection;
  final bool isSelected;
  final bool isBatch;

  /// Why it cannot be chosen; null where it can.
  final String? unavailableReason;
  final VoidCallback? onTap;

  const _ConnectionTile({
    required this.connection,
    required this.isSelected,
    required this.isBatch,
    this.unavailableReason,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final why = unavailableReason;
    final tile = GestureDetector(
      key: ValueKey('wizard-host-${connection.id}'),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.orange.withValues(alpha: 0.08)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppColors.orange : AppColors.divider,
          ),
        ),
        child: Row(
          children: [
            HostGlyph(host: connection, size: 26),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Recording mode: a host label and an address, masked.
                  RedactedText(
                    Redactable.host(connection.label),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  RedactedText(
                    Redactable.address(hostWithPort(connection.host, connection.port)),
                    style: TextStyle(
                      fontSize: 12,
                      fontFamily: 'JetBrainsMono',
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
                  if (why != null) ...[
                    const SizedBox(height: 2),
                    Text(why, style: TextStyle(fontSize: 11.5, color: AppColors.onSurfaceDim)),
                  ],
                ],
              ),
            ),
            if (isBatch)
              Icon(
                isSelected
                    ? LucideIcons.checkSquare
                    : LucideIcons.square,
                size: 22,
                color: isSelected ? AppColors.accentInk : AppColors.onSurfaceDim,
              )
            else
              Icon(
                isSelected
                    ? LucideIcons.circleDot
                    : LucideIcons.circle,
                size: 22,
                color: isSelected ? AppColors.accentInk : AppColors.onSurfaceDim,
              ),
          ],
        ),
      ),
    );
    return why == null ? tile : Opacity(opacity: 0.55, child: tile);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 2b -- Pick Workflow (workflow action only)
// ═══════════════════════════════════════════════════════════════════════

class _WorkflowPickerStep extends ConsumerWidget {
  final Workflow? selectedWorkflow;
  final ValueChanged<Workflow> onSelect;

  const _WorkflowPickerStep({
    required this.selectedWorkflow,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final workflows = ref.watch(automationWorkflowsProvider).valueOrNull ?? const <Workflow>[];

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.autoWizPickWorkflow,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.autoWizPickWorkflowSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 16),
          Expanded(
            child: workflows.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.gitFork,
                            size: 48, color: AppColors.onSurfaceDim),
                        const SizedBox(height: 12),
                        Text(
                          l10n.autoWizNoWorkflows,
                          style: TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l10n.autoWizNoWorkflowsHint,
                          style: TextStyle(
                            color: AppColors.onSurfaceDim,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: workflows.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      final wf = workflows[index];
                      final isSelected = selectedWorkflow?.id == wf.id;
                      return GestureDetector(
                        onTap: () => onSelect(wf),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? AppColors.orange.withValues(alpha: 0.08)
                                : AppColors.surface,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected
                                  ? AppColors.orange
                                  : AppColors.divider,
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                LucideIcons.gitFork,
                                size: 20,
                                color: isSelected
                                    ? AppColors.accentInk
                                    : AppColors.onSurfaceDim,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      wf.name,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: AppColors.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      '${l10n.autoWizStepCount(wf.steps.length)}'
                                      '${wf.description != null && wf.description!.isNotEmpty ? ' · ${wf.description}' : ''}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: AppColors.onSurfaceDim,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              Icon(
                                isSelected
                                    ? LucideIcons.circleDot
                                    : LucideIcons.circle,
                                size: 22,
                                color: isSelected
                                    ? AppColors.accentInk
                                    : AppColors.onSurfaceDim,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 3 -- Configure
// ═══════════════════════════════════════════════════════════════════════

class _ConfigureStep extends ConsumerWidget {
  final _ActionType action;
  final TextEditingController commandController;
  final double timeout;
  final ValueChanged<double> onTimeoutChanged;
  final Snippet? selectedSnippet;
  final ValueChanged<Snippet?> onSnippetSelected;
  final Map<String, TextEditingController> variableControllers;
  final int selectedConnectionCount;

  const _ConfigureStep({
    required this.action,
    required this.commandController,
    required this.timeout,
    required this.onTimeoutChanged,
    required this.selectedSnippet,
    required this.onSnippetSelected,
    required this.variableControllers,
    required this.selectedConnectionCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.autoWizConfigure,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            action == _ActionType.snippet
                ? l10n.autoWizConfigureSnippetSubtitle
                : action == _ActionType.batch
                    ? l10n.autoWizConfigureBatchSubtitle(selectedConnectionCount)
                    : l10n.autoWizConfigureExecuteSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 20),

          if (action == _ActionType.snippet) ...[
            _buildSnippetSection(context, ref),
          ] else ...[
            _buildCommandSection(context),
          ],

          // Timeout slider (Execute and Batch)
          if (action == _ActionType.execute || action == _ActionType.batch) ...[
            const SizedBox(height: 24),
            Row(
              children: [
                Text(
                  l10n.autoWizTimeout,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: AppColors.onSurface,
                  ),
                ),
                const Spacer(),
                Text(
                  timeout == 0
                      ? l10n.autoWizTimeoutDefault
                      : l10n.autoWizTimeoutSeconds(timeout.round()),
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: 'JetBrainsMono',
                    fontWeight: FontWeight.w600,
                    color: AppColors.accentInk,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SliderTheme(
              data: SliderThemeData(
                activeTrackColor: AppColors.orange,
                inactiveTrackColor: AppColors.surfaceLight,
                thumbColor: AppColors.orange,
                overlayColor: AppColors.orange.withValues(alpha: 0.12),
                trackHeight: 4,
              ),
              child: Slider(
                value: timeout,
                min: 0,
                max: 300,
                divisions: 60,
                onChanged: onTimeoutChanged,
              ),
            ),
            Text(
              l10n.autoWizTimeoutHelp,
              style: TextStyle(fontSize: 11, color: AppColors.onSurfaceDim),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCommandSection(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.autoWizCommand,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: commandController,
          maxLines: 3,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 13,
            color: AppColors.onSurface,
          ),
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.autoWizCommandHint,
            hintStyle: TextStyle(
              color: AppColors.onSurfaceDim,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
            filled: true,
            fillColor: AppColors.surfaceDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.orange),
            ),
            contentPadding: const EdgeInsets.all(14),
          ),
        ),
      ],
    );
  }

  Widget _buildSnippetSection(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final snippetsAsync = ref.watch(snippetsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.autoWizSnippet,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w500,
            color: AppColors.onSurface,
          ),
        ),
        const SizedBox(height: 8),
        snippetsAsync.when(
          data: (snippets) {
            if (snippets.isEmpty) {
              return Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDark,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.divider),
                ),
                child: Text(
                  l10n.autoWizNoSnippets,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
              );
            }
            // The app's select (a Material dropdown in a box of its own;
            // found in a design audit).
            return ZestSelect<Snippet>(
              value: selectedSnippet,
              hint: l10n.autoWizSelectSnippet,
              items: [for (final s in snippets) ZestSelectItem(s, s.label)],
              onChanged: onSnippetSelected,
            );
          },
          loading: () => Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: CircularProgressIndicator(color: AppColors.orange),
            ),
          ),
          error: (_, _) => Text(
            l10n.autoWizErrorSnippets,
            style: TextStyle(color: AppColors.error),
          ),
        ),

        // Show snippet preview
        if (selectedSnippet != null) ...[
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.surfaceDark,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.divider),
            ),
            child: Text(
              selectedSnippet!.command,
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 12,
                height: 1.5,
                color: AppColors.onSurfaceVariant,
              ),
            ),
          ),
        ],

        // Variable fields
        if (variableControllers.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            l10n.autoWizVariables,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.autoWizVariablesHint,
            style: TextStyle(fontSize: 11, color: AppColors.onSurfaceDim),
          ),
          const SizedBox(height: 12),
          ...variableControllers.entries.map((entry) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: entry.value,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 13,
                  color: AppColors.onSurface,
                ),
                decoration: InputDecoration(
                  labelText: entry.key,
                  labelStyle: TextStyle(
                    color: AppColors.accentInk,
                    fontSize: 13,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceDark,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.divider),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.divider),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide(color: AppColors.orange),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 4 -- Filters (Execute / Batch only)
// ═══════════════════════════════════════════════════════════════════════

class _FiltersStep extends StatelessWidget {
  final TextEditingController grepController;
  final TextEditingController headController;
  final TextEditingController tailController;
  final TextEditingController webhookController;

  const _FiltersStep({
    required this.grepController,
    required this.headController,
    required this.tailController,
    required this.webhookController,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.autoWizFilters,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.autoWizFiltersSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: AppColors.orange.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.info,
                    size: 14, color: AppColors.accentInk),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l10n.autoWizFiltersOptionalNote,
                    style: TextStyle(fontSize: 11, color: AppColors.accentInk),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // Grep
          _FilterField(
            controller: grepController,
            label: l10n.autoWizGrepLabel,
            hint: 'e.g. error|warning',
            icon: LucideIcons.search,
            helpText: l10n.autoWizGrepHelp,
          ),
          const SizedBox(height: 16),

          // Head / Tail side by side
          Row(
            children: [
              Expanded(
                child: _FilterField(
                  controller: headController,
                  label: l10n.autoWizHead,
                  hint: 'e.g. 10',
                  icon: LucideIcons.arrowUpToLine,
                  helpText: l10n.autoWizHeadHelp,
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _FilterField(
                  controller: tailController,
                  label: l10n.autoWizTail,
                  hint: 'e.g. 20',
                  icon: LucideIcons.arrowDownToLine,
                  helpText: l10n.autoWizTailHelp,
                  keyboardType: TextInputType.number,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // Webhook
          _FilterField(
            controller: webhookController,
            label: l10n.autoWizWebhookLabel,
            hint: 'https://hooks.slack.com/...',
            icon: LucideIcons.webhook,
            helpText: l10n.autoWizWebhookHelp,
            keyboardType: TextInputType.url,
          ),
        ],
      ),
    );
  }
}

class _FilterField extends StatelessWidget {
  final TextEditingController controller;
  final String label;
  final String hint;
  final IconData icon;
  final String helpText;
  final TextInputType keyboardType;

  const _FilterField({
    required this.controller,
    required this.label,
    required this.hint,
    required this.icon,
    required this.helpText,
    this.keyboardType = TextInputType.text,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: AppColors.onSurfaceVariant),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 13,
            color: AppColors.onSurface,
          ),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(
              color: AppColors.onSurfaceDim,
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
            ),
            filled: true,
            fillColor: AppColors.surfaceDark,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.orange),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            isDense: true,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          helpText,
          style: TextStyle(fontSize: 11, color: AppColors.onSurfaceDim),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Step 5 -- Result
// ═══════════════════════════════════════════════════════════════════════

class _ResultStep extends ConsumerWidget {
  final String url;
  final String taskerIntent;
  final String adbCommand;
  final _ActionType? actionType;

  /// The key made on this page and the key itself, or null: the examples
  /// then carry [automationKeyPlaceholder].
  final ({AutomationApiKey key, String secret})? madeHere;
  final ValueChanged<({AutomationApiKey key, String secret})> onMade;

  const _ResultStep({
    required this.url,
    required this.taskerIntent,
    required this.adbCommand,
    required this.actionType,
    required this.madeHere,
    required this.onMade,
  });

  Future<void> _copy(
      BuildContext context, WidgetRef ref, String text, String label) async {
    // The clipboard payload is the REAL url / intent / command, live API key
    // and host included. While recording, the gate makes the user turn the
    // mode off before the secret leaves the app onto the clipboard.
    if (!await confirmRevealWhileRecording(context, ref)) return;
    // Taken off the clipboard as every secret copied is (it was left there).
    await SecretClipboard.copy(text);
    if (!context.mounted) return;
    final l10n = AppLocalizations.of(context)!;
    showTopSnackBar(
      context,
      l10n.autoWizCopied(label),
      duration: const Duration(seconds: 2),
    );
  }

  /// Makes a key for this automation: the examples carry it while this page
  /// is open, and it is shown once in its dialog, as everywhere a key is made.
  Future<void> _generateKey(BuildContext context, WidgetRef ref, String label) async {
    final made = ref.read(automationKeysProvider.notifier).createKey(label);
    onMade(made);
    await showApiKeyOnceDialog(context, apiKey: made.key, secret: made.secret);
  }

  Future<void> _showGenerateDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final label = await showZestInputDialog(
      context: context,
      title: l10n.autoWizCreateApiKey,
      icon: LucideIcons.key,
      fieldLabel: l10n.autoWizKeyLabel,
      hintText: l10n.autoWizKeyLabelHint,
      confirmLabel: l10n.create,
      validator: (v) => v.trim().isEmpty ? l10n.autoWizEnterLabel : null,
    );
    if (label == null || label.trim().isEmpty || !context.mounted) return;
    await _generateKey(context, ref, label.trim());
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final keys = ref.watch(automationKeysProvider);
    // The key made here, while it is still there (deleted meanwhile, the
    // examples would carry a key that no longer works).
    final made = madeHere != null && keys.any((k) => k.id == madeHere!.key.id) ? madeHere : null;

    // Recording mode: the URL, the Tasker intent and the ADB command all embed
    // the LIVE API key and the connection host / label. Show a redacted copy on
    // screen (the key becomes the password mask; the rest goes through the
    // free-text rule, which masks an address-shaped or registered host). Copy
    // and Share stay gated, so revealing the real value is a deliberate act
    // that turns recording off first.
    final recording = ref.watch(recordingModeProvider);
    final apiKeyValue = made?.secret;
    String shown(String content) {
      if (!recording) return content;
      var out = content;
      if (apiKeyValue != null && apiKeyValue.isNotEmpty) {
        out = out.replaceAll(apiKeyValue, Redactor.passwordMask);
      }
      return Redactable.freeText(out).display;
    }

    // No API keys -- show generate button
    if (keys.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.keyRound,
                  size: 56,
                  color: AppColors.onSurfaceDim.withValues(alpha: 0.5)),
              const SizedBox(height: 16),
              Text(
                l10n.autoWizApiKeyRequired,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: AppColors.onSurface,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.autoWizApiKeyRequiredDesc,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () => _showGenerateDialog(context, ref),
                icon: const Icon(LucideIcons.plus),
                label: Text(l10n.autoWizGenerateApiKey),
                style: FilledButton.styleFrom(
                  backgroundColor: AppColors.brandOrange,
                  foregroundColor: AppColors.onBrand(AppColors.brandOrange),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.autoWizYourAutomation,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l10n.autoWizYourAutomationSubtitle,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),

          // ── Credential warning ──
          // SECURITY: with a key made here, the generated URL, Tasker intent
          // and ADB command all embed the live API key. Make it explicit that
          // these are secrets so the user doesn't paste them into a public
          // place / chat / bug report.
          if (made != null) ...[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppColors.orange.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppColors.orange.withValues(alpha: 0.4)),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(LucideIcons.alertTriangle,
                      size: 16, color: AppColors.accentInk),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      // Where the key is revoked: on a phone or tablet in
                      // Settings, Automation, API keys; on a computer under
                      // Automation, API keys (it said "in Settings" on both:
                      // the 3.0 docs check).
                      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS
                          ? l10n.autoWizCredentialWarningPhone
                          : l10n.autoWizCredentialWarning,
                      key: const ValueKey('auto-wiz-credential-warning'),
                      style: TextStyle(fontSize: 11, color: AppColors.accentInk),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
          ],

          // ── The key in the examples ──
          // A key is shown once, when it is made, and only its hash is kept,
          // so a key from before cannot be put in here: the examples carry the
          // one made on this page, or YOUR_KEY for the person to paste theirs.
          Text(
            l10n.autoWizApiKey,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: AppColors.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            key: const ValueKey('wizard-key-note'),
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: AppColors.surfaceDark,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.divider),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  made != null
                      ? l10n.autoWizKeyMadeHere(made.key.label)
                      : l10n.autoWizKeyPlaceholderNote(automationKeyPlaceholder),
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary, height: 1.4),
                ),
                if (made == null) ...[
                  const SizedBox(height: 8),
                  TextButton.icon(
                    key: const ValueKey('wizard-make-key'),
                    onPressed: () => _showGenerateDialog(context, ref),
                    icon: const Icon(LucideIcons.plus, size: 16),
                    label: Text(l10n.autoWizMakeKeyForThis, style: const TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accentInk,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 16),

          // ── URL ──
          _ResultCard(
            title: l10n.autoWizUrlScheme,
            icon: LucideIcons.link,
            content: shown(url),
            onCopy: () => _copy(context, ref, url, l10n.autoWizCopyLabelUrl),
          ),
          const SizedBox(height: 14),

          // ── MacroDroid instructions ──
          // Static setup steps, no secret, so the content is not redacted; the
          // copy still hands over the real URL, so it is gated.
          _ResultCard(
            title: 'MacroDroid',
            icon: Icons.android_rounded,
            content: l10n.autoWizMacroDroidSteps,
            onCopy: () =>
                _copy(context, ref, url, l10n.autoWizCopyLabelUrlMacroDroid),
          ),
          const SizedBox(height: 14),

          // ── Tasker ──
          _ResultCard(
            title: l10n.autoWizTaskerIntent,
            icon: LucideIcons.settings2,
            content: shown(taskerIntent),
            onCopy: () => _copy(
                context, ref, taskerIntent, l10n.autoWizCopyLabelTaskerIntent),
          ),
          const SizedBox(height: 14),

          // ── ADB ──
          _ResultCard(
            title: l10n.autoWizAdbCommand,
            icon: Icons.adb_rounded,
            content: shown(adbCommand),
            onCopy: () => _copy(
                context, ref, adbCommand, l10n.autoWizCopyLabelAdbCommand),
          ),
          const SizedBox(height: 20),

          // ── Share button ──
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () async {
                // Sharing sends the real URL (live key + host) to another app;
                // gate it behind turning recording off, like Copy.
                if (!await confirmRevealWhileRecording(context, ref)) return;
                await Share.share(url);
              },
              icon: const Icon(LucideIcons.share2, size: 18),
              label: Text(l10n.autoWizShareUrl),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.orange,
                foregroundColor: AppColors.onBrand(AppColors.orange),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  final String title;
  final IconData icon;
  final String content;
  final VoidCallback onCopy;

  const _ResultCard({
    required this.title,
    required this.icon,
    required this.content,
    required this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 8, 0),
            child: Row(
              children: [
                Icon(icon, size: 16, color: AppColors.accentInk),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.onSurface,
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: onCopy,
                  icon: const Icon(LucideIcons.copy, size: 16),
                  color: AppColors.onSurfaceVariant,
                  tooltip: l10n.copy,
                  visualDensity: VisualDensity.compact,
                  padding: const EdgeInsets.all(6),
                  constraints: const BoxConstraints(),
                ),
              ],
            ),
          ),
          // Content
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: AppColors.surfaceDark,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                content,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 11,
                  height: 1.6,
                  color: AppColors.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
