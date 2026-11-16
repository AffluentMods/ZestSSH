import 'package:zestssh/services/ssh_service.dart';

/// A host signed in to for a run on hosts (3.0), and [teamLog]: the id its
/// team's log of the run goes by (TeamSessionLogs), where the host's Crate
/// logs sessions; null where nobody logs them.
class RunClient {
  const RunClient(this.ssh, {this.teamLog});

  final SshService ssh;
  final String? teamLog;
}
