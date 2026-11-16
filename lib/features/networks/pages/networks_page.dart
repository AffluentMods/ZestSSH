import 'package:flutter/material.dart';

import 'networks_screen.dart';

/// Sidebar entry: Networks (desktop).
///
/// As of the 1.7 refactor the body IS the [NetworksScreen] master/detail - the
/// former `ListEditorSplit` + modal editor (and its top-right "+ Add network"
/// button) are gone. This thin wrapper is kept only so the desktop shell's
/// existing `const NetworksPage()` reference stays valid.
class NetworksPage extends StatelessWidget {
  const NetworksPage({super.key});

  @override
  Widget build(BuildContext context) => const NetworksScreen();
}
