# SFTP / SSH connection isolation architecture (Design B)

Status: DESIGN, in progress.
Phase 0 (send-side yield) landing first.

## Problem

Flutter/Dart runs the whole app on one thread per isolate, and today **every byte
of SSH work lives on the same isolate as the UI**: terminal rendering, input, and
the entire SFTP transfer (local file read, packet framing, ChaCha/GCM crypto, the
SFTP protocol state machine, socket I/O). During a heavy transfer that one worker
is buried, so it never paints a frame or services a click. A folder of many small
files is the worst case: ~5 SFTP requests per file (open `.zestpart`, write, close,
rename, setstat) means a few hundred files is 1000+ mostly tiny packets, each a
full trip through that single busy isolate. When the torrent never lets up, the UI
looks hung, minimized windows will not restore, and the terminal stutters.

Two failed/rejected narrower attempts frame this design:

- **Per-packet send-crypto offload (abandoned).** Moving only encryption to a
  worker isolate ADDED per-packet cross-isolate copy + serialization overhead that,
  for tiny packets, dwarfs the ~1-2 us of crypto it removed, and had no cooperative
  yield on the outbound path, so it made the folder case worse and hung the app. See
  `sftp-ui-lag-mainisolate-crypto` memory.
- **32 KB chunk size (shipped, keep).** Halved packet/round-trip count per MB for
  large files. Necessary but not sufficient.

## Decision: Design B (per-connection worker isolate). Reject Design A.

**B:** each SSH session (transport + terminal channel + SFTP channel + port-forwards)
lives on ONE worker isolate that owns the socket. The UI isolate becomes a thin
client: it sends commands (keystrokes, sftp ops) and receives events (terminal
output, sftp progress) over a `SendPort`/`ReceivePort` pair. All SSH work is off
the UI thread, and there is exactly ONE connection per session.

**A (rejected):** a dedicated *second* SSH connection for SFTP on its own worker,
leaving the terminal on the primary connection. Better SFTP-vs-terminal isolation,
smaller blast radius, but it is **eliminated on the "no security downsides" bar**,
not on preference:

1. **Second factor breaks.** `onUserInfoRequest` deliberately returns empty for
   single-use verification-code prompts because reusing a factor leaks it into the
   server's 2FA log (`lib/services/ssh_service.dart:301-338`). A's second login needs
   a *fresh* factor the first login already burned: it must re-prompt for a new TOTP
   just to browse files, or replay one (a real downside, usually server-rejected).
2. **Credential-retention regression.** Credentials are nulled the instant auth
   resolves (`ssh_service.dart:213-216`). A opened lazily needs them after they are
   gone: pin plaintext for the whole session, or re-prompt. Either weakens the
   current clear-within-seconds posture.
3. **Jump chains double every login.** A forwarded socket cannot cross into A's
   isolate, so `_buildJumpChain` (`lib/providers/terminal_providers.dart:3036`)
   re-dials and re-auths end to end: a 3-hop chain goes from 4 logins to 8.

A's whole "show the user we opened a second connection" transparency requirement
exists only to paper over a wound A inflicts. **B deletes it**: one login, one line
in the server's `auth.log`, nothing to disclose, no second factor, no confusion.

## Security: B has no inherent downside vs today, with ONE hard invariant

One login, one host-key verification, credential lifetime identical to today (auth
runs once on the worker, credentials cleared on the same schedule), no second
socket, no second factor. Crossing credentials + callbacks to a worker is **not** a
new trust boundary: isolates share one OS process and heap, and the pattern already
shipped (the send-crypto worker sent live send keys to a worker with a Finalizer to
kill an orphaned one).

**MANDATORY INVARIANT (hard review gate, must have a regression test):** the
worker's host-key callback MUST route the decision back to the main isolate and call
the *identical* `KnownHostsService.verify` (`lib/services/known_hosts_service.dart:94`)
against the SQLCipher DB the main isolate owns: TOFU, changed-key and key-type-change
detection, and `viaScope` route-scoping all intact. The interactive auth callbacks
(`onPasswordRequest`, `onUserInfoRequest`) must reach the *same* prompt UI. A
worker-side `return true` stub would silently downgrade MITM protection; that is the
one thing that can make B insecure, and it must be gated in review and covered by a
host-key-change test before any transport work lands on the worker.

## Keeping the same session's terminal snappy

In B the terminal and SFTP share one per-connection worker, so a heavy transfer
could contend with that session's terminal. It can never *freeze* it (per-channel
flow windows keep the terminal channel's buffer from starving,
`packages/zest_ssh_core/lib/src/ssh_channel.dart:49-53`; the cooperative yield caps
how long a terminal packet waits behind an SFTP burst). The residual stutter is
driven to near-zero by, in priority order:

1. **A child sub-worker for SFTP file grunt work.** The connection-owning worker
   does ONLY transport (socket read, decrypt, frame, dispatch). Local file read/write
   for bulk transfers runs on a *second, child* isolate spawned from the owner, so the
   owner's event loop is never blocked by disk. (B's ownership model borrowing A's
   "separate the heavy work" idea without a second connection.) Note: ZestSSH does no
   local integrity hashing today, so there is no hashing to offload; if resume/verify
   ever adds it, it goes here.
2. **Terminal-priority draining.** When packets drain, service the terminal channel
   ahead of the SFTP channel within each yield quantum.
3. **Tuned SFTP receive window** so a bulk transfer cannot monopolize socket
   head-of-line; the terminal channel's independent window keeps its bytes flowing.
4. **Terminal output across the boundary via `TransferableTypedData`** (zero-copy
   Uint8List hand-off) with small-batch chunking + port backpressure, so a `cat biglog`
   firehose cannot flood the `SendPort`. Interactive keystroke latency stays sub-ms.

## Phased migration (each phase independently valuable + reversible)

### Phase 0: Send-side cooperative yield (LANDING NOW; not part of B, but the right first relief)

Mirror the receive-side `_packetsPerYield = 8` (`ssh_transport.dart:828`) on the
OUTBOUND path: after every N packets/chunks in the upload drive, do a *macrotask*
yield (`await Future<void>.delayed(Duration.zero)`) so the platform message pump
(paint, input, window-restore) gets a slice during a sustained upload burst. This
directly closes the "no outbound yield" gap that caused the hang, needs no isolate,
no cross-isolate copy, and no nonce-reuse surface. One connection, zero security
change. Must be live-tested against a real host (SFTP-must-test convention). This is
the cheap fix that makes today's lag tolerable while B is built.

### Phase 1: The B core, feature-flagged, behind the existing interfaces

Build a per-connection worker transport *behind* the current `SSHService` /
`SftpService` public surface so consumers (`terminal_providers`, monitoring,
port-forward) are unchanged. Message protocol: commands in, events out; terminal
bytes via `TransferableTypedData`. Invert the five `SSHClient` callbacks
(`onVerifyHostKey`, `onPasswordRequest`, `onUserInfoRequest`, `onUserauthBanner`,
`onHostKeyReceived`) to request/response over the `SendPort`. **The security
invariant above lives here**: wire the routed host-key check to the real
`KnownHostsService.verify` and add the host-key-change regression test first.

Blueprint build order (each sub-step compiles + has a no-live-host test):
1. feature flag + shared prompt rule (prep, no behavior change);
2. **`SshCallbackRouter` + the host-key-change regression test FIRST: the merge
   gate**, pure main-isolate, runs under `flutter test`;
3. message protocol + `ConnectParams` serialization (round-trip test);
4. worker entrypoint + spawn/handshake/close over a fake in-memory `SSHSocket`;
5. terminal I/O batching + backpressure credit loop (fake-socket test);
6. `WorkerSshService` facade satisfying `ShellService`;
7. seam-2 capability gates (`shell is SshService` -> `shell.supportsInProcessClient`);
8. flag wiring in `_createSshShell` + widen its return type to `ShellService`.

**Scope resolution (from the Phase-1 blueprint):** one connection = one socket =
one isolate, and a live `SSHClient` cannot cross an isolate, so terminal-on-worker
+ SFTP-on-main for the SAME session is infeasible. Phase 1 therefore selects the
worker path ONLY for **direct (no jump chain), terminal-only** sessions, and only
when the flag is ON; anything needing SFTP, port-forward, or a jump chain stays on
the in-isolate `SshService`. With the flag default OFF, production never hits that
gap. SFTP moves onto the worker in Phase 2.

**AS-BUILT (2026-09-01, steps 1-2 LANDED + verified, UNCOMMITTED, flag OFF):**
`lib/config/feature_flags.dart` (`kWorkerConnectionIsolation`, default false,
`--dart-define=WORKER_CONN_ISOLATION=true` override) · `lib/services/ssh_auth_prompts.dart`
(the single `isRealPasswordPrompt` rule, now used by BOTH `SshService` and the
router so the 2FA-fail-closed check cannot drift) · `lib/services/worker/ssh_callback_router.dart`
(the security seam: forwards `verifyHostKey`/`passwordRequest`/`userInfoResponse`
to the injected real `HostKeyVerifyCallback` + the shared prompt rule; holds no
`KnownHostsService`, no DAO: structurally cannot self-approve). Merge-gate test
`test/services/worker_hostkey_gate_test.dart`: 8 cases (changed key, changed key
TYPE, `viaScope` route scoping survives the boundary, no self-approve path,
credential fail-closed on a 2FA prompt): all green, plus the 12 existing
known-hosts tests still green (refactor is byte-identical).

