# ZestSSH Architecture

Last updated for **v1.5.41**.

This is the high-level map of the codebase. For specifics, follow the file
links and read the comments: every non-trivial file has a docstring at the
top explaining its role and gotchas.

---

## Tech stack

| Layer | Choice | Why |
|---|---|---|
| Framework | Flutter (Dart 3.10+) | Single codebase across 5 platforms |
| State | Riverpod (Notifier + StateProvider + FutureProvider) | Compile-time-safe DI, no global singletons |
| Navigation | GoRouter | Declarative deep-link safe routing |
| Local DB | Drift (SQLite via SQLCipher) | Type-safe queries, encrypted at rest |
| Secrets | flutter_secure_storage | OS Keychain / Keystore / DPAPI¹ |
| SSH | `packages/zest_ssh_core` (MIT-licensed fork of dartssh2) | Full control over the transport, KEX, ciphers |
| Terminal | `packages/xterm` (custom-patched) | xterm.js-compatible renderer |
| IAP | RevenueCat | Cross-platform purchase wrapper |
| Cloud auth | Firebase Auth (Google + Apple sign-in) | Identity for sync only |
| Cloud sync | Node.js + Postgres backend, AES-256-GCM E2EE | Zero-knowledge sync |
| Theming | OLED-first dark, charcoal + chrome | Designed around terminal contrast |

¹ **Windows secure-storage threat model:** `flutter_secure_storage` on Windows
wraps secrets (incl. the SQLCipher DB key) with DPAPI bound to the *Windows
user account*, with no app-specific entropy. This protects against other OS
users and offline disk theft, but NOT against malware or another process
running as the same user: such a process can call `CryptUnprotectData` and
recover the DB key. "Encrypted at rest" should be read with that scope. See
the security-audit notes for the optional per-app-entropy hardening path.

Platforms: **Android, iOS, Windows, macOS, Linux**: all share `lib/`.

---

## Project layout

```
lib/
├── core/
│   ├── data/                   static catalogs (OS icons, key types, etc.)
│   ├── models/                 cross-feature domain types
│   ├── theme/                  ZestColors, GroupColor enum
│   └── widgets/                shared atoms (OsIcon, StatusPill)
│
├── database/
│   ├── database.dart           AppDatabase + migrations (schema v18)
│   ├── database.g.dart         generated Drift code (DON'T edit)
│   ├── tables/                 12 Drift table definitions
│   └── daos/                   12 DAOs, one per table
│
├── features/                   feature modules: self-contained
│   ├── groups/                 connection groups (color + icon)
│   ├── hosts/
│   │   ├── data/               host-network-overrides repo
│   │   ├── models/             host card settings, network override
│   │   ├── pages/              hosts_home_page (grid view)
│   │   └── widgets/            host_card, host_grid_area, multi-select
│   ├── networks/
│   │   ├── data/               network_repository, icon_catalog
│   │   ├── engine/             detector, resolver, network_state
│   │   ├── models/             Network, NetworkTrigger sealed hierarchy
│   │   └── pages/              networks_page, network_editor_page
│   ├── notifications/
│   │   ├── models/             AppNotification
│   │   ├── notification_center.dart   queue + history Notifier
│   │   └── widgets/            bell, toast overlay
│   └── shortcuts/
│       ├── default_bindings.dart  built-in defaults map
│       ├── shortcut_action.dart   23 actions across 5 categories
│       ├── shortcut_key.dart      data class with HSV-style serialization
│       └── widgets/               keyboard_shortcuts_panel
│
├── l10n/                       .arb files + flutter gen-l10n output
├── models/                     domain types not tied to a single feature
│                                 (Connection-with-details, PaneTree,
│                                  WorkTab, Workflow, etc.)
├── providers/                  Riverpod surface (one file per concern)
│
├── router/                     GoRouter routes + guards
│
├── services/                   long-lived services + IO
│   ├── ssh_service.dart            owns one SSH session
│   ├── sftp_service.dart           wraps zest_ssh_core SFTP
│   ├── port_forward_service.dart   per-session forward registry
│   ├── session_transcript_service  recording + replay
│   ├── automation_service          workflow + scheduler executor
│   ├── network_detector            connectivity_plus + SSID lookups
│   ├── connection_resolver         host + network → ResolvedConnection
│   ├── pinned_http_client          cloud sync HTTPS w/ cert pinning
│   ├── prometheus_secure_settings  monitoring config
│   ├── security_lock_service       app PIN / biometric gate
│   ├── hardware_token/             YubiKey / FIDO2 ssh-agent integration
│   └── ssh_cert/                   SSH user-certificate generation
│
├── theme/
│   ├── app_colors.dart             every named color
│   ├── desktop_dimensions.dart     every desktop layout token
│   └── terminal_themes.dart        built-in xterm color schemes
│
└── ui/
    └── screens/                screen widgets, organised by feature area
```

External packages we own:

