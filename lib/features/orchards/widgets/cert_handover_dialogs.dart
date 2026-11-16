import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/team_certificate_login.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_words.dart' show offlineSpanWords;
import 'package:zestssh/features/orchards/widgets/fingerprint_qr.dart' show canScanFingerprints;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart' show ZestFieldLabel;
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

// A certificate handed over, on screen (3.0,
// so that a team reaches its hosts while ZestSSH Cloud is
// away). Two screens, one on each device. The member's shows their request as
// a code and as a text to copy, and takes what an owner gives back. The
// owner's takes a request, says who asks for what and until when, signs, and
// shows the certificate the same two ways. A phone scans the other screen;
// any device takes the text. What each step checks is in
// orchard_cert_handover.dart: these screens only carry the two texts, and
// say in words what the service says of them.
//
// An offline pass goes the same way (rules/offline_pass.dart,
// orchard_pass_handover.dart): the owner's screen takes either kind of
// request and says which it is; a member asks for a pass on a screen of its
// own, which also names the device the pass will be for.

/// What to tell an owner whose device will not sign a request handed to it.
String handedRequestMessage(AppLocalizations l10n, HandedRequestRefused e) => switch (e.problem) {
      HandedRequestProblem.notARequest => l10n.certSignNotARequest,
      HandedRequestProblem.isACertificate => l10n.certSignIsCertificate,
      HandedRequestProblem.otherOrchard => l10n.certSignOtherTeam,
      HandedRequestProblem.notAnOwner => l10n.certSignNotOwner,
      HandedRequestProblem.notLetIn => l10n.certSignNotLetIn,
      HandedRequestProblem.keyNotHere => l10n.certSignKeyNotHere,
      HandedRequestProblem.refused => switch (e.refusal) {
          CertRequestRefusal.noAuthority => l10n.certSignNoAuthority,
          CertRequestRefusal.notAMember => l10n.certSignNotMember,
          CertRequestRefusal.noAccess => l10n.certSignNoAccess,
          CertRequestRefusal.notCurrentKeys => l10n.certSignOldKeys,
          CertRequestRefusal.notRecent => l10n.certSignTooOld,
          CertRequestRefusal.noUserNames => l10n.certSignNoNames,
          CertRequestRefusal.notSignedByMember => l10n.certSignBadSignature,
          CertRequestRefusal.deviceNotApproved => l10n.certSignDeviceNotApproved,
          CertRequestRefusal.notSignedByDevice => l10n.certSignDeviceBadSignature,
          // (Refused, and nothing said of why: it is not signed either way.)
          null => l10n.certSignNotARequest,
        },
    };

/// What to tell a member whose device will not keep what it was handed.
String handedCertificateMessage(AppLocalizations l10n, HandedCertificateProblem problem) => switch (problem) {
      HandedCertificateProblem.notACertificate => l10n.certHandNotAnAnswer,
      HandedCertificateProblem.isARequest => l10n.certHandIsRequest,
      HandedCertificateProblem.otherOrchard => l10n.certHandOtherTeam,
      HandedCertificateProblem.noAuthority => l10n.teamCertNoAuthority,
      HandedCertificateProblem.notForThisDevice => l10n.certHandNotForThisDevice,
      HandedCertificateProblem.expired => l10n.certHandExpired,
    };

/// What to tell an owner whose device will not sign a pass for a request
/// handed to it.
String handedPassRequestMessage(AppLocalizations l10n, HandedPassRequestRefused e) => switch (e.problem) {
      HandedPassRequestProblem.notARequest => l10n.certSignNotARequest,
      HandedPassRequestProblem.isAPass => l10n.passSignIsPass,
      HandedPassRequestProblem.otherOrchard => l10n.certSignOtherTeam,
      HandedPassRequestProblem.notAnOwner => l10n.passSignNotOwner,
      HandedPassRequestProblem.notLetIn => l10n.certSignNotLetIn,
      HandedPassRequestProblem.closedHere => l10n.passSignClosedHere,
      HandedPassRequestProblem.ownDevice => l10n.passSignOwnDevice,
      HandedPassRequestProblem.refused => switch (e.refusal) {
          PassRequestRefusal.noSuchCrate => l10n.passSignNoCrate,
          PassRequestRefusal.notAMember => l10n.certSignNotMember,
          PassRequestRefusal.noAccess => l10n.certSignNoAccess,
          PassRequestRefusal.notCurrentKeys => l10n.certSignOldKeys,
          PassRequestRefusal.notRecent => l10n.certSignTooOld,
          PassRequestRefusal.notSignedByMember => l10n.certSignBadSignature,
          PassRequestRefusal.deviceNotApproved => l10n.certSignDeviceNotApproved,
          // (Refused, and nothing said of why: it is not signed either way.)
          null => l10n.certSignNotARequest,
        },
    };

