import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/profile/device_approval_dialogs.dart' show ApprovalWords;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

/// Trusted devices (3.0), the two screens of an approval: on the
/// device that asks, the request and the three words to read out; on an
/// approved device, who asks, the same three words to compare, and the
/// approval itself. What each step sends and checks is in
/// orchard_devices.dart.

/// How often an open dialog looks at where its request stands.
const _lookEvery = Duration(seconds: 2);

/// Waiting for the other device: a ring on its track, the words beside it.
Widget _waiting(String text) => TeamWaiting(text);

Widget _text(String text, {Color? color, Key? key}) => Text(text,
    key: key, style: TextStyle(fontSize: 13, height: 1.45, color: color ?? ZestColors.textSecondary));

/// A device's short name, set apart so that two people can read it out.
Widget _codeLine(String label, {Key? key}) => Text(label,
    key: key,
    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, height: 1.45, color: ZestColors.textTertiary));

/// On a device that is not approved for [orchard]: asks, and shows the words
/// once someone answers. Closing it before the device is approved takes the
/// request back.
Future<void> showDeviceAsk(BuildContext context, WidgetRef ref, OrchardSummary orchard) => showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: _DeviceAskDialog(orchard: orchard),
    );

/// On an approved device: the request [request] of [name]'s device ([own]
/// when it is another device of this account), from answering it to
/// approving or declining.
Future<void> showDeviceRequest(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard,
  DeviceRequestView request, {
  required String name,
  required bool own,
}) =>
    showZestModal<void>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: _DeviceRequestDialog(orchard: orchard, request: request, name: name, own: own),
    );

// ── The device that asks ───────────────────────────────────────────────

enum _AskStep { starting, waiting, words, approved, gone, cannot, failed }

