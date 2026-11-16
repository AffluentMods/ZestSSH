import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_edit_controller.dart';

/// A three-node "This device → Server → Service" tunnel diagram, shared by the
/// Simple and Advanced Port Forwarding editors.
///
/// Each column is an icon + a bright label + a dim mono sub-line, joined by two
/// arrows. All three modes read left-to-right with arrows pointing RIGHT; the
/// node CONTENT changes per mode so the brand-accented "This device" always
/// sits on the sending or receiving side the user should notice first:
///
///  * LOCAL   - this device ▸ server ▸ the service you're reaching.
///  * REMOTE  - callers on the server ▸ through the tunnel ▸ your device
///              (mirrored so This device, the receiving end, is on the right).
///  * DYNAMIC - this device ▸ server ▸ the open internet (SOCKS5).
///
/// In Simple mode ([showCaption] true) a hairline + one plain-language sentence
/// is drawn beneath the nodes; Advanced omits it.
class TunnelDiagram extends StatelessWidget {
  const TunnelDiagram({
    super.key,
    required this.type,
    required this.devicePort,
    required this.servicePort,
    required this.serverName,
    this.serverAddress,
    this.showCaption = false,
  });

  /// The forward direction - decides the node content and arrow direction.
  final PfForwardType type;

  /// The local port on this device (the rule's bindPort). Null while unfilled.
  final int? devicePort;

  /// The service / server-side port (the rule's remotePort). Null while
  /// unfilled and ignored for [PfForwardType.dynamic].
  final int? servicePort;

  /// The scoped connection's display name (its label), or a fallback.
  final String serverName;

  /// The scoped connection's host/address, shown as the server node's mono sub.
  /// Falls back to a neutral "tunnel" when unknown.
  final String? serverAddress;

  /// Draw the hairline + plain-language sentence beneath the nodes (Simple).
  final bool showCaption;

  String get _devicePortText => devicePort?.toString() ?? '<port>';
  String get _servicePortText => servicePort?.toString() ?? '<port>';

  String _serverSub(AppLocalizations l10n) {
    final a = serverAddress?.trim();
    return (a == null || a.isEmpty) ? l10n.zestPfNodeTunnel : a;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (left, right, mid, arrowsIncoming) = _nodes(l10n);

    return Container(
      padding: const EdgeInsets.fromLTRB(13, 14, 13, 14),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _NodeColumn(node: left)),
              _Arrow(incoming: arrowsIncoming),
              Expanded(child: _NodeColumn(node: mid)),
              _Arrow(incoming: arrowsIncoming),
              Expanded(child: _NodeColumn(node: right)),
            ],
          ),
          if (showCaption) ...[
            const SizedBox(height: 12),
            Divider(height: 1, color: ZestTokens.border),
            const SizedBox(height: 11),
            _Caption(text: _captionText(l10n)),
          ],
        ],
      ),
    );
  }

  /// Returns (leftNode, rightNode, midNode, arrowsIncoming). Arrows point RIGHT
  /// for all three modes; REMOTE is drawn as a MIRROR (On the server ▸ Server ▸
  /// This device) so the brand-accented "This device" reads as the receiving
  /// end on the right, consistent with the outbound LOCAL / DYNAMIC layouts.
  (_Node, _Node, _Node, bool) _nodes(AppLocalizations l10n) {
    final server = _Node(
      icon: LucideIcons.server,
      label: serverName,
      sub: _serverSub(l10n),
    );
    switch (type) {
      case PfForwardType.local:
        return (
          _Node(
            icon: LucideIcons.laptop,
            label: l10n.zestPfNodeThisDevice,
            sub: ':$_devicePortText',
            accent: true,
          ),
          _Node(
            icon: LucideIcons.database,
            label: l10n.zestPfNodeService,
            sub: 'localhost:$_servicePortText',
          ),
          server,
          false,
        );
      case PfForwardType.remote:
        // Mirror of LOCAL/DYNAMIC: arrows point RIGHT and the brand-accented
        // "This device" (the RECEIVING end of a -R exposure) sits on the RIGHT,
        // so the row reads left-to-right "callers on the server -> tunnel ->
        // your device" and matches the other two diagrams' direction. Tuple is
        // (left, right, mid): left = On the server, right = This device.
        return (
          _Node(
            icon: LucideIcons.globe,
            label: l10n.zestPfNodeOnServer,
            sub: ':$_servicePortText',
          ),
          _Node(
            icon: LucideIcons.laptop,
            label: l10n.zestPfNodeThisDevice,
            sub: 'localhost:$_devicePortText',
            accent: true,
          ),
          server,
          false,
        );
      case PfForwardType.dynamic:
        return (
          _Node(
            icon: LucideIcons.laptop,
            label: l10n.zestPfNodeThisDevice,
            sub: 'localhost:$_devicePortText',
            accent: true,
          ),
          _Node(
            icon: LucideIcons.globe,
            label: l10n.zestPfNodeInternet,
            sub: 'SOCKS5',
          ),
          server,
          false,
        );
    }
  }

  /// The Simple-mode caption. The port values are baked into the localized
  /// string (the ARB declares them as String args to avoid number-grouping).
  String _captionText(AppLocalizations l10n) {
    switch (type) {
      case PfForwardType.local:
        return l10n.zestPfCaptionLocal(_devicePortText);
      case PfForwardType.remote:
        return l10n.zestPfCaptionRemote(_servicePortText, _devicePortText);
      case PfForwardType.dynamic:
        return l10n.zestPfCaptionDynamic(_devicePortText);
    }
  }
}

class _Node {
  const _Node({
    required this.icon,
    required this.label,
    required this.sub,
    this.accent = false,
  });

  final IconData icon;
  final String label;
  final String sub;

  /// The "This device" node is tinted with the brand accent.
  final bool accent;
}

class _NodeColumn extends StatelessWidget {
  const _NodeColumn({required this.node});

  final _Node node;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          node.icon,
          size: 19,
          color: node.accent ? ZestTokens.brandInk : ZestTokens.textSecondary,
        ),
        const SizedBox(height: 5),
        Text(
          node.label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 11, color: ZestTokens.textPrimary),
        ),
        const SizedBox(height: 1),
        // The mono endpoint (e.g. `localhost:<port>`) is the widest content in a
        // node and the diagram column is narrow in the side-by-side layout, so it
        // is allowed to wrap onto a SECOND line rather than clip to `localhost:<por…`.
        Text(
          node.sub,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 11,
            fontFamily: 'JetBrainsMono',
            color: ZestTokens.textTertiary,
          ),
        ),
      ],
    );
  }
}

class _Arrow extends StatelessWidget {
  const _Arrow({required this.incoming});

  final bool incoming;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Icon(
        incoming ? LucideIcons.arrowLeft : LucideIcons.arrowRight,
        size: 16,
        color: ZestTokens.textTertiary,
      ),
    );
  }
}

class _Caption extends StatelessWidget {
  const _Caption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.5,
        color: ZestTokens.textSecondary,
      ),
    );
  }
}
