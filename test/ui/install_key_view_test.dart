import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/run/run_on_hosts_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// An install that keeps what it was asked and shows what the test sets.
class _Recorded extends RunOnHostsNotifier {
  _Recorded() : super((_) async => throw StateError('nothing is signed in to here'));

  final runs = <({List<String> hosts, String command, String? input})>[];
  final calls = <String>[];

  void show(HostsRun run) => state = run;

  @override
  Future<void> run(List<Connection> hosts, String command,
      {String? typed, List<String> secrets = const [], String? shown, String? input}) async {
    runs.add((hosts: [for (final h in hosts) h.id], command: command, input: input));
    state = HostsRun(
      command: command,
      input: input,
      hosts: [for (final h in hosts) HostRun(host: h, state: HostRunState.signingIn)],
      running: true,
    );
  }

  @override
  Future<void> again({bool all = false}) async => calls.add('again');
}

Connection _conn(String id) => Connection(
      id: id,
      label: id,
      host: '$id.example.com',
      port: 22,
      colorIndex: 0,
      protocol: 'ssh',
      zlibCompression: false,
      keepAliveSeconds: 0,
      envVars: '',
      forwardAgent: false,
      compatibilityMode: false,
      sortOrder: 0,
      sizeTier: 1,
      pinned: false,
      monitored: false,
      createdAt: DateTime(2026, 10, 15),
      updatedAt: DateTime(2026, 10, 15),
    );

const _line = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyForTheTestOnly alex@laptop';

Identity _key({String? public = _line}) => Identity(
      id: 'k1',
      label: 'Deploy key',
      username: 'deploy',
      authMethod: 'publicKey',
      publicKeyData: public,
      colorIndex: 0,
      isDefault: false,
      allowUnattended: false,
      usesAgent: false,
      passwordAfterKey: false,
      createdAt: DateTime(2026, 10, 15),
    );

