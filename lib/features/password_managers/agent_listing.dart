import 'dart:isolate';

import 'package:zestssh/services/hardware_token/os_ssh_agent.dart';

/// The keys the agent at [socketPath] (null: the system's) offers (3.0),
/// read off the app's main thread: an agent that hangs, or a password
/// manager waiting on the person, cannot freeze the app.
Future<List<OsAgentIdentity>> listAgentIdentities(String? socketPath) => Isolate.run(() async {
      final agent = await OsSshAgent.open(socketPath: socketPath);
      try {
        return await agent.listIdentities();
      } finally {
        await agent.close();
      }
    });