/// What to tell someone whose device makes no request for an offline pass.
String passAskMessage(AppLocalizations l10n, PassAskProblem problem) => switch (problem) {
      PassAskProblem.otherOrchard => l10n.passAskNoTeam,
      PassAskProblem.noDeviceKey => l10n.passAskNoDeviceKey,
    };

/// What the pass that was [taken] is for, in words: all of the Orchard by
/// [orchard], the name this device calls it by, or a Crate by the name read
/// while the pass was checked (an Orchard that is closed here lists none of
/// its Crates, and a pass for one of them may still be handed to it).
String takenPassWhat(AppLocalizations l10n, TakenPass taken, {required String orchard}) {
  if (taken.crateId == kAllOfOrchard) return orchard;
  final name = taken.crateName;
  return name == null || name.trim().isEmpty ? l10n.crateUnnamed : name;
}

/// What to tell a member whose device will not keep a pass it was handed.
String handedPassMessage(AppLocalizations l10n, HandedPassRefused e) => switch (e.problem) {
      HandedPassProblem.notAPass => l10n.certHandNotAnAnswer,
      HandedPassProblem.isARequest => l10n.certHandIsRequest,
      HandedPassProblem.otherOrchard => l10n.passTakeOtherTeam,
      HandedPassProblem.refused => switch (e.refusal) {
          OfflinePassProblem.noSuchCrate => l10n.passTakeNoCrate,
          OfflinePassProblem.notForThisAccount => l10n.passTakeOtherAccount,
          OfflinePassProblem.notForThisDevice => l10n.passTakeOtherDevice,
          OfflinePassProblem.notAnOwner => l10n.passTakeNotOwner,
          OfflinePassProblem.notCurrentKeys => l10n.passTakeOldKeys,
          OfflinePassProblem.notSignedByOwner => l10n.passTakeBadSignature,
          OfflinePassProblem.expired => l10n.passTakeExpired,
          OfflinePassProblem.tooLong => l10n.passTakeTooLong,
          // (Refused, and nothing said of why: it is not kept either way.)
          null => l10n.certHandNotAnAnswer,
        },
    };

/// How large a text of [length] characters handed over is drawn as a code,
/// where there is room. A short one (a request) is 240 on a computer and 280
/// on a phone, whose screen is held further from the camera. A long one (a
/// certificate, a pass) has many more points to a side: at the same size
/// each point is too small for a camera to tell apart, so it is drawn at
/// 340, and on a phone as large as the window lets it be up to that.
double handedCodeSize({required bool phone, required int length}) {
  if (length > handedCodeShortUpTo) return 340;
  return phone ? 280 : 240;
}

/// Up to how many characters a text handed over is short ([handedCodeSize]):
/// the most a code of version 13 holds with the least error correction (69
/// points to a side, about 3.5 pixels a point at 240). A request (about 340
/// characters) is short; a certificate (about 760, 93 points to a side) is
/// not, and at 340 its points are as large as a request's.
const int handedCodeShortUpTo = 425;

/// A text handed over as a code, dark on white so that any camera reads it
/// in any theme. Drawn with the least error correction: it goes from a
/// screen to a camera, where nothing of it is torn or stained, and a code
/// with fewer points is the one a camera reads from further away.
class HandedCode extends StatelessWidget {
  const HandedCode({super.key, required this.text});

  final String text;

  /// The white edge around the code (its quiet zone), which a camera needs
  /// to find it.
  static const double edge = 12;

  @override
  Widget build(BuildContext context) {
    final phone = vaultOnPhone(context);
    return LayoutBuilder(builder: (context, box) {
      // No wider than the screen it is on (a phone's).
      final wanted = handedCodeSize(phone: phone, length: text.length);
      final room = box.maxWidth.isFinite ? box.maxWidth - 2 * edge : wanted;
      final size = room < wanted ? room : wanted;
      return Center(
        child: Container(
          padding: const EdgeInsets.all(edge),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(8)),
          child: QrImageView(
            data: text,
            version: QrVersions.auto,
            size: size,
            errorCorrectionLevel: QrErrorCorrectLevel.L,
            gapless: true,
            backgroundColor: Colors.white,
            eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Color(0xFF0A0A0A)),
            dataModuleStyle:
                const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Color(0xFF0A0A0A)),
            // More than a code holds: the text is still there to send.
            errorStateBuilder: (context, error) => SizedBox(width: size, height: 0),
          ),
        ),
      );
    });
  }
}

/// The first of the scanned [codes] that holds a text of one of the kinds
/// [want] that reads, or null: a camera sees whatever is in front of it, and
/// only the other device's code is taken.
String? handedTextAmong(Iterable<String?> codes, Set<HandedKind> want) {
  bool reads(String raw, HandedKind kind) => switch (kind) {
        HandedKind.request => HandedRequest.fromText(raw) != null,
        HandedKind.certificate => HandedCertificate.fromText(raw) != null,
        HandedKind.passRequest => HandedPassRequest.fromText(raw) != null,
        HandedKind.pass => HandedPass.fromText(raw) != null,
      };
  for (final raw in codes) {
    if (raw != null && want.any((kind) => reads(raw, kind))) return raw;
  }
  return null;
}