/// Install key on hosts (3.0), its dialog: hosts ticked, Install, and each
/// host's result: added for the account it signs in as, there already, or
/// not added; the key on the command's input, never in it; Install again
/// where it failed; Copy all results; a key with no public key, and the free
/// plan's limit.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;
  final copied = <String>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    L10nGlobal.update(l10n);
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied.add((call.arguments as Map)['text'] as String);
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, null));

  Future<_Recorded> open(WidgetTester tester,
      {Identity? key, List<String> hosts = const ['web1', 'web2', 'web3'], bool pro = true}) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final recorded = _Recorded();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        installKeyRunProvider.overrideWith((ref) => recorded),
        connectionsWithDetailsProvider.overrideWith(
            (ref) => Stream.value([for (final id in hosts) ConnectionWithDetails(connection: _conn(id))])),
        isProProvider.overrideWith((ref) => _Pro(pro)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) =>
                TextButton(onPressed: () => showInstallKey(context, key ?? _key()), child: const Text('open')),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(InstallKeyDialog), findsOneWidget);
    return recorded;
  }

  Finder primary() => find.byKey(const ValueKey('zest-dialog-primary'));
  String labelOf(WidgetTester tester, Finder button) => (tester.widget(button) as dynamic).label as String;
  bool enabled(WidgetTester tester, Finder button) => (tester.widget(button) as dynamic).onPressed != null;
  String textOf(WidgetTester tester, String key) => tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  testWidgets('hosts ticked: the key goes to each on its input, never in the command; each says added for its '
      'account, there already, or not added; Copy all results; Install again where it failed', (tester) async {
    final run = await open(tester);
    expect(find.text(l10n.installKeySubtitle('Deploy key')), findsOneWidget);
    expect(find.byKey(const ValueKey('install-pick')), findsOneWidget);
    expect(enabled(tester, primary()), isFalse);
    await tester.tap(find.byKey(const ValueKey('install-host-web1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('install-host-web2')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('install-host-web3')));
    await tester.pump();
    expect(labelOf(tester, primary()), l10n.installKeyRun(3));
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(run.runs.single.hosts, ['web1', 'web2', 'web3']);
    expect(run.runs.single.command, kInstallKeyCommand);
    expect(run.runs.single.command, isNot(contains('AAAAC3Nz')), reason: 'the key is never in the command');
    expect(run.runs.single.input, '$_line\n');
    expect(textOf(tester, 'install-summary'), l10n.runOnHostsProgress(0, 3));

    run.show(HostsRun(command: kInstallKeyCommand, input: '$_line\n', hosts: [
      HostRun(host: _conn('web1'), state: HostRunState.done, exitCode: 0, output: '$kKeyAdded\n', user: 'deploy'),
      HostRun(host: _conn('web2'), state: HostRunState.done, exitCode: 0, output: '$kKeyThere\n', user: 'root'),
      HostRun(
          host: _conn('web3'),
          state: HostRunState.done,
          exitCode: 7,
          errors: 'sh: .ssh/authorized_keys: Permission denied\n',
          user: 'deploy'),
    ]));
    await tester.pumpAndSettle();
    expect(textOf(tester, 'install-summary'), l10n.installKeySummary(2, 1));
    expect(textOf(tester, 'run-state-web1'), l10n.installKeyAdded('deploy'));
    expect(textOf(tester, 'run-state-web2'), l10n.installKeyThere('root'));
    expect(textOf(tester, 'run-state-web3'), l10n.installKeyNotAdded);
    expect(find.byType(HostRunRow), findsNWidgets(3));

    await tester.tap(find.byKey(const ValueKey('install-copy')));
    await tester.pump();
    expect(copied.single, startsWith('${l10n.installKeyTitle}: Deploy key\n'));
    expect(copied.single, contains('== web1 (web1.example.com): ${l10n.installKeyAdded('deploy')}\n'));
    expect(copied.single, contains('== web3 (web3.example.com): ${l10n.installKeyNotAdded}\nsh: .ssh/authorized_keys: Permission denied\n'));
    expect(copied.single, isNot(contains(kKeyAdded)));

    expect(labelOf(tester, primary()), l10n.installKeyAgain);
    await tester.tap(primary());
    await tester.pump();
    expect(run.calls, ['again']);
  });

  testWidgets('opened for another key while one installs: the results on screen say whose they are', (tester) async {
    final run = await open(tester);
    await tester.tap(find.byKey(const ValueKey('install-host-web1')));
    await tester.pump();
    await tester.tap(primary());
    await tester.pumpAndSettle();
    expect(run.runs, hasLength(1));
    // Closed while it runs, and opened again for another key.
    Navigator.of(tester.element(find.byType(InstallKeyDialog))).pop();
    await tester.pumpAndSettle();
    final other = Identity(
      id: 'k2',
      label: 'Backup key',
      username: 'backup',
      authMethod: 'publicKey',
      publicKeyData: _line,
      colorIndex: 0,
      isDefault: false,
      allowUnattended: false,
      usesAgent: false,
      passwordAfterKey: false,
      createdAt: DateTime(2026, 10, 15),
    );
    unawaited(showInstallKey(tester.element(find.text('open')), other));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('install-summary')), findsOneWidget, reason: 'the run on screen');
    expect(find.text(l10n.installKeySubtitle('Deploy key')), findsOneWidget);
    expect(find.text(l10n.installKeySubtitle('Backup key')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('install-copy')));
    await tester.pump();
    expect(copied.single, startsWith('${l10n.installKeyTitle}: Deploy key\n'));
  });

  testWidgets('every host has it: nothing to install again', (tester) async {
    final run = await open(tester);
    await tester.tap(find.byKey(const ValueKey('install-host-web1')));
    await tester.pump();
    await tester.tap(primary());
    await tester.pumpAndSettle();
    run.show(HostsRun(command: kInstallKeyCommand, hosts: [
      HostRun(host: _conn('web1'), state: HostRunState.done, exitCode: 0, output: kKeyThere, user: 'deploy'),
    ]));
    await tester.pumpAndSettle();
    expect(enabled(tester, primary()), isFalse);
  });

  testWidgets('a key with no public key says so, and installs nothing', (tester) async {
    await open(tester, key: _key(public: null));
    await tester.tap(find.byKey(const ValueKey('install-host-web1')));
    await tester.pump();
    expect(find.byKey(const ValueKey('install-no-key')), findsOneWidget);
    expect(enabled(tester, primary()), isFalse);
  });

  testWidgets('the free plan installs on as many hosts at once as it opens sessions', (tester) async {
    final hosts = [for (var i = 1; i <= runOnHostsFreeLimit + 1; i++) 'web$i'];
    await open(tester, hosts: hosts, pro: false);
    await tester.tap(find.byKey(const ValueKey('install-group-none')));
    await tester.pump();
    expect(find.byKey(const ValueKey('install-limit')), findsOneWidget);
    expect(enabled(tester, primary()), isFalse);
    await tester.tap(find.byKey(ValueKey('install-host-${hosts.last}')));
    await tester.pump();
    expect(find.byKey(const ValueKey('install-limit')), findsNothing);
    expect(enabled(tester, primary()), isTrue);
  });
}
