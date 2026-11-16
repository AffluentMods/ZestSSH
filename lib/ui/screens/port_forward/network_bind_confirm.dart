import 'package:flutter/widgets.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/port_forward_service.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Where a forward listens on this device, as it will run: [bindAddress],
/// or every address where "Allow other devices on my network" is on
/// ([PortForwardService.bindAddressFor]). Null for a forward from a port on
/// the host, which listens there.
String? forwardListensOn(PortForwardType type, String bindAddress, {bool gatewayPorts = false}) =>
    type == PortForwardType.remote
        ? null
        : PortForwardService.bindAddressFor(type, bindAddress.trim().isEmpty ? '127.0.0.1' : bindAddress.trim(),
            gatewayPorts: gatewayPorts);

/// A forward's kind as a rule keeps it and the editor gives it ('local',
/// 'remote', 'dynamic').
PortForwardType forwardTypeOf(String type) => type == 'remote'
    ? PortForwardType.remote
    : type == 'dynamic'
        ? PortForwardType.dynamic
        : PortForwardType.local;

/// Asks before a forward is kept that other devices can reach, a forward
/// that listens beyond this device ([PortForwardService.isNonLocalBind]),
/// where it did not before ([before], where it listened as it was saved):
/// anyone who reaches this device over the network can then go through the
/// SSH connection (22 October 2026: the service said its callers should ask,
/// and none did). True when it may be kept: it listens on this device
/// alone, it listened there before, or the person allowed it.
Future<bool> confirmNetworkBind(
  BuildContext context, {
  required String? listensOn,
  required int port,
  String? before,
}) async {
  if (listensOn == null || !PortForwardService.isNonLocalBind(listensOn)) return true;
  if (before != null && before == listensOn) return true;
  final l10n = AppLocalizations.of(context)!;
  // It exposes the connection to the network: the reason in its amber
  // sentence, and Allow red (the dialog rules of 3.4).
  final allowed = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.pfNetworkBindTitle,
    body: '',
    warning: l10n.pfNetworkBindBody(listensOn, port),
    confirmLabel: l10n.pfNetworkBindAllow,
    // Enter, Enter must not expose it: the safe choice stands (L10).
    autofocusConfirm: false,
  );
  return allowed == true;
}