/// Scans the code on the other device's screen and returns the text it
/// holds, or null when the person backs out. Phones and tablets only.
Future<String?> scanHandedText(
  BuildContext context, {
  required Set<HandedKind> want,
  required String title,
  required String hint,
  required String wrong,
}) =>
    Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => _HandedScanScreen(want: want, title: title, hint: hint, wrong: wrong),
        fullscreenDialog: true,
      ),
    );

class _HandedScanScreen extends StatefulWidget {
  const _HandedScanScreen({required this.want, required this.title, required this.hint, required this.wrong});

  final Set<HandedKind> want;
  final String title;
  final String hint;
  final String wrong;

  @override
  State<_HandedScanScreen> createState() => _HandedScanScreenState();
}

class _HandedScanScreenState extends State<_HandedScanScreen> {
  final _controller = MobileScannerController(detectionSpeed: DetectionSpeed.noDuplicates, facing: CameraFacing.back);
  bool _wrongCode = false;
  bool _done = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done) return;
    final text = handedTextAmong(capture.barcodes.map((b) => b.rawValue), widget.want);
    if (text != null) {
      _done = true;
      Navigator.of(context).pop(text);
      return;
    }
    if (!_wrongCode) setState(() => _wrongCode = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(title: Text(widget.title)),
      body: Stack(
        children: [
          MobileScanner(controller: _controller, onDetect: _onDetect),
          Positioned(
            left: 16,
            right: 16,
            bottom: 32,
            child: Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                _wrongCode ? widget.wrong : widget.hint,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white, fontSize: 13.5, height: 1.4),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

TextStyle get _prose => TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary);

TextStyle get _small => TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary);

Widget _waiting(String text) => Row(
      children: [
        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 12),
        Expanded(child: Text(text, style: _prose)),
      ],
    );

/// A text handed over, shown: the code, and the text to copy.
class _Shown extends StatelessWidget {
  const _Shown({required this.text, required this.codeKey, required this.copyKey});

  final String text;
  final Key codeKey;
  final Key copyKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        HandedCode(key: codeKey, text: text),
        const SizedBox(height: 12),
        Center(
          child: vaultButton(
            context,
            key: copyKey,
            onPressed: () async {
              // What is handed over lets whoever holds it finish the hand-over:
              // it leaves the clipboard by itself, as a secret does, and the
              // person is told.
              await SecretClipboard.copy(text);
              if (context.mounted) {
                showTopSnackBar(context, clearsSoon(l10n, l10n.certHandCopied), isSuccess: true);
              }
            },
            icon: LucideIcons.copy,
            label: l10n.certHandCopy,
          ),
        ),
        const SizedBox(height: 8),
        Text(l10n.certHandCodeHint, textAlign: TextAlign.center, style: _small),
      ],
    );
  }
}

/// Where the other device's text is entered: typed or pasted, from the
/// clipboard at a tap, or scanned on a phone.
class _Entered extends StatelessWidget {
  const _Entered({
    required this.controller,
    required this.hint,
    required this.fieldKey,
    required this.pasteKey,
    required this.scanKey,
    required this.onSubmit,
    required this.onScan,
    required this.problem,
    required this.problemKey,
  });

  final TextEditingController controller;
  final String hint;
  final Key fieldKey;
  final Key pasteKey;
  final Key scanKey;
  final VoidCallback onSubmit;
  final VoidCallback onScan;
  final String? problem;
  final Key problemKey;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final problem = this.problem;
    final target = vaultOnPhone(context) ? 44.0 : 32.0;
    Widget action(Key key, IconData icon, String tip, VoidCallback onPressed) => IconButton(
          key: key,
          // Its own colour: the field's error colours a suffix red.
          icon: Icon(icon, size: 16, color: ZestTokens.textSecondary),
          tooltip: tip,
          constraints: BoxConstraints.tightFor(width: target, height: target),
          padding: EdgeInsets.zero,
          onPressed: onPressed,
        );
    // The other device's text in mono, as it is; Paste (and Scan on a phone)
    // inside the field at its end; what is wrong with it under it, in the
    // theme's error look (a red edge, a red line with its icon).
    return KeyedSubtree(
      key: fieldKey,
      child: TextField(
      controller: controller,
      onSubmitted: (_) => onSubmit(),
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestTokens.textPrimary),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(fontFamily: 'GeistSans', fontSize: 13, color: ZestTokens.textTertiary),
        suffixIcon: Padding(
          padding: const EdgeInsetsDirectional.only(end: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              action(pasteKey, LucideIcons.clipboardPaste, l10n.identityPaste, () async {
                final clip = await Clipboard.getData(Clipboard.kTextPlain);
                final text = clip?.text;
                if (text != null && text.isNotEmpty) controller.text = text;
              }),
              if (canScanFingerprints) action(scanKey, LucideIcons.scanLine, l10n.certHandScan, onScan),
            ],
          ),
        ),
        error: problem == null
            ? null
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(LucideIcons.alertCircle, size: 14, color: ZestTokens.statusCritical),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    // Its last two words on one line ("back." was alone under
                    // "gives you a different code" before).
                    //
                    child: Text(noOrphan(problem),
                        key: problemKey,
                        style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.statusCritical)),
                  ),
                ],
              ),
      ),
      ),
    );
  }
}

