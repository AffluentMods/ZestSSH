import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/cloud/cloud_statement.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';

/// The Help panel's footer says how ZestSSH Cloud stands (3.0, the outage
/// work). Where its own check got no answer it said "ZestSSH Cloud is
/// unreachable" whatever was in the way, a device with no network
/// included. It says which kind of "no answer" it is now, as far as the app
/// knows, in the words the status bar has for it, and in amber where what
/// is in the way is on this side.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final l10n = lookupAppLocalizations(const Locale('en'));

  late SharedPreferences prefs;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });
  tearDown(() => currentCloudReach = null);

  Future<void> open(WidgetTester tester, CloudStatus status) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        helpDockProvider.overrideWith((_) => HelpPage.home),
        cloudStatusProvider.overrideWith((_) async => status),
        appVersionLabelProvider.overrideWith((_) async => '3.0.0'),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Row(
            children: [
              const Expanded(child: SizedBox()),
              HelpDock(
                captureScreenshot: ({required bool redacted}) async => Uint8List.fromList(const [0x89, 0x50, 0x4e, 0x47]),
                onCopyRedactedScreenshot: () {},
                onOpenShortcuts: () {},
                onAbout: () {},
              ),
            ],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The colour of the footer's dot.
  Color dot(WidgetTester tester) {
    final dots = tester.widgetList<Container>(find.byWidgetPredicate((w) {
      if (w is! Container) return false;
      final decoration = w.decoration;
      return decoration is BoxDecoration && decoration.shape == BoxShape.circle && w.constraints?.maxWidth == 7;
    }));
    return (dots.single.decoration! as BoxDecoration).color!;
  }

  /// What the app knows of the service after its health check met [health]
  /// and the status service said [said].
  Future<void> found(WidgetTester tester, Object health, CloudStatement? said, {bool? network}) async {
    final reach = CloudReachService(
      check: () async => health is int ? health : throw health,
      status: () async => said,
      timer: (wait, then) => Timer(const Duration(days: 1), () {}),
    );
    addTearDown(reach.dispose);
    currentCloudReach = reach;
    if (network != null) reach.networkChanged(up: network);
    await tester.runAsync(reach.checkNow);
  }

  const refused = SocketException('Connection refused');
  const at = 1791474000;
  const down = CloudStatement(down: true, at: at, until: at + 900, since: at - 3600, keyId: 'k1');
  const up = CloudStatement(down: false, at: at, until: at + 900, since: 0, keyId: 'k1');

  testWidgets('no answer, and nothing more known: the service is said not to respond, in red', (tester) async {
    await open(tester, CloudStatus.unreachable);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.cloudChipNotResponding)), findsOneWidget);
    expect(dot(tester), AppColors.v3Error);
  });

  testWidgets('no answer, and the device has no network: said as the device, in amber', (tester) async {
    await found(tester, refused, null, network: false);
    await open(tester, CloudStatus.unreachable);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.cloudChipOffline)), findsOneWidget);
    expect(find.textContaining(l10n.cloudChipNotResponding), findsNothing);
    expect(dot(tester), AppColors.v3Warning);
  });

  testWidgets('no answer, and the service proven down: said as that, in red', (tester) async {
    await found(tester, refused, down);
    await open(tester, CloudStatus.unreachable);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.cloudChipDown)), findsOneWidget);
    expect(dot(tester), AppColors.v3Error);
  });

  testWidgets('no answer, and the service up: this network is in the way, in amber', (tester) async {
    await found(tester, refused, up);
    await open(tester, CloudStatus.unreachable);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.cloudChipBlocked)), findsOneWidget);
    expect(dot(tester), AppColors.v3Warning);
  });

  testWidgets('no answer, and nothing of ZestSSH reached: no internet, in amber', (tester) async {
    await found(tester, refused, null);
    await open(tester, CloudStatus.unreachable);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.cloudChipNoInternet)), findsOneWidget);
    expect(dot(tester), AppColors.v3Warning);
  });

  testWidgets('answering, and answering with trouble, are said as before', (tester) async {
    await open(tester, CloudStatus.ok);
    expect(find.text(l10n.helpFooterStatus('3.0.0')), findsOneWidget);
    expect(dot(tester), AppColors.v3Success);

    await tester.pumpWidget(const SizedBox());
    await open(tester, CloudStatus.degraded);
    expect(find.text(l10n.helpFooterStatusDegraded('3.0.0', l10n.helpStatusDegraded)), findsOneWidget);
    expect(dot(tester), AppColors.v3Warning);
  });

  test('the sentence that called every kind of no answer "unreachable" is gone, in every language', () {
    for (final f in Directory('lib/l10n').listSync()) {
      if (f is! File || !f.path.endsWith('.arb')) continue;
      expect(f.readAsStringSync(), isNot(contains('"helpStatusUnreachable"')), reason: f.path);
    }
    expect(File('lib/ui/screens/desktop/widgets/help_dock.dart').readAsStringSync(), contains('cloudNoAnswerNow()'));
  });
}