class _DeviceAskDialog extends ConsumerStatefulWidget {
  const _DeviceAskDialog({required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<_DeviceAskDialog> createState() => _DeviceAskDialogState();
}

class _DeviceAskDialogState extends ConsumerState<_DeviceAskDialog> {
  late final OrchardService _service;
  _AskStep _step = _AskStep.starting;
  DeviceAsk? _ask;
  String? _code;
  String? _failure;
  Timer? _timer;
  bool _looking = false;

  String get _id => widget.orchard.id;

  @override
  void initState() {
    super.initState();
    _service = ref.read(orchardServiceProvider);
    // After the first frame: the steps read this screen's language.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _start();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    // Closed before anyone approved: the request ends with the dialog.
    if (_step == _AskStep.waiting || _step == _AskStep.words) {
      unawaited(_service.withdrawDeviceAsk(_id).catchError((Object _) {}));
    }
    super.dispose();
  }

  void _show(_AskStep step, {DeviceAsk? ask, String? failure}) {
    if (!mounted) return;
    setState(() {
      _step = step;
      _ask = ask ?? _ask;
      _failure = failure;
    });
  }

  Future<void> _start() async {
    final l10n = AppLocalizations.of(context)!;
    _show(_AskStep.starting);
    try {
      final ask = await _service.askDeviceApproval(_id);
      final code = (await _service.deviceStanding(_id)).thisCode;
      if (!mounted) return;
      _code = code;
      _show(ask.words == null ? _AskStep.waiting : _AskStep.words, ask: ask);
      _timer ??= Timer.periodic(_lookEvery, (_) => _look());
    } on DeviceCannotBeNamed {
      _show(_AskStep.cannot);
    } on OrchardServerException catch (e) {
      if (e.code == 'device-approved') {
        await _settled();
      } else {
        AppLogger.warning('Trusted devices: asking failed ($e)');
        _show(_AskStep.failed, failure: orchardErrorMessage(e, l10n));
      }
    } catch (e) {
      AppLogger.warning('Trusted devices: asking failed ($e)');
      _show(_AskStep.failed, failure: orchardErrorMessage(e, l10n));
    }
  }

  /// Where the request stands now. Gone, it was approved, declined or ran
  /// out of time: the record says which.
  Future<void> _look() async {
    if (_looking || !mounted || (_step != _AskStep.waiting && _step != _AskStep.words)) return;
    _looking = true;
    try {
      final ask = await _service.deviceAsk(_id);
      if (!mounted) return;
      if (ask != null) {
        _show(ask.words == null ? _AskStep.waiting : _AskStep.words, ask: ask);
      } else {
        await _settled();
      }
    } catch (e) {
      // Looked at again in a moment.
      AppLogger.info('Trusted devices: the request could not be read ($e)');
    } finally {
      _looking = false;
    }
  }

  /// The request is gone: reads the Orchard again, and says whether this
  /// device is approved now.
  Future<void> _settled() async {
    _timer?.cancel();
    _timer = null;
    var approved = false;
    try {
      await _service.refresh();
      approved = (await _service.deviceStanding(_id)).approved;
    } catch (e) {
      AppLogger.info('Trusted devices: where this device stands could not be read ($e)');
    }
    if (!mounted) return;
    ref.read(orchardListVersionProvider.notifier).state++;
    if (approved) {
      // What the Orchard holds comes now.
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
    }
    _show(approved ? _AskStep.approved : _AskStep.gone);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    void close() => Navigator.of(context).pop();
    final code = _code;
    final again = (label: l10n.deviceAskAgain, onPressed: _start, icon: LucideIcons.refreshCw);
    final (Widget body, primary) = switch (_step) {
      _AskStep.starting => (_waiting(l10n.deviceAskStarting), null),
      _AskStep.waiting => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text(l10n.deviceAskIntro, color: ZestColors.textPrimary),
              const SizedBox(height: 10),
              _text(l10n.deviceAskWhere),
              if (code != null) ...[
                const SizedBox(height: 10),
                _codeLine(l10n.deviceThisCode(code), key: const ValueKey('device-ask-code')),
              ],
              const SizedBox(height: 14),
              _waiting(l10n.deviceAskWaiting),
            ],
          ),
          null,
        ),
      _AskStep.words => (
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _text((_ask?.sameAccount ?? false) ? l10n.deviceAskWordsOwn : l10n.deviceAskWords,
                  color: ZestColors.textPrimary),
              const SizedBox(height: 14),
              ApprovalWords(key: const ValueKey('device-ask-words'), words: _ask!.words!),
              if (code != null) ...[
                const SizedBox(height: 10),
                _codeLine(l10n.deviceThisCode(code), key: const ValueKey('device-ask-code')),
              ],
              const SizedBox(height: 14),
              _waiting(l10n.deviceAskWaitingApproval),
            ],
          ),
          null,
        ),
      _AskStep.approved => (
          Row(
            children: [
              const TeamIconTile(icon: LucideIcons.checkCircle2, tone: TeamTone.success, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: _text(l10n.deviceAskApproved(name),
                    key: const ValueKey('device-ask-approved'), color: ZestColors.textPrimary),
              ),
            ],
          ),
          (label: l10n.done, onPressed: close, icon: null),
        ),
      _AskStep.gone => (_text(l10n.deviceAskGone, key: const ValueKey('device-ask-gone')), again),
      _AskStep.cannot => (_text(l10n.deviceAskCannot, key: const ValueKey('device-ask-cannot')), null),
      _AskStep.failed => (_text(_failure ?? l10n.deviceAskGone, key: const ValueKey('device-ask-failed')), again),
    };
    final done = _step == _AskStep.approved;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: switch (_step) {
        // Why it did not go through, plainly: nothing amber.
        _AskStep.gone || _AskStep.cannot || _AskStep.failed => ZestDialogTone.neutral,
        _AskStep.approved => ZestDialogTone.success,
        _ => ZestDialogTone.info,
      },
      icon: done ? LucideIcons.shieldCheck : LucideIcons.monitorSmartphone,
      title: done ? l10n.teamAdminDeviceApproved : l10n.deviceAskTitle,
      subtitle: name,
      body: body,
      primaryAction: primary,
      secondaryAction: done
          ? null
          : (
              label: _step == _AskStep.waiting || _step == _AskStep.words ? l10n.cancel : l10n.close,
              onPressed: close,
            ),
    );
  }
}

// ── The device that approves ───────────────────────────────────────────