/// The name of [crateId] in [orchardId] as this device has it.
String _crateName(WidgetRef ref, AppLocalizations l10n, String orchardId, String crateId) {
  final orchards = [
    ...?ref.read(orchardSummariesProvider).valueOrNull,
    ?ref.read(activeOrchardProvider).valueOrNull,
  ];
  final crate =
      orchards.where((o) => o.id == orchardId).expand((o) => o.crates).where((c) => c.id == crateId).firstOrNull;
  return crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n);
}

/// The Orchard [orchardId] as this device calls it ("Acme Orchard"), also
/// while it is closed here.
String _orchardName(WidgetRef ref, AppLocalizations l10n, String orchardId) => orchardDisplayName(
    [
      ...?ref.read(orchardSummariesProvider).valueOrNull,
      ?ref.read(activeOrchardProvider).valueOrNull,
    ].where((o) => o.id == orchardId).firstOrNull?.name,
    l10n);

/// What a pass is for, in words: the Crate's name, or the Orchard's for all
/// of it.
String _passFor(WidgetRef ref, AppLocalizations l10n, String orchardId, String crateId) =>
    crateId == kAllOfOrchard ? _orchardName(ref, l10n, orchardId) : _crateName(ref, l10n, orchardId, crateId);

/// Opens "Offline pass from an owner" where it was asked for by something
/// that has no screen of its own (the action of a notice:
/// [passAskRequestProvider]), in the context [navigator] gives (the app's
/// navigator). What was asked is taken away as it is answered, so the same
/// asked again opens it again; with no screen to open it on, it is dropped.
/// Call it from a build: the app's root does.
void answerPassAskRequests(WidgetRef ref, BuildContext? Function() navigator) {
  ref.listen<({String orchardId, String crateId})?>(passAskRequestProvider, (_, asked) {
    if (asked == null) return;
    ref.read(passAskRequestProvider.notifier).state = null;
    final context = navigator();
    if (context == null) return;
    showPassFromOwner(context, orchardId: asked.orchardId, crateId: asked.crateId);
  });
}

// ── A member's screen ───────────────────────────────────────────────────

/// On a member's device: shows the request for a certificate in [crateId]
/// for an owner's device to take, and takes what the owner gives back.
Future<void> showCertFromOwner(BuildContext context, {required String orchardId, required String crateId}) =>
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: _CertFromOwnerDialog(orchardId: orchardId, crateId: crateId),
    );

enum _HandStep { making, show, cannot, done }

class _CertFromOwnerDialog extends ConsumerStatefulWidget {
  const _CertFromOwnerDialog({required this.orchardId, required this.crateId});

  final String orchardId;
  final String crateId;

  @override
  ConsumerState<_CertFromOwnerDialog> createState() => _CertFromOwnerDialogState();
}