**AS-BUILT (2026-09-02, steps 3-5 LANDED + verified + COMMITTED, flag still OFF):**
the entire unit-testable core of the scaffold now exists, all `flutter test`
green, nothing wired into a production path yet.

- Step 3 (`a9bac5c`) `lib/services/worker/worker_protocol.dart`: the closed
  `WorkerCommand` (main->worker) and `WorkerEvent` (worker->main) families plus
  `ConnectParams`, each with explicit `toWire()`/`fromWire()` (short string tag,
  fails loud on mismatch). Auth + host-key prompts travel OUT as request events;
  only the answer comes back, so the worker keeps no self-approve path.
  `test/services/worker_protocol_test.dart`: 24 round-trip tests incl. a
  recursive guard that every wire form is `SendPort`-transmissible.
- Step 4 (`f31fcd5`) `worker_transport.dart` (the `WorkerTransport` seam +
  `WorkerTransportHooks` + factory) and `worker_connection_host.dart` (the
  isolate-agnostic lifecycle core). The host allocates a request id, emits the
  request event, and parks on a completer only a main-isolate reply can
  complete; a mismatched id is dropped; teardown fails every parked request
  CLOSED (host key -> reject). `test/services/worker_connection_host_test.dart`:
  7 lifecycle tests incl. reject-aborts-before-auth and stray-reply-no-unblock,
  driven by a fake transport (no live host).
- Step 5 (`a7f8c89`) `terminal_output_batcher.dart`: same-turn stdout coalesces
  into one microtask-flushed batch, threshold chunk flushes sync, high/low-water
  ack backpressure pauses+resumes the shell read.
  `test/services/terminal_output_batcher_test.dart`: 9 tests.

**REMAINING = steps 6-8, the live-integration layer (deliberately NOT built
compile-only in a marathon tail):** the real isolate entrypoint + an
`SSHClient`-backed `WorkerTransport` (mirrors `ssh_service.dart:264-418`), the
`WorkerSshService` facade over `ShellService`, the seam-2 capability gate in
`terminal_providers`, and the flag wiring in `_createSshShell` (with the
mandatory default-OFF test). These touch the SSH hot path and are verifiable
only against a real host, so they land as one careful pass with live testing in
the loop, which is also the first point they do anything (flag flips on). **OPEN
DESIGN QUESTION they surface:** publickey auth on the worker needs the private
key to sign there; the password/keyboard-interactive path round-trips cleanly
via the router (no key crossing), but publickey either serializes key material
onto the worker (spec-sanctioned: same OS process/heap) or needs an
external-signer hook the forked core does not expose today. First worker slice
is therefore password / keyboard-interactive, direct + terminal-only; publickey
on the worker is a Phase-2 decision.

### Phase 2: SFTP onto the worker's connection

Move SFTP to channels on the worker's transport; add the child sub-worker (disk I/O),
terminal-priority draining, and the tuned SFTP window from the section above. This
kills A's whole problem class: one login, no second factor, and SFTP can lag all it
wants without freezing the UI.

### Phase 3: Finish the migration

Move port-forward (`forwardLocal`/`forwardRemote`), SOCKS5, and monitoring (`execute`)
onto the worker; jump chains move wholesale onto the worker as one owned unit (cleaner
than A's per-hop redial). The UI isolate becomes provably pure UI.

## Interfaces to preserve

`SSHService` and `SftpService` public methods keep their signatures; only their
implementations move behind the worker proxy. Consumers must not need edits. The
feature flag lets Phase 1/2 ship dark and be A/B'd against the current in-isolate
path.

## Risks + de-risking

- **Host-key downgrade (critical).** Mitigation: the mandatory invariant + a
  host-key-change regression test as the first thing that lands in Phase 1.
- **Terminal-output boundary throughput.** Mitigation: `TransferableTypedData` +
  batching + backpressure; benchmark a firehose (`yes`, `cat biglog`) before Phase 3.
- **Callback deadlocks (worker blocked awaiting a UI prompt).** Mitigation: the
  worker never blocks its event loop on a prompt; prompts are async request/response,
  and pending transport continues.
- **Scope creep.** Mitigation: strict phase gates; Phase 0 ships alone and is worth
  it alone.

## Testing

- Phase 0: real-host large single-file upload + a folder of many small files;
  confirm the UI stays responsive and window-restore works during a transfer.
- Phase 1: the host-key-change regression test (changed key, changed key type,
  jump-host route scope) MUST pass before merge; verify prompts still appear.
- Phase 2: byte-integrity of a large upload + download (checksum vs local) across
  several server types; terminal-usable-during-transfer manual check.