class _DeviceRequestDialog extends ConsumerStatefulWidget {
  const _DeviceRequestDialog({required this.orchard, required this.request, required this.name, required this.own});

  final OrchardSummary orchard;
  final DeviceRequestView request;
  final String name;
  final bool own;

  @override
  ConsumerState<_DeviceRequestDialog> createState() => _DeviceRequestDialogState();
}

class _DeviceRequestDialogState extends ConsumerState<_DeviceRequestDialog> {
  late final OrchardService _service;
  late DeviceRequestView _view = widget.request;
  Timer? _timer;
  bool _looking = false;

  /// Answering, approving or declining is on its way.
  bool _busy = false;

  /// This dialog answered the request: closed before it approved, it
  /// declines, so the other device does not wait for nothing.
  bool _answered = false;

  /// Approved or declined: nothing more to end.
  bool _done = false;

  /// The request is no longer listed.
  bool _gone = false;
  String? _failure;

  String get _id => widget.orchard.id;

  @override
  void initState() {
    super.initState();
    _service = ref.read(orchardServiceProvider);
    _timer = Timer.periodic(_lookEvery, (_) => _look());
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (_answered && !_done && !_gone) {
      unawaited(_service.declineDeviceRequest(_id, widget.request.id).catchError((Object _) {}));
    }
    super.dispose();
  }

  Future<void> _look() async {
    if (_looking || _busy || _done || _gone || !mounted) return;
    _looking = true;
    try {
      final listed = (await _service.deviceRequests(_id)).where((r) => r.id == widget.request.id).firstOrNull;
      if (!mounted || _busy || _done) return;
      setState(() {
        if (listed == null) {
          _gone = true;
          _timer?.cancel();
        } else {
          _view = listed;
          if (listed.stage == DeviceRequestStage.changed) {
            // Ended by the service: nothing left to decline.
            _gone = true;
            _timer?.cancel();
          }
        }
      });
    } catch (e) {
      // Looked at again in a moment.
      AppLogger.info('Trusted devices: the requests could not be read ($e)');
    } finally {
      _looking = false;
    }
  }