class _CertFromOwnerDialogState extends ConsumerState<_CertFromOwnerDialog> {
  late final OrchardService _service;
  final _answer = TextEditingController();
  _HandStep _step = _HandStep.making;
  String? _ask;
  String? _cannot;
  String? _problem;
  HeldCertificate? _held;
  bool _taking = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(orchardServiceProvider);
    // Use it waits for an answer.
    _answer.addListener(_answerChanged);
    // After the first frame: the steps read this screen's language.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _make();
    });
  }

  void _answerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _answer.removeListener(_answerChanged);
    _answer.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final l10n = AppLocalizations.of(context)!;
    String? ask;
    String? cannot;
    try {
      ask = (await _service.handRequest(widget.orchardId, widget.crateId)).toText();
    } on TeamCertificateUnavailable catch (e) {
      cannot = teamCertificateMessage(l10n, e, '');
    } catch (e) {
      AppLogger.warning('Orchards: no request to hand over could be made ($e)');
      cannot = orchardErrorMessage(e, l10n);
    }
    if (!mounted) return;
    setState(() {
      _ask = ask;
      _cannot = cannot;
      _step = ask == null ? _HandStep.cannot : _HandStep.show;
    });
  }

  Future<void> _take([String? scanned]) async {
    final text = scanned ?? _answer.text;
    if (_taking || text.trim().isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _taking = true);
    HeldCertificate? held;
    String? problem;
    try {
      held = await _service.takeHandedCertificate(text);
    } on HandedCertificateRefused catch (e) {
      problem = handedCertificateMessage(l10n, e.problem);
    } catch (e) {
      AppLogger.warning('Orchards: a certificate handed over could not be taken ($e)');
      problem = orchardErrorMessage(e, l10n);
    }
    if (!mounted) return;
    setState(() {
      _taking = false;
      _held = held;
      _problem = problem;
      if (held != null) _step = _HandStep.done;
    });
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    final text = await scanHandedText(
      context,
      want: const {HandedKind.certificate},
      title: l10n.certHandButton,
      hint: l10n.certHandScanHint,
      wrong: l10n.certHandScanWrong,
    );
    if (text != null && mounted) await _take(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final crate = _crateName(ref, l10n, widget.orchardId, widget.crateId);
    void close() => Navigator.of(context).pop();
    final held = _held;
    final (Widget body, primary) = switch (_step) {
      _HandStep.making => (_waiting(l10n.certHandMaking), null),
      _HandStep.cannot => (
          Text(_cannot ?? l10n.teamCertNoAuthority, key: const ValueKey('cert-hand-cannot'), style: _prose),
          null,
        ),
      _HandStep.show => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.certHandIntro, style: _prose),
              const SizedBox(height: 12),
              _Shown(
                text: _ask!,
                codeKey: const ValueKey('cert-hand-code'),
                copyKey: const ValueKey('cert-hand-copy'),
              ),
              const SizedBox(height: 16),
              ZestFieldLabel(l10n.certHandAnswerLabel),
              const SizedBox(height: 6),
              _Entered(
                controller: _answer,
                hint: l10n.certHandAnswerHint,
                fieldKey: const ValueKey('cert-hand-answer'),
                pasteKey: const ValueKey('cert-hand-paste'),
                scanKey: const ValueKey('cert-hand-scan'),
                onSubmit: _take,
                onScan: _scan,
                problem: _problem,
                problemKey: const ValueKey('cert-hand-problem'),
              ),
            ],
          ),
          (
            label: l10n.certHandUse,
            onPressed: _taking || _answer.text.trim().isEmpty ? null : _take,
            icon: LucideIcons.badgeCheck,
          ),
        ),
      _HandStep.done => (
          VaultCallout(
            kind: ZestStatusKind.healthy,
            icon: LucideIcons.checkCircle2,
            text: l10n.certHandDone(crate, accessTimeText(held!.validBefore, l10n)),
            textKey: const ValueKey('cert-hand-done'),
          ),
          (label: l10n.done, onPressed: close, icon: null),
        ),
    };
    return ZestDialogShell(
      size: ZestModalSize.standard,
      // A certificate taken: done, a green tick; why one cannot be, plainly.
      tone: switch (_step) {
        _HandStep.done => ZestDialogTone.success,
        _HandStep.cannot => ZestDialogTone.neutral,
        _ => ZestDialogTone.info,
      },
      icon: LucideIcons.qrCode,
      title: l10n.certHandButton,
      subtitle: crate,
      body: body,
      primaryAction: primary,
      secondaryAction: switch (_step) {
        _HandStep.show => (label: l10n.cancel, onPressed: close),
        _HandStep.cannot => (label: l10n.close, onPressed: close),
        _ => null,
      },
    );
  }
}

/// On a member's device: shows the request for an offline pass for
/// [crateId] of [orchardId] (all of the Orchard where none is given) for an
/// owner's device to take, with what this device is called, and takes the
/// pass the owner gives back.
Future<void> showPassFromOwner(BuildContext context, {required String orchardId, String crateId = kAllOfOrchard}) =>
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: _PassFromOwnerDialog(orchardId: orchardId, crateId: crateId),
    );

class _PassFromOwnerDialog extends ConsumerStatefulWidget {
  const _PassFromOwnerDialog({required this.orchardId, required this.crateId});

  final String orchardId;
  final String crateId;

  @override
  ConsumerState<_PassFromOwnerDialog> createState() => _PassFromOwnerDialogState();
}

