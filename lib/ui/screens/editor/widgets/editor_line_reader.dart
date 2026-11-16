import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:re_editor/re_editor.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// The code editor to a screen reader (4.0 accessibility pass). The editor
/// (re_editor) paints its text and tells a screen reader nothing of it: the
/// code was one unnamed area. Now it is a text field named for its file
/// ("Editor: config.yaml") whose value is the line the caret is on and where
/// that line is ("Line 2 of 30: name: shop"), so moving the caret up and down
/// reads the code line by line; a screen reader's tap gives it the keyboard.
class EditorLineReader extends StatefulWidget {
  const EditorLineReader({
    super.key,
    required this.controller,
    required this.fileName,
    required this.child,
    this.onActivate,
  });

  final CodeLineEditingController controller;
  final String fileName;
  final Widget child;
  final VoidCallback? onActivate;

  /// The caret's line as a screen reader says it.
  static String lineOf(AppLocalizations l10n, CodeLineEditingValue value) {
    final lines = value.codeLines;
    if (lines.length == 0) return l10n.a11yEditorLine(1, 1, '');
    final at = value.selection.extentIndex.clamp(0, lines.length - 1);
    return l10n.a11yEditorLine(at + 1, lines.length, lines[at].text);
  }

  @override
  State<EditorLineReader> createState() => _EditorLineReaderState();
}

class _EditorLineReaderState extends State<EditorLineReader> {
  bool _queued = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_changed);
  }

  @override
  void didUpdateWidget(EditorLineReader old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeListener(_changed);
      widget.controller.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    super.dispose();
  }

  /// The editor changes its value while it builds too: the line is said
  /// again after the frame, once.
  void _changed() {
    if (_queued) return;
    _queued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _queued = false;
      if (mounted) setState(() {});
    });
    SchedulerBinding.instance.ensureVisualUpdate();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // One node: the editor's own (its scrolling, its tap) merged into it.
    return MergeSemantics(
      child: Semantics(
        container: true,
        textField: true,
        multiline: true,
        label: l10n.a11yEditorName(widget.fileName),
        value: EditorLineReader.lineOf(l10n, widget.controller.value),
        onTap: widget.onActivate,
        child: widget.child,
      ),
    );
  }
}
