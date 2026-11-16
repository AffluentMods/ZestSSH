// Compile-time / dart-define feature flags.
//
// Flags here gate features that are being built incrementally and must ship
// dark (inert) until they are proven against real hosts.

/// Design B (per-connection worker isolate) connection isolation.
///
/// Read where a session connects (terminal_providers.dart, workerEligible):
/// with it on, a DIRECT, terminal-only SSH session runs its transport on a
/// dedicated worker isolate that owns the socket, so a heavy SFTP transfer can
/// never freeze the UI, while sessions needing SFTP, port-forwarding, or a
/// jump chain stay on the in-isolate path. (This said nothing read it, while
/// the connect path does: found in a code audit.)
///
/// Defaults OFF (test/config/worker_flag_default_test.dart):
///
///   --dart-define=WORKER_CONN_ISOLATION=true
const bool kWorkerConnectionIsolation =
    bool.fromEnvironment('WORKER_CONN_ISOLATION', defaultValue: false);