class _PassFromOwnerDialogState extends ConsumerState<_PassFromOwnerDialog> {
  late final OrchardService _service;
  final _answer = TextEditingController();
  _HandStep _step = _HandStep.making;
  String? _ask;
  String? _code;
  String? _cannot;
  String? _problem;
  TakenPass? _taken;
  bool _taking = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(orchardServiceProvider);
    // Use it waits for an answer.
    _answer.addListener(_answerChanged);
    // After the first frame: the steps read this screen's language.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _make();
    });
  }

  void _answerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _answer.removeListener(_answerChanged);
    _answer.dispose();
    super.dispose();
  }

  Future<void> _make() async {
    final l10n = AppLocalizations.of(context)!;
    String? ask;
    String? code;
    String? cannot;
    try {
      ask = (await _service.handPassRequest(widget.orchardId, crateId: widget.crateId)).toText();
      code = await _service.ownDeviceCode();
    } on OfflinePassUnavailable catch (e) {
      cannot = passAskMessage(l10n, e.problem);
    } catch (e) {
      AppLogger.warning('Orchards: no request for an offline pass could be made ($e)');
      cannot = orchardErrorMessage(e, l10n);
    }
    if (!mounted) return;
    setState(() {
      _ask = ask;
      _code = code;
      _cannot = cannot;
      _step = ask == null ? _HandStep.cannot : _HandStep.show;
    });
  }

  Future<void> _take([String? scanned]) async {
    final text = scanned ?? _answer.text;
    if (_taking || text.trim().isEmpty) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _taking = true);
    TakenPass? taken;
    String? problem;
    try {
      taken = await _service.takePass(text);
    } on HandedPassRefused catch (e) {
      problem = handedPassMessage(l10n, e);
    } catch (e) {
      AppLogger.warning('Orchards: an offline pass handed over could not be taken ($e)');
      problem = orchardErrorMessage(e, l10n);
    }
    if (!mounted) return;
    setState(() {
      _taking = false;
      _taken = taken;
      _problem = problem;
      if (taken != null) _step = _HandStep.done;
    });
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    final text = await scanHandedText(
      context,
      want: const {HandedKind.pass},
      title: l10n.passAskButton,
      hint: l10n.certHandScanHint,
      wrong: l10n.certHandScanWrong,
    );
    if (text != null && mounted) await _take(text);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final what = _passFor(ref, l10n, widget.orchardId, widget.crateId);
    void close() => Navigator.of(context).pop();
    final taken = _taken;
    final takenFor =
        taken == null ? '' : takenPassWhat(l10n, taken, orchard: _orchardName(ref, l10n, taken.orchardId));
    final code = _code;
    final (Widget body, primary) = switch (_step) {
      _HandStep.making => (_waiting(l10n.certHandMaking), null),
      _HandStep.cannot => (
          Text(_cannot ?? '', key: const ValueKey('pass-hand-cannot'), style: _prose),
          null,
        ),
      _HandStep.show => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.passAskIntro, style: _prose),
              const SizedBox(height: 12),
              _Shown(
                text: _ask!,
                codeKey: const ValueKey('pass-hand-code'),
                copyKey: const ValueKey('pass-hand-copy'),
              ),
              // This device's code, which the owner's screen shows too:
              // read out, so it stands as a code of its own.
              if (code != null) ...[
                const SizedBox(height: 16),
                ZestFieldLabel(l10n.vaultUiDeviceCodeLabel),
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: ZestTokens.surfaceChip,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: ZestTokens.borderSubtle),
                    ),
                    child: SelectableText(code,
                        key: const ValueKey('pass-hand-device'),
                        style: TextStyle(
                            fontFamily: 'JetBrainsMono',
                            fontSize: 20,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 1,
                            color: ZestTokens.textPrimary)),
                  ),
                ),
                const SizedBox(height: 6),
                Text(l10n.vaultUiDeviceCodeHelp, style: _small),
              ],
              const SizedBox(height: 16),
              ZestFieldLabel(l10n.certHandAnswerLabel),
              const SizedBox(height: 6),
              _Entered(
                controller: _answer,
                hint: l10n.certHandAnswerHint,
                fieldKey: const ValueKey('pass-hand-answer'),
                pasteKey: const ValueKey('pass-hand-paste'),
                scanKey: const ValueKey('pass-hand-scan'),
                onSubmit: _take,
                onScan: _scan,
                problem: _problem,
                problemKey: const ValueKey('pass-hand-problem'),
              ),
            ],
          ),
          (
            label: l10n.certHandUse,
            onPressed: _taking || _answer.text.trim().isEmpty ? null : _take,
            icon: LucideIcons.badgeCheck,
          ),
        ),
      _HandStep.done => (
          // Kept: a success, or kept while the team itself is still closed
          // here (a warning: there is more to ask for).
          VaultCallout(
            kind: taken!.orchardClosed ? ZestStatusKind.warning : ZestStatusKind.healthy,
            icon: taken.orchardClosed ? LucideIcons.alertTriangle : LucideIcons.checkCircle2,
            // Its last two words on one line ("Cloud." was alone on the
            // second).
            text: noOrphan(taken.orchardClosed
                ? l10n.passAskDoneOrchardClosed(takenFor, accessTimeText(taken.until, l10n))
                : l10n.passAskDone(takenFor, accessTimeText(taken.until, l10n))),
            textKey: const ValueKey('pass-hand-done'),
          ),
          (label: l10n.done, onPressed: close, icon: null),
        ),
    };
    return ZestDialogShell(
      size: ZestModalSize.standard,
      // A pass kept: done, a green tick (unless the team is still closed
      // here, which its callout says); why one cannot be, plainly.
      tone: switch (_step) {
        _HandStep.done when taken?.orchardClosed != true => ZestDialogTone.success,
        _HandStep.cannot => ZestDialogTone.neutral,
        _ => ZestDialogTone.info,
      },
      icon: LucideIcons.qrCode,
      title: l10n.passAskButton,
      subtitle: what,
      body: body,
      primaryAction: primary,
      secondaryAction: switch (_step) {
        _HandStep.show => (label: l10n.cancel, onPressed: close),
        _HandStep.cannot => (label: l10n.close, onPressed: close),
        _ => null,
      },
    );
  }
}

