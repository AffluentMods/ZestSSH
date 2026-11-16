import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/members/member_trust.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_qr.dart';
import 'package:zestssh/features/teams/crypto/fingerprint_words.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// A fingerprint to read out (3.0): eight numbered words, or the 60
/// digits when [digits] is set. The words sit four to a row where there is
/// room and two where not, so two lists side by side line up.
class FingerprintWords extends StatelessWidget {
  const FingerprintWords({super.key, required this.fingerprint, this.digits = false});

  final Uint8List fingerprint;
  final bool digits;

  /// The fingerprint as [FingerprintWords] shows it, for copying.
  static String text(Uint8List fingerprint, {bool digits = false}) =>
      digits ? formatFingerprint(fingerprint) : fingerprintWords(fingerprint).join(' ');

  @override
  Widget build(BuildContext context) {
    if (digits) {
      return SelectableText(
        formatFingerprint(fingerprint),
        style: TextStyle(
          fontFamily: 'JetBrainsMono',
          fontSize: 13.5,
          height: 1.6,
          letterSpacing: 0.5,
          color: ZestColors.textPrimary,
        ),
      );
    }
    final words = fingerprintWords(fingerprint);
    Widget word(int i) => Expanded(
          child: Row(
            children: [
              SizedBox(
                width: 18,
                child: Text(
                  '${i + 1}',
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10.5, color: ZestColors.textMuted),
                ),
              ),
              Flexible(
                child: Text(
                  words[i],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: ZestColors.textPrimary,
                  ),
                ),
              ),
            ],
          ),
        );
    return SelectionArea(
      child: LayoutBuilder(builder: (context, c) {
        final perRow = c.maxWidth >= 400 ? 4 : 2;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var row = 0; row < words.length; row += perRow) ...[
              if (row > 0) const SizedBox(height: 8),
              Row(children: [for (var i = row; i < row + perRow && i < words.length; i++) word(i)]),
            ],
          ],
        );
      }),
    );
  }
}

/// A fingerprint in a box, with a copy button and a switch between words
/// and digits: this account's own to read out, or someone else's.
class FingerprintBox extends StatefulWidget {
  const FingerprintBox({super.key, required this.fingerprint});

  final Uint8List fingerprint;

  @override
  State<FingerprintBox> createState() => _FingerprintBoxState();
}

