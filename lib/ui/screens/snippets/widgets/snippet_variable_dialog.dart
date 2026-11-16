import 'dart:convert';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/shell_fill.dart';
import 'package:zestssh/theme/zest_tokens.dart';

/// Callback type for executing a command on the active SSH session.
///
/// Returns stdout output or null on failure.
typedef CommandExecutor = Future<String?> Function(String command);

/// Shows the variable input dialog as a sequential picker.
///
/// Variables are resolved left-to-right. Each shows its picker/input
/// before moving to the next. Supports three types:
/// - Free text (`${VAR}`) - text field
/// - Inline list (`$[a,b,c]`) - option picker
/// - Dynamic list (`$[DOCKER]`) - queries SSH, then option picker
///
/// Returns a map of variable key → selected/entered value, or null if cancelled.
/// The last step's button says [doneLabel] (what happens next: "Run" for a run
/// on hosts), or "Paste" where none is given.
///
/// [only], where given, is the keys of the variables to ask for: every variable
/// of [command] without a default otherwise. [given] is the values it has
/// already, which its preview shows. [note] says something of where the values
/// go, above what is asked.
Future<Map<String, String>?> showVariableInputDialog({
  required BuildContext context,
  required List<String> variables,
  required String snippetLabel,
  String? command,
  CommandExecutor? executeCommand,
  String? doneLabel,
  Set<String>? only,
  Map<String, String> given = const {},
  String? note,
}) async {
  final values = await _askVariables(
    context: context,
    variables: variables,
    snippetLabel: snippetLabel,
    command: command,
    executeCommand: executeCommand,
    doneLabel: doneLabel,
    only: only,
    given: given,
    note: note,
  );
  // A masked variable's value (`${VAR:secret}`) never reaches a team
  // session log, wherever the session echoes it.
  if (values != null && command != null) {
    for (final v in parseVariablesWithOptions(command)) {
      final value = v.secret ? values[v.key] : null;
      if (value != null) filledForms(value).forEach(TeamSessionLogs.addSecret);
    }
  }
  return values;
}

