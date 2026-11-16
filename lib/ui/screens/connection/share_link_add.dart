import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/hosts/host_share_file.dart' show addLinkedHost;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

export 'package:zestssh/services/connection_share_url_service.dart' show looksLikeShareLink;

// A host's share link (`zestssh://share?d=...` or `zestssh://add-host?...`)
// pasted into the app, or opened by the device: read by the same strict
// parser (ConnectionShareUrlService.tryParse), shown in the same
// confirmation (IncomingShareDialog) and saved the same way (addLinkedHost,
// into your Tree, its forwards never started on their own). Nothing is
// written before the person says yes.

/// Why a pasted text is not taken as a share link.
enum ShareLinkRefusal {
  /// Nothing was pasted.
  empty,

  /// Not a `zestssh://share` or `zestssh://add-host` link.
  notShareLink,

  /// Longer than any share link can be ([kMaxShareLinkChars]).
  tooLong,

  /// A share link the parser refuses: bad base64, a version it does not
  /// know, a bad host or port, or a field a share link never carries (a
  /// password, a key, a token).
  unreadable,
}

/// The longest text read as a share link, as for a link the device opens
/// ([ConnectionShareUrlService.maxLinkChars]). Anything longer is refused
/// before it is parsed.
const kMaxShareLinkChars = ConnectionShareUrlService.maxLinkChars;

/// A text read as a share link: its host ([share], from [uri]), or why not
/// ([refusal]).
class ShareLinkReading {
  const ShareLinkReading._({this.share, this.uri, this.refusal});

  final ParsedConnectionShare? share;
  final Uri? uri;
  final ShareLinkRefusal? refusal;

  bool get ok => share != null;
}

/// Whether [text] is meant as a host's share link (it starts with
/// `zestssh://share` or `zestssh://add-host`), for a field that takes other
/// things too: it is then read by [readShareLink], which may still refuse it.
/// [text] read as a share link, as strictly as a link the device opens: one
/// link, no spaces, the `zestssh` scheme, `share` or `add-host`, and what
/// [ConnectionShareUrlService.tryParse] accepts.
ShareLinkReading readShareLink(String text) {
  final t = text.trim();
  if (t.isEmpty) return const ShareLinkReading._(refusal: ShareLinkRefusal.empty);
  if (t.length > kMaxShareLinkChars) return const ShareLinkReading._(refusal: ShareLinkRefusal.tooLong);
  final uri = Uri.tryParse(t);
  if (uri == null || uri.scheme != 'zestssh') return const ShareLinkReading._(refusal: ShareLinkRefusal.notShareLink);
  final path = uri.host + uri.path;
  if (path != 'share' && path != 'add-host') return const ShareLinkReading._(refusal: ShareLinkRefusal.notShareLink);
  // A link is one line: what has a space or a line break in it was cut or
  // joined on its way here, and is not read.
  if (RegExp(r'\s').hasMatch(t)) return const ShareLinkReading._(refusal: ShareLinkRefusal.unreadable);
  final share = ConnectionShareUrlService.tryParse(uri);
  if (share == null) return const ShareLinkReading._(refusal: ShareLinkRefusal.unreadable);
  return ShareLinkReading._(share: share, uri: uri);
}

/// What [refusal] says to the person.
String shareLinkRefusalWords(AppLocalizations l10n, ShareLinkRefusal refusal) => switch (refusal) {
      ShareLinkRefusal.empty || ShareLinkRefusal.notShareLink => l10n.shareLinkRefusedNotLink,
      ShareLinkRefusal.tooLong => l10n.shareLinkRefusedTooLong,
      ShareLinkRefusal.unreadable => l10n.shareLinkRefusedUnreadable,
    };

/// Shows the host of [share] (read from [sourceUri]) for the person to look
/// at, and adds it to their Tree only when they say yes. Says what happened;
/// true when the host was added.
Future<bool> addShareLinkHost(BuildContext context, ParsedConnectionShare share, Uri sourceUri) async {
  // Read before the question: the screen that asked may be gone once it is
  // answered, and the answer still counts.
  final container = ProviderScope.containerOf(context, listen: false);
  final l10n = AppLocalizations.of(context)!;
  final approved = await IncomingShareDialog.show(context, payload: share, sourceUri: sourceUri);
  if (!approved) {
    AppLogger.info('Share link rejected by user');
    return false;
  }
  try {
    // Into your Tree, with its user, group and tags; its forwards never
    // started on their own (a shared URL must never open a tunnel by
    // itself, even after the host was approved).
    await addLinkedHost(container.read(treeDatabaseProvider), container.read(secureStorageProvider), share);
    if (context.mounted) showTopSnackBar(context, l10n.qrScanConnectionAdded, isSuccess: true);
    return true;
  } catch (e, stack) {
    AppLogger.error('Failed to save shared connection', e);
    if (context.mounted) {
      // What failed, with its report behind Copy details.
      showTopSnackBar(context, l10n.sharedConnectionSaveFailed, isError: true, details: '$e\n$stack');
    }
    return false;
  }
}