```
packages/
├── xterm/                custom xterm renderer (Flutter port)
└── zest_ssh_core/        SSH library, an MIT fork of dartssh2 (Ed448, ChaCha20, certs)
```

---

## Database (schema v18)

12 tables, all encrypted via SQLCipher:

| Table | Purpose |
|---|---|
| `connections` | Hostname, port, protocol, jump host, env vars, colour, etc. |
| `identities` | Passwords, key pairs, certificates, hardware-token refs |
| `connection_groups` | User-defined groups (colour + icon) for hosts |
| `known_hosts` | TOFU host key cache |
| `snippets` | Reusable command templates with variables |
| `port_forward_rules` | Saved -L/-R/-D rules, optionally pinned to a Network |
| `automation_history` | Workflow execution log |
| `workflows` | Visual automation pipelines (steps as JSON) |
| `scheduled_tasks` | WorkManager-backed background automation |
| `networks` | User-defined networks with triggers |
| `host_network_overrides` | Per-host config that fires when a network matches |
| `connection_tags` | Composite-PK (connectionId, tag) for free-form labels |

Migrations are append-only in `database.dart`'s `onUpgrade` block. **Never
re-number a schema version.** When you add a column, add a `from < N` step.

Pre/post-migration row-count integrity check guards against silent data loss
during migration (`_recordTableCounts` + `_verifyMigrationIntegrity`).

---

## Authentication flow

1. User clicks a host card → `activeSessionsProvider.startSession(connection)`
2. `_resolveIdentity` reads the identity row, decrypts secrets, materialises a
   `SSHKeyPair` (PEM keys), optionally a password, and resolves any SSH cert
3. `_buildJumpChain` walks `connectViaId` recursively (with cycle detection),
   dials from outermost-first, returns a tunnel socket + list of intermediate
   `SSHClient`s for cleanup
4. `SshService` opens the SSH session using either the direct socket or the
   tunnel socket, applies keep-alive, compression, agent-forwarding settings
5. Session id stored in `activeSessionsProvider`, terminal widget mounts and
   connects its xterm to the session's stdout/stdin streams

---

## Networks feature (v1.5)

Context-aware connection profiles:

- **NetworkDetector** runs `connectivity_plus` plus SSID lookups (perm-gated
  on Android via `ACCESS_FINE_LOCATION`, on iOS via the wifi-info
  entitlement). Reports a `NetworkState` snapshot.
- **NetworkRepository** stores user-defined `Network`s with one or more
  `NetworkTrigger`s (sealed hierarchy: `SubnetTrigger`, `SsidTrigger`,
  `CellularTrigger`, `ConnectivityTrigger`, `AlwaysTrigger`).
- **ConnectionResolver** combines the detected network + per-host overrides
  to produce a `ResolvedConnection`: the final address, port, username,
  identity, jump chain, and optional `bringUpVpn` host id.
- **HostNetworkOverride** lets each host specify `address / port / username /
  identityKeyId / jumpHostId / jumpHostChain / skipHost` per network.
- **PortForwardRule.networkId** (v1.5 addition) pins auto-start forwards to a
  specific network: null = "all networks" (pre-v1.5 behaviour).

The Default fallback network is pinned to the bottom of the eval order with
an `AlwaysTrigger`, never deleted, and always present after `ensureDefault()`
runs on first launch.

---

## Cloud sync

Zero-knowledge end-to-end encryption:

1. User sets a Master Sync Password
2. Argon2id(password, 256-bit salt) → 256-bit MEK (Memory: 128 MB, Iters: 3,
   Parallelism: 4). 64 MB is the legacy v1 profile, kept for accounts created
   before the v2 parameter bump.
3. SHA-256(MEK) → verification hash (this is what the server compares; the
   server never sees the MEK)
4. Push flow: JSON → zlib → AES-256-GCM(MEK) → `salt|IV|tag|ciphertext` →
   base64 → POST `/v1/sync/push`
5. Pull flow: GET `/v1/sync/pull` → base64 → split → Argon2id → verify SHA-256
   → decrypt → decompress → parse

Backend lives at `backend/` (Node + Postgres + Firebase Admin). API base:
`https://api.zestssh.com`. See [memory/cloud-sync.md](cloud-sync.md) for the
table schema + endpoint list.

**Bring-your-own-cloud (v1.5.41):** the hosted ZestSSH Cloud is now just one
of several sync targets behind a `SyncBackend` abstraction (`lib/services/sync/`).
The same E2E-encrypted blob can be pushed to WebDAV, S3-compatible object
storage, Google Drive, a self-hosted "dumb store", or the ZestSSH server:
the encryption model above is unchanged; only the transport differs. See
[docs/self-hosted-sync.md](../docs/self-hosted-sync.md).

---

## Notifications (IntelliJ-style)

Single `NotificationCenter` Riverpod Notifier holds:

- A history list (cap 50, oldest evicted)
- A set of currently-visible toast ids (cap 4 concurrent)
- An ordered queue of pending toasts when at capacity