Future<Map<String, String>?> _askVariables({
  required BuildContext context,
  required List<String> variables,
  required String snippetLabel,
  String? command,
  CommandExecutor? executeCommand,
  String? doneLabel,
  Set<String>? only,
  Map<String, String> given = const {},
  String? note,
}) async {
  // Parse full variable info from the command
  final parsedVars = command != null
      ? parseVariablesWithOptions(command)
      : variables
            .map((v) => ParsedVariable(
                  name: v,
                  type: VariableType.freeText,
                  matchPattern: '\${$v}',
                  key: v,
                ))
            .toList();

  if (parsedVars.isEmpty) return {};

  // Variables that carry a `${VAR:-default}` default are resolved silently and
  // NOT prompted for. Seed their values and prompt only for the remainder.
  bool asks(ParsedVariable v) => only?.contains(v.key) ?? !v.hasDefault;
  final seeds = <String, String>{
    for (final v in parsedVars)
      if (v.hasDefault && !asks(v)) v.key: v.defaultValue!,
    ...given,
  };
  final promptVars = parsedVars.where(asks).toList();

  // Everything had a default → nothing to ask; resolve straight away.
  if (promptVars.isEmpty) return seeds;

  // The app's dialog (3.4), a phone's sheet: the steps in its body, Back (a
  // side option), Cancel and Next (or Paste) in its footer
  // ([_SequentialPicker] draws it). A phone's was a sheet of its own.
  return showZestModal<Map<String, String>>(
    context: context,
    size: ZestModalSize.compact,
    child: _SequentialPicker(
      parsedVars: promptVars,
      seedValues: seeds,
      snippetLabel: snippetLabel,
      command: command,
      executeCommand: executeCommand,
      doneLabel: doneLabel,
      note: note,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════
//  Sequential Picker - steps through variables one at a time
// ═══════════════════════════════════════════════════════════════════

class _SequentialPicker extends StatefulWidget {
  final List<ParsedVariable> parsedVars;

  /// Pre-resolved values for variables that carry a `${VAR:-default}` default -
  /// not prompted for, but merged into the result and used in the live preview.
  final Map<String, String> seedValues;
  final String snippetLabel;
  final String? command;
  final CommandExecutor? executeCommand;

  /// What the last step's button says ("Paste" where null).
  final String? doneLabel;

  /// Something of where the values go, above what is asked.
  final String? note;

  const _SequentialPicker({
    required this.parsedVars,
    this.seedValues = const {},
    required this.snippetLabel,
    this.command,
    this.executeCommand,
    this.doneLabel,
    this.note,
  });

  @override
  State<_SequentialPicker> createState() => _SequentialPickerState();
}

class _SequentialPickerState extends State<_SequentialPicker> {
  int _currentStep = 0;
  late final Map<String, String> _values;
  late final Map<String, TextEditingController> _textControllers;

  // Dynamic list state
  final Map<String, List<String>> _dynamicOptions = {};
  final Map<String, bool> _dynamicLoading = {};
  final Map<String, String?> _dynamicErrors = {};

  @override
  void initState() {
    super.initState();
    // Start with the defaulted (un-prompted) values so the live preview
    // resolves them and the returned map carries them through.
    _values = {...widget.seedValues};
    _textControllers = {};

    for (final v in widget.parsedVars) {
      if (v.isFreeText) {
        _textControllers[v.key] = TextEditingController();
      } else if (v.isInlineList && v.options.isNotEmpty) {
        // Pre-select first option
        _values[v.key] = v.options.first;
      }
    }

    // Kick off dynamic list loading for the first step if needed
    _loadDynamicIfNeeded(_currentStep);
  }

  @override
  void dispose() {
    for (final c in _textControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _loadDynamicIfNeeded(int step) {
    if (step >= widget.parsedVars.length) return;
    final v = widget.parsedVars[step];
    if (!v.isDynamic) return;
    if (_dynamicOptions.containsKey(v.key)) return; // Already loaded
    if (_dynamicErrors.containsKey(v.key)) return; // Already failed

    _dynamicLoading[v.key] = true;

    final source = v.dynamicSource!;
    final cmd = dynamicListCommands[source];
    if (cmd == null || widget.executeCommand == null) {
      // No command executor or unknown source → fall back to free text
      setState(() {
        _dynamicLoading[v.key] = false;
        _dynamicErrors[v.key] = widget.executeCommand == null
            ? gl10n.snippetVarNoSession
            : gl10n.snippetVarUnknownSource;
        _textControllers[v.key] = TextEditingController();
      });
      return;
    }

    widget.executeCommand!(cmd).then((output) {
      if (!mounted) return;
      if (output == null || output.trim().isEmpty) {
        setState(() {
          _dynamicLoading[v.key] = false;
          _dynamicErrors[v.key] = gl10n.snippetVarNoResults;
          _textControllers[v.key] = TextEditingController();
        });
        return;
      }

      List<String> items;
      if (source == 'PM2') {
        items = parsePm2Output(output);
      } else {
        items = const LineSplitter()
            .convert(output.trim())
            .map((l) => l.trim())
            .where((l) => l.isNotEmpty)
            .toList();
      }

      setState(() {
        _dynamicLoading[v.key] = false;
        if (items.isEmpty) {
          _dynamicErrors[v.key] = gl10n.snippetVarNoResults;
          _textControllers[v.key] = TextEditingController();
        } else {
          _dynamicOptions[v.key] = items;
          _values[v.key] = items.first;
        }
      });
    }).catchError((Object e) {
      if (!mounted) return;
      setState(() {
        _dynamicLoading[v.key] = false;
        _dynamicErrors[v.key] = gl10n.snippetVarQueryFailed;
        _textControllers[v.key] = TextEditingController();
      });
    });
  }

  ParsedVariable get _currentVar => widget.parsedVars[_currentStep];
  bool get _isFirstStep => _currentStep == 0;
  bool get _isLastStep => _currentStep == widget.parsedVars.length - 1;
  int get _totalSteps => widget.parsedVars.length;

  bool get _canProceed {
    final v = _currentVar;
    if (v.isDynamic && (_dynamicLoading[v.key] ?? false)) return false;
    if (v.isFreeText || _hasDynamicFallback(v)) {
      final text = _textControllers[v.key]?.text.trim() ?? '';
      return text.isNotEmpty;
    }
    return _values[v.key]?.isNotEmpty ?? false;
  }

  bool _hasDynamicFallback(ParsedVariable v) {
    return v.isDynamic && _dynamicErrors[v.key] != null;
  }

  void _next() {
    _collectCurrentValue();
    if (_isLastStep) {
      _submit();
      return;
    }
    setState(() {
      _currentStep++;
      _loadDynamicIfNeeded(_currentStep);
    });
  }

  void _back() {
    if (_isFirstStep) return;
    _collectCurrentValue();
    setState(() => _currentStep--);
  }

  void _collectCurrentValue() {
    final v = _currentVar;
    if (v.isFreeText || _hasDynamicFallback(v)) {
      _values[v.key] = _textControllers[v.key]?.text.trim() ?? '';
    }
    // Inline/dynamic list values are set on selection
  }

  void _submit() {
    _collectCurrentValue();
    for (final v in widget.parsedVars) {
      final val = _values[v.key];
      if (val == null || val.isEmpty) return;
    }
    Navigator.pop(context, _values);
  }

  String _previewResolved() {
    if (widget.command == null) return '';
    final partialValues = <String, String>{...widget.seedValues};
    for (final v in widget.parsedVars) {
      final val = _values[v.key];
      if (val != null && val.isNotEmpty) {
        partialValues[v.key] = val;
      } else if (v.isFreeText || _hasDynamicFallback(v)) {
        final text = _textControllers[v.key]?.text.trim() ?? '';
        if (text.isNotEmpty) partialValues[v.key] = text;
      }
    }
    // One typed with dots is not read out beside them.
    for (final v in parseVariablesWithOptions(widget.command!)) {
      if (v.secret && (partialValues[v.key]?.isNotEmpty ?? false)) partialValues[v.key] = kMaskedValueShown;
    }
    return fillPlaceholders(widget.command!, partialValues, doubleBraces: true);
  }

  @override
  Widget build(BuildContext context) => _dialog(context, _currentVar);

  /// The shell (a phone's sheet), with the step as its subtitle, the
  /// progress, the picker and what it will run in its body, and Back (a side
  /// option), Cancel and Next or Paste in its footer.
  Widget _dialog(BuildContext context, ParsedVariable v) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.slidersHorizontal,
      title: widget.snippetLabel,
      subtitle: _totalSteps > 1 ? l10n.snippetVarStep(_currentStep + 1, _totalSteps) : null,
      maxWidth: 500,
      maxHeight: 620,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_totalSteps > 1) ...[
            Row(
              children: List.generate(_totalSteps, (i) {
                final isActive = i == _currentStep;
                final isDone = i < _currentStep;
                return Expanded(
                  child: Container(
                    height: 3,
                    margin: EdgeInsets.only(right: i < _totalSteps - 1 ? 4 : 0),
                    decoration: BoxDecoration(
                      color: isDone
                          ? AppColors.v3TextSecondary
                          : isActive
                              ? AppColors.v3TextSecondary.withValues(alpha: 0.5)
                              : AppColors.v3BorderSubtle,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),
          ],
          if (widget.note case final note?) ...[
            Text(
              note,
              key: const ValueKey('snippet-variable-note'),
              style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 12),
          ],
          _buildVariableBadge(v),
          const SizedBox(height: 16),
          _buildPicker(v),
          const SizedBox(height: 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.v3Background,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppColors.v3BorderSubtle),
            ),
            child: Text(
              // What it will run, with what would draw it wrongly made visible.
              visibleCommand(_previewResolved()),
              key: const ValueKey('snippet-variable-preview'),
              style: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: AppColors.v3TextSecondary,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      tertiaryAction: _isFirstStep ? null : (label: l10n.back, onPressed: _back),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
      primaryKey: const ValueKey('snippet-variable-next'),
      primaryAction: (
        label: _isLastStep ? widget.doneLabel ?? l10n.snippetVarPaste : l10n.next,
        icon: _isLastStep ? LucideIcons.play : LucideIcons.chevronRight,
        onPressed: _canProceed ? _next : null,
      ),
    );
  }

  // ─── Badge showing variable type & name ──────────────────────

  Widget _buildVariableBadge(ParsedVariable v) {
    final IconData icon;
    final String label;
    final Color badgeColor;

    switch (v.type) {
      case VariableType.freeText:
        icon = LucideIcons.pencil;
        label = v.name;
        badgeColor = AppColors.accentInk;
      case VariableType.inlineList:
        icon = LucideIcons.list;
        label = '${v.options.length} options';
        badgeColor = AppColors.categorySystem;
      case VariableType.dynamicList:
        icon = LucideIcons.downloadCloud;
        label = v.name;
        badgeColor = const Color(0xFF10B981);
    }

    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: badgeColor.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 14, color: badgeColor),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'JetBrainsMono',
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: badgeColor,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            v.matchPattern,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.textSecondary.withValues(alpha: 0.5),
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  // ─── Build the appropriate picker for the current variable ────

  Widget _buildPicker(ParsedVariable v) {
    switch (v.type) {
      case VariableType.freeText:
        return _buildFreeTextInput(v);
      case VariableType.inlineList:
        return _buildOptionList(v, v.options);
      case VariableType.dynamicList:
        return _buildDynamicListPicker(v);
    }
  }

  // ─── Free text input ─────────────────────────────────────────

  Widget _buildFreeTextInput(ParsedVariable v) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)!.snippetVarEnterValueFor(v.name),
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: 10),
        TextFormField(
          controller: _textControllers[v.key],
          autofocus: true,
          // A `${VAR:secret}` variable (a token/password) is entered masked and
          // kept out of autocorrect/suggestions.
          obscureText: v.secret,
          enableSuggestions: !v.secret,
          autocorrect: !v.secret,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.snippetVarEnterHint(v.name.toLowerCase()),
            hintStyle: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              color: ZestTokens.textPlaceholder,
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
          ),
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 14,
            color: Color(0xFFD4D4D4),
          ),
          onChanged: (_) => setState(() {}),
          onFieldSubmitted: (_) {
            if (_canProceed) _next();
          },
        ),
      ],
    );
  }

  // ─── Option list (used for both inline & resolved dynamic) ───

  Widget _buildOptionList(ParsedVariable v, List<String> options) {
    final selected = _values[v.key];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              AppLocalizations.of(context)!.snippetVarSelect,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
            const Spacer(),
            Text(
              '${options.length} available',
              style: TextStyle(
                fontSize: 11,
                color: AppColors.textSecondary.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...options.map((option) => _buildOptionTile(
              option: option,
              isSelected: option == selected,
              onTap: () {
                setState(() => _values[v.key] = option);
                // Auto-advance on tap if not last step
                if (!_isLastStep) {
                  Future.delayed(const Duration(milliseconds: 200), () {
                    if (mounted) _next();
                  });
                }
              },
            )),
      ],
    );
  }

  // ─── Dynamic list picker ─────────────────────────────────────

  Widget _buildDynamicListPicker(ParsedVariable v) {
    final isLoading = _dynamicLoading[v.key] ?? false;
    final error = _dynamicErrors[v.key];
    final options = _dynamicOptions[v.key];

    if (isLoading) {
      return _buildLoadingState(v);
    }

    if (error != null) {
      return _buildFallbackTextInput(v, error);
    }

    if (options != null && options.isNotEmpty) {
      return _buildOptionList(v, options);
    }

    return _buildFallbackTextInput(v, AppLocalizations.of(context)!.snippetVarNoOptions);
  }

  Widget _buildLoadingState(ParsedVariable v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: AppColors.brandOrange,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            AppLocalizations.of(context)!.snippetVarQuerying(v.name.toLowerCase()),
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            dynamicListCommands[v.dynamicSource] ?? '',
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: AppColors.textSecondary.withValues(alpha: 0.4),
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildFallbackTextInput(ParsedVariable v, String reason) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.warning.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: AppColors.warning.withValues(alpha: 0.3),
            ),
          ),
          child: Row(
            children: [
              Icon(LucideIcons.info,
                  size: 16,
                  color: AppColors.warning.withValues(alpha: 0.8)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  AppLocalizations.of(context)!.snippetVarTypeInstead(reason),
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.warning.withValues(alpha: 0.8),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        TextFormField(
          controller: _textControllers[v.key],
          autofocus: true,
          // A `${VAR:secret}` variable (a token/password) is entered masked and
          // kept out of autocorrect/suggestions.
          obscureText: v.secret,
          enableSuggestions: !v.secret,
          autocorrect: !v.secret,
          decoration: InputDecoration(
            hintText: AppLocalizations.of(context)!.snippetVarEnterHint(v.name.toLowerCase()),
            hintStyle: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              color: ZestTokens.textPlaceholder,
            ),
            isDense: true,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(color: AppColors.divider),
            ),
            filled: true,
            fillColor: const Color(0xFF1E1E1E),
          ),
          style: const TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 14,
            color: Color(0xFFD4D4D4),
          ),
          onChanged: (_) => setState(() {}),
          onFieldSubmitted: (_) {
            if (_canProceed) _next();
          },
        ),
      ],
    );
  }

  // ─── Shared option tile ──────────────────────────────────────

  Widget _buildOptionTile({
    required String option,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: isSelected
            ? AppColors.brandOrange.withValues(alpha: 0.12)
            : AppColors.surfaceContainer,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: isSelected
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: AppColors.brandOrange.withValues(alpha: 0.4),
                      width: 1.5,
                    ),
                  )
                : null,
            child: Row(
              children: [
                Icon(
                  isSelected
                      ? LucideIcons.circleDot
                      : LucideIcons.circle,
                  size: 18,
                  color: isSelected
                      ? AppColors.accentInk
                      : AppColors.textSecondary.withValues(alpha: 0.4),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    option,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected ? AppColors.accentInk : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