/// [text] (typed or pasted into a field that takes other things too, such as
/// quick connect) read as a share link: refused with words, or its host shown
/// for the person to add ([addShareLinkHost]). True when it was added.
Future<bool> addShareLinkFromText(BuildContext context, String text) async {
  final reading = readShareLink(text);
  if (!reading.ok) {
    showTopSnackBar(context, shareLinkRefusalWords(AppLocalizations.of(context)!, reading.refusal!), isError: true);
    return false;
  }
  return addShareLinkHost(context, reading.share!, reading.uri!);
}

/// Whether the clipboard can be read here without the system saying so or
/// asking: on Windows and Linux. An iPhone or iPad shows a banner (or asks)
/// and Android says so in a toast, and macOS may ask too: there it is read
/// only on a tap of Paste.
bool clipboardReadIsSilent([TargetPlatform? platform]) =>
    switch (platform ?? defaultTargetPlatform) { TargetPlatform.windows || TargetPlatform.linux => true, _ => false };

/// The clipboard's text, or null.
Future<String?> readClipboardText() async {
  try {
    return (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {
    return null;
  }
}

/// Opens "Paste a share link": a field for the link and Paste from
/// clipboard. Ends with the link's host once it reads ([readShareLink]), for
/// [addShareLinkHost] to show; null when closed. A link that does not read
/// is refused under the field, with what is wrong.
Future<ShareLinkReading?> showPasteShareLink(BuildContext context, {Future<String?> Function()? readClipboard}) =>
    showZestModal<ShareLinkReading>(
      context: context,
      size: ZestModalSize.standard,
      child: PasteShareLinkDialog(readClipboard: readClipboard),
    );

class PasteShareLinkDialog extends StatefulWidget {
  const PasteShareLinkDialog({super.key, this.readClipboard});

  /// Reads the clipboard (a stand-in in tests); [readClipboardText] otherwise.
  final Future<String?> Function()? readClipboard;

  @override
  State<PasteShareLinkDialog> createState() => _PasteShareLinkDialogState();
}

class _PasteShareLinkDialogState extends State<PasteShareLinkDialog> {
  final _link = TextEditingController();
  String? _error;

  @override
  void initState() {
    super.initState();
    _link.addListener(_changed);
  }

  void _changed() {
    if (_error != null) _error = null;
    setState(() {});
  }

  @override
  void dispose() {
    _link.dispose();
    super.dispose();
  }

  void _continue() {
    final reading = readShareLink(_link.text);
    if (!reading.ok) {
      setState(() => _error = shareLinkRefusalWords(AppLocalizations.of(context)!, reading.refusal!));
      return;
    }
    Navigator.of(context).pop(reading);
  }

  /// What is on the clipboard into the field, and read at once: a link that
  /// reads goes straight on to its host.
  Future<void> _paste() async {
    final text = await (widget.readClipboard ?? readClipboardText)();
    if (!mounted) return;
    if (text == null || text.trim().isEmpty) {
      setState(() => _error = AppLocalizations.of(context)!.shareLinkClipboardEmpty);
      return;
    }
    _link.text = text.trim();
    _continue();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.link,
      title: l10n.shareLinkPasteTitle,
      subtitle: l10n.shareLinkPasteSubtitle,
      body: ZestTextField(
        key: const ValueKey('share-link-field'),
        controller: _link,
        label: l10n.shareLinkPasteLabel,
        hintText: 'zestssh://share?d=...',
        errorText: _error,
        keyboardType: TextInputType.url,
        onSubmit: _continue,
      ),
      primaryKey: const ValueKey('share-link-continue'),
      primaryAction: (
        label: l10n.shareLinkPasteContinue,
        icon: LucideIcons.arrowRight,
        onPressed: _link.text.trim().isEmpty ? null : _continue,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      tertiaryKey: const ValueKey('share-link-paste'),
      tertiaryAction: (label: l10n.sshImportPasteFromClipboard, onPressed: _paste),
    );
  }
}
