import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/mosh/builtin_mosh_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/widgets/mosh_contact_mark.dart';

import '../../a11y/a11y_checks.dart';

/// A shell with a Mosh link the test sets (the built-in client's, 4.0).
class _MoshShell implements ShellService, MoshLinkSource {
  final link = ValueNotifier<MoshLink>(const MoshLink());

  @override
  ValueListenable<MoshLink> get moshLink => link;

  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => false;
}

/// "Last contact" over a Mosh session's terminal while its host is quiet: shown
/// only then, in words with an icon, read by a screen reader with what it
/// means, and nothing for a session that is not a built-in Mosh one.
void main() {
  setUp(() => AppColors.applyTheme(BuiltInThemes.getById('default_dark').colorScheme));
  final now = DateTime(2026, 11, 14, 12);

  Widget app(ShellService? shell, {bool screenReader = false}) => MaterialApp(
        theme: BuiltInThemes.getById('default_dark').toThemeData(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Stack(children: [
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            Positioned(top: 0, right: 0, child: MoshContactMark(shell: shell, now: () => now)),
          ]),
        ),
      );

  testWidgets('nothing while the host answers, the mark once it is quiet, gone when it answers again', (tester) async {
    final shell = _MoshShell();
    await tester.pumpWidget(app(shell));
    expect(find.byKey(const ValueKey('mosh-contact-mark')), findsNothing);
    shell.link.value = const MoshLink(lastHeard: Duration(seconds: 4), srttMs: 30);
    await tester.pump();
    expect(find.byKey(const ValueKey('mosh-contact-mark')), findsNothing, reason: 'a heartbeat or two late is nothing');
    shell.link.value = const MoshLink(lastHeard: Duration(seconds: 12), srttMs: 30);
    await tester.pump();
    expect(find.text('Last contact 12s ago'), findsOneWidget);
    expect(find.bySemanticsLabel('Mosh: no contact with the host, last contact 12s ago. Still trying.'), findsOneWidget);
    shell.link.value = const MoshLink(lastHeard: Duration(seconds: 75));
    await tester.pump();
    expect(find.text('Last contact 1m ago'), findsOneWidget);
    shell.link.value = const MoshLink(lastHeard: Duration.zero);
    await tester.pump();
    expect(find.byKey(const ValueKey('mosh-contact-mark')), findsNothing);
  });

  testWidgets('no mark for a session that is not a built-in Mosh one', (tester) async {
    await tester.pumpWidget(app(null));
    expect(find.byKey(const ValueKey('mosh-contact-mark')), findsNothing);
    expect(MoshContactMark.sourceOf(null), isNull);
  });

  testWidgets('accessibility: words that read on what is behind them, a name for a screen reader', (tester) async {
    final shell = _MoshShell()..link.value = const MoshLink(lastHeard: Duration(seconds: 30));
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(app(shell, screenReader: true));
    await tester.pump();
    // Not a control (nothing to press): its words and icon on what is behind
    // them, and its name, are what is held.
    await expectA11y(tester, computer: true, where: 'the Mosh contact mark');
    expect(find.bySemanticsLabel(RegExp('^Mosh: no contact with the host')), findsOneWidget);
    handle.dispose();
  });
}