Severity-driven auto-dismiss:

| Severity | Default dismiss |
|---|---|
| info | 4 s |
| success | 4 s |
| warning | 8 s |
| error | ∞ (sticky) |

`showTopSnackBar(context, msg)` is platform-aware:

- **Desktop** → pushes to `NotificationCenter` (slide-in from the right,
  click to dismiss)
- **Mobile** → Material `SnackBar` pinned to the top, swipe-UP to dismiss
  (the snackbar lives at the top via a huge `bottom: size.height - 100`
  margin, so swipe-down would push it INTO the screen: `dismissDirection:
  DismissDirection.up` is the natural gesture)

---

## Editable keyboard shortcuts

23 actions across 5 categories (General / Tabs / Layout / Terminal / Misc),
all rebindable. Defaults in
[`lib/features/shortcuts/default_bindings.dart`](lib/features/shortcuts/default_bindings.dart).

User overrides stored as JSON in SharedPreferences. The dispatcher
(`shortcutBindingsProvider`) resolves `effective = override ?? default`. An
explicit unbind sentinel (`keyId == 0`) lets the user say "this action has no
shortcut" without losing the action entry.

`desktop_shell.dart`'s `_handleKeyEvent` dispatches the most common shortcuts
via `bindings.matches(event, action)`. Deeper layout shortcuts (split, pane
focus) still have direct handlers: those don't go through the dispatcher
because they'd race the IME / focus traversal.

---

## Branding

| Tier | Internal name | Display name | Price |
|---|---|---|---|
| Free | `free` | Free | - |
| Pro | `pro` | **Squeezed** | $9.99 |
| Cloud Sync | `cloud_sync` | **Juiced** | $24.99 |
| Pro + Cloud | both entitlements | **Orchard** | $29.99 (bundle) |

RevenueCat product IDs: `zestssh_pro`, `zestssh_cloud_sync`, `zestssh_bundle`.

---

## Build + ship

All release builds need `--dart-define-from-file=.env` so the bundled config
(RevenueCat keys, sync API base, Firebase config) is present:

```bash
flutter build windows --release --dart-define-from-file=.env
flutter build appbundle --release --dart-define-from-file=.env
flutter build ipa --release --dart-define-from-file=.env
flutter build macos --release --dart-define-from-file=.env
flutter build linux --release --dart-define-from-file=.env
```

Windows ships as an Inno Setup installer (`installer/zestssh_setup.iss`,
bump `MyAppVersion` before compiling). Sign with `signtool` before public
distribution: comment block in the .iss has the exact incantation.

macOS is **not** sandboxed (see comments in
`macos/Runner/Release.entitlements`). Sandboxing forced
`com.apple.security.keychain-access-groups` to resolve `$(AppIdentifierPrefix)`
at sign time, which broke every non-App-Store build with `errSecMissingEntitlement
= -34018`. Plus an SSH client needs `~/.ssh` access, which the sandbox does
not give.

---

## Conventions

| Rule | Why |
|---|---|
| `const` constructors wherever possible | Tree-shaking depends on it (icons especially) |
| Every colour goes through `AppColors` | Re-themable, no inline hex |
| Database icons stored as codePoint + looked up in a const catalog | Tree-shake-safe |
| No `Co-Authored-By` lines in commits | Project convention |
| Don't add file-based logging | Removed in 1.5: zero data on disk |
| Brand names: Squeezed / Juiced / Orchard | Free / Pro / Cloud / Bundle |

---

## Where to look

| Looking for… | Look at… |
|---|---|
| Schema migrations | `lib/database/database.dart` `onUpgrade` |
| SSH connect flow | `lib/providers/terminal_providers.dart` `_createSshShell` |
| Network detection | `lib/features/networks/engine/network_detector.dart` |
| Network resolver | `lib/features/networks/engine/connection_resolver.dart` |
| Notification center | `lib/features/notifications/notification_center.dart` |
| Keyboard shortcuts | `lib/features/shortcuts/` |
| Pill bar + sidebar | `lib/ui/screens/desktop/desktop_shell.dart` |
| Hosts grid + customization | `lib/features/hosts/widgets/host_card.dart` |
| Theme designer + HSV picker | `lib/ui/screens/desktop/widgets/theme_designer_view.dart` |
| Settings nav + sections | `lib/ui/screens/desktop/widgets/settings_inline_view.dart` |
| Workflow editor | `lib/ui/screens/automation/workflow_editor_screen.dart` |
| Identity edit dialog | `lib/ui/screens/identity/identity_edit_screen.dart` |
| Connection edit dialog | `lib/ui/screens/connection/connection_edit_screen.dart` |
| OS icons catalog | `lib/core/data/os_catalog.dart` |
| Network icon catalog | `lib/features/networks/data/network_icon_catalog.dart` |
| Theme tokens | `lib/theme/app_colors.dart`, `lib/theme/desktop_dimensions.dart` |