// ── An owner's screen ───────────────────────────────────────────────────

/// On an owner's device: takes a request a member hands over, for a
/// certificate or for an offline pass, says who asks for what, signs it and
/// shows what to hand back.
Future<void> showSignHandedRequest(BuildContext context) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      child: const _SignHandedRequestDialog(),
    );

enum _SignStep { enter, review, signed }

class _SignHandedRequestDialog extends ConsumerStatefulWidget {
  const _SignHandedRequestDialog();

  @override
  ConsumerState<_SignHandedRequestDialog> createState() => _SignHandedRequestDialogState();
}

class _SignHandedRequestDialogState extends ConsumerState<_SignHandedRequestDialog> {
  late final OrchardService _service;
  final _request = TextEditingController();
  _SignStep _step = _SignStep.enter;
  HandedRequestReview? _review;

  /// The request read last, where it asks for an offline pass, and how long
  /// the pass is to last (hours).
  HandedPassReview? _passReview;
  int _hours = 24;
  String? _give;
  String? _problem;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(orchardServiceProvider);
  }

  @override
  void dispose() {
    _request.dispose();
    super.dispose();
  }

  /// Runs [step], and shows what it has against the request when it has.
  Future<T?> _checked<T>(Future<T> Function() step) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    T? done;
    String? problem;
    try {
      done = await step();
    } on HandedRequestRefused catch (e) {
      problem = handedRequestMessage(l10n, e);
    } on HandedPassRequestRefused catch (e) {
      problem = handedPassRequestMessage(l10n, e);
    } catch (e) {
      AppLogger.warning('Orchards: a request handed over could not be read or signed ($e)');
      problem = orchardErrorMessage(e, l10n);
    }
    if (!mounted) return null;
    setState(() {
      _busy = false;
      _problem = problem;
      // What it will not sign is said where the request is entered.
      if (problem != null) _step = _SignStep.enter;
    });
    return done;
  }

  Future<void> _read([String? scanned]) async {
    final text = scanned ?? _request.text;
    if (_busy || text.trim().isEmpty) return;
    // What the text says it is decides who reads it: a request for a pass
    // (or a pass, which is said to be no request) or, for anything else, a
    // request for a certificate.
    final kind = handedKindOf(text);
    if (kind == HandedKind.passRequest || kind == HandedKind.pass) {
      final review = await _checked(() => _service.reviewPassRequest(text));
      if (review == null || !mounted) return;
      setState(() {
        _passReview = review;
        _review = null;
        _hours = 24;
        _step = _SignStep.review;
      });
      return;
    }
    final review = await _checked(() => _service.reviewHandedRequest(text));
    if (review == null || !mounted) return;
    setState(() {
      _review = review;
      _passReview = null;
      _step = _SignStep.review;
    });
  }

  Future<void> _sign() async {
    final review = _review;
    final pass = _passReview;
    if (_busy || (review == null && pass == null)) return;
    final give = await _checked(() async => pass != null
        ? (await _service.signPass(pass, hours: _hours)).toText()
        : (await _service.signHandedRequest(review!)).toText());
    if (give == null || !mounted) return;
    setState(() {
      _give = give;
      _step = _SignStep.signed;
    });
  }

  Future<void> _scan() async {
    final l10n = AppLocalizations.of(context)!;
    final text = await scanHandedText(
      context,
      want: const {HandedKind.request, HandedKind.passRequest},
      title: l10n.certSignTitle,
      hint: l10n.certSignScanHint,
      wrong: l10n.certSignScanWrong,
    );
    if (text != null && mounted) await _read(text);
  }

  void _another() => setState(() {
        _request.clear();
        _review = null;
        _passReview = null;
        _give = null;
        _problem = null;
        _step = _SignStep.enter;
      });

  Widget _row(String label, String value, {required Key key}) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(width: 150, child: Text(label, style: _prose)),
            Expanded(
              child: Text(value, key: key, style: _prose.copyWith(color: AppColors.v3TextPrimary)),
            ),
          ],
        ),
      );

  /// What an owner reads of a request for an offline pass before signing:
  /// who asks, for what, from which device, and how long the pass is to
  /// last, which is theirs to choose.
  Widget _passBody(AppLocalizations l10n, HandedPassReview review) {
    final who = review.email ?? l10n.certSignSomeone;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          review.crateId == kAllOfOrchard
              ? l10n.passSignWhoAll(who, _orchardName(ref, l10n, review.orchardId))
              : l10n.passSignWho(who, _crateName(ref, l10n, review.orchardId, review.crateId)),
          key: const ValueKey('pass-sign-who'),
          style: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
        ),
        const SizedBox(height: 6),
        _row(l10n.passSignDevice, review.deviceCode, key: const ValueKey('pass-sign-device')),
        _row(l10n.memberPanelRole, orchardRoleLabel(review.role, l10n, names: orchardRoleNames(ref, review.orchardId)),
            key: const ValueKey('pass-sign-role')),
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Row(
            children: [
              SizedBox(width: 150, child: Text(l10n.passSignLasts, style: _prose)),
              ZestSelect<int>(
                key: const ValueKey('pass-sign-lasts'),
                value: _hours,
                width: 140,
                items: [
                  for (final hours in kOfflinePassChoices) ZestSelectItem(hours, offlineSpanWords(l10n, hours)),
                ],
                onChanged: _busy ? null : (hours) => setState(() => _hours = hours),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Text(l10n.passSignNote, key: const ValueKey('pass-sign-note'), style: _small),
        if (!review.fromServer) ...[
          const SizedBox(height: 12),
          VaultCallout(
            kind: ZestStatusKind.warning,
            icon: LucideIcons.alertTriangle,
            text: l10n.certSignStaleNote,
            textKey: const ValueKey('pass-sign-stale'),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    void close() => Navigator.of(context).pop();
    final review = _review;
    final pass = _passReview;
    final (Widget body, primary, secondary) = switch (_step) {
      _SignStep.enter => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.certSignIntro, style: _prose),
              const SizedBox(height: 12),
              _Entered(
                controller: _request,
                hint: l10n.certSignHint,
                fieldKey: const ValueKey('cert-sign-request'),
                pasteKey: const ValueKey('cert-sign-paste'),
                scanKey: const ValueKey('cert-sign-scan'),
                onSubmit: _read,
                onScan: _scan,
                problem: _problem,
                problemKey: const ValueKey('cert-sign-problem'),
              ),
            ],
          ),
          (label: l10n.certSignRead, onPressed: _busy ? null : _read, icon: null),
          (label: l10n.cancel, onPressed: close),
        ),
      _SignStep.review when pass != null => (
          _passBody(l10n, pass),
          (label: l10n.certSignConfirm, onPressed: _busy ? null : _sign, icon: LucideIcons.fileSignature),
          (label: l10n.back, onPressed: () => setState(() => _step = _SignStep.enter)),
        ),
      _SignStep.review => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.certSignWho(
                    review!.email ?? l10n.certSignSomeone, _crateName(ref, l10n, review.orchardId, review.crateId)),
                key: const ValueKey('cert-sign-who'),
                style: TextStyle(fontSize: 14, height: 1.4, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
              ),
              const SizedBox(height: 6),
              _row(l10n.certSignAs, review.userNames.join(', '), key: const ValueKey('cert-sign-as')),
              _row(l10n.certSignUntil, accessTimeText(review.validUntil, l10n), key: const ValueKey('cert-sign-until')),
              _row(l10n.memberPanelRole,
                  orchardRoleLabel(review.role, l10n, names: orchardRoleNames(ref, review.orchardId)),
                  key: const ValueKey('cert-sign-role')),
              const SizedBox(height: 12),
              Text(l10n.certSignKeysNote, style: _small),
              if (!review.fromServer) ...[
                const SizedBox(height: 12),
                VaultCallout(
                  kind: ZestStatusKind.warning,
                  icon: LucideIcons.alertTriangle,
                  text: l10n.certSignStaleNote,
                  textKey: const ValueKey('cert-sign-stale'),
                ),
              ],
            ],
          ),
          (label: l10n.certSignConfirm, onPressed: _busy ? null : _sign, icon: LucideIcons.fileSignature),
          (label: l10n.back, onPressed: () => setState(() => _step = _SignStep.enter)),
        ),
      _SignStep.signed => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(l10n.certSignedIntro, style: _prose),
              const SizedBox(height: 12),
              _Shown(
                text: _give!,
                codeKey: const ValueKey('cert-sign-code'),
                copyKey: const ValueKey('cert-sign-copy'),
              ),
            ],
          ),
          (label: l10n.done, onPressed: close, icon: null),
          (label: l10n.certSignAnother, onPressed: _another),
        ),
    };
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.fileSignature,
      title: l10n.certSignTitle,
      subtitle: _step == _SignStep.enter
          ? null
          : switch (pass?.orchardId ?? review?.orchardId) {
              final id? => _orchardName(ref, l10n, id),
              null => null,
            },
      body: body,
      primaryAction: primary,
      secondaryAction: secondary,
    );
  }
}