  Future<void> _run(Future<void> Function() step) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      await step();
    } on DeviceRequestGone {
      if (mounted) setState(() => _gone = true);
    } on OrchardServerException catch (e) {
      AppLogger.warning('Trusted devices: $e');
      if (mounted) {
        setState(() => _failure = e.code == 'answered' ? l10n.deviceRequestTaken : orchardChangeErrorMessage(e, l10n));
      }
    } catch (e) {
      AppLogger.warning('Trusted devices: $e');
      if (mounted) setState(() => _failure = orchardChangeErrorMessage(e, l10n));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _answer() => _run(() async {
        await _service.answerDeviceRequest(_id, widget.request.id);
        _answered = true;
        final listed = (await _service.deviceRequests(_id)).where((r) => r.id == widget.request.id).firstOrNull;
        if (mounted && listed != null) setState(() => _view = listed);
      });

  Future<void> _approve() => _run(() async {
        final l10n = AppLocalizations.of(context)!;
        final done = await withRecentSignIn(
          context,
          ref,
          () => _service.approveDevice(_id, widget.request.id),
          summary: (
            what: widget.own ? l10n.stepUpApproveOwnDevice : l10n.stepUpApproveDevice(widget.name),
            effects: [l10n.stepUpApproveDeviceEffect],
          ),
        );
        if (!done || !mounted) return;
        _done = true;
        ref.read(orchardListVersionProvider.notifier).state++;
        ref.read(deviceRequestsVersionProvider.notifier).state++;
        showTopSnackBar(context, l10n.deviceRequestApproved, isSuccess: true);
        Navigator.of(context).pop();
      });

  Future<void> _decline({required bool differ}) => _run(() async {
        final l10n = AppLocalizations.of(context)!;
        await _service.declineDeviceRequest(_id, widget.request.id);
        _done = true;
        if (!mounted) return;
        ref.read(deviceRequestsVersionProvider.notifier).state++;
        showTopSnackBar(context, differ ? l10n.deviceRequestDiffered : l10n.deviceRequestDeclined,
            isWarning: differ, duration: Duration(seconds: differ ? 10 : 4));
        Navigator.of(context).pop();
      });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    void close() => Navigator.of(context).pop();
    final failure = _failure;
    final stage = _view.stage;
    final code = _view.code;
    Widget column(List<Widget> children) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ...children,
            if (failure != null) ...[
              const SizedBox(height: 12),
              _text(failure, key: const ValueKey('device-request-error'), color: ZestColors.statusError),
            ],
          ],
        );
    final closeOnly = (label: l10n.close, onPressed: close);
    final Widget body;
    ({String label, VoidCallback? onPressed, IconData? icon})? primary;
    ({String label, VoidCallback? onPressed})? secondary = closeOnly;
    ({String label, VoidCallback? onPressed})? tertiary;
    if (_gone && stage != DeviceRequestStage.changed) {
      body = _text(l10n.deviceRequestGone, key: const ValueKey('device-request-gone'));
    } else {
      switch (stage) {
        case DeviceRequestStage.asks:
          body = column([
            _text(widget.own ? l10n.deviceRequestIntroOwn : l10n.deviceRequestIntro(widget.name),
                color: ZestColors.textPrimary),
            const SizedBox(height: 10),
            _text(l10n.deviceRequestHow),
          ]);
          primary = (label: l10n.profileContinue, onPressed: _busy ? null : _answer, icon: LucideIcons.arrowRight);
          // Close did what the header's X does. Decline answers the request,
          // apart from Continue (a red button beside it was one slip from
          // the way on): the tertiary place, as answering a request for
          // access has it.
          secondary = null;
          tertiary = (label: l10n.deviceRequestDecline, onPressed: _busy ? null : () => _decline(differ: false));
        case DeviceRequestStage.answered:
          body = column([_waiting(l10n.deviceRequestWaitingDevice)]);
          secondary = (label: l10n.cancel, onPressed: close);
        case DeviceRequestStage.compare:
          body = column([
            _text(l10n.deviceRequestCompare, color: ZestColors.textPrimary),
            const SizedBox(height: 14),
            ApprovalWords(key: const ValueKey('device-request-words'), words: _view.words!),
            if (code != null) ...[
              const SizedBox(height: 10),
              _codeLine(l10n.deviceTheirCode(code), key: const ValueKey('device-request-code')),
            ],
          ]);
          primary = (label: l10n.deviceRequestApprove, onPressed: _busy ? null : _approve, icon: LucideIcons.check);
          secondary = (label: l10n.deviceRequestDiffer, onPressed: _busy ? null : () => _decline(differ: true));
        case DeviceRequestStage.cutOff:
          body = column([_text(l10n.deviceRequestCutOff, key: const ValueKey('device-request-cut-off'))]);
          primary = (label: l10n.deviceRequestDecline, onPressed: _busy ? null : () => _decline(differ: false), icon: null);
        case DeviceRequestStage.changed:
          body = _text(l10n.deviceRequestChanged,
              key: const ValueKey('device-request-changed'), color: ZestColors.textPrimary);
      }
    }
    final warn = _gone || stage == DeviceRequestStage.cutOff || stage == DeviceRequestStage.changed;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: stage == DeviceRequestStage.changed
          ? ZestDialogTone.destructive
          : warn
              ? ZestDialogTone.neutral
              : ZestDialogTone.info,
      icon: LucideIcons.monitorSmartphone,
      title: widget.own ? l10n.deviceRequestTitleOwn : l10n.deviceRequestTitle(widget.name),
      subtitle: orchardDisplayName(widget.orchard.name, l10n),
      body: body,
      primaryAction: primary,
      secondaryAction: secondary,
      // Declining, or saying the codes differ, refuses the device: red.
      secondaryDanger: secondary?.label == l10n.deviceRequestDiffer,
      primaryDanger: primary?.label == l10n.deviceRequestDecline,
      tertiaryAction: tertiary,
      tertiaryDanger: tertiary?.label == l10n.deviceRequestDecline,
      tertiaryKey: tertiary == null ? null : const ValueKey('device-request-decline'),
    );
  }
}