class _FingerprintBoxState extends State<FingerprintBox> {
  bool _digits = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 4, 4),
      decoration: BoxDecoration(
        color: ZestColors.bgContent,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FingerprintWords(fingerprint: widget.fingerprint, digits: _digits),
          ),
          Row(
            children: [
              _FormatSwitch(digits: _digits, onChanged: (d) => setState(() => _digits = d)),
              const Spacer(),
              IconButton(
                key: const ValueKey('fingerprint-copy'),
                icon: const Icon(LucideIcons.copy, size: 14),
                tooltip: MaterialLocalizations.of(context).copyButtonLabel,
                onPressed: () => Clipboard.setData(
                    ClipboardData(text: FingerprintWords.text(widget.fingerprint, digits: _digits))),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Both people's words side by side, for one call that checks both (3.0):
/// this account's to read out, and [name]'s to listen for. The
/// other person sees the same two lists, swapped. Or by QR code: this
/// account's own code to show, and on a phone a scan of theirs
/// (3.0); a scan that matches calls [onScanMatch].
class CompareCodes extends StatefulWidget {
  const CompareCodes({
    super.key,
    required this.theirs,
    required this.name,
    this.mine,
    this.onScanMatch,
    this.scan = scanFingerprint,
    bool? canScan,
  }) : _canScan = canScan;

  final Uint8List theirs;
  final String name;

  /// This account's own fingerprint; null while its keys are not known here.
  final Uint8List? mine;

  /// A scan of their code matched: as good as "They match".
  final VoidCallback? onScanMatch;

  /// Reads their code (the camera on a phone).
  final Future<Uint8List?> Function(BuildContext context, {required String name}) scan;

  final bool? _canScan;

  /// Whether this device offers to scan.
  bool get canScan => _canScan ?? canScanFingerprints;

  @override
  State<CompareCodes> createState() => _CompareCodesState();
}

class _CompareCodesState extends State<CompareCodes> {
  bool _digits = false;
  bool _showQr = false;

  /// What the last scan found: null before any.
  bool? _scanMatched;

  Future<void> _scan() async {
    final scanned = await widget.scan(context, name: widget.name);
    if (scanned == null || !mounted) return;
    final matched = sameFingerprint(scanned, widget.theirs);
    setState(() => _scanMatched = matched);
    if (matched) widget.onScanMatch?.call();
  }

  Widget _side(String title, String caption, Uint8List fp, Key key) => Container(
        key: key,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: ZestColors.bgContent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: ZestColors.borderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textPrimary)),
            const SizedBox(height: 2),
            Text(caption, style: TextStyle(fontSize: 11, color: ZestColors.textTertiary)),
            const SizedBox(height: 10),
            FingerprintWords(fingerprint: fp, digits: _digits),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final mine = widget.mine;
    final theirs = _side(l10n.fpTheirWords(widget.name), l10n.fpTheyReadThese(widget.name), widget.theirs,
        const ValueKey('compare-theirs'));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (mine == null)
          theirs
        else
          LayoutBuilder(builder: (context, c) {
            final yours = _side(l10n.fpYourWords, l10n.fpYouReadThese, mine, const ValueKey('compare-mine'));
            // Side by side where they fit, one above the other where not.
            if (c.maxWidth < 520) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [yours, const SizedBox(height: 10), theirs],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [Expanded(child: yours), const SizedBox(width: 12), Expanded(child: theirs)],
            );
          }),
        const SizedBox(height: 4),
        Wrap(
          spacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _FormatSwitch(digits: _digits, onChanged: (d) => setState(() => _digits = d)),
            if (mine != null)
              TextButton.icon(
                key: const ValueKey('fingerprint-show-qr'),
                onPressed: () => setState(() => _showQr = !_showQr),
                icon: const Icon(LucideIcons.qrCode, size: 15),
                label: Text(_showQr ? l10n.fpHideMyCode : l10n.fpShowMyCode),
              ),
            if (widget.canScan)
              TextButton.icon(
                key: const ValueKey('fingerprint-scan'),
                onPressed: _scan,
                icon: const Icon(LucideIcons.scanLine, size: 15),
                label: Text(l10n.fpScanTheirCode),
              ),
          ],
        ),
        if (_showQr && mine != null) ...[
          const SizedBox(height: 8),
          FingerprintQr(fingerprint: mine),
          const SizedBox(height: 6),
          Text(
            l10n.fpQrCaption(widget.name),
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
          ),
        ],
        if (_scanMatched != null) ...[
          const SizedBox(height: 8),
          _ScanResult(matched: _scanMatched!, name: widget.name),
        ],
      ],
    );
  }
}

/// What a scan of their code found.
class _ScanResult extends StatelessWidget {
  const _ScanResult({required this.matched, required this.name});

  final bool matched;
  final String name;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = matched ? ZestColors.statusSuccess : ZestColors.statusError;
    return Container(
      key: ValueKey(matched ? 'fingerprint-scan-match' : 'fingerprint-scan-mismatch'),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(matched ? LucideIcons.checkCircle : LucideIcons.xCircle, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              matched ? l10n.fpScanMatch(name) : l10n.fpScanMismatch(name),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textPrimary),
            ),
          ),
        ],
      ),
    );
  }
}

/// "Use digits" / "Use words".
class _FormatSwitch extends StatelessWidget {
  const _FormatSwitch({required this.digits, required this.onChanged});

  final bool digits;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return TextButton(
      key: const ValueKey('fingerprint-format'),
      onPressed: () => onChanged(!digits),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12, fontWeight: FontWeight.w500),
      ),
      child: Text(digits ? l10n.fpUseWords : l10n.fpUseDigits),
    );
  }
}
