import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' show Bidi, DateFormat;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:zestssh/l10n/generated/app_localizations.dart';

// The recovery kit (3.0): the recovery key on one page with
// everything a person needs to use it years later: which account it is for,
// when it was made, what it does, how to use it, where to keep it, and how
// to check or replace it. Saved as text and printed or saved as a PDF. The
// PDF page is drawn by the app itself, so it reads right in every language
// the app speaks (the PDF library's own fonts cover only Latin letters).

/// Everything on the kit, in the person's language.
class RecoveryKitText {
  const RecoveryKitText({
    required this.title,
    required this.privateNote,
    required this.accountLabel,
    required this.account,
    required this.madeLabel,
    required this.made,
    required this.keyLabel,
    required this.key,
    required this.whatTitle,
    required this.what,
    required this.howTitle,
    required this.steps,
    required this.keepTitle,
    required this.keep,
    required this.checkTitle,
    required this.check,
    required this.footer,
    required this.rtl,
  });

  /// The kit for [key], made [made] for the account [account] (null when the
  /// vault is on the person's own storage with no ZestSSH account).
  factory RecoveryKitText.of(AppLocalizations l10n, {required String key, required String? account, required DateTime made}) =>
      RecoveryKitText(
        title: l10n.recoveryKitTitle,
        privateNote: l10n.recoveryKitPrivate,
        accountLabel: l10n.recoveryKitAccount,
        account: account,
        madeLabel: l10n.recoveryKitMade,
        made: DateFormat.yMMMMd(l10n.localeName).format(made),
        keyLabel: l10n.recoveryKitYourKey,
        key: key,
        whatTitle: l10n.recoveryKitWhatTitle,
        what: l10n.recoveryKitWhat,
        howTitle: l10n.recoveryKitHowTitle,
        steps: [
          account == null ? l10n.recoveryKitStep1Storage : l10n.recoveryKitStep1Account(account),
          l10n.recoveryKitStep2,
          l10n.recoveryKitStep3,
        ],
        keepTitle: l10n.recoveryKitKeepTitle,
        keep: l10n.recoveryKitKeep,
        checkTitle: l10n.recoveryKitCheckTitle,
        check: l10n.recoveryKitCheck,
        footer: l10n.recoveryKitFooter,
        rtl: Bidi.isRtlLanguage(l10n.localeName),
      );

  final String title;
  final String privateNote;
  final String accountLabel;
  final String? account;
  final String madeLabel;
  final String made;
  final String keyLabel;
  final String key;
  final String whatTitle;
  final String what;
  final String howTitle;
  final List<String> steps;
  final String keepTitle;
  final String keep;
  final String checkTitle;
  final String check;
  final String footer;
  final bool rtl;
}

/// The kit as a text file.
String recoveryKitPlainText(RecoveryKitText t) {
  final b = StringBuffer()
    ..writeln(t.title)
    ..writeln('=' * t.title.length.clamp(8, 60))
    ..writeln(t.privateNote)
    ..writeln();
  if (t.account != null) b.writeln('${t.accountLabel}: ${t.account}');
  b
    ..writeln('${t.madeLabel}: ${t.made}')
    ..writeln()
    ..writeln(t.keyLabel)
    ..writeln()
    ..writeln('    ${t.key}')
    ..writeln()
    ..writeln(t.whatTitle)
    ..writeln(t.what)
    ..writeln()
    ..writeln(t.howTitle);
  for (var i = 0; i < t.steps.length; i++) {
    b.writeln('${i + 1}. ${t.steps[i]}');
  }
  b
    ..writeln()
    ..writeln(t.keepTitle)
    ..writeln(t.keep)
    ..writeln()
    ..writeln(t.checkTitle)
    ..writeln(t.check)
    ..writeln()
    ..writeln(t.footer);
  return b.toString();
}

/// An A4 page at 96 dots per inch, in logical pixels.
const kRecoveryKitPageSize = Size(794, 1123);

const _paper = Color(0xFFFFFFFF);
const _ink = Color(0xFF1B1B1F);
const _muted = Color(0xFF585864);
const _rule = Color(0xFFFF7A1A);
const _keyFill = Color(0xFFF3F3F5);
const _keyBorder = Color(0xFFD6D6DC);

/// The kit as a printed page: dark ink on white, whatever the app's theme.
class RecoveryKitPage extends StatelessWidget {
  const RecoveryKitPage({super.key, required this.text});

  final RecoveryKitText text;

  @override
  Widget build(BuildContext context) {
    final t = text;
    TextStyle style(double size, {FontWeight weight = FontWeight.w400, Color color = _ink, double height = 1.45}) =>
        TextStyle(fontFamily: 'GeistSans', fontSize: size, fontWeight: weight, color: color, height: height, decoration: TextDecoration.none);
    Widget section(String title, Widget body) => Padding(
          padding: const EdgeInsets.only(top: 22),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: style(14, weight: FontWeight.w700)),
              const SizedBox(height: 6),
              body,
            ],
          ),
        );
    Widget fact(String label, String value) => Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '$label: ', style: style(12.5, color: _muted)),
              TextSpan(text: value, style: style(12.5, weight: FontWeight.w600)),
            ]),
          ),
        );
    return Directionality(
      textDirection: t.rtl ? TextDirection.rtl : TextDirection.ltr,
      child: Container(
        width: kRecoveryKitPageSize.width,
        height: kRecoveryKitPageSize.height,
        color: _paper,
        padding: const EdgeInsets.fromLTRB(64, 60, 64, 48),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(height: 4, width: 56, color: _rule),
            ),
            const SizedBox(height: 18),
            Text(t.title, style: style(28, weight: FontWeight.w700, height: 1.15)),
            const SizedBox(height: 6),
            Text(t.privateNote, style: style(12.5, color: _muted)),
            const SizedBox(height: 22),
            if (t.account != null) fact(t.accountLabel, t.account!),
            fact(t.madeLabel, t.made),
            const SizedBox(height: 18),
            Text(t.keyLabel, style: style(13, weight: FontWeight.w700)),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
              decoration: BoxDecoration(
                color: _keyFill,
                border: Border.all(color: _keyBorder, width: 1.2),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Directionality(
                // The key reads left to right in every language.
                textDirection: TextDirection.ltr,
                child: Text(
                  t.key,
                  key: const ValueKey('recovery-kit-key'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 25,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 2.2,
                    color: _ink,
                    decoration: TextDecoration.none,
                  ),
                ),
              ),
            ),
            section(t.whatTitle, Text(t.what, style: style(12.5))),
            section(
              t.howTitle,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < t.steps.length; i++)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 5),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(width: 22, child: Text('${i + 1}.', style: style(12.5, weight: FontWeight.w700))),
                          Expanded(child: Text(t.steps[i], style: style(12.5))),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            section(t.keepTitle, Text(t.keep, style: style(12.5))),
            section(t.checkTitle, Text(t.check, style: style(12.5))),
            const Spacer(),
            Container(height: 1, color: _keyBorder),
            const SizedBox(height: 10),
            Text(t.footer, style: style(10.5, color: _muted)),
          ],
        ),
      ),
    );
  }
}

/// [widget] drawn off screen at [size] (logical pixels) and [pixelRatio]:
/// the PNG bytes. Nothing is shown.
Future<Uint8List> renderOffscreenPng(Widget widget, {required Size size, double pixelRatio = 2.5}) async {
  final boundary = RenderRepaintBoundary();
  final view = WidgetsBinding.instance.platformDispatcher.implicitView ?? WidgetsBinding.instance.platformDispatcher.views.first;
  final renderView = RenderView(
    view: view,
    child: RenderPositionedBox(alignment: Alignment.center, child: boundary),
    configuration: ViewConfiguration(
      logicalConstraints: BoxConstraints.tight(size),
      physicalConstraints: BoxConstraints.tight(size * pixelRatio),
      devicePixelRatio: pixelRatio,
    ),
  );
  final pipelineOwner = PipelineOwner()..rootNode = renderView;
  renderView.prepareInitialFrame();
  final buildOwner = BuildOwner(focusManager: FocusManager(), onBuildScheduled: () {});
  final root = RenderObjectToWidgetAdapter<RenderBox>(
    container: boundary,
    child: MediaQuery(
      data: MediaQueryData(size: size, devicePixelRatio: pixelRatio),
      child: widget,
    ),
  ).attachToRenderTree(buildOwner);
  buildOwner
    ..buildScope(root)
    ..finalizeTree();
  pipelineOwner
    ..flushLayout()
    ..flushCompositingBits()
    ..flushPaint();
  final image = await boundary.toImage(pixelRatio: pixelRatio);
  try {
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  } finally {
    image.dispose();
  }
}

/// The kit as a one-page A4 PDF, the page drawn by the app (every language
/// reads right), ready to print or save. [compress] off only for tests that
/// read the file.
Future<Uint8List> recoveryKitPdf(RecoveryKitText text, {required String title, bool compress = true}) async {
  final png = await renderOffscreenPng(RecoveryKitPage(text: text), size: kRecoveryKitPageSize);
  final doc = pw.Document(title: title, creator: 'ZestSSH', compress: compress);
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4,
    margin: pw.EdgeInsets.zero,
    build: (_) => pw.Image(pw.MemoryImage(png), fit: pw.BoxFit.contain),
  ));
  return doc.save();
}
